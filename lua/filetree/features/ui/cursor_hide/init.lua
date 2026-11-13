---@module 'filetree.features.ui.cursor_hide'
---@brief Hide the block cursor while the tree window is focused.
---@description
--- Creates a window-local highlight override (winhighlight) so the cursor
--- disappears when focus is inside a tree buffer, and reappears on leave.
--- Uses a dedicated `FiletreeCursorHidden` hl group with blend=100 so the
--- global Cursor group is never touched.
---
--- Adapter-agnostic: the tree filetypes come from the active adapter's
--- optional `filetypes` capability (same pattern as window_style), so this
--- generalizes to whichever backend is configured. A superset covering all
--- known trees is used as a fallback when an adapter omits it.
---
--- The winhighlight entry is merged into whatever is already set on the
--- window rather than replacing it outright, so it survives regardless of
--- whether the tree plugin's own winhighlight (e.g. neo-tree's Normal/
--- NormalNC/... mapping) was applied before or after this handler runs.
---
--- ### The `'cursorline'` guard
---
--- Hiding the real block cursor only makes sense as long as SOMETHING else
--- marks where the cursor is -- normally the tree plugin's own `'cursorline'`
--- highlight. Nothing here controls that option; it is entirely up to the
--- adapter/colorscheme/user config to leave it on. If it ever ends up off
--- while the real cursor is hidden -- another plugin's own "cursorline only
--- in the active window" autocmd racing this one, a colorscheme reset, a
--- config change -- the tree window shows literally no position indicator at
--- all: not a redraw glitch, just nothing, indistinguishable from having lost
--- the cursor. Movement (`j`/`k`, opening nodes, closing the window) still
--- works throughout, since the cursor is very much still there -- just
--- invisible. Reported 2026-09-23: after some unidentified sequence in real
--- use, the block cursor came back on leaving the tree, as always, but never
--- reappeared IN the tree afterwards -- restarting Neovim was the only fix
--- found. `force_cursorline` (default true) is the guard: whenever this
--- hides the block cursor, it also force-enables `'cursorline'` on that
--- window, remembering whatever it was so `apply_show` can restore the exact
--- previous value on leave (not just re-enable/re-disable blindly, in case
--- the user had it deliberately off in a given window). Set false to go back
--- to leaving `'cursorline'` alone.
---
--- Config:
---   enabled           boolean (default true)
---   force_cursorline  boolean (default true) -- see above
---
--- Note: could not be confirmed via headless Neovim testing (no UIEnter
--- without a real UI attached makes VeryLazy fire unpredictably relative to
--- a scripted test). Confirmed working in real interactive use.

local bufevents = require("filetree.util.bufevents")
local au = require("filetree.util.autocmd")
-- Module-level (not just inside `M.setup()`) so `M.teardown()` can also
-- strip a window's `Cursor` override -- see the restore loop there.
local wh = require("lib.nvim.ui.winhighlight")
local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.cursor_hide` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  force_cursorline = "boolean",
}

local DEFAULT_FILETYPES = { "neo-tree", "NvimTree", "netrw", "oil", "minifiles", "filetree" }

---@type integer?
local _augroup = nil
---@type FiletreeAdapter?
local _adapter = nil
---Per-window `'cursorline'` value from just before this hid the cursor there,
---so `apply_show` restores the exact prior state instead of assuming "on".
---@type table<integer, boolean>
local _prev_cursorline = {}
---Windows that currently carry the `Cursor` winhighlight override, tracked
---independently of `_prev_cursorline` (which only fills in when
---`force_cursorline` is true). `M.teardown()` walks this set to restore
---every such window instead of leaving it stranded -- see the comment there.
---@type table<integer, boolean>
local _hidden_wins = {}

---Tree filetypes to target — the adapter's if declared, else the superset.
---@return table<string, boolean>
local function tree_filetypes()
  local ft = _adapter and _adapter.filetypes
  local list = (type(ft) == "table" and #ft > 0) and ft or DEFAULT_FILETYPES
  local set = {}
  for _, f in ipairs(list) do
    set[f] = true
  end
  return set
end

---@param config FiletreeCursorHideConfig
function M.setup(config, adapter)
  if not config.enabled then return end
  _adapter = adapter
  local force_cursorline = config.force_cursorline ~= false

  vim.api.nvim_set_hl(0, "FiletreeCursorHidden", { blend = 100, nocombine = true })

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_cursor_hide", true)
  _prev_cursorline = {}
  _hidden_wins = {}

  -- `wh` (module-level `lib.nvim.ui.winhighlight`, required above) rather
  -- than string concatenation and a gsub. It is the same merge-and-strip
  -- this used to do by hand, minus two rough edges: appending did not
  -- dedupe, so applying twice left `Cursor:X,Cursor:X`, and the strip was a
  -- Lua pattern over a value other plugins also write.

  local function apply_hide(win, buf)
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then return end
    if not tree_filetypes()[vim.bo[buf].filetype] then return end
    wh.update(win, { Cursor = "FiletreeCursorHidden" })
    _hidden_wins[win] = true
    if force_cursorline then
      -- Only remember on the FIRST hide of a hide/show pair -- a second
      -- BufEnter/WinEnter for the same window before any WinLeave (both
      -- events routinely fire together) must not overwrite the real prior
      -- value with the `true` this itself just set.
      if _prev_cursorline[win] == nil then _prev_cursorline[win] = vim.wo[win].cursorline end
      vim.wo[win].cursorline = true
    end
  end

  local function apply_show(win, buf)
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then return end
    if not tree_filetypes()[vim.bo[buf].filetype] then return end
    -- Strips our override only; every other entry on the window stays.
    wh.remove(win, "Cursor")
    _hidden_wins[win] = nil
    local prev = _prev_cursorline[win]
    if prev ~= nil then
      vim.wo[win].cursorline = prev
      _prev_cursorline[win] = nil
    end
  end

  -- Deferred via vim.schedule: the tree plugin's own window/renderer setup
  -- (still running synchronously within the same BufEnter/WinEnter cycle)
  -- can re-touch winhighlight after this callback returns, so applying
  -- immediately loses the race. Deferring to the next tick - after that
  -- setup has fully settled - is what made window_style's equivalent
  -- fallback reliable; same fix here.
  bufevents.register("cursor_hide", { "BufEnter:*", "WinEnter:*" }, {
    desc = "[filetree] Hide the cursor in the tree window",
    load = function(ctx)
      local win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        apply_hide(win, ctx.buf)
      end)
    end,
  })

  au.acmd({ "BufLeave", "WinLeave" }, {
    group = _augroup,
    desc = "[filetree] Restore the cursor when leaving the tree window",
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        apply_show(win, ev.buf)
      end)
    end,
  })

  -- Belt-and-suspenders: a window can go away without WinLeave firing first
  -- (e.g. `:only` from elsewhere, a plugin closing it directly), which would
  -- otherwise leave a stale entry in `_prev_cursorline` forever. Harmless on
  -- its own (the winid is simply never looked up again), but there is no
  -- reason to keep it either.
  au.acmd("WinClosed", {
    group = _augroup,
    desc = "[filetree] Drop any remembered cursorline state for a closed window",
    callback = function(ev)
      local win = tonumber(ev.match)
      if win then
        _prev_cursorline[win] = nil
        _hidden_wins[win] = nil
      end
    end,
  })
end

function M.teardown()
  bufevents.unregister("cursor_hide")
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
  -- Restore any window this feature is still hiding the cursor in *before*
  -- wiping the state below. Without this, a reconfigure (filetree.setup()
  -- called again while a tree window is focused -- see case (b) at
  -- filetree/init.lua's own setup(), which tears every feature down and
  -- sets it back up) strands that window: the next setup() starts from a
  -- fresh, empty `_prev_cursorline`, so `apply_show` can never find the real
  -- prior value again and 'cursorline' is stuck forced on forever. Worse if
  -- the user disables this feature in the same reconfigure -- no BufLeave/
  -- WinLeave handler is left to run `apply_show` at all, so the `Cursor`
  -- winhighlight override is never removed either and the block cursor
  -- never reappears in that window, exactly the symptom this module's
  -- docstring above describes as needing a Neovim restart.
  for win in pairs(_hidden_wins) do
    if vim.api.nvim_win_is_valid(win) then
      wh.remove(win, "Cursor")
      local prev = _prev_cursorline[win]
      if prev ~= nil then vim.wo[win].cursorline = prev end
    end
  end
  _adapter = nil
  _prev_cursorline = {}
  _hidden_wins = {}
end

return M
