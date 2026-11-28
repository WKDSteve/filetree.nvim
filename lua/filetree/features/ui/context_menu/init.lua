---@module 'filetree.features.ui.context_menu'
---@brief Right-click context menu in the tree, via ui.contextmenu.
---@description
--- Binds a mouse trigger (default `<RightMouse>`) inside the tree buffer.
--- On click: moves the cursor to the clicked node first (so the menu acts on
--- what was actually clicked, not wherever the cursor happened to be), then
--- opens the menu through `ui.contextmenu`, populated with
--- `filetree.integrations.menu.items()` — the SAME curated, self-gating entry
--- list a host config could already wire up by hand. This feature only adds
--- the trigger; which entries appear is still controlled entirely by the
--- top-level `menu` config (group-level opt-out — see @types/config.lua).
---
--- Only a click on a text row of the tree opens it. A click anywhere else --
--- the empty area below the last node, the tree's statusline / winbar /
--- vertical separator, another window -- opens no menu and leaves the cursor
--- alone. `keymap` is a MOUSE trigger: it reads the pointer position.
---
--- `ui.contextmenu` draws the menu with `ui.kit.menu` (no third-party
--- dependency), so this feature needs no menu plugin. It is never require()d until the
--- first click. On by default (opt-out); degrades to a single notify, not an
--- error, only if ui.nvim itself predates `ui.contextmenu`.
---
--- Two extras of the kit renderer:
---  * the clicked node's line is highlighted for as long as the menu stays
---    open, so it is never ambiguous which node an entry would act on;
---  * with the tree docked left/right, the menu opens beside the tree
---    window instead of at the click -- which would otherwise sit on top
---    of, and often fully hide, the very row it is highlighting.

local notify = require("filetree.util.notify").create("[filetree.context_menu]")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeContextMenuConfig
local DEFAULTS = {
  enabled = true,
  keymap = "<RightMouse>",
}

---@type FiletreeContextMenuConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.context_menu` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
}

---@type boolean
local _warned_missing = false

---@type FiletreeAdapter?
local _adapter = nil

---Whether the pointer is on the empty area below the last line of the tree.
---`getmousepos().line` is clamped to the last line there, so the line alone
---cannot tell a click on the last node from one below it -- the screen row
---can: it lies past the bottom of the buffer text drawn from the top line.
---
---The screen row where the text starts is taken from the CURSOR line, which is
---always on screen. `screenpos()` of the last line is not usable for that: it
---reports row 0 whenever the window is scrolled sideways past the first
---column of that line (trees are `nowrap`), which silently disabled this.
---
---Needs the pointer's window to be the current one (`resolve_click` checks).
---@param pos table  `getmousepos()` result
---@return boolean
local function is_below_last_line(pos)
  local win = pos.winid
  local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  if pos.line < last then return false end
  local cur = vim.api.nvim_win_get_cursor(win)
  local cursor_row = vim.fn.screenpos(win, cur[1], cur[2] + 1).row
  if cursor_row == 0 then return false end
  local view = vim.fn.winsaveview()
  local ok, h = pcall(vim.api.nvim_win_text_height, win, {
    start_row = view.topline - 1,
    start_vcol = view.skipcol,
  })
  if not ok then return false end
  local first_text_row = cursor_row - vim.fn.winline() + 1
  return pos.screenrow > first_text_row + h.all - 1
end

---The pointer position, when it is on a text row of the tree window that this
---mapping fired in -- i.e. when "the node under the mouse" means something.
---Everything else is not a click on a node and is ignored by the caller:
---the empty area below the last node, the tree's statusline / winbar /
---vertical separator (`line == 0`), the tabline or command line (`winid == 0`),
---and any other window (a buffer-local mapping fires for the CURRENT buffer,
---whichever window the pointer is over).
---@return table?
local function resolve_click()
  local ok, pos = pcall(vim.fn.getmousepos)
  if not ok or type(pos) ~= "table" then return nil end
  if pos.winid ~= vim.api.nvim_get_current_win() or pos.line < 1 then return nil end
  if is_below_last_line(pos) then return nil end
  return pos
end

---Move the tree cursor to the clicked node (`pos` from `resolve_click`).
---A mapped `<RightMouse>` replaces Neovim's own click handling, so nothing
---else moves the cursor to the pointer: this has to, or the menu would act on
---wherever the cursor happened to be.
---@param pos table
local function move_to_click(pos)
  local ok_set =
    pcall(vim.api.nvim_win_set_cursor, pos.winid, { pos.line, math.max(0, pos.column - 1) })
  if not ok_set then return end

  -- Tell whoever tracks the cursor about the jump NOW. neo-tree remembers the
  -- cursor line from a `CursorMoved` autocmd and puts it back on every
  -- `WinEnter` of the tree window. That autocmd only fires once this mapping
  -- has returned, but the menu opens synchronously below, and creating its
  -- window briefly re-enters the tree window -- so neo-tree restored the line
  -- it had remembered BEFORE the click, and the menu acted on the node the
  -- cursor was last on (usually further down) instead of the one clicked.
  pcall(vim.api.nvim_exec_autocmds, "CursorMoved", {
    buffer = vim.api.nvim_win_get_buf(pos.winid),
    modeline = false,
  })
end

-- ── Clicked-node highlight, for the life of the menu ────────────────────────

local NODE_HL = "FiletreeContextMenuNode"
local _hl_ensured = false
---@type string?
local _highlighted_path = nil
---@type integer?
local _hl_augroup = nil

---@internal
local function ensure_node_hl()
  if _hl_ensured then return end
  _hl_ensured = true
  -- `default = true`: a colorscheme or the user's own config may already
  -- define this group (or link it elsewhere); this only supplies a sensible
  -- fallback, never overrides one already set. Linked rather than a fixed
  -- hex color so it matches whatever theme is active, the same way the kit
  -- menu's own selection highlight does.
  pcall(vim.api.nvim_set_hl, 0, NODE_HL, { link = "Visual", default = true })
end

-- Bumped on every clear -- lets a deferred re-application (below) tell "the
-- click I was applied for is still the live one" from "a newer click, or an
-- explicit clear, has already superseded me" without needing a timer to
-- cancel itself.
local _hl_generation = 0

---@internal
local function clear_node_highlight()
  if _highlighted_path and _adapter and _adapter.unhighlight_node then
    pcall(_adapter.unhighlight_node, _highlighted_path)
  end
  _highlighted_path = nil
  _hl_generation = _hl_generation + 1
end

---@internal
--- Apply the extmark for `path`, unless a newer click (or an explicit
--- clear) has since moved `_hl_generation` past `generation` -- see the
--- three call sites in `highlight_current_node` for why this runs more
--- than once. `announce`: only the first, immediate attempt warns on
--- failure; a real failure is a persistent condition (the adapter/node
--- itself), not a transient one the later attempts would recover from
--- differently, so repeating the same warning three times adds noise
--- without adding information.
---@param path string
---@param generation integer
---@param announce boolean
local function apply_highlight_now(path, generation, announce)
  if generation ~= _hl_generation then return end
  if not _adapter or not _adapter.highlight_node then return end
  -- Replace this click's own earlier application instead of stacking another
  -- extmark: adapters track one mark id per path, so the older ones could
  -- never be removed again. Only when WE put it there (`_highlighted_path`):
  -- the slot is shared with other features highlighting the same node.
  if _highlighted_path == path and _adapter.unhighlight_node then
    pcall(_adapter.unhighlight_node, path)
  end
  local ok = _adapter.highlight_node(path, NODE_HL)
  if ok then
    _highlighted_path = path
  elseif announce then
    notify.warn("context_menu: adapter.highlight_node() failed for " .. path)
  end
end

---@internal
--- Highlight the node the menu is about to act on. A one-shot fallback
--- (the next time the cursor actually moves within the tree buffer) also
--- clears it, in case the renderer never gives back a close hook to do it
--- promptly (a disabled menu returns none) or the menu fails to open at all.
---
--- Deliberately `CursorMoved` only, NOT `BufLeave`: opening the menu itself
--- moves focus to its own window (kit's float is `enter = true`), which fires `BufLeave` on the tree buffer as a
--- pure side effect of the menu appearing -- before the user has even seen
--- it. That cleared the highlight instantly on every click, which is a
--- silent no-op from the user's perspective: indistinguishable from the
--- highlight never having been applied at all. `CursorMoved` only fires
--- from an actual cursor move while the tree buffer is the one being
--- edited, which cannot happen while a floating menu holds focus.
---
--- Applied three times, not once: `move_to_click`'s cursor move can itself
--- set off a reactive re-render in the tree plugin behind the adapter --
--- often debounced -- and a same-tick extmark can be wiped moments later by
--- that re-render with nothing visibly wrong at click time (confirmed live:
--- `adapter.highlight_node()` reports success, the row never actually shows
--- highlighted). Immediate + next-tick (`vim.schedule`) + a delayed pass
--- past typical debounce windows (`vim.defer_fn`, 150ms) covers same-tick,
--- next-tick and debounced wipes without this needing to know which one a
--- given backend actually does. Nothing here reaches into a specific tree
--- plugin -- every attempt goes through `_adapter.highlight_node`, same as
--- the very first one did.
local function highlight_current_node()
  if not _adapter or not _adapter.get_current_node or not _adapter.highlight_node then
    notify.warn(
      "context_menu: adapter is missing get_current_node/highlight_node -- cannot highlight"
    )
    return
  end
  local node = _adapter.get_current_node()
  if not node or not node.path then
    -- Diagnostic, not silence: a report of "no highlight" with nothing here
    -- means this branch, not a rendering problem -- get_current_node() (or
    -- the cursor move that precedes it) is the thing to look at next.
    notify.warn("context_menu: adapter.get_current_node() returned nothing to highlight")
    return
  end

  ensure_node_hl()
  clear_node_highlight() -- in case a previous click's highlight is still up; bumps the generation
  local generation = _hl_generation
  local path = node.path

  apply_highlight_now(path, generation, true)
  vim.schedule(function()
    apply_highlight_now(path, generation, false)
  end)
  vim.defer_fn(function()
    apply_highlight_now(path, generation, false)
  end, 150)

  local buf = vim.api.nvim_get_current_buf()
  _hl_augroup = vim.api.nvim_create_augroup("FiletreeContextMenuHlFallback", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = _hl_augroup,
    buffer = buf,
    once = true,
    callback = clear_node_highlight,
  })
end

-- ── Positioning beside the tree, when it is docked left/right ───────────────

---@internal
--- Extra `ui.contextmenu.open` opts that anchor the menu just outside
--- the tree window (`relative = "win"`, offset from ITS top-left corner) so
--- it never overlaps the tree itself -- and so never the highlighted row
--- from `highlight_current_node` either. `{}` (fall back to the default
--- mouse anchor) whenever the tree's side isn't left/right: "float"/
--- "current" have no fixed edge to dock the menu against, and covering the
--- tree briefly there is the accepted tradeoff -- the row is still marked,
--- just not necessarily visible the whole time the menu is open.
---@return table
local function beside_tree_opts()
  if not _adapter or not _adapter.get_winid or not _adapter.get_position then return {} end
  local winid = _adapter.get_winid()
  if not winid or not vim.api.nvim_win_is_valid(winid) then return {} end
  local pos = _adapter.get_position()
  if pos ~= "left" and pos ~= "right" then return {} end

  local row = 0
  local ok_cur, cur = pcall(vim.api.nvim_win_get_cursor, winid)
  if ok_cur then row = math.max(0, cur[1] - 1) end

  if pos == "left" then
    -- Float's top-left corner sits at the tree window's own right edge.
    return {
      relative = "win",
      win = winid,
      anchor = "NW",
      row = row,
      col = vim.api.nvim_win_get_width(winid),
    }
  end
  -- "right": float's top-RIGHT corner sits at the tree window's left edge
  -- (col = 0) -- extends leftward, away from the tree, without needing to
  -- know the float's own width up front.
  return { relative = "win", win = winid, anchor = "NE", row = row, col = 0 }
end

local function open_menu()
  local pos = resolve_click()
  if not pos then return end

  move_to_click(pos)
  highlight_current_node()

  local ok_items, items_mod = pcall(require, "filetree.integrations.menu")
  local items = ok_items and items_mod.items() or {}
  if #items == 0 then
    clear_node_highlight()
    return -- nothing enabled/available to show
  end

  local ok_cm, contextmenu = pcall(require, "ui.contextmenu")
  if not ok_cm or type(contextmenu.open) ~= "function" then
    clear_node_highlight()
    if not _warned_missing then
      notify.info(
        "ui.contextmenu unavailable — context_menu has nothing to open (update ui.nvim, or set features.context_menu.enabled = false)"
      )
      _warned_missing = true
    end
    return
  end

  local open_opts = vim.tbl_extend("force", { mouse = true }, beside_tree_opts())
  local surf = contextmenu.open(items, open_opts)
  -- Kit renderer: clear promptly when the menu actually closes, on top of
  -- the CursorMoved/BufLeave fallback above. A disabled menu (surf is nil
  -- here) has no close hook to offer, so the fallback is all it gets.
  if surf and surf.on_close then surf:on_close(clear_node_highlight) end
end

---@param config FiletreeContextMenuConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  -- Merge onto _cfg's own defaults, not a bare overwrite: filetree/init.lua's
  -- setup loop only guarantees `enabled` is set on the incoming table — a user
  -- who never configures features.context_menu at all still needs the default
  -- keymap to survive, not get wiped out by `config` not mentioning it.
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  if not _cfg.keymap then return end

  bind.bind("context_menu", _cfg, {
    { name = "open", field = "keymap", rhs = open_menu, desc = "right-click context menu" },
  })
end

function M.teardown()
  _warned_missing = false
  clear_node_highlight()
  if _hl_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, _hl_augroup)
    _hl_augroup = nil
  end
  _adapter = nil
end

return M
