-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_view_spec.lua -- the own tree (backend `native`) against a real directory, through the
-- adapter contract: the window and its options, lines and nodes, folding, reveal, refresh that keeps
-- open folders, sort, merged folder lines, opening files, positions, two tabs sharing one read.
--
--   nvim --clean --headless -u NONE -l TESTS/native_view_spec.lua

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

-- Results go to stdout directly, not through print(): Neovim 0.12.2 segfaults in a headless `-l` run
-- when the screen is redrawn (`:redraw`, or a `vim.wait` that processes events) after a dozen
-- print() lines.
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

vim.o.columns = 120
vim.o.lines = 40
vim.g.have_nerd_font = false -- no icons: the lines below are plain text on every machine

local list = require("filetree.native.fs.list")
local native = require("filetree.native")
require("filetree.config").setup({})
local adapter = require("filetree.adapter.native")

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = base .. "/ft_native_" .. vim.uv.hrtime()
local function mkfile(rel, text)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ text or "x" }, path)
  return path
end
mkfile("a/a1.lua")
mkfile("a/a2.lua")
mkfile("a/deep/x.txt")
mkfile("chain/only/inner/leaf.txt")
vim.fn.mkdir(dir .. "/empty", "p")
mkfile("B.txt")
mkfile("c.txt", "larger content than the others")
mkfile(".hidden")

local function lines()
  return vim.api.nvim_buf_get_lines(adapter.get_bufnr(), 0, -1, false)
end
local function names(filter)
  return vim.tbl_map(function(node)
    return node.name
  end, adapter.get_visible_nodes(filter))
end
local editor_win = vim.api.nvim_get_current_win()

-- ── nothing before the tree was asked for ──────────────────────────────────────
eq("is_available", adapter.is_available(), true)
eq("is_open before anything", { adapter.is_open() }, { false })
eq(
  "no window, no buffer, no node yet",
  { adapter.get_winid(), adapter.get_bufnr(), adapter.get_current_node() },
  {}
)
eq("close with no tree answers false", adapter.close(), false)

-- ── open ───────────────────────────────────────────────────────────────────────
ok("toggle_at left opens", adapter.toggle_at("left", { dir = dir }))
local win, buf = adapter.get_winid(), adapter.get_bufnr()
eq("is_open", { adapter.is_open() }, { true, buf })
eq("the tree window has the focus after a toggle", vim.api.nvim_get_current_win(), win)
eq("filetype", vim.bo[buf].filetype, "filetree")
eq("buftype / listed", { vim.bo[buf].buftype, vim.bo[buf].buflisted }, { "nofile", false })
eq("the view name is on the buffer", vim.b[buf].filetree_view, "files")
eq("not modifiable", vim.bo[buf].modifiable, false)
eq("root", adapter.get_root_path(), dir)
eq("position", adapter.get_position(), "left")
eq("it is the leftmost window", vim.api.nvim_win_get_position(win)[2], 0)
eq("width", vim.api.nvim_win_get_width(win), 32)
eq("window options", {
  vim.wo[win].number,
  vim.wo[win].wrap,
  vim.wo[win].foldmethod,
  vim.wo[win].foldenable,
  vim.wo[win].winfixwidth,
  vim.wo[win].winfixbuf,
}, { false, false, "manual", false, true, true })
eq("the editor window keeps its own options", vim.wo[editor_win].winfixbuf, false)

eq("lines: root, folders first, then names without regard to case", lines(), {
  "▾ " .. list.basename(dir) .. "/",
  "  ▸ a/",
  "  ▸ chain/only/inner/",
  "  ▸ empty/",
  "    .hidden",
  "    B.txt",
  "    c.txt",
})

-- ── nodes ──────────────────────────────────────────────────────────────────────
local nodes = adapter.get_visible_nodes()
eq(
  "visible nodes: the root line is not one",
  names(),
  { "a", "chain/only/inner", "empty", ".hidden", "B.txt", "c.txt" }
)
eq("node of a folder", nodes[1], {
  id = dir .. "/a",
  name = "a",
  path = dir .. "/a",
  type = "directory",
  depth = 1,
  line_number = 2,
  is_expanded = false,
})
eq(
  "node of a file: is_expanded is nil",
  { nodes[5].type, nodes[5].is_expanded, nodes[5].line_number },
  { "file", nil, 6 }
)
eq("filter files", names("files"), { ".hidden", "B.txt", "c.txt" })
eq("filter folders", names("folders"), { "a", "chain/only/inner", "empty" })
eq("get_node_line", adapter.get_node_line(dir .. "/B.txt"), 6)
eq(
  "get_node_line: backslashes and a lower-case drive are the same path",
  adapter.get_node_line((dir .. "/B.txt"):gsub("/", "\\"):gsub("^%u", string.lower)),
  6
)
eq("get_node_line: unknown", adapter.get_node_line(dir .. "/nope"), nil)
eq("get_node_at_line (0-based)", adapter.get_node_at_line(buf, 5).name, "B.txt")
eq("get_node_at_line: the root line", adapter.get_node_at_line(buf, 0), nil)
eq("get_node_at_line: past the end", adapter.get_node_at_line(buf, 99), nil)
eq(
  "get_node_at_line: a foreign buffer",
  adapter.get_node_at_line(vim.api.nvim_win_get_buf(editor_win), 1),
  nil
)
eq("get_state(buf) is the view", adapter.get_state(buf).root, dir)
eq("an empty folder is a folder", { nodes[3].type, nodes[3].is_expanded }, { "directory", false })

-- ── cursor and folding ─────────────────────────────────────────────────────────
ok("scroll_to_line", adapter.scroll_to_line(6))
vim.cmd("doautocmd CursorMoved")
eq("current node", adapter.get_current_node().name, "B.txt")
ok("expand_node", adapter.expand_node(nodes[1]))
eq(
  "lines after expand",
  vim.list_slice(lines(), 2, 5),
  { "  ▾ a/", "    ▸ deep/", "      a1.lua", "      a2.lua" }
)
eq(
  "the cursor stayed on its node",
  { vim.api.nvim_win_get_cursor(win)[1], adapter.get_current_node().name },
  { 9, "B.txt" }
)
eq("is_expanded follows", adapter.get_visible_nodes()[1].is_expanded, true)
eq("depth of a child", adapter.get_node_at_line(buf, 2).depth, 2)
ok("expand_node on an open folder is fine", adapter.expand_node(nodes[1]))
ok("collapse_node", adapter.collapse_node(nodes[1]))
eq("cursor after collapse", vim.api.nvim_win_get_cursor(win)[1], 6)
eq("collapse_node on a closed folder", adapter.collapse_node(nodes[1]), false)

-- keys of the tree itself
vim.api.nvim_win_set_cursor(win, { 2, 0 })
vim.cmd("doautocmd CursorMoved")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
vim.wait(200, function()
  return #lines() == 10
end)
eq("<CR> on a folder opens it (read without blocking)", #lines(), 10)
vim.api.nvim_feedkeys("h", "x", false)
eq("h closes it", #lines(), 7)
eq("the root does not close", { adapter.collapse_node({ path = dir }), #lines() }, { false, 7 })

-- ── merged folder line ─────────────────────────────────────────────────────────
eq(
  "a folder inside a merged line resolves to that line",
  adapter.get_node_line(dir .. "/chain/only"),
  3
)
eq(
  "the merged node carries the innermost path",
  adapter.get_node_at_line(buf, 2).path,
  dir .. "/chain/only/inner"
)
adapter.expand_node({ path = dir .. "/chain" })
eq("expanding by an outer folder of the chain opens the line", lines()[4], "      leaf.txt")
adapter.collapse_node({ path = dir .. "/chain/only/inner" })

-- ── reveal ─────────────────────────────────────────────────────────────────────
vim.api.nvim_set_current_win(editor_win)
ok("open_reveal", adapter.open_reveal(dir .. "/a/deep/x.txt"))
eq("open_reveal does not take the focus", vim.api.nvim_get_current_win(), editor_win)
eq(
  "the folders on the way are open",
  vim.list_slice(lines(), 2, 4),
  { "  ▾ a/", "    ▾ deep/", "        x.txt" }
)
eq("the tree's cursor is on the file", vim.api.nvim_win_get_cursor(win)[1], 4)
eq("the root stayed", adapter.get_root_path(), dir)
ok("open_reveal with a root", adapter.open_reveal(dir .. "/a/deep/x.txt", 0, dir .. "/a"))
eq("... roots the tree there", { adapter.get_root_path(), lines()[1] }, { dir .. "/a", "▾ a/" })
eq("... and reveals", adapter.get_node_line(dir .. "/a/deep/x.txt"), 3)
ok("open_reveal of a file outside the root", adapter.open_reveal(dir .. "/B.txt"))
eq("... roots the tree at its folder", adapter.get_root_path(), dir)
ok("open_reveal with parent_levels", adapter.open_reveal(dir .. "/a/deep/x.txt", 2))
eq("... ascends that many folders", adapter.get_root_path(), dir .. "/a")
ok("set_root", adapter.set_root(dir))
eq("set_root to something that is no folder", adapter.set_root(dir .. "/B.txt"), false)
eq("... leaves the root", adapter.get_root_path(), dir)

-- ── refresh keeps what is open ─────────────────────────────────────────────────
adapter.open_reveal(dir .. "/a/deep/x.txt")
mkfile("a/deep/new.txt")
mkfile("zz.txt")
vim.fn.delete(dir .. "/B.txt")
local rendered = 0
local unsubscribe = adapter.on_render(function(bufnr)
  if bufnr == buf then rendered = rendered + 1 end
end)
ok("refresh", adapter.refresh())
eq("new and removed entries show, open folders stay open", lines(), {
  "▾ " .. list.basename(dir) .. "/",
  "  ▾ a/",
  "    ▾ deep/",
  "        new.txt",
  "        x.txt",
  "      a1.lua",
  "      a2.lua",
  "  ▸ chain/only/inner/",
  "  ▸ empty/",
  "    .hidden",
  "    c.txt",
  "    zz.txt",
})
eq(
  "the cursor followed its node down a line",
  adapter.get_node_at_line(buf, vim.api.nvim_win_get_cursor(win)[1] - 1).name,
  "x.txt"
)
ok("on_render fired for this buffer", rendered >= 1)
rendered = 0
adapter.refresh()
ok("a refresh that changes nothing still reaches on_render", rendered >= 1)
unsubscribe()
rendered = 0
adapter.refresh()
eq("after unsubscribe nothing arrives", rendered, 0)
ok("redraw", adapter.redraw())

-- a folder that vanished while it was open
vim.fn.delete(dir .. "/a/deep", "rf")
adapter.refresh()
eq(
  "a removed open folder is gone with its rows",
  vim.list_slice(lines(), 2, 4),
  { "  ▾ a/", "      a1.lua", "      a2.lua" }
)

-- ── expanded paths, collapse_all ───────────────────────────────────────────────
adapter.expand_node({ path = dir .. "/chain/only/inner" })
eq("get_expanded_paths", adapter.get_expanded_paths(), { dir .. "/a", dir .. "/chain/only/inner" })
ok("collapse_all with a path to keep", adapter.collapse_all(dir .. "/a/a2.lua"))
eq(
  "only the chain to it stays open",
  { adapter.get_expanded_paths(), adapter.get_current_node().name },
  { { dir .. "/a" }, "a2.lua" }
)
ok("collapse_all", adapter.collapse_all())
eq(
  "everything is closed, the cursor is on the top-level entry",
  { adapter.get_expanded_paths(), adapter.get_current_node().name, #lines() },
  { {}, "a", 7 }
)
ok(
  "expand_paths",
  adapter.expand_paths({ dir .. "/chain/only/inner", dir .. "/a", dir .. "/gone" })
)
eq(
  "... opens what still exists",
  adapter.get_expanded_paths(),
  { dir .. "/a", dir .. "/chain/only/inner" }
)
adapter.collapse_all()

-- ── sort ───────────────────────────────────────────────────────────────────────
eq("get_sort", adapter.get_sort(), { kind = "name", descending = false })
ok("set_sort name descending", adapter.set_sort("name", true))
eq(
  "folders stay first, names descend",
  names(),
  { "empty", "chain/only/inner", "a", "zz.txt", "c.txt", ".hidden" }
)
ok("set_sort size", adapter.set_sort("size", true))
eq("the largest file first", names("files")[1], "c.txt")
adapter.set_sort("name", false)

-- ── hiding the names of the ignore list ────────────────────────────────────────
vim.fn.mkdir(dir .. "/node_modules", "p")
adapter.refresh()
ok("an ignored name is shown by default", vim.tbl_contains(names(), "node_modules"))
-- the ignore list feature is not set up in this spec: hand the view the predicate it would get
adapter.get_state()._opts.hide = function()
  return function(name)
    return name == "node_modules"
  end
end
adapter.get_state():set_hide_ignored(true)
ok("... and hidden on request", not vim.tbl_contains(names(), "node_modules"))
adapter.get_state():set_hide_ignored(false)

-- ── marks on lines ─────────────────────────────────────────────────────────────
ok("highlight_node", adapter.highlight_node(dir .. "/c.txt", "Visual"))
ok("sign_node", adapter.sign_node(dir .. "/c.txt", ">", "Visual"))
eq(
  "highlight_node on a path that is not shown",
  adapter.highlight_node(dir .. "/nope", "Visual"),
  false
)
ok(
  "unhighlight_node / unsign_node",
  adapter.unhighlight_node(dir .. "/c.txt") and adapter.unsign_node(dir .. "/c.txt")
)

-- ── opening a file ─────────────────────────────────────────────────────────────
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { adapter.get_node_line(dir .. "/c.txt"), 0 })
vim.cmd("doautocmd CursorMoved")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
eq(
  "<CR> on a file opens it in the editor window",
  { vim.api.nvim_get_current_win(), list.norm(vim.api.nvim_buf_get_name(0)) },
  { editor_win, dir .. "/c.txt" }
)
eq("the tree window still shows the tree", vim.api.nvim_win_get_buf(win), buf)
ok("open_file vsplit", adapter.open_file(dir .. "/zz.txt", "vsplit"))
eq(
  "... in a new window, not in the tree's",
  { #vim.api.nvim_tabpage_list_wins(0), vim.api.nvim_win_get_buf(win) },
  { 3, buf }
)
eq("... and the focus is on the file", list.norm(vim.api.nvim_buf_get_name(0)), dir .. "/zz.txt")
vim.cmd("close")

-- ── close, toggle, positions ───────────────────────────────────────────────────
ok("close", adapter.close())
eq("closed", { adapter.is_open() }, { false })
eq("the position is remembered while closed", adapter.get_position(), "left")
eq("the buffer stays (state survives)", vim.api.nvim_buf_is_valid(buf), true)
ok("open_cwd shows it again", adapter.open_cwd())
eq("open_cwd does not take the focus", vim.api.nvim_get_current_win() ~= adapter.get_winid(), true)
eq("the same buffer is reused", adapter.get_bufnr(), buf)
ok("toggle_at right moves it", adapter.toggle_at("right"))
eq(
  "right: the rightmost window",
  { adapter.get_position(), vim.api.nvim_win_get_position(adapter.get_winid())[2] > 0 },
  { "right", true }
)
ok("toggle_at right again closes", adapter.toggle_at("right"))
eq("closed again", { adapter.is_open() }, { false })
ok("toggle_at float", adapter.toggle_at("float"))
eq("float: a floating window, no fixed buffer", {
  vim.api.nvim_win_get_config(adapter.get_winid()).relative,
  vim.wo[adapter.get_winid()].winfixbuf,
}, { "editor", false })
adapter.toggle_at("float")
local before = vim.api.nvim_get_current_buf()
ok("toggle_at current", adapter.toggle_at("current"))
eq(
  "current: the tree is in the editor window",
  { adapter.get_winid(), vim.api.nvim_get_current_buf() },
  { vim.api.nvim_get_current_win(), buf }
)
adapter.toggle_at("current")
eq("... and closing gives the window its buffer back", vim.api.nvim_get_current_buf(), before)

-- reveal with a toggle
ok("toggle_at with reveal", adapter.toggle_at("left", { reveal = true, file = dir .. "/a/a1.lua" }))
eq("the cursor is on the revealed file", adapter.get_current_node().name, "a1.lua")
adapter.close()

-- ── the last window of a tab ───────────────────────────────────────────────────
vim.cmd("tabnew")
local scans = list.stats.scans
adapter.toggle_at("left", { dir = dir })
eq("a second tab has its own view", adapter.get_bufnr() ~= buf, true)
eq("... and reads no folder the first one read", list.stats.scans, scans)
vim.cmd("wincmd l | close")
eq("the tree is the only window of the tab", #vim.api.nvim_tabpage_list_wins(0), 1)
ok("close does not fail there", adapter.close())
eq(
  "the window stays and shows another buffer",
  { adapter.is_open(), vim.bo.filetype ~= "filetree", #vim.api.nvim_list_tabpages() },
  { false, true, 2 }
)
vim.cmd("tabclose")
eq("back in the first tab its view answers", adapter.get_bufnr(), buf)

-- ── the trash history viewer no longer shares the tree's filetype ──────────────
local undo =
  table.concat(vim.fn.readfile(root .. "/lua/filetree/features/fileops/trash/undo.lua"), "\n")
ok(
  "the trash history is not filetype `filetree`",
  undo:find('filetype = "filetree"', 1, true) == nil
)

-- ── found in review ────────────────────────────────────────────────────────────
adapter.toggle_at("left", { dir = dir })
adapter.collapse_all()

-- a cursor moved by the API belongs to its new node at once, not after CursorMoved
local c_line = adapter.get_node_line(dir .. "/c.txt")
ok("scroll_to_line", adapter.scroll_to_line(c_line))
adapter.expand_node({ path = dir .. "/a" })
eq(
  "a cursor set by scroll_to_line stays on that node when rows above it come",
  adapter.get_node_at_line(
    adapter.get_bufnr(),
    vim.api.nvim_win_get_cursor(adapter.get_winid())[1] - 1
  ).name,
  "c.txt"
)
vim.api.nvim_win_set_cursor(adapter.get_winid(), { adapter.get_node_line(dir .. "/zz.txt"), 0 })
adapter.collapse_node({ path = dir .. "/a" })
eq(
  "... and one set with nvim_win_set_cursor, without a CursorMoved in between",
  adapter.get_node_at_line(
    adapter.get_bufnr(),
    vim.api.nvim_win_get_cursor(adapter.get_winid())[1] - 1
  ).name,
  "zz.txt"
)
eq("scroll_to_line past the end answers false", adapter.scroll_to_line(9999), false)

-- open_cwd brings a tree back as it was left, it does not root it at the cwd again
adapter.set_root(dir .. "/a")
adapter.close()
adapter.open_cwd()
eq("open_cwd keeps the root of an existing view", adapter.get_root_path(), dir .. "/a")
adapter.set_root(dir)

-- a folder that answers after the root changed must not write into the new tree
do
  local held
  local real_list = list.list
  list.list = function(path, cb)
    if path == dir .. "/chain/only/inner" then
      held = function()
        real_list(path, cb)
      end
      return
    end
    real_list(path, cb)
  end
  list.invalidate(dir .. "/chain/only/inner")
  local state = adapter.get_state()
  state:toggle(dir .. "/chain/only/inner") -- asynchronous: the read is held back
  ok("the folder is being read", held ~= nil)
  adapter.set_root(dir .. "/a")
  local shown = lines()
  held()
  vim.wait(300, function()
    return false
  end)
  eq("an answer for the old tree leaves the new one alone", lines(), shown)
  list.list = real_list
  adapter.set_root(dir)
end

-- the test for hidden names is built once per listing
do
  local built = 0
  local state = adapter.get_state()
  state._opts.hide = function()
    built = built + 1
    return function(name)
      return name == "node_modules"
    end
  end
  state:set_hide_ignored(true)
  ok(
    ("the hide test is built per listing, not per entry (%d times)"):format(built),
    built >= 1 and built <= 3
  )
  state:set_hide_ignored(false)
end

-- inside(): the separator counts, a bare root already ends in one
eq(
  "inside: a folder and what is below it",
  { list.inside("/a/b", "/a/b"), list.inside("/a/b", "/a/b/c") },
  { true, true }
)
eq("inside: a longer sibling name is not below", list.inside("/a/b", "/a/bc/d"), false)
eq(
  "inside: the file system root",
  { list.inside("/", "/x/y"), list.inside("C:/", "C:/x") },
  { true, true }
)
eq("inside: another drive", list.inside("C:/", "D:/x"), false)
eq(
  "norm keeps a bare root",
  { list.norm("c:\\"), list.norm("/"), list.norm("c:\\a\\") },
  { "C:/", "/", "C:/a" }
)
eq(
  "parent of an entry of a drive root",
  { list.parent("C:/x"), list.parent("/x"), list.parent("/") },
  { "C:/", "/" }
)

-- ── 10 000 entries in one folder ───────────────────────────────────────────────
local big = dir .. "/big"
vim.fn.mkdir(big, "p")
for i = 1, 10000 do
  local fd = vim.uv.fs_open(("%s/f%05d.txt"):format(big, i), "w", 420)
  vim.uv.fs_close(fd)
end
adapter.toggle_at("left", { dir = dir })
adapter.refresh()
local t0 = vim.uv.hrtime()
adapter.expand_node({ path = big })
local expand_ms = (vim.uv.hrtime() - t0) / 1e6
eq("10k entries: all of them are lines", #lines() > 10000, true)
say(("  info 10k entries: expand (read, sort, model, 10k buffer lines) %.1f ms"):format(expand_ms))
ok(("10k entries: expand under 1500 ms (%.0f ms)"):format(expand_ms), expand_ms < 1500)
t0 = vim.uv.hrtime()
adapter.collapse_node({ path = big })
adapter.expand_node({ path = big })
local again_ms = (vim.uv.hrtime() - t0) / 1e6
say(("  info 10k entries: close and open again from the model %.1f ms"):format(again_ms))
ok(("10k entries: reopening under 500 ms (%.0f ms)"):format(again_ms), again_ms < 500)
-- Not through `:redraw`: Neovim 0.12.2 segfaults in a headless `-l` run when a redraw follows a
-- dozen print() lines (no plugin needed to see it). The provider's line function is called directly.
local view_mod = require("filetree.native.view")
local big_buf = adapter.get_bufnr()
t0 = vim.uv.hrtime()
local spans = 0
for lnum = 0, 49 do
  spans = spans + view_mod.decorate_line(big_buf, lnum)
end
local draw_ms = (vim.uv.hrtime() - t0) / 1e6
say(("  info 10k entries: decorating 50 visible lines %.2f ms"):format(draw_ms))
ok("decorating a screen of lines highlights something", spans >= 50)
ok(
  ("10k entries: a screen of lines is decorated in under 10 ms (%.2f ms)"):format(draw_ms),
  draw_ms < 10
)
eq(
  "nothing is stored in the buffer for it",
  #vim.api.nvim_buf_get_extmarks(
    big_buf,
    vim.api.nvim_create_namespace("filetree_native"),
    0,
    -1,
    {}
  ),
  0
)
eq(
  "a buffer that is no tree is left alone",
  view_mod.decorate_line(vim.api.nvim_create_buf(false, true), 0),
  0
)

native.reset()
eq("reset closes the tree", { adapter.is_open() }, { false })
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_view_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
