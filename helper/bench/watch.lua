-- helper/bench/watch.lua -- E3h: does a change in a folder the tree never opened reach it? The Lua
-- watcher of the own tree (`filetree.native.fs.watch`, as the tree uses it: the root is watched) and
-- the prototype helper watch the same root; then a file appears in a closed folder two levels down and
-- in a folder made after the watch started. Prints which of them reported which folder.
--
--   nvim --clean --headless -u NONE -l helper/bench/watch.lua <helper-exe>
--
-- On Windows and macOS both should see everything (libuv watches recursively there); on Linux the
-- Lua watcher has one handle per watched folder, which is the gap of native-linux-closed-folder-watch.

local this = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(repo)
local lib = vim.fn.fnamemodify(repo, ":h") .. "/lib.nvim"
if vim.fn.isdirectory(lib) == 1 then vim.opt.rtp:prepend(lib) end

local function say(text)
  io.stdout:write(text, "\n")
end

local exe = assert(_G.arg[1], "usage: watch.lua <helper-exe>")
local list = require("filetree.native.fs.list")
local watch = require("filetree.native.fs.watch")
local uv = vim.uv

local base = list.norm(uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local root = ("%s/ft_watch_%d"):format(base, uv.hrtime() % 1e9)
vim.fn.mkdir(root .. "/closed/deeper", "p")

local seen = { lua = {}, helper = {} }
local unsubscribe = watch.subscribe(function(dirs)
  for _, dir in ipairs(dirs) do
    seen.lua[dir] = true
  end
end)
-- the Lua watcher without the helper (libuv handles), the helper's watch beside it
local helper = require("filetree.native.fs.helper")
helper.configure(false)
local unwatch = watch.watch(root)
helper.configure(exe)
local gen = helper.request("watch", root, function(kind, payload)
  if kind == "changed" then
    for _, dir in ipairs(payload) do
      seen.helper[dir] = true
    end
  elseif kind == "error" then
    say("helper error: " .. tostring(payload))
  end
  return true
end)
assert(gen, "cannot start " .. exe)
vim.wait(500, function()
  return false
end)

local cases = {
  { "a closed folder two levels down", root .. "/closed/deeper", "/closed/deeper/new.txt" },
  { "a folder made after the watch started", root .. "/later/sub", "/later/sub/new.txt" },
  { "the root itself", root, "/top.txt" },
}
for _, case in ipairs(cases) do
  vim.fn.mkdir(case[2], "p")
  vim.wait(300, function()
    return false
  end)
  vim.fn.writefile({ "x" }, root .. case[3])
end
vim.wait(1500, function()
  return false
end)

say(
  ("system %s, libuv recursive: %s"):format(uv.os_uname().sysname, tostring(watch.native_recursive))
)
for _, case in ipairs(cases) do
  say(
    ("  %-40s lua %-3s helper %s"):format(
      case[1],
      seen.lua[case[2]] and "yes" or "no",
      seen.helper[case[2]] and "yes" or "no"
    )
  )
end

helper.drop(gen, "unwatch")
helper.stop()
unwatch()
unsubscribe()
watch.stop_all()
vim.fn.delete(root, "rf")
vim.cmd("qa!")
