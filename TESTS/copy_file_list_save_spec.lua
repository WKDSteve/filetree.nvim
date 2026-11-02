-- TESTS/copy_file_list_save_spec.lua -- features.copy_file_list can write its file list to a file.
--
-- A temp tree with an ignored folder (.git), one file and a nested one. The spec checks the list
-- (relative to the cwd, ignore list applied) and that write_list creates the missing parent
-- directory, writes one path per line and reports a path it cannot write.
--
--   nvim --clean --headless -u NONE -l TESTS/copy_file_list_save_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

-- lib.nvim, which filetree's util modules need (same search as the refs specs).
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

local scratch = vim.fs.normalize(vim.fn.tempname() .. "-ft-filelist")
vim.fn.mkdir(scratch .. "/proj/sub", "p")
vim.fn.mkdir(scratch .. "/proj/.git", "p")
vim.fn.writefile({ "a" }, scratch .. "/proj/a.txt")
vim.fn.writefile({ "b" }, scratch .. "/proj/sub/b.txt")
vim.fn.writefile({ "g" }, scratch .. "/proj/.git/config")

-- The ignore list the file lists follow (`.git` here), set up the way the tree does.
require("filetree.features.infra.ignore_list").setup(
  { enabled = true, names = { ".git" } },
  { name = "stub" }
)

local mod = require("filetree.features.paths.copy_file_list")
mod.setup({ keymap_files_abs = false, keymap_files_rel = false }, {
  get_current_node = function()
    return nil
  end,
})

vim.cmd.cd(vim.fn.fnameescape(scratch))
local lines = mod.files_for({ scratch .. "/proj" }, true)
table.sort(lines)
check("list: relative to the cwd", lines[1] == "proj/a.txt", tostring(lines[1]))
check("list: nested file included", lines[2] == "proj/sub/b.txt", tostring(lines[2]))
check("list: the ignored .git folder stays out", #lines == 2, tostring(#lines))

local out = scratch .. "/out/dir/file-list.txt"
local ok, err = mod.write_list(out, lines)
check("write_list: ok, parent directories created", ok == true and err == nil, tostring(err))
local back = vim.fn.readfile(out)
check("write_list: one path per line", #back == 2 and back[1] == lines[1] and back[2] == lines[2])

-- A target below a file cannot be created: reported, not raised.
local bad_ok, bad_err = mod.write_list(scratch .. "/proj/a.txt/x/list.txt", lines)
check("write_list: an impossible target is reported", bad_ok == false and bad_err ~= nil)

vim.cmd.cd("/")
vim.fn.delete(scratch, "rf")
print(("\nfiletree.nvim copy_file_list_save_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
