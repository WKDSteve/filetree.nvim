-- TESTS/grep_in_dir_fallback_spec.lua -- grep_in_dir on a machine without ripgrep.
--
-- The builtin backend falls back to `grep` when `rg` is missing. grep prints no column, and the
-- parser only read rg's `file:line:col:text`: every grep match was dropped and the search said
-- "No matches" although grep had found them. Here `rg` is hidden and the real grep runs.
--
--   nvim --clean --headless -u NONE -l TESTS/grep_in_dir_fallback_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ { "LIB_NVIM_DIR", "lib.nvim", "lib" }, { "UI_NVIM_DIR", "ui.nvim", "ui" } }) do
  for _, dir in ipairs({
    vim.env[dep[1]] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep[2],
    vim.fn.stdpath("data") .. "/lazy/" .. dep[2],
  }) do
    if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/" .. dep[3]) == 1 then
      vim.opt.rtp:prepend(vim.fs.normalize(dir))
      break
    end
  end
end

if vim.fn.executable("grep") ~= 1 then
  print("n/a  no grep on this machine")
  vim.cmd("qa!")
  return
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

local work = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(work .. "/src/sub", "p")
vim.fn.writefile({ "local needle = 1", "x" }, work .. "/src/a.lua")
vim.fn.writefile({ "-- none", "-- at 3:12: a needle" }, work .. "/src/sub/b.lua")

-- No ripgrep on this machine.
local real_executable = vim.fn.executable
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.executable = function(name)
  if name == "rg" then return 0 end
  return real_executable(name)
end

local said = {}
local real_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg)
  said[#said + 1] = tostring(msg)
end

local grep = require("filetree.features.search.grep_in_dir")
grep.grep(work .. "/src", "needle")
vim.wait(10000, function()
  return #said > 0
end)
vim.notify = real_notify
vim.fn.executable = real_executable

local items = {}
for _, item in ipairs(vim.fn.getqflist()) do
  local name = vim.fs.normalize(vim.api.nvim_buf_get_name(item.bufnr))
  items[#items + 1] = name:sub(#work + 2) .. ":" .. item.lnum .. ":" .. item.text
end
table.sort(items)

eq("grep's matches are not dropped", table.concat(said, " "):find("No matches", 1, true), nil)
eq("both matches are in the quickfix list", #items, 2)
eq("the first: file and line", items[1], "src/a.lua:1:local needle = 1")
eq(
  "a ':3:12:' in the text is text, not a line and column",
  items[2],
  "src/sub/b.lua:2:-- at 3:12: a needle"
)

vim.fn.delete(work, "rf")
print(("\nfiletree.nvim grep_in_dir_fallback_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
