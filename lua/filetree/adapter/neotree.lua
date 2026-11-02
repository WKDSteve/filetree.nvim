---@module 'filetree.adapter.neotree'
--- Neo-tree adapter — implements the FiletreeAdapter interface for neo-tree.nvim.

local notify = require("filetree.util.notify").create("[filetree.adapter.neotree]")
local registry = require("filetree.adapter")
local au = require("filetree.util.autocmd")
local lib_debounce = require("lib.nvim.debounce")

-- Shared neo-tree node helpers live in lib.nvim (a hard dependency).
local libnode = require("lib.nvim.neotree.node")
local normkey = require("lib.nvim.fs.normkey")

---@class FiletreeNeotreeAdapter : FiletreeAdapter
---@field _retry { limit: integer, interval_ms: integer }  Background install retries (`on_render`, redraw hook). Private: tests shorten it.
local M = {
  name = "neotree",
  -- UI capabilities consumed by adapter-agnostic features.
  filetypes = { "neo-tree" },
  hl_groups = {
    NeoTreeNormal = "Normal",
    NeoTreeNormalNC = "NormalNC",
    NeoTreeEndOfBuffer = "EndOfBuffer",
  },
}

-- ── Internal helpers ──────────────────────────────────────────────────────────

---@internal
local function get_manager()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then return nil end
  return manager
end

-- Tab a tree's live window was last resolved on -- a BACKGROUND-tab fallback
-- for `get_state()`'s ambient (no-bufnr-in-hand) resolution only; see that
-- function below for the priority this is checked at and why.
--
-- Neo-tree's `manager.get_state(source_name, tabid)` defaults `tabid` to
-- `vim.api.nvim_get_current_tabpage()` when the argument is omitted -- i.e.
-- whichever tab is current AT CALL TIME, not necessarily the tab a tree
-- sidebar actually lives in. A redraw driven by neo-tree's own AFTER_RENDER
-- event or an async git-status/fs-watcher job completion can run while a
-- DIFFERENT tab happens to be current -- an adapter function that only ever
-- asked for "the current tab's state" would then silently resolve an
-- empty/wrong per-tab state and no-op instead of touching the real tree
-- buffer, so whatever the real redraw just wiped (e.g. a symlink sign) stayed
-- undrawn until the tree's own tab became current again. This cache lets an
-- ambient caller from any tab still find a tree that lives entirely in the
-- background.
--
-- NOT consulted at all by callers that already have a concrete bufnr in hand
-- (`get_node_at_line`, and anything the render-hook below hands a bufnr to) --
-- those resolve straight from that bufnr's own window via `state_for_bufnr`,
-- which needs no cache and is never ambiguous, even with two trees live on
-- two different tabs at once (this cache, being a single global slot, could
-- only ever remember one of them).
---@type integer?
local _tree_tabid = nil

---@internal
---Whether neo-tree already tracks a "filesystem" state for `tabid`, WITHOUT
---creating one -- unlike `manager.get_state`, which lazily creates and
---PERMANENTLY registers an empty placeholder state (firing `STATE_CREATED`)
---for any tabid that never had one. `manager._get_all_states()` is the one
---read-only way to answer this without a side effect; on any failure (an older
---neo-tree without it, say) this answers `true`, falling back to the old
---creating lookup rather than never finding a tree.
---
---Only a TAB state counts (`id == tabid`, as neo-tree's `create_state` sets
---it): a window-only state of a `position = "current"` tree carries the same
---`tabid` but lives in `state_by_win` under its window id, so
---`get_state("filesystem", tabid)` would still create a tab placeholder.
---@param manager table
---@param tabid integer
---@return boolean
local function has_tracked_state(manager, tabid)
  local ok, states = pcall(manager._get_all_states)
  if not ok or type(states) ~= "table" then return true end
  for _, s in ipairs(states) do
    if s.name == "filesystem" and s.tabid == tabid and (s.id == nil or s.id == tabid) then
      return true
    end
  end
  return false
end

---The "filesystem" state neo-tree tracks for `tabid`, or nil -- never created
---here. A placeholder created by filetree is not harmless:
---
--- - Created before neo-tree merged the user's config (filetree's own setup asks
---   for the tree window before the tree was ever opened), it is replaced in
---   `state_by_tab` by a fresh table at the next config merge while the old one
---   stays in `all_states`. `manager.refresh` and neo-tree's own event handlers
---   walk `all_states` only, so from then on they no longer reach the visible
---   tree: a refresh after creating a folder rendered nothing, and the cursor
---   stayed on the node it was on.
--- - Nothing ever disposes it, and a stray state in `all_states` can make
---   neo-tree's `opened_buffers_changed` handler pcall-abort its whole iteration
---   early (see `TESTS/adapter_lines.lua`'s
---   `run_neotree_opened_buffers_redraw_check`).
---@internal
---@param manager table
---@param tabid integer
---@return table? state
local function tracked_state(manager, tabid)
  if not has_tracked_state(manager, tabid) then return nil end
  local ok, state = pcall(manager.get_state, "filesystem", tabid)
  return ok and state or nil
end

---@internal
---@param manager table
---@param tabid integer
---@return table? state  Only when its window is a live, real window.
local function state_with_live_window(manager, tabid)
  local state = tracked_state(manager, tabid)
  if state and state.winid and vim.api.nvim_win_is_valid(state.winid) then return state end
  return nil
end

-- Per-bufnr memoization of `state_for_bufnr`'s own resolution, keyed on the
-- buffer's changedtick -- see that function's doc comment for what it
-- resolves. A tree buffer's own bufnr→window→tab→state chain cannot change
-- without the buffer's content also changing (a redraw, an expand/collapse,
-- ...), which already bumps the changedtick this is keyed on -- so within one
-- render pass (the same tick throughout), every per-line caller
-- (`get_node_at_line`, used once per rendered line by up to six decorating
-- features -- link_marker, git_status, lsp_diagnostics, size_info,
-- copy_move, filter) hits this cache instead of redoing the
-- `vim.fn.win_findbuf` scan plus a `manager.get_state` pcall from scratch on
-- every single line. Measured on a 1000-line tree: the win_findbuf scan
-- alone is the dominant cost of a full render pass once six features each
-- walk every line once.
---@type table<integer, {tick: integer, state: table?}>
local _state_for_bufnr_cache = {}

---@internal
---Resolve the neo-tree state whose window is showing `bufnr` right now --
---independent of which tab is current and of `_tree_tabid`'s single-slot
---cache. A caller that already knows the specific tree buffer it cares about
---should always prefer this over the ambient `get_state()` below: with two
---trees simultaneously live on two different tabs, ambient resolution can
---only guess which one a caller means (and, worse, a single-slot cache can
---only ever remember one of them, so it would keep guessing the SAME one).
---Given a concrete bufnr there is nothing to guess -- the bufnr's own window
---names its own tab, and that tab's state is unambiguously the right one.
---@param bufnr integer
---@return table? state
local function state_for_bufnr(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    _state_for_bufnr_cache[bufnr] = nil
    return nil
  end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = _state_for_bufnr_cache[bufnr]
  if cached and cached.tick == tick then return cached.state end

  local manager = get_manager()
  local resolved = nil
  if manager then
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
      if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
        local ok, tabid = pcall(vim.api.nvim_win_get_tabpage, winid)
        if ok then
          local state = state_with_live_window(manager, tabid)
          if state and state.winid == winid then
            resolved = state
            break
          end
        end
      end
    end
  end

  -- Drop entries of wiped buffers on the way (a miss is the rare path): each
  -- one pins a whole neo-tree state table that nothing else would release.
  for cached_bufnr in pairs(_state_for_bufnr_cache) do
    if not vim.api.nvim_buf_is_valid(cached_bufnr) then
      _state_for_bufnr_cache[cached_bufnr] = nil
    end
  end
  _state_for_bufnr_cache[bufnr] = { tick = tick, state = resolved }
  return resolved
end

---@internal
---Ambient resolution -- "the tree", with no bufnr or tab given to disambiguate
---by. Used by every adapter function that has nothing more specific to go on
---(get_bufnr, get_winid, get_current_node, expand/collapse_node, ...), most of
---which are reached from a keymap or command run WHILE the tree window itself
---has focus -- so simply preferring the current tab already resolves those
---correctly, including with a second, unrelated tree live on some other tab.
---@return table? state
local function get_state()
  local manager = get_manager()
  if not manager then return nil end

  -- Checked FIRST, ahead of the background-tab cache below: the tree open on
  -- the tab that is current right now. This is not just the common case --
  -- with more than one tree simultaneously live, it is the ONLY generally
  -- correct answer an ambient caller can give. Checking the cache first here
  -- (as this function once did) made it win unconditionally over a second,
  -- genuinely-current tree: whichever tab got cached first stayed "the" tree
  -- for every ambient caller everywhere, even one running from inside the
  -- second tree's own window.
  local current_tab = vim.api.nvim_get_current_tabpage()
  local current = state_with_live_window(manager, current_tab)
  if current then
    _tree_tabid = current.tabid
    return current
  end

  -- Background-tab fallback: the tab a live window was last resolved on --
  -- covers a tree that lives entirely on some OTHER tab while this call
  -- happens to run with a different (treeless) tab current. See the
  -- `_tree_tabid` comment above.
  if _tree_tabid and vim.api.nvim_tabpage_is_valid(_tree_tabid) then
    local state = state_with_live_window(manager, _tree_tabid)
    if state then return state end
  end

  -- Last resort: the tree may live on some other, background tab that was
  -- never cached (or whose cache went stale). Only worth trying with more
  -- than one tab open -- with a single tab, the current-tab call above
  -- already covered the only tab there is. Creates nothing (see
  -- `tracked_state`).
  local tabpages = vim.api.nvim_list_tabpages()
  if #tabpages > 1 then
    for _, tabid in ipairs(tabpages) do
      if tabid ~= _tree_tabid then
        local state = state_with_live_window(manager, tabid)
        if state then
          _tree_tabid = tabid
          return state
        end
      end
    end
  end

  -- Nothing live anywhere: the current tab's tracked state, window closed (it
  -- still knows e.g. the position the tree was last shown at), or nil before
  -- the tree has ever been shown.
  return tracked_state(manager, current_tab)
end

---@internal
local function get_commands()
  local ok, commands = pcall(require, "neo-tree.command")
  if not ok then return nil end
  return commands
end

---@type table<string, true>
local VALID_POSITIONS = { left = true, right = true, float = true, current = true }

---Position the tree is currently at (or was last shown at), so system-triggered
---actions (reveal, re-root) preserve it instead of snapping back to a hardcoded
---default. Neo-tree keeps one shared state per source, not per position, so this
---is the only source of truth for "where is/was the tree". Falls back to "left"
---when there is no prior state (e.g. first show of the session) or an unexpected value.
---@internal
---@return FiletreeTreePosition
local function get_current_position()
  local state = get_state()
  local pos = state and state.current_position
  if type(pos) == "string" and VALID_POSITIONS[pos] then
    -- VALID_POSITIONS narrows out "bottom" (added upstream, not supported
    -- here) at runtime; the table lookup does not narrow the type itself.
    ---@cast pos FiletreeTreePosition
    return pos
  end
  return "left"
end

---Where the tree is (or was last) shown — see `get_current_position`. Public so
---features can place new windows clear of the sidebar's side instead of relying
---on 'splitright' (util.window.open_editor_window).
---@return FiletreeTreePosition
function M.get_position()
  return get_current_position()
end

---Resolve a neo-tree node's filesystem path robustly.
---Prefers the canonical `node.path`, falls back to the node id (which for the
---filesystem source is the path). Returns nil for nodes without a real path
---(message / loading / virtual nodes), so callers can skip them.
---
---`lib.nvim`'s `get_path` is the shared helper for this, and it returns
---`path, is_dir` — computing that second value with a `vim.fn.isdirectory()`,
---i.e. a filesystem stat, which this function then throws away. Measured at
---~19us per call on Windows, against ~0us for reading `node.path` directly.
---That was invisible while this ran once per cursor move; `get_node_at_line`
---calls it once per rendered line per decorating feature, where it is ~100ms
---per render on a 1000-line tree.
---
---So the plain field goes first and the helper stays as the fallback. Nothing
---is lost by the order: `get_path`'s own path resolution is `node.path`, then
---`node:get_id()` — exactly the two steps below it.
---@internal
---@param node table?
---@return string? path
local function node_path(node)
  if not node then return nil end

  local p = node.path
  if (type(p) ~= "string" or p == "") and node.get_id then
    local ok, id = pcall(node.get_id, node)
    if ok then p = id end
  end
  if type(p) == "string" and p ~= "" then return p end

  local lp = libnode.get_path(node)
  return lp ~= "" and lp or nil
end

---Determine whether a node is a directory (uses node.type, falls back to a
---filesystem check only when the field is absent).
---
---neo-tree already resolves a symlink's real type when it can: a `"link"`
---node only keeps that type when its target could not be `uv.fs_stat`'d at
---all -- i.e. a dangling symlink, which by definition is not a directory. The
---same holds for `"unknown"` (its own `uv.fs_lstat` already failed). Both
---used to fall through to the `vim.fn.isdirectory()` stat below, which was
---always going to fail too, on a real filesystem check per rendered line for
---every dangling link in the tree. Any *other* non-nil type is equally
---conclusive -- only a genuinely absent field means neo-tree told us nothing.
---@internal
---@param node table
---@param path string
---@return boolean
local function node_is_dir(node, path)
  if node.type == "directory" then return true end
  if node.type ~= nil then return false end
  return vim.fn.isdirectory(path) == 1
end

---Convert one neo-tree (nui) node into the adapter contract's node shape.
---
---Shared by `get_current_node` and `get_node_at_line`: the two differ only in
---how they FIND the node, and a second hand-rolled copy of this mapping is how
---the two drift apart (a `depth` of 0 here and `node.level` there, say) for no
---reason the caller can see.
---
---`line_number` is the contract's 1-based line, and is the caller's to supply
---— it is the one field that does not come from the node itself.
---
---Neo-tree's `type = "message"` nodes — the `(N hidden items)` /
---`(empty folder)` lines — are not nodes in the contract's sense and come back
---nil. They carry a synthetic id (`…/.git_hidden_message`) that `node_path`
---happily reports as a path, which then makes every caller treat a notice as a
---file: a stat of something that does not exist per render, and, on
---`get_current_node`, a `d`/rename aimed at it.
---
---`is_link`/`link_to` cost nothing extra here: neo-tree's own scan
---(`file-items.lua`) already calls `uv.fs_readlink()` for every symlink it
---finds and stores the result on the item as `is_link`/`link_to`, which
---`ui/renderer.lua` then copies onto the nui node unchanged. Reading those two
---fields is a plain table access, same cost class as `node.name` above — not a
---filesystem call, so it does not reintroduce the per-node `stat` this module
---was fixed to avoid (see `node_is_dir`'s comment and
---`docs/FEATURES/BACKENDS.md`'s "Line-resolved decorations").
---
---`link_broken`: a symlink's `node.type` stays the literal `"link"` only when
---neo-tree's own `uv.fs_stat()` of the target failed (see `node_is_dir`'s
---comment above) — i.e. exactly the dangling-link case. Any other type on a
---link node means neo-tree resolved it fine.
---@internal
---@param node table?
---@param line_number integer
---@return FiletreeNode?
local function to_filetree_node(node, line_number)
  if not node or node.type == "message" then return nil end
  local path = node_path(node)
  if not path then return nil end -- other virtual nodes without a real path

  local is_dir = node_is_dir(node, path)
  local is_link = node.is_link == true
  -- true / false for a directory (open / closed), nil for a file. Spelled out:
  -- `is_dir and <maybe false> or nil` collapses a closed directory to nil.
  local expanded ---@type boolean?
  if is_dir then expanded = (node.is_expanded and node:is_expanded()) == true end
  return {
    id = (node.get_id and node:get_id()) or node.id or path,
    name = node.name or vim.fn.fnamemodify(path, ":t"),
    path = path,
    type = is_dir and "directory" or "file",
    depth = (node.get_depth and node:get_depth()) or 0,
    line_number = line_number,
    is_expanded = expanded,
    is_link = is_link or nil,
    link_to = (is_link and type(node.link_to) == "string" and node.link_to) or nil,
    link_broken = (is_link and node.type == "link") or nil,
  }
end

-- ── Interface ─────────────────────────────────────────────────────────────────

---@return boolean
function M.is_available()
  local ok = pcall(require, "neo-tree")
  return ok
end

---@return boolean, integer? bufnr
function M.is_open()
  local state = get_state()
  if not state then return false, nil end
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local bufnr = vim.api.nvim_win_get_buf(state.winid)
    if vim.api.nvim_buf_is_valid(bufnr) then return true, bufnr end
  end
  return false, nil
end

---@return integer? bufnr
function M.get_bufnr()
  local _, bufnr = M.is_open()
  return bufnr
end

---The neo-tree "filesystem" state of one tree, for a feature that has to drive
---neo-tree's own API on it (the filter sets `search_pattern` on it). With
---`bufnr`, the state whose window shows that buffer (nil when none does);
---without, the same ambient resolution every other adapter function uses: the
---live tree on the current tab, else one live on a background tab, else the
---current tab's tracked state. Never creates a state -- unlike neo-tree's own
---`manager.get_state`, which registers an empty placeholder for a treeless tab.
---@param bufnr integer?
---@return table? state
function M.get_state(bufnr)
  if bufnr then return state_for_bufnr(bufnr) end
  return get_state()
end

---@return integer? winid
function M.get_winid()
  local state = get_state()
  if not state then return nil end
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then return state.winid end
  return nil
end

---@return string? root_path
function M.get_root_path()
  local state = get_state()
  return state and state.path or nil
end

---@return FiletreeNode?
function M.get_current_node()
  local state = get_state()
  if not state or not state.tree then return nil end
  local ok, node = pcall(function()
    return state.tree:get_node()
  end)
  if not ok then return nil end
  return to_filetree_node(node, vim.fn.line("."))
end

---Node rendered on one line of the tree buffer.
---
---`linenr` is **0-based** — the contract states it, and it is what every
---caller has: all five (git_status, lsp_diagnostics, size_info, copy_move's
---clipboard marker, filter's dim fallback) walk `0 .. line_count - 1` to place
---extmarks, which are 0-based too. Neo-tree renders through a nui tree, whose
---line numbers are 1-based buffer lines, hence the `+ 1` here and nowhere else.
---
---The lookup is nui's own line→node mapping rather than a reconstruction from
---`get_visible_nodes`: nui knows which lines it actually drew, so a line it
---drew for something that is not a node resolves to nil instead of silently
---shifting every node below it by one. It also memoizes that mapping after the
---second lookup, which is what keeps the callers' per-line loop linear rather
---than quadratic. Neo-tree's root IS a node and resolves like any other; its
---`(N hidden items)`/`(empty folder)` notices are the lines that come back
---nil.
---
---Resolved via `state_for_bufnr(bufnr)`, NOT the ambient `get_state()`: this
---function is always called with a specific bufnr already in hand (a caller's
---own `get_bufnr()`, or -- for link_marker/git_status/size_info's redraws --
---one tied to one particular render pass), and with two trees simultaneously
---live on two different tabs, ambient resolution has no way to know which of
---them `bufnr` even refers to. Resolving from the bufnr's own window sidesteps
---the question entirely — see that function's doc comment. A stale bufnr (its
---tree closed and reopened between render and callback) resolves to no window
---at all and correctly returns nil here, same as the old direct `state.winid`
---check this replaced.
---@param bufnr integer
---@param linenr integer  0-based buffer line
---@return FiletreeNode?
function M.get_node_at_line(bufnr, linenr)
  local state = state_for_bufnr(bufnr)
  if not state or not state.tree then return nil end

  local ok, node = pcall(function()
    return state.tree:get_node(linenr + 1)
  end)
  if not ok then return nil end
  return to_filetree_node(node, linenr + 1)
end

---Extract filesystem paths (and display names) from a list of neo-tree nodes.
---Nodes without a real path are skipped. Useful for batch operations over
---marked nodes.
---@param nodes table[]
---@return string[] paths, string[] names
function M.extract_paths(nodes)
  return libnode.extract_paths(nodes)
end

-- Safety cap: the walk already only descends into *expanded* nodes (so it is
-- bounded by the rendered line count, not the filesystem), but a single directory
-- expanded with tens of thousands of entries could still be pathological. Stop
-- collecting past this many nodes — far more than any picker/marks use needs.
---@return integer
local function max_visible()
  local ok, ft = pcall(require, "filetree.config")
  if not ok or not ft.get then return 5000 end
  local n = ft.get().max_visible_nodes
  return (type(n) == "number" and n > 0) and n or 5000
end

---`bufnr`, when given, resolves the SAME tree a specific render pass belongs
---to (via `state_for_bufnr`) instead of the ambient "current tab" tree --
---needed by marks' on_render-driven redraw, for the identical two-simultaneous
----trees reason `get_node_at_line`'s doc comment explains. Omitted (the
---common case — a keymap/command run with the tree itself focused), this
---falls back to the ambient `get_state()`, which is already correct there.
---@param filter? FiletreeFilterMode
---@param bufnr? integer
---@return FiletreeNode[]
function M.get_visible_nodes(filter, bufnr)
  -- Deliberately NOT `bufnr and state_for_bufnr(bufnr) or get_state()`: with
  -- a real bufnr given, a resolution failure (state_for_bufnr returning nil
  -- -- a normal, reachable outcome, e.g. the tree's window closed between the
  -- render and this call) must return {} here, not silently fall through to
  -- the ambient get_state() and substitute a possibly unrelated tree. That
  -- `and/or` idiom cannot tell "bufnr given but unresolved" apart from
  -- "bufnr omitted" -- both evaluate the right-hand side. get_node_at_line
  -- (same bufnr contract) already gets this right; this matches it.
  local state
  if bufnr then
    state = state_for_bufnr(bufnr)
  else
    state = get_state()
  end
  if not state or not state.tree then return {} end

  local nodes = {}
  local line_nr = 1
  local capped = false
  local cap = max_visible()

  ---@internal
  local function collect(node)
    if not node or #nodes >= cap then
      capped = capped or #nodes >= cap
      return
    end
    local depth = (node.get_depth and node:get_depth()) or 0
    if depth > 0 then
      local ntype = node.type == "directory" and "directory" or "file"
      local include = filter == nil
        or filter == "all"
        or (filter == "files" and ntype == "file")
        or (filter == "folders" and ntype == "directory")

      if include then
        local id = (node.get_id and node:get_id()) or node.id or ""
        local node_expanded ---@type boolean?
        if ntype == "directory" then
          node_expanded = (node.is_expanded and node:is_expanded()) == true
        end
        nodes[#nodes + 1] = {
          id = id,
          name = node.name or "",
          path = id,
          type = ntype,
          depth = depth,
          line_number = line_nr,
          is_expanded = node_expanded,
        }
      end
      line_nr = line_nr + 1
    end

    local expanded = node.is_expanded and node:is_expanded()
    local has_children = node.has_children and node:has_children()
    if expanded and has_children then
      local child_ids = (node.get_child_ids and node:get_child_ids()) or {}
      for _, cid in ipairs(child_ids) do
        local child = state.tree.get_node and state.tree:get_node(cid)
        if child then collect(child) end
      end
    end
  end

  local roots = state.tree.get_nodes and state.tree:get_nodes()
  if roots then
    for _, root in ipairs(roots) do
      collect(root)
    end
  end
  if capped then notify.debug("get_visible_nodes: capped at " .. cap .. " nodes") end
  return nodes
end

-- Cache the path→line map so repeated lookups (e.g. current_hl highlights the
-- current file AND its parent per event, and cwd_sync/auto_reveal reveal on
-- every buffer switch) don't each rebuild the full visible-node list. Keyed on
-- the tree buffer's changedtick: neo-tree bumps it whenever the rendered tree
-- changes (expand/collapse/refresh), which is exactly when the line map goes
-- stale — so a cursor move or file open that leaves the tree untouched is a hit.
---Normalize a path to forward slashes for use as a line-map key. Neo-tree's own
---node.path is native-separator (backslash on Windows), while callers querying
---the map (cwd_sync/auto_reveal/current_hl) source their path from
---`vim.api.nvim_buf_get_name()` / `vim.fn.expand("%:p")`, which return
---forward-slash paths on this platform's Neovim build. Without normalizing both
---sides to the same form, every lookup silently misses on Windows — the map
---builds fine but `get_node_line()` never finds an entry, forcing the
---(otherwise avoidable) slow reveal path on every call.
---@internal
---@param p string
---@return string
local function key_of(p)
  return (p:gsub("\\", "/"))
end

---@type table<string, integer>?
local _line_map = nil
local _line_map_buf = -1
local _line_map_tick = -1

---Build (or reuse) the path→line map for the currently rendered tree.
---@internal
---@return table<string, integer>?
local function line_map()
  local _, bufnr = M.is_open()
  if not bufnr then
    _line_map, _line_map_buf, _line_map_tick = nil, -1, -1
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if _line_map and _line_map_buf == bufnr and _line_map_tick == tick then return _line_map end

  local map = {}
  for _, node in ipairs(M.get_visible_nodes()) do
    -- First occurrence wins (a path is rendered once); keep the earliest line.
    if node.path then
      local key = key_of(node.path)
      if map[key] == nil then map[key] = node.line_number end
    end
  end
  _line_map, _line_map_buf, _line_map_tick = map, bufnr, tick
  return map
end

---@param path string
---@return integer? line_number
function M.get_node_line(path)
  local map = line_map()
  return map and map[key_of(path)] or nil
end

---@internal
---Narrow, no-rescan redraw of `state`'s tree — the single place
---`expand_node`/`collapse_node`/`M.redraw()` reach `renderer.redraw` through,
---so the require/field-check dance lives once instead of three times.
---@param state neotree.State
---@return boolean
local function do_narrow_redraw(state)
  local ok_r, renderer = pcall(require, "neo-tree.ui.renderer")
  if not ok_r or type(renderer.redraw) ~= "function" then return false end
  return (pcall(renderer.redraw, state))
end

---@param node FiletreeNode
---@return boolean
function M.expand_node(node)
  local state = get_state()
  if not state or not state.tree then return false end
  local ok2, tree_node = pcall(function()
    return state.tree:get_node(node.id)
  end)
  if not ok2 or not tree_node then return false end
  if tree_node.is_expanded and not tree_node:is_expanded() and tree_node.expand then
    tree_node:expand()
    do_narrow_redraw(state)
  end
  return true
end

---@internal
---Nearest ancestor of `tree_node` that is itself collapsible (has children),
---stopping before the tree root -- collapsing the root would hide the whole
---tree, not just back out one level.
---@param state neotree.State
---@param tree_node table
---@return table? parent
local function collapsible_parent(state, tree_node)
  local ok_id, parent_id = pcall(function()
    return tree_node.get_parent_id and tree_node:get_parent_id()
  end)
  if not ok_id or not parent_id then return nil end

  local ok_parent, parent = pcall(function()
    return state.tree:get_node(parent_id)
  end)
  if not ok_parent or not parent then return nil end

  local ok_root, root = pcall(function()
    return state.tree:get_nodes()[1]
  end)
  local is_root = ok_root and root and parent.get_id and parent:get_id() == root:get_id()
  if is_root then return nil end

  if parent.has_children and parent:has_children() then return parent end
  return nil
end

---Whether `node` is currently displayed as a `group_empty_dirs` merged line
---(neo-tree's single-line display for a chain of directories holding nothing
---but another single directory, e.g. "personal/All/Finish") rather than an
---ordinary directory.
---
---The node's own display name IS the tell: `to_filetree_node` copies it
---verbatim from neo-tree's own `node.name` (see this file's `name = node.name`),
---and a merged node's name is literally the chain's separator-joined path
---segments, never a bare basename the way an ordinary directory's is --
---confirmed against a real neo-tree. `is_expanded()`/`has_children()` cannot
---make this call: a merged node mid-chain (not yet drilled into further)
---reports `false`/`false`, identically to an ordinary directory that was
---simply never opened, and a merged node drilled all the way to a real file
---reports `true`/`true`, identically to a genuinely expanded ordinary
---directory -- the name is the only signal an ordinary directory never has.
---@param node FiletreeNode
---@return boolean
local function is_group_empty_dirs_merge(node)
  return node.type == "directory"
    and type(node.name) == "string"
    and (node.name:find("/", 1, true) or node.name:find("\\", 1, true)) ~= nil
end

---Collapse `node`, falling back to its nearest collapsible ancestor when the
---node itself isn't expanded.
---
---A `group_empty_dirs` merged node (see `is_group_empty_dirs_merge`) always
---goes straight to `M.refresh()` regardless of its own `is_expanded()` state,
---checked FIRST, before any of the structural collapse logic below: neo-tree
---rebuilds that node from scratch on every lazy-loaded level (see
---`ui/renderer.lua:show_nodes`, the `state.group_empty_dirs` branch), spliced
---in via `tree:set_nodes()` directly rather than the usual `node:expand()`
---call -- so collapsing the node itself (or its structural parent) only ever
---hides whatever it most recently drilled into, leaving the display still
---merged on the very same line, not genuinely back to e.g. "personal". Each
---merge step also re-parents the replacement onto the *grandparent* of the
---directory it just absorbed (see `show_nodes`: `parentId =
---parent:get_parent_id()`), not onto anything still visible in between -- so
---a chain merged all the way from a top-level directory ends up parented
---directly on the tree root, where there is no structural ancestor left to
---collapse to at all. `M.refresh()` sidesteps both problems at once: it
---re-scans from disk and rebuilds the top level fresh, unmerged and collapsed
---because the merged node was never actually marked expanded to begin with.
---
---For an ordinary directory, the fallback mirrors neo-tree's own `close_node`
---command (bound to `C` by default): collapse the node itself if it is
---expanded-with-children, else its nearest collapsible ancestor stopping
---before the tree root -- collapsing root would hide the whole tree, and (for
---an ordinary directory, unlike a merged one) there is nothing there to fix
---with a refresh either, so this is a no-op instead.
---
---Kept synchronous and immediate on purpose (`do_narrow_redraw` runs right
---here, not through `M.redraw_soon()`): `renderer.focus_node` below needs the
---tree's just-rendered line state, so deferring the redraw would risk the
---cursor landing on a stale line -- worse than the flicker this trades
---against. Known limitation: neo-tree's own native "modified"/"opened"
---markers (`enable_modified_markers`/`enable_opened_markers`) are recomputed
---and drawn by neo-tree itself on ITS OWN redraw schedule (its
---`opened_buffers_changed` debounce, watcher-driven redraws, ...), entirely
---outside this plugin, so a residual blink sourced purely from neo-tree's own
---internal timing can never be eliminated from here. `M.redraw_soon()` exists
---for a filetree-own redraw trigger that is NOT already debounced against
---anything else and could otherwise stack with this one; `opened_sync`, the
---original motivating caller, turned out not to need it -- its own debounce
---already reduces a burst to one call, so a second debounce layer on top only
---added latency (see `opened_sync`'s doc comment).
---@param node FiletreeNode
---@return boolean
function M.collapse_node(node)
  local state = get_state()
  if not state or not state.tree then return false end
  local ok2, tree_node = pcall(function()
    return state.tree:get_node(node.id)
  end)
  if not ok2 or not tree_node then return false end

  if is_group_empty_dirs_merge(node) then
    -- Collapse the node itself FIRST when it is currently expanded (the
    -- "drilled all the way to a real file" state, e.g. Finish showing
    -- leaf.txt): neo-tree's own refresh preserves expand state across a
    -- rescan by re-walking `renderer.get_expanded_nodes(state.tree, ...)`
    -- and re-loading exactly those same ids (see fs_scan.lua's
    -- `handle_refresh_or_up`) -- so calling M.refresh() while this node's
    -- `is_expanded()` still reads true just rebuilds it right back into the
    -- same drilled-open state, a no-op in practice even though a real
    -- filesystem rescan happened. Collapsing first clears that flag so the
    -- rescan actually lands on a clean, collapsed "personal".
    if tree_node.is_expanded and tree_node:is_expanded() and tree_node.collapse then
      pcall(function()
        tree_node:collapse()
      end)
    end
    return M.refresh()
  end

  local target
  if
    tree_node.is_expanded
    and tree_node:is_expanded()
    and tree_node.has_children
    and tree_node:has_children()
  then
    target = tree_node
  else
    target = collapsible_parent(state, tree_node)
  end

  if target and target.collapse then
    target:collapse()
    do_narrow_redraw(state)
    local ok3, renderer = pcall(require, "neo-tree.ui.renderer")
    if ok3 and renderer and renderer.focus_node and target.get_id then
      pcall(renderer.focus_node, state, target:get_id())
    end
    return true
  end

  return false
end

---@internal
---Comparable form of a tree path: neo-tree's ids are native-separator paths,
---a buffer name may differ in separators and drive-letter case. Lower-cased on
---Windows, whose paths are case-insensitive. A pure string operation -- no
---symlink is resolved, so the chain THROUGH a linked folder stays intact (the
---folder above a link keeps its own path, the file below it too), and no
---filesystem call is made per node. `real` resolves instead (`uv.fs_realpath`):
---only used when the plain form of the kept path does not even lie under the
---root's plain form, i.e. when the two are spelled differently (an 8.3 short
---name such as `STEFAN~1` against the long one).
---@param p string
---@param real? boolean
---@return string
local function chain_key(p, real)
  local k = normkey(p, { realpath = real == true })
  if vim.fn.has("win32") == 1 then k = k:lower() end
  return (k:gsub("/+$", ""))
end

---@internal
---Whether `key` is `dir_key` or lies below it (both from `chain_key`).
---@param key string
---@param dir_key string
---@return boolean
local function key_under(key, dir_key)
  return key == dir_key or key:sub(1, #dir_key + 1) == dir_key .. "/"
end

---@internal
---The tab's own "filesystem" state: its live tree, else the one it tracks
---with the window closed. Deliberately NOT `get_state()`, whose fallbacks hand
---out another tab's live tree when this tab has none open -- right for a
---decoration that wants "the" tree, wrong for an action on this tab's tree
---(`collapse_on_toggle` would collapse the tree on the other tab, then open
---this tab's untouched).
---@return table? state
local function current_tab_state()
  local manager = get_manager()
  if not manager then return nil end
  local tab = vim.api.nvim_get_current_tabpage()
  return state_with_live_window(manager, tab) or tracked_state(manager, tab)
end

---@internal
---Sort criteria neo-tree's `state.sort` knows, by the neutral names the adapter interface uses.
local SORT_LABELS = { name = "Name", size = "Size", mtime = "Last Modified" }

---@internal
---@param kind string
---@return fun(node: table): any
local function sort_field(kind)
  local utils = require("neo-tree.utils")
  if kind == "size" then
    return function(node)
      return utils.get_stat(node).size or 0
    end
  elseif kind == "mtime" then
    return function(node)
      local stat = utils.get_stat(node)
      return stat.mtime and stat.mtime.sec or 0
    end
  end
  return function(node)
    return node.path:lower()
  end
end

---Sort this tab's tree by `kind` (`"name"|"size"|"mtime"`), ascending or `descending`.
---Drives neo-tree's own `state.sort` / `sort_field_provider` (what its `order_by_*`
---commands set) and refreshes, then puts the cursor back on the entry it was on.
---@param kind "name"|"size"|"mtime"
---@param descending? boolean
---@return boolean ok
---@return string? reason
function M.set_sort(kind, descending)
  local label = SORT_LABELS[kind]
  if not label then return false, "unknown sort criterion: " .. tostring(kind) end
  local state = current_tab_state()
  local manager = get_manager()
  if not state or not manager then return false, "the tree has not been shown yet" end
  local ok_u = pcall(require, "neo-tree.utils")
  if not ok_u then return false, "neo-tree utils unavailable" end

  local node = M.get_current_node()
  local keep = node and node.path or nil

  state.sort = { label = label, direction = descending and -1 or 1 }
  state.sort_field_provider = sort_field(kind)
  if not pcall(manager.refresh, state.name or "filesystem") then return false, "refresh failed" end

  if keep then
    -- The refresh is asynchronous: the entry has a line again once the tree re-rendered.
    -- One shot: the first render, or nothing after 3 s (a refresh that never renders must not
    -- leave a hook behind that later drags the cursor back to a stale entry).
    local unsubscribe
    local armed = true
    local function disarm()
      armed = false
      if unsubscribe then unsubscribe() end
    end
    unsubscribe = M.on_render(function()
      if not armed then return end
      disarm()
      local line = M.get_node_line(keep)
      if line then M.scroll_to_line(line) end
    end)
    vim.defer_fn(disarm, 3000)
  end
  return true, nil
end

---The sort criterion in force on this tab's tree (neo-tree's default is name, ascending).
---@return { kind: "name"|"size"|"mtime", descending: boolean }?
function M.get_sort()
  local state = current_tab_state()
  if not state then return nil end
  local sort = state.sort
  local kind = "name"
  for k, label in pairs(SORT_LABELS) do
    if sort and sort.label == label then kind = k end
  end
  return { kind = kind, descending = sort ~= nil and sort.direction == -1 }
end

---@internal
---The top-level entry (direct child of the root) the node `id` lives under,
---or nil for the root itself / an unknown id.
---@param state neotree.State
---@param id string
---@param root_id string
---@return string?
local function top_level_of(state, id, root_id)
  local current = id
  for _ = 1, 256 do
    local ok, node = pcall(function()
      return state.tree:get_node(current)
    end)
    if not ok or not node then return nil end
    local parent_id = node.get_parent_id and node:get_parent_id() or nil
    if not parent_id then return nil end
    if parent_id == root_id then return current end
    current = parent_id
  end
  return nil
end

---Collapse every expanded folder of the tree in one pass and one redraw --
---neo-tree's own `close_all_nodes` (`z`), plus `keep_path`: the folders on the
---way from the root to that path stay open (the current file's chain, for
---`tree_toggle.collapse_on_toggle`). A path outside the root keeps nothing.
---
---Acts on THIS tab's tree (`current_tab_state`), also while its window is
---closed (the state survives a close; the next show renders what is left
---open), and then skips the redraw. With a live window and no `keep_path`,
---the cursor lands on the top-level entry it was under (or the root).
---
---Folders opened through neo-tree's `follow_current_file` are remembered in
---`state.explicitly_opened_nodes` and re-opened on the next reveal; that set is
---reset to the kept chain, exactly as `close_all_nodes` empties it.
---
---A collapsed `group_empty_dirs` line ("personal/All/Finish", see
---`is_group_empty_dirs_merge`) would keep showing the merged chain after a
---plain `collapse()`; as in `collapse_node`, a live tree is then refreshed,
---which rebuilds the top level unmerged.
---@param keep_path? string  Absolute path whose ancestor folders stay open.
---@return boolean ok
---@return string? reason
function M.collapse_all(keep_path)
  local state = current_tab_state()
  if not state or not state.tree then return false, "the tree has not been shown yet" end
  local ok_r, renderer = pcall(require, "neo-tree.ui.renderer")
  if not ok_r or type(renderer.get_expanded_nodes) ~= "function" then
    return false, "neo-tree renderer unavailable"
  end
  local ok_root, root = pcall(function()
    return state.tree:get_nodes()[1]
  end)
  local root_id = ok_root and root and root.get_id and root:get_id() or nil

  local live = state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
  local focus_id = nil
  if live and root_id and not keep_path then
    local ok_cur, cur = pcall(function()
      return state.tree:get_node()
    end)
    if ok_cur and cur and cur.get_id then
      focus_id = top_level_of(state, cur:get_id(), root_id) or root_id
    end
  end

  local keep, real = nil, false
  if type(keep_path) == "string" and keep_path ~= "" then
    keep = chain_key(keep_path)
    if root_id and not key_under(keep, chain_key(root_id)) then
      real = true
      keep = chain_key(keep_path, true)
    end
  end
  local ok_ids, expanded = pcall(renderer.get_expanded_nodes, state.tree)
  if not ok_ids or type(expanded) ~= "table" then return false, "no expanded nodes to read" end

  local opened, merged = {}, false
  for _, id in ipairs(expanded) do
    if id ~= root_id then
      if keep ~= nil and key_under(keep, chain_key(id, real)) then
        opened[id] = true
      else
        local node = state.tree:get_node(id)
        if node and node.collapse then
          pcall(node.collapse, node)
          merged = merged or is_group_empty_dirs_merge(node)
        end
      end
    end
  end
  state.explicitly_opened_nodes = opened

  if live then
    if merged then
      -- As in collapse_node: straight to the rescan, no redraw of the
      -- still-merged state in between.
      M.refresh()
    else
      do_narrow_redraw(state)
    end
    if focus_id and type(renderer.focus_node) == "function" then
      pcall(renderer.focus_node, state, focus_id)
    end
  end
  return true, nil
end

---@param path string
---@param mode? FiletreeOpenMode
---@return boolean
function M.open_file(path, mode)
  mode = mode or "edit"
  local cmd_map = {
    edit = "edit",
    split = "split",
    vsplit = "vsplit",
    tab = "tabnew",
    preview = "split",
  }
  local cmd = cmd_map[mode]
  if not cmd then return false end
  local ok = pcall(function()
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(path))
  end)
  return ok
end

---@param path string
---@return boolean
function M.set_root(path)
  local commands = get_commands()
  if not commands then return false end
  local ok = pcall(commands.execute, {
    action = "show",
    source = "filesystem",
    position = get_current_position(),
    dir = path,
  })
  return ok
end

---@param path string
---@param parent_levels? integer
---@param root_dir? string
---@return boolean
function M.open_reveal(path, parent_levels, root_dir)
  local commands = get_commands()
  if not commands then return false end
  -- Explicit root_dir (e.g. the project root resolved by cwd_sync) wins: the tree
  -- is rooted there. Otherwise derive the root from the file by ascending
  -- `parent_levels` (legacy behaviour).
  local target = root_dir
  if not target or target == "" then
    target = path
    for _ = 1, (parent_levels or 0) do -- fixed: was 0,n (ran n+1 times); now 1,n (runs n times)
      target = vim.fn.fnamemodify(target, ":h")
    end
  end
  -- `dir` is the tree root neo-tree navigates/tcd's to, so it MUST be a
  -- directory. With parent_levels = 0 (the default) and no root_dir, `target` is
  -- still the file itself — passing that made neo-tree run `tcd <file>` →
  -- E344/ENOTDIR. Ascend to the containing directory whenever target is not one.
  if vim.fn.isdirectory(target) ~= 1 then target = vim.fn.fnamemodify(target, ":h") end
  local ok = pcall(commands.execute, {
    action = "show",
    source = "filesystem",
    position = get_current_position(),
    dir = target,
    reveal_file = path,
  })
  return ok
end

---@return boolean
function M.open_cwd()
  local commands = get_commands()
  if not commands then return false end
  local ok = pcall(commands.execute, {
    action = "show",
    source = "filesystem",
    position = get_current_position(),
  })
  return ok
end

---Toggle the tree at a given position, optionally revealing a file / setting root.
---
---Self-heals one neo-tree race. Toggling again before the (debounced)
---`filesystem_navigate` scan of a previous toggle has settled -- a keypress
---that lands right after startup is the easiest way -- makes
---`nvim_buf_set_name` collide inside `renderer.acquire_window()` (E95: a
---buffer with this name already exists). Left alone, that leaves a blank,
---unfocusable "neo-tree" window that re-errors on every redraw; the manual
---remedy was to press the key again, which opened a second, working window
---next to the dead one. So on failure any window still showing an unnamed
---(never rendered) neo-tree buffer is closed and the toggle is retried once.
---@param position FiletreeTreePosition
---@param opts? FiletreeToggleOpts
---@return boolean
function M.toggle_at(position, opts)
  opts = opts or {}
  local commands = get_commands()
  if not commands then return false end
  local exec_opts = {
    action = "focus",
    source = "filesystem",
    position = position,
    toggle = true,
    reveal = opts.reveal == true,
    reveal_file = opts.reveal and opts.file or nil,
    reveal_force_cwd = opts.reveal == true and opts.reveal_force_cwd == true,
    dir = opts.dir,
  }
  if pcall(commands.execute, exec_opts) then return true end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" and vim.api.nvim_buf_get_name(buf) == "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  local ok, err = pcall(commands.execute, exec_opts)
  if not ok then notify.warn("toggle failed: " .. tostring(err)) end
  return ok
end

---@return boolean
function M.close()
  local commands = get_commands()
  if not commands then return false end
  local ok = pcall(commands.execute, { action = "close", source = "filesystem" })
  return ok
end

---How long after a refresh further refresh requests are folded into one (see `M.refresh`).
local REFRESH_WINDOW_MS = 60
---@type uv.uv_timer_t|nil
local refresh_window = nil
local refresh_pending = false

---Re-scan the filesystem and re-render the tree — the same thing neo-tree's own
---`R` mapping does.
---
---Deliberately routed through `sources.manager.refresh` rather than
---`neo-tree.command.execute`: `execute` only ever understands the "show",
---"focus" and "close" actions, so an `action = "refresh"` fell straight through
---`do_show_or_focus` without matching either branch and did nothing at all —
---while still reporting success, since nothing threw. A newly created directory
---then only appeared when some *unrelated* event happened to re-navigate the
---tree (opening a file right after a create, follow_current_file firing, ...),
---which is why a manual `R` was needed roughly half the time.
---
---**Bursts are coalesced.** One user action can ask for several refreshes in a row (a batch rename, a move, the
---file watcher on top of a fileop): each one is a full re-scan (~12 ms, 1 967 of them in 52 sessions in the
---telemetry). The first call of a burst runs at once; calls inside `REFRESH_WINDOW_MS` of it are folded into ONE
---trailing refresh that runs when the window ends (they answer `true`: the refresh is on its way).
---@return boolean
function M.refresh()
  if refresh_window then
    refresh_pending = true
    return true
  end
  local manager = get_manager()
  if not manager or type(manager.refresh) ~= "function" then return false end
  refresh_window = vim.uv.new_timer()
  refresh_window:start(
    REFRESH_WINDOW_MS,
    0,
    vim.schedule_wrap(function()
      local timer = refresh_window
      refresh_window = nil
      if timer and not timer:is_closing() then timer:close() end
      if refresh_pending then
        refresh_pending = false
        M.refresh()
      end
    end)
  )
  return (pcall(manager.refresh, "filesystem"))
end

---Re-render the CURRENT tree from its existing state, without rescanning the
---filesystem (unlike refresh). Cheap enough to run on buffer open/close so
---neo-tree's `highlight_opened_files` decoration re-evaluates and stays in sync
---with which files are actually open. Returns false when the tree isn't open.
---@return boolean
function M.redraw()
  local state = get_state()
  if not state or not state.tree then return false end
  return do_narrow_redraw(state)
end

---@type table?  Built lazily on first use — see M.redraw_soon.
local _redraw_soon = nil
---Milliseconds within which repeated `M.redraw_soon()` calls collapse into
---one `M.redraw()` — small and fixed: just enough to absorb a same-moment
---burst of MULTIPLE, otherwise-independent filetree-own redraw requests
---without adding perceptible latency to any single one of them.
local REDRAW_COALESCE_MS = 30

---Coalescing counterpart to `M.redraw()`: multiple calls within
---`REDRAW_COALESCE_MS` collapse into a single `renderer.redraw(state)` pass,
---for a caller whose own trigger isn't already synchronously tied to a
---structural tree mutation AND isn't already debounced against itself
---(unlike `collapse_node`/`expand_node`, which stay on their own immediate,
---uncoalesced `do_narrow_redraw` — see those functions' doc comments for why
---deferring THEIR redraw is not safe; and unlike `opened_sync`, which tried
---this and reverted it — see its doc comment — because its OWN debounce
---already reduces a burst to one call, leaving nothing here to coalesce
---with). No production call site uses this today; kept as a primitive for a
---future caller whose trigger genuinely fires more than once per structural
---change with no debounce of its own.
---
---This only coordinates FILETREE's own call sites against each other. It
---cannot and does not coalesce with neo-tree's OWN internal `renderer.redraw`
---callers (`opened_buffers_changed`'s own debounce, filesystem-watcher-driven
---redraws, ...) — those live entirely in the external neo-tree.nvim
---dependency, out of this plugin's reach. See `docs/FEATURES/BACKENDS.md`'s
---render-event-bridge section.
---@return boolean
function M.redraw_soon()
  if not _redraw_soon then
    _redraw_soon = lib_debounce.new(function()
      M.redraw()
    end, REDRAW_COALESCE_MS)
  end
  _redraw_soon.call()
  return true
end

---@param line integer
---@return boolean
function M.scroll_to_line(line)
  local winid = M.get_winid()
  if not winid then return false end
  local l = math.max(1, math.floor(line))
  local ok = pcall(vim.api.nvim_win_set_cursor, winid, { l, 0 })
  return ok
end

-- Highlights are applied as extmarks on the tree buffer.
---@type table<string, integer>   path → extmark id
local _hl_marks = {}
local _ns = nil

---@internal
local function ns()
  if not _ns then _ns = vim.api.nvim_create_namespace("filetree_current_hl_neotree") end
  return _ns
end

---@param path string
---@param hl_group string
---@return boolean
function M.highlight_node(path, hl_group)
  local line = M.get_node_line(path)
  if not line then return false end
  local _, bufnr = M.is_open()
  if not bufnr then return false end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns(), line - 1, 0, {
    line_hl_group = hl_group,
    priority = 150,
  })
  if ok then _hl_marks[path] = id end
  return ok
end

---@param path string
---@return boolean
function M.unhighlight_node(path)
  local id = _hl_marks[path]
  if not id then return true end
  local _, bufnr = M.is_open()
  if not bufnr then return false end
  local ok = pcall(vim.api.nvim_buf_del_extmark, bufnr, ns(), id)
  _hl_marks[path] = nil
  return ok
end

-- Sign-column markers (a separate namespace + mark table from the line
-- highlights above, so a node can carry both a line highlight AND a sign, and
-- either can be cleared independently).
---@type table<string, integer>   path → sign extmark id
local _sign_marks = {}
local _sign_ns = nil
---@internal
local function sign_ns()
  if not _sign_ns then _sign_ns = vim.api.nvim_create_namespace("filetree_sign_neotree") end
  return _sign_ns
end

---@param path string
---@param text string
---@param hl_group string
---@return boolean
function M.sign_node(path, text, hl_group)
  local line = M.get_node_line(path)
  if not line then return false end
  local _, bufnr = M.is_open()
  if not bufnr then return false end
  M.unsign_node(path)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, sign_ns(), line - 1, 0, {
    sign_text = text,
    sign_hl_group = hl_group,
    priority = 160,
  })
  if ok then _sign_marks[path] = id end
  return ok
end

---@param path string
---@return boolean
function M.unsign_node(path)
  local id = _sign_marks[path]
  if not id then return true end
  local _, bufnr = M.is_open()
  if not bufnr then return false end
  local ok = pcall(vim.api.nvim_buf_del_extmark, bufnr, sign_ns(), id)
  _sign_marks[path] = nil
  return ok
end

-- ── Render-event bridge ───────────────────────────────────────────────────────

-- Neo-tree redraws its buffer on its own schedule, not just when filetree asks
-- it to: a git-status fetch landing, a filesystem-watcher event, a background
-- diagnostics update, `follow_current_file`, all rewrite the tree buffer from
-- scratch. Any decoration drawn as an extmark on the previous render (marks'
-- checkmarks, most visibly -- see the bug this fixes: a checkmark surviving
-- only until the next such redraw, which reads as "vanishes after a second")
-- gets wiped along with it. Callers that need to redraw a decoration in sync
-- with neo-tree's OWN render cycle -- not just filetree's BufEnter/BufWritePost
-- dispatch -- subscribe here instead of guessing at a poll interval.
--
-- Two DIFFERENT neo-tree code paths end a render, and only one of them fires
-- an event: `ui/renderer.lua`'s `show_nodes` (a full filesystem-rescan pass --
-- `refresh()`, `navigate()`, the first render after `:Neotree show`) rebuilds
-- the whole node tree and fires `events.AFTER_RENDER` at the very end. But
-- `renderer.redraw(state)` -- called from a dozen NARROWER call sites that
-- only need to re-draw already-set nodes without rescanning anything, most
-- notably `sources/manager.lua`'s `opened_buffers_changed` (wired to
-- `enable_opened_markers`/`enable_modified_markers`, both default-on: ANY
-- buffer opening or closing ANYWHERE in the session redraws EVERY tracked
-- per-tab tree, including ones on background tabs the user never touched) --
-- only calls a local `render_tree(state)` (`state.tree:render()` plus cursor
-- restore) and never reaches `show_nodes` at all, so it never fires
-- AFTER_RENDER. `state.tree:render()` is still a real NuiTree buffer-content
-- replace though -- it does not carry extmarks over, same as any other
-- render -- so a subscriber that only listens for AFTER_RENDER silently misses
-- this whole class of redraw, and whatever it drew (a symlink sign, a mark
-- checkmark) on a background tab's tree stays gone until that tab's OWN tree
-- gets a real AFTER_RENDER of its own (its own focus, its own rescan).
--
-- Closed below by also monkeypatching `renderer.redraw` itself (see
-- `install_redraw_hook`) rather than parallel-listening for neo-tree's own
-- BufAdd/BufDelete/BufWipeout autocmds and guessing at its 200ms debounce from
-- the outside: every one of those call sites reaches `renderer.redraw` through
-- a plain field lookup on the shared `neo-tree.ui.renderer` module table
-- (`local renderer = require("neo-tree.ui.renderer")`, then
-- `renderer.redraw(state)`), resolved at CALL time -- not a function value
-- captured once at neo-tree's own `setup()` time the way each event queue's
-- subscriber list is (see `M.opened_buffers_changed`'s callers) -- so
-- wrapping it here is visible to EVERY caller regardless of load order, the
-- same reasoning `install_reveal_guard` below already relies on for
-- `commands.execute`. It also runs synchronously, inside neo-tree's own
-- callstack, immediately after the real redraw -- no timing window to race,
-- and no separate debounce interval of this module's own to keep in sync with
-- neo-tree's should that ever change. (It also, as a side effect, closes the
-- identical gap for every OTHER narrow-redraw call site -- diagnostics,
-- dir-changed, clipboard changes, several `sources/common/commands.lua`
-- actions, and filetree's own `opened_sync` feature's `adapter.redraw()` --
-- all of which share this exact "render without AFTER_RENDER" shape.)
---@type table<fun(integer?), true>
local _render_listeners = {}
---@type boolean  the AFTER_RENDER subscription -- see `install_render_hook`.
local _after_render_subscribed = false
---@type boolean  the `renderer.redraw` monkeypatch -- see `install_render_hook`.
local _redraw_hook_installed = false
---@type boolean  a `try_install_redraw_hook_later` retry loop is in flight.
local _redraw_hook_retry_scheduled = false
---@type integer
local _redraw_hook_retries = 0
-- How long the background install loops keep trying (limit x interval_ms,
-- 3 s by default) before `on_render` falls back to waiting for neo-tree's
-- first tree buffer (see `M.on_render`). Read at call time; a field on `M`
-- only so a test can shorten it -- not configuration.
M._retry = { limit = 20, interval_ms = 150 }
-- Augroup of the late-install `FileType neo-tree` autocmds `M.on_render` arms
-- once its retries run out (one autocmd per subscriber, deleted individually).
local LATE_INSTALL_GROUP = "filetree_neotree_late_install"
-- Field name `install_redraw_hook` stores its live notify callback under, on
-- `renderer` itself (neo-tree's own module table) rather than in a local
-- here -- see that function's doc comment for why a module-level local
-- cannot make the wrap idempotent across a hot reload, and why a table field
-- on the CALLEE's own persistent table can.
---@type string
local REDRAW_NOTIFY_FIELD = "_filetree_notify_redraw"

---@internal
---Neo-tree's `ui/renderer.lua` fires AFTER_RENDER as
---`events.fire_event(events.AFTER_RENDER, state)` -- passing the REAL state
---for whichever tree just (re)rendered, which is exactly the tab/window that
---rendering happened on, regardless of which tab is nominally current when
---the handler runs (a background tab's async git-status/watcher-driven redraw
---does not switch tabs to get there). Reducing that down to a bufnr here,
---once, is what lets every subscriber below resolve ITS OWN render pass
---directly (`state_for_bufnr`/`get_node_at_line(bufnr, ...)`) instead of
---falling back on the ambient, tab-guessing `get_state()` -- which, with two
---trees simultaneously live on two different tabs, cannot always tell the two
---apart (see `state_for_bufnr`'s doc comment).
---
---Shared by BOTH render hooks below (the real `AFTER_RENDER` event and the
---`renderer.redraw` monkeypatch) -- `state` means the same thing on either
---path: neo-tree's own per-render state for whichever tree just redrew.
---@param state table?
---@return integer? bufnr
local function bufnr_of(state)
  if not state or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return nil end
  return vim.api.nvim_win_get_buf(state.winid)
end

---@internal
---Fire every `on_render` subscriber with `bufnr` -- see `M.on_render`'s doc
---comment for what a subscriber does with it.
---@param bufnr integer?
local function notify_render_listeners(bufnr)
  for callback in pairs(_render_listeners) do
    pcall(callback, bufnr)
  end
end

---@internal
---Shared monkeypatch technique: replace `tbl[field_name]` with
---`wrapper_factory(original)`, forwarding the stash/replace/forward dance
---`install_redraw_hook` and `M.install_reveal_guard` each otherwise hand-roll
---separately (a third, also-unfactored copy lives in `lib.nvim`'s
---`lua/lib/nvim/neotree/watch/init.lua M.install()`). A deliberate
---monkeypatch of the callee's own module table, not a redefinition of
---anything at the call site: every caller reaches `tbl[field_name]` through
---its own `require(...)` of the SAME shared module table, resolved at CALL
---time via a plain field lookup -- so this is visible to every caller
---regardless of which module loaded first, unlike a caller-side wrapper,
---which only ever sees calls made through that one particular upvalue.
---@param tbl table
---@param field_name string
---@param wrapper_factory fun(original: function): function
---@return boolean installed
local function monkeypatch(tbl, field_name, wrapper_factory)
  local original = tbl[field_name]
  if type(original) ~= "function" then return false end
  ---@diagnostic disable-next-line: duplicate-set-field
  tbl[field_name] = wrapper_factory(original)
  return true
end

---@internal
---Monkeypatch `neo-tree.ui.renderer`'s `redraw` (the narrow, no-rescan redraw
---path -- see the "Render-event bridge" comment above for why this exists
---alongside the AFTER_RENDER subscription, not instead of it) so every caller
----- regardless of which neo-tree module holds its own `local renderer =
---require(...)` upvalue, and regardless of whether that caller's module
---loaded before or after this hook installs -- notifies this bridge's
---subscribers right after neo-tree's own real redraw completes.
---
---Idempotent across a hot reload -- but NOT via a module-level local here,
---the way a first attempt at this did: a plugin reload (`package.loaded[...]
---= nil` + re-require, a normal dev workflow) gives THIS module a brand-new,
---empty set of locals, including any "already wrapped" bookkeeping kept in
---one -- so a local-only guard sees nothing and wraps `renderer.redraw`
---again, stacking a second layer around a first-generation wrapper closure
---whose own `notify_render_listeners` upvalue is now orphaned: the SECOND
---generation's `marks`/`link_marker` subscribe into a fresh `_render_listeners`
---table that the still-installed FIRST wrapper never calls, so its callbacks
---never fire at all (measured, not theoretical -- this exact gap shipped once
---before this comment was written).
---
---Fixed by storing the live notify callback on `renderer` itself
---(`REDRAW_NOTIFY_FIELD` above) instead of in a local here: `renderer` is
---neo-tree's OWN persistent module table, untouched by reloading THIS one --
---so repointing that field to the CURRENT generation's `notify_render_listeners`
---is enough to keep an already-installed wrapper calling the right callbacks,
---with no need to ever re-wrap `renderer.redraw` a second time. The wrapper
---itself reads the field fresh on every call (not a captured closure value),
---so it is generation-agnostic by construction; only the very first call ever
---(field is nil, nothing wrapped yet) does the actual monkeypatch.
---@param renderer table  `neo-tree.ui.renderer`, already `require`d by the caller.
---@return boolean installed
local function install_redraw_hook(renderer)
  if renderer[REDRAW_NOTIFY_FIELD] ~= nil then
    -- Wrapped by an earlier generation of this module: just repoint it.
    renderer[REDRAW_NOTIFY_FIELD] = notify_render_listeners
    return true
  end
  local installed = monkeypatch(renderer, "redraw", function(original_redraw)
    return function(state, ...)
      local result = original_redraw(state, ...)
      local notify_fn = renderer[REDRAW_NOTIFY_FIELD]
      if notify_fn then notify_fn(bufnr_of(state)) end
      return result
    end
  end)
  -- Marked only AFTER a wrap actually happened: setting the field first
  -- (as this once did) made a failed wrap -- `renderer.redraw` not a plain
  -- function -- read as "already wrapped" on the very next call, so the
  -- retry loop reported a hook that was never installed as installed.
  if installed then renderer[REDRAW_NOTIFY_FIELD] = notify_render_listeners end
  return installed
end

---@internal
---Keep retrying `install_redraw_hook` in the background until it succeeds,
---independent of the AFTER_RENDER subscription below -- see
---`install_render_hook`'s doc comment for why the two are tracked
---separately. Warns once, after retries are exhausted, rather than staying
---silent forever: a failed install here means narrow, no-rescan redraws
---(neo-tree's own `opened_buffers_changed`, several `sources/common/
---commands.lua` actions) silently stop keeping filetree's decorations in
---sync, with nothing else about the session looking broken.
local function try_install_redraw_hook_later()
  if _redraw_hook_installed or _redraw_hook_retry_scheduled then return end
  _redraw_hook_retry_scheduled = true
  local function retry()
    _redraw_hook_retry_scheduled = false
    if _redraw_hook_installed then return end
    local ok_renderer, renderer = pcall(require, "neo-tree.ui.renderer")
    if ok_renderer then _redraw_hook_installed = install_redraw_hook(renderer) end
    if _redraw_hook_installed then return end
    _redraw_hook_retries = _redraw_hook_retries + 1
    if _redraw_hook_retries < M._retry.limit then
      _redraw_hook_retry_scheduled = true
      vim.defer_fn(retry, M._retry.interval_ms)
    else
      notify.warn(
        "could not hook neo-tree's narrow redraw path (renderer.redraw) after retries -- "
          .. "decorations (marks, symlink signs, ...) may go stale after operations that "
          .. "redraw without a full rescan (copy/cut/paste, opening/closing buffers, ...). "
          .. "See docs/FEATURES/BACKENDS.md."
      )
    end
  end
  vim.defer_fn(retry, M._retry.interval_ms)
end

---@internal
---Installs the AFTER_RENDER subscription and the `renderer.redraw`
---monkeypatch as two INDEPENDENT flags, not one -- a failed redraw-hook
---install (e.g. some future/forked neo-tree where `renderer.redraw` isn't a
---plain function) must not be silently, permanently swallowed just because
---the AFTER_RENDER half succeeded: the old single-flag version set
---`_render_hook_installed = true` unconditionally after firing both
---installs, ignoring `install_redraw_hook`'s own return value -- and because
---this function short-circuits at the top once that flag is set, a failed
---redraw-hook install was never retried and never logged again, with the
---AFTER_RENDER half still visibly working so nothing looked broken.
---
---Returns true once the AFTER_RENDER subscription is up -- the minimum bar
---for `M.on_render` callbacks to fire at all. The redraw-hook half keeps
---retrying independently via `try_install_redraw_hook_later` when it fails,
---and warns once its own retries are exhausted.
---@return boolean installed
local function install_render_hook()
  if _after_render_subscribed and _redraw_hook_installed then return true end
  local ok_events, events = pcall(require, "neo-tree.events")
  local ok_renderer, renderer = pcall(require, "neo-tree.ui.renderer")
  if not ok_events or not ok_renderer then return false end

  if not _after_render_subscribed then
    local handler = {
      event = events.AFTER_RENDER,
      id = "filetree_neotree_after_render",
      handler = function(state)
        notify_render_listeners(bufnr_of(state))
      end,
    }
    -- Unsubscribe first: neo-tree's event queue does not dedupe by id, so a
    -- second subscribe (e.g. filetree.setup() re-running) would otherwise
    -- fire the same handler twice per render.
    pcall(events.unsubscribe, handler)
    pcall(events.subscribe, handler)
    _after_render_subscribed = true
  end

  if not _redraw_hook_installed then
    _redraw_hook_installed = install_redraw_hook(renderer)
    if not _redraw_hook_installed then try_install_redraw_hook_later() end
  end

  return _after_render_subscribed
end

---@internal
---Hoist the `renderer.redraw` monkeypatch to install BEFORE anyone else's
---FIRST `require("neo-tree.ui.renderer")` -- closing a gap `install_redraw_hook`
---alone cannot: neo-tree's own `sources/filesystem/commands.lua` does
---`local redraw = renderer.redraw` at ITS OWN module-load time (a plain Lua
---upvalue, captured once, not a field lookup) -- and that module is required
---EAGERLY, for every configured source, from inside neo-tree's own `setup()`
---(see `setup/init.lua`: `source_default_config.commands = ... or
---require(mod_root .. ".commands")`). For a commonly lazy-loaded neo-tree.nvim
---(`cmd = "Neotree"` / `ft = "neo-tree"`), that `setup()` call itself only
---runs on the user's FIRST `:Neotree` invocation -- so `install_render_hook`'s
---own retry loop, which only starts once THIS module's `on_render` is first
---called (from marks/link_marker's own `setup()`), can lose the race
---entirely: by the time it gets a turn, `commands.lua` may already have
---captured the pre-patch `renderer.redraw` into its own local, permanently,
---for the rest of the session -- the four clipboard commands bound through it
---(`y`/`x`/`<Esc>`/`p` by default) then never notify this bridge again, no
---matter how many times `renderer.redraw` itself gets patched afterwards
---(Lua upvalues do not re-resolve to a table's current field value).
---
---Patching the table field later cannot retroactively fix an already-
---captured local anywhere else in the process -- so the fix has to be
---structural: win the race instead of running faster. `package.preload`
---is Lua's own hook for "run this the FIRST time -- and only the first time
----- anyone requires this module name", checked by `require()` before the
---normal file-based searchers and cached into `package.loaded` exactly the
---same way a normal `require` result is. Installing our own preload entry
---here means the very FIRST `require("neo-tree.ui.renderer")` from ANYONE --
---including from inside neo-tree's own `setup()` -- returns an
---ALREADY-patched module table, before any caller's own top-level
---`local redraw = renderer.redraw` can run. This wins regardless of whether
---neo-tree.setup() runs before or after THIS function, as long as THIS
---function runs before neo-tree.ui.renderer is first required by anyone --
---which is why it's called eagerly, at THIS adapter module's own load time
---(see the bottom of this file), rather than only from marks/link_marker's
---`setup()` the way `install_render_hook` is.
---
---Residual limitation, clearly disclosed rather than papered over (see
---docs/FEATURES/BACKENDS.md): if `neo-tree.ui.renderer` is ALREADY loaded by
---the time this runs (e.g. the user's own config calls
---`require("neo-tree").setup()` -- which itself requires `commands.lua`,
---which requires `renderer` -- before `require("filetree").setup()` /
---`require("filetree.adapter.neotree")` ever runs), hoisting is no longer
---possible: `commands.lua` has already captured whatever `renderer.redraw`
---was at that point. The fallback branch below still patches the field
---directly (matching this module's previous, pre-fix behavior) so every
---OTHER narrow-redraw call site (the ones that resolve `renderer.redraw` via
---a live field lookup, not a captured local -- see the "Render-event bridge"
---comment above) still benefits, but `commands.lua`'s own four clipboard
---commands specifically stay unpatched for that session. Loading
---filetree.nvim's setup before neo-tree.nvim's own setup() call (e.g. neither
---plugin lazy-loaded past VimEnter, or filetree declared as neo-tree's own
---plugin-manager dependency) avoids this entirely.
---@internal
---Load `name` via Lua's own module searchers, SKIPPING the `package.preload`
---searcher (always index 1 -- see the Lua manual's `require`/`package.searchers`)
----- i.e. exactly what `require(name)` itself would do, minus the preload
---lookup. Needed because `hoist_redraw_hook`'s own preload entry cannot just
---call `require(name)` to get the real module: `require` is not reentrant for
---a module whose loader is still running -- calling it again for the SAME
---name from inside our own preload function (even after clearing that entry)
---errors "loop or previous error loading module", since Neovim's own
---`require` tracks the in-flight call, not merely `package.loaded`/
---`package.preload`'s current contents. Going straight to the remaining
---searchers sidesteps that reentrancy check entirely.
---@param name string
---@return unknown
local function require_bypassing_preload(name)
  ---@diagnostic disable-next-line: deprecated, undefined-field
  local searchers = package.loaders or package.searchers -- luacheck: ignore 143
  for i = 2, #searchers do
    -- A searcher's second return is the loader's own argument (the file path
    -- for the Lua-file searcher); `require` hands it on as `...`'s second
    -- value, and a module may read it.
    local loader, loader_data = searchers[i](name)
    if type(loader) == "function" then
      local result = loader(name, loader_data)
      -- `require`'s own contract: a non-nil return wins; otherwise whatever
      -- the module stored in package.loaded itself; otherwise `true`.
      if result == nil then result = package.loaded[name] end
      if result == nil then result = true end
      package.loaded[name] = result
      return result
    end
  end
  error("module '" .. name .. "' not found", 0)
end

local function hoist_redraw_hook()
  if package.loaded["neo-tree.ui.renderer"] then
    -- Already loaded by someone else before we got here -- too late to hoist
    -- (see the "Residual limitation" paragraph above); patch the field
    -- directly, same as `install_render_hook` would, so at least every OTHER
    -- call site still benefits.
    pcall(function()
      install_redraw_hook(require("neo-tree.ui.renderer"))
    end)
    return
  end
  if package.preload["neo-tree.ui.renderer"] then return end -- already hoisted

  local function preload_loader()
    -- Clear our own preload entry FIRST -- belt and suspenders, since
    -- `require_bypassing_preload` below never even looks at it.
    package.preload["neo-tree.ui.renderer"] = nil
    local ok, mod = pcall(require_bypassing_preload, "neo-tree.ui.renderer")
    if not ok then
      -- Neo-tree is not on the runtimepath (yet) -- the normal state of a
      -- lazy-loaded plugin, and exactly what `install_render_hook`'s own
      -- background retries `require` into. LuaJIT's `require` stores a
      -- "loading" sentinel in `package.loaded[name]` BEFORE it calls a loader
      -- and never clears it when that loader throws, so leaving it would fail
      -- every later `require("neo-tree.ui.renderer")` -- neo-tree's own, once
      -- it does load -- with "loop or previous error loading module", for the
      -- rest of the session. A plain `require` of a missing module leaves no
      -- such trace; undo it, and re-arm the hoist for the real first load.
      package.loaded["neo-tree.ui.renderer"] = nil
      package.preload["neo-tree.ui.renderer"] = preload_loader
      error(mod, 0)
    end
    pcall(install_redraw_hook, mod)
    return mod
  end
  package.preload["neo-tree.ui.renderer"] = preload_loader
end

---Subscribe `callback` to fire every time neo-tree finishes (re)rendering the
---filesystem tree -- both a full rescan (`AFTER_RENDER`) and a narrower
---redraw-without-rescan (`renderer.redraw`, e.g. neo-tree's own
---`opened_buffers_changed` -- see the "Render-event bridge" comment above).
---Neo-tree may not be loaded yet (cmd-lazy), so installation is retried in the
---background for a few seconds (`M._retry`), mirroring sidebar_guard's
---deferred install. A neo-tree that is still not loaded when those retries run
---out -- a lazy `cmd = "Neotree"` / `ft = "neo-tree"` plugin the user first
---opens minutes into the session -- is not given up on: the subscription then
---waits for the first `neo-tree` buffer (`FileType`), which cannot exist before
---neo-tree itself is loaded, installs the hooks then, and calls `callback`
---once with that buffer. Without this fallback such a session never got a
---single redraw signal, and marks/link_marker decorations stayed undrawn.
---
---`callback` receives the bufnr of the tree that just rendered (nil if it
---could not be resolved, e.g. the window closed between the render and this
---handler running) -- resolve any per-line/per-node state from THAT bufnr
---(`get_node_at_line`/`get_visible_nodes(filter, bufnr)`), not from a fresh
---ambient `get_bufnr()` call, so a redraw of one tree can never be decorated
---using -- or silently dropped for -- a second, unrelated tree simultaneously
---live on another tab.
---@param callback fun(bufnr: integer?)
---@return fun() unsubscribe
function M.on_render(callback)
  local cancelled = false
  ---@type integer?
  local late_autocmd

  local function disarm_late_install()
    if late_autocmd then pcall(vim.api.nvim_del_autocmd, late_autocmd) end
    late_autocmd = nil
  end

  ---Retries are spent: wait for the first neo-tree buffer instead. Stays armed
  ---until an install succeeds (a `FileType neo-tree` that fires before the
  ---plugin's modules are requirable just leaves it for the next one) or until
  ---the subscription is cancelled.
  local function arm_late_install()
    if cancelled or late_autocmd then return end
    local scheduled = false
    notify.debug("on_render: neo-tree not loaded after retries; waiting for its first buffer")
    late_autocmd = au.create("FileType", function(args)
      if scheduled then return end
      scheduled = true
      -- Deferred: the plugin manager that loads a lazy neo-tree on this very
      -- FileType may run after this autocmd, and the tree buffer is not
      -- rendered yet either -- let both settle before requiring/decorating.
      vim.schedule(function()
        scheduled = false
        if cancelled or not install_render_hook() then return end
        disarm_late_install()
        _render_listeners[callback] = true
        if vim.api.nvim_buf_is_valid(args.buf) then pcall(callback, args.buf) end
      end)
    end, {
      group = au.group(LATE_INSTALL_GROUP, false),
      pattern = "neo-tree",
      record = false, -- per-subscriber, deleted again: not part of the binding catalog
      desc = "filetree.adapter.neotree: install the render hooks once neo-tree exists",
    })
  end

  if install_render_hook() then
    _render_listeners[callback] = true
  else
    local tries = 0
    local function retry()
      if cancelled then return end
      tries = tries + 1
      if install_render_hook() then
        if not cancelled then _render_listeners[callback] = true end
        return
      end
      if tries < M._retry.limit then
        vim.defer_fn(retry, M._retry.interval_ms)
      else
        arm_late_install()
      end
    end
    vim.defer_fn(retry, M._retry.interval_ms)
  end
  return function()
    cancelled = true
    _render_listeners[callback] = nil
    disarm_late_install()
  end
end

-- ── Reveal-prompt guard ───────────────────────────────────────────────────────

---@type boolean
local _reveal_guard_installed = false

---Ensure `require("neo-tree.command").execute` never triggers neo-tree's own
---"File not in cwd. Change cwd to <dir>?" confirm prompt (see neo-tree's
---lua/neo-tree/command/init.lua, handle_reveal()).
---
---That prompt fires whenever a reveal is requested — explicitly via
---`reveal = true`, or IMPLICITLY whenever `filesystem.follow_current_file.enabled`
---is on and `reveal` was left unset — without an explicit `dir` and without
---`reveal_force_cwd`, and the file to reveal isn't under the tree's current
---(possibly stale) root. `reveal_force_cwd` is a per-call flag with no
---persistent `filesystem.follow_current_file.*` config equivalent, so setting
---it on every one of filetree.nvim's own calls isn't enough — ANY code that
---calls neo-tree's command API directly (a user's own custom keymaps, a
---plugin, neo-tree's own internals) can just as easily trigger it, and missing
---even one call site (this is exactly how the original bug report happened —
---several sites were correctly guarded, one was overlooked) brings the prompt
---back. Since every caller shares the same `neo-tree.command` module table,
---wrapping `execute` once here protects all of them, current and future,
---without needing to audit every call site by hand.
---
---Only touches calls that would otherwise be at risk: an explicit
---`reveal = false`, or a call that already sets `dir` or `reveal_force_cwd`
---itself, is left completely alone — this never changes behavior for a call
---that already knows what it wants.
---@return nil
function M.install_reveal_guard()
  if _reveal_guard_installed then return end
  local ok, commands = pcall(require, "neo-tree.command")
  if not ok then return end

  -- Shared monkeypatch technique with install_redraw_hook -- see
  -- `monkeypatch`'s own doc comment above.
  local installed = monkeypatch(commands, "execute", function(original_execute)
    return function(args, ...)
      if
        type(args) == "table"
        and args.dir == nil
        and args.reveal_force_cwd == nil
        and args.reveal ~= false
      then
        args.reveal_force_cwd = true
      end
      return original_execute(args, ...)
    end
  end)

  if installed then _reveal_guard_installed = true end
end

-- Hoist the redraw hook as early as this module can manage -- see
-- `hoist_redraw_hook`'s own doc comment for why this runs unconditionally at
-- module-load time rather than gated behind any feature's own setup().
hoist_redraw_hook()

-- Self-register
registry.register(M)

return M
