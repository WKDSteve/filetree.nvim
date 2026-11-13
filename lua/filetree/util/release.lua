---@module 'filetree.util.release'
---@brief Let go of every directory handle on a path before it is renamed, moved or deleted.
---@description
--- Windows will not rename or delete a folder while a handle is open on it. Two kinds of handle can
--- hold one: neo-tree's watcher (released through `lib.nvim.neotree.watch`, a no-op unless the
--- handle_guard feature installed its registry) and the own tree's watcher
--- (`filetree.native.fs.watch`, only when that backend was loaded). Callers use this one function and
--- need to know neither.
---
---   local release = require("filetree.util.release")
---   local count, resume = release.path(src)
---   -- ... move / delete ...
---   resume()  -- the own tree's handles open again where their folders still exist

local neotree_watch = require("lib.nvim.neotree.watch")

local M = {}

---Close the handles that hold `path` or something below it.
---@param path string
---@return integer count  Handles closed, of both kinds.
---@return fun() resume  Opens the own tree's handles again; safe to call more than once.
function M.path(path)
  local count = neotree_watch.release(path) or 0
  local resume = function() end
  -- not loaded = the own tree never ran in this session, so it holds nothing
  local native = package.loaded["filetree.native.fs.watch"]
  if native then
    local norm = require("filetree.native.fs.list").norm(path)
    local native_resume, native_count = native.release(norm)
    count = count + (native_count or 0)
    resume = native_resume
  end
  return count, resume
end

---`path` for several paths at once.
---@param paths string[]
---@return integer count
---@return fun() resume
function M.paths(paths)
  local count, resumes = 0, {}
  for _, path in ipairs(paths) do
    local n, resume = M.path(path)
    count = count + n
    resumes[#resumes + 1] = resume
  end
  return count, function()
    for _, resume in ipairs(resumes) do
      resume()
    end
  end
end

return M
