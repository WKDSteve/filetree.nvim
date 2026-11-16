-- TESTS/trash_wsl_powershell_spec.lua -- the WSL trash starts `powershell.exe`, and a program that
-- cannot be started is reported instead of hanging the delete.
--
-- In WSL only `powershell.exe` is on PATH, not `powershell`: the trash spawned the short name,
-- vim.system threw ENOENT inside a scheduled callback and the trash callback never ran, so a delete
-- in WSL hung (found by TESTS/live/trash_linux.lua wsl on Arch under WSL). Platform and process are
-- doubles here; the real run is that live script.
--
--   nvim --clean --headless -u NONE -l TESTS/trash_wsl_powershell_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dir in ipairs({
  vim.env.LIB_NVIM_DIR or "",
  vim.fn.fnamemodify(root, ":h") .. "/lib.nvim",
  vim.fn.stdpath("data") .. "/lazy/lib.nvim",
}) do
  if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(vim.fs.normalize(dir))
    break
  end
end

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

-- WSL, with wslpath: the real detection is replaced, the rest of util.platform is the real one.
package.loaded["lib.nvim.cross.platform.is_wsl"] = function()
  return true
end
package.loaded["lib.nvim.cross.platform.is_windows"] = function()
  return false
end
package.loaded["filetree.util.platform"] = nil
local real_executable = vim.fn.executable
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.executable = function(name)
  if name == "wslpath" then return 1 end
  return real_executable(name)
end

-- Processes: wslpath answers a Windows path; any other program is "not on PATH" unless named here.
local on_path = { wslpath = true, ["powershell.exe"] = true }
local started = {}
local real_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(argv, _, on_exit)
  started[#started + 1] = argv[1]
  if not on_path[argv[1]] then
    error(("ENOENT: no such file or directory (cmd): '%s'"):format(argv[1]))
  end
  local stdout = argv[1] == "wslpath" and "C:\\Users\\x\\note.txt\n" or ""
  on_exit({ code = 0, signal = 0, stdout = stdout, stderr = "" })
  return {}
end

local platform = require("filetree.features.fileops.trash.platform")

---@param path string
---@return TrashResult?
local function send(path)
  local result
  local ok, err = pcall(platform.send, path, function(r)
    result = r
  end)
  if not ok then
    print("  send threw: " .. tostring(err))
    return nil
  end
  vim.wait(2000, function()
    return result ~= nil
  end, 10)
  return result
end

local res = send("/home/x/note.txt")
eq("wsl: the delete answers", res ~= nil, true)
eq("wsl: the delete is reported ok", res and res.ok, true)
eq("wsl: the program started after wslpath is powershell.exe", started[2], "powershell.exe")

-- A program that cannot be started: the callback runs with an error naming it, no hang.
on_path["powershell.exe"] = nil
started = {}
res = send("/home/x/note.txt")
eq("not startable: the delete still answers", res ~= nil, true)
eq("not startable: reported as failed", res and res.ok, false)
eq(
  "not startable: the error names the program",
  res ~= nil and tostring(res.err):find("powershell.exe", 1, true) ~= nil,
  true
)

vim.system = real_system
print(("\nfiletree.nvim trash_wsl_powershell_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
