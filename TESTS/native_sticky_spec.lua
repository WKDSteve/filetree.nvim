-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_sticky_spec.lua -- the folders the top row of the own tree lies in stay pinned on top
-- while the tree is scrolled (`native.sticky_parents`): which rows are pinned, that the cursor never
-- ends under them, that a click on one jumps to it, and that nothing is there while the tree is not
-- scrolled or the option is off.
--
--   nvim --clean --headless -u NONE -l TESTS/native_sticky_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local files = { "deep/d.lua", "deep/a/a.lua", "deep/a/b/x.lua", "top.lua", "README.md" }
for i = 1, 40 do
  files[#files + 1] = ("deep/a/b/c/f%02d.lua"):format(i)
end
local T = dofile(here .. "/native_drive.lua")({
  name = "native_sticky_spec",
  setup = { native = { watch = false } },
  features = { file_watcher = { enabled = false } },
  files = files,
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local api = vim.api
local adapter = T.adapter
local native = require("filetree.native")
local sticky = require("filetree.native.sticky")
local view_mod = require("filetree.native.view")
local view = adapter.get_state()
T.tree()
view:expand_all()
T.settle(80)
local win, buf = adapter.get_winid(), adapter.get_bufnr()

---@param rel string
---@return integer
local function row_of(rel)
  return view:line_of(dir .. "/" .. rel)
end
---Scroll the tree window so that `top` is its first line, and let the event go through. The cursor
---is put on that line, where Vim leaves a cursor the window was scrolled away from.
---@param top integer
local function scroll_to(top)
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = top, lnum = top })
  end)
  -- a script run with `-l` never reaches the place where Neovim fires WinScrolled
  api.nvim_exec_autocmds("WinScrolled", {})
  T.settle(30)
end
---@return integer[]?
local function pinned()
  local state = sticky.state(view)
  return state and state.rows or nil
end
local function top_line()
  return vim.fn.line("w0", win)
end

local deep, a, b, c = row_of("deep"), row_of("deep/a"), row_of("deep/a/b"), row_of("deep/a/b/c")
local first = row_of("deep/a/b/c/f01.lua")
ok(
  "(the fixture: four folders below one another, then forty files)",
  deep and a == deep + 1 and b == a + 1 and c == b + 1 and first == c + 1
)
ok(
  "(the tree is longer than its window)",
  api.nvim_buf_line_count(buf) > api.nvim_win_get_height(win)
)

-- ── not scrolled ───────────────────────────────────────────────────────────────
scroll_to(1)
eq("not scrolled: nothing is pinned", pinned(), nil)

-- ── scrolled into the deep folder ──────────────────────────────────────────────
scroll_to(first + 5)
eq("scrolled into the deep folder: the three nearest folders are pinned", pinned(), { a, b, c })
local state = sticky.state(view)
eq(
  "... the float shows their lines",
  api.nvim_buf_get_lines(state.buf, 0, -1, false),
  api.nvim_buf_get_lines(buf, a - 1, c, false)
)
local config = api.nvim_win_get_config(state.win)
eq("... one line each", config.height, 3)
eq("... as wide as the tree", config.width, api.nvim_win_get_width(win))
eq(
  "... below the view bar when there is one",
  config.row,
  (vim.fn.getwininfo(win)[1] or {}).winbar or 0
)
eq("... and nobody can end in it", config.focusable, false)
ok(
  "a pinned folder is drawn as its row of the tree is",
  view_mod.decorate_line(buf, a - 1, state.win, state.buf, 0) > 0
)
ok(
  "the cursor was taken along, clear of the float",
  api.nvim_win_get_cursor(win)[1] >= top_line() + 3
)
local float_win = state.win
scroll_to(first + 9)
eq("scrolled on: the same folders", pinned(), { a, b, c })
eq("... in the same float", sticky.state(view).win, float_win)

-- the cursor moved up into the rows the float covers: the window follows
api.nvim_set_current_win(win)
local before = top_line()
eq(
  "(the cursor is on the first row the float leaves visible)",
  api.nvim_win_get_cursor(win)[1],
  before + 3
)
feed("k")
vim.cmd("doautocmd CursorMoved")
T.settle(30)
local rows = pinned() or {}
ok("k at the first visible row scrolls the window", top_line() < before)
ok(
  "... and the cursor is not under the float",
  api.nvim_win_get_cursor(win)[1] >= top_line() + #rows
)

-- ── the end of the deep folder ─────────────────────────────────────────────────
-- the first row the float leaves visible is `x.lua` in b: c is no folder of it
local x = row_of("deep/a/b/x.lua")
scroll_to(x - 3)
eq("at the file after the folder: the folders of that file", pinned(), { deep, a, b })
-- `top.lua` lies in no folder; `d.lua` right above it lies in one. Fewer lines win.
scroll_to(row_of("deep/d.lua"))
local last = pinned()
ok("where the depth falls, the float does not swing: at most one folder", last == nil or #last <= 1)
scroll_to(1)
eq("scrolled back to the top: nothing is pinned", pinned(), nil)
ok("... and the float is gone", not api.nvim_win_is_valid(float_win))

-- ── a click on a pinned folder ─────────────────────────────────────────────────
scroll_to(first + 5)
eq("(pinned again)", pinned(), { a, b, c })
local map = vim.fn.maparg("<LeftMouse>", "n", false, true)
ok("the buffer maps the click", map.buffer == 1 and map.expr == 1)
eq(
  "a click below the float is Vim's",
  sticky.click(view, { winid = win, line = top_line() + 3 }),
  false
)
eq(
  "... one in another window too",
  sticky.click(view, { winid = T.editor_win, line = top_line() }),
  false
)
-- the click goes through the float: the line under it is the second one it covers
eq(
  "a click on the second pinned folder is taken",
  sticky.click(view, { winid = win, line = top_line() + 1 }),
  true
)
T.settle(30)
eq(
  "... and the cursor is on that folder",
  (adapter.get_current_node() or {}).path,
  dir .. "/deep/a/b"
)
-- a Neovim that hands the click to the float itself
scroll_to(first + 5)
state = sticky.state(view)
eq(
  "a click the float itself reports: its window row counts",
  sticky.click(view, { winid = state.win, winrow = 1 }),
  true
)
T.settle(30)
eq("... the first pinned folder", (adapter.get_current_node() or {}).path, dir .. "/deep/a")

-- ── the tree changes under the float ───────────────────────────────────────────
scroll_to(first + 5)
float_win = sticky.state(view).win
adapter.close()
T.settle(30)
eq("the tree closed: nothing is pinned", pinned(), nil)
ok("... the float is gone with it", not api.nvim_win_is_valid(float_win))

-- ── fewer, and switched off ────────────────────────────────────────────────────
---@param count integer|false
local function reopen(count)
  native.reset()
  native.setup({ watch = false, sticky_parents = count })
  adapter.toggle_at("left", { dir = dir })
  view = native.current()
  win = adapter.get_winid()
  view:expand_all()
  T.settle(80)
  scroll_to(row_of("deep/a/b/c/f01.lua") + 5)
end
reopen(1)
eq("sticky_parents = 1: the nearest folder only", pinned(), { row_of("deep/a/b/c") })
reopen(0)
eq("sticky_parents = 0: nothing is pinned", pinned(), nil)
reopen(false)
eq("sticky_parents = false: nothing either", pinned(), nil)

eq("nothing at warning level in the whole run", T.loud(), {})
T.finish()
