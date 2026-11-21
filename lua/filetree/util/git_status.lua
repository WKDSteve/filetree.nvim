---@module 'filetree.util.git_status'
---@brief One `git status` per occasion, shared by everyone in filetree who asks.
---@description
--- The badges of `features.git_status` and the view git of the own tree both ask
--- `lib.nvim.git.status_porcelain_async` for the same repository, and each from several
--- events (opening the tree, entering its buffer, a write, focus). Every start of `git` costs
--- 50-500 ms on Windows, and on a large repository the status itself costs more. So a request
--- says how old an answer it can take, and this module:
---
--- - hands it the last answer when that one started late enough (`since`),
--- - lets it wait for the running `git status` when that one started late enough,
--- - otherwise starts a new one; a running one that is too old is stopped, and whoever waited for it
---   gets the new answer instead (newer is never worse for them).
---
--- `since` is a time on this module's clock (`M.now()`, ms): "the answer must come from a
--- `git status` started at or after this". A caller that knows of a change (a write, a git action,
--- focus back from a terminal) passes the time of the change; a caller that only wants to show
--- what is there (the tree opened, its buffer entered) passes nothing and takes an answer up to
--- `M.FRESH_MS` old. A failed status is never kept.
---
--- Answers come on the main loop (lib.nvim schedules them), each waiter exactly once, a raising
--- waiter never costs the others their answer.

local M = {}

---How old an answer may be for a caller that knows of no change (ms).
M.FRESH_MS = 2000

---This module's clock, in ms (fractions kept). Specs replace it.
---@return number
function M.now()
  return (vim.uv or vim.loop).hrtime() / 1e6
end

---@class Filetree.GitStatus.Waiter
---@field cb fun(map: table|nil, err: string|nil)
---@field cancelled boolean

---@class Filetree.GitStatus.Query
---@field started number
---@field handle { stop: fun() }|nil
---@field waiters Filetree.GitStatus.Waiter[]

---@class Filetree.GitStatus.Slot
---@field running Filetree.GitStatus.Query|nil
---@field last { started: number, map: table }|nil

---@type table<string, Filetree.GitStatus.Slot>
local slots = {}

---@param opts { dir: string, ignored?: boolean }
---@return string
local function key_of(opts)
  local dir = opts.dir:gsub("\\", "/"):gsub("/+$", "")
  dir = dir:gsub("^(%a):", function(d)
    return d:upper() .. ":"
  end)
  return dir .. (opts.ignored and "\0ignored" or "")
end

---@param waiter Filetree.GitStatus.Waiter
local function deliver(waiter, map, err)
  if waiter.cancelled then return end
  waiter.cancelled = true -- exactly once
  local ok, raised = pcall(waiter.cb, map, err)
  if not ok then
    vim.notify("[filetree] after git status: " .. tostring(raised), vim.log.levels.ERROR)
  end
end

---@param slot Filetree.GitStatus.Slot
---@param opts { dir: string, ignored?: boolean }
---@param waiters Filetree.GitStatus.Waiter[]
local function start(slot, opts, waiters)
  ---@type Filetree.GitStatus.Query
  local query = { started = M.now(), waiters = waiters }
  slot.running = query
  query.handle = require("lib.nvim.git").status_porcelain_async(
    { dir = opts.dir, ignored = opts.ignored },
    function(map, err)
      -- a superseded query was stopped and its waiters moved on: its answer goes nowhere
      if slot.running ~= query then return end
      slot.running = nil
      if map then slot.last = { started = query.started, map = map } end
      for _, waiter in ipairs(query.waiters) do
        deliver(waiter, map, err)
      end
    end
  )
end

---Ask for the status of `opts.dir` (`opts.ignored` adds ignored files).
---@param opts { dir: string, ignored?: boolean }
---@param since number|nil  The answer must come from a status started at or after this (`M.now()`
---  time); nil: up to `M.FRESH_MS` old.
---@param cb fun(map: table|nil, err: string|nil)  `map` as `lib.nvim.git.status_porcelain_async`
---  gives it, shared: read it, never change it.
---@return { stop: fun() } request  `stop()` drops this caller's answer; the status itself stops
---  when nobody waits for it any more.
function M.status(opts, since, cb)
  local key = key_of(opts)
  local slot = slots[key]
  if not slot then
    slot = {}
    slots[key] = slot
  end
  since = since or (M.now() - M.FRESH_MS)

  ---@type Filetree.GitStatus.Waiter
  local waiter = { cb = cb, cancelled = false }
  local request = {
    stop = function()
      if waiter.cancelled then return end
      waiter.cancelled = true
      local running = slot.running
      if not running then return end
      for _, w in ipairs(running.waiters) do
        if not w.cancelled then return end
      end
      -- nobody waits for it any more
      slot.running = nil
      if running.handle then pcall(running.handle.stop) end
    end,
  }

  if slot.last and slot.last.started >= since then
    local map = slot.last.map
    vim.schedule(function()
      deliver(waiter, map, nil)
    end)
    return request
  end

  local running = slot.running
  if running and running.started >= since then
    running.waiters[#running.waiters + 1] = waiter
    return request
  end

  local waiters = { waiter }
  if running then
    -- too old for this caller, so for its own waiters the new one is at least as good
    for _, w in ipairs(running.waiters) do
      if not w.cancelled then waiters[#waiters + 1] = w end
    end
    slot.running = nil
    if running.handle then pcall(running.handle.stop) end
  end
  start(slot, opts, waiters)
  return request
end

---Forget every answer and drop every waiter (specs; a test that swaps the clock).
function M._reset()
  for _, slot in pairs(slots) do
    if slot.running and slot.running.handle then pcall(slot.running.handle.stop) end
  end
  slots = {}
end

return M
