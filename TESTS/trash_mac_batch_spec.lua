-- TESTS/trash_mac_batch_spec.lua -- the AppleScript that trashes a macOS batch, on any system.
--
-- Finder's `delete {a, b, c}` stops at a locked item and leaves the others where they are, so one
-- locked file blocked a whole batch. Each item has its own `try` now, and an unanswered Finder is
-- cut off by a limit. Platform and process are doubles here: this checks the script and how the
-- outcome is read. What Finder does with it is TESTS/live/trash_macos.lua on a real Mac.
--
--   nvim --clean --headless -u NONE -l TESTS/trash_mac_batch_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

-- lib.nvim, which platform.lua needs (same search as the refs specs).
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

package.loaded["filetree.util.platform"] = {
  is_mac = function()
    return true
  end,
  is_windows = function()
    return false
  end,
  is_wsl = function()
    return false
  end,
  is_linux = function()
    return false
  end,
}

-- No `trash` CLI: the AppleScript path.
local real_executable = vim.fn.executable
vim.fn.executable = function(name)
  if name == "trash" then return 0 end
  return real_executable(name)
end

-- The process double: records the call, answers with `exit_code`.
local calls, exit_code = {}, 0
local real_system = vim.system
vim.system = function(argv, opts, on_exit)
  calls[#calls + 1] = { argv = argv, opts = opts }
  on_exit({ code = exit_code, stdout = "", stderr = "" })
end

local scratch = vim.fs.normalize(vim.fn.tempname() .. "-ft-macbatch")
vim.fn.mkdir(scratch, "p")
local stays = scratch .. "/stays.txt"
vim.fn.writefile({ "x" }, stays)
local gone = scratch .. "/gone.txt"

local platform = require("filetree.features.fileops.trash.platform")

---@param paths string[]
---@return TrashResult[]
local function batch(paths)
  local results
  platform.send_batch(paths, function(r)
    results = r
  end)
  vim.wait(2000, function()
    return results ~= nil
  end, 5)
  return results
end

---The script osascript gets, one line per `-e`.
---@param argv string[]
---@return string[]
local function script_lines(argv)
  local lines = {}
  for i = 2, #argv, 2 do
    eq("argv: -e before every line", argv[i], "-e")
    lines[#lines + 1] = argv[i + 1]
  end
  return lines
end

local odd = scratch .. '/with"quote\\.txt'
local results = batch({ gone, stays, odd })
eq("batch: one process", #calls, 1)
eq("batch: osascript", calls[1].argv[1], "osascript")
eq(
  "batch: every item alone in its own try, inside a limit",
  table.concat(script_lines(calls[1].argv), "\n"),
  table.concat({
    "with timeout of 30 seconds",
    'tell application "Finder"',
    "try",
    ('delete POSIX file "%s"'):format(gone),
    "end try",
    "try",
    ('delete POSIX file "%s"'):format(stays),
    "end try",
    "try",
    ('delete POSIX file "%s/with\\"quote\\\\.txt"'):format(scratch),
    "end try",
    "end tell",
    "end timeout",
  }, "\n")
)
eq("batch: the process has its own limit too", calls[1].opts.timeout, (3 * 30 + 10) * 1000)

-- Exit 0 does not mean every item went: the `try`s swallow a locked one.
eq("outcome: an item that is gone is ok", results[1].ok, true)
eq("outcome: exit 0, but the item stayed", results[2].ok, false)
eq("outcome: and it says so", type(results[2].err), "string")

-- A killed or failed process: the error of the process, per item that stayed.
calls, exit_code = {}, 124
results = batch({ gone, stays })
eq("killed: the item that is gone stays ok", results[1].ok, true)
eq("killed: the one that stayed fails", results[2].ok, false)
eq("killed: with the backend's message", results[2].err, "AppleScript trash failed")

-- One path alone: no try, so that its exit code stays the answer.
calls, exit_code = {}, 1
local single
platform.send(stays, function(r)
  single = r
end)
vim.wait(2000, function()
  return single ~= nil
end, 5)
eq(
  "single: no try",
  table.concat(script_lines(calls[1].argv), "\n"),
  table.concat({
    "with timeout of 30 seconds",
    'tell application "Finder"',
    ('delete POSIX file "%s"'):format(stays),
    "end tell",
    "end timeout",
  }, "\n")
)
eq("single: the exit code is the result", single.ok, false)

vim.system = real_system
vim.fn.executable = real_executable
vim.fn.delete(scratch, "rf")
print(("\nfiletree.nvim trash_mac_batch_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
