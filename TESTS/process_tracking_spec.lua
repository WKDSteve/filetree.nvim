-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/process_tracking_spec.lua -- external processes of filetree.nvim:
--   * the builtin search of grep_in_dir is tracked and killed at exit (POSIX
--     leaves a vim.system child running otherwise);
--   * a Chocolatey rg shim resolves to the real rg.exe, an unresolvable one
--     falls back to the name.
--
--   nvim --clean --headless -u NONE -l TESTS/process_tracking_spec.lua

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
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end

-- grep_in_dir: a search that is still running is tracked, and killed.
local grep = require("filetree.features.search.grep_in_dir")
grep.setup({ enabled = true, prefer = "builtin" }, {})
local killed = 0
local real_system = vim.system
vim.system = function()
  return {
    kill = function()
      killed = killed + 1
    end,
  }
end
grep.grep(root, "needle")
vim.system = real_system
check("a running builtin search is tracked", grep.live_count() == 1, tostring(grep.live_count()))
check("kill_live stops it", grep.kill_live() == 1 and killed == 1)
check("and forgets it", grep.live_count() == 0)

-- Chocolatey: <choco>/bin/rg.exe is a shim, the binary lives in lib/ripgrep/tools.
local platform = require("filetree.util.platform")
local choco = vim.fn.tempname()
vim.fn.mkdir(choco .. "/bin", "p")
vim.fn.mkdir(choco .. "/lib/ripgrep/tools/ripgrep-14.1.0-x86_64-pc-windows-msvc", "p")
local real = choco .. "/lib/ripgrep/tools/ripgrep-14.1.0-x86_64-pc-windows-msvc/rg.exe"
local function touch(path, exec)
  vim.fn.writefile({ "x" }, path)
  if exec then vim.uv.fs_chmod(path, 493) end
end
touch(choco .. "/bin/rg.exe", true)
touch(real, true)
local got = platform.chocolatey_target(choco .. "/bin/rg.exe")
check("a Chocolatey shim resolves to the real rg.exe", got ~= nil and vim.fs.normalize(got) == vim.fs.normalize(real), tostring(got))
check("an exe outside a bin folder is left alone", platform.chocolatey_target(choco .. "/lib/rg.exe") == nil)
vim.fn.delete(real)
check("a missing package folder falls back", platform.chocolatey_target(choco .. "/bin/rg.exe") == nil)
vim.fn.delete(choco, "rf")

print(("\nfiletree.nvim process_tracking_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
