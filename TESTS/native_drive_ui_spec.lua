-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive_ui_spec.lua -- the ui features on the own tree, each through its key, its click
-- or the event it reacts to, on a real tree window: `node_info`, `breadcrumbs`, `link_marker`,
-- `cursor_hide`, `window_style`, `cheatsheet`, `context_menu` (opened by a right click, an entry
-- picked by key and by click), `kit_slot`.
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_ui_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local linked = false
local windows = vim.fn.has("win32") == 1
local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_ui_spec",
  -- package.json marks the project: the breadcrumbs count from its root
  files = {
    "lua/mod/a.lua",
    "lua/mod/b.lua",
    "lua/init.lua",
    "docs/guide.md",
    "README.md",
    "package.json",
  },
  before_setup = function(bench)
    -- A link to a folder. Windows: a junction (no privilege needed), whose target is always the
    -- whole path. Elsewhere: a symlink with the short relative target.
    if windows then
      linked = vim.uv.fs_symlink(
        bench.dir .. "/docs",
        bench.dir .. "/docs_link",
        { dir = true, junction = true }
      ) == true
    else
      linked = vim.uv.fs_symlink("docs", bench.dir .. "/docs_link") == true
    end
  end,
  features = {
    link_marker = { enabled = true, show_target = true },
    breadcrumbs = { enabled = true, mode = "winbar" },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local tree_win = T.adapter.get_winid()

local function winbar_of(win)
  local bar = vim.wo[win].winbar
  if bar == "" then return "" end
  return vim.api.nvim_eval_statusline(bar, { winid = win, use_winbar = true }).str
end
local function float_text(filetype)
  for _, float in ipairs(T.floats()) do
    if not filetype or float.filetype == filetype then return table.concat(float.lines, "\n") end
  end
  return nil
end

-- ── window_style: the tree window has a blank statusline ───────────────────────
eq("window_style blanks the statusline of the tree window", vim.wo[tree_win].statusline, " ")
ok("... and leaves the editor window's alone", vim.wo[T.editor_win].statusline ~= " ")

-- ── cursor_hide: the cursor is hidden while the tree has the focus ─────────────
T.tree()
T.wait(function()
  return vim.wo[tree_win].winhighlight:find("Cursor:FiletreeCursorHidden", 1, true) ~= nil
end)
ok(
  "cursor_hide hides the cursor in the focused tree: " .. vim.wo[tree_win].winhighlight,
  vim.wo[tree_win].winhighlight:find("Cursor:FiletreeCursorHidden", 1, true) ~= nil
)
ok("... where the cursor line marks the place instead", vim.wo[tree_win].cursorline)
vim.api.nvim_set_current_win(T.editor_win)
T.wait(function()
  return vim.wo[tree_win].winhighlight:find("FiletreeCursorHidden", 1, true) == nil
end)
ok(
  "... and gives it back when the focus leaves",
  vim.wo[tree_win].winhighlight:find("FiletreeCursorHidden", 1, true) == nil
)

-- ── breadcrumbs: the path of the node, in the winbar of the editor window ──────
local tree_bar = winbar_of(tree_win)
T.on("docs/guide.md")
T.wait(function()
  return winbar_of(T.editor_win):find("guide.md", 1, true) ~= nil
end)
local crumbs = winbar_of(T.editor_win)
ok(
  "breadcrumbs shows the node's path from the project root in the editor window: " .. crumbs,
  crumbs:find("docs.+guide%.md") ~= nil
)
eq("... and leaves the tree's own bar (the views) alone", winbar_of(tree_win), tree_bar)

-- ── link_marker: a link carries its sign and its target ────────────────────────
if linked then
  T.on("docs_link")
  local link, plain = T.drawn("docs_link"), T.drawn("docs")
  ok("link_marker draws on a link: " .. link.text, link.text ~= "" and link.text ~= plain.text)
  if windows then
    -- the target of a junction is the whole path: no room for it in a tree this narrow
    T.na("link_marker: the target column, on a junction")
  else
    ok(
      "... the target after it (show_target): " .. link.text,
      link.text:find("-> docs", 1, true) ~= nil
    )
  end
  eq("... and nothing on a plain folder", plain.text, "")
else
  T.na("link_marker: this machine cannot create a link to a folder")
end

-- ── node_info: I ───────────────────────────────────────────────────────────────
T.on("docs/guide.md")
feed("I")
local info = float_text("filetree_node_info")
ok("I opens the info of the node", info ~= nil and info:find("guide.md", 1, true) ~= nil)
T.filetree.feature("node_info").close()
eq("... and it closes again", float_text("filetree_node_info"), nil)
eq(
  "the focus is back in the tree, the cursor still on the node",
  { vim.api.nvim_get_current_win() == tree_win, T.adapter.get_current_node().name },
  { true, "guide.md" }
)

-- ── auto_reveal: a float opened from the tree is not "stepping into the tree" ──
-- The editor window shows README.md, the tree's cursor is on another node. A new window shows the
-- buffer it was created from until its own is set, and focus comes back to the tree when it
-- closes: neither may move the tree's cursor to the editor's file.
local scratch = vim.api.nvim_create_buf(false, true)
local scratch_win = vim.api.nvim_open_win(
  scratch,
  true,
  { relative = "editor", row = 2, col = 2, width = 20, height = 3 }
)
eq(
  "opening a float from the tree leaves the tree's cursor alone",
  T.adapter.get_current_node().name,
  "guide.md"
)
vim.api.nvim_win_close(scratch_win, true)
eq("... and so does closing it", T.adapter.get_current_node().name, "guide.md")
vim.api.nvim_set_current_win(T.editor_win)
vim.api.nvim_set_current_win(tree_win)
eq(
  "stepping into the tree from the editor window still lands on its file",
  T.adapter.get_current_node().name,
  "README.md"
)
T.on("docs/guide.md")

-- ── cheatsheet: ? ──────────────────────────────────────────────────────────────
feed("?")
local sheet = float_text("filetree_cheatsheet") or ""
ok("? opens the cheatsheet on the page of this node", sheet:find("[1 here]", 1, true) ~= nil)
ok("... which names the node", sheet:find("on guide.md", 1, true) ~= nil)
ok("... lists a feature's key that applies to it", sheet:find("ML%s+Markdown link") ~= nil)
ok("... and the tree's own", sheet:find("sw%s+Open the file in a window you pick") ~= nil)
-- an action without a key is listed by its name, not under a key it does not have
ok(
  "... an action without a key by its name",
  sheet:find("without a key", 1, true) ~= nil
    and sheet:find("\n%s+up%s+Show the parent folder") ~= nil
)
eq("... and not under `-`, which is a key", sheet:find("\n%s+%-%s+Show the", 1) ~= nil, false)
feed("<Tab>")
local second = float_text("filetree_cheatsheet") or ""
ok("<Tab> turns to the page of all feature keys", second:find("[2 filetree]", 1, true) ~= nil)
ok("... with the file operations on it", second:find("a%s+Smart create") ~= nil)
T.filetree.feature("cheatsheet").close()
T.close_floats()
T.tree()

-- ── context_menu: a right click opens it on the node that was clicked ──────────
require("ui.contextmenu").setup({ renderer = "kit" })
local real_mousepos = vim.fn.getmousepos
---Put the pointer on a line of a window (what `getmousepos()` then reports).
local function pointer(win, line)
  vim.fn.getmousepos = function()
    return {
      winid = win,
      line = line,
      column = 4,
      screenrow = vim.fn.screenpos(win, line, 1).row,
      screencol = 4,
    }
  end
end
---The menu window and the line of the entry whose text contains `label`.
local function menu_entry(label)
  for _, float in ipairs(T.floats()) do
    for i, text in ipairs(float.lines) do
      if text:find(label, 1, true) then return float.win, i end
    end
  end
  return nil, nil
end

-- the cursor is somewhere else; the click decides
local guide_line = T.adapter.get_node_line(dir .. "/docs/guide.md")
T.on("README.md")
pointer(tree_win, guide_line)
feed("<RightMouse>")
eq(
  "a right click moves the cursor to the clicked node",
  T.adapter.get_current_node().name,
  "guide.md"
)
local menu_win, link_line = menu_entry("Markdown link")
ok("... and opens the menu with the entries of the features", menu_win ~= nil)
ok("... which has the focus", vim.api.nvim_get_current_win() == menu_win)

-- an entry picked by key acts on that node
T.forget_copy()
vim.api.nvim_win_set_cursor(menu_win, { link_line, 0 })
feed("<CR>")
T.wait(function()
  return T.copied() ~= ""
end)
eq("an entry picked with <CR> acts on the clicked node", T.copied(), "[guide.md](docs/guide.md)")
eq("... and the menu is closed", (menu_entry("Markdown link")), nil)

-- an entry picked by a click
T.tree()
local a_line = T.adapter.get_node_line(T.on("lua/mod/a.lua"))
T.on("README.md")
pointer(tree_win, a_line)
feed("<RightMouse>")
local mark_win, mark_line = menu_entry("Toggle mark")
ok("a second right click opens the menu again", mark_win ~= nil)
pointer(mark_win, mark_line)
feed("<LeftMouse>")
T.wait(function()
  return T.filetree.feature("marks").count() == 1
end)
eq(
  "an entry picked by a click acts on the clicked node",
  vim.tbl_map(T.norm, T.filetree.feature("marks").get_marked()),
  { dir .. "/lua/mod/a.lua" }
)
T.filetree.feature("marks").clear_all()
T.close_floats()

-- a click below the last line is no node: no menu
T.tree()
local last = vim.api.nvim_buf_line_count(T.buf)
vim.fn.getmousepos = function()
  return {
    winid = tree_win,
    line = last,
    column = 4,
    screenrow = vim.fn.screenpos(tree_win, last, 1).row + 3,
    screencol = 4,
  }
end
feed("<RightMouse>")
eq("a right click below the last node opens nothing", #T.floats(), 0)
vim.fn.getmousepos = real_mousepos

-- ── kit_slot: the tree and a kit sidebar share the left side ───────────────────
local sidebar = require("lib.nvim.ui.kit.sidebar")
T.tree()
T.settle()
local slot = sidebar.get("filetree")
ok("kit_slot registers the tree as a panel of the kit", slot ~= nil)
eq("... on the side it is on", slot and slot.position, "left")
local notes_panel = sidebar.open({ name = "native_drive_notes", position = "left", enter = false })
T.wait(function()
  return not T.adapter.is_open()
end)
ok("a kit sidebar on the same side takes the tree off the screen", not T.adapter.is_open())
notes_panel:close()
T.wait(function()
  return T.adapter.is_open()
end)
ok("... and closing it brings the tree back", T.adapter.is_open())
eq("... the same tree", T.adapter.get_bufnr(), T.buf)

eq("no prompt went unanswered", T.unanswered, 0)
eq("no warning or error in the whole run", T.loud(), {})

if linked then vim.uv.fs_unlink(dir .. "/docs_link") end
T.finish()
