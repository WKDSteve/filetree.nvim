-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_source_builtin_spec.lua -- the sources the own tree brings (stage E5). `buffers`: files,
-- an unnamed buffer and a terminal, live; a file node is a file for the features and the decorators;
-- `dd` deletes a buffer while `d` stays the features' key. `git`: an XY code to its groups (pure), a
-- real repository grouped by state, live after a write, and a root that is no repository.
--
--   nvim --clean --headless -u NONE -l TESTS/native_source_builtin_spec.lua

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

-- ── git, pure ──────────────────────────────────────────────────────────────────
local git = require("filetree.native.source.git")
local function groups_of(code)
  return vim.tbl_map(function(state)
    return state.group .. ":" .. state.letter .. ":" .. state.status
  end, git.classify(code))
end
eq("changed in the work tree", groups_of(" M"), { "changes:M:modified" })
eq("staged", groups_of("A "), { "staged:A:added" })
eq(
  "staged and changed again: both groups",
  groups_of("MM"),
  { "staged:M:modified", "changes:M:modified" }
)
eq("deleted", groups_of(" D"), { "changes:D:deleted" })
eq("renamed in the index", groups_of("R "), { "staged:R:renamed" })
eq("untracked", groups_of("??"), { "untracked:?:untracked" })
eq("ignored is in no group", groups_of("!!"), {})
eq("a conflict is only a conflict", {
  groups_of("UU"),
  groups_of("AA"),
  groups_of("DU"),
}, { { "conflicts:!:conflict" }, { "conflicts:!:conflict" }, { "conflicts:!:conflict" } })

local nodes = git.groups({
  ["lua/b.lua"] = { code = " M" },
  ["lua/a.lua"] = { code = "MM" },
  ["docs/x.md"] = { code = "??" },
  ["old.txt"] = { code = "R ", orig_path = "older.txt" },
}, "/repo", "/repo/lua")
eq(
  "the groups in a fixed order, each with its count",
  vim.tbl_map(function(group)
    return { group.label, group.columns[1], #group.children, group.open }
  end, nodes),
  { { "Staged", "2", 2, true }, { "Changes", "2", 2, true }, { "Untracked", "1", 1, true } }
)
eq(
  "a file below the view's root is named relative to it, another relative to the repository",
  vim.tbl_map(function(file)
    return file.label
  end, nodes[1].children),
  { "a.lua", "old.txt" }
)
eq("every file node carries its absolute path", nodes[2].children[2].path, "/repo/lua/b.lua")
eq(
  "a file in two groups has two ids and one path",
  { nodes[1].children[1].id, nodes[2].children[1].id, nodes[2].children[1].path },
  { "git:staged:/repo/lua/a.lua", "git:changes:/repo/lua/a.lua", "/repo/lua/a.lua" }
)
eq("a rename keeps where it came from", nodes[1].children[2].data.git.orig_path, "older.txt")
eq(
  "a clean tree says so in one line",
  vim.tbl_map(function(node)
    return { node.label, node.kind }
  end, git.groups({}, "/repo", "/repo")),
  { { "nothing changed", "note" } }
)

-- ── fixture ────────────────────────────────────────────────────────────────────
local list = require("filetree.native.fs.list")
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_builtin_%d"):format(base, vim.uv.hrtime() % 1e9)
local function mkfile(rel, lines)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines or { "x" }, path)
  return path
end
mkfile("lua/a.lua")
mkfile("lua/b.lua")
mkfile("README.md")
local outside = list.norm(vim.fn.tempname() .. "_outside.txt")
vim.fn.writefile({ "o" }, outside)
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
local editor_win = vim.api.nvim_get_current_win()
vim.cmd("badd " .. vim.fn.fnameescape(dir .. "/lua/a.lua"))
vim.cmd("badd " .. vim.fn.fnameescape(outside))
local buf_a = vim.fn.bufnr(dir .. "/lua/a.lua")
local buf_readme = vim.fn.bufnr(dir .. "/README.md")

-- a path decorator of another plugin: it has to find a buffer's node by its path
local registry = require("lib.nvim.tree.registry")
local remove_decorator = registry.decorator({
  name = "spec_flag",
  get = function(path)
    if path == dir .. "/lua/a.lua" then return { text = "F", status = "flag" } end
  end,
  subscribe = function()
    return function() end
  end,
})

local filetree = require("filetree")
ok(
  "setup with adapter = native",
  pcall(filetree.setup, {
    adapter = "native",
    deps_popup = false,
    native = { width = 34, watch = false },
    features = {
      session = { enabled = false },
      auto_reveal = { enabled = false },
      close_on_open = { enabled = false },
    },
  })
)
local adapter = filetree.adapter()
local native = require("filetree.native")
local action = require("filetree.native.action")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function settle(ms)
  vim.wait(ms or 80, function()
    return false
  end)
end
local function lines()
  return vim.tbl_map(function(line)
    return (line:gsub("^%s+", ""))
  end, vim.api.nvim_buf_get_lines(adapter.get_bufnr(), 0, -1, false))
end
local function goto_id(view, id)
  vim.api.nvim_set_current_win(view.win)
  vim.api.nvim_win_set_cursor(view.win, { view.tree:row_of(id), 0 })
  vim.cmd("doautocmd CursorMoved")
end

adapter.toggle_at("left", { dir = dir })
settle(150)
local view = native.current()

eq(
  "the tree brings its own sources, after the files",
  vim.tbl_map(function(v)
    return v.name
  end, view:views()),
  { "files", "buffers", "git", "symbols", "diagnostics" }
)
eq("the files have no dd", vim.fn.maparg("dd", "n"), "")

-- ── buffers ────────────────────────────────────────────────────────────────────
view:show("buffers")
local outside_label = (vim.fn.fnamemodify(outside, ":~"):gsub("\\", "/"))
eq("the listed buffers, by name; a file below the root relative to it", lines(), {
  "▾ Buffers",
  "lua/a.lua",
  "README.md",
  outside_label,
})
eq("the head counts them", view.tree:node("buffers:root").columns, { "3" })

goto_id(view, "buffers:" .. buf_a)
eq(
  "a buffer of a file is a file for the features",
  { adapter.get_current_node().path, adapter.get_current_node().type },
  { dir .. "/lua/a.lua", "file" }
)
eq(
  "the features' own key applies to it (trash on d)",
  view.actions:resolve("d", view:current().node, action.ctx(view)).name,
  "feature:d"
)
eq(
  "a path decorator finds it",
  vim.tbl_map(function(badge)
    return badge.name .. ":" .. badge.text
  end, require("filetree.native.decor").badges(view:current().node, false)),
  { "spec_flag:F" }
)
eq("the tree finds the buffer by its path", adapter.get_node_line(dir .. "/lua/a.lua"), 2)
eq("d waits for the dd this view has", {
  vim.fn.maparg("d", "n", false, true).nowait,
  vim.fn.maparg("dd", "n", false, true).desc,
}, { 0, action.PREFIX .. "Delete the buffer" })

-- live: a new buffer, an unnamed one, a terminal
vim.cmd("badd " .. vim.fn.fnameescape(dir .. "/lua/b.lua"))
local buf_b = vim.fn.bufnr(dir .. "/lua/b.lua")
local unnamed = vim.api.nvim_create_buf(true, false)
local term = vim.api.nvim_create_buf(true, false)
vim.api.nvim_open_term(term, {})
vim.b[term].term_title = "spec shell"
settle()
eq("new buffers appear by themselves; unnamed ones and terminals stand last", lines(), {
  "▾ Buffers",
  "lua/a.lua",
  "lua/b.lua",
  "README.md",
  outside_label,
  "[No Name]",
  "spec shell",
})
eq("the cursor stayed on its buffer", view:current().id, "buffers:" .. buf_a)
goto_id(view, "buffers:" .. term)
eq("a terminal is no file for the features", adapter.get_current_node(), nil)
feed("<CR>")
eq("<CR> on a terminal shows it in the editor window", {
  vim.api.nvim_get_current_win(),
  vim.api.nvim_get_current_buf(),
}, { editor_win, term })

-- dd
goto_id(view, "buffers:" .. term)
feed("dd")
settle()
eq("dd on a terminal deletes it", vim.api.nvim_buf_is_valid(term), false)
ok("... and the window that showed it is still there", vim.api.nvim_win_is_valid(editor_win))
eq("... showing the buffer it showed before", vim.api.nvim_win_get_buf(editor_win), buf_readme)
goto_id(view, "buffers:" .. buf_b)
feed("dd")
settle()
eq("dd on a file buffer deletes the buffer, not the file", {
  vim.fn.buflisted(buf_b),
  vim.fn.filereadable(dir .. "/lua/b.lua"),
}, { 0, 1 })
eq("the list follows", lines(), {
  "▾ Buffers",
  "lua/a.lua",
  "README.md",
  outside_label,
  "[No Name]",
})
vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { "unsaved" })
-- the editor reports a change of 'modified' for the buffer one is in; this one was changed from outside
vim.cmd("doautocmd BufModifiedSet")
settle()
eq("a modified buffer has the status", view.tree:node("buffers:" .. unnamed).status, "modified")
goto_id(view, "buffers:" .. unnamed)
feed("dd")
settle()
eq("dd on a modified buffer keeps it", vim.api.nvim_buf_is_valid(unnamed), true)
eq(
  "... and says why",
  last_note(),
  "[filetree.native] [No Name] has unsaved changes: write it first"
)
vim.bo[unnamed].modified = false
feed("dd")
settle()
eq("... and deletes it once it is not", vim.fn.buflisted(unnamed), 0)

view:show("files")
eq("back in the files dd is gone", vim.fn.maparg("dd", "n"), "")

-- ── git ────────────────────────────────────────────────────────────────────────
view:show("git")
vim.wait(2000, function()
  return #lines() > 1
end)
eq("a root outside a repository says so", lines(), { "▾ Git", "not a git repository" })

if vim.fn.executable("git") == 1 then
  vim.fn.system({ "git", "-C", dir, "init", "-q" })
  vim.fn.system({ "git", "-C", dir, "add", "README.md", "lua/a.lua" })
  vim.fn.writefile({ "x", "changed" }, dir .. "/lua/a.lua") -- staged, then changed again
  vim.api.nvim_set_current_win(view.win)
  feed("R")
  vim.wait(5000, function()
    return #lines() > 3
  end)
  eq("the changed files, grouped by state, the groups open", lines(), {
    "▾ Git",
    "▾ Staged",
    "lua/a.lua",
    "README.md",
    "▾ Changes",
    "lua/a.lua",
    "▾ Untracked",
    "lua/b.lua",
  })
  eq("a group counts its files", view.tree:node("git:staged").columns, { "2" })
  eq("the head adds up the worst state below", view.tree:agg("git:root").status, "modified")
  goto_id(view, "git:untracked:" .. dir .. "/lua/b.lua")
  eq(
    "a changed file is a file for the features",
    { adapter.get_current_node().path, adapter.get_current_node().type },
    { dir .. "/lua/b.lua", "file" }
  )
  eq(
    "the features' own key applies to it (trash on d)",
    view.actions:resolve("d", view:current().node, action.ctx(view)).name,
    "feature:d"
  )
  feed("<CR>")
  eq("<CR> opens it in the editor window", {
    vim.api.nvim_get_current_win(),
    list.norm(vim.api.nvim_buf_get_name(0)),
  }, { editor_win, dir .. "/lua/b.lua" })

  -- stage and unstage
  local untracked_b = "git:untracked:" .. dir .. "/lua/b.lua"
  local staged_b = "git:staged:" .. dir .. "/lua/b.lua"
  local function names_here()
    return vim.tbl_map(function(item)
      return item.action.name
    end, action.applicable(view))
  end
  goto_id(view, untracked_b)
  ok("an untracked file can be staged", vim.tbl_contains(names_here(), "git.stage"))
  ok("... and not unstaged", not vim.tbl_contains(names_here(), "git.unstage"))
  view:collapse("git:changes")
  feed("ga")
  vim.wait(5000, function()
    return view.tree:node(staged_b) ~= nil
  end)
  eq("ga stages the file; a group closed by hand stays closed", lines(), {
    "▾ Git",
    "▾ Staged",
    "lua/a.lua",
    "lua/b.lua",
    "README.md",
    "▸ Changes",
  })
  goto_id(view, staged_b)
  ok("a staged file can be unstaged", vim.tbl_contains(names_here(), "git.unstage"))
  feed("gu")
  vim.wait(5000, function()
    return view.tree:node(untracked_b) ~= nil
  end)
  eq("gu takes it out of the index again", {
    view.tree:node(staged_b),
    view.tree:node(untracked_b).label,
  }, { nil, "lua/b.lua" })

  -- diff and blame are gitsuite.nvim's: offered when it is installed
  view:expand("git:changes")
  goto_id(view, "git:changes:" .. dir .. "/lua/a.lua")
  ok("without gitsuite.nvim no diff is offered", not vim.tbl_contains(names_here(), "git.diff"))
  local called = {}
  package.loaded["gitsuite.features.diff"] = {
    head = function()
      called[#called + 1] = "diff " .. list.norm(vim.api.nvim_buf_get_name(0))
    end,
  }
  package.loaded["gitsuite.features.blame"] = {
    full = function()
      called[#called + 1] = "blame " .. list.norm(vim.api.nvim_buf_get_name(0))
    end,
  }
  git._forget_gitsuite()
  ok(
    "with it, diff and blame are",
    vim.tbl_contains(names_here(), "git.diff") and vim.tbl_contains(names_here(), "git.blame")
  )
  feed("gd")
  goto_id(view, "git:changes:" .. dir .. "/lua/a.lua")
  feed("gB")
  eq("gd and gB open the file in the editor window and hand over to gitsuite", {
    called,
    vim.api.nvim_get_current_win(),
  }, { { "diff " .. dir .. "/lua/a.lua", "blame " .. dir .. "/lua/a.lua" }, editor_win })
  package.loaded["gitsuite.features.diff"], package.loaded["gitsuite.features.blame"] = nil, nil
  git._forget_gitsuite()

  -- live: a write is answered by another status, without a key
  vim.fn.writefile({ "x", "changed" }, dir .. "/README.md")
  vim.cmd("doautocmd BufWritePost")
  vim.wait(5000, function()
    return view.tree:node("git:changes:" .. dir .. "/README.md") ~= nil
  end)
  ok(
    "after a write the status is asked again",
    view.tree:node("git:changes:" .. dir .. "/README.md") ~= nil
  )
  vim.fn.delete(dir .. "/.git", "rf")
else
  say("  n/a  git: no git on this machine")
end

view:show("files")
eq("nothing at warning level in the whole run", loud(), {})
remove_decorator()
vim.notify = real_notify
native.reset()
eq("reset takes the tree's sources out of the registry", registry.get("source", "buffers"), nil)
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(dir, "rf")
vim.fn.delete(outside)

say(("\nfiletree.nvim native_source_builtin_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
