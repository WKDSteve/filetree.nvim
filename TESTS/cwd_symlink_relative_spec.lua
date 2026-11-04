-- TESTS/cwd_symlink_relative_spec.lua -- a node reached through a symlink to the cwd is still
-- inside the cwd, so every "relative to the cwd" path comes out relative.
--
-- getcwd() reports the physical directory, a node keeps the spelling its tree was rooted with:
-- on macOS `/var/...` (a symlink) against a cwd of `/private/var/...`, anywhere else a project
-- opened through a symlink. The link is real here (a junction on Windows, which needs no
-- privilege), so this fails on all three systems without the fix, not only on macOS.
--
--   nvim --clean --headless -u NONE -l TESTS/cwd_symlink_relative_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

-- lib.nvim and ui.nvim, which filetree's feature modules need (same search as the refs specs).
for _, dep in ipairs({
  { name = "lib.nvim", env = "LIB_NVIM_DIR", marker = "/lua/lib" },
  { name = "ui.nvim", env = "UI_NVIM_DIR", marker = "/lua/ui" },
}) do
  for _, dir in ipairs({
    vim.env[dep.env] or "", -- not nil: ipairs would stop right here
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep.name,
    vim.fn.stdpath("data") .. "/lazy/" .. dep.name,
  }) do
    if dir and dir ~= "" and vim.fn.isdirectory(dir .. dep.marker) == 1 then
      vim.opt.rtp:prepend(vim.fs.normalize(dir))
      break
    end
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

local uv = vim.uv or vim.loop
local scratch = vim.fs.normalize(vim.fn.tempname() .. "-ft-cwdlink")
local real = scratch .. "/real"
local link = scratch .. "/link"
vim.fn.mkdir(real .. "/proj/sub", "p")
vim.fn.writefile({ "a" }, real .. "/proj/a.txt")
vim.fn.writefile({ "b" }, real .. "/proj/sub/b.txt")
local other = scratch .. "/other"
vim.fn.mkdir(other, "p")
vim.fn.writefile({ "o" }, other .. "/o.txt")
assert(uv.fs_symlink(real, link, { dir = true, junction = true }))

-- The cwd is the physical directory; the nodes spell it through the link.
vim.cmd.cd(vim.fn.fnameescape(real))
local node_dir = link .. "/proj"
local node_file = link .. "/proj/a.txt"

local ftpath = require("filetree.util.path")
local cwd = ftpath.slashify(vim.fn.getcwd())
eq("cwd_alias: the link names the cwd", ftpath.cwd_alias(node_file), link)
eq("cwd_alias: the cwd's own spelling", ftpath.cwd_alias(cwd .. "/proj/a.txt"), cwd)
eq("cwd_alias: the cwd itself", ftpath.cwd_alias(cwd), cwd)
eq("cwd_alias: the link itself", ftpath.cwd_alias(link), link)
eq("cwd_alias: a path outside", ftpath.cwd_alias(other .. "/o.txt"), nil)
eq("cwd_alias: a sibling sharing the prefix", ftpath.cwd_alias(cwd .. "-not/x"), nil)
eq("cwd_alias: a relative path names none", ftpath.cwd_alias("proj/a.txt"), nil)
eq("in_cwd: a relative path stays", ftpath.in_cwd("proj/a.txt"), "proj/a.txt")
eq("in_cwd: rewritten onto the cwd", ftpath.in_cwd(node_file), cwd .. "/proj/a.txt")
eq("in_cwd: a path outside stays", ftpath.in_cwd(other .. "/o.txt"), other .. "/o.txt")

local cur_node = { type = "file", path = node_file }
local adapter = {
  get_current_node = function()
    return cur_node
  end,
}

-- copy_file_list: ]f / ]F, and the list the save command writes.
require("filetree.features.infra.ignore_list").setup(
  { enabled = true, names = {} },
  { name = "stub" }
)
local list = require("filetree.features.paths.copy_file_list")
list.setup({ keymap_files_abs = false, keymap_files_rel = false }, adapter)

local files = list.files_for({ node_dir }, true)
table.sort(files)
eq("files: relative through the link", files[1], "proj/a.txt")
eq("files: nested too", files[2], "proj/sub/b.txt")

local function register(fn, node)
  cur_node = node
  vim.fn.setreg('"', "")
  fn()
  return vim.fn.getreg('"')
end

eq(
  "]f on a file node",
  register(list.copy_files_rel, { type = "file", path = node_file }),
  "proj/a.txt"
)
eq(
  "]F on a file node: its parent",
  register(list.copy_dirs_rel, { type = "file", path = node_file }),
  "proj"
)
local dirs = vim.split(register(list.copy_dirs_rel, { type = "directory", path = node_dir }), "\n")
table.sort(dirs)
eq("]F on a folder node: the folder", dirs[1], "proj")
eq("]F on a folder node: its child", dirs[2], "proj/sub")
local at_cwd = vim.split(register(list.copy_dirs_rel, { type = "directory", path = cwd }), "\n")
table.sort(at_cwd)
eq("]F on the cwd itself: a dot", at_cwd[1], ".")
eq(
  "]f outside the cwd: stays absolute",
  register(list.copy_files_rel, { type = "file", path = other .. "/o.txt" }),
  other .. "/o.txt"
)

-- path_copy: the relative format and the path:line one.
local pc = require("filetree.features.paths.path_copy")
pc.setup({ enabled = true }, adapter)
eq(
  "path_copy relative",
  ftpath.slashify(register(pc.copy_relative, { type = "file", path = node_file })),
  "proj/a.txt"
)

-- markdown_links: the generated link target.
local ml = require("filetree.features.paths.markdown_links")
ml.setup({ enabled = true }, adapter)
eq(
  "markdown_links: link target",
  register(ml.link_current, { type = "file", path = node_file }),
  "[a.txt](proj/a.txt)"
)

vim.cmd.cd("/")
uv.fs_unlink(link)
vim.fn.delete(scratch, "rf")
print(("\nfiletree.nvim cwd_symlink_relative_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
