-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_root_history_spec.lua -- the history of roots of the own tree (`<BS>` back, `g<BS>`
-- forward) and "expand all" (`E`): level by level, with a cap, saying how many folders it opened and
-- how many it left closed.
--
--   nvim --clean --headless -u NONE -l TESTS/native_root_history_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_root_history_spec",
  setup = { native = { watch = false, expand_all_max = 6 } },
  features = { file_watcher = { enabled = false } },
  files = {
    "a/one/x.lua",
    "a/two/t.lua",
    "a/two/deep/y.lua",
    "a/two/deep/er/z.lua",
    "b/b.lua",
    "b/three/w.lua",
    "c/file.lua",
    "README.md",
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local adapter = T.adapter
local view = adapter.get_state()
T.tree()

-- ── the history of roots ───────────────────────────────────────────────────────
local mark = T.mark()
feed("<BS>")
ok("back with no history says so", T.told("no root to go back to", mark))
eq("... and the root stays", view.root, dir)

ok("set_root to a folder", view:set_root(dir .. "/a"))
ok("... and to one below", view:set_root(dir .. "/a/two"))
T.tree()
feed("<BS>")
eq("<BS> goes back one root", view.root, dir .. "/a")
eq(
  "... the cursor is on the folder it came from",
  (adapter.get_current_node() or {}).path,
  dir .. "/a/two"
)
feed("<BS>")
eq("<BS> again: the root before that", view.root, dir)
eq(
  "... the cursor on the folder it came from",
  (adapter.get_current_node() or {}).path,
  dir .. "/a"
)
mark = T.mark()
feed("<BS>")
ok("at the start of the history it says so", T.told("no root to go back to", mark))
feed("g<BS>")
eq("g<BS> goes forward again", view.root, dir .. "/a")
feed("g<BS>")
eq("... and again", view.root, dir .. "/a/two")
mark = T.mark()
feed("g<BS>")
ok("at the end of the history it says so", T.told("no root to go forward to", mark))
feed("<BS>")
eq("(back to a)", view.root, dir .. "/a")
view:set_root(dir .. "/b")
mark = T.mark()
T.tree()
feed("g<BS>")
ok("a new root after going back forgets the way forward", T.told("no root to go forward to", mark))
feed("-")
eq("(`-` shows the parent as the root)", view.root, dir)
feed("<BS>")
eq("`-` is a step of the history too", view.root, dir .. "/b")
-- a root that is gone is passed over
view:set_root(dir .. "/c")
view:set_root(dir .. "/a")
vim.fn.delete(dir .. "/c", "rf")
T.tree()
feed("<BS>")
eq("a root that is gone is passed over", view.root, dir .. "/b")
view:set_root(dir)
T.tree()
-- the folder deleted above is still a row (the bench does not watch the disk): read again
adapter.refresh()
T.wait(function()
  return not T.shown("c")
end)

-- ── expand all ─────────────────────────────────────────────────────────────────
local function open_folders()
  return #adapter.get_expanded_paths()
end
adapter.collapse_all()
T.settle(50)
eq("(everything closed)", open_folders(), 0)
T.on("a")
mark = T.mark()
feed("E")
T.settle(80)
ok("E on a folder opens what lies below it", T.shown("a/one/x.lua") and T.shown("a/two/deep/y.lua"))
ok("... on every level", T.shown("a/two/deep/er/z.lua"))
ok("... and nothing next to it", not T.shown("b/three"))
ok("(the folder next to it is still closed)", T.shown("b") and not T.shown("b/b.lua"))
ok("it says how many folders it opened", T.told("opened 5 folder(s)", mark))
eq("the cursor stays on the folder", (adapter.get_current_node() or {}).path, dir .. "/a")

adapter.collapse_all()
T.settle(50)
T.on("a")
local opened, left = view:expand_all(dir .. "/a", 2)
eq("with a cap of two: two folders opened", opened, 2)
ok(
  "... the shallowest first",
  T.shown("a/one") and T.shown("a/two") and not T.shown("a/two/deep/y.lua")
)
ok("... and it counts what it left closed", left >= 1)

adapter.collapse_all()
T.settle(50)
-- the cap of the option (6), on the whole tree: seven folders
vim.api.nvim_win_set_cursor(adapter.get_winid(), { 1, 0 })
vim.cmd("doautocmd CursorMoved")
mark = T.mark()
feed("E")
T.settle(80)
ok(
  "E on the root opens level by level up to native.expand_all_max",
  T.told("opened 6 folder(s)", mark)
)
ok("... and says that a folder is left", T.told("1 more left closed (native.expand_all_max)", mark))
ok(
  "... the upper levels are open before the deepest one",
  T.shown("a/one/x.lua") and T.shown("b/three/w.lua")
)
ok(
  "... which is the one left closed",
  T.shown("a/two/deep/er") and not T.shown("a/two/deep/er/z.lua")
)

adapter.collapse_all()
T.settle(50)
T.on("README.md")
mark = T.mark()
feed("E")
T.settle(80)
ok("E on a file acts on the folder the file lies in", T.shown("a/one") and T.told("opened", mark))

eq("nothing at warning level in the whole run", T.loud(), {})
T.finish()
