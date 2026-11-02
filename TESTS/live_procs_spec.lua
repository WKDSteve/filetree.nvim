-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil
-- TESTS/live_procs_spec.lua -- util.live_procs tracks a process until it exits and
-- kills what is still running on request (VimLeavePre calls the same function).
--
--   nvim --clean --headless -u NONE -l TESTS/live_procs_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s want %s"):format(name, tostring(got), tostring(want)))
  end
end

local live = require("filetree.util.live_procs")

-- A child that outlives the spec unless it is killed: this nvim waits on stdin.
local sleeper = { vim.v.progpath, "--clean", "--headless", "-u", "NONE", "-c", "sleep 60" }
local exited
local obj = live.spawn(sleeper, {}, function(res)
  exited = res
end)
eq("running process is tracked", live.count(), 1)
eq("kill_all reports the process", live.kill_all(), 1)
vim.wait(5000, function()
  return exited ~= nil
end)
eq("killed process reached its exit callback", exited ~= nil, true)
eq("nothing is tracked afterwards", live.count(), 0)
eq("kill_all with nothing running", live.kill_all(), 0)

-- A process that ends by itself drops out of the table.
local done
live.spawn({ vim.v.progpath, "--clean", "--headless", "-u", "NONE", "-c", "qa!" }, {}, function()
  done = true
end)
vim.wait(10000, function()
  return done
end)
eq("finished process is forgotten", live.count(), 0)
obj:wait(1000)

print(("\nfiletree.nvim live_procs_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
