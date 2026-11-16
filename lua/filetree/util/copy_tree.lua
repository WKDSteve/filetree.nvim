---@module 'filetree.util.copy_tree'
---@brief Copy a file, a symlink or a whole directory tree in-process, on lib.nvim's
--- `cross.fs.mutate` primitives (libuv, no shell, no program started). Shared by `copy_move` (paste of
--- a copy) and `safety.backup` (backup before a destructive operation), so both copy one way.
---
---   local copy_tree = require("filetree.util.copy_tree")
---   local ok, err = copy_tree.copy(src, dst)   -- dst must not exist yet

-- Central FS-mutation chokepoint (libuv-based, no shell). Retries transient Windows sharing errors
-- (EPERM/EACCES/EBUSY) that a raw uv.fs_copyfile would surface as a hard failure.
local fsops = require("lib.nvim.cross.fs.mutate")
local symlink = require("filetree.util.symlink")

local M = {}

---Recreate the symlink at `src` as a new symlink at `dst`, pointing at the same (possibly relative)
---target, instead of letting a plain file/directory copy dereference it. Two reasons this matters,
---not just fidelity: a dereferenced *directory* symlink would deep-copy whatever it points at
---(potentially huge, and unboundedly recursive through a symlink cycle -- `dir` below has no cycle
---guard because a real directory tree cannot contain one), and a dereferenced *file* symlink
---silently turns a link into an independent full copy of its target's content.
---@param src string
---@param dst string
---@return boolean ok
---@return string? err  libuv-style failure reason, when not ok
function M.symlink(src, dst)
  local target = (vim.uv or vim.loop).fs_readlink(src)
  if not target then return false, "could not read the symlink's own target" end
  return fsops.symlink(target, dst, vim.fn.isdirectory(src) == 1)
end

---Recursively copy the directory `src` to `dst` (shell-agnostic: works identically whether &shell
---is cmd.exe, PowerShell, or a POSIX shell). Symlinks inside are recreated, not followed.
---@param src string
---@param dst string
---@return boolean ok
---@return string? err  libuv-style failure reason of whichever entry failed first
function M.dir(src, dst)
  if vim.fn.mkdir(dst, "p") == 0 then return false, "could not create directory: " .. dst end
  for _, name in ipairs(vim.fn.readdir(src)) do
    local s = src .. "/" .. name
    local d = dst .. "/" .. name
    local ok, err
    if symlink.is_link(s) then
      ok, err = M.symlink(s, d)
    elseif vim.fn.isdirectory(s) == 1 then
      ok, err = M.dir(s, d)
    else
      ok, err = fsops.copy_file(s, d)
    end
    if not ok then return false, err end
  end
  return true, nil
end

---Copy `src` (a file, a symlink or a directory) to `dst`. No collision handling: the caller has
---already decided what to do about an existing `dst`.
---@param src string
---@param dst string
---@return boolean ok
---@return string? err  libuv-style failure reason, when not ok
function M.copy(src, dst)
  if symlink.is_link(src) then return M.symlink(src, dst) end
  if vim.fn.isdirectory(src) == 1 then return M.dir(src, dst) end
  local ok, err = fsops.copy_file(src, dst)
  return ok == true, err
end

return M
