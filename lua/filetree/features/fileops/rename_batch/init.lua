---@module 'filetree.features.fileops.rename_batch'
--- Batch-rename visible tree nodes in a scratch buffer.
---
--- Opens a scratch buffer listing the names (not full paths) of all visible
--- file and directory nodes in the current tree. The user edits the names
--- in normal Vim; on write (:w) the module diffs old vs new and executes
--- the renames via vim.fn.rename(). Directories are renamed atomically.
---
--- Features:
---   - Order-preserving: line 1 = node 1 no matter what.
---   - Dry-run preview: shows the plan before executing.
---   - Undo: uses safety backup if safety feature is loaded.
---   - Conflict detection: refuses to rename if the target already exists.
---
--- Keymap (default): "<leader>rb" in tree buffer.
--- User commands: :FiletreeRenameBatch
---
--- NOTE: does not default to "R" -- that's left free for the adapter's own
--- native refresh command (neo-tree's window.mappings default binds "R" to
--- refresh; overriding it here would silently shadow that far more commonly
--- expected action).

local notify = require("filetree.util.notify").create("[filetree.rename_batch]")

-- cwd-relative, forward-slash display form -- this repo's canonical way to
-- show a path in a message (see move/init.lua's identical "Failed: src ->
-- dst (reason)" shape).
local path = require("filetree.util.path")
local au = require("filetree.util.autocmd")
local buffer = require("filetree.util.buffer")
local ui_confirm = require("filetree.util.confirm")
-- Cross-file references (markdown links, require()/import statements) after
-- the batch: one scan, one chooser for the whole batch — see filetree.refs.
local refs = require("filetree.refs")

-- The one way this plugin moves a path: Windows sharing-lock retries (a batch
-- rename touches many watched paths in a row, so it is a prime trigger) plus
-- the cross-drive EXDEV fallback. See filetree.util.mutate.
local mutate = require("filetree.util.mutate")
-- Case-insensitive-FS guard: a case-only rename must not be blocked by the
-- "target already exists" check (see filetree.util.case_clash).
local case_clash = require("filetree.util.case_clash")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeRenameBatchConfig
local DEFAULTS = {
  enabled = false,
  keymap = "<leader>rb",
  confirm = false,
  use_safety = true,
  dry_run = false,
}

---@type FiletreeRenameBatchConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.rename_batch` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  confirm = "boolean",
  use_safety = "boolean",
  dry_run = "boolean",
  -- Deprecated, migrated by config/init.lua's apply_legacy_refs().
  check_markdown_refs = "boolean",
  refs_picker_prefer = { "string", enum = { "auto", "telescope", "fzf-lua", "quickfix" } },
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Node snapshot ─────────────────────────────────────────────────────────────

---@class RenameEntry
---@field abs_dir  string  Parent directory.
---@field old_name string  Original filename (tail only).
---@field new_name string  Name after user edit.

---@internal
---@return RenameEntry[]
local function snapshot_nodes()
  if not _adapter then return {} end
  local nodes = _adapter.get_visible_nodes and _adapter.get_visible_nodes() or {}
  local entries = {}
  for _, node in ipairs(nodes) do
    if node.type == "file" or node.type == "directory" then
      local abs_dir = vim.fn.fnamemodify(node.path, ":h")
      local old_name = vim.fn.fnamemodify(node.path, ":t")
      entries[#entries + 1] = {
        abs_dir = abs_dir,
        old_name = old_name,
        new_name = old_name,
      }
    end
  end
  return entries
end

-- ── Diff + execute ────────────────────────────────────────────────────────────

---@internal
---Actually perform the renames for an already-confirmed plan.
---
---Asynchronous because the reference scan is: it starts BEFORE the first
---rename (while every source still exists on disk, so relative link targets
---and module names resolve against the old layout) and the renames run inside
---its callback, so nothing can move out from under the scanner.
---@param plan {src:string, dst:string}[]
---@param on_done fun(ok: boolean)
local function run_plan(plan, on_done)
  -- Safety backup
  if _cfg.use_safety then
    local ok_s, safety = require("filetree.features").load("safety")
    if ok_s and safety then
      for _, op in ipairs(plan) do
        pcall(safety.before_move, op.src, op.dst)
      end
    end
  end

  local sources = {}
  for _, op in ipairs(plan) do
    sources[#sources + 1] = op.src
  end

  refs.prefetch(sources, { op = "rename" }).await(function(scan_result)
    local errors = 0
    local relocated = 0
    -- Only sources whose rename actually landed contribute references; a
    -- failed one must not have its links rewritten to a file that isn't there.
    local moves = {}

    for _, op in ipairs(plan) do
      local ok, err = mutate.move(op.src, op.dst)
      if not ok then
        notify.error(
          string.format(
            "Failed: %s → %s (%s)",
            path.relative(op.src),
            path.relative(op.dst),
            tostring(err)
          )
        )
        errors = errors + 1
      else
        -- Repoint any open buffer(s) at the old path (or nested under it, for a
        -- renamed directory) so a stale buffer for the old name doesn't linger
        -- alongside a second, disconnected buffer for the new one.
        relocated = relocated + buffer.relocate(op.src, op.dst)
        moves[op.src] = op.dst
      end
    end

    local done = #plan - errors
    local msg = string.format("Renamed %d/%d item(s)", done, #plan)
    if relocated > 0 then
      msg = msg .. string.format(" (%d open buffer(s) repointed)", relocated)
    end
    notify.info(msg)

    -- One chooser for the whole batch, across every provider, instead of one
    -- popup per renamed file. Refresh (and this function's own on_done) wait
    -- for the apply to actually land -- own_links.collect, when enabled, is
    -- never fully synchronous, so firing these right after the call returns
    -- would refresh before the rewrite is on disk.
    refs.handle_result(scan_result, moves, {
      op = "rename",
      title = "References across the renamed batch",
    }, function()
      require("filetree.util.changed").refresh(_adapter)
      on_done(errors == 0)
    end)
  end)
end

---@internal
---@param entries RenameEntry[]
---@param new_names string[]  Edited lines from the scratch buffer.
---@param on_done fun(ok: boolean)
local function execute_renames(entries, new_names, on_done)
  -- Pair up and collect changes
  ---@type {src:string, dst:string}[]
  local plan = {}

  for i, entry in ipairs(entries) do
    local new = new_names[i] and vim.trim(new_names[i]) or ""
    if new == "" then
      notify.warn(string.format("Line %d is blank — skipping %s", i, entry.old_name))
    elseif new ~= entry.old_name then
      local src = entry.abs_dir .. "/" .. entry.old_name
      local dst = entry.abs_dir .. "/" .. new
      plan[#plan + 1] = { src = src, dst = dst }
    end
  end

  if #plan == 0 then
    notify.info("Nothing to rename")
    on_done(true)
    return
  end

  -- Conflict check
  local blocked = false
  for _, op in ipairs(plan) do
    local exists = vim.fn.filereadable(op.dst) == 1 or vim.fn.isdirectory(op.dst) == 1
    -- A case-only rename (`Foo` → `FOO`) looks like a collision on a
    -- case-insensitive filesystem but is just an in-place re-casing.
    if exists and not case_clash.is_alias(op.src, op.dst) then
      notify.error("Target already exists: " .. op.dst)
      blocked = true
    end
  end
  if blocked then
    on_done(false)
    return
  end

  -- Dry-run
  if _cfg.dry_run then
    local lines = { "-- Rename plan (dry-run) --" }
    for _, op in ipairs(plan) do
      lines[#lines + 1] = "  "
        .. vim.fn.fnamemodify(op.src, ":t")
        .. " → "
        .. vim.fn.fnamemodify(op.dst, ":t")
    end
    notify.info(table.concat(lines, "\n"))
    on_done(true)
    return
  end

  -- Confirm
  if _cfg.confirm then
    ui_confirm({
      question = string.format("Rename %d item(s)?", #plan),
      on_choice = function(yes)
        if not yes then
          notify.info("Cancelled")
          on_done(false)
          return
        end
        run_plan(plan, on_done)
      end,
    })
    return
  end

  run_plan(plan, on_done)
end

-- ── Scratch buffer ────────────────────────────────────────────────────────────

function M.open()
  local entries = snapshot_nodes()
  if #entries == 0 then
    notify.warn("No visible nodes in tree")
    return
  end

  -- Header: 2 lines (comment + blank) prepended before any autocmd is wired
  -- up, so the BufWriteCmd below only ever has to know one offset, not patch
  -- around a header added after the fact.
  local HEADER_LINES = 2
  local header = string.format(
    "-- filetree: rename %d items. Edit names, then :w to apply or :bd to cancel.",
    #entries
  )
  local lines = { header, "" }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = e.old_name
  end

  -- Open horizontal split with scratch buffer
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, "filetree://rename")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("buftype", "acwrite", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })

  local augroup = au.group("filetree_rename_batch_" .. bufnr, true)
  -- The id of every autocmd made through the wrapper, so the BufDelete hook can
  -- take back their records with them: the group is named after this scratch
  -- buffer and never asked for twice, so deleting it alone left the records in
  -- lib.nvim's registry for the rest of the session (two per batch rename).
  local ids = {}

  -- BufWriteCmd fires when user does :w
  ids[#ids + 1] = au.acmd("BufWriteCmd", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local new_names = {}
      for i = HEADER_LINES + 1, #all_lines do
        new_names[#new_names + 1] = all_lines[i]
      end
      execute_renames(entries, new_names, function(ok)
        if ok then
          vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
          -- Close the scratch window
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end)
    end,
  })

  ids[#ids + 1] = au.acmd("BufDelete", {
    group = augroup,
    buffer = bufnr,
    once = true,
    callback = function()
      for _, id in ipairs(ids) do
        au.delete(id)
      end
      au.del_group(augroup)
    end,
  })

  -- Syntax: make header lines look like comments
  vim.cmd("syntax match Comment /^--.*$/")

  notify.info(string.format("Edit %d filenames. :w to apply, :bd to cancel.", #entries))
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---Toggle dry-run for batch rename.
---
--- `dry_run` was config-only here, while `trash` and `safety` both had a
--- runtime toggle. That asymmetry is the wrong way round: these two are the
--- destructive bulk operations you most want to preview once before letting
--- them run, and turning it on meant editing the config and reloading.
---@return boolean dry_run  the new state
function M.toggle_dry_run()
  _cfg.dry_run = not _cfg.dry_run
  notify.info("batch rename dry-run: " .. (_cfg.dry_run and "ON" or "OFF"))
  return _cfg.dry_run
end

---@param config FiletreeRenameBatchConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("rename_batch", _cfg, {
    { name = "open", field = "keymap", rhs = M.open, desc = "open batch rename buffer" },
  })
end

function M.teardown()
  _adapter = nil
end

return M
