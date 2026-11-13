---@module 'filetree.features.search.filter'
--- Live filter/search within the tree using a floating input.
---
--- Two strategies, tried in order:
---   1. The backend's own filter, so the listing really narrows
---      (neo-tree: `state.search_pattern` + a refresh; nvim-tree: its
---      `Explorer.live_filter`).
---   2. Extmark-based dimming fallback: non-matching lines are greyed out.
---      Used when the backend has no filter of its own, or its API changed
---      under us -- `try_native_filter` reports failure rather than swallowing
---      it, so a broken native path degrades to dimming instead of to nothing.
---
--- Keymaps:
---   "/" inside tree buffer    → enter filter mode
---   <Esc> / empty query       → clear filter (inside the input prompt)
---   <C-c> inside tree buffer  → clear an already-applied filter directly
---
--- User commands:
---   :Filetree filter [query]
---   :Filetree filter clear

local kit = require("ui.kit")
local bind = require("filetree.util.bind")
local M = {}

---@type FiletreeFilterConfig
local DEFAULTS = {
  enabled = false,
  keymap = "/",
  keymap_clear = "<C-c>",
  case_sensitive = false,
  dim_hl_group = "Comment",
  debounce_ms = 80,
}

---@type FiletreeFilterConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.filter` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  keymap_clear = "keymap",
  case_sensitive = "boolean",
  dim_hl_group = "string",
  debounce_ms = { "number", min = 0 },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer  extmark namespace for dimming
local _ns = -1

---@type string  current filter query
local _query = ""

-- ── Adapter-native filter ─────────────────────────────────────────────────────

---@internal
---Pre-search expanded-folders snapshot, tracked independently of neo-tree's
---own `state.open_folders_before_search`.
---
---`reset_search` nils that field synchronously but its own re-render
---(`navigate`) is debounced ~100ms. A quick clear-then-retype inside that
---window used to make the "capture if unset" guard below re-derive the
---baseline from `state.tree`, which at that moment could still be showing
---stale/filtered content rather than the true pre-search tree -- corrupting
---what later gets restored. Owning the snapshot here means it survives a
---`reset_search` call untouched, and is only released once a deferred check
---confirms no new search picked it back up.
---@type table?
local _pre_search_folders = nil

---@internal
---Tree buffer the open filter input belongs to: captured by `M.enter` while the
---tree has focus, released when the input closes. Nil outside the input.
---@type integer?
local _target_bufnr = nil

---@internal
---The neo-tree state the filter drives -- resolved through the adapter, not
---neo-tree's ambient `manager.get_state("filesystem")`. That one is the CURRENT
---tab's state, and creates an empty placeholder for a treeless tab: with the
---tree live on another tab, the filter used to set its pattern on that
---placeholder, report success, and leave the visible tree unfiltered. The
---adapter resolves the tree that is actually live (the input's own tree while
---it is open, else the ambient tree) and never creates a state.
---@return table? state
local function neotree_state()
  if not (_adapter and _adapter.get_state) then return nil end
  local bufnr = _target_bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or nil
  end
  local state = bufnr and _adapter.get_state(bufnr) or nil
  return state or _adapter.get_state()
end

---@internal
---Second half of a clear: called once the clear's own refresh has rendered.
---
---`reset_search` hands the pre-search folders to neo-tree as
---`state.force_open_folders`, which the next full draw consumes (and nils).
---It also kills a search job that is still running, but a killed job still
---runs its exit handler, which schedules a render of the partial search
---result. When the clear comes less than one navigate debounce (100 ms) after
---the search started, that stale render is the next full draw: it consumes the
---folders, and the clear's refresh then rebuilds the tree from what that
---render left open -- only the root. Whether it happens is timing alone: a
---search that spawns quickly (short $PATH, so neo-tree's per-search lookup of
---its find command is cheap) is cleared inside that window, a slow one is not.
---This puts the folders back when the clear's refresh did not reopen them.
---@param state table  The state the clear ran on.
---@param restore string[]?  Its `open_folders_before_search` at the clear.
local function restore_after_clear(state, restore)
  -- A new query since the clear owns the tree now; it restores on its own clear.
  if not restore or state.search_pattern or not state.tree then return end
  local ok_r, renderer = pcall(require, "neo-tree.ui.renderer")
  if not ok_r then return end
  local open = {}
  for _, id in ipairs(renderer.get_expanded_nodes(state.tree)) do
    open[id] = true
  end
  for _, id in ipairs(restore) do
    local stat = not open[id] and vim.uv.fs_stat(id)
    if stat and stat.type == "directory" then
      -- One more navigate, no callback: a folder that still does not open is
      -- not retried forever.
      state.force_open_folders = vim.deepcopy(restore)
      require("neo-tree.sources.filesystem").navigate(state)
      return
    end
  end
end

---@internal
---Drive neo-tree's own filter: it is `state.search_pattern` plus a refresh,
---which is exactly what its filter prompt does on submit. The pre-search
---expansion is recorded first so `reset_search` can put the tree back the way
---it was rather than leaving every folder the search opened hanging open.
---@param query string?
---@return boolean handled
local function neotree_filter(query)
  local ok_mgr, mgr = pcall(require, "neo-tree.sources.manager")
  local ok_fs, fs = pcall(require, "neo-tree.sources.filesystem")
  if not ok_mgr or not ok_fs then return false end

  local ok, done = pcall(function()
    local state = neotree_state()
    if not state then return false end

    -- Redraw only a tree whose window is actually shown, which is the guard
    -- `manager.refresh` applies per state (it marks the others dirty). A closed
    -- tree is still resolved (the current tab's tracked state), and navigating
    -- it -- directly, or through `reset_search(state, true)` -- makes neo-tree
    -- open a new tree window on the current tab: `:Filetree filter foo`, the
    -- clear in `tree_reset` or the teardown of a re-`setup()` popped the tree
    -- open. A closed tree keeps the pattern and is redrawn when it next opens.
    local ok_r, renderer = pcall(require, "neo-tree.ui.renderer")
    local shown = not (ok_r and renderer.window_exists) or renderer.window_exists(state)

    if not query or query == "" then
      local restore = state.open_folders_before_search
      fs.reset_search(state, false)
      if shown then
        fs.navigate(state, nil, nil, function()
          restore_after_clear(state, restore)
        end)
      else
        state.dirty = true
      end
      -- Release the snapshot only once we're sure this clear stuck -- if
      -- another query lands before neo-tree's debounced re-render fires,
      -- search_pattern will be set again and the release is skipped, so the
      -- original snapshot survives for that next apply/clear round instead
      -- of being re-derived from a not-yet-settled tree. Checked on the very
      -- state just cleared, not looked up again: by then another tab (with
      -- its own tree and pattern) may be current.
      vim.defer_fn(function()
        if not state.search_pattern then _pre_search_folders = nil end
      end, 150)
      return true
    end

    if not _pre_search_folders then
      if ok_r and state.tree and renderer.get_expanded_nodes then
        _pre_search_folders = renderer.get_expanded_nodes(state.tree)
      end
    end
    state.open_folders_before_search = _pre_search_folders
    state.search_pattern = query
    -- This state's own navigate, which is what `manager.refresh` runs per
    -- state -- but refresh only reaches states on the CURRENT tab (others
    -- are merely marked dirty), so a tree live on another tab never redrew.
    if shown then
      mgr.navigate(state, state.path)
    else
      state.dirty = true
    end
    return true
  end)
  return ok and done == true
end

---@internal
---Drive nvim-tree's live filter directly.
---
---NOT `api.tree.search_node`, which this used to call: that function takes no
---argument at all. It opens its own "Search:" prompt and then REVEALS a single
---matching file -- so the query the user already typed was discarded, a second
---prompt appeared, and the tree jumped instead of filtering. The live filter is
---the feature that narrows the listing, and setting its `filter` field plus
---`apply_filter`/`draw` is what its own prompt does per keystroke, minus the
---overlay window.
---@param query string?
---@return boolean handled
local function nvimtree_filter(query)
  local ok_core, core = pcall(require, "nvim-tree.core")
  if not ok_core then return false end

  local ok, done = pcall(function()
    local explorer = core.get_explorer()
    local live = explorer and explorer.live_filter
    if not live or type(live.apply_filter) ~= "function" then return false end

    live.filter = (query ~= "" and query) or nil
    live:apply_filter()
    if explorer.renderer and explorer.renderer.draw then explorer.renderer:draw() end
    return true
  end)
  return ok and done == true
end

---@internal
---Try the adapter's native filter. Returns false when the backend has none, or
---when driving it failed -- the caller then falls back to dimming.
---
---Reporting failure honestly is the point. Both branches used to wrap the call
---in a bare `pcall(...)` and `return true` regardless, so when
---`manager.filter_all` disappeared from neo-tree, `/` silently did nothing at
---all: the native call raised, the error was swallowed, and the fallback was
---never reached because the branch claimed success.
---@param query string?
---@return boolean handled
local function try_native_filter(query)
  if not _adapter then return false end
  if _adapter.name == "neotree" then return neotree_filter(query) end
  if _adapter.name == "nvimtree" then return nvimtree_filter(query) end
  if _adapter.name == "native" then
    -- The own tree lays the hits over itself and reaches folders it never opened; an empty query
    -- shows the tree again exactly as it was (nothing was collapsed, so nothing has to be restored).
    local view = _adapter.get_state and _adapter.get_state()
    if not view then return false end
    view:search(query or "")
    return true
  end
  return false
end

-- ── Extmark-based dimming fallback ────────────────────────────────────────────

---@internal
---Dim non-matching lines in the tree buffer via extmarks (fallback strategy).
---@param query string?
local function dim_non_matching(query)
  if not _adapter then return end
  local bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or -1
  if bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  if not query or query == "" then return end

  local pattern = _cfg.case_sensitive and query or query:lower()

  if not _adapter.get_node_at_line then return end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for linenr = 0, line_count - 1 do
    local node = _adapter.get_node_at_line(bufnr, linenr)
    local name = node and node.name or ""
    local test = _cfg.case_sensitive and name or name:lower()
    if not test:find(pattern, 1, true) then
      -- Dim entire line
      pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, linenr, 0, {
        end_col = #(vim.api.nvim_buf_get_lines(bufnr, linenr, linenr + 1, false)[1] or ""),
        hl_group = _cfg.dim_hl_group,
        hl_eol = true,
        priority = 10,
      })
    end
  end
end

---@internal
---Apply `query`: try the native filter first, fall back to dimming.
---@param query string?
local function apply(query)
  _query = query or ""
  if not try_native_filter(query) then dim_non_matching(query) end
end

-- ── Floating input ────────────────────────────────────────────────────────────

---@type Ui.Kit.Surface|nil
local _surf = nil

---Open the floating filter-query input, focusing it if already open.
function M.enter()
  if _surf and _surf:is_valid() then
    _surf:focus()
    return
  end

  -- Position at bottom of the tree window
  local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid() or -1
  _target_bufnr = tree_win > 0
      and vim.api.nvim_win_is_valid(tree_win)
      and vim.api.nvim_win_get_buf(tree_win)
    or nil
  local row, col, width
  if tree_win > 0 and vim.api.nvim_win_is_valid(tree_win) then
    local pos = vim.api.nvim_win_get_position(tree_win)
    row = pos[1] + vim.api.nvim_win_get_height(tree_win) - 1
    col = pos[2]
    width = vim.api.nvim_win_get_width(tree_win)
  else
    row, col, width = vim.o.lines - 3, 0, 30
  end

  local function return_to_tree()
    if tree_win > 0 and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_set_current_win(tree_win)
    end
  end

  _surf = kit.live_input({
    title = "Filter",
    relative = "editor",
    row = row,
    col = col,
    width = math.max(width, 20),
    default = _query,
    debounce = _cfg.debounce_ms,
    on_change = apply,
    on_submit = function(query)
      apply(query)
      return_to_tree()
    end,
    on_cancel = function()
      M.clear()
      return_to_tree()
    end,
  })
  if _surf then
    _surf:on_close(function()
      _surf = nil
      _target_bufnr = nil
    end)
  else
    _target_bufnr = nil
  end
end

---Clear the current filter.
function M.clear()
  _query = ""
  apply("")
end

---Apply a filter query directly (without the floating input).
---@param query string
function M.apply(query)
  apply(query)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeFilterConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter
  _ns = vim.api.nvim_create_namespace("filetree_filter")

  bind.bind("filter", _cfg, {
    { name = "enter", field = "keymap", rhs = M.enter, desc = "enter filter mode" },
    { name = "clear", field = "keymap_clear", rhs = M.clear, desc = "clear filter" },
  })
end

---Clear the filter and close the floating input, if open.
function M.teardown()
  M.clear()
  if _surf then _surf:close() end
  _adapter = nil
  _pre_search_folders = nil
  _target_bufnr = nil
end

return M
