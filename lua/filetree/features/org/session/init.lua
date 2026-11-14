---@module 'filetree.features.org.session'
---@brief Save and restore tree scroll position and adapter root across sessions.
---@description
--- Persists per-project tree state to JSON:
---   - adapter name
---   - tree root directory
---   - scroll position (topline)
---   - cursor line
---   - a list of expanded directory paths (adapter-dependent; best-effort)
---
--- State is keyed by project root (detected via project_root feature or cwd).
--- On VimLeavePre the current state is written; on VimEnter (deferred) it is
--- restored.
---
--- User commands:
---   :FiletreeSessionSave
---   :FiletreeSessionRestore
---   :FiletreeSessionClear

local notify = require("filetree.util.notify").create("[filetree.session]")

local au = require("filetree.util.autocmd")
local tree_attach = require("filetree.util.tree_attach")
local bufutil = require("filetree.util.buffer")
local is_subpath = require("lib.nvim.fs.is_subpath")
local normkey = require("lib.nvim.fs.normkey")
local M = {}

--- Counts the restores asked for and the ones called off: a restore waits 100 ms for the tree, and
--- runs only when nothing newer came in between.
local _restore_gen = 0
--- The restore on the first attach of the tree has run, or was called off.
local _auto_restored = false

---@type FiletreeSessionConfig
local DEFAULTS = {
  enabled = false,
  auto_save = true,
  auto_restore = true,
  max_sessions = 50,
}

---@type FiletreeSessionConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.session` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  auto_save = "boolean",
  auto_restore = "boolean",
  max_sessions = { "number", min = 1 },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type string  path to session JSON file
local _store_path = ""

-- Cap on `entry.expanded`'s length when restoring (SEC-33: a persisted
-- snapshot is untrusted, and a count needs a defined bound same as a type
-- does). Matches config/DEFAULTS.lua's `max_visible_nodes` default -- a
-- session cannot plausibly have more expanded directories than the tree
-- walk itself is willing to collect nodes for.
local MAX_EXPANDED_DIRS = 5000

-- ── Storage ───────────────────────────────────────────────────────────────────

---@class FiletreeSessionEntry
---@field adapter   string
---@field root      string?   Tree root dir at save time.
---@field topline   integer   Scroll position.
---@field cursor    integer   Cursor line number.
---@field expanded  string[]  Expanded directory paths (best-effort).
---@field saved_at  integer   Unix timestamp.

---@type table<string, FiletreeSessionEntry>  project_key → entry
local _sessions = {}

local function ensure_dir()
  local dir = vim.fn.fnamemodify(_store_path, ":h")
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
end

---Back up `_store_path`'s current on-disk lines to `<path>.corrupt`, once, so
---a broken-but-present file never turns into silent data loss the next time
---`save_store()` writes the whole file back over it. Not re-written if a
---backup already exists (an earlier corruption caught on a previous load),
---so a caller retrying after that does not clobber it with, say, an
---even-more-truncated read.
---@param lines string[]?  Already-read lines, when available (avoids a second read).
local function backup_corrupt_store(lines)
  local backup_path = _store_path .. ".corrupt"
  if vim.fn.filereadable(backup_path) == 1 then return end
  lines = lines or select(2, pcall(vim.fn.readfile, _store_path))
  if type(lines) == "table" then pcall(vim.fn.writefile, lines, backup_path) end
end

---"File missing" (nothing saved yet — fine) and "file present but broken"
---(unreadable, undecodable, or decoded to something other than a table) are
---NOT the same situation: `save_store()` unconditionally serializes the
---WHOLE `_sessions` table back over `_store_path`, so collapsing "broken" to
---the same silent empty `_sessions` as "missing" means the very next save —
---triggered by any project, not just the one whose entry was being read —
---permanently discards every other project's saved adapter, root, scroll
---position and expanded-dir list with no trace it ever existed. A broken
---file is therefore backed up before being treated as empty, and reported,
---instead of failing quietly.
local function load_store()
  if vim.fn.filereadable(_store_path) == 0 then return end -- first run: nothing to load, not an error

  local ok, content = pcall(vim.fn.readfile, _store_path)
  if ok and content and #content > 0 then
    local json_ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
    if json_ok and type(data) == "table" then
      _sessions = data
      return
    end
  end

  backup_corrupt_store(ok and content or nil)
  notify.warn(
    "Session store is unreadable or corrupt; starting fresh (original kept at "
      .. _store_path
      .. ".corrupt)"
  )
end

local function save_store()
  ensure_dir()
  -- Prune oldest if over limit
  local keys = vim.tbl_keys(_sessions)
  if #keys > _cfg.max_sessions then
    table.sort(keys, function(a, b)
      return (_sessions[a].saved_at or 0) < (_sessions[b].saved_at or 0)
    end)
    for i = 1, #keys - _cfg.max_sessions do
      _sessions[keys[i]] = nil
    end
  end
  local ok, encoded = pcall(vim.fn.json_encode, _sessions)
  if not ok then return end
  -- Temp file and rename (lib.nvim): a crash or a full disk mid-write keeps the previous store
  -- instead of truncating every project's saved state.
  pcall(require("lib.nvim.fs.write.atomic"), _store_path, encoded .. "\n")
end

-- ── Project key ───────────────────────────────────────────────────────────────

local function project_key()
  local ok_pr, pr = require("filetree.features").load("project_root")
  local raw
  if ok_pr and pr and type(pr.find) == "function" then
    local buf = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(buf)
    raw = pr.find(name ~= "" and name or vim.fn.getcwd())
  else
    raw = vim.fn.getcwd()
  end
  -- Canonicalized (forward slashes, uppercase drive letter, realpath-
  -- resolved): `pr.find()` and `getcwd()` hand back whichever separator/case
  -- style their input happened to use, so the same project was silently
  -- keying two or more divergent entries in the store -- confirmed live via
  -- "E:/repos/lib.nvim" and "E:\repos\lib.nvim" sitting side by side in
  -- sessions.json for the one directory.
  local canon = normkey(raw)
  return canon ~= "" and canon or raw
end

-- ── Save / Restore ────────────────────────────────────────────────────────────

function M.save()
  if not _adapter then return end

  local winid = _adapter.get_winid and _adapter.get_winid() or -1

  local topline = 1
  local cursor = 1
  if winid > 0 and vim.api.nvim_win_is_valid(winid) then
    topline = vim.fn.line("w0", winid)
    cursor = vim.api.nvim_win_get_cursor(winid)[1]
  end

  -- Best-effort: ask adapter for expanded paths (optional API)
  local expanded = {}
  if _adapter.get_expanded_paths then expanded = _adapter.get_expanded_paths() or {} end

  -- `get_root_path`, not `get_root`: no adapter has ever had the shorter
  -- name, so this recorded `root = nil` for every session it saved.
  local root = _adapter.get_root_path and _adapter.get_root_path() or nil

  local key = project_key()

  -- The adapter's visual root can be caught mid-flight: cwd_sync's chdir
  -- fires DirChanged, and neo-tree's own bind_to_cwd re-roots the tree in
  -- response to it -- but debounced. BufHidden on the tree buffer (the other
  -- trigger for this save) fires synchronously and can read the OLD root
  -- before that debounce settles, persisting a stale ancestor (e.g.
  -- "E:/repos") under the new project's key ("E:/repos/ui.nvim"). Restoring
  -- that later jumps the cwd straight back out to it -- the exact bug this
  -- guards against. A root that is not the project itself or a directory
  -- inside it is never a legitimate per-project root, stale read or hand-
  -- edited store alike, so it is dropped rather than trusted.
  if root and root ~= "" then
    local nroot = normkey(root)
    if nroot == "" or not is_subpath(nroot, key) then root = nil end
  end

  _sessions[key] = {
    adapter = _adapter.name,
    root = root,
    topline = topline,
    cursor = cursor,
    expanded = expanded,
    saved_at = os.time(),
  }
  save_store()
end

function M.restore()
  if not _adapter then return end

  local key = project_key()
  local entry = _sessions[key]
  if not entry then return end

  -- Only restore if adapter matches
  if entry.adapter and entry.adapter ~= _adapter.name then return end

  _restore_gen = _restore_gen + 1
  local gen = _restore_gen
  vim.defer_fn(function()
    -- called off (`skip_restore`) or overtaken by a later restore while it waited
    if gen ~= _restore_gen or not _adapter then return end
    -- Restore tree root -- same invariant as M.save(): a root outside the
    -- project it was saved under is stale or foreign data, not something to
    -- act on. Guards entries written before this check existed, and any
    -- future write path that skips M.save() (a hand-edited store, a script).
    if type(entry.root) == "string" and entry.root ~= "" and _adapter.set_root then
      local nroot = normkey(entry.root)
      if nroot ~= "" and is_subpath(nroot, key) then pcall(_adapter.set_root, entry.root) end
    end

    -- Restore expanded dirs. A persisted snapshot is untrusted (SEC-33):
    -- `entry.expanded` is re-validated as a list of strings, capped, before
    -- reaching the adapter -- `#entry.expanded` on a hand-edited store's
    -- non-table value would otherwise throw here, uncaught (this whole
    -- callback runs outside any pcall until the cursor/topline block below).
    if type(entry.expanded) == "table" and _adapter.expand_paths then
      local expanded = {}
      for _, p in ipairs(entry.expanded) do
        if type(p) == "string" then expanded[#expanded + 1] = p end
        if #expanded >= MAX_EXPANDED_DIRS then break end
      end
      if #expanded > 0 then pcall(_adapter.expand_paths, expanded) end
    end

    -- Restore scroll / cursor. Both fields are untrusted persisted data too:
    -- `cursor` going into `nvim_win_set_cursor` via the API (not a command
    -- string) was already safe, pcall'd -- but `topline` is concatenated
    -- straight into a `:normal!` string, where a string value replays as
    -- literal keystrokes instead of moving the view, and any non-number
    -- throws mid-restore: after the window switch but before switching
    -- back, stranding the cursor in the tree window with nothing to explain
    -- why. Both are validated to a plain positive integer first.
    local winid = _adapter.get_winid and _adapter.get_winid() or -1
    if winid > 0 and vim.api.nvim_win_is_valid(winid) then
      local cursor_line = type(entry.cursor) == "number" and entry.cursor or 1
      pcall(vim.api.nvim_win_set_cursor, winid, { cursor_line, 0 })

      local topline = type(entry.topline) == "number" and math.floor(entry.topline) or 1
      if topline < 1 then topline = 1 end

      -- topline: use normal-mode command as there is no direct API
      local prev_win = vim.api.nvim_get_current_win()
      if pcall(vim.api.nvim_set_current_win, winid) then
        pcall(vim.cmd, "normal! " .. topline .. "zt")
        pcall(vim.api.nvim_set_current_win, prev_win)
      end
    end
  end, 100)
end

---Somebody else restores the tree (a named session of sessions.nvim): call off a restore of this
---feature that is still waiting, and do not run the one on the first attach of the tree. Root and open
---folders from the per-project store would otherwise land on top of what the other side just set.
---`:FiletreeSessionRestore` and `restore()` keep working: this only stops what nobody asked for.
function M.skip_restore()
  _restore_gen = _restore_gen + 1
  _auto_restored = true
end

function M.clear()
  local key = project_key()
  _sessions[key] = nil
  save_store()
  notify.info("Session cleared for: " .. key)
end

function M.clear_all()
  _sessions = {}
  save_store()
  notify.info("All sessions cleared")
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreeSessionConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter
  _store_path = vim.fn.stdpath("data") .. "/filetree/sessions.json"

  load_store()

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_session", true)

  if _cfg.auto_save then
    au.acmd("VimLeavePre", {
      group = _augroup,
      desc = "[filetree] Save the tree session before leaving Neovim",
      callback = M.save,
    })
    -- Also save when the tree buffer is hidden
    au.acmd("BufHidden", {
      group = _augroup,
      pattern = "*",
      desc = "[filetree] Save the tree session when the tree buffer is hidden",
      callback = function(ev)
        if bufutil.is_tree_buffer(ev.buf) then M.save() end
      end,
    })
  end

  if _cfg.auto_restore then
    -- Restore after the tree is opened, once per setup.
    _auto_restored = false
    tree_attach.on_attach(function()
      if _auto_restored then return end
      _auto_restored = true
      M.restore()
    end)
  end
end

function M.teardown()
  if _cfg.auto_save then pcall(M.save) end
  _adapter = nil
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
