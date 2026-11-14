---@module 'filetree.features.nav.auto_reveal'
--- Automatically reveal the current editor buffer in the tree.
---
--- Unlike cwd_sync (which changes the working directory), auto_reveal never
--- changes the cwd. On every buffer switch it:
---   1. Scrolls to the file's line if it is already rendered (cheap).
---   2. Otherwise expands collapsed parent directories to reveal it, within
---      the tree's CURRENT root (adapter.open_reveal is called with that
---      root pinned) -- so the tree's root stays where it was.
---   3. When the file lives OUTSIDE the current root: re-roots the tree to
---      wherever filetree.util.target_dir resolves for that file (the same
---      resolver cwd_sync uses, so both agree on the target), unless
---      `follow_root = false`. Skipped when cwd_sync is already doing its
---      own reveal for this switch (cwd_sync.reveal_active()) -- no cwd
---      change happens here either way, this only moves the tree's display;
---      getting Neovim's own cwd there too is still cwd_sync's job (or the
---      tree plugin's native cwd-follow, e.g. neo-tree's bind_to_cwd +
---      follow_current_file).
---
---      follow_root defaults to true so "the tree follows the current
---      buffer, however it got focused" holds out of the box; set it to
---      false in features.auto_reveal to restore the old behaviour of
---      silently doing nothing outside the current root.
---
--- Debounced to avoid spam during rapid buffer switching. Automatically
--- pauses when the cursor is inside the tree window to prevent feedback
--- loops. Can also be paused programmatically (e.g. during batch ops).
---
--- Entering the tree window (`<C-w>w`, `<C-h>`, `:wincmd h`, a mouse click)
--- syncs the tree cursor to the file you came from, before the pause is armed.
--- Without that, landing on the right node depended on whether the debounced
--- BufEnter reveal happened to have fired first: switch buffers and step into
--- the tree inside the debounce window and the reveal arrives to find the
--- cursor already in the tree, drops itself, and leaves you on whatever node
--- you last touched. Same for stepping out and back in inside the pause. The
--- reveal-on-enter does not go through the debounce and does not consult the
--- entry pause -- it *is* the entry -- so where the cursor lands no longer
--- depends on how fast the window switch was.
---
--- Config:
---   enabled        boolean
---   debounce_ms    integer   Delay after BufEnter (default 150ms).
---   ignore_ft      string[]  Filetypes to never trigger reveal (e.g. lazy, mason).
---   only_if_open   boolean   Only reveal when tree window is visible (default true).
---   sync_on_enter  boolean   Move the tree cursor onto the current file's node
---                            when the tree window is entered (default true).
---   follow_root    boolean   Re-root the tree for a file outside its current
---                            root instead of doing nothing (default true).
---
--- User commands:
---   :FiletreeAutoRevealPause [ms]   Pause for N ms (default 2000).
---   :FiletreeAutoRevealResume       Resume immediately.
---   :FiletreeRevealCurrent          Force reveal now.

local bufevents = require("filetree.util.bufevents")
local au = require("filetree.util.autocmd")
local lib_debounce = require("lib.nvim.debounce")
local lib_is_subpath = require("lib.nvim.fs.is_subpath")
local target_dir_util = require("filetree.util.target_dir")
local place_cursor = require("filetree.util.place_cursor")
local M = {}

---@type FiletreeAutoRevealConfig
local DEFAULTS = {
  enabled = false,
  debounce_ms = 150,
  ignore_ft = {
    "neo-tree",
    "NvimTree",
    "filetree",
    "netrw",
    "TelescopePrompt",
    "fzf",
    "lazy",
    "mason",
    "trouble",
    "qf",
    "help",
    "man",
    "terminal",
    "nofile",
    "prompt",
  },
  only_if_open = true,
  sync_on_enter = true,
  follow_root = true,
}

---@type FiletreeAutoRevealConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.auto_reveal` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  debounce_ms = { "number", min = 0 },
  ignore_ft = { "table", of = "string" },
  only_if_open = "boolean",
  sync_on_enter = "boolean",
  follow_root = "boolean",
}

---@type FiletreeAdapter?
local _adapter = nil

---Built in M.setup() via `filetree.util.target_dir` (default markers/policy,
---the same as cwd_sync's own default -- this is a fallback, not meant to be
---separately tuned; use cwd_sync itself for that) -- used by `reveal_to`
---when `follow_root` needs to re-root for a file outside the tree's current
---root.
---@type fun(file: string): string
local _resolve_target_dir

---Explicit pauses only -- `M.pause()`, `:Filetree reveal pause`. Kept separate
---from the entry pause below so that a caller pausing reveals for a batch
---operation still silences everything, while merely stepping into the tree does
---not disable the reveal-on-enter that stepping into the tree is supposed to do.
---@type integer  monotonic timestamp (vim.uv.hrtime) after which reveals are active
local _paused_until = 0

---Set when the tree window is entered: suppresses the *editor-driven* reveal for
---a moment, so leaving the tree does not immediately drag the tree cursor off
---the node the user just navigated to. Deliberately not consulted by the
---reveal-on-enter -- re-entering the tree within the window would otherwise skip
---the sync and land on a stale node, which is the very unreliability this
---feature exists to remove.
---@type integer  monotonic timestamp (vim.uv.hrtime) after which reveals are active
local _tree_pause_until = 0

---Last real file seen in an editor window, as the fallback for
---`current_file_path()` when the window we came from holds something else
---(a terminal, help, a picker) or is already gone.
---@type string?
local _last_editor_path = nil

---Whether the window that was left last is a floating one. Focus that comes back to the tree from a
---float (a menu, a dialog, a prompt, a viewer) is not the user stepping into the tree: the float was
---opened from the node the cursor is on, and what it does applies to that node.
---@type boolean
local _left_float = false

---@type integer?
local _augroup = nil

---Debounce handle built in M.setup() (needs `_cfg.debounce_ms`); `{ call, cancel }`.
---@type table?
local _debounce = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

---@internal
---@return boolean
local function is_paused()
  return (vim.uv or vim.loop).hrtime() < _paused_until
end

---@internal
---@return boolean
local function tree_paused()
  return (vim.uv or vim.loop).hrtime() < _tree_pause_until
end

---@internal
---@return boolean
local function tree_is_open()
  if not _adapter then return false end
  local winid = _adapter.get_winid and _adapter.get_winid() or -1
  return winid > 0 and vim.api.nvim_win_is_valid(winid)
end

---@internal
---@return boolean
local function cursor_in_tree()
  if not _adapter then return false end
  local winid = _adapter.get_winid and _adapter.get_winid() or -1
  return winid > 0 and vim.api.nvim_get_current_win() == winid
end

---@internal
---@param bufnr integer
---@return boolean
local function should_ignore(bufnr)
  local ft = vim.bo[bufnr].filetype
  local bt = vim.bo[bufnr].buftype
  if bt ~= "" and bt ~= "acwrite" then return true end
  for _, ignored in ipairs(_cfg.ignore_ft) do
    if ft == ignored then return true end
  end
  return false
end

---@internal
---Whether `path` lives under `root` (lib.nvim.fs.is_subpath, a hard dependency).
---
---The `{}` third argument makes is_subpath canonicalize both sides through
---`lib.nvim.fs.normkey` instead of `vim.fs.normalize`. Neither side is ours:
---`path` comes from a buffer name and `root` from whatever resolved the
---project, so on Windows they can differ in drive-letter case or in 8.3 short
---vs long form and a plain string compare then answers false — auto-reveal
---silently never fires.
---@param path string
---@param root string
---@return boolean
local function under_root(path, root)
  local ok, result = pcall(lib_is_subpath, path, root, {})
  if ok then return result end
  local p = path:gsub("\\", "/")
  local r = root:gsub("\\", "/"):gsub("/$", "")
  return p == r or p:sub(1, #r + 1) == r .. "/"
end

-- ── Reveal logic ──────────────────────────────────────────────────────────────

---Ask the cwd_mode feature what its active policy wants for this file.
---Mirrors cwd_sync's own `policy()` -- returns nil (no opinion, resolve
---normally) when the feature is absent, disabled, or in "follow" mode.
---@internal
---@param path string
---@return FiletreeCwdDecision?
---@see filetree.features.nav.cwd_mode
local function policy_decision(path)
  local mode = require("filetree.features").require("cwd_mode")
  if not mode or type(mode.decide) ~= "function" then return nil end
  local ok, decision = pcall(mode.decide, path)
  return ok and decision or nil
end

---`_adapter.open_reveal(path, 0, root)`, then the cursor onto the node.
---
---`open_reveal` only guarantees the node becomes *rendered*. Neo-tree reveals
---through a debounced, asynchronous rescan, and when that is driven from inside
---the tree window it leaves the cursor where it was instead of jumping to the
---revealed node -- so the tree expands correctly and the cursor sits on the root
---line. `util.place_cursor` puts the cursor there once the node turns up, and
---gives up as soon as the tree cursor leaves the line it was on when the reveal
---was issued (the tree plugin focused the node itself, or the user moved on).
---@internal
---@param path string
---@param root string
local function do_open_reveal(path, root)
  local winid = _adapter.get_winid and _adapter.get_winid() or -1
  local anchor = nil
  if winid > 0 and vim.api.nvim_win_is_valid(winid) then
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, winid)
    if ok then anchor = pos[1] end
  end
  pcall(_adapter.open_reveal, path, 0, root)
  if anchor then
    place_cursor.when_rendered(function()
      return _adapter
    end, path, { anchor = anchor })
  end
end

---Move the tree cursor onto `path`, expanding parents if it takes that. No
---guards: every caller has already decided that a reveal is wanted.
---@internal
---@param path string
local function reveal_to(path)
  if not _adapter then return end

  -- Fast path: the file is already rendered (its parent dirs are expanded) —
  -- just move the tree cursor to it (cheap; the adapter caches the path→line map).
  if type(_adapter.get_node_line) == "function" and type(_adapter.scroll_to_line) == "function" then
    local line = _adapter.get_node_line(path)
    if line then
      _adapter.scroll_to_line(line)
      return
    end
  end

  if type(_adapter.get_root_path) ~= "function" or type(_adapter.open_reveal) ~= "function" then
    return
  end
  local root = _adapter.get_root_path()
  if not (root and root ~= "") then return end

  -- Within the tree's CURRENT root: the node is not currently visible (a
  -- parent dir is collapsed) — expand to reveal it, root unchanged.
  if under_root(path, root) then
    do_open_reveal(path, root)
    return
  end

  -- Outside the current root: re-root to wherever the file actually belongs,
  -- unless told not to, or unless cwd_sync is already handling this switch
  -- with its own reveal (both resolve the identical directory via
  -- filetree.util.target_dir, so this is only ever redundant work to skip,
  -- never a conflict to avoid).
  if not _cfg.follow_root then return end
  local cwd_sync = require("filetree.features").require("cwd_sync")
  if cwd_sync and cwd_sync.reveal_active() then return end

  local decision = policy_decision(path)
  if decision and decision.reveal == false then return end

  local new_root = (decision and decision.root)
    or (_resolve_target_dir and _resolve_target_dir(path))
  if new_root and new_root ~= "" then do_open_reveal(path, new_root) end
end

---The editor-driven reveal: something entered a buffer, follow it in the tree.
---@internal
---@param path string
local function do_reveal(path)
  if not _adapter then return end
  if is_paused() or tree_paused() then return end
  if cursor_in_tree() then return end
  if _cfg.only_if_open and not tree_is_open() then return end
  reveal_to(path)
end

---@internal
---@param path string
local function schedule_reveal(path)
  if _debounce then _debounce.call(path) end
end

---The file the user was looking at before stepping into the tree. Prefers the
---window actually left behind (`winnr("#")`) over the alternate buffer or the
---last BufEnter, because with several editor windows open those disagree — and
---the one the user came from is the one they mean.
---@internal
---@return string?
local function current_file_path()
  local nr = vim.fn.winnr("#")
  if nr > 0 then
    local win = vim.fn.win_getid(nr)
    -- win_getid(0) is the *current* window, so a stale `#` must not fall through
    -- to it: that would resolve to the tree buffer and be discarded a line later
    -- anyway, but only by accident.
    if win ~= 0 and win ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if not should_ignore(buf) then
        local p = vim.api.nvim_buf_get_name(buf)
        if p ~= "" and vim.fn.filereadable(p) == 1 then return p end
      end
    end
  end
  if _last_editor_path and vim.fn.filereadable(_last_editor_path) == 1 then
    return _last_editor_path
  end
  return nil
end

---Whether the `WinEnter` being handled is the user stepping into the tree window from a window
---beside it. Two things look the same to an autocmd on the tree buffer and are not that:
---
--- - A window that was just created shows the buffer of the window it was created from until its
---   own buffer is set, and `WinEnter` fires in between. A float opened from the tree (every menu,
---   dialog and prompt) therefore "enters the tree buffer" in a window that is not the tree.
--- - Focus coming back to the tree when such a float closes.
---
---In both the cursor is on the node the float belongs to; moving it to the editor's file made a
---right click act on another node than the one clicked, and every dialog opened from the tree
---leave the cursor somewhere else.
---@internal
---@return boolean
local function stepped_into_tree()
  local win = vim.api.nvim_get_current_win()
  local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid() or nil
  if tree_win and tree_win > 0 and vim.api.nvim_win_is_valid(tree_win) then
    -- the adapter knows its window (a floating tree is one too): any other only shows the buffer
    if tree_win ~= win then return false end
  elseif vim.api.nvim_win_get_config(win).relative ~= "" then
    -- it cannot say (the tree is being opened right now): a float is taken for a window passing by
    return false
  end
  return not _left_float
end

---Put the tree cursor on the current file's node, on entering the tree window.
---Unlike `do_reveal` this runs *while* the cursor is in the tree — that is the
---point — and ignores the entry pause it is about to arm. An explicit
---`M.pause()` still silences it: a batch operation that asked for no reveals
---means no reveals.
---@internal
local function sync_on_enter()
  if not _cfg.sync_on_enter then return end
  if not _adapter or is_paused() then return end
  if not stepped_into_tree() then return end
  local path = current_file_path()
  if not path then return end
  -- A reveal queued by the BufEnter that brought us here is now redundant, and
  -- would fire from inside the tree only to drop itself.
  if _debounce then _debounce.cancel() end
  reveal_to(path)
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Pause auto-reveal for `ms` milliseconds.
---@param ms? integer  Default 2000ms.
function M.pause(ms)
  ms = ms or 2000
  _paused_until = (vim.uv or vim.loop).hrtime() + (ms * 1e6)
end

---Resume auto-reveal immediately.
function M.resume()
  _paused_until = 0
end

---Force-reveal the current buffer right now.
function M.reveal_current()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path and path ~= "" and vim.fn.filereadable(path) == 1 then do_reveal(path) end
end

---@return boolean
function M.is_paused()
  return is_paused()
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeAutoRevealConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter
  -- Built from cwd_sync's OWN configured root_markers/use_project_root
  -- (falling back to target_dir's defaults when cwd_sync's section is absent,
  -- e.g. the user never touched it) rather than target_dir_util's bare
  -- defaults -- both features must resolve the identical directory for the
  -- same file, per this module's own header comment, and cwd_sync is the one
  -- of the two with a schema exposing those knobs to the user
  -- (features.cwd_sync.root_markers / .use_project_root); reading its config
  -- here instead of hardcoding target_dir's defaults is what actually keeps
  -- that promise when the user customizes them.
  local cwd_sync_cfg = require("filetree.config").get().features.cwd_sync or {}
  _resolve_target_dir = target_dir_util.new({
    root_markers = cwd_sync_cfg.root_markers,
    use_project_root = cwd_sync_cfg.use_project_root,
  })

  if _debounce then _debounce.cancel() end
  _debounce = lib_debounce.new(do_reveal, _cfg.debounce_ms)

  bufevents.register("auto_reveal", "BufEnter:editor", {
    desc = "[filetree] Reveal the entered file in the tree",
    priority = bufevents.PRIORITY.REVEAL,
    load = function(ctx)
      if should_ignore(ctx.buf) then return end
      local path = vim.api.nvim_buf_get_name(ctx.buf)
      if path and path ~= "" and vim.fn.filereadable(path) == 1 then
        _last_editor_path = path
        schedule_reveal(path)
      end
    end,
  })

  -- Entering the tree: land on the current file's node, then hold reveals off
  -- for a moment so leaving again doesn't immediately drag the cursor away.
  bufevents.register("auto_reveal", "WinEnter:tree", {
    desc = "[filetree] Reveal the current file when the tree window is entered",
    priority = bufevents.PRIORITY.REVEAL,
    load = function()
      sync_on_enter()
      _tree_pause_until = (vim.uv or vim.loop).hrtime() + (500 * 1e6)
    end,
  })

  -- which kind of window the focus comes from, for `stepped_into_tree`
  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_auto_reveal", true)
  _left_float = false
  au.acmd("WinLeave", {
    group = _augroup,
    desc = "[filetree] Remember whether the window that is left is a floating one",
    callback = function()
      _left_float = vim.api.nvim_win_get_config(0).relative ~= ""
    end,
  })
end

function M.teardown()
  bufevents.unregister("auto_reveal")
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
  _left_float = false
  _adapter = nil
  _resolve_target_dir = nil
  _paused_until = 0
  _tree_pause_until = 0
  _last_editor_path = nil
  if _debounce then
    if _debounce then _debounce.cancel() end
    _debounce = nil
  end
end

return M
