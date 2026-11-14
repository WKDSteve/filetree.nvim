-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive_rest_spec.lua -- what the other `native_drive_*_spec.lua` files left: `preview`
-- (the text preview in the editor window, following the cursor), `open_variants` (split, vsplit,
-- tab, buffer list), `window_size_cycler`, `tree_reset`, the jump and bulk keys of `marks`, the
-- sibling keys of `tree_traverse`, `broken_link_notify`.
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_rest_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_rest_spec",
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    preview = { enabled = true, mode = "buffer", cursor_debounce_ms = 10 },
    window_size_cycler = { enabled = true, sizes = { 30, 40, 20 } },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local tree_win = T.adapter.get_winid()
T.mkfile("docs/guide.md", { "# the guide" })
T.mkfile("lua/init.lua", { "-- the init" })

local function current()
  local node = T.adapter.get_current_node()
  return node and node.name or nil
end
local function editor_text()
  local buf = vim.api.nvim_win_get_buf(T.editor_win)
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
end
local function normal_wins()
  local n = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then n = n + 1 end
  end
  return n
end

-- ── preview: <Tab> shows the node in the editor window and follows the cursor ──
local before_preview = vim.api.nvim_win_get_buf(T.editor_win)
T.on("docs/guide.md")
feed("<Tab>")
T.wait(function()
  return editor_text() == "# the guide"
end)
eq("<Tab> shows the file under the cursor in the editor window", editor_text(), "# the guide")
eq("... the focus stays in the tree", vim.api.nvim_get_current_win(), tree_win)
eq("... on the same node", current(), "guide.md")
T.on("lua/init.lua")
T.wait(function()
  return editor_text() == "-- the init"
end)
eq("the preview follows the cursor to another file", editor_text(), "-- the init")
eq("... without opening a window for it", normal_wins(), 2)
T.tree()
feed("<Tab>")
T.wait(function()
  return vim.api.nvim_win_get_buf(T.editor_win) == before_preview
end)
eq(
  "<Tab> again ends the preview: the editor window shows what it showed before",
  vim.api.nvim_win_get_buf(T.editor_win),
  before_preview
)

-- ── open_variants: sg, sv, st, gb ──────────────────────────────────────────────
T.on("lua/init.lua")
feed("sg")
local split_win = vim.api.nvim_get_current_win()
eq(
  "sg opens the file in a vertical split",
  { normal_wins(), T.norm(vim.api.nvim_buf_get_name(0)), split_win ~= tree_win },
  { 3, dir .. "/lua/init.lua", true }
)
eq("... the tree window still shows the tree", vim.api.nvim_win_get_buf(tree_win), T.buf)
vim.api.nvim_win_close(split_win, true)

T.on("docs/guide.md")
feed("sv")
split_win = vim.api.nvim_get_current_win()
eq(
  "sv opens the file in a horizontal split",
  { normal_wins(), T.norm(vim.api.nvim_buf_get_name(0)), split_win ~= tree_win },
  { 3, dir .. "/docs/guide.md", true }
)
ok(
  "... beside the tree, not under it: the tree keeps its full height",
  vim.api.nvim_win_get_height(tree_win) > vim.api.nvim_win_get_height(split_win)
)
vim.api.nvim_win_close(split_win, true)

T.on("lua/mod/a.lua")
feed("st")
eq(
  "st opens the file in a new tab",
  { #vim.api.nvim_list_tabpages(), T.norm(vim.api.nvim_buf_get_name(0)) },
  { 2, dir .. "/lua/mod/a.lua" }
)
vim.cmd("tabclose")
eq("... and the first tab still has its tree", vim.api.nvim_win_get_buf(tree_win), T.buf)

T.on("lua/mod/b.lua")
feed("gb")
local b_buf = vim.fn.bufnr(dir .. "/lua/mod/b.lua")
ok("gb adds the file to the buffer list", b_buf > 0 and vim.bo[b_buf].buflisted)
eq("... without leaving the tree", vim.api.nvim_get_current_win(), tree_win)

-- ── window_size_cycler: w ──────────────────────────────────────────────────────
T.tree()
eq("the tree starts at the configured width", vim.api.nvim_win_get_width(tree_win), 36)
feed("w")
local first = vim.api.nvim_win_get_width(tree_win)
feed("w")
local second = vim.api.nvim_win_get_width(tree_win)
feed("w")
local third = vim.api.nvim_win_get_width(tree_win)
local seen = { first, second, third }
table.sort(seen)
eq("w cycles the width of the tree through the presets", seen, { 20, 30, 40 })
feed("2w")
eq("a count jumps to that preset", vim.api.nvim_win_get_width(tree_win), 40)
eq("... and the tree is still the tree", vim.api.nvim_win_get_buf(tree_win), T.buf)

-- ── tree_reset: <Esc> ──────────────────────────────────────────────────────────
local view = T.adapter.get_state()
T.filetree.feature("filter").apply("init")
T.wait(function()
  local search = view:searching()
  return search ~= nil and search.done
end, 5000)
ok("a filter is on", view:searching() ~= nil)
T.tree()
feed("<Esc>")
T.wait(function()
  return view:searching() == nil
end)
eq("<Esc> in the tree clears the filter", view:searching(), nil)
ok("... and the tree shows everything again", T.shown("README.md") and T.shown("docs"))

-- ── marks: the bulk and jump keys ──────────────────────────────────────────────
local marks = T.filetree.feature("marks")
T.on("docs/guide.md")
feed("m")
T.on("lua/init.lua")
feed("m")
T.on("README.md")
feed("[M")
local jumped_back = current()
feed("]M")
local jumped_on = current()
ok(
  ("[M and ]M jump between the marked nodes (%s, %s)"):format(
    tostring(jumped_back),
    tostring(jumped_on)
  ),
  (jumped_back == "guide.md" or jumped_back == "init.lua")
    and (jumped_on == "guide.md" or jumped_on == "init.lua")
    and jumped_back ~= jumped_on
)
feed("1gm")
local nth = current()
ok(
  "gm with a count jumps to that marked node: " .. tostring(nth),
  nth == "guide.md" or nth == "init.lua"
)
feed("\\mc")
eq("<leader>mc clears the marks", marks.count(), 0)
feed("]m")
ok("]m marks every node the tree shows", marks.count() >= 5)
feed("[m")
eq("[m unmarks them", marks.count(), 0)

-- ── tree_traverse: ]s and [s go to the next and previous sibling ───────────────
T.on("lua/mod/a.lua")
feed("]s")
eq("]s goes to the next entry of the same folder", current(), "b.lua")
feed("[s")
eq("[s goes back", current(), "a.lua")

-- ── broken_link_notify: a dangling link says what it is when it is opened ──────
local dangling = dir .. "/dangling.md"
local made = vim.uv.fs_symlink(dir .. "/nowhere.md", dangling) == true
if made then
  vim.api.nvim_set_current_win(T.editor_win)
  local from = T.mark()
  vim.cmd("edit " .. vim.fn.fnameescape(dangling))
  T.wait(function()
    return #T.loud(from) > 0
  end)
  ok(
    "opening a dangling link says so: " .. tostring(T.loud(from)[1]),
    (T.loud(from)[1] or ""):lower():find("link", 1, true) ~= nil
  )
  vim.cmd("bwipeout!")
  vim.uv.fs_unlink(dangling)
else
  T.na("broken_link_notify: this machine cannot create a link to a file")
end

eq("no prompt went unanswered", T.unanswered, 0)
T.finish()
