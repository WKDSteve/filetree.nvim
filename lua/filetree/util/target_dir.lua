---@module 'filetree.util.target_dir'
--- Shared "what project root does this file belong to" resolver.
---
--- Used by `cwd_sync` (to choose what to chdir/reveal to) and by
--- `auto_reveal` (to know where to re-root the tree for a file outside its
--- current root, when nothing else is already handling that -- see its
--- `follow_root` option). Kept in one place so both features agree on the
--- same directory for the same file: cwd_sync's chdir and auto_reveal's
--- re-root target the identical path, so either or both running for the
--- same buffer switch is redundant at worst, never conflicting.
---
--- Resolution order, first hit wins:
---   0. A root provider registered with `filetree.roots` (a plugin that knows
---      a folder is its own root). cwd_mode asks the same providers first, so
---      this step only matters while cwd_mode is off.
---   1. cwd_mode's marker walk (shared with `util.root`, find_files, grep,
---      git_status, so nothing that is "the project" can disagree). Skipped
---      when cwd_mode is disabled or torn down.
---   2. Nearest ancestor containing a configured stable marker (default
---      `.git`), via a cached lib.nvim finder. Disabled with
---      `root_markers = false`.
---   3. The project_root feature's broader marker set, when `use_project_root`.
---   4. The file's own parent directory.

local find_root = require("lib.nvim.fs.find_root")
local path = require("filetree.util.path")

local M = {}

---@class FiletreeTargetDirOpts
---@field root_markers? string[]|false  Default: { ".git" }. false disables step 2.
---@field use_project_root? boolean  Default: true.

---Build a resolver function bound to `opts`, ready to call per file.
---@param opts FiletreeTargetDirOpts|nil
---@return fun(file: string): string
function M.new(opts)
  opts = opts or {}

  local root_finder = nil
  local markers = opts.root_markers
  if markers == nil then markers = { ".git" } end
  if markers ~= false then root_finder = find_root({ markers = markers }) end

  ---@param file string
  ---@return string
  return function(file)
    local roots = require("filetree.roots")
    if roots.any() then
      local provided = roots.resolve(file)
      if provided then return path.normalize(provided) end
    end
    local mode = require("filetree.features").require("cwd_mode")
    if mode and type(mode.resolve) == "function" then
      local ok, root = pcall(mode.resolve, file)
      if ok and root and root ~= "" then return root end
    end
    if root_finder then
      local ok, root = pcall(root_finder.find, file)
      if ok and root and root ~= "" then return root end
    end
    if opts.use_project_root ~= false then
      local registry = require("filetree.features")
      local proot = registry.require("project_root")
      if proot then
        local ok, root = pcall(proot.find, file)
        if ok and root and root ~= "" then return root end
      end
    end
    return path.parent(file)
  end
end

return M
