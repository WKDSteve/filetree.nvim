---@module 'filetree.roots'
--- Root providers: another plugin says which directory a file's root is, for
--- the folders it knows -- a case folder inside a larger repository, say --
--- ahead of the marker walk. The first provider with an answer wins, in
--- registration order; a provider that raises, or answers with something that
--- is not an existing directory, is skipped.
---
--- Asked by `cwd_mode` (every mode's root, so `project` holds the provider's
--- root instead of the repository around it) and by `util.target_dir` (the
--- root cwd_sync and auto_reveal move to when cwd_mode is off). `lock` and
--- `manual` are not affected: an explicit pin always wins.
---
--- Kept apart from the feature modules on purpose, like `create_names`: a
--- plugin can register at its own setup, before or after filetree's, without
--- filetree being set up or any feature being enabled.
---
--- ```lua
--- require("filetree.roots").register("casedesk", function(path)
---   local case = require("casedesk.registry").owning(path)
---   return case and case.dir or nil
--- end)
--- ```

local M = {}

---@alias FiletreeRootProvider fun(path: string): string|nil

---@type { id: string, fn: FiletreeRootProvider }[]
local providers = {}

--- Register (or replace, by `id`) a provider.
---@param id string
---@param fn FiletreeRootProvider
function M.register(id, fn)
  assert(
    type(id) == "string" and id ~= "",
    "filetree.roots.register: id must be a non-empty string"
  )
  assert(type(fn) == "function", "filetree.roots.register: fn must be a function")
  for _, p in ipairs(providers) do
    if p.id == id then
      p.fn = fn
      return
    end
  end
  providers[#providers + 1] = { id = id, fn = fn }
end

--- Drop the provider registered under `id`; a no-op for an unknown one.
---@param id string
function M.unregister(id)
  for i, p in ipairs(providers) do
    if p.id == id then
      table.remove(providers, i)
      return
    end
  end
end

--- Whether any provider is registered (lets callers skip the call entirely).
---@return boolean
function M.any()
  return providers[1] ~= nil
end

--- The root a provider gives for `path` (a file or a directory), or nil when
--- none has one. The answer is returned as the provider gave it; callers
--- canonicalize it the way they canonicalize their own roots.
---@param path string
---@return string|nil
function M.resolve(path)
  if type(path) ~= "string" or path == "" then return nil end
  for _, p in ipairs(providers) do
    local ok, dir = pcall(p.fn, path)
    if ok and type(dir) == "string" and dir ~= "" and vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil
end

return M
