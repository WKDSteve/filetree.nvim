---@module 'filetree.native.fs.watch'
---@brief Watch the folders a tree shows and say which of them changed.
---@description
--- The own tree stays current by being told which folder changed, and reading exactly that one again.
--- This module owns the libuv handles for it, turns raw events into "these folders are dirty", and
--- keeps a folder that is being hammered from costing a read per event.
---
--- Key responsibilities:
--- - `watch(dir)`: reference-counted; one recursive handle per root on Windows and macOS, one handle
---   per folder elsewhere (libuv cannot watch recursively there). Elsewhere with the helper process
---   (`filetree.native.fs.helper`) one recursive watch of the helper per root: a closed folder and a
---   folder made later are followed too. A helper that ends leaves each of its watches to a libuv
---   handle on the same folder (and reports that folder, so that it is read again); the folders below
---   it are followed again when they are read again
--- - Group events by the folder whose listing changed, wait for a short quiet, tell the subscribers
---   and fire `User FiletreeFsChanged` (`data.dirs`)
--- - Quarantine: a folder with an event storm is reported once, after it went quiet
--- - Every handle is known: `count()`, `release(path)` for an operation that must not find the path
---   held, `stop_all()`; `state()` is all of it at once, for whoever wants to show it
---
--- Which folders matter (loaded, shown) is the subscriber's business: this module reports all of them.

local list = require("filetree.native.fs.list")

local uv = vim.uv

local M = {}

local sysname = uv.os_uname().sysname
--- libuv watches a directory tree with one handle on these systems only.
M.native_recursive = sysname == "Windows_NT" or sysname == "Darwin"

---Does the helper process watch here (a system without recursive handles, and a helper to use)?
---@return boolean
local function by_helper()
  return not M.native_recursive and require("filetree.native.fs.helper").available()
end
M.by_helper = by_helper

-- `M.recursive`: is a folder below a watched one covered by that one's watch? Read live: with the
-- helper on a system without recursive handles it is true until the helper ends.
setmetatable(M, {
  __index = function(_, key)
    if key == "recursive" then return M.native_recursive or by_helper() end
  end,
})

---@class Filetree.Fs.Watch.Options
---@field debounce_ms integer  Quiet time before dirty folders are reported.
---@field storm integer  Events per second in one folder from which it is quarantined.
---@field quiet_ms integer  How long a quarantined folder has to be quiet before it is reported.

---@type Filetree.Fs.Watch.Options
local options = { debounce_ms = 100, storm = 200, quiet_ms = 2000 }

---@class Filetree.Fs.Watch.Entry
---@field handle? uv_fs_event_t  A libuv handle, or:
---@field helper? integer  the generation of a watch of the helper process.
---@field refs integer
---@field error? string

---@type table<string, Filetree.Fs.Watch.Entry>  watched folder -> its handle
local watchers = {}
---@type table<string, integer>  folder closed by release() -> the references still held on it
local released = {}
---@type table<integer, fun(dirs: string[])>
local subscribers = {}
local next_id = 1

---@type table<string, true>  folders whose listing changed since the last report
local dirty = {}
---@type table<string, { n: integer, since: integer, last: integer, held: boolean }>
local traffic = {}
---@type uv_timer_t|nil
local timer = nil

M.stats = { events = 0, reports = 0, quarantined = 0 }

---@param opts? { debounce_ms?: integer, storm?: integer, quiet_ms?: integer }
function M.configure(opts)
  options = vim.tbl_extend("force", options, opts or {})
end

local arm

---Report what is dirty and not held back; folders that went quiet are let go first.
local function report()
  local now = uv.now()
  local held = false
  for dir, t in pairs(traffic) do
    if t.held then
      if now - t.last >= options.quiet_ms then
        t.held = false
        dirty[dir] = true
        traffic[dir] = nil
      else
        held = true
      end
    elseif now - t.last >= 1000 then
      traffic[dir] = nil
    end
  end
  local dirs = vim.tbl_keys(dirty)
  dirty = {}
  if #dirs > 0 then
    table.sort(dirs)
    M.stats.reports = M.stats.reports + 1
    -- for whoever wants to know that the disk changed without being a tree: `data.dirs`
    pcall(
      vim.api.nvim_exec_autocmds,
      "User",
      { pattern = "FiletreeFsChanged", data = { dirs = dirs } }
    )
    for _, fn in pairs(subscribers) do
      local ok, err = pcall(fn, dirs)
      if not ok then
        vim.notify(
          "[filetree.native] watch subscriber failed: " .. tostring(err),
          vim.log.levels.WARN
        )
      end
    end
  end
  -- a held folder needs another look even when no further event arrives
  if held then arm(options.quiet_ms) end
end

---@param ms integer
arm = function(ms)
  if not timer then timer = assert(uv.new_timer()) end
  timer:stop()
  timer:start(ms, 0, function()
    vim.schedule(report)
  end)
end

---One raw event: `filename` changed in the watched folder `watched` (a path relative to it, or nil
---when the system did not say). Exposed so that a storm can be fed in a spec.
---@param watched string
---@param filename? string
function M.on_event(watched, filename)
  local changed = watched
  if filename and filename ~= "" then
    -- the listing that changed is the one of the folder the entry lies in
    local full = list.norm(list.join(watched, (filename:gsub("\\", "/"))))
    changed = list.parent(full) or watched
  end
  M.on_changed(changed)
end

---One folder whose listing changed (what the helper process reports, and what `on_event` works out).
---@param changed string  Normalized.
function M.on_changed(changed)
  M.stats.events = M.stats.events + 1
  local now = uv.now()
  local t = traffic[changed]
  if not t or (not t.held and now - t.since >= 1000) then
    t = { n = 0, since = now, last = now, held = false }
    traffic[changed] = t
  end
  t.n, t.last = t.n + 1, now
  if t.held then return end
  if t.n > options.storm then
    t.held = true
    dirty[changed] = nil
    M.stats.quarantined = M.stats.quarantined + 1
    arm(options.quiet_ms)
    return
  end
  dirty[changed] = true
  arm(options.debounce_ms)
end

local open_handle

---A watch of the helper process on `dir` and below. Nil when the helper cannot take it.
---@param dir string
---@return Filetree.Fs.Watch.Entry|nil
local function open_helper(dir)
  local helper = require("filetree.native.fs.helper")
  ---@type Filetree.Fs.Watch.Entry
  local entry = { refs = 0 }
  local gen = helper.request("watch", dir, function(kind, payload)
    if kind == "changed" and type(payload) == "table" then
      for _, changed in ipairs(payload) do
        M.on_changed(list.norm(changed))
      end
    elseif kind == "watching" then
      -- A libuv handle watches from the call on; the helper only once it has read the request.
      -- What came or went in between is caught by reading the folder once more.
      M.on_changed(dir)
    elseif kind == "error" then
      entry.error = tostring(payload)
    elseif kind == "lost" then
      -- the helper ended: a libuv handle on the same folder from now on, and the folder is read
      -- again (what changed below it in the meantime would be missed otherwise)
      entry.helper = nil
      if watchers[dir] == entry then
        local fallback, err = open_handle(dir)
        if fallback then
          entry.handle = fallback.handle
        else
          entry.error = err
        end
        M.on_changed(dir)
      end
      return false
    end
    return true
  end)
  if not gen then return nil end
  entry.helper = gen
  return entry
end

---@param dir string
---@return Filetree.Fs.Watch.Entry|nil entry
---@return string|nil err
local function open(dir)
  if by_helper() then
    local entry = open_helper(dir)
    if entry then return entry, nil end
  end
  return open_handle(dir)
end

---A libuv handle on `dir` (recursive where the system can).
---@param dir string
---@return Filetree.Fs.Watch.Entry|nil entry
---@return string|nil err
open_handle = function(dir)
  local handle, err = uv.new_fs_event()
  if not handle then return nil, tostring(err) end
  local ok, start_err = handle:start(
    dir,
    { recursive = M.native_recursive },
    function(event_err, filename, events)
      if event_err then
        local entry = watchers[dir]
        if entry then entry.error = tostring(event_err) end
        return
      end
      -- A listing changes when an entry comes, goes or is renamed. `change` alone is a file's
      -- content, or a folder's timestamp after something in it changed (which has its own event).
      if type(events) == "table" and events.change and not events.rename then return end
      M.on_event(dir, filename)
    end
  )
  if not ok or ok ~= 0 then
    if not handle:is_closing() then handle:close() end
    return nil, tostring(start_err or ok)
  end
  return { handle = handle, refs = 0 }, nil
end

---@param dir string
local function close(dir)
  local entry = watchers[dir]
  if not entry then return end
  watchers[dir] = nil
  if entry.helper then
    require("filetree.native.fs.helper").drop(entry.helper, "unwatch")
    entry.helper = nil
  end
  local handle = entry.handle
  if not handle then return end
  pcall(handle.stop, handle)
  if not handle:is_closing() then pcall(handle.close, handle) end
end

---Watch a folder. On a system with recursive handles a folder below one that is watched already takes
---no handle of its own.
---@param dir string  Normalized.
---@return fun() unwatch  Gives the reference back; the handle closes with the last one. Safe to call twice.
---@return string|nil err  Why the folder is not watched, when it is not.
function M.watch(dir)
  if M.recursive then
    for watched in pairs(watchers) do
      if watched ~= dir and list.inside(watched, dir) then return M.watch(watched) end
    end
  end
  local entry = watchers[dir]
  if not entry then
    local err
    entry, err = open(dir)
    if not entry then
      return function() end, err
    end
    watchers[dir] = entry
  end
  entry.refs = entry.refs + 1
  local done = false
  return function()
    if done then return end
    done = true
    local current = watchers[dir]
    if current then
      current.refs = current.refs - 1
      if current.refs <= 0 then close(dir) end
    elseif released[dir] then
      -- closed for an operation: the reference is given back there, so resume() does not revive it
      released[dir] = released[dir] - 1
      if released[dir] <= 0 then released[dir] = nil end
    end
  end,
    nil
end

---Be told which folders changed (normalized paths, sorted), a short quiet after the events.
---@param fn fun(dirs: string[])
---@return fun() unsubscribe
function M.subscribe(fn)
  local id = next_id
  next_id = id + 1
  subscribers[id] = fn
  return function()
    subscribers[id] = nil
  end
end

---Is `dir` watched, by a handle of its own or by a recursive one above it? A cached listing of a
---folder that is not covered may be stale without anybody having been told.
---@param dir string  Normalized.
---@return boolean
function M.covers(dir)
  if watchers[dir] then return true end
  if M.recursive then
    for watched in pairs(watchers) do
      if list.inside(watched, dir) then return true end
    end
  end
  return false
end

---How many handles are open.
---@return integer
function M.count()
  return vim.tbl_count(watchers)
end

---The watched folders, sorted.
---@return string[]
function M.watched()
  local out = vim.tbl_keys(watchers)
  table.sort(out)
  return out
end

---What this module holds right now, as plain data (a copy: changing it changes nothing here).
---@return Filetree.Fs.WatchState
function M.state()
  local out = {
    recursive = M.recursive,
    by_helper = by_helper(),
    watchers = {},
    released = {},
    quarantined = {},
    changed = {},
    stats = vim.deepcopy(M.stats),
  }
  for dir, entry in pairs(watchers) do
    out.watchers[#out.watchers + 1] =
      { dir = dir, refs = entry.refs, error = entry.error, helper = entry.helper ~= nil or nil }
  end
  for dir, refs in pairs(released) do
    out.released[#out.released + 1] = { dir = dir, refs = refs }
  end
  for dir, t in pairs(traffic) do
    if t.held then out.quarantined[#out.quarantined + 1] = dir end
  end
  for dir in pairs(dirty) do
    out.changed[#out.changed + 1] = dir
  end
  local function by_dir(a, b)
    return a.dir < b.dir
  end
  table.sort(out.watchers, by_dir)
  table.sort(out.released, by_dir)
  table.sort(out.quarantined)
  table.sort(out.changed)
  return out
end

---Close every handle that holds `path` or something below it, for an operation that renames, moves or
---deletes it (an open handle on a folder keeps Windows from letting go of it).
---@param path string  Normalized.
---@return fun() resume  Opens the handles again, with the references they had; folders that are gone stay closed.
---@return integer count  Handles closed.
function M.release(path)
  local mine = {}
  for dir, entry in pairs(watchers) do
    if list.inside(path, dir) then
      mine[#mine + 1] = dir
      released[dir] = entry.refs
    end
  end
  for _, dir in ipairs(mine) do
    close(dir)
  end
  local count = #mine
  local function resume()
    for _, dir in ipairs(mine) do
      local refs = released[dir]
      released[dir] = nil
      if refs and refs > 0 and not watchers[dir] then
        local entry = open(dir)
        if entry then
          entry.refs = refs
          watchers[dir] = entry
        end
      end
    end
    mine = {}
  end
  return resume, count
end

---Close every handle and forget what was pending. Subscribers stay.
function M.stop_all()
  for _, dir in ipairs(vim.tbl_keys(watchers)) do
    close(dir)
  end
  dirty, traffic, released = {}, {}, {}
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
end

return M
