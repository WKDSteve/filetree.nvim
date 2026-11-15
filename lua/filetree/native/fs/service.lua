---@module 'filetree.native.fs.service'
---@brief The one place the own tree asks the file system through.
---@description
--- What is behind it may change (the Lua stages today, a helper process for the deep work later); who
--- asks here does not care. A folder is read once for every view (`fs.list`), and each folder that
--- was asked for has a state:
---
---   (never asked) ──list──► loading ──answer──► fresh ──invalidate──► dirty ──list──► loading ...
---                              │                                         ▲
---                              └──failed──► error ──list──► loading      │
---                              └──invalidate while reading: read again ──┘ (stays loading)
---
--- - `list(dir, cb)`, `list_sync(dir)`: the entries of one folder, from the cache when it is fresh
--- - `cached(dir)`: the entries when they are fresh, nothing is read
--- - `invalidate(dir?)`: the folder (or every one) changed; the next request reads again
--- - `status(dir)`: `fresh`, `loading`, `dirty`, `error` (with the message), nil when never asked
--- - `states()`: how many folders are in which state, and the ones that failed
--- - `reading()`: the folders being read right now
--- - `deep`, `watch`: the deep search and the watcher, as modules (loaded when first asked for)
---
--- Paths are spelled by `fs.list` (`norm`, `join`, `parent`, `inside`); that is no question to the
--- file system and stays there.

local list = require("filetree.native.fs.list")

local M = {}

---Read a directory without blocking. `cb` runs on the main loop; at once when the folder is fresh.
---@param dir string  Normalized.
---@param cb fun(entries?: Filetree.Fs.Entry[], err?: string)
function M.list(dir, cb)
  list.list(dir, cb)
end

---Read a directory now. Served from the cache when the folder is fresh.
---@param dir string  Normalized.
---@return Filetree.Fs.Entry[]|nil entries
---@return string|nil err
function M.list_sync(dir)
  return list.list_sync(dir)
end

---The entries of a folder that is fresh; nil for every other state. Nothing is read.
---@param dir string  Normalized.
---@return Filetree.Fs.Entry[]|nil
function M.cached(dir)
  return list.cached(dir)
end

---A folder changed (or, without one, everything is to be forgotten): the next request reads again.
---@param dir? string  Normalized.
function M.invalidate(dir)
  list.invalidate(dir)
end

---The state of a folder.
---@param dir string  Normalized.
---@return Filetree.Fs.State|nil state  nil: never asked for.
---@return string|nil err  Why the last read failed, for `error`.
function M.status(dir)
  return list.state_of(dir)
end

---How many folders are in which state, and the ones that failed.
---@return Filetree.Fs.States
function M.states()
  return list.states()
end

---The folders being read right now, sorted.
---@return string[]
function M.reading()
  return list.reading()
end

-- `deep` and `watch` are loaded when somebody asks for them: a tree that never searches starts no
-- search module, and one with `native.watch = false` no watcher.
return setmetatable(M, {
  __index = function(self, key)
    if key == "deep" or key == "watch" then
      local mod = require("filetree.native.fs." .. key)
      rawset(self, key, mod)
      return mod
    end
    return nil
  end,
})
