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
--- - `build()`: puts the program there, built with cargo or downloaded from the release (blocks: the
---   build step of a plugin manager); `build_async()` does it in the background with a progress
---   indicator, cancellable (`:Filetree helper build`, `:Filetree helper cancel`)
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

---Where cargo puts what it builds: `$CARGO_TARGET_DIR` when set (relative to the working directory,
---as cargo reads it), else `helper/target` of this repository.
---@return string
local function target_dir()
  local dir = vim.env.CARGO_TARGET_DIR
  if dir and dir ~= "" then
    return (vim.fn.fnamemodify(dir, ":p"):gsub("\\", "/"):gsub("/$", ""))
  end
  return repo .. "/helper/target"
end

---@alias Filetree.Fs.Helper.Run fun(argv: string[], done: fun(result: { code: integer, stderr?: string }))
---@alias Filetree.Fs.Helper.Done fun(ok: boolean, message: string)

---The steps of a build, the same for both forms: `run` starts a program and calls back with its end
---(at once for `build()`, later for `build_async()`), `say` tells what is being done, `done` is called
---exactly once. While it runs, the helper is off (the Lua tiers serve), so that no request starts the
---old program again: a running program cannot be replaced on Windows.
---@param opts { download?: boolean }
---@param run Filetree.Fs.Helper.Run
---@param say fun(text: string)
---@param done Filetree.Fs.Helper.Done
local function install(opts, run, say, done)
  if M.workstation() then
    return done(
      false,
      "not on the workstation (NVIM_MACHINE_ROLE=workstation): nothing native before the EDR check"
    )
  end
  local function finish(ok, message)
    -- a program found later in the session is used from the next request on
    lib.configure(nil)
    done(ok, message)
  end
  lib.configure(false)
  local target = M.default_path()
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  if opts.download ~= true and vim.fn.executable("cargo") == 1 then
    local manifest = repo .. "/helper/Cargo.toml"
    say("cargo build --release (the first build takes minutes)")
    run({ "cargo", "build", "--release", "--manifest-path", manifest }, function(result)
      if result.code ~= 0 then
        return finish(false, "cargo build failed: " .. vim.trim(result.stderr or ""):sub(-400))
      end
      local built = target_dir() .. "/release/" .. M.binary_name()
      os.remove(target)
      local copied, err = uv.fs_copyfile(built, target)
      if not copied then return finish(false, "cannot copy " .. built .. ": " .. tostring(err)) end
      finish(true, "filetree-helper installed: " .. target)
    end)
  elseif opts.download ~= false then
    local asset = M.asset_name()
    if not asset then
      return finish(
        false,
        "no release program for this system; install a Rust toolchain and build again"
      )
    end
    if vim.fn.executable("curl") ~= 1 then return finish(false, "neither cargo nor curl found") end
    local part = target .. ".part"
    say("downloading " .. asset)
    run({
      "curl",
      "--fail",
      "--location",
      "--silent",
      "--show-error",
      "--output",
      part,
      M.RELEASES .. asset,
    }, function(result)
      if result.code ~= 0 then
        os.remove(part)
        return finish(false, "download failed: " .. vim.trim(result.stderr or ""))
      end
      os.remove(target)
      local moved, err = os.rename(part, target)
      if not moved then
        return finish(false, "cannot move the download into place: " .. tostring(err))
      end
      if uv.os_uname().sysname ~= "Windows_NT" then uv.fs_chmod(target, tonumber("755", 8)) end
      finish(true, "filetree-helper installed: " .. target)
    end)
  else
    finish(false, "cargo not found and downloading is off")
  end
end

---Start a program without a shell, by its bare name (so a stand-in on the PATH takes it); an error
---of the start becomes a failed end.
---@param argv string[]
---@param on_exit? fun(result: vim.SystemCompleted)
---@return vim.SystemObj|nil job
---@return string|nil err
local function start(argv, on_exit)
  local ok, job = pcall(vim.system, argv, { text = true }, on_exit)
  if not ok then return nil, tostring(job) end
  return job, nil
end

---@class Filetree.Fs.Helper.Build
---@field cancel fun()  Stop the build: the running program is killed, the callback hears "cancelled".

---The build that runs now, nil when none does.
---@type Filetree.Fs.Helper.Build|nil
local running = nil

---Put the program where `"auto"` finds it (`stdpath("data")/filetree-helper/`): built with cargo when
---a Rust toolchain is there, else downloaded from the latest release. For the `build` step of a plugin
---manager: **blocks** until cargo or curl is done (minutes for a first build); from a running editor use
---`build_async()` (`:Filetree helper build`). Refuses on the workstation (`NVIM_MACHINE_ROLE=workstation`)
---and while a `build_async()` runs.
---@param opts? { download?: boolean }  `download = true`: never build, `false`: never download.
---@return boolean ok
---@return string message
function M.build(opts)
  if running then return false, "a build of filetree-helper is already running" end
  local ok, message = false, "the build did not end"
  install(opts or {}, function(argv, done)
    local job, err = start(argv)
    if not job then return done({ code = -1, stderr = err }) end
    done(job:wait())
  end, function() end, function(o, m)
    ok, message = o, m
  end)
  return ok, message
end

---`build()` without blocking the editor: cargo or curl run in the background with a progress
---indicator (`progress_style`), and `on_done` hears the outcome on the main loop. While it runs the
---helper is off and the Lua tiers serve; a second build is refused, Neovim quitting kills it.
---@param opts? { download?: boolean }  As in `build()`.
---@param on_done? fun(ok: boolean, message: string)  Default: say it (`vim.notify`).
---@return Filetree.Fs.Helper.Build|nil build  nil when nothing was started (`on_done` has heard why).
function M.build_async(opts, on_done)
  on_done = on_done
    or function(ok, message)
      vim.notify("[filetree] " .. message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
  if running then
    on_done(
      false,
      "a build of filetree-helper is already running (:Filetree helper cancel stops it)"
    )
    return nil
  end
  local job ---@type vim.SystemObj|nil
  local cancelled = false
  local progress = require("filetree.util.progress").create({ title = "[filetree-helper]" })
  local group = vim.api.nvim_create_augroup("filetree.helper.build", { clear = true })
  ---@type Filetree.Fs.Helper.Build
  local this_build = { cancel = function() end }
  running = this_build

  ---@param ok boolean
  ---@param message string
  local function finish(ok, message)
    if running ~= this_build then return end
    running = nil
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if progress then
      if ok then
        progress:finish(message)
      else
        progress:cancel(message)
      end
    end
    on_done(ok, message)
  end

  function this_build.cancel()
    if running ~= this_build or cancelled then return end
    cancelled = true
    if job then pcall(job.kill, job, "sigterm") end
    -- without a running program (between two steps) nothing calls back: end it here
    if not job then finish(false, "build cancelled") end
  end
  if progress then progress:on_cancel(this_build.cancel) end
  -- a build must not outlive the editor that started it
  vim.api.nvim_create_autocmd(
    "VimLeavePre",
    { group = group, once = true, callback = this_build.cancel }
  )

  install(opts or {}, function(argv, done)
    local err
    job, err = start(argv, function(result)
      vim.schedule(function()
        job = nil
        -- a program that ended on its own just before the cancel did not install anything yet
        if cancelled then return done({ code = -1, stderr = "cancelled" }) end
        done(result)
      end)
    end)
    if not job then done({ code = -1, stderr = err }) end
  end, function(text)
    if progress then progress:update({ text = text }) end
  end, function(ok, message)
    if cancelled and not ok then message = "build cancelled" end
    finish(ok, message)
  end)
  return running == this_build and this_build or nil
end

---Stop the build `build_async()` runs.
---@return boolean stopped  false when none runs.
function M.cancel_build()
  if not running then return false end
  running.cancel()
  return true
end

---Is a `build_async()` running?
---@return boolean
function M.building()
  return running ~= nil
end

---`:checkhealth filetree`: what the helper does on this machine.
---@param ok fun(msg: string)
---@param info fun(msg: string)
---@param warn fun(msg: string)
function M.health(ok, info, warn)
  lib.health(ok, info, warn, "native")
end

return M
