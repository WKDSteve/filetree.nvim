---@module 'filetree.util.decorate'
---@brief Let a feature hand its per-node marks to the own tree as a decorator.
---@description
--- On a foreign tree a feature draws its marks itself: it walks the rendered lines and sets extmarks,
--- and has to do so again after every redraw of that tree. The own tree (`adapter = "native"`) draws
--- decorators with each line, so there a feature only says what it knows and the tree does the rest.
---
--- Key responsibilities:
--- - `by_path(adapter, spec)`: a decorator fed with a map path -> badge; nil on any other backend
--- - `by_node(adapter, spec, fn)`: a decorator that answers from the node (a symlink, a name), for what
---   is no property of a path
---
--- Both return a handle with `remove()`; a feature keeps it from `setup()` to `teardown()` and keeps
--- its extmark path for every other backend.

local M = {}

---@class Filetree.Decorate.Paths
---@field set fun(map: table<string, Filetree.Badge>)  Replace every badge; paths in any spelling.
---@field remove fun()

---@class Filetree.Decorate.Nodes
---@field changed fun(keys?: string[])  Ask the tree to draw again (all rows, or the given paths).
---@field remove fun()

---@param adapter FiletreeAdapter|nil
---@return boolean
function M.native(adapter)
  return adapter ~= nil and adapter.name == "native"
end

---A decorator keyed by path, for the own tree only.
---@param adapter FiletreeAdapter|nil
---@param spec { name: string, slot?: string, priority?: integer, roll_up?: string|false, severity?: string[] }
---@return Filetree.Decorate.Paths|nil  nil when the active backend is not the own tree.
function M.by_path(adapter, spec)
  if not M.native(adapter) then return nil end
  local norm = require("filetree.native.fs.list").norm
  ---@type table<string, Filetree.Badge>
  local badges = {}
  ---@type fun(keys?: string[])|nil
  local emit = nil
  local unregister = require("filetree.registry").decorator(vim.tbl_extend("force", spec, {
    get = function(path)
      return badges[path]
    end,
    all = function()
      return badges
    end,
    subscribe = function(on_change)
      emit = on_change
      return function()
        emit = nil
      end
    end,
  }))
  return {
    set = function(map)
      local out = {}
      for path, badge in pairs(map) do
        out[norm(path)] = badge
      end
      badges = out
      if emit then emit() end
    end,
    remove = function()
      unregister()
      badges, emit = {}, nil
    end,
  }
end

---A decorator that answers from the node itself, for the own tree only.
---@param adapter FiletreeAdapter|nil
---@param spec { name: string, slot?: string, priority?: integer }
---@param fn fun(node: Filetree.Node, key: string): Filetree.Badge|nil  Called while the tree draws: no I/O.
---@return Filetree.Decorate.Nodes|nil
function M.by_node(adapter, spec, fn)
  if not M.native(adapter) then return nil end
  ---@type fun(keys?: string[])|nil
  local emit = nil
  local unregister = require("filetree.registry").decorator(vim.tbl_extend("force", spec, {
    get = function(key, node)
      if not node then return nil end
      return fn(node, key)
    end,
    subscribe = function(on_change)
      emit = on_change
      return function()
        emit = nil
      end
    end,
  }))
  return {
    changed = function(keys)
      if emit then emit(keys) end
    end,
    remove = function()
      unregister()
      emit = nil
    end,
  }
end

return M
