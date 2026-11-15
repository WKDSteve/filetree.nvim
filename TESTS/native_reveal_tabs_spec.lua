-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_reveal_tabs_spec.lua -- two tabs, each with a tree on its own project: coming back to
-- the tree window of the first tab must not reveal the file entered last in the second one (that
-- re-rooted the tree of the first tab to the project of the second; found by a sheet of images.nvim).
--
--   nvim --clean --headless -u NONE -l TESTS/native_reveal_tabs_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_reveal_tabs_spec",
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    auto_reveal = { enabled = true, debounce_ms = 10, sync_on_enter = true },
  },
  files = { "site/index.md", "site/about.md", "README.md" },
})
local eq, ok, dir = T.eq, T.ok, T.dir
local api = vim.api
local adapter = T.adapter
local native = require("filetree.native")

-- a second project next to the first
local blog = dir .. "_blog"
vim.fn.mkdir(blog .. "/posts", "p")
vim.fn.writefile({ "# Post" }, blog .. "/posts/post.md")

T.tree()
local view1 = native.current()
local tab1 = api.nvim_get_current_tabpage()
eq("(tab 1: the tree shows the first project)", view1.root, dir)
-- the cursor is in the tree window of tab 1 when the tab is left
api.nvim_set_current_win(adapter.get_winid())
T.settle(700)

vim.cmd("tabedit " .. vim.fn.fnameescape(blog .. "/posts/post.md"))
vim.cmd("tcd " .. vim.fn.fnameescape(blog))
adapter.toggle_at("left", { dir = blog })
T.settle(100)
local view2 = native.current()
ok("(tab 2 has a tree of its own)", view2 ~= view1)
eq("(... on the second project)", view2.root, T.norm(blog))
-- back in the editor window of tab 2, where its file is entered once more
vim.cmd("wincmd p")
vim.cmd("doautocmd BufEnter")
T.settle(700)

api.nvim_set_current_tabpage(tab1)
T.settle(300)
eq("back in tab 1 the cursor is in its tree window", api.nvim_get_current_win(), view1.win)
eq("the tree of tab 1 still shows its own project", view1.root, dir)
eq("... and the tree of tab 2 its own", view2.root, T.norm(blog))
eq("both roots are there", native.roots(), { dir, T.norm(blog) })
eq("the working directory of tab 1 is its project", T.norm(vim.fn.getcwd()), dir)

-- the fallback still works inside a tab: the file entered last in THIS tab is the one revealed
vim.cmd("wincmd p")
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/site/about.md"))
T.settle(100)
vim.cmd("enew") -- the window left behind holds no file now: the remembered one is used
api.nvim_set_current_win(view1.win)
T.settle(300)
eq(
  "entering the tree from a window without a file reveals the file entered last in this tab",
  (adapter.get_current_node() or {}).path,
  dir .. "/site/about.md"
)

vim.cmd("tabonly")
vim.fn.delete(blog, "rf")
eq("nothing at warning level in the whole run", T.loud(), {})
T.finish()
