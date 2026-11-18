---@module 'filetree.native.fs.helper'
---@brief The helper process of the own tree (tier 3): filetree's side of `lib.nvim.fs.helper`.
---@description
--- `helper/` of this repository builds `filetree-helper`, a small read-only program (Rust) that lists the
--- files below a folder with the ignore rules of ripgrep, adds up the size of a folder and watches a
--- folder tree, also on Linux. The client that starts it and talks to it lives in lib.nvim
--- (`lib.nvim.fs.helper`), so that every plugin shares one process; `lib.nvim.fs.fast` lists, sizes and
--- watches through it with fallbacks. This module is what stays with the program's own repository:
---
--- - the option `native.fs.helper`, handed to lib.nvim as its mode: `"auto"` (default) uses the program
---   below `stdpath("data")/filetree-helper/` when it is there, except on a machine with
---   `NVIM_MACHINE_ROLE=workstation` (nothing native runs there until the EDR check clears it); `false`
---   never uses one; a path uses exactly that program
--- - `build()`: puts the program there, built with cargo or downloaded from the release
--- - `health()` for `:checkhealth filetree`
--- - the client calls (`request`, `drop`, `tell`, `on`, `stop`, `configure`, `state`, `find`,
---   `available`), passed through to lib.nvim, so the tree's own modules keep their calls
---
--- A program built before protocol 3 answers through `require('filetree.native.fs.helper').on`; that
--- is lib.nvim's `on` too, so it still works until `build()` replaces it.

local lib = require("lib.nvim.fs.helper")

local uv = vim.uv

local M = {}

--- The protocol the client speaks (`filetree-helper --version` names its own).
M.PROTOCOL = lib.PROTOCOL

---@alias Filetree.Fs.Helper.Mode "auto"|false|string
---@alias Filetree.Fs.Helper.State Lib.Fs.Helper.State

local this = debug.getinfo(1, "S").source:sub(2)
--- The repository this file belongs to (`lua/filetree/native/fs/helper.lua` is five levels down).
local repo = vim.fn.fnamemodify(this, ":p:h:h:h:h:h"):gsub("\\", "/")

---The option `native.fs.helper`, nil when it is not set.
---@return Filetree.Fs.Helper.Mode|nil
local function option()
  local ok, native = pcall(require, "filetree.native")
  local fs = ok and type(native.options) == "function" and native.options().fs or nil
  if type(fs) == "table" then return fs.helper end
  return nil
end

-- the tree's option decides for every plugin while filetree is loaded
lib.set_mode_provider(option)

M.binary_name = lib.binary_name
M.default_path = lib.default_path
M.workstation = lib.workstation
M.find = lib.find
M.available = lib.available
M.request = lib.request
M.drop = lib.drop
M.tell = lib.tell
M.on = lib.on
M.stop = lib.stop
M.configure = lib.configure
M.state = lib.state

---@return Filetree.Fs.Helper.Mode
function M.mode()
  return lib.mode()
end

--- Where the CI publishes the programs (`.github/workflows/helper.yml`, a release per tag `helper-v*`).
M.RELEASES = "https://github.com/WKDSteve/filetree.nvim/releases/latest/download/"

---The name of the release asset for this system, or nil when the CI builds none for it.
---@param uname? { sysname: string, machine: string }  Default: this machine (specs pass others).
---@return string|nil
function M.asset_name(uname)
  uname = uname or uv.os_uname()
  local os_name = ({ Windows_NT = "windows", Linux = "linux", Darwin = "macos" })[uname.sysname]
  local arch = ({
    x86_64 = "x86_64",
    AMD64 = "x86_64",
    x64 = "x86_64",
    arm64 = "aarch64",
    aarch64 = "aarch64",
  })[uname.machine]
  if not os_name or not arch then return nil end
  -- what the CI builds: Linux and Windows on x86_64, macOS on Apple silicon
  local built = { ["linux-x86_64"] = true, ["windows-x86_64"] = true, ["macos-aarch64"] = true }
  if not built[os_name .. "-" .. arch] then return nil end
  return ("filetree-helper-%s-%s%s"):format(os_name, arch, os_name == "windows" and ".exe" or "")
end

---Put the program where `"auto"` finds it (`stdpath("data")/filetree-helper/`): built with cargo when
---a Rust toolchain is there, else downloaded from the latest release. For the `build` step of a plugin
---manager; blocks. Refuses on the workstation (`NVIM_MACHINE_ROLE=workstation`).
---@param opts? { download?: boolean }  `download = true`: never build, `false`: never download.
---@return boolean ok
---@return string message
function M.build(opts)
  opts = opts or {}
  if M.workstation() then
    return false,
      "not on the workstation (NVIM_MACHINE_ROLE=workstation): nothing native before the EDR check"
  end
  -- a running program cannot be replaced on Windows
  M.stop()
  vim.fn.mkdir(lib.install_dir(), "p")
  local target = M.default_path()
  if opts.download ~= true and vim.fn.executable("cargo") == 1 then
    local manifest = repo .. "/helper/Cargo.toml"
    local result = vim
      .system({ "cargo", "build", "--release", "--manifest-path", manifest }, { text = true })
      :wait()
    if result.code ~= 0 then
      return false, "cargo build failed: " .. vim.trim(result.stderr or ""):sub(-400)
    end
    local built = repo .. "/helper/target/release/" .. M.binary_name()
    os.remove(target)
    local copied, err = uv.fs_copyfile(built, target)
    if not copied then return false, "cannot copy " .. built .. ": " .. tostring(err) end
  elseif opts.download ~= false then
    local asset = M.asset_name()
    if not asset then
      return false, "no release program for this system; install a Rust toolchain and build again"
    end
    if vim.fn.executable("curl") ~= 1 then return false, "neither cargo nor curl found" end
    local part = target .. ".part"
    local result = vim
      .system({
        "curl",
        "--fail",
        "--location",
        "--silent",
        "--show-error",
        "--output",
        part,
        M.RELEASES .. asset,
      }, { text = true })
      :wait()
    if result.code ~= 0 then
      os.remove(part)
      return false, "download failed: " .. vim.trim(result.stderr or "")
    end
    os.remove(target)
    local moved, err = os.rename(part, target)
    if not moved then return false, "cannot move the download into place: " .. tostring(err) end
    if uv.os_uname().sysname ~= "Windows_NT" then uv.fs_chmod(target, tonumber("755", 8)) end
  else
    return false, "cargo not found and downloading is off"
  end
  -- a program found later in the session is used from the next request on
  lib.configure(nil)
  return true, "filetree-helper installed: " .. target
end

---`:checkhealth filetree`: what the helper does on this machine.
---@param ok fun(msg: string)
---@param info fun(msg: string)
---@param warn fun(msg: string)
function M.health(ok, info, warn)
  local s = M.state()
  if s.lost then
    warn("native: the helper process " .. s.lost .. "; the Lua tiers serve this session")
  elseif s.exe then
    ok(
      ("native: helper process %s (%s)"):format(
        s.running and ("running, pid " .. tostring(s.pid)) or "found, starts on first need",
        s.exe
      )
    )
  else
    info("native: helper process " .. (s.off or "off"))
  end
end

return M
