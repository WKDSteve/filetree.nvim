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

---Bring the tree up to date after a file operation that was announced with `emit`.
---
---The own tree answers `FiletreeChanged` itself and reads the folders `from` and `to` lie in; asking
---it for a refresh on top would read every folder it has open again. Every other backend knows
---nothing of the event, so there the refresh of everything is the way.
---
---A feature that calls this has to have announced what it did (`emit` here, a move through
---`util.mutate`, a copy or a delete through `util.hooks`), or the own tree hears of the change
---only from its watcher.
---@param adapter FiletreeAdapter?
function M.refresh(adapter)
  if not adapter or type(adapter.refresh) ~= "function" then return end
  if adapter.name == "native" then return end
  pcall(adapter.refresh)
end

return M
