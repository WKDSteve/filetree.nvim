---@module 'filetree.integrations.explorer'
---@brief filetree.nvim's answer to "show this path in the tree" of `lib.nvim.explorer`, for every backend.
---@description
--- `lib.nvim.explorer` asks whoever signed in to show a path (`reveal`): a picker's "reveal in tree"
--- goes there and names no tree plugin. The built-in adapters of lib.nvim for neo-tree, nvim-tree,
--- netrw and oil do not carry it, and filetree.nvim knows how to do it with each of them
--- (`adapter.open_reveal`). So filetree.nvim signs in under its own name, whatever backend runs.
---
--- With the own tree (`adapter = "native"`) the entry is the one `filetree.native.explorer` registers:
--- it also owns the tree buffer and answers `current_path` and `reload`. With any other backend the
--- entry registered here owns no buffer (those belong to the built-in adapters) and only reveals.

local M = {}

---The name filetree.nvim goes by in `lib.nvim.explorer` (the same for every backend).
M.NAME = "filetree"

---Show `path` in the tree of the active backend.
---@param path string  Absolute.
---@return boolean shown
function M.reveal(path)
  local adapter = require("filetree.adapter").get()
  if not adapter or type(adapter.open_reveal) ~= "function" then return false end
  return adapter.open_reveal(path) == true
end

---Sign in for the backend that is active. The own tree signs in by itself: nothing to do then.
---@param adapter FiletreeAdapter
---@return boolean registered
function M.register(adapter)
  if not adapter or adapter.name == "native" then return false end
  local ok, explorer = pcall(require, "lib.nvim.explorer")
  if not ok or type(explorer.register) ~= "function" then return false end
  if type(adapter.open_reveal) ~= "function" then
    -- a backend that cannot reveal must not leave the entry of an earlier setup behind
    pcall(explorer.unregister, M.NAME)
    return false
  end
  explorer.register({
    name = M.NAME,
    -- the buffers of the backend belong to its own adapter in lib.nvim: this entry owns none
    detect = function()
      return false
    end,
    reveal = M.reveal,
  })
  return true
end

return M
