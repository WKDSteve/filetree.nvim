-- helper/bench/watches.lua -- what a watch of the helper costs on Linux: how many inotify watches the
-- helper holds for a root, how long it took until the watch stood, and whether it stood at all (past
-- `fs.inotify.max_user_watches` it does not). Only reads the root.
--
--   nvim --clean --headless -u NONE -l helper/bench/watches.lua <helper-exe> <root>
--
-- A lower limit for one run, without touching the system's (a user namespace has its own):
--
--   unshare --user --map-root-user sh -c 'echo 8192 > /proc/sys/user/max_inotify_watches && nvim ...'

local this = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(repo)
local lib = vim.fn.fnamemodify(repo, ":h") .. "/lib.nvim"
if vim.fn.isdirectory(lib) == 1 then vim.opt.rtp:prepend(lib) end

local function say(text)
  io.stdout:write(text, "\n")
end

local exe = assert(_G.arg[1], "usage: watches.lua <helper-exe> <root>")
local root = assert(_G.arg[2], "usage: watches.lua <helper-exe> <root>")
local uv = vim.uv
local helper = require("filetree.native.fs.helper")
root =
  require("filetree.native.fs.list").norm(assert(uv.fs_realpath(root), "no such folder: " .. root))

if uv.os_uname().sysname ~= "Linux" then
  say("not Linux: the helper watches recursively here, there is nothing to count")
  vim.cmd("qa!")
end

---@return integer
local function inotify_watches()
  local count = 0
  local fdinfo = ("/proc/%d/fdinfo"):format(helper.state().pid)
  for name in vim.fs.dir(fdinfo) do
    local file = io.open(fdinfo .. "/" .. name, "r")
    if file then
      for line in file:lines() do
        if line:find("^inotify wd:") then count = count + 1 end
      end
      file:close()
    end
  end
  return count
end

local function read(path)
  local file = io.open(path, "r")
  if not file then return "?" end
  local text = file:read("*l")
  file:close()
  return text
end

helper.configure(exe)
local answer, payload
local started = uv.hrtime()
local gen = helper.request("watch", root, function(kind, data)
  if kind == "watching" or kind == "error" then
    answer, payload = kind, data
  end
  return true
end)
assert(gen, "cannot start " .. exe)
vim.wait(120000, function()
  return answer ~= nil
end, 5)
local ms = (uv.hrtime() - started) / 1e6

say(("root            %s"):format(root))
say(
  ("limit           fs.inotify.max_user_watches %s, user.max_inotify_watches %s"):format(
    read("/proc/sys/fs/inotify/max_user_watches"),
    read("/proc/sys/user/max_inotify_watches")
  )
)
say(
  ("answer          %s%s"):format(
    tostring(answer),
    answer == "error" and (": " .. tostring(payload)) or ""
  )
)
say(("after           %.0f ms"):format(ms))
say(("inotify watches %d"):format(inotify_watches()))

helper.drop(gen, "unwatch")
helper.stop()
vim.cmd("qa!")
