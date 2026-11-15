---@module 'filetree.native.fs.helper'
---@brief The helper process of the own tree (tier 3): one child of this Neovim that lists, sizes and watches.
---@description
--- `helper/` of this repository builds `filetree-helper`, a small read-only program (Rust) that lists the
--- files below a folder with the ignore rules of ripgrep, adds up the size of a folder and watches a
--- folder tree, also on Linux (there folder by folder, ignored ones left out). This module finds it, starts it on first need, talks to it
--- over msgpack-RPC on stdin/stdout and hands its answers to whoever asked.
---
--- Key responsibilities:
--- - `find()` / `available()`: is there a helper to use, and if not, why (for `:checkhealth`)
--- - `request(method, arg, handler)`: a generation per request; an answer of a dropped request is
---   thrown away before anybody sees it; `drop(gen, method?)` forgets one (and tells the helper);
---   `tell(gen, method, arg)` says something more about one that is open (`"follow"` for a watch)
--- - A helper that ends or cannot start is not started again in this session: every request still
---   open gets `"lost"`, the callers go on with the Lua tiers, and the user is told once
--- - `state()`: everything at once, plain data
---
--- `native.fs.helper` decides: `"auto"` (default) uses `helper/bin/filetree-helper[.exe]` when it is
--- there, except on a machine with `NVIM_MACHINE_ROLE=workstation` (nothing native runs there until
--- the EDR check clears it); `false` never uses one; a path uses exactly that program.
---
--- The helper answers by having this Neovim run `require('filetree.native.fs.helper').on(kind, gen,
--- payload)`; that is the only thing it can make the editor do.

local uv = vim.uv

local M = {}

--- The protocol this module speaks (`filetree-helper --version` names its own).
M.PROTOCOL = 2

---@alias Filetree.Fs.Helper.Mode "auto"|false|string

---@class Filetree.Fs.Helper.State
---@field mode Filetree.Fs.Helper.Mode
---@field exe? string  The program in use, or the one that would be used.
---@field running boolean
---@field pid? integer
---@field off? string  Why no helper is used, when none is.
---@field lost? string  Why the helper of this session ended, when it did.
---@field requests integer  Requests waiting for an answer.

local state = {
  ---@type integer|nil
  chan = nil,
  ---@type integer|nil
  pid = nil,
  ---@type string|nil  why the helper is out for the rest of the session
  lost = nil,
  told = false,
  stopping = false,
  generation = 0,
  ---@type table<integer, fun(kind: string, payload: any): boolean|nil>
  handlers = {},
  ---@type Filetree.Fs.Helper.Mode|nil  set by `configure` (specs); nil: from `native.fs.helper`
  override = nil,
  ---@type { key: any, exe: string|nil, why: string|nil }|nil
  found = nil,
}

local this = debug.getinfo(1, "S").source:sub(2)
--- The repository this file belongs to (`lua/filetree/native/fs/helper.lua` is five levels down).
local repo = vim.fn.fnamemodify(this, ":p:h:h:h:h:h"):gsub("\\", "/")

---@return string
function M.binary_name()
  return uv.os_uname().sysname == "Windows_NT" and "filetree-helper.exe" or "filetree-helper"
end

---Where `"auto"` looks for the program: `helper/bin/` of this plugin.
---@return string
function M.default_path()
  return repo .. "/helper/bin/" .. M.binary_name()
end

---Is this the workstation, where nothing native may run until the EDR check clears it?
---@return boolean
function M.workstation()
  return (vim.env.NVIM_MACHINE_ROLE or ""):lower() == "workstation"
end

---@return Filetree.Fs.Helper.Mode
function M.mode()
  if state.override ~= nil then return state.override end
  local ok, native = pcall(require, "filetree.native")
  local fs = ok and type(native.options) == "function" and native.options().fs or nil
  local value = type(fs) == "table" and fs.helper or nil
  if value == nil then return "auto" end
  return value
end

---Which program would be used, without starting it.
---@return string|nil exe
---@return string|nil why  Why none, when none.
function M.find()
  local mode = M.mode()
  local key = tostring(mode) .. "|" .. tostring(vim.env.NVIM_MACHINE_ROLE)
  if state.found and state.found.key == key then return state.found.exe, state.found.why end
  local exe, why
  if mode == false then
    why = "off (native.fs.helper = false)"
  elseif mode == "auto" then
    if M.workstation() then
      why =
        "off on the workstation (NVIM_MACHINE_ROLE=workstation): nothing native runs there before the EDR check"
    elseif uv.fs_stat(M.default_path()) then
      exe = M.default_path()
    else
      why = "not installed (no " .. M.default_path() .. "; see :help filetree-native-helper)"
    end
  elseif type(mode) == "string" and mode ~= "" then
    if uv.fs_stat(mode) then
      exe = mode
    else
      why = "native.fs.helper names no program: " .. mode
    end
  else
    why = 'native.fs.helper must be "auto", false or the path of the program'
  end
  state.found = { key = key, exe = exe, why = why }
  return exe, why
end

---Can the helper be used now? False after it ended in this session.
---@return boolean ok
---@return string|nil why  Why not.
function M.available()
  if state.lost then return false, state.lost end
  local exe, why = M.find()
  return exe ~= nil, why
end

---@param reason string
local function lose(reason)
  state.lost = reason
  state.chan, state.pid = nil, nil
  local waiting = state.handlers
  state.handlers = {}
  for _, handler in pairs(waiting) do
    pcall(handler, "lost", reason)
  end
  if not state.told then
    state.told = true
    vim.schedule(function()
      vim.notify(
        ("[filetree] the helper process %s; the Lua tiers take over for the rest of this session"):format(
          reason
        ),
        vim.log.levels.WARN
      )
    end)
  end
end

---Start the helper if it is not running. Nothing when it is not available.
---@return integer|nil channel
local function start()
  if state.chan then return state.chan end
  if not M.available() then return nil end
  local exe = assert(M.find())
  local chan
  local ok, result = pcall(vim.fn.jobstart, { exe }, {
    rpc = true,
    on_exit = function(_, code)
      if state.chan ~= chan then return end
      if state.stopping then
        state.chan, state.pid = nil, nil
        return
      end
      lose(("ended (exit code %s)"):format(tostring(code)))
    end,
  })
  if not ok or type(result) ~= "number" or result <= 0 then
    lose(("could not be started (%s): %s"):format(exe, tostring(result)))
    return nil
  end
  chan = result
  state.chan = chan
  state.stopping = false
  local pid_ok, pid = pcall(vim.fn.jobpid, chan)
  state.pid = pid_ok and pid or nil
  return chan
end

---Ask the helper for something. `handler(kind, payload)` gets every answer of this request, on the main
---loop; it returns true to hear more (a listing comes in batches), anything else ends the request. A
---helper that ends meanwhile calls it once more with `"lost"` and the reason.
---@param method "walk"|"size"|"watch"
---@param arg string  The folder.
---@param handler fun(kind: string, payload: any): boolean|nil
---@return integer|nil generation  Nil when there is no helper (the handler is not called then).
function M.request(method, arg, handler)
  local chan = start()
  if not chan then return nil end
  state.generation = state.generation + 1
  local gen = state.generation
  state.handlers[gen] = handler
  local ok, err = pcall(vim.rpcnotify, chan, method, gen, arg)
  if not ok then
    state.handlers[gen] = nil
    lose("could not be reached: " .. tostring(err))
    return nil
  end
  return gen
end

---Forget a request: nothing more of it reaches anybody. With `method` the helper is told too
---(`"cancel"` for a listing, `"unwatch"` for a watch).
---@param gen integer
---@param method? "cancel"|"unwatch"
function M.drop(gen, method)
  state.handlers[gen] = nil
  if method and state.chan then pcall(vim.rpcnotify, state.chan, method, gen) end
end

---Say something more about a request that is still open: `"follow"` makes the watch `gen` watch the
---folder `arg` too, whatever the ignore rules say about it. Nothing when the request is over.
---@param gen integer
---@param method "follow"
---@param arg string
function M.tell(gen, method, arg)
  if state.handlers[gen] and state.chan then pcall(vim.rpcnotify, state.chan, method, gen, arg) end
end

---An answer of the helper. Called by the helper itself (through `nvim_exec_lua`), never by the tree.
---@param kind string
---@param gen integer
---@param payload any
function M.on(kind, gen, payload)
  local handler = state.handlers[gen]
  -- an answer of a request somebody dropped, or of an older helper
  if not handler then return end
  local ok, more = pcall(handler, kind, payload)
  if not ok then
    state.handlers[gen] = nil
    vim.schedule(function()
      vim.notify("[filetree] a helper answer failed: " .. tostring(more), vim.log.levels.WARN)
    end)
  elseif not more then
    state.handlers[gen] = nil
  end
end

---Stop the helper (not counted as its end: it is started again on the next request). Every request
---still open gets `"lost"`.
function M.stop()
  local chan = state.chan
  if not chan then return end
  state.stopping = true
  local waiting = state.handlers
  state.handlers = {}
  for _, handler in pairs(waiting) do
    pcall(handler, "lost", "stopped")
  end
  pcall(vim.fn.jobstop, chan)
  state.chan, state.pid = nil, nil
end

---Use `mode` instead of `native.fs.helper` (nil: back to the option), and forget an earlier end.
---For specs, and for a user who installed the program during the session.
---@param mode? Filetree.Fs.Helper.Mode
function M.configure(mode)
  M.stop()
  state.override = mode
  state.found = nil
  state.lost = nil
  state.told = false
end

---@return Filetree.Fs.Helper.State
function M.state()
  local exe, why = M.find()
  return {
    mode = M.mode(),
    exe = exe,
    running = state.chan ~= nil,
    pid = state.pid,
    off = why,
    lost = state.lost,
    requests = vim.tbl_count(state.handlers),
  }
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

---Put the program where `"auto"` finds it (`helper/bin/`): built with cargo when a Rust toolchain is
---there, else downloaded from the latest release. For the `build` step of a plugin manager; blocks.
---Refuses on the workstation (`NVIM_MACHINE_ROLE=workstation`).
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
  local bin = repo .. "/helper/bin"
  vim.fn.mkdir(bin, "p")
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
  M.configure(state.override)
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
