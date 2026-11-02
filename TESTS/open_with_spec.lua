-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/open_with_spec.lua -- "open with <app>" starts the configured command with its args and the
-- node's path appended (the system-default route went through lib.nvim cross.open_default; the
-- app route must keep its own spawn helper).
--
--   nvim --clean --headless -u NONE -l TESTS/open_with_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  for _, candidate in ipairs({
    vim.env[dep:upper():gsub("%.", "_") .. "_DIR"] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep,
    root .. "/.deps/" .. dep,
    vim.fn.stdpath("data") .. "/lazy/" .. dep,
  }) do
    if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua") == 1 then
      vim.opt.rtp:prepend(candidate)
      break
    end
  end
end

local passed, failed = 0, 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local open_with = require("filetree.features.system.open_with")
local path = "/tmp/some file.txt"
open_with.setup({ enabled = true, apps = { { name = "Echo", cmd = "echo", args = { "a" } } } }, {
  get_current_node = function()
    return { path = path }
  end,
})

local real_system, spawned = vim.system, {}
vim.system = function(cmd, opts)
  spawned[#spawned + 1] = { cmd = cmd, opts = opts }
  return {}
end
local real_notify = vim.notify
vim.notify = function() end

open_with.open_app("Echo")
vim.system, vim.notify = real_system, real_notify

eq("one process is started", #spawned, 1)
eq(
  "argv: the app, its args, then the path as one argument",
  spawned[1] and spawned[1].cmd,
  { "echo", "a", path }
)
eq("the process is detached", spawned[1] and spawned[1].opts.detach, true)

print(("\nfiletree.nvim open_with: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cq")
