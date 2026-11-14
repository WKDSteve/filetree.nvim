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

--- CDX: shells out to xcopy/cp -r here, while copy_move's own copy_dir()
--- copies recursively via lib.nvim.cross.fs.mutate.copy_file (libuv, no
--- shell). Possible consolidation onto the same primitive; out of scope
--- for this pass.
---Recursively copy a file or directory.
---A file is copied in-process; a directory with `xcopy` on Windows, `cp -r` elsewhere.
---@param src string
---@param dst string
---@return boolean
local function copy(src, dst)
  if vim.fn.isdirectory(src) == 0 then
    -- One file needs no program. On Windows it must not get one: `xcopy` asks whether a target that
    -- does not exist yet names a file or a directory (`/I` answers that for a directory source
    -- only), and with nobody to answer the backup of every single file failed.
    return (vim.uv.fs_copyfile(src, dst)) == true
  end
  local platform = require("filetree.util.platform")
  local run_argv = require("lib.nvim.cross.run_argv")
  local ok
  if platform.is_windows() and not platform.is_wsl() then
    ok = run_argv.run_blocking({ "xcopy", "/E", "/I", "/H", "/Y", src, dst })
  else
    ok = run_argv.run_blocking({ "cp", "-r", src, dst })
  end
  return ok or false
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
