-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_embed_spec.lua -- the layout `embed`: the directory tree drawn into a buffer another
-- plugin owns, here a float that cannot take the focus (the directory hover of hover.nvim). Lines,
-- order and merged lines as in the tree window; the selection, expand and collapse through the
-- handle; nothing taken (no keymap, no autocmd, no window option) and nothing left after `close`.
--
--   nvim --clean --headless -u NONE -l TESTS/native_embed_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  for _, candidate in ipairs({
    vim.env[dep:upper():gsub("%.", "_") .. "_DIR"] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep,
    root .. "/.deps/" .. dep,
    vim.fn.stdpath("data") .. "/lazy/" .. dep,
  }) do
    if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua") == 1 then
      vim.opt.rtp:prepend(candidate)
      break
    end
  end
end

-- No `vim.o.columns` / `vim.o.lines` in this file: a headless run has no UI, its screen grid stays
-- 80x24 whatever the options say, and the next forced redraw writes past it.

local function say(text)
  io.stdout:write(text, "\n")
end
local passed, failed = 0, 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    say("  ok   " .. name)
  else
    failed = failed + 1
    say(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end
local function ok(name, cond)
  eq(name, cond and true or false, true)
end

vim.g.have_nerd_font = false

local list = require("filetree.native.fs.list")
local watch = require("filetree.native.fs.watch")
local native = require("filetree.native")
-- the tree window's module brings the highlight groups, and its own autocmds once per editor: loaded
-- here so that the counts below are about an embed, not about the first load of the plugin
require("filetree.native.view")

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_embed_%d"):format(base, vim.uv.hrtime() % 1e9)
for _, rel in ipairs({
  "lua/mod/a.lua",
  "lua/mod/b.lua",
  "lua/init.lua",
  "chain/only/leaf.lua",
  "docs/guide.md",
  "README.md",
  "zeta.txt",
}) do
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
end

---Everything the editor holds that an embed could have added to.
local function census()
  return {
    autocmds = #vim.api.nvim_get_autocmds({}),
    wins = #vim.api.nvim_list_wins(),
    bufs = #vim.api.nvim_list_bufs(),
    handles = watch.count(),
  }
end

-- a float that cannot take the focus, as a hover draws it
local editor_win = vim.api.nvim_get_current_win()
local before = census()
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].modifiable = false
local win = vim.api.nvim_open_win(buf, false, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 30,
  height = 8,
  style = "minimal",
  focusable = false,
})
local wo_before = { vim.wo[win].wrap, vim.wo[win].cursorline, vim.wo[win].number }
local with_float = census()

local changes = 0
local tree, err = native.embed(buf, dir, {
  on_change = function()
    changes = changes + 1
  end,
})
ok("embed answers a handle: " .. tostring(err), tree ~= nil)
local function lines()
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- ── the picture ────────────────────────────────────────────────────────────────
eq("the entries of the folder, folders first, a chain as one line", lines(), {
  "▸ chain/only/",
  "▸ docs/",
  "▸ lua/",
  "  README.md",
  "  zeta.txt",
})
eq("the buffer is still not modifiable", vim.bo[buf].modifiable, false)
eq("the caller was told that the lines were written", changes, 1)
eq("the focus stayed where it was", vim.api.nvim_get_current_win(), editor_win)
eq(
  "no option of the window was touched",
  { vim.wo[win].wrap, vim.wo[win].cursorline, vim.wo[win].number },
  wo_before
)
eq("no keymap on the buffer", #vim.api.nvim_buf_get_keymap(buf, "n"), 0)
eq("no autocmd, no window, no buffer, no watcher handle was added", census(), with_float)
ok("the names carry highlights", #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) > 0)

-- ── the selection ──────────────────────────────────────────────────────────────
local current = tree:current()
eq(
  "the selection starts on the first row",
  { current.line, current.kind, current.path },
  { 1, "dir", dir .. "/chain/only" }
)
eq("move goes down", tree:move(2).path, dir .. "/lua")
eq("... and stops at the last row", tree:move(99).line, 5)
eq("... and at the first", tree:move(-99).line, 1)
eq("select by line", tree:select(4).path, dir .. "/README.md")
eq("select by path", tree:select(dir .. "/lua").line, 3)
eq("select of a path that is no row", tree:select(dir .. "/nope"), nil)
eq("... leaves the selection", tree:current().line, 3)
local selection_marks = vim.tbl_filter(function(mark)
  return mark[4].line_hl_group == "FiletreeEmbedSelection"
end, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true }))
eq("one line carries the selection", { #selection_marks, selection_marks[1][2] }, { 1, 2 })

-- ── expand and collapse ────────────────────────────────────────────────────────
eq("expand opens the folder under the selection", tree:expand(), true)
eq(
  "... its entries are drawn",
  vim.list_slice(lines(), 3, 5),
  { "▾ lua/", "  ▸ mod/", "    init.lua" }
)
eq("... the selection stays on the folder", tree:current().path, dir .. "/lua")
eq("expand of an open folder answers false", tree:expand(), false)
eq("expand by path", tree:expand(dir .. "/lua/mod"), true)
ok("... draws the files below", vim.tbl_contains(lines(), "      a.lua"))
eq("expand of a file answers false", tree:expand(dir .. "/README.md"), false)
eq(
  "the rows say what they are",
  vim.tbl_map(function(row)
    return row.kind .. ":" .. row.label
  end, tree:rows()),
  {
    "dir:chain/only",
    "dir:docs",
    "dir:lua",
    "dir:mod",
    "file:a.lua",
    "file:b.lua",
    "file:init.lua",
    "file:README.md",
    "file:zeta.txt",
  }
)
tree:select(dir .. "/zeta.txt")
eq("collapse by path", tree:collapse(dir .. "/lua"), true)
eq("... the rows below are gone", #lines(), 5)
eq("... the selection moved along with its node", tree:current().path, dir .. "/zeta.txt")
tree:select(dir .. "/lua")
eq("toggle opens", tree:toggle(), true)
eq("... with what was open below it", #lines(), 9)
eq("toggle closes", tree:toggle(), true)
eq("collapse of a closed folder answers false", tree:collapse(), false)

-- ── the disk, when asked ───────────────────────────────────────────────────────
vim.fn.writefile({ "x" }, dir .. "/added.txt")
vim.wait(400, function()
  return false
end)
ok(
  "without watch a new file does not appear by itself",
  not vim.tbl_contains(lines(), "  added.txt")
)
tree:refresh()
ok("refresh reads the folders again", vim.tbl_contains(lines(), "  added.txt"))
eq("... and keeps the selection", tree:current().path, dir .. "/lua")

-- ── close ──────────────────────────────────────────────────────────────────────
tree:close()
eq("after close the highlights are gone", #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}), 0)
eq(
  "... the handle answers nothing",
  { tree:current(), tree:move(1), tree:expand(), #tree:rows() },
  { nil, nil, false, 0 }
)
ok("... the buffer is the caller's and still there", vim.api.nvim_buf_is_valid(buf))
tree:close()
eq("close twice is safe, and nothing was left behind", census(), with_float)

-- ── options ────────────────────────────────────────────────────────────────────
local rooted =
  native.embed({ buf = buf, root = dir, show_root = true, max_entries = 2, select = false })
eq("as a table: the root as the first row, the cut announced", lines(), {
  "▾ " .. vim.fn.fnamemodify(dir, ":t") .. "/",
  "  ▸ chain/only/",
  "  ▸ docs/",
  "    … 4 more (showing 2, native.max_entries)",
})
eq("select = false: no selection", rooted:current(), nil)
eq("... and no line highlighted", #vim.tbl_filter(function(mark)
  return mark[4].line_hl_group ~= nil
end, vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })), 0)
rooted:close()

local by_win = native.embed({
  win = win,
  root = dir,
  hide = function(name)
    return name:match("%.txt$") ~= nil
  end,
  group_empty = false,
})
ok("a window instead of a buffer", by_win ~= nil)
eq("hide leaves names out, group_empty = false keeps folders apart", lines(), {
  "▸ chain/",
  "▸ docs/",
  "▸ lua/",
  "  README.md",
})
by_win:close()

-- a hover opens often: the highlight groups are defined while they are missing, not per embed
do
  local defined = 0
  local real_set_hl = vim.api.nvim_set_hl
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_set_hl = function(...)
    defined = defined + 1
    return real_set_hl(...)
  end
  local again = native.embed(buf, dir)
  again:expand(dir .. "/lua")
  again:close()
  vim.api.nvim_set_hl = real_set_hl
  eq("a second embed defines no highlight group (each one forces a full redraw)", defined, 0)
end

-- following the disk
local live = native.embed(buf, dir, { watch = true })
ok("watch = true holds a handle", watch.count() >= 1)
vim.fn.writefile({ "x" }, dir .. "/live.md")
ok(
  "a new file appears by itself",
  vim.wait(4000, function()
    return vim.tbl_contains(lines(), "  live.md")
  end, 20)
)
live:close()
eq("close gives the handle back", watch.count(), 0)

-- what cannot be drawn
eq("no such buffer", { native.embed(99999, dir) }, { nil, "no such buffer" })
local none, why = native.embed(buf, dir .. "/README.md")
ok(
  "a file is no directory: " .. tostring(why),
  none == nil and why:find("not a directory", 1, true) ~= nil
)
eq("no directory given", { native.embed(buf, "") }, { nil, "no directory given" })

vim.api.nvim_win_close(win, true)
vim.api.nvim_buf_delete(buf, { force = true })
-- (the autocmds are compared around the embed above: opening the first float of the editor adds one
-- that is nobody's here)
local after = census()
eq(
  "with the caller's float gone no window, buffer or handle is left",
  { after.wins, after.bufs, after.handles },
  { before.wins, before.bufs, before.handles }
)
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_embed_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
