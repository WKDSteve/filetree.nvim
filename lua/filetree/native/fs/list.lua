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
---
--- No watcher and no generations here; they belong to the fs service of the next stage.

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
  if not handle then return nil, tostring(err or ("cannot read " .. dir)) end
  M.stats.scans = M.stats.scans + 1
  local entries = read(handle, dir)
  cache[dir] = entries
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
  uv.fs_scandir(dir, function(err, handle)
    local entries = nil
    if handle then
      M.stats.scans = M.stats.scans + 1
      entries = read(handle, dir)
    end
    vim.schedule(function()
      local waiting = pending[dir] or {}
      pending[dir] = nil
      if entries then cache[dir] = entries end
      for _, fn in ipairs(waiting) do
        fn(entries, entries == nil and tostring(err or ("cannot read " .. dir)) or nil)
      end
    end)
  end)
end

---The cached entries of a directory, or nil when it was not read (or was invalidated).
---@param dir string
---@return Filetree.Fs.Entry[]|nil
function M.cached(dir)
  return cache[dir]
end

---Forget one directory, or every one.
---@param dir? string
function M.invalidate(dir)
  if dir then
    cache[dir] = nil
  else
    cache = {}
  end
end

return M
