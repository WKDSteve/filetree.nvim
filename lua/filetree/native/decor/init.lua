---@module 'filetree.native.decor'
---@brief The decorators of the own tree: who has a badge for which node, and when to draw again.
---@description
--- A decorator (`filetree.registry`, see `Filetree.Decorator`) knows something about paths or node ids:
--- a git state, a diagnostics count, a test result. This module asks every registered one while the
--- tree draws and adds up what lies below a folder, so a folder that was never opened still shows it.
---
--- Key responsibilities:
--- - Follow the registry: decorators registered before or after the tree opened, and removed ones
--- - Keep a `filetree.native.decor.store` per decorator, fed by its `all()` and by the keys it emits
--- - `badges(node, is_dir)`: what to draw on one row, the folder roll-up included
--- - Ask for a redraw when a decorator says something changed (coalesced to one per tick)
---
--- Nothing here draws: `filetree.native.view` places the badges. A decorator that raises is switched
--- off for the session and named once; the tree keeps drawing.

local store_mod = require("filetree.native.decor.store")
local notify = require("filetree.util.notify").create("[filetree.native]")

local M = {}

---@class Filetree.Decor.Active
---@field entry Filetree.Decorator
---@field store Filetree.Decor.Store
---@field samples table<string, Filetree.Badge>  status -> a badge that carries it, for a folder's roll-up
---@field stop? fun()
---@field broken? boolean

---@type table<string, Filetree.Decor.Active>
local active = {}
---@type string[]  Names in registration order.
local order = {}
---@type fun()|nil
local unsubscribe_registry = nil
---@type fun()|nil  Asks every open view to draw again.
local redraw = nil
local redraw_pending = false

local function request_redraw()
  if redraw_pending or not redraw then return end
  redraw_pending = true
  vim.schedule(function()
    redraw_pending = false
    if redraw then redraw() end
  end)
end

---@param item Filetree.Decor.Active
---@param what string
---@param err any
local function fail(item, what, err)
  if item.broken then return end
  item.broken = true
  notify.warn(
    ("decorator %s failed in %s and is off for this session: %s"):format(
      item.entry.name,
      what,
      tostring(err)
    )
  )
end

---@param item Filetree.Decor.Active
---@param key string
---@param badge Filetree.Badge|nil
local function remember(item, key, badge)
  if type(badge) ~= "table" then badge = nil end
  if badge and badge.status then item.samples[badge.status] = badge end
  item.store:set(key, badge)
end

---Read everything a decorator has, when it can say (`all()`); else forget what was known.
---@param item Filetree.Decor.Active
local function reload(item)
  local all = item.entry.all
  if type(all) ~= "function" then
    item.store:replace({})
    return
  end
  local ok, map = pcall(all)
  if not ok then
    fail(item, "all()", map)
    return
  end
  if type(map) ~= "table" then map = {} end
  for _, badge in pairs(map) do
    if type(badge) == "table" and badge.status then item.samples[badge.status] = badge end
  end
  item.store:replace(map)
end

---@param entry Filetree.Decorator
local function attach(entry)
  local name = entry.name
  if active[name] then M.detach(name) end
  ---@type Filetree.Decor.Active
  local item = { entry = entry, store = store_mod.new({ severity = entry.severity }), samples = {} }
  active[name] = item
  order[#order + 1] = name
  reload(item)
  local ok, stop = pcall(entry.subscribe, function(keys)
    if item.broken or active[name] ~= item then return end
    if type(keys) == "table" then
      for _, key in ipairs(keys) do
        local got, badge = pcall(entry.get, key)
        if not got then
          fail(item, "get()", badge)
          return
        end
        remember(item, key, badge)
      end
    else
      reload(item)
    end
    request_redraw()
  end)
  if not ok then
    fail(item, "subscribe()", stop)
  elseif type(stop) == "function" then
    item.stop = stop
  end
end

---Stop following one decorator.
---@param name string
function M.detach(name)
  local item = active[name]
  if not item then return end
  active[name] = nil
  for i, known in ipairs(order) do
    if known == name then
      table.remove(order, i)
      break
    end
  end
  if item.stop then pcall(item.stop) end
end

---Start following the registry. Safe to call again; `on_redraw` replaces the earlier one.
---@param on_redraw fun()  Called (at most once per tick) when badges changed.
function M.start(on_redraw)
  redraw = on_redraw
  if unsubscribe_registry then return end
  local registry = require("filetree.registry")
  for _, entry in ipairs(registry.list("decorator")) do
    attach(entry)
  end
  unsubscribe_registry = registry.subscribe(function(ev)
    if ev.kind ~= "decorator" then return end
    if ev.entry then
      attach(ev.entry)
    else
      M.detach(ev.name)
    end
    request_redraw()
  end)
end

---Stop every decorator and forget what they said.
function M.stop()
  if unsubscribe_registry then
    unsubscribe_registry()
    unsubscribe_registry = nil
  end
  for _, name in ipairs(vim.list_slice(order)) do
    M.detach(name)
  end
  redraw = nil
end

---@class Filetree.Decor.Drawn : Filetree.Badge
---@field slot "name"|"sign"|"badge"|"column"|"line"
---@field priority integer
---@field name string  The decorator it came from.

---@param item Filetree.Decor.Active
---@param key string
---@return Filetree.Badge|nil
local function rolled_up(item, key)
  local mode = item.entry.roll_up
  if not mode then return nil end
  local rollup = item.store:rollup(key)
  if not rollup then return nil end
  local sample = rollup.status and item.samples[rollup.status] or nil
  if mode == "count" then
    return { text = tostring(rollup.total), hl = sample and sample.hl, status = rollup.status }
  end
  if sample then return { text = sample.text, hl = sample.hl, status = rollup.status } end
  return rollup.status and { text = rollup.status, status = rollup.status } or nil
end

---What the decorators have for one row, in registration order.
---@param node Filetree.Node
---@param is_dir boolean
---@return Filetree.Decor.Drawn[]
function M.badges(node, is_dir)
  local out = {}
  for _, name in ipairs(order) do
    local item = active[name]
    if item and not item.broken then
      local entry = item.entry
      local key = entry.key == "id" and node.id or node.path
      if type(key) == "string" then
        local ok, badge = pcall(entry.get, key)
        if not ok then
          fail(item, "get()", badge)
          badge = nil
        end
        if type(badge) ~= "table" and is_dir and entry.key ~= "id" then
          badge = rolled_up(item, key)
        end
        if type(badge) == "table" and (badge.text or badge.hl) then
          out[#out + 1] = {
            text = badge.text,
            hl = badge.hl,
            status = badge.status,
            count = badge.count,
            slot = entry.slot or "badge",
            priority = entry.priority or 0,
            name = name,
          }
        end
      end
    end
  end
  return out
end

---The names of the decorators being followed, in order. For health and specs.
---@return string[]
function M.names()
  return vim.list_slice(order)
end

return M
