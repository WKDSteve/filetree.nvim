---@module 'filetree.features.ui.kit_slot'
---@brief Let the tree take part in sidebar slot exclusivity with `lib.nvim.ui.kit` sidebars.
---@description
--- A kit sidebar on the left and a tree on the left stand next to each other: neither knows of the other. This
--- registers the tree as a *foreign* panel at `lib.nvim.ui.kit.sidebar.register_foreign`, so the two agree on one
--- slot -- opening a kit sidebar where the tree is takes the tree off the screen and remembers it; closing that
--- sidebar brings the tree back, and the other way round.
---
--- It works for whichever backend is active, through the adapter alone: `get_winid` is the window, `close` hides
--- the tree, `open_cwd` brings it back, `get_position` says which side it is on. The tree is "foreign" to the kit,
--- so the kit asks and the tree answers; the feature only tells the kit when the tree appeared or went away on its
--- own (the user pressed the toggle key): `BufWinEnter` / `WinEnter` for a new tree window, `WinClosed` for the end
--- of one.
---
--- A tree that is not on a side (`float`, `current`) is not a sidebar and takes no slot.

local au = require("filetree.util.autocmd")

local M = {}

---Option schema (see `filetree.config.schema`): exactly what `features.kit_slot` accepts.
---@type FiletreeSchema
M.SCHEMA = {
  name = "string",
}

local DEFAULT_NAME = "filetree"

---@type integer?
local _augroup = nil
---@type Lib.UI.Kit.Foreign?
local _handle = nil
---@type integer?  The tree window the kit was last told about.
local _known_win = nil

---The side the tree is on, or nil when it takes no slot.
---@param adapter FiletreeAdapter
---@return "left"|"right"?
local function slot_of(adapter)
  local pos = adapter.get_position and adapter.get_position() or "left"
  if pos == "left" or pos == "right" then return pos end
  return nil
end

---@param adapter FiletreeAdapter
---@param name string
---@return Lib.UI.Kit.Foreign?
local function register(adapter, name)
  local position = slot_of(adapter)
  if not position then return nil end
  local ok, sidebar = pcall(require, "lib.nvim.ui.kit.sidebar")
  if not ok then return nil end
  return sidebar.register_foreign({
    name = name,
    position = position,
    win = function()
      return adapter.get_winid()
    end,
    hide = function()
      adapter.close()
    end,
    show = function()
      adapter.open_cwd()
    end,
  })
end

---The tree window may have appeared: say so once per window.
---@param adapter FiletreeAdapter
---@param name string
local function appeared(adapter, name)
  local win = adapter.get_winid()
  if not win or not vim.api.nvim_win_is_valid(win) or win == _known_win then return end
  -- registered on every appearance: the side can change between two of them (a toggle at the other position)
  local handle = register(adapter, name)
  if not handle then return end
  _handle = handle
  _known_win = win
  handle:shown()
end

---@param config FiletreeKitSlotConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  if type(adapter.get_winid) ~= "function" or type(adapter.close) ~= "function" then return end
  local name = config.name or DEFAULT_NAME

  M.teardown()
  _augroup = au.group("filetree_kit_slot", true)

  au.acmd({ "BufWinEnter", "WinEnter" }, {
    group = _augroup,
    desc = "[filetree] Tell the kit sidebar slots the tree appeared",
    callback = function()
      vim.schedule(function()
        appeared(adapter, name)
      end)
    end,
  })

  au.acmd("WinClosed", {
    group = _augroup,
    desc = "[filetree] Tell the kit sidebar slots the tree went away",
    callback = function(event)
      if _known_win and tonumber(event.match) == _known_win then
        local handle = _handle
        _known_win = nil
        vim.schedule(function()
          if handle then handle:hidden() end
        end)
      end
    end,
  })

  -- a tree that is already open when this runs
  vim.schedule(function()
    appeared(adapter, name)
  end)
end

function M.teardown()
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
  if _handle then
    pcall(_handle.unregister, _handle)
    _handle = nil
  end
  _known_win = nil
end

return M
