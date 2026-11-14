---@module 'filetree.native.action.table'
---@brief One table of the actions of a tree view: which applies to a node, which a key runs, and why not.
---@description
--- Pure: no buffer, no window, no keymap. The dispatcher (`filetree.native.action`) fills a table per
--- view and binds its keys; the cheatsheet, the context menu and `:Filetree action` read the same table,
--- so a key, its row in `?` and its menu entry cannot disagree (rule UI-20).
---
--- Key responsibilities:
--- - `new()`: an empty table; `add(action, origin)` / `remove(name)` / `get(name)` / `list()`
--- - `check(action, node, ctx)`: whether an action applies to a node, and the one-line reason when not
--- - `resolve(lhs, node, ctx)`: the action a key runs on a node (rank below), or the reason none does
--- - `applicable(node, ctx)`: every action that applies to a node, in rank order
--- - `keys()`: every left-hand side some action claims
---
--- Rank among the actions of one key, first wins: an action of the view's source before every other
--- one, then the higher `priority`, then the origin (a filetree feature before another plugin's
--- action before the tree's own), then the order of registration. A source can so take a key
--- (`d` = diff in a test view) without a list of exceptions anywhere.
---
--- `needs` (all have to hold): `path` (the node is a file or folder on disk), `file`, `dir`,
--- `mutable` (the view's source lets files be changed), `kind:<k>` (the node's kind), `source:<s>`
--- (the view shows that source). `when(node, ctx)` says the rest.

local M = {}

---@alias Filetree.Action.Origin "source"|"feature"|"plugin"|"builtin"

---@class Filetree.Action
---@field name string  Unique within a table.
---@field key? string|string[]  Left-hand side(s) in the tree buffer.
---@field desc? string  One line for the cheatsheet, the menu and the command catalog.
---@field needs? string[]
---@field when? fun(node: table, ctx: Filetree.Action.Ctx): boolean
---@field priority? integer  Among actions on the same key (default 0).
---@field mutates? boolean  It changes files.
---@field menu? boolean  false keeps it out of the context menu (the tree's own folding keys).
---@field run fun(nodes: table[], ctx: Filetree.Action.Ctx, args?: table<string, string>)
---@field origin? Filetree.Action.Origin  Set by `add`.
---@field seq? integer  Set by `add`: order of registration.

---@class Filetree.Action.Ctx
---@field source? string  The source the view shows ("files").
---@field mutable? boolean  false: the source does not let files be changed.
---@field view? table  The view, for actions that act on it.

---@type table<Filetree.Action.Origin, integer>
local ORIGIN_RANK = { source = 0, feature = 1, plugin = 2, builtin = 3 }

---@class Filetree.Action.Table
---@field private _by_name table<string, Filetree.Action>
---@field private _seq integer
---@field private _canon fun(lhs: string): string
local Table = {}
Table.__index = Table

---@param lhs string
---@return string
local function same(lhs)
  return lhs
end

---@param canon? fun(lhs: string): string  One spelling per key (`<C-f>` and `<C-F>` are one key);
---  keys are compared through it. Default: as written.
---@return Filetree.Action.Table
function M.new(canon)
  return setmetatable({ _by_name = {}, _seq = 0, _canon = canon or same }, Table)
end

---Whether `action` claims the key `lhs`, whichever way either is spelled.
---@param action Filetree.Action
---@param lhs string
---@return boolean
function Table:claims(action, lhs)
  local want = self._canon(lhs)
  for _, key in ipairs(M.keys_of(action)) do
    if self._canon(key) == want then return true end
  end
  return false
end

---The one spelling of a key this table compares by.
---@param lhs string
---@return string
function Table:canon(lhs)
  return self._canon(lhs)
end

---The left-hand sides of an action, as a list.
---@param action Filetree.Action
---@return string[]
function M.keys_of(action)
  local key = action.key
  if type(key) == "string" then return key ~= "" and { key } or {} end
  if type(key) == "table" then return key end
  return {}
end

---Add an action, or replace the one of the same name.
---@param action Filetree.Action
---@param origin Filetree.Action.Origin
---@return Filetree.Action entry  A copy with `origin` and `seq` set.
function Table:add(action, origin)
  assert(type(action) == "table" and type(action.name) == "string", "action: needs a name")
  assert(type(action.run) == "function", "action " .. action.name .. ": needs run()")
  assert(ORIGIN_RANK[origin], "action " .. action.name .. ": unknown origin " .. tostring(origin))
  local old = self._by_name[action.name]
  local entry = setmetatable({ origin = origin }, { __index = action })
  if old then
    entry.seq = old.seq
  else
    self._seq = self._seq + 1
    entry.seq = self._seq
  end
  self._by_name[action.name] = entry
  return entry
end

---@param name string
---@return boolean removed
function Table:remove(name)
  if not self._by_name[name] then return false end
  self._by_name[name] = nil
  return true
end

---Take out every action of one origin (a feature's keys are read again as a whole).
---@param origin Filetree.Action.Origin
function Table:remove_origin(origin)
  for name, entry in pairs(self._by_name) do
    if entry.origin == origin then self._by_name[name] = nil end
  end
end

---@param name string
---@return Filetree.Action|nil
function Table:get(name)
  return self._by_name[name]
end

---@param a Filetree.Action
---@param b Filetree.Action
---@return boolean
local function before(a, b)
  local sa, sb = a.origin == "source", b.origin == "source"
  if sa ~= sb then return sa end
  local pa, pb = a.priority or 0, b.priority or 0
  if pa ~= pb then return pa > pb end
  local oa, ob = ORIGIN_RANK[a.origin], ORIGIN_RANK[b.origin]
  if oa ~= ob then return oa < ob end
  return a.seq < b.seq
end

---Every action, in rank order.
---@return Filetree.Action[]
function Table:list()
  local out = {}
  for _, entry in pairs(self._by_name) do
    out[#out + 1] = entry
  end
  table.sort(out, before)
  return out
end

---Every key some action claims, once each (in the spelling of the action of highest rank), sorted.
---@return string[]
function Table:keys()
  local seen, out = {}, {}
  for _, entry in ipairs(self:list()) do
    for _, lhs in ipairs(M.keys_of(entry)) do
      local id = self._canon(lhs)
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = lhs
      end
    end
  end
  table.sort(out)
  return out
end

---Whether one requirement holds.
---@param need string
---@param node table
---@param ctx Filetree.Action.Ctx
---@return boolean ok
---@return string|nil reason
local function holds(need, node, ctx)
  if need == "path" then
    return node.path ~= nil, "needs a file or folder"
  elseif need == "file" then
    return node.path ~= nil and node.kind ~= "dir", "needs a file"
  elseif need == "dir" then
    return node.path ~= nil and node.kind == "dir", "needs a folder"
  elseif need == "mutable" then
    return ctx.mutable ~= false, "this view does not change files"
  end
  local kind = need:match("^kind:(.+)$")
  if kind then return node.kind == kind, "needs a " .. kind end
  local source = need:match("^source:(.+)$")
  if source then return ctx.source == source, "only in the " .. source .. " view" end
  return false, "unknown requirement " .. need
end

---Whether `action` applies to `node`.
---@param action Filetree.Action
---@param node table|nil  nil: no node under the cursor.
---@param ctx Filetree.Action.Ctx
---@return boolean ok
---@return string|nil reason  One line when it does not apply.
function M.check(action, node, ctx)
  ctx = ctx or {}
  local needs = action.needs or {}
  if node == nil then
    if #needs > 0 or action.when then return false, "no entry under the cursor" end
    return true, nil
  end
  for _, need in ipairs(needs) do
    local ok, reason = holds(need, node, ctx)
    if not ok then return false, reason end
  end
  if action.when then
    local ok, applies = pcall(action.when, node, ctx)
    if not ok then return false, "its check failed: " .. tostring(applies) end
    if not applies then return false, "does not apply here" end
  end
  return true, nil
end

---The action `lhs` runs on `node`: the first in rank order that applies.
---@param lhs string
---@param node table|nil
---@param ctx Filetree.Action.Ctx
---@param skip? table<string, true>  Names to pass over (the ones running already on this key).
---@return Filetree.Action|nil action
---@return string|nil reason  When none applies: "<lhs>: <why the first candidate does not>".
function Table:resolve(lhs, node, ctx, skip)
  local first_reason = nil
  for _, entry in ipairs(self:list()) do
    if self:claims(entry, lhs) and not (skip and skip[entry.name]) then
      local ok, reason = M.check(entry, node, ctx)
      if ok then return entry, nil end
      first_reason = first_reason or reason
    end
  end
  if not first_reason then return nil, lhs .. ": no action on this key" end
  return nil, lhs .. ": " .. first_reason
end

---Every action that applies to `node`, in rank order.
---@param node table|nil
---@param ctx Filetree.Action.Ctx
---@return Filetree.Action[]
function Table:applicable(node, ctx)
  local out = {}
  for _, entry in ipairs(self:list()) do
    if M.check(entry, node, ctx) then out[#out + 1] = entry end
  end
  return out
end

---Whether `action` is the one its key `lhs` reaches on `node` (another one of higher rank may take
---the key there).
---@param lhs string
---@param action Filetree.Action
---@param node table|nil
---@param ctx Filetree.Action.Ctx
---@return boolean
function Table:reaches(lhs, action, node, ctx)
  local winner = self:resolve(lhs, node, ctx)
  return winner ~= nil and winner.name == action.name
end

return M
