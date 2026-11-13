-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_features_spec.lua -- the features on the own tree: a full `setup({ adapter = "native" })`
-- and what the user-facing features then do in a real tree window. The conformance run of the backend:
-- every case here is a feature written against the adapter contract, driven through its own key or API.
--
--   nvim --clean --headless -u NONE -l TESTS/native_features_spec.lua

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

vim.o.columns = 140
vim.o.lines = 45
vim.g.have_nerd_font = false
vim.g.mapleader = "\\"

local list = require("filetree.native.fs.list")

-- every message of the run, to see that setup and the features say nothing they should not
local notes = {}
local real_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end
local function loud()
  local out = {}
  for _, note in ipairs(notes) do
    if note.level >= vim.log.levels.WARN then out[#out + 1] = note.msg end
  end
  return out
end

-- ── fixture: a small project ───────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_feat_%d"):format(base, vim.uv.hrtime() % 1e9)
local function mkfile(rel)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "local x = 1" }, path)
  return path
end
mkfile("lua/mod/a.lua")
mkfile("lua/mod/b.lua")
mkfile("lua/init.lua")
mkfile("docs/guide.md")
mkfile("README.md")
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
local editor_win = vim.api.nvim_get_current_win()

local filetree = require("filetree")
local set_up = pcall(filetree.setup, {
  adapter = "native",
  deps_popup = false,
  native = { width = 36 },
  adapter_keymaps = { H = false }, -- one of the tree's own keys, switched off
  features = {
    tree_toggle = { enabled = true },
    auto_reveal = { enabled = true, debounce_ms = 10 },
    session = { enabled = false }, -- writes into the user's data directory
  },
})
ok("setup with adapter = native", set_up)
local adapter = filetree.adapter()
eq("the active adapter", adapter.name, "native")
eq("setup says nothing at warning level", loud(), {})

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function settle(ms)
  vim.wait(ms or 80, function()
    return false
  end)
end
local function lines()
  return vim.api.nvim_buf_get_lines(adapter.get_bufnr(), 0, -1, false)
end
local function goto_path(path)
  vim.api.nvim_set_current_win(adapter.get_winid())
  vim.api.nvim_win_set_cursor(adapter.get_winid(), { adapter.get_node_line(path), 0 })
  vim.cmd("doautocmd CursorMoved")
end
local function marks_in_tree()
  local n = 0
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name ~= "filetree_native" then
      n = n + #vim.api.nvim_buf_get_extmarks(adapter.get_bufnr(), ns, 0, -1, {})
    end
  end
  return n
end

-- ── tree_toggle: the global Alt keys place the tree ────────────────────────────
feed("<M-l>")
settle()
eq(
  "<M-l> opens the tree on the left",
  { adapter.is_open(), adapter.get_position() },
  { true, "left" }
)
eq("the width of the `native` block applies", vim.api.nvim_win_get_width(adapter.get_winid()), 36)
local buf = adapter.get_bufnr()
eq("tree_toggle reveals the file it came from", adapter.get_current_node().name, "README.md")

-- ── the features bound their keys on the tree buffer ───────────────────────────
local bound = {}
for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
  bound[map.lhs] = map.desc or ""
end
for _, lhs in ipairs({ "m", "a", "d", "r", "c", "p", "W", "-", "+", "I", "?", "gr", "f" }) do
  ok("feature key bound in the tree: " .. lhs, bound[lhs] ~= nil)
end
-- adapter_keymaps: an override reaches the own tree's buffer (it used to be bound to the filetypes
-- neo-tree and NvimTree only)
local h_map = vim.fn.maparg("H", "n", false, true)
ok("adapter_keymaps = { H = false } disables the tree's own H", h_map.rhs == "<Nop>")
ok(
  "the tree's own keys are there too",
  bound["q"] ~= nil and bound["R"] ~= nil and bound["h"] ~= nil
)

-- ── <CR>: the preview feature wraps the tree's own key and falls through to it ─
goto_path(dir .. "/lua")
feed("<CR>")
vim.wait(300, function()
  return adapter.get_node_line(dir .. "/lua/init.lua") ~= nil
end)
ok("<CR> on a folder opens it", adapter.get_node_line(dir .. "/lua/init.lua") ~= nil)
goto_path(dir .. "/lua/init.lua")
feed("<CR>")
settle()
eq(
  "<CR> on a file opens it in the editor window",
  { vim.api.nvim_get_current_win(), list.norm(vim.api.nvim_buf_get_name(0)) },
  { editor_win, dir .. "/lua/init.lua" }
)
vim.wait(500, function()
  return not adapter.is_open()
end)
eq(
  "close_on_open: the tree closes after a file was opened from it",
  { adapter.is_open() },
  { false }
)
-- close_on_open undoes a tree that comes back by itself within 1.5 s of the close (a backend that
-- re-creates its window); the spec is no user pressing a key, so it waits that guard out
settle(1600)
adapter.open_cwd()
local win = adapter.get_winid()
eq("open_cwd brings the same tree back", adapter.get_bufnr(), buf)

-- ── auto_reveal: entering a file moves the tree's cursor to it ─────────────────
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/lua/mod/b.lua"))
vim.wait(1000, function()
  return adapter.get_node_line(dir .. "/lua/mod/b.lua") ~= nil
    and vim.api.nvim_win_get_cursor(win)[1] == adapter.get_node_line(dir .. "/lua/mod/b.lua")
end)
eq(
  "auto_reveal opened the folders and put the tree's cursor on the file",
  vim.api.nvim_win_get_cursor(win)[1],
  adapter.get_node_line(dir .. "/lua/mod/b.lua")
)
eq("... without taking the focus", vim.api.nvim_get_current_win(), editor_win)

-- ── marks: `m` marks the node and draws on its line ────────────────────────────
local marks = filetree.feature("marks")
local before_marks = marks_in_tree()
goto_path(dir .. "/lua/mod/a.lua")
feed("m")
settle()
eq(
  "m marks the node under the cursor",
  vim.tbl_map(list.norm, marks.get_marked()),
  { dir .. "/lua/mod/a.lua" }
)
ok("the mark is drawn in the tree", marks_in_tree() > before_marks)
adapter.refresh()
settle()
ok("the mark is drawn again after a refresh", marks_in_tree() > before_marks)
marks.clear_all()

-- ── lsp_diagnostics: a file's diagnostics show on its line and on its folders ──
local diag_ns = vim.api.nvim_create_namespace("ft_feat_spec")
local a_buf = vim.fn.bufadd(dir .. "/lua/mod/a.lua")
vim.fn.bufload(a_buf)
local before_diag = marks_in_tree()
vim.diagnostic.set(diag_ns, a_buf, {
  { lnum = 0, col = 0, message = "boom", severity = vim.diagnostic.severity.ERROR },
})
vim.wait(1500, function()
  return marks_in_tree() > before_diag
end)
local with_diag = marks_in_tree()
ok("diagnostics are drawn in the tree", with_diag > before_diag)
ok("... on more than the file's own line (its folders too)", with_diag - before_diag >= 2)
vim.diagnostic.reset(diag_ns, a_buf)
vim.wait(1500, function()
  return marks_in_tree() <= before_diag
end)
eq("... and gone with the diagnostics", marks_in_tree() <= before_diag, true)

-- ── collapse_all: W ────────────────────────────────────────────────────────────
vim.api.nvim_set_current_win(win)
feed("W")
settle()
eq("W closes every folder", adapter.get_expanded_paths(), {})
eq("... and the tree shows the top level only", #lines(), 4)

-- ── sort_cycle ─────────────────────────────────────────────────────────────────
local sort_cycle = filetree.feature("sort_cycle")
sort_cycle.cycle()
eq(
  "sort_cycle moves to the next criterion, largest first",
  adapter.get_sort(),
  { kind = "size", descending = true }
)
sort_cycle.reverse()
eq("sort_cycle reverses", adapter.get_sort().descending, false)
sort_cycle.cycle()
sort_cycle.cycle()
eq("... and comes back to name", adapter.get_sort().kind, "name")

-- ── tree_traverse: + roots the tree at a folder, - goes up ─────────────────────
goto_path(dir .. "/lua")
feed("+")
settle()
eq("+ makes the folder the root", adapter.get_root_path(), dir .. "/lua")
eq("the tree lists that folder", lines()[1], "▾ lua/")
vim.api.nvim_set_current_win(win)
feed("-")
settle()
eq("- goes back up", adapter.get_root_path(), dir)

-- ── buffer_cycle: <C-n> cycles the editor window, the tree keeps the focus ─────
vim.api.nvim_set_current_win(win)
local shown = vim.api.nvim_win_get_buf(editor_win)
feed("<C-n>")
settle()
eq(
  "<C-n> changes the buffer of the editor window",
  vim.api.nvim_win_get_buf(editor_win) ~= shown,
  true
)
eq("... and the focus stays in the tree", vim.api.nvim_get_current_win(), win)

-- ── cursor_hide / window_style: they recognise the tree window by its filetype ─
ok(
  "the tree buffer is a tree buffer for the features",
  require("filetree.util.buffer").is_tree_buffer(buf)
)
eq(
  "an editor buffer is not",
  require("filetree.util.buffer").is_tree_buffer(vim.api.nvim_win_get_buf(editor_win)),
  false
)

-- ── health ─────────────────────────────────────────────────────────────────────
-- the check function itself: `:checkhealth` ends a headless `-l` run on this Neovim
local reported = {}
local real_health = vim.health
---@diagnostic disable-next-line: duplicate-set-field
vim.health = setmetatable({}, {
  __index = function(_, kind)
    return function(text)
      reported[#reported + 1] = kind .. ": " .. tostring(text)
    end
  end,
})
local health_ok, health_err = pcall(require("filetree.health").check)
vim.health = real_health
ok("the health check runs with the native adapter: " .. tostring(health_err), health_ok)
local health_text = table.concat(reported, " | ")
ok("... and names the adapter", health_text:find("native", 1, true) ~= nil)
eq(
  "... without an error line",
  vim.tbl_filter(function(line)
    return line:match("^error:") ~= nil
  end, reported),
  {}
)

eq("no warning or error in the whole run", loud(), {})

vim.notify = real_notify
require("filetree.native").reset()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_features_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
