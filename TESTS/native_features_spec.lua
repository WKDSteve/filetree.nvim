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

-- No `vim.o.columns` / `vim.o.lines` in this file: a headless run has no UI, its screen grid stays
-- 80x24 whatever the options say, and the next forced redraw writes past it (Neovim 0.12: a
-- segfault on Windows, a failed assertion in grid_line_flush in a debug build). The tree and the
-- editor windows fit into 80 columns.

-- Results go to stdout directly: print() in a headless run goes through the message area.
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
    git_status = { enabled = true, debounce_ms = 10 },
    file_watcher = { enabled = true }, -- stands down on the own tree, which watches itself
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
-- On the own tree the feature is a decorator: nothing is written into the buffer, the badge is drawn
-- with the line. What is drawn is read by recording the calls that place the (ephemeral) marks.
local view_mod = require("filetree.native.view")
local function right_of(path)
  local line = adapter.get_node_line(path)
  if not line then return nil end
  local out = {}
  local real = vim.api.nvim_buf_set_extmark
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_buf_set_extmark = function(_, _, _, _, opts)
    for _, chunk in ipairs(opts.virt_text or {}) do
      out[#out + 1] = vim.trim(chunk[1])
    end
    return 0
  end
  pcall(view_mod.decorate_line, adapter.get_bufnr(), line - 1, adapter.get_winid())
  vim.api.nvim_buf_set_extmark = real
  return table.concat(out, " ")
end

local diag_ns = vim.api.nvim_create_namespace("ft_feat_spec")
local a_buf = vim.fn.bufadd(dir .. "/lua/mod/a.lua")
vim.fn.bufload(a_buf)
local marks_before_diag = marks_in_tree()
eq("no diagnostics yet: nothing on the file", right_of(dir .. "/lua/mod/a.lua"), "")
vim.diagnostic.set(diag_ns, a_buf, {
  { lnum = 0, col = 0, message = "boom", severity = vim.diagnostic.severity.ERROR },
  { lnum = 0, col = 0, message = "hm", severity = vim.diagnostic.severity.WARN },
})
vim.wait(1500, function()
  return (right_of(dir .. "/lua/mod/a.lua") or "") ~= ""
end)
local on_file = right_of(dir .. "/lua/mod/a.lua")
ok("diagnostics are drawn on the file: " .. tostring(on_file), on_file:find("1") ~= nil)
eq("... the same counts on its folder", right_of(dir .. "/lua/mod"), on_file)
eq("... and on the folder above", right_of(dir .. "/lua"), on_file)
eq("... a sibling file stays clean", right_of(dir .. "/lua/mod/b.lua"), "")
eq("nothing was written into the tree buffer for it", marks_in_tree(), marks_before_diag)
vim.diagnostic.reset(diag_ns, a_buf)
vim.wait(1500, function()
  return right_of(dir .. "/lua/mod/a.lua") == ""
end)
eq(
  "gone with the diagnostics",
  { right_of(dir .. "/lua/mod/a.lua"), right_of(dir .. "/lua") },
  { "", "" }
)

-- ── git_status: the state of a file on its line, the worst below on its folders ─
if vim.fn.executable("git") == 1 then
  vim.fn.system({ "git", "-C", dir, "init", "-q" })
  vim.fn.system({ "git", "-C", dir, "add", "README.md" })
  filetree.feature("git_status").refresh()
  vim.wait(5000, function()
    return (right_of(dir .. "/README.md") or "") ~= ""
  end)
  eq("an added file shows the sign for added", right_of(dir .. "/README.md"), "+")
  eq("an untracked file shows the sign for untracked", right_of(dir .. "/lua/mod/a.lua"), "?")
  eq("a folder shows the worst state below it", right_of(dir .. "/lua"), "?")
  adapter.collapse_node({ path = dir .. "/lua" })
  eq("... also when it is closed", right_of(dir .. "/lua"), "?")
  adapter.expand_node({ path = dir .. "/lua" })
  -- a file created outside the editor: the tree shows it by itself, and git_status hears of it
  local full_refreshes = 0
  local real_refresh = adapter.refresh
  adapter.refresh = function(...)
    full_refreshes = full_refreshes + 1
    return real_refresh(...)
  end
  vim.fn.writefile({ "x" }, dir .. "/lua/outside.lua")
  vim.wait(6000, function()
    return (right_of(dir .. "/lua/outside.lua") or "") ~= ""
  end, 25)
  eq(
    "a file created outside appears with its git sign, no refresh asked",
    right_of(dir .. "/lua/outside.lua"),
    "?"
  )
  eq("... and no feature answered the change with a refresh of the whole tree", full_refreshes, 0)
  adapter.refresh = real_refresh
  vim.fn.delete(dir .. "/.git", "rf")
else
  say("  n/a  git_status: no git on this machine")
end

-- ── collapse_all: W ────────────────────────────────────────────────────────────
vim.api.nvim_set_current_win(win)
feed("W")
settle()
eq("W closes every folder", adapter.get_expanded_paths(), {})
local nested = vim.tbl_filter(function(node)
  return node.depth > 1
end, adapter.get_visible_nodes())
eq("... and the tree shows the top level only", #nested, 0)

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
-- the check function itself, with a stand-in `vim.health`: the report is read here, not shown in a tab
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
