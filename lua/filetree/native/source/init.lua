---@module 'filetree.native.source'
---@brief The sources the own tree brings itself, and their registration.
---@description
--- The built-in sources are ordinary entries of the registry (`filetree.registry`): the tree shows
--- them the way it shows a source of another plugin, and a source registered under one of their names
--- before `setup()` is left alone.
---
--- Key responsibilities:
--- - `register()` / `unregister()`: put the built-in sources into the registry, and take them out
--- - `NAMES`: their order in the view bar
---
--- The directory tree (`files`) is not in this list: `filetree.native.view` owns it.

local M = {}

--- The built-in sources, in the order of the view bar.
---@type string[]
M.NAMES = { "buffers", "git", "symbols", "diagnostics" }

---@type table<string, fun(): boolean>  name -> take our entry out again
local removers = {}

---Register every built-in source that is not registered yet. Safe to call again.
function M.register()
  local registry = require("filetree.registry")
  for _, name in ipairs(M.NAMES) do
    if not removers[name] and registry.get("source", name) == nil then
      removers[name] = registry.source(require("filetree.native.source." .. name).source())
    end
  end
end

---Take the built-in sources out of the registry (a source somebody registered over one of them stays).
function M.unregister()
  for name, remove in pairs(removers) do
    remove()
    removers[name] = nil
  end
end

return M
