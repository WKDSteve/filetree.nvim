---@module 'filetree.native.fs.list'
---@brief Read one directory, once, for every tree view that shows it.
---@description
--- The own tree is lazy: a folder is read when it is opened, never before. This module is that one read
--- (`uv.fs_scandir`) and the cache in front of it, shared by all views, so two tabs with a tree on the
--- same root read each folder once.
---
--- Key responsibilities:
--- - `list(dir, cb)` asynchronous, `list_sync(dir)` for callers that must answer at once (reveal a path)
--- - One spelling per path (`norm`, `join`): `/`-separated, drive letter upper case
--- - Single flight: a second request for a folder that is being read waits for the first
--- - `invalidate(dir?)`: forget a folder (or all) so that the next request reads again
--- - A state per folder that was asked for (`state_of`, `states`): `loading` while it is read, `fresh`
---   once its listing is cached, `dirty` after it was invalidated and before it is read again, `error`
---   when the last read failed (with the message)
--- - A generation per folder: a read that was overtaken by `invalidate` is not cached and not handed
---   out; the folder is read once more first
---
--- No watcher here. The callers of the tree ask through `filetree.native.fs.service`.

local uv = vim.uv

local M = {}

---@class Filetree.Fs.Entry
---@field name string
---@field path string  Normalized absolute path.
---@field is_dir boolean  A directory, or a link to one.
---@field is_link? boolean
---@field link_to? string  Raw link target, as read.
---@field link_broken? boolean  The target of the link does not resolve.

---@type table<string, Filetree.Fs.Entry[]>
local cache = {}
---@type table<string, (fun(entries?: Filetree.Fs.Entry[], err?: string))[]>
local pending = {}

---@alias Filetree.Fs.State "fresh"|"loading"|"dirty"|"error"

---@type table<string, Filetree.Fs.State>  Every folder that was asked for and not forgotten.
local state = {}
---@type table<string, string>  Why the last read of a folder failed.
local errors = {}
---@type table<string, integer>  Counted up by `invalidate`: a read that started before is overtaken.
local generation = {}

--- Reads one request makes at most while the folder keeps being invalidated under it.
local MAX_READS = 3

--- How often a directory was really read (not served from the cache). For specs and health.
M.stats = { scans = 0 }

---One spelling for a path: `/`-separated, drive letter upper case, no trailing slash (a bare root keeps
---it: `/`, `C:/`).
---@param path string
---@return string
function M.norm(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^(%a):", function(drive)
    return drive:upper() .. ":"
  end)
  if #path > 1 and path:sub(-1) == "/" and not path:match("^%a:/$") then path = path:sub(1, -2) end
  return path
end

---@param dir string  Normalized.
---@param name string
---@return string
function M.join(dir, name)
  if dir:sub(-1) == "/" then return dir .. name end
  return dir .. "/" .. name
end

---The folder a normalized path lies in, or nil at the top.
---@param path string
---@return string|nil
function M.parent(path)
  local parent = path:match("^(.*)/[^/]+$")
  if not parent then return nil end
  if parent == "" then return "/" end
  if parent:match("^%a:$") then return parent .. "/" end
  return parent
end

---Is `path` the folder `root` or something below it? Both normalized.
---@param root string
---@param path string
---@return boolean
function M.inside(root, path)
  if path == root then return true end
  -- with the separator: `/a/bc` is not inside `/a/b`; a bare root (`/`, `C:/`) ends in it already
  local prefix = M.join(root, "")
  return path:sub(1, #prefix) == prefix
end

---@param path string
---@return string
function M.basename(path)
  return path:match("([^/]+)$") or path
end

---@param handle uv_fs_t
---@param dir string
---@return Filetree.Fs.Entry[]
local function read(handle, dir)
  local out = {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end
    local full = M.join(dir, name)
    ---@type Filetree.Fs.Entry
    local entry = { name = name, path = full, is_dir = kind == "directory" }
    if kind == "link" then
      local stat = uv.fs_stat(full)
      entry.is_link = true
      entry.link_to = uv.fs_readlink(full)
      entry.link_broken = stat == nil
      entry.is_dir = stat ~= nil and stat.type == "directory"
    elseif kind ~= "file" and kind ~= "directory" then
      -- a file system that does not say (some network mounts): ask
      local stat = uv.fs_stat(full)
      entry.is_dir = stat ~= nil and stat.type == "directory"
    end
    out[#out + 1] = entry
  end
  return out
end

---Read a directory now. Served from the cache when it was read before.
---@param dir string  Normalized.
---@return Filetree.Fs.Entry[]|nil entries
---@return string|nil err
function M.list_sync(dir)
  local hit = cache[dir]
  if hit then return hit, nil end
  local handle, err = uv.fs_scandir(dir)
  if not handle then
    local why = tostring(err or ("cannot read " .. dir))
    -- a read without blocking that is on its way decides the state when it answers
    if not pending[dir] then
      state[dir], errors[dir] = "error", why
    end
    return nil, why
  end
  M.stats.scans = M.stats.scans + 1
  local entries = read(handle, dir)
  cache[dir] = entries
  if not pending[dir] then
    state[dir], errors[dir] = "fresh", nil
  end
  return entries, nil
end

---Read a directory without blocking. `cb` runs on the main loop; at once when the folder is cached.
---@param dir string  Normalized.
---@param cb fun(entries?: Filetree.Fs.Entry[], err?: string)
function M.list(dir, cb)
  local hit = cache[dir]
  if hit then
    cb(hit, nil)
    return
  end
  if pending[dir] then
    table.insert(pending[dir], cb)
    return
  end
  pending[dir] = { cb }
  state[dir] = "loading"
  local reads = 0
  local function scan()
    local asked = generation[dir] or 0
    reads = reads + 1
    uv.fs_scandir(dir, function(err, handle)
      local entries = nil
      if handle then
        M.stats.scans = M.stats.scans + 1
        entries = read(handle, dir)
      end
      vim.schedule(function()
        local overtaken = (generation[dir] or 0) ~= asked
        if overtaken and reads < MAX_READS then
          -- invalidated while it was read: what came back may be from before the change. Those who
          -- wait asked for the folder as it is, so it is read once more before anybody is answered.
          scan()
          return
        end
        local waiting = pending[dir] or {}
        pending[dir] = nil
        local why = nil
        if overtaken and entries then
          -- a folder that changes faster than it can be read: those who wait are answered with the
          -- last listing, which is not kept; the next request reads again
          state[dir], errors[dir] = "dirty", nil
        elseif entries then
          cache[dir] = entries
          state[dir], errors[dir] = "fresh", nil
        else
          why = tostring(err or ("cannot read " .. dir))
          state[dir], errors[dir] = "error", why
        end
        for _, fn in ipairs(waiting) do
          fn(entries, why)
        end
      end)
    end)
  end
  scan()
end

---The folders being read right now (a read without blocking that has not answered yet), sorted.
---@return string[]
function M.reading()
  local out = vim.tbl_keys(pending)
  table.sort(out)
  return out
end

---The cached entries of a directory, or nil when it was not read (or was invalidated).
---@param dir string
---@return Filetree.Fs.Entry[]|nil
function M.cached(dir)
  return cache[dir]
end

---The state of a folder: nil for one that was never asked for (or was forgotten with everything).
---@param dir string  Normalized.
---@return Filetree.Fs.State|nil state
---@return string|nil err  Why the last read failed, for `error`.
function M.state_of(dir)
  return state[dir], errors[dir]
end

---@class Filetree.Fs.States
---@field fresh integer  Folders whose listing is cached.
---@field loading integer  Folders being read.
---@field dirty integer  Folders that were invalidated and not read again yet.
---@field error integer  Folders whose last read failed.
---@field errors { dir: string, error: string }[]  Those, sorted by folder.

---How many folders are in which state, and the ones that failed.
---@return Filetree.Fs.States
function M.states()
  ---@type Filetree.Fs.States
  local out = { fresh = 0, loading = 0, dirty = 0, error = 0, errors = {} }
  for dir, what in pairs(state) do
    out[what] = out[what] + 1
    if what == "error" then
      out.errors[#out.errors + 1] = { dir = dir, error = errors[dir] or "" }
    end
  end
  table.sort(out.errors, function(a, b)
    return a.dir < b.dir
  end)
  return out
end

---Forget one directory, or every one. A folder that is being read is read again before its read
---answers (see `list`).
---@param dir? string
function M.invalidate(dir)
  if dir then
    cache[dir] = nil
    -- a folder nobody asked for has nothing to forget, and gets no state
    if state[dir] == nil then return end
    generation[dir] = (generation[dir] or 0) + 1
    if not pending[dir] then
      state[dir], errors[dir] = "dirty", nil
    end
    return
  end
  cache = {}
  local reading = {}
  for folder in pairs(pending) do
    reading[folder] = "loading"
    generation[folder] = (generation[folder] or 0) + 1
  end
  -- everything else is forgotten for good: no state, as if it had never been asked for
  state, errors = reading, {}
  for folder in pairs(generation) do
    if not pending[folder] then generation[folder] = nil end
  end
end

return M
