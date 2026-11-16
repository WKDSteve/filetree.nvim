---@module 'filetree.features.infra.safety.backup'
---@brief File backup engine — copies files to a backup directory before destructive operations.

local notify = require("filetree.util.notify").create("[filetree.safety.backup]")
local path = require("filetree.util.path")
local globbable = require("lib.nvim.fs.globbable")

local M = {}

---@type FiletreeSafetyConfig
local _cfg = {}

---@type string  resolved backup directory
local _dir = ""

---Initialize and create the backup directory.
---@param config FiletreeSafetyConfig
function M.init(config)
  _cfg = config
  _dir = config.backup_dir and path.to_absolute(config.backup_dir)
    or (vim.fn.stdpath("data") .. "/filetree/backups")
  if vim.fn.isdirectory(_dir) == 0 then vim.fn.mkdir(_dir, "p") end
end

---Return a unique backup destination path for `src`.
---Format: <backup_dir>/<timestamp>_<basename>
---@param src string  Absolute source path.
---@return string
local function backup_path(src)
  local ts = os.date("%Y%m%d_%H%M%S")
  local base = path.basename(src)
  return _dir .. "/" .. ts .. "_" .. base
end

---Copy a file or a whole directory in-process (filetree.util.copy_tree, the same copy a paste
---uses): a backup starts no program. `xcopy` once asked whether a target that does not exist yet
---names a file or a directory, and with nobody to answer every backup failed.
---@param src string
---@param dst string
---@return boolean
local function copy(src, dst)
  return (require("filetree.util.copy_tree").copy(src, dst))
end

---Create a backup of `src`.
---@param src string  Absolute path of the file or directory to back up.
---@return string?    Path of the created backup, or nil on failure.
function M.create(src)
  if _cfg.dry_run then
    notify.info("[dry-run] would back up: " .. src)
    return src
  end
  if vim.fn.filereadable(src) == 0 and vim.fn.isdirectory(src) == 0 then
    notify.warn("backup: source does not exist: " .. src)
    return nil
  end
  local dst = backup_path(src)
  if not copy(src, dst) then
    notify.error("backup failed: " .. src .. " → " .. dst)
    return nil
  end
  M.prune()
  return dst
end

---Remove oldest backups when count exceeds max_backups.
function M.prune()
  local max = _cfg.max_backups or 5
  -- `_dir` is a filesystem path, not a pattern -- globbable() (XP-01) keeps
  -- an 8.3 short-name `~` component (a config.backup_dir under a Windows
  -- %TEMP%, for a profile name over eight characters) from being misread as
  -- a home-directory reference, which would make glob silently return an
  -- empty list here instead of the real backup files.
  local ok, files = pcall(vim.fn.glob, globbable(_dir) .. "/*", false, true)
  if not ok or not files then return end
  -- Sort by name (timestamp prefix ensures chronological order)
  table.sort(files)
  while #files > max do
    local oldest = table.remove(files, 1)
    if vim.fn.isdirectory(oldest) == 1 then
      pcall(vim.fn.delete, oldest, "rf")
    else
      pcall(vim.fn.delete, oldest)
    end
  end
end

---List all backups (sorted oldest→newest).
---@return string[]
function M.list()
  local ok, files = pcall(vim.fn.glob, globbable(_dir) .. "/*", false, true)
  if not ok or not files then return {} end
  table.sort(files)
  return files
end

return M
