---@module 'filetree.registry'
---@brief Register sources, decorators and actions for the tree.
---@description
--- A thin re-export of `lib.nvim.tree.registry` (LUA-03): the lists live there, so that a plugin can
--- register without loading filetree.nvim. This module is the name a user and the docs go by;
--- `require("filetree").source` / `.decorator` / `.action` and the `sources` / `decorators` / `actions`
--- options of `setup()` end up here.
---
--- Key responsibilities:
--- - Hand `source`, `decorator`, `action`, `list`, `get` and `subscribe` through unchanged
--- - Own the entries that came from `setup()`, so a second `setup()` replaces them instead of adding
---
--- What an entry means is defined by the types in `filetree.@types.native`, not here.

local M = {}

---@return table
local function lib()
  local ok, mod = pcall(require, "lib.nvim.tree.registry")
  if not ok then
    error(
      "filetree.nvim: registering sources, decorators and actions needs a newer lib.nvim "
        .. "(the module lib.nvim.tree.registry is missing) -- update lib.nvim",
      3
    )
  end
  return mod
end

---Register a source: it supplies the nodes of one view. Needs `name` and `root()`.
---A second registration under the same name replaces the first.
---@param entry Filetree.Source
---@return fun(): boolean unregister
function M.source(entry)
  return lib().source(entry)
end

---Register a decorator: badges on nodes. Needs `name`, `get()` and `subscribe()`.
---@param entry Filetree.Decorator
---@return fun(): boolean unregister
function M.decorator(entry)
  return lib().decorator(entry)
end

---Register an action: something to do with the node under the cursor or the selection. Needs `name`
---and `run()`.
---@param entry Filetree.Action
---@return fun(): boolean unregister
function M.action(entry)
  return lib().action(entry)
end

---The registered entries of one kind, in registration order.
---@param kind "source"|"decorator"|"action"
---@return table[]
function M.list(kind)
  return lib().list(kind)
end

---@param kind "source"|"decorator"|"action"
---@param name string
---@return table|nil
function M.get(kind, name)
  return lib().get(kind, name)
end

---Follow registrations and removals (`ev = { kind, name, entry?, replaced? }`).
---@param fn fun(ev: table)
---@return fun() unsubscribe
function M.subscribe(fn)
  return lib().subscribe(fn)
end

---@type (fun(): boolean)[]  The unregister functions of the entries the last setup() brought.
local from_setup = {}

---@type table<string, fun(entry: table): fun(): boolean>
local BY_OPTION = { sources = M.source, decorators = M.decorator, actions = M.action }

---Register what `setup({ sources, decorators, actions })` lists, replacing what the previous `setup()`
---registered. An entry that is refused is skipped and reported; the others still register.
---@param opts { sources?: Filetree.Source[], decorators?: Filetree.Decorator[], actions?: Filetree.Action[] }
---@return string[] issues  One line per refused entry, empty when all registered.
function M.apply_setup(opts)
  for _, remove in ipairs(from_setup) do
    remove()
  end
  from_setup = {}
  local issues = {}
  for _, option in ipairs({ "sources", "decorators", "actions" }) do
    local entries = opts[option]
    if entries ~= nil and type(entries) ~= "table" then
      issues[#issues + 1] = ("option '%s' must be a list, got %s"):format(option, type(entries))
    elseif entries then
      for i, entry in ipairs(entries) do
        local ok, result = pcall(BY_OPTION[option], entry)
        if ok then
          from_setup[#from_setup + 1] = result
        else
          issues[#issues + 1] = ("option '%s[%d]': %s"):format(option, i, tostring(result))
        end
      end
    end
  end
  return issues
end

return M
