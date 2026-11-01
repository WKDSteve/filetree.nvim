---@module 'filetree.features.infra.hooks_api'
---@brief Public event hook system for filetree.nvim.
---@description
--- Provides a simple observable event emitter that other features and
--- third-party plugins can use to react to filetree lifecycle events.
---
--- Usage (from user config or other plugins):
---   local ft = require("filetree")
---   local hooks = ft.feature("hooks_api")
---   if hooks then
---     hooks.on("before_delete", function(data) ... end)
---   end
---
--- Wired today (via `filetree.util.hooks.emit`): `before_delete`/`after_delete`
--- (trash), `before_move`/`after_move` (move, and the cut half of copy_move),
--- `before_copy`/`after_copy` (copy_move). The rest are declared but have no
--- emit site yet.
---
--- Built-in events emitted by features:
---   before_delete   { path: string }
---   after_delete    { path: string, ok: boolean }
---   before_move     { src: string, dst: string }
---   after_move      { src: string, dst: string, ok: boolean }
---   before_copy     { src: string, dst: string }
---   after_copy      { src: string, dst: string, ok: boolean }
---   node_open       { path: string }
---   tree_open       {}
---   tree_close      {}
---   session_save    { path: string }
---   session_restore { path: string }
---   root_change     { old: string, new: string }
---   refresh         {}
---
--- API:
---   M.on(event, fn)      → handler_id (integer)
---   M.once(event, fn)    → handler_id
---   M.off(id)            → removed (boolean)
---   M.emit(event, data)  → called_count (integer)
---   M.clear(event?)      → remove all handlers for event (or all)

local notify = require("filetree.util.notify").create("[filetree.hooks]")

local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.hooks_api` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {}

-- ── Registry ──────────────────────────────────────────────────────────────────

---@class FiletreeHookHandler
---@field id     integer
---@field event  string
---@field fn     function
---@field once   boolean

local _next_id = 1
---@type table<integer, FiletreeHookHandler>
local _handlers = {}
---@type table<string, integer[]>  event → [ids]
local _by_event = {}

-- ── Public API ────────────────────────────────────────────────────────────────

---Register a handler for an event. Returns a handler id.
---@param event string
---@param fn    fun(data: table)
---@return integer id
function M.on(event, fn)
  local id = _next_id
  _next_id = _next_id + 1
  _handlers[id] = { id = id, event = event, fn = fn, once = false }
  _by_event[event] = _by_event[event] or {}
  table.insert(_by_event[event], id)
  return id
end

---Register a one-shot handler (auto-removed after first fire).
---@param event string
---@param fn    fun(data: table)
---@return integer id
function M.once(event, fn)
  local id = _next_id
  _next_id = _next_id + 1
  _handlers[id] = { id = id, event = event, fn = fn, once = true }
  _by_event[event] = _by_event[event] or {}
  table.insert(_by_event[event], id)
  return id
end

---Remove a handler by id.
---@param id integer
---@return boolean removed
function M.off(id)
  local h = _handlers[id]
  if not h then return false end
  _handlers[id] = nil
  local list = _by_event[h.event]
  if list then
    for i, eid in ipairs(list) do
      if eid == id then
        table.remove(list, i)
        break
      end
    end
  end
  return true
end

---Emit an event, calling all registered handlers.
---@param event string
---@param data  table?
---@return integer  Number of handlers called.
function M.emit(event, data)
  data = data or {}
  local ids = _by_event[event]
  if not ids or #ids == 0 then return 0 end

  local count = 0
  local to_remove = {}

  for _, id in ipairs(vim.list_slice(ids)) do -- copy so removals mid-loop are safe
    local h = _handlers[id]
    if h then
      count = count + 1
      local ok, err = pcall(h.fn, data)
      if not ok then
        vim.schedule(function()
          notify.warn(string.format("handler %d for '%s' error: %s", id, event, tostring(err)))
        end)
      end
      if h.once then to_remove[#to_remove + 1] = id end
    end
  end

  for _, id in ipairs(to_remove) do
    M.off(id)
  end
  return count
end

---Clear all handlers for a given event, or ALL handlers if event is nil.
---@param event? string
function M.clear(event)
  if event then
    local ids = _by_event[event] or {}
    for _, id in ipairs(ids) do
      _handlers[id] = nil
    end
    _by_event[event] = {}
  else
    _handlers = {}
    _by_event = {}
  end
end

---List all registered events.
---@return string[]
function M.events()
  local out = {}
  for ev in pairs(_by_event) do
    if _by_event[ev] and #_by_event[ev] > 0 then out[#out + 1] = ev end
  end
  table.sort(out)
  return out
end

---Count handlers registered for an event (or total if nil).
---@param event? string
---@return integer
function M.count(event)
  if event then
    local ids = _by_event[event] or {}
    local n = 0
    for _, id in ipairs(ids) do
      if _handlers[id] then n = n + 1 end
    end
    return n
  end
  local n = 0
  for _ in pairs(_handlers) do
    n = n + 1
  end
  return n
end

-- ── Setup / teardown ──────────────────────────────────────────────────────────

---@param config FiletreeHooksApiConfig
---@param _adapter FiletreeAdapter
function M.setup(config, _adapter)
  if not config.enabled then return end
  -- No adapter needed; hooks_api is a pure event bus.
  -- Reset state on re-setup so old handlers from a previous session don't linger.
  M.clear()
end

function M.teardown()
  M.clear()
end

return M
