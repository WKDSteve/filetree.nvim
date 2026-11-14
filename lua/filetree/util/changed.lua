---@module 'filetree.util.changed'
---@brief Announce a file operation that is done: `User FiletreeChanged` with `{ op, from, to }`.
---@description
--- The last link of the operation pipeline. Whoever shows files reacts to what changed instead of
--- reading everything again: the own tree reads exactly the folders `from` and `to` lie in.
---
---   op    "create" | "move" | "copy" | "delete"
---   from  the path before (move, copy, delete), nil for create
---   to    the path after (create, move, copy), nil for delete
---
--- A move covers a rename. Emitted after the operation succeeded; a failed one changed nothing.

local M = {}

---@alias Filetree.Changed.Op "create"|"move"|"copy"|"delete"

---@param op Filetree.Changed.Op
---@param from? string
---@param to? string
function M.emit(op, from, to)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "FiletreeChanged",
    modeline = false,
    data = { op = op, from = from, to = to },
  })
end

return M
