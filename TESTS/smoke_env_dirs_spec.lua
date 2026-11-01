-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil
-- TESTS/smoke_env_dirs_spec.lua -- TESTS/smoke.lua puts $LIB_NVIM_DIR / $UI_NVIM_DIR
-- first on the runtimepath. Starts the smoke script in a child nvim pointed at fake
-- dependency checkouts and reads the runtimepath back on exit.
--
--   nvim --clean --headless -u NONE -l TESTS/smoke_env_dirs_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
local smoke = root .. "/TESTS/smoke.lua"

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

local tmp = vim.fn.tempname()
local fake_lib, fake_ui = tmp .. "/fakelib", tmp .. "/fakeui"
vim.fn.mkdir(fake_lib .. "/lua/lib", "p")
vim.fn.mkdir(fake_ui .. "/lua/ui", "p")

-- The child records its runtimepath when it leaves, however smoke.lua ends
-- (qa!, cq or an error from a fake dependency).
local out = tmp .. "/rtp.txt"
local wrapper = tmp .. "/wrapper.lua"
vim.fn.writefile({
  "vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()",
  ("  vim.fn.writefile(vim.opt.rtp:get(), %q)"):format(out),
  "end })",
  ("dofile(%q)"):format(smoke),
}, wrapper)

vim.system({ vim.v.progpath, "--clean", "--headless", "-u", "NONE", "-l", wrapper }, {
  env = { LIB_NVIM_DIR = fake_lib, UI_NVIM_DIR = fake_ui },
  cwd = root,
  text = true,
}):wait(60000)

local rtp = vim.fn.filereadable(out) == 1 and vim.fn.readfile(out) or {}
local function index_of(dir)
  for i, p in ipairs(rtp) do
    if vim.fs.normalize(p) == vim.fs.normalize(dir) then return i end
  end
end
local lib_i, ui_i = index_of(fake_lib), index_of(fake_ui)
local sibling_lib = index_of(vim.fn.fnamemodify(root, ":h") .. "/lib.nvim")
local sibling_ui = index_of(vim.fn.fnamemodify(root, ":h") .. "/ui.nvim")
check("child reported its runtimepath", #rtp > 0)
check("LIB_NVIM_DIR is on the runtimepath", lib_i ~= nil)
check("UI_NVIM_DIR is on the runtimepath", ui_i ~= nil)
check("the sibling lib.nvim is not used instead", sibling_lib == nil)
check("the sibling ui.nvim is not used instead", sibling_ui == nil)

vim.fn.delete(tmp, "rf")
print(("\nfiletree.nvim smoke_env_dirs_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then vim.cmd("cq") else vim.cmd("qa!") end
