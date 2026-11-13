---@module 'filetree.features.git.git_status'
---@brief Decorate tree nodes with git status indicators via extmarks.
---@description
--- Queries git status for the nearest project root via
--- lib.nvim.git.status_porcelain_async and maps each changed path to its
--- status code. The adapter's highlight_node() is NOT used here -- instead
--- we render directly into the tree buffer via extmarks (virtual text at
--- end-of-line) so we stay adapter-agnostic.
---
--- Indicators:
---   M  modified (working tree)   ●
---   A  added / staged             +
---   D  deleted                    -
---   R  renamed                    »
---   ?  untracked                  ?
---   !  ignored                    ·
---   C  conflict                   ✗
---
--- On the own tree (`adapter = "native"`) nothing is written into the buffer: the status is handed to
--- the tree as a decorator (`filetree.registry`), which draws it with the line and also shows on a
--- folder the worst status below it.
---
--- Updates on: BufEnter (tree buffer), BufWritePost (any buffer),
--- FocusGained, and gitsuite.nvim's `User GitsuiteBranchSwitched`/
--- `GitsuiteConflictsResolved` events (optional, no dependency either way).

local au = require("filetree.util.autocmd")
local tree_attach = require("filetree.util.tree_attach")
local lib_debounce = require("lib.nvim.debounce")
local lib_git = require("lib.nvim.git")
local M = {}

---@type FiletreeGitStatusConfig
local DEFAULTS = {
  enabled = false,
  debounce_ms = 300,
  show_ignored = false,
  signs = {
    modified = { text = "●", hl = "DiagnosticWarn" },
    added = { text = "+", hl = "DiagnosticOk" },
    deleted = { text = "-", hl = "DiagnosticError" },
    renamed = { text = "»", hl = "DiagnosticHint" },
    untracked = { text = "?", hl = "Comment" },
    ignored = { text = "·", hl = "Comment" },
    conflict = { text = "✗", hl = "DiagnosticError" },
  },
}

---@type FiletreeGitStatusConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.git_status` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  debounce_ms = { "number", min = 0 },
  show_ignored = "boolean",
  signs = {
    "table",
    of = { "table", fields = { text = "string", hl = "string" } },
  },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer  extmark namespace id
local _ns = -1

---@type table<string, string>  abs_path → status_code ("M","A","D","R","?","!","C")
local _status_map = {}

---Debounce handle built in M.setup() (needs `_cfg.debounce_ms`); `{ call, cancel }`.
---@type table?
local _debounce = nil

---Debounce handle for cursor-triggered re-renders (visual-only, no git query).
---Coalesces rapid j/k movement inside the tree buffer so each keystroke does
---not force a full clear+rebuild of every extmark in the buffer.
---@type table?
local _render_debounce = nil

---In-flight `status_porcelain_async` job, if any. Stopping it on a new
---`run_git()` call means a slow, superseded response can only ever arrive as
---a killed-process failure (map = nil, ignored below), never overwrite a
---newer, already-rendered `_status_map` with stale data.
---@type { stop: fun() }?
local _pending_query = nil

-- ── Git query ─────────────────────────────────────────────────────────────────

---One path's XY status code -> the single-letter code this module renders.
---@param xy string  two-character XY status, e.g. " M", "??", "R ", "UU"
---@return string
local function classify(xy)
  if xy:find("U") or xy == "AA" or xy == "DD" then
    return "C"
  elseif xy:sub(1, 1) == "?" then
    return "?"
  elseif xy:sub(1, 1) == "!" then
    return "!"
  elseif xy:sub(1, 1) == "R" or xy:sub(2, 2) == "R" then
    return "R"
  elseif xy:sub(1, 1) == "A" or xy:sub(2, 2) == "A" then
    return "A"
  elseif xy:sub(1, 1) == "D" or xy:sub(2, 2) == "D" then
    return "D"
  else
    return "M"
  end
end

---@param root string  git repo root directory
local function run_git(root)
  if _pending_query then _pending_query.stop() end

  _pending_query = lib_git.status_porcelain_async(
    { dir = root, ignored = _cfg.show_ignored },
    function(map)
      _pending_query = nil
      if not map then return end

      local new_map = {}
      for path, entry in pairs(map) do
        -- `map` keys are repo-root relative (lib.nvim.git's -z parser, exact
        -- for paths with spaces/non-ASCII bytes -- unlike the old `-> "` string
        -- match this replaced, a literal " -> " inside a path is never
        -- mistaken for a rename: renames arrive pre-resolved, keyed by the new
        -- path, with the old one in entry.orig_path.
        local abs = (root .. "/" .. path):gsub("\\", "/")
        new_map[abs] = classify(entry.code)
      end
      _status_map = new_map
      M._render()
    end
  )
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

local _sign_map = {
  M = "modified",
  A = "added",
  D = "deleted",
  R = "renamed",
  ["?"] = "untracked",
  ["!"] = "ignored",
  C = "conflict",
}

---The badges of the own tree's decorator: normalized path -> badge. Rebuilt from `_status_map`.
---@type table<string, { text: string, hl: string, status: string }>
local _badges = {}
---Tells the own tree that `_badges` changed; set while the decorator is subscribed.
---@type fun()|nil
local _emit = nil
---@type fun()|nil
local _unregister = nil

--- Worst first: what a folder shows when several states lie below it.
local SEVERITY = { "conflict", "deleted", "modified", "renamed", "added", "untracked", "ignored" }

local function rebuild_badges()
  local norm = require("filetree.native.fs.list").norm
  local out = {}
  for abs, code in pairs(_status_map) do
    local key = _sign_map[code]
    local sign = key and _cfg.signs[key]
    if sign then out[norm(abs)] = { text = sign.text, hl = sign.hl, status = key } end
  end
  _badges = out
  if _emit then _emit() end
end

function M._render()
  if not _adapter then return end
  if _adapter.name == "native" then
    rebuild_badges()
    return
  end
  local bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or -1
  if not bufnr or bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for linenr = 0, line_count - 1 do
    local node = _adapter.get_node_at_line and _adapter.get_node_at_line(bufnr, linenr)
    if node and node.path then
      local abs = node.path:gsub("\\", "/")
      local code = _status_map[abs]
      if code then
        local sign_key = _sign_map[code]
        local sign = sign_key and _cfg.signs[sign_key]
        if sign then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, linenr, -1, {
            virt_text = { { " " .. sign.text, sign.hl } },
            virt_text_pos = "eol",
            priority = 50,
          })
        end
      end
    end
  end
end

-- ── Refresh ───────────────────────────────────────────────────────────────────

local function debounce_refresh()
  if _debounce then _debounce.call() end
end

---Refresh git status for the current adapter root.
function M.refresh()
  if not _adapter then return end

  -- cwd_mode's held root first, then project_root, then the cwd. Resolving
  -- from the current buffer alone was actively wrong under a lock: a tree
  -- rooted at the locked project would get decorated with the git status of
  -- whatever unrelated repository the focused buffer belongs to.
  local root_path = require("filetree.util.root").find()

  -- Verify it is actually a git repo
  local git_dir = root_path .. "/.git"
  if vim.fn.isdirectory(git_dir) == 0 and vim.fn.filereadable(git_dir) == 0 then return end

  run_git(root_path)
end

---Clear all git status decorations.
function M.clear()
  if not _adapter then return end
  local bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or -1
  if bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  end
  _status_map = {}
  if _adapter.name == "native" then rebuild_badges() end
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreeGitStatusConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter
  _ns = vim.api.nvim_create_namespace("filetree_git_status")

  -- A re-setup (config reload) while a query from the PREVIOUS setup is
  -- still in flight must not let its callback render into the new
  -- _adapter/_status_map once it lands -- stop it the same way run_git()
  -- stops a superseded query of its own.
  if _pending_query then
    _pending_query.stop()
    _pending_query = nil
  end

  if _debounce then _debounce.cancel() end
  _debounce = lib_debounce.new(M.refresh, _cfg.debounce_ms)

  if _render_debounce then _render_debounce.cancel() end
  _render_debounce = lib_debounce.new(M._render, 50)

  if _unregister then _unregister() end
  _unregister = nil
  if adapter.name == "native" then
    _unregister = require("filetree.registry").decorator({
      name = "git",
      slot = "badge",
      priority = 50,
      roll_up = "worst",
      severity = SEVERITY,
      get = function(path)
        return _badges[path]
      end,
      all = function()
        return _badges
      end,
      subscribe = function(emit)
        _emit = emit
        return function()
          _emit = nil
        end
      end,
    })
  end

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_git_status", true)

  -- Re-render when entering the tree buffer, and bind a buffer-local
  -- CursorMoved so redraws-on-cursor-move only fire inside the tree buffer
  -- itself, not globally on every cursor step in every window (pattern="*"
  -- would run a callback on every single cursor move in the whole editor).
  tree_attach.on_attach(function(buf)
    debounce_refresh()
    au.acmd("CursorMoved", {
      group = _augroup,
      buffer = buf,
      callback = function()
        if _render_debounce then _render_debounce.call() end
      end,
    })
  end)

  -- Re-query on file save or focus return
  au.acmd({ "BufWritePost", "FocusGained" }, {
    group = _augroup,
    desc = "[filetree] Re-query git status after a write or on regaining focus",
    callback = function()
      debounce_refresh()
    end,
  })

  -- React to gitsuite.nvim's post-action events (GS-25): no dependency
  -- either way (D-2 in gitsuite's own design -- events, not a pcall
  -- integration), this autocmd simply never fires without gitsuite.nvim
  -- installed. A branch switch or clearing the last conflict marker in a
  -- buffer both change what `git status` reports, and waiting for the next
  -- BufWritePost/FocusGained would leave the decorations stale until then.
  au.acmd("User", {
    group = _augroup,
    pattern = { "GitsuiteBranchSwitched", "GitsuiteConflictsResolved" },
    desc = "[filetree] Re-query git status after a gitsuite.nvim branch switch or conflict resolution",
    callback = function()
      debounce_refresh()
    end,
  })

  -- The own tree reports folders whose listing changed on disk (a file created, deleted or renamed
  -- outside the editor). Changes inside `.git` are left out: `git status` itself may write the index,
  -- and answering that with another `git status` would never end.
  au.acmd("User", {
    group = _augroup,
    pattern = "FiletreeFsChanged",
    desc = "[filetree] Re-query git status after files came or went on disk",
    callback = function(ev)
      for _, dir in ipairs((ev.data and ev.data.dirs) or {}) do
        if not (dir .. "/"):find("/.git/", 1, true) then
          debounce_refresh()
          return
        end
      end
    end,
  })

  M.refresh()
end

function M.teardown()
  M.clear()
  if _unregister then _unregister() end
  _unregister = nil
  _badges = {}
  _adapter = nil
  if _pending_query then
    _pending_query.stop()
    _pending_query = nil
  end
  if _debounce then
    if _debounce then _debounce.cancel() end
    _debounce = nil
  end
  if _render_debounce then
    if _render_debounce then _render_debounce.cancel() end
    _render_debounce = nil
  end
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
