-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_action_spec.lua -- the action table of the own tree (stage E4): which action a key runs
-- on a node and why none does (pure), and in a real tree: an action of another plugin with `needs`,
-- the selection handed to `run`, a feature key taken into the table, a key the user mapped over left
-- alone, the tree's own `-` and `sw`, trees at the top and bottom, a folder opened as a buffer, the
-- operation pipeline (`User FiletreeChanged` reads one folder), the `?` page "here", the context menu
-- and `:Filetree action`.
--
--   nvim --clean --headless -u NONE -l TESTS/native_action_spec.lua

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
vim.g.mapleader = "\\"

local notes = {}
local real_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end
local function last_note()
  return notes[#notes] and notes[#notes].msg or nil
end
local function loud()
  local out = {}
  for _, note in ipairs(notes) do
    if note.level >= vim.log.levels.WARN then out[#out + 1] = note.msg end
  end
  return out
end

-- ── the table, pure ────────────────────────────────────────────────────────────
local tbl = require("filetree.native.action.table")
local noop = function() end
local t = tbl.new()
t:add({ name = "own_d", key = "d", run = noop }, "builtin")
t:add({ name = "trash", key = "d", needs = { "path", "mutable" }, run = noop }, "feature")
t:add({ name = "diff", key = "d", needs = { "source:tests" }, run = noop }, "source")
t:add({
  name = "pdf",
  key = "go",
  when = function(n)
    return n.path ~= nil and n.path:match("%.pdf$") ~= nil
  end,
  run = noop,
}, "plugin")
t:add({ name = "only_files", key = "gx", needs = { "file" }, run = noop }, "plugin")
t:add({ name = "loud", key = "gx", needs = { "file" }, priority = 5, run = noop }, "plugin")

local file = { id = "/p/a.lua", path = "/p/a.lua", kind = "file" }
local folder = { id = "/p/lua", path = "/p/lua", kind = "dir" }
local symbol = { id = "sym", kind = "function" }
local files_ctx = { source = "files", mutable = true }

eq("a source's action ranks first", t:resolve("d", file, { source = "tests" }).name, "diff")
eq(
  "... and steps back where its source is not shown",
  t:resolve("d", file, files_ctx).name,
  "trash"
)
eq("a feature before the tree's own", t:resolve("d", folder, files_ctx).name, "trash")
eq("the tree's own where nothing else applies", t:resolve("d", symbol, files_ctx).name, "own_d")
eq("priority decides among the same origin", t:resolve("gx", file, files_ctx).name, "loud")
local none, why = t:resolve("gx", folder, files_ctx)
eq("no action that applies: nil and the reason", { none, why }, { nil, "gx: needs a file" })
eq("a key nobody claims", select(2, t:resolve("zz", file, files_ctx)), "zz: no action on this key")
eq(
  "a read-only view",
  select(2, tbl.check({ name = "x", needs = { "mutable" }, run = noop }, file, { mutable = false })),
  "this view does not change files"
)
eq(
  "when() decides the rest",
  t:resolve("go", { path = "/p/x.pdf", kind = "file" }, files_ctx).name,
  "pdf"
)
eq("... and says so", select(2, t:resolve("go", file, files_ctx)), "go: does not apply here")
eq(
  "skip passes over a running action",
  t:resolve("gx", file, files_ctx, { loud = true }).name,
  "only_files"
)
local names = {}
for _, a in ipairs(t:applicable(file, files_ctx)) do
  names[#names + 1] = a.name
end
eq(
  "applicable lists every action that applies, in rank order",
  names,
  { "loud", "trash", "only_files", "own_d" }
)
eq("keys", t:keys(), { "d", "go", "gx" })
t:add({ name = "trash", key = "D", run = noop }, "feature")
eq("adding under a taken name replaces the entry", t:resolve("D", file, files_ctx).name, "trash")
eq("... and keeps its place", t:get("trash").seq, 2)

-- ── fixture ────────────────────────────────────────────────────────────────────
local list = require("filetree.native.fs.list")
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_action_%d"):format(base, vim.uv.hrtime() % 1e9)
local function mkfile(rel)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
  return path
end
mkfile("lua/a.lua")
mkfile("lua/b.lua")
mkfile("docs/guide.md")
mkfile("README.md")
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
local editor_win = vim.api.nvim_get_current_win()

-- an action of another plugin, registered before setup
local ran = {}
local registry = require("lib.nvim.tree.registry")
local remove_count = registry.action({
  name = "spec.count",
  key = "gC",
  desc = "Count the files",
  needs = { "file" },
  run = function(nodes)
    ran[#ran + 1] = #nodes
  end,
})
local info_runs = 0
local remove_info = registry.action({
  name = "spec.md_info",
  key = "I", -- node_info's key: taken over on markdown files only
  desc = "Markdown info",
  priority = 10,
  when = function(node)
    return node.path ~= nil and node.path:match("%.md$") ~= nil
  end,
  run = function()
    info_runs = info_runs + 1
  end,
})

local filetree = require("filetree")
ok(
  "setup with adapter = native",
  pcall(filetree.setup, {
    adapter = "native",
    deps_popup = false,
    native = { width = 34, watch = false },
    adapter_keymaps = { R = false }, -- the user switches one of the tree's own keys off
    features = {
      session = { enabled = false },
      auto_reveal = { enabled = false },
      -- it closes the tree once a file is opened from it, and keeps it closed until a key is typed;
      -- this spec opens files from the tree and the tree again without typing
      close_on_open = { enabled = false },
    },
  })
)
local adapter = filetree.adapter()

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function settle(ms)
  vim.wait(ms or 80, function()
    return false
  end)
end
local function goto_path(path)
  vim.api.nvim_set_current_win(adapter.get_winid())
  vim.api.nvim_win_set_cursor(adapter.get_winid(), { adapter.get_node_line(path), 0 })
  vim.cmd("doautocmd CursorMoved")
end

adapter.toggle_at("left", { dir = dir })
settle(150) -- the features bind their keys one tick after FileType, then the table reads them
local view = require("filetree.native").current()
local action = require("filetree.native.action")
adapter.expand_node({ path = dir .. "/lua" })
adapter.expand_node({ path = dir .. "/docs" })

-- ── an action with needs, from another plugin ──────────────────────────────────
goto_path(dir .. "/lua/a.lua")
feed("gC")
eq("gC on a file runs the plugin's action with the node", ran, { 1 })
goto_path(dir .. "/lua")
local before = #notes
feed("gC")
eq("gC on a folder runs nothing", ran, { 1 })
eq(
  "... and says why in one line",
  { #notes - before, last_note() },
  { 1, "[filetree.native] gC: needs a file" }
)

-- ── the selection goes to run as a list ────────────────────────────────────────
local marks = filetree.feature("marks")
marks.toggle(dir .. "/lua/a.lua")
marks.toggle(dir .. "/lua/b.lua")
goto_path(dir .. "/lua/a.lua")
feed("gC")
eq("with two marked files the action gets both", ran[#ran], 2)
goto_path(dir .. "/lua")
feed("gC")
eq("a selection is checked as a whole, not by the cursor's node", ran[#ran], 2)
marks.clear_all()
settle()

-- ── a feature key in the same table ────────────────────────────────────────────
ok("the feature's I is in the table", view.actions:get("feature:I") ~= nil)
eq(
  "I is taken over by the dispatcher",
  vim.fn.maparg("I", "n", false, true).desc:sub(1, #action.PREFIX),
  action.PREFIX
)
goto_path(dir .. "/docs/guide.md")
feed("I")
eq("I on a markdown file runs the plugin's action (priority 10)", info_runs, 1)
eq(
  "... and on a lua file the feature's own I",
  view.actions:resolve("I", view.tree:node(dir .. "/lua/a.lua"), action.ctx(view)).name,
  "feature:I"
)

-- ── a key the user mapped over stays theirs ────────────────────────────────────
eq("adapter_keymaps R = false is still <Nop>", vim.fn.maparg("R", "n", false, true).rhs, "<Nop>")
action.sync(view)
eq("... after the table is read again", vim.fn.maparg("R", "n", false, true).rhs, "<Nop>")
local reach_r = nil
for _, e in ipairs(action.applicable(view)) do
  if e.action.name == "refresh" then reach_r = e.key or false end
end
eq("... and the cheatsheet does not offer R for refresh", reach_r, false)

-- ── the tree's own keys: - and sw ──────────────────────────────────────────────
goto_path(dir .. "/lua/a.lua")
local picked = nil
package.loaded["ui.windowpicker"] = {
  pick = function()
    picked = editor_win
    return editor_win
  end,
}
action.run(view, "open_picked")
eq("open_picked opens the file in the window the picker answered", {
  picked,
  list.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor_win))),
}, { editor_win, dir .. "/lua/a.lua" })
package.loaded["ui.windowpicker"] = nil
vim.api.nvim_set_current_win(adapter.get_winid())
local up_ok = action.run(view, "up")
eq("up: the parent folder is the root", { up_ok, view.root }, { true, list.parent(dir) })
eq("... with the cursor on the folder it came from", adapter.get_current_node().path, dir)
adapter.set_root(dir)
settle()

-- ── trees at the top and the bottom ────────────────────────────────────────────
adapter.close()
view:open("bottom")
local win = view.win
eq("a tree at the bottom: full width, its own height", {
  vim.api.nvim_win_get_width(win) == vim.o.columns,
  vim.api.nvim_win_get_height(win),
  vim.wo[win].winfixheight,
}, { true, 15, true })
ok(
  "... below the editor window",
  vim.fn.win_screenpos(win)[1] > vim.fn.win_screenpos(editor_win)[1]
)
view:open("top")
ok(
  "a tree at the top lies above it",
  vim.fn.win_screenpos(view.win)[1] < vim.fn.win_screenpos(editor_win)[1]
)
view:open("left")
settle()
adapter.expand_node({ path = dir .. "/lua" })
adapter.expand_node({ path = dir .. "/docs" })
ok("the tree is back on the left", adapter.get_winid() ~= nil)

-- ── the operation pipeline: one folder read, not the tree ──────────────────────
local scans = list.stats.scans
vim.fn.writefile({ "y" }, dir .. "/lua/c.lua") -- watch = false: nothing sees this on its own
require("filetree.util.changed").emit("create", nil, dir .. "/lua/c.lua")
vim.wait(2000, function()
  return adapter.get_node_line(dir .. "/lua/c.lua") ~= nil
end, 20)
ok("after FiletreeChanged the new file shows", adapter.get_node_line(dir .. "/lua/c.lua") ~= nil)
eq("... and exactly one folder was read for it", list.stats.scans - scans, 1)
scans = list.stats.scans
require("filetree.util.mutate").move(dir .. "/lua/c.lua", dir .. "/docs/c.lua")
vim.wait(2000, function()
  return adapter.get_node_line(dir .. "/docs/c.lua") ~= nil
end, 20)
eq("a move through util.mutate reads the two folders it touched", {
  adapter.get_node_line(dir .. "/lua/c.lua") == nil,
  adapter.get_node_line(dir .. "/docs/c.lua") ~= nil,
  list.stats.scans - scans,
}, { true, true, 2 })
local changed = nil
vim.api.nvim_create_autocmd("User", {
  pattern = "FiletreeChanged",
  once = true,
  callback = function(ev)
    changed = ev.data
  end,
})
require("filetree.util.mutate").move(dir .. "/docs/c.lua", dir .. "/docs/d.lua")
eq("User FiletreeChanged carries op, from and to", changed, {
  op = "move",
  from = dir .. "/docs/c.lua",
  to = dir .. "/docs/d.lua",
})

-- ── the ? page "here" lists what applies to the node ───────────────────────────
goto_path(dir .. "/lua/a.lua")
filetree.feature("cheatsheet").show()
settle()
local sheet = {}
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(w).relative ~= "" then
    sheet = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
  end
end
local text = table.concat(sheet, "\n")
ok("the cheatsheet opens on the page 'here'", text:find("[1 here]", 1, true) ~= nil)
ok("... names the node", text:find("on a.lua", 1, true) ~= nil)
ok("... lists the plugin's action on its key", text:find("gC%s+Count the files") ~= nil)
ok("... and the tree's own", text:find("sw%s+Open the file in a window you pick") ~= nil)
ok("... but not the markdown action on a lua file", text:find("Markdown info", 1, true) == nil)
filetree.feature("cheatsheet").close()
settle()

-- ── the context menu ───────────────────────────────────────────────────────────
goto_path(dir .. "/docs/guide.md")
local items = require("filetree.integrations.menu").items()
local labels = {}
for _, item in ipairs(items) do
  labels[item.name] = item.rtxt or true
end
eq("the menu offers the actions that apply, with their keys", {
  labels["Markdown info"],
  labels["Count the files"],
  labels["Show or hide the names of the ignore list"],
}, { "I", "gC", "H" })
eq("... and not the tree's folding keys", labels["Close every folder"], nil)
goto_path(dir .. "/lua")
items = require("filetree.integrations.menu").items()
labels = {}
for _, item in ipairs(items) do
  labels[item.name] = true
end
eq("on a folder, not the file-only action", labels["Count the files"], nil)

-- ── :Filetree action ───────────────────────────────────────────────────────────
goto_path(dir .. "/lua/b.lua")
vim.cmd("Filetree action spec.count")
eq(":Filetree action runs an action by name", ran[#ran], 1)
goto_path(dir .. "/lua")
before = #ran
vim.cmd("Filetree action spec.count")
eq(
  "... and where it does not apply says why",
  { #ran, last_note() },
  { before, "[filetree.native] spec.count: needs a file" }
)
vim.cmd("Filetree action no.such")
eq("... an unknown name too", last_note(), '[filetree.native] no action "no.such" in this tree')

-- ── review of a9c4415 ──────────────────────────────────────────────────────────
-- one key, two spellings: a feature's <C-k> (Neovim reports it as <C-K>) and a plugin's <c-k>
local fake_runs = 0
vim.keymap.set("n", "<C-k>", function()
  fake_runs = fake_runs + 1
end, { buffer = view.buf, desc = "filetree: fake ctrl-k" })
local ctrl_runs = 0
local remove_ctrl = registry.action({
  name = "spec.ctrl",
  key = "<c-k>",
  desc = "Ctrl-k on folders",
  needs = { "dir" },
  priority = 10, -- above the feature on the same key, where it applies
  run = function()
    ctrl_runs = ctrl_runs + 1
  end,
})
settle(100)
goto_path(dir .. "/lua")
feed("<C-k>")
goto_path(dir .. "/lua/a.lua")
feed("<C-k>")
eq(
  "<c-k> and <C-K> are one key: the plugin's on a folder, the feature's on a file",
  { ctrl_runs, fake_runs },
  { 1, 1 }
)
remove_ctrl()
settle(100)
eq(
  "an action that goes gives the key back to the feature",
  vim.fn.maparg("<C-k>", "n", false, true).desc,
  "filetree: fake ctrl-k"
)
feed("<C-k>")
eq("... which runs it again", fake_runs, 2)

-- sw opens the file under the cursor, also with other nodes marked
marks.toggle(dir .. "/docs/guide.md")
goto_path(dir .. "/lua/a.lua")
vim.api.nvim_win_call(editor_win, function()
  vim.cmd("enew")
end)
package.loaded["ui.windowpicker"] = {
  pick = function()
    return editor_win
  end,
}
action.run(view, "open_picked")
package.loaded["ui.windowpicker"] = nil
eq(
  "sw with a marked node opens the file under the cursor",
  list.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor_win))),
  dir .. "/lua/a.lua"
)
marks.clear_all()
settle()

-- ── a folder opened as a buffer shows the tree (netrw replacement) ─────────────
adapter.close()
vim.api.nvim_set_current_win(editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/docs"))
vim.wait(1000, function()
  return vim.bo[vim.api.nvim_win_get_buf(editor_win)].filetype == "filetree"
end, 20)
eq(
  "`:edit <folder>` shows the tree in that window",
  vim.bo[vim.api.nvim_win_get_buf(editor_win)].filetype,
  "filetree"
)
eq("... rooted at the folder", view.root, dir .. "/docs")
eq("... in the place of the window", view.position, "current")
ok("... and the folder buffer is gone", vim.fn.bufexists(dir .. "/docs") == 0)

-- `nvim <dir>` with filetree set up after the folder buffer was entered (lazy loading)
adapter.close()
vim.api.nvim_set_current_win(editor_win)
-- what closing scheduled runs first: the empty buffer it left is reused by the :edit below, and a
-- check still queued for it would find the folder there (not what this case is about)
settle()
vim.cmd("noautocmd edit " .. vim.fn.fnameescape(dir .. "/lua"))
require("filetree.native").hijack_netrw(true)
-- without its BufEnter: only the look at what is already on screen can show the tree now
vim.api.nvim_clear_autocmds({ group = "filetree_native_netrw" })
vim.wait(1000, function()
  return vim.bo[vim.api.nvim_win_get_buf(editor_win)].filetype == "filetree"
end, 20)
eq(
  "a folder buffer already on screen when the replacement starts shows the tree",
  { vim.bo[vim.api.nvim_win_get_buf(editor_win)].filetype, view.root },
  { "filetree", dir .. "/lua" }
)

-- the registry is followed once, however often the tree was reset
local native = require("filetree.native")
for _ = 1, 2 do
  native.reset()
  adapter.toggle_at("left", { dir = dir })
  settle()
end
local syncs = 0
local real_sync = action.sync
---@diagnostic disable-next-line: duplicate-set-field
action.sync = function(v)
  syncs = syncs + 1
  return real_sync(v)
end
local remove_late = registry.action({ name = "spec.late", key = "gL", run = function() end })
settle(100)
action.sync = real_sync
eq("a registered action is read once per view after two resets", syncs, 1)
remove_late()

eq("nothing at warning level in the whole run", loud(), {})
remove_count()
remove_info()
vim.notify = real_notify
require("filetree.native").reset()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_action_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
