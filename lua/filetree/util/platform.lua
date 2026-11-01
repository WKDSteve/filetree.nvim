---@module 'filetree.util.platform'
--- Cross-platform detection utilities.
---
--- Base OS detectors (`is_windows`/`is_wsl`/`is_mac`/`is_linux`) delegate to
--- `lib.nvim.cross.platform.*` (a hard dependency — see `filetree/commands.lua`,
--- required unconditionally from `filetree/init.lua`, so there is no reduced
--- mode without it to fall back to). `has_executable()`/`get_cwd()` have no
--- lib.nvim equivalent and stay local; `current()` delegates to
--- `lib.nvim.cross.platform.is()`, its unified selector.

local cross_is_windows = require("lib.nvim.cross.platform.is_windows")
local cross_is_wsl = require("lib.nvim.cross.platform.is_wsl")
local cross_is_macos = require("lib.nvim.cross.platform.is_macos")
local cross_is_linux = require("lib.nvim.cross.platform.is_linux")
local cross_is = require("lib.nvim.cross.platform.is")

local M = {}

---@return boolean
function M.is_windows()
  return cross_is_windows()
end

---@return boolean
function M.is_wsl()
  return cross_is_wsl()
end

---@return boolean
function M.is_mac()
  return cross_is_macos()
end

---@return boolean
function M.is_linux()
  return cross_is_linux()
end

---@return "windows"|"wsl"|"mac"|"linux"
function M.current()
  -- lib.nvim.cross.platform.is() always resolves to one of these four
  -- (falling back to "linux" itself when nothing else matched), so there is
  -- no fifth case to compose locally.
  local platform = cross_is() ---@type "windows"|"wsl"|"macos"|"linux"
  if platform == "macos" then return "mac" end
  return platform
end

---Return true when `name` is found in PATH.
---@param name string
---@return boolean
function M.has_executable(name)
  return vim.fn.executable(name) == 1
end

---The ripgrep binary to start. A Scoop shim (`...\shims\rg.exe` next to an
---`rg.shim` naming the real binary) is resolved to the binary it points at.
---
---The shim is a process of its own between the editor and ripgrep. libuv puts
---the processes it starts into a kill-on-close job object, but children of
---those processes may break away from it, and a shim killed (scan timeout,
---editor exit) right after it created ripgrep left ripgrep behind: a search
---from a refs spec was found still alive hours after its editor exited,
---holding the editor's inherited stdout, so `scripts/test.sh | tail` never
---saw EOF. Started directly, ripgrep is the job member and dies with it.
---
---A Chocolatey (shimgen) shim has no side file; its target is looked up in
---the package folder next to its `bin` (`lib/ripgrep/tools/**/rg.exe`, see
---`M.chocolatey_target`).
---
---Limits: a shim that cannot be resolved is started by name, with the same
---risk. A Scoop shim that also adds arguments (an `args = ...` line) is started by
---name too, so those arguments are never dropped.
---@return string
function M.rg_binary()
  local exe = vim.fn.exepath("rg")
  if exe == "" then return "rg" end
  local shim = exe:gsub("%.[eE][xX][eE]$", "") .. ".shim"
  if vim.fn.filereadable(shim) == 0 then return M.chocolatey_target(exe) or "rg" end
  local target
  for _, line in ipairs(vim.fn.readfile(shim)) do
    if line:match("^%s*args%s*=") then return "rg" end
    target = target or line:match('^%s*path%s*=%s*"([^"]+)"') or line:match("^%s*path%s*=%s*(%S+)")
  end
  if target and vim.fn.executable(target) == 1 then return target end
  return "rg"
end

---@internal
---The real `rg.exe` behind a Chocolatey shim: `<root>/bin/rg.exe` stands for
---`<root>/lib/ripgrep/tools/**/rg.exe`. nil when `exe` is not in a `bin` folder
---next to such a package folder.
---@param exe string  the path `exepath("rg")` found
---@return string|nil
function M.chocolatey_target(exe)
  local bin = vim.fs.dirname(exe)
  if not bin or vim.fs.basename(bin) ~= "bin" then return nil end
  local tools = vim.fs.dirname(bin) .. "/lib/ripgrep/tools"
  if vim.fn.isdirectory(tools) == 0 then return nil end
  local found = vim.fn.globpath(tools, "**/rg.exe", true, true)
  table.sort(found)
  local target = found[#found]
  if target and vim.fn.executable(target) == 1 then return target end
  return nil
end

---Return the current working directory (never nil).
---@return string
function M.get_cwd()
  local uv = vim.uv or vim.loop
  return (uv and uv.cwd and uv.cwd()) or vim.fn.getcwd()
end

return M
