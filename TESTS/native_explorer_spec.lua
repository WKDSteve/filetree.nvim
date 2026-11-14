-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_explorer_spec.lua -- the own tree as an explorer of `lib.nvim.explorer` (stage E7): the
-- two questions other plugins ask "whatever tree is open" (the path under the cursor, read again), and
-- what fileops.nvim says after an operation (`User FileopsChanged`, then `reload_all()`).
--
--   nvim --clean --headless -u NONE -l TESTS/native_explorer_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_explorer_spec",
  setup = { native = { watch = false } },
  features = { file_watcher = { enabled = false } },
})
local eq, ok, dir = T.eq, T.ok, T.dir
local view = T.adapter.get_state()
local explorer = require("lib.nvim.explorer")

---What fileops.nvim does at the end of an operation: the event, then the reload of every explorer.
---@param action string
---@param rel string
---@return string[] reloaded
local function fileops(action, rel)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "FileopsChanged",
    data = { action = action, path = dir .. "/" .. rel },
  })
  return explorer.reload_all()
end

-- every refresh of the whole tree, counted: the reload that is skipped must not run one
local refreshes = 0
local real_refresh = view.refresh
view.refresh = function(self, ...)
  refreshes = refreshes + 1
  return real_refresh(self, ...)
end

-- ── who owns the buffer, and the path under the cursor ─────────────────────────
T.on("lua/mod/a.lua")
eq("the tree buffer belongs to the explorer `filetree`", explorer.current(T.buf), "filetree")
eq(
  "the path under the cursor, asked in the tree window",
  T.norm(explorer.current_path()),
  T.norm(dir .. "/lua/mod/a.lua")
)
vim.api.nvim_set_current_win(T.editor_win)
eq("an editor buffer belongs to no explorer", explorer.current(), nil)
eq(
  "... and asked from the editor window with the tree's buffer",
  T.norm(explorer.current_path(T.buf)),
  T.norm(dir .. "/lua/mod/a.lua")
)

-- ── read again ─────────────────────────────────────────────────────────────────
T.tree()
T.mkfile("lua/mod/behind.lua", "return 1\n")
ok(
  "a file made behind the tree's back is not shown (no watcher)",
  not T.shown("lua/mod/behind.lua")
)
ok("reload_all names the tree", vim.tbl_contains(explorer.reload_all(), "filetree"))
ok(
  "... and the file is there",
  T.wait(function()
    return T.shown("lua/mod/behind.lua")
  end)
)
eq("... by one refresh of the tree", refreshes, 1)

-- ── fileops.nvim ───────────────────────────────────────────────────────────────
refreshes = 0
T.mkfile("lua/mod/made.lua", "return 2\n")
fileops("new", "lua/mod/made.lua")
ok(
  "a file fileops made is shown",
  T.wait(function()
    return T.shown("lua/mod/made.lua")
  end)
)
eq("... by reading its folder: the reload after the event reads nothing again", refreshes, 0)

vim.fn.delete(dir .. "/lua/mod/made.lua")
fileops("delete", "lua/mod/made.lua")
ok(
  "a file fileops deleted is gone",
  T.wait(function()
    return not T.shown("lua/mod/made.lua")
  end)
)
eq("... again without a refresh of everything", refreshes, 0)

-- a move names only where the file went: the folder it left is known to nobody but the reload
vim.fn.mkdir(dir .. "/lua/other", "p")
vim.fn.rename(dir .. "/lua/mod/behind.lua", dir .. "/lua/other/behind.lua")
fileops("move", "lua/other/behind.lua")
ok(
  "a file fileops moved is gone from the folder it left",
  T.wait(function()
    return not T.shown("lua/mod/behind.lua")
  end)
)
eq("... by the reload", refreshes, 1)

-- the skipped reload is the one in the same call, not a later one
refreshes = 0
vim.api.nvim_exec_autocmds("User", {
  pattern = "FileopsChanged",
  data = { action = "touch", path = dir .. "/lua/mod/a.lua" },
})
T.settle(50)
explorer.reload_all()
T.settle(50)
eq("a reload some time after an event is a reload", refreshes, 1)

-- a bulk rename announces every file, with a reload each: the tree is read once
refreshes = 0
for _, name in ipairs({ "one", "two", "three" }) do
  fileops("rename", "lua/mod/" .. name .. ".lua")
end
eq("three renames in one tick read nothing before the tick ends", refreshes, 0)
T.settle(50)
eq("... and the tree once after it", refreshes, 1)

-- ── a view of another source ───────────────────────────────────────────────────
vim.api.nvim_set_current_win(T.editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/lua/mod/a.lua"))
T.tree()
view:show("buffers")
T.settle(200)
local on_buffer, on_head = nil, nil
for line, text in ipairs(T.lines()) do
  if text:find("a.lua", 1, true) then on_buffer = on_buffer or line end
  if text:find("Buffers", 1, true) then on_head = on_head or line end
end
vim.api.nvim_win_set_cursor(T.adapter.get_winid(), { on_buffer, 0 })
eq(
  "in the buffers view the path is the one of the buffer under the cursor",
  T.norm(explorer.current_path()),
  T.norm(dir .. "/lua/mod/a.lua")
)
if on_head then
  vim.api.nvim_win_set_cursor(T.adapter.get_winid(), { on_head, 0 })
  eq("a row without a path answers nil", explorer.current_path(), nil)
end
view:show("files")
T.settle(100)

-- ── gone with the tree ─────────────────────────────────────────────────────────
view.refresh = real_refresh
eq("nothing at warning level in the whole run", T.loud(), {})
require("filetree.native").reset()
local names = vim.tbl_map(function(adapter)
  return adapter.name
end, explorer.adapters())
ok("after native.reset the explorer `filetree` is gone", not vim.tbl_contains(names, "filetree"))
eq(
  "... and FileopsChanged has no listener left",
  #vim.api.nvim_get_autocmds({ event = "User", pattern = "FileopsChanged" }),
  0
)

T.finish()
