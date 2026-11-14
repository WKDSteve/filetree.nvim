---@module 'filetree.native.keys'
---@brief Kept for callers of the first stages: the tree's keys are the action table now.
---@description
--- The keys of the own tree come from `filetree.native.action` (one table with `needs` / `when`,
--- read by the cheatsheet and the context menu as well). This module only forwards.

local action = require("filetree.native.action")

local M = {}

---`<CR>` on a row: a folder opens or closes, a file opens in an editor window.
---@param view Filetree.View
---@param mode? FiletreeOpenMode
function M.activate(view, mode)
  action.activate(view, mode)
end

---Bind the keys of a view's buffer (the action table).
---@param view Filetree.View
---@param buf integer
function M.attach(view, buf)
  action.attach(view, buf)
end

return M
