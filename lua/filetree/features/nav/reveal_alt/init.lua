---@module 'filetree.features.nav.reveal_alt'
---@brief Reveal the alternate buffer (#) in the tree.
---@description
--- Binds a key (default `B`) in the tree buffer.  On activation it resolves
--- the alternate file of the editor window (`#` there, not in the tree window),
--- validates that the file is readable, and calls `adapter.open_reveal()` to
--- navigate the tree to it — adjusting the root if the file is outside the
--- current tree root.
---
--- Mirrors the `B` mapping in the user's neotree config (analog to `:e #`).
---
--- Config:
---   enabled  boolean
---   keymap   string?   Key in tree buffer (default "B").

local notify = require("filetree.util.notify").create("[filetree.reveal_alt]")
local bind = require("filetree.util.bind")

local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.reveal_alt` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
}

---The alternate file the key means: the one of the editor window.
---
---`#` belongs to a window. Asked in the tree window it is whatever that window showed before the
---tree (the buffer it was split off from, or nothing at all, in which case `expand()` throws E194),
---never the file the user had open before the current one.
---@param adapter FiletreeAdapter
---@return string  Absolute path, "" when there is none.
function M.alternate(adapter)
  local function read()
    local ok, alt = pcall(vim.fn.expand, "#:p")
    return ok and type(alt) == "string" and alt or ""
  end
  local tree_win = adapter.get_winid and adapter.get_winid() or nil
  if tree_win and tree_win <= 0 then tree_win = nil end
  local win = require("filetree.util.buffer").find_editor_win(tree_win)
  if win and vim.api.nvim_win_is_valid(win) then return vim.api.nvim_win_call(win, read) end
  return read()
end

---@param config FiletreeRevealAltConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end

  bind.bind("reveal_alt", config, {
    {
      name = "reveal",
      field = "keymap",
      default = "B",
      desc = "reveal alternate buffer in tree",
      rhs = function()
        local alt = M.alternate(adapter)
        if not alt or alt == "" then
          notify.warn("No alternate buffer")
          return
        end
        if vim.fn.filereadable(alt) ~= 1 then
          notify.warn("Alternate buffer is not a readable file: " .. alt)
          return
        end
        if type(adapter.open_reveal) == "function" then
          local ok, err = pcall(adapter.open_reveal, alt, 0)
          if not ok then notify.warn("Reveal failed: " .. tostring(err)) end
        else
          notify.warn("Adapter does not support open_reveal")
        end
      end,
    },
  })
end

function M.teardown() end

return M
