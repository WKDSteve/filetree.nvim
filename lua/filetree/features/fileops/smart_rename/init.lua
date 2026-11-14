---@module 'filetree.features.fileops.smart_rename'
--- LSP-aware single-node rename with will/did rename notifications.
---
--- Renames the current node and notifies all attached LSP servers via the
--- workspace/willRenameFiles → (file move) → workspace/didRenameFiles
--- protocol sequence so that servers can update cross-file references.
---
--- Falls back gracefully when no LSP servers support file renames. Everything
--- an LSP client did *not* rewrite — markdown links always, plus require()/
--- import statements whenever no workspace edit was applied (which, for Lua,
--- is always: lua_ls never advertises the capability) — is handled by the
--- reference engine, `filetree.refs`, which also owns the chooser and the
--- undoable rewrite. Open Neovim buffers pointing at the old path are
--- repointed, and the safety feature gets its pre-rename backup.
---
--- Config:
---   enabled     boolean
---   keymap      string?   Key inside tree (default "r").
---   use_safety  boolean   Create safety backup before rename (default true).
---   dry_run     boolean   Log without executing (default false).
---   cursor      string    Prompt cursor: "before_ext" (before the last extension, default) or "end".
---
--- Reference handling is configured centrally under `refs` (see
--- `filetree.refs.DEFAULTS`), not per feature.
---
--- Commands (via :Filetree dispatcher):
---   :Filetree smartrename

local notify = require("filetree.util.notify").create("[filetree.smart_rename]")

local confirm_choice = require("filetree.util.confirm_choice")
-- Case-insensitive-FS guard: on Windows/macOS a case-only rename
-- (`Telemetry` → `TELEMETRY`) makes `isdirectory(new_path)` report a bogus
-- collision, because the OS folds the new spelling onto the existing entry.
local case_clash = require("filetree.util.case_clash")
local path = require("filetree.util.path")
local buffer = require("filetree.util.buffer")
-- Cross-file references (markdown links, require()/import statements) are the
-- reference engine's job, not this feature's: it owns the scan, the chooser
-- and the undoable rewrite for every provider at once.
local refs = require("filetree.refs")

-- The one way this plugin moves a path: retries the transient Windows sharing
-- errors (EPERM/EACCES/EBUSY) that a raw uv.fs_rename surfaces as a hard
-- failure, releasing neo-tree's watcher on the source between attempts, and
-- falls back to a copy+delete across drive letters. See filetree.util.mutate.
local mutate = require("filetree.util.mutate")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeSmartRenameConfig
local DEFAULTS = {
  enabled = false,
  keymap = "r",
  use_safety = true,
  dry_run = false,
  cursor = "before_ext",
}

---@type FiletreeSmartRenameConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.smart_rename` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  use_safety = "boolean",
  dry_run = "boolean",
  cursor = { "string", enum = { "before_ext", "end" } },
  -- Deprecated, migrated by config/init.lua's apply_legacy_refs().
  update_references = "boolean",
  check_markdown_refs = "boolean",
  refs_picker_prefer = { "string", enum = { "auto", "telescope", "fzf-lua", "quickfix" } },
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── LSP helpers ───────────────────────────────────────────────────────────────

---@internal
local function make_rename_files_params(old_uri, new_uri)
  return { files = { { oldUri = old_uri, newUri = new_uri } } }
end

---@internal
local function uri(fname)
  return vim.uri_from_fname(fname)
end

---@internal
---Send willRenameFiles to all supporting clients. Returns edit to apply (or nil).
---@param old_path string
---@param new_path string
---@param cb fun(workspace_edit: table?)
local function lsp_will_rename(old_path, new_path, cb)
  local params = make_rename_files_params(uri(old_path), uri(new_path))
  local clients = {}
  for _, client in pairs(vim.lsp.get_clients()) do
    local cap =
      vim.tbl_get(client, "server_capabilities", "workspace", "fileOperations", "willRename")
    if cap then clients[#clients + 1] = client end
  end

  if #clients == 0 then
    cb(nil)
    return
  end

  local pending = #clients
  local merged = {}
  for _, client in ipairs(clients) do
    client:request("workspace/willRenameFiles", params, function(err, result)
      pending = pending - 1
      if not err and result then merged = vim.tbl_deep_extend("force", merged, result) end
      if pending == 0 then cb(#vim.tbl_keys(merged) > 0 and merged or nil) end
    end)
  end
end

---@internal
local function lsp_did_rename(old_path, new_path)
  local params = make_rename_files_params(uri(old_path), uri(new_path))
  for _, client in pairs(vim.lsp.get_clients()) do
    local cap =
      vim.tbl_get(client, "server_capabilities", "workspace", "fileOperations", "didRename")
    if cap then client:notify("workspace/didRenameFiles", params) end
  end
end

-- Buffer update: filetree.util.buffer.relocate() (shared with copy_move and
-- rename_batch, which have the exact same "file moved on disk, repoint any
-- open buffer" need) handles both the single-file and nested-directory cases,
-- and normalizes path-separator style before comparing, and preserves
-- unsaved changes on a modified buffer instead of force-reloading them away.

-- ── Core rename ───────────────────────────────────────────────────────────────

---@internal
---@param old_path string
---@param new_path string
---@param scan_result FiletreeRefScanResult|nil  References captured BEFORE the
---  rename (via `refs.prefetch`), so every link style resolved against the old
---  location.
local function do_rename(old_path, new_path, scan_result)
  if _cfg.dry_run then
    notify.info(
      string.format(
        "[dry-run] %s → %s",
        vim.fn.fnamemodify(old_path, ":t"),
        vim.fn.fnamemodify(new_path, ":t")
      )
    )
    return
  end

  -- Safety backup
  if _cfg.use_safety then
    local ok_s, safety = require("filetree.features").load("safety")
    if ok_s and safety then pcall(safety.before_move, old_path, new_path) end
  end

  lsp_will_rename(old_path, new_path, function(workspace_edit)
    -- Apply workspace edit from LSP (reference updates) before the move
    if workspace_edit then pcall(vim.lsp.util.apply_workspace_edit, workspace_edit, "utf-8") end

    -- Synchronous rather than an async uv.fs_rename callback: we are already on
    -- the main loop here (the un-scheduled apply_workspace_edit above depends
    -- on that), which is exactly what the retry backoff's vim.wait needs — so
    -- the post-rename work runs inline instead of hopping through vim.schedule.
    local ok, err = mutate.move(old_path, new_path)
    if not ok then
      notify.error("Rename failed: " .. tostring(err))
      return
    end

    -- Notify LSP servers
    lsp_did_rename(old_path, new_path)

    -- Update open buffers
    buffer.relocate(old_path, new_path)

    local function finish()
      require("filetree.util.changed").refresh(_adapter)
      notify.info(
        string.format(
          "%s → %s",
          vim.fn.fnamemodify(old_path, ":t"),
          vim.fn.fnamemodify(new_path, ":t")
        )
      )
    end

    -- Everything that pointed at the old path: markdown links, require()s,
    -- imports. `lsp_handled` lets the engine skip the code providers whose
    -- language server already rewrote them (`refs.prefer_lsp`), while markdown
    -- and Lua — which never get an LSP edit here — still run. `finish` (tree
    -- refresh + notify) waits for the apply to actually land -- own_links,
    -- when enabled, is never fully synchronous.
    if scan_result then
      refs.handle_result(scan_result, { [old_path] = new_path }, {
        op = "rename",
        lsp_handled = workspace_edit ~= nil,
      }, finish)
    else
      finish()
    end
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Byte column (0-based) just before the extension of `name`, or nil when the
---cursor should stay at the end (directory, no extension, dotfile like ".gitignore").
---@param name string
---@param is_dir boolean?
---@return integer?
function M.stem_end(name, is_dir)
  if is_dir then return nil end
  local dot = name:match("^.*()%.")
  if not dot or dot == 1 or dot == #name then return nil end
  return dot - 1
end

function M.rename_current()
  if not _adapter then return end
  local node = _adapter.get_current_node()
  if not node or not node.path then
    notify.warn("No node under cursor")
    return
  end

  local old_path = node.path
  local old_name = vim.fn.fnamemodify(old_path, ":t")
  local dir = path.parent(old_path)

  -- Start the reference scan NOW, while old_path still exists on disk, so it
  -- overlaps with the (potentially long) time the user spends typing a new
  -- name. The rename only happens inside `await`, i.e. strictly after this
  -- scan finished, so old_path is always still present while it runs — see
  -- refs.prefetch. (Returns an immediately-resolving handle when references
  -- are switched off, so the flow below stays the same either way.)
  local refs_handle = refs.prefetch({ old_path }, { op = "rename" })

  local surf = require("ui.kit").input({
    title = "Rename to: ",
    default = old_name,
    on_submit = function(new_name)
      if not new_name or new_name == "" or new_name == old_name then return end
      new_name = path.slashify(new_name) -- accept "/" or "\" if renaming into a subdir
      local new_path = dir .. "/" .. new_name

      local function proceed()
        refs_handle.await(function(result)
          do_rename(old_path, new_path, result)
        end)
      end

      local exists = vim.fn.filereadable(new_path) == 1 or vim.fn.isdirectory(new_path) == 1
      if exists and case_clash.is_alias(old_path, new_path) then
        -- Only the case changed: `new_path` and `old_path` are the same entry
        -- on this filesystem. Not a real collision — mutate.move() (uv.fs_rename)
        -- re-cases it in place.
        proceed()
      elseif exists then
        confirm_choice("'" .. new_name .. "' exists.", { "Overwrite", "Cancel" }, function(choice)
          if choice == "Overwrite" then proceed() end
        end)
      else
        proceed()
      end
    end,
  })

  -- kit.input parks the cursor at the end of the line; for a file put it right
  -- before the extension so typing replaces just the stem.
  local stem_end = _cfg.cursor ~= "end" and M.stem_end(old_name, node.type == "directory") or nil
  if surf and stem_end then
    vim.schedule(function()
      if surf:is_valid() then pcall(vim.api.nvim_win_set_cursor, surf.winid, { 1, stem_end }) end
    end)
  end
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeSmartRenameConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("smart_rename", _cfg, {
    { name = "rename", field = "keymap", rhs = M.rename_current, desc = "LSP-aware rename" },
  })
end

function M.teardown()
  _adapter = nil
end

return M
