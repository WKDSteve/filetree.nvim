-- TESTS/refs/deadline_spec.lua -- the nested git listings of the refs walk share ONE time budget.
--
-- `filetree.refs.scan` lists a project with `git ls-files`, and lists every checked-out submodule
-- or embedded repository again from inside (its own ignore rules). All those listings draw on the
-- budget of the first call; once it is used up, a nested repository is walked plainly instead of
-- asked of git again, so a project with many submodules cannot take n * `scan.timeout_ms`.
--
-- Real timing would make this flaky, so the scan's clock (`scan.clock`) is swapped for one that
-- reads a variable. The nested repository holds a gitignored file: git's listing leaves it out,
-- the plain walk does not, so the file shows which of the two listed the repository.
--
--   nvim --clean --headless -u NONE -l TESTS/refs/deadline_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(root)

-- lib.nvim, which filetree's util modules need (same search as the other refs specs).
for _, dir in ipairs({
  vim.env.LIB_NVIM_DIR,
  vim.env.FILETREE_LIB_NVIM,
  vim.env.LIB_NVIM_PATH,
  vim.fn.fnamemodify(root, ":h") .. "/lib.nvim",
  vim.fn.stdpath("data") .. "/lazy/lib.nvim",
}) do
  if dir and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(vim.fs.normalize(dir))
    break
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

local function finish()
  print(("\nfiletree.nvim refs/deadline_spec: %d passed, %d failed"):format(passed, failed))
  if failed > 0 then
    vim.cmd("cq")
  else
    vim.cmd("qa!")
  end
end

if vim.fn.executable("git") == 0 then
  print("  skip git is not installed: nothing to list")
  finish()
  return
end

local scan = require("filetree.refs.scan")
local real_clock = scan.clock

-- A project that is a git repository with an embedded repository `sub/` (untracked, so the
-- superproject lists it only as `sub/`), which has a file of its own ignored by its own
-- `.gitignore`.
local scratch = (vim.fn.tempname() .. "-ft-deadline"):gsub("\\", "/")
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ text }, path)
end
local function git(dir, ...)
  local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  assert(res.code == 0, "git failed: " .. (res.stderr or ""))
end

write(scratch .. "/top.txt", "top")
write(scratch .. "/sub/inner.txt", "inner")
write(scratch .. "/sub/hidden.txt", "hidden")
write(scratch .. "/sub/.gitignore", "hidden.txt")
git(scratch, "init", "-q")
git(scratch .. "/sub", "init", "-q")

---Names (relative to the project) of the files `scan.git_listing` returns, sorted.
---`calls_before_expiry`: how many clock reads see the full budget; later reads see it used up.
---@param calls_before_expiry integer
---@return table<string, true>
local function listing(calls_before_expiry)
  local reads = 0
  scan.clock = function()
    reads = reads + 1
    return reads <= calls_before_expiry and 0 or 30000 * 1e6 + 1
  end
  -- A real git runs under this budget too: ample for a loaded VM, and the expired cases use the fake clock.
  local files = scan.git_listing(scratch, 30000)
  scan.clock = real_clock
  local seen = {}
  for _, abs in ipairs(files or {}) do
    seen[abs:sub(#scratch + 2)] = true
  end
  return seen
end

-- Read 1 sets the shared deadline (30000 ms from "0"); read 2 is the nested repository asking
-- how much is left.
local budget_left = listing(2)
check("budget left: the top-level file is listed", budget_left["top.txt"] == true)
check("budget left: the nested repository is listed by git", budget_left["sub/inner.txt"] == true)
check(
  "budget left: git's ignore rules of the nested repository apply",
  budget_left["sub/hidden.txt"] == nil
)

local budget_used = listing(1)
check("budget used up: the top-level file is still listed", budget_used["top.txt"] == true)
check("budget used up: the nested repository is still listed", budget_used["sub/inner.txt"] == true)
check(
  "budget used up: the nested repository falls back to the plain walk",
  budget_used["sub/hidden.txt"] == true
)

vim.fn.delete(scratch, "rf")
finish()
