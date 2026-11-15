-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_sources_spec.lua -- views of registered sources in the own tree (stage E5): a source
-- shown in the tree window (lazy root, groups, leaves with and without a path), what switching keeps
-- (window, width, the files as they were left, a cursor per view), live updates through `emit`, a
-- subscription that runs only while the view is on screen, a source that cannot load, two sources as
-- sections of one view, actions of a source on its own rows only, and what the adapter hands the
-- features there.
--
--   nvim --clean --headless -u NONE -l TESTS/native_sources_spec.lua

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

-- ── fixture ────────────────────────────────────────────────────────────────────
local list = require("filetree.native.fs.list")
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_sources_%d"):format(base, vim.uv.hrtime() % 1e9)
local function mkfile(rel, lines)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines or { "x" }, path)
  return path
end
mkfile("lua/a.lua", { "one", "two", "three", "four" })
mkfile("lua/b.lua")
mkfile("sub/inner/c.lua")
mkfile("README.md")
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
local editor_win = vim.api.nvim_get_current_win()
local editor_buf = vim.api.nvim_get_current_buf()

-- ── two sources, registered before setup ───────────────────────────────────────
local registry = require("lib.nvim.tree.registry")
local spec = {
  items = { { name = "one", file = "lua/a.lua", lnum = 3 }, { name = "two", file = "README.md" } },
  ctx = {}, -- every ctx root() was called with
  subscribed = 0,
  stopped = 0,
  emit = nil,
  marked = {},
}
local function spec_items()
  return vim.tbl_map(function(item)
    return {
      id = "spec:" .. item.name,
      label = item.name,
      kind = "item",
      path = dir .. "/" .. item.file,
      data = item.lnum and { lnum = item.lnum, col = 1 } or nil,
    }
  end, spec.items)
end
local remove_spec = registry.source({
  name = "spec",
  title = "Spec",
  root = function(ctx)
    spec.ctx[#spec.ctx + 1] = ctx
    return {
      id = "spec:root",
      label = "Spec",
      columns = not spec.no_count and { tostring(#spec.items) } or nil,
      -- a lazy root that answers a group with a list of its own, and a leaf that is no file
      children = function(_, cb)
        cb({
          { id = "spec:group", label = "group", kind = "group", children = spec_items() },
          { id = "spec:note", label = "note", kind = "note" },
        })
      end,
    }
  end,
  subscribe = function(_, emit)
    spec.subscribed = spec.subscribed + 1
    spec.emit = emit
    return function()
      spec.stopped = spec.stopped + 1
      spec.emit = nil
    end
  end,
  actions = {
    {
      name = "spec.mark",
      key = "<F9>",
      desc = "Mark the item",
      needs = { "kind:item" },
      run = function(nodes, ctx)
        spec.marked[#spec.marked + 1] = { nodes[1].id, ctx.source, ctx.view }
        spec.tree = ctx.tree
      end,
    },
  },
})
local other_available, other_reason = true, "nothing to show right now"
local remove_other = registry.source({
  name = "other",
  root = function()
    return {
      id = "other:root",
      label = "Other",
      children = { { id = "other:x", label = "x", kind = "item", path = dir .. "/lua/b.lua" } },
    }
  end,
  available = function()
    if other_available then return true end
    return false, other_reason
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
---The lines of the tree buffer, without leading blanks.
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
local tree_win, tree_buf = view.win, view.buf
adapter.expand_node({ path = dir .. "/lua" })
vim.api.nvim_win_set_cursor(view.win, { adapter.get_node_line(dir .. "/lua/b.lua"), 0 })
vim.cmd("doautocmd CursorMoved")
local files_lines = lines()

-- ── the views there are ────────────────────────────────────────────────────────
eq(
  "without native.views: the files, then one view per registered source",
  vim.tbl_map(function(v)
    return v.name
  end, view:views()),
  { "files", "buffers", "git", "symbols", "diagnostics", "spec", "other" }
)
eq(
  "the tree starts on the files",
  { view.view_name, vim.b[tree_buf].filetree_view },
  { "files", "files" }
)
eq("nothing is asked of a source that is not shown", { #spec.ctx, spec.subscribed }, { 0, 0 })
eq("an unknown view is refused with the names there are", { view:show("nope") }, {
  false,
  'no view "nope" (views: files, buffers, git, symbols, diagnostics, spec, other)',
})

-- ── a source in the tree window ────────────────────────────────────────────────
local seen_event = nil
vim.api.nvim_create_autocmd("User", {
  pattern = "FiletreeView",
  callback = function(ev)
    seen_event = ev.data
  end,
})
eq("show() answers true", { view:show("spec") }, { true })
eq(
  "the root answered lazily is open, its group closed",
  lines(),
  { "▾ Spec", "▸ group", "note" }
)
eq(
  "the window and the buffer are the ones that were there",
  { view.win, view.buf },
  { tree_win, tree_buf }
)
eq("... and as wide", vim.api.nvim_win_get_width(tree_win), 34)
eq("the buffer says which view it shows", vim.b[tree_buf].filetree_view, "spec")
eq("User FiletreeView names buffer and view", seen_event, { buf = tree_buf, view = "spec" })
eq("the source was asked with the root, the view and the editor buffer", {
  spec.ctx[1].root,
  spec.ctx[1].view,
  spec.ctx[1].source,
  spec.ctx[1].alt_buf,
}, { dir, "spec", "spec", editor_buf })
eq("it is followed while it is on screen", { spec.subscribed, spec.stopped }, { 1, 0 })
eq("a group of a source has no trailing slash", lines()[2], "▸ group")

view:expand("spec:group")
eq("a group opens like a folder", lines(), { "▾ Spec", "▾ group", "one", "two", "note" })

-- ── what the adapter hands the features ────────────────────────────────────────
goto_id(view, "spec:one")
eq(
  "a node with a path is a file for the features",
  { adapter.get_current_node().path, adapter.get_current_node().type },
  { dir .. "/lua/a.lua", "file" }
)
goto_id(view, "spec:note")
eq("a node without a path is no entry for them", adapter.get_current_node(), nil)
goto_id(view, "spec:group")
eq("... nor is a group", adapter.get_current_node(), nil)
eq(
  "the visible nodes are the ones with a path",
  vim.tbl_map(function(n)
    return n.path
  end, adapter.get_visible_nodes()),
  { dir .. "/lua/a.lua", dir .. "/README.md" }
)
eq("a path is found where a source shows it", adapter.get_node_line(dir .. "/README.md"), 4)
eq("... and not where none does", adapter.get_node_line(dir .. "/lua/b.lua"), nil)

-- ── opening a node ─────────────────────────────────────────────────────────────
goto_id(view, "spec:one")
feed("<CR>")
eq("<CR> on a leaf opens its file in the editor window", {
  vim.api.nvim_get_current_win(),
  list.norm(vim.api.nvim_buf_get_name(0)),
}, { editor_win, dir .. "/lua/a.lua" })
eq("... at the place the source gave", vim.api.nvim_win_get_cursor(editor_win), { 3, 1 })
goto_id(view, "spec:note")
feed("<CR>")
eq(
  "<CR> on a leaf that is nothing to open stays in the tree",
  vim.api.nvim_get_current_win(),
  tree_win
)

-- ── actions ────────────────────────────────────────────────────────────────────
goto_id(view, "spec:two")
feed("<F9>")
eq(
  "a key of the source runs on its node, with the source and the name of the view in ctx",
  spec.marked,
  {
    { "spec:two", "spec", "spec" },
  }
)
ok("... and the tree view itself as ctx.tree", spec.tree == view)
eq(
  "a source is told the name of the view under the same field, and no tree",
  { type(spec.ctx[1].view), spec.ctx[1].tree },
  { "string", nil }
)
goto_id(view, "spec:group")
feed("<F9>")
eq(
  "... and says why not where it does not apply",
  last_note(),
  "[filetree.native] <F9>: needs a item"
)
eq("an action of the directory tree does not run in another view", action.run(view, "up"), false)
eq("... and says so", last_note(), "[filetree.native] up: only in the files view")
eq("... and the view is still the source's", view.view_name, "spec")

-- ── live updates ───────────────────────────────────────────────────────────────
goto_id(view, "spec:two")
spec.emit.push({ id = "spec:note", label = "note!" })
eq("emit.push rewrites the one line", lines()[5], "note!")
spec.items[#spec.items + 1] = { name = "three", file = "lua/b.lua" }
table.remove(spec.items, 1)
spec.emit.reset()
eq("emit.reset asks the source again; the open group stays open", lines(), {
  "▾ Spec",
  "▾ group",
  "two",
  "three",
  "note",
})
eq("the cursor stays on its node", view:current().id, "spec:two")
eq("the root took over its new column", view.tree:node("spec:root").columns, { "2" })
spec.items[#spec.items + 1] = { name = "four", file = "sub/inner/c.lua" }
spec.emit.invalidate("spec:root")
eq("emit.invalidate of the root does the same", lines()[5], "four")
-- a head that no longer carries a field loses it (the old count must not stand there)
spec.no_count = true
spec.emit.reset()
eq("a root that comes back without its column loses it", view.tree:node("spec:root").columns, nil)
eq("... and nothing else of the view changed", lines()[5], "four")
spec.no_count = nil
spec.emit.reset()
eq("... and gets it back", view.tree:node("spec:root").columns, { "3" })

-- ── a subscription only while the view is on screen ────────────────────────────
view:close()
eq("closing the window stops following", { spec.subscribed, spec.stopped }, { 1, 1 })
local asked = #spec.ctx
table.remove(spec.items) -- "four" goes while nobody follows
view:open(nil, true)
eq("opening it follows again", { spec.subscribed, spec.stopped }, { 2, 1 })
ok("... after asking the source again", #spec.ctx > asked)
eq(
  "what changed meanwhile is on screen",
  lines(),
  { "▾ Spec", "▾ group", "two", "three", "note" }
)
eq("the window is as wide as before", vim.api.nvim_win_get_width(view.win), 34)

-- ── back to the files ──────────────────────────────────────────────────────────
goto_id(view, "spec:three")
eq("show(files)", { view:show("files") }, { true })
eq("the files are as they were left", lines(), files_lines)
eq("... with their cursor", view:current().node.path, dir .. "/lua/b.lua")
eq("the source is not followed any more", { spec.subscribed, spec.stopped }, { 2, 2 })
eq("a key of the source is gone with it", vim.fn.maparg("<F9>", "n"), "")
feed("-")
eq("the files' own key works again", view.root, list.parent(dir))
view:set_root(dir)
adapter.expand_node({ path = dir .. "/lua" })

-- a change of the listing asked for while another view is shown is made when the files come back
view:show("spec")
eq("the view kept its cursor", view:current().id, "spec:three")
adapter.set_sort("name", true)
eq("sorting the files leaves the other view on screen", lines()[1], "▾ Spec")
view:show("files")
eq("... and is in force when the files are shown again", { lines()[2], lines()[#lines()] }, {
  "▸ sub/inner/",
  "README.md",
})
adapter.set_sort("name", false)

-- the root directory of the view belongs to the ctx: a source is asked again when it changes
view:show("spec")
asked = #spec.ctx
view:set_root(dir .. "/lua")
ok("set_root asks the source on screen again", #spec.ctx > asked)
eq("... with the new root", spec.ctx[#spec.ctx].root, dir .. "/lua")
eq("... and leaves it on screen", lines()[1], "▾ Spec")
view:show("files")
eq("the files show the new root", lines()[1], "▾ lua/")
view:set_root(dir)

-- ── a source that cannot load ──────────────────────────────────────────────────
other_available = false
view:show("other")
eq("it shows one line that says why", lines(), { "Other  [!] nothing to show right now" })
eq("its section says so too", {
  view:sections()[1].available,
  view:sections()[1].reason,
}, { false, "nothing to show right now" })
vim.api.nvim_set_current_win(view.win)
feed("<CR>")
eq(
  "<CR> on that line repeats it",
  last_note(),
  "[filetree.native] Other  [!] nothing to show right now"
)
other_reason = "still nothing"
feed("R")
eq("R asks again: another reason is another line", lines(), { "Other  [!] still nothing" })
other_available, other_reason = true, "nothing to show right now"
feed("R")
eq("R asks again: the source is there now", lines(), { "▾ Other", "x" })

-- ── two sources as sections of one view ────────────────────────────────────────
native.setup(vim.tbl_extend("force", native.options(), {
  views = { { "files" }, { name = "both", "spec", "other" }, { "missing" } },
}))
eq(
  "native.views names the views",
  vim.tbl_map(function(v)
    return { v.name, v.sources }
  end, view:views()),
  { { "files", { "files" } }, { "both", { "spec", "other" } }, { "missing", { "missing" } } }
)
view:show("both")
eq("each source is a section under a hidden root", lines(), {
  "▾ Spec",
  "▸ group",
  "note",
  "▾ Other",
  "x",
})
eq(
  "both heads stand at depth 0",
  { view:row(1).depth, view:row(4).depth, view:row(5).depth },
  { 0, 0, 1 }
)
goto_id(view, "other:x")
eq("the source of a node is the section it is in", action.ctx(view).source, "other")
feed("<F9>")
eq("a key of one source does nothing on the rows of another", {
  #spec.marked,
  last_note(),
}, { 1, "[filetree.native] <F9>: only in the spec view" })
spec.emit.push({ id = "other:x", label = "taken over" })
spec.emit.invalidate("other:root")
eq("a source cannot change the nodes of another section", lines()[5], "x")
view:expand("spec:group")
goto_id(view, "spec:two")
feed("<F9>")
eq("... and runs on its own", spec.marked[#spec.marked], { "spec:two", "spec", "both" })
feed("z")
eq("closing everything keeps the sections open", lines(), {
  "▾ Spec",
  "▸ group",
  "note",
  "▾ Other",
  "x",
})
eq("... and puts the cursor on the head of its section", view:current().id, "spec:root")

view:show("missing")
eq("a view of a source nobody registered says so", lines(), {
  "Missing  [!] no source of this name is registered",
})

-- ── a source registered or replaced while it is shown ──────────────────────────
local remove_missing = registry.source({
  name = "missing",
  root = function()
    return { id = "missing:root", label = "Found", children = {} }
  end,
})
settle(60)
eq("a source registered later is shown where its view is on screen", lines(), { "Found" })
remove_missing()
settle(60)
eq("... and gone again when it is removed", lines(), {
  "Missing  [!] no source of this name is registered",
})

-- two sources that answer the same id: the view says so, it does not raise
local remove_clash = registry.source({
  name = "clash",
  root = function()
    return { id = "other:root", label = "Clash" }
  end,
})
native.setup(vim.tbl_extend("force", native.options(), {
  views = { { "files" }, { name = "bad", "other", "clash" } },
}))
ok("a view whose sources clash still shows", (view:show("bad")))
ok("... one line with the reason", #lines() == 1 and lines()[1]:find("duplicate node id", 1, true))
remove_clash()

-- ── the example source of docs/api.md, in the tree ─────────────────────────────
-- native_contract_spec.lua checks that the example loads against the types; here it is shown.
local api_md = table.concat(vim.fn.readfile(root .. "/docs/api.md"), "\n")
local example = api_md:match("<!%-%- example:source %-%->\n```lua\n(.-)\n```")
ok(
  "the example source of docs/api.md runs",
  pcall(loadstring(example or "error('none')", "example"))
)
native.setup(vim.tbl_extend("force", native.options(), { views = {} }))
ok("a source registered the way the page says is a view of the tree", (view:show("todo")))
eq("... with the groups of the example", lines(), { "▾ Todo", "▸ today", "▸ later" })
view:expand("todo:today")
goto_id(view, "todo:/notes/bank.md")
eq(
  "its leaf is a file for the features, because it carries a path",
  adapter.get_current_node().path,
  "/notes/bank.md"
)
eq(
  "the action it brought applies to its own kind of node",
  view.actions:resolve("gd", view:current().node, action.ctx(view)).name,
  "todo.done"
)

-- ── a node that carries the path of the node above it ──────────────────────────
-- a test case under its spec file, a symbol under its file: a place in the file, not the file
do
  local spec_file = dir .. "/lua/a.lua"
  local remove_places = registry.source({
    name = "places",
    root = function()
      return {
        id = "places:root",
        label = "Places",
        children = {
          {
            id = "places:file",
            label = "a.lua",
            kind = "file",
            path = spec_file,
            children = {
              { id = "places:case1", label = "first case", kind = "case", path = spec_file },
              {
                id = "places:describe",
                label = "a describe block",
                kind = "describe",
                path = spec_file,
                children = {
                  { id = "places:case3", label = "third case", kind = "case", path = spec_file },
                },
              },
              {
                id = "places:group",
                label = "a group",
                kind = "group",
                children = function(_, cb)
                  cb({
                    { id = "places:case2", label = "second case", kind = "case", path = spec_file },
                  })
                end,
              },
            },
          },
          { id = "places:other", label = "b.lua", kind = "file", path = dir .. "/lua/b.lua" },
        },
      }
    end,
  })
  eq("the view of the places", { view:show("places") }, { true })
  settle(100)
  local file_line = adapter.get_node_line(spec_file)
  ok("the path is on the row of the file while the file is closed", file_line ~= nil)
  eq("... and that row is the file", view:row(file_line).id, "places:file")
  view:expand("places:file")
  settle(50)
  eq(
    "with its cases open the path is still the file's",
    view:row(adapter.get_node_line(spec_file)).id,
    "places:file"
  )
  view:expand("places:group")
  settle(50)
  eq(
    "... also after a lazy group below brought another node with that path",
    view:row(adapter.get_node_line(spec_file)).id,
    "places:file"
  )
  ok("reveal of the path lands on the file", view:reveal(spec_file))
  eq("... not on a case", view:current().id, "places:file")
  eq(
    "a node with a path of its own keeps it",
    view:row(adapter.get_node_line(dir .. "/lua/b.lua")).id,
    "places:other"
  )
  local describe_text = lines()[view.tree:row_of("places:describe")]
  ok(
    "an expandable node that says what it is gets no folder slash: " .. tostring(describe_text),
    describe_text ~= nil and describe_text:find("a describe block/", 1, true) == nil
  )
  remove_places()
end

view:show("files")
eq(
  "the files are still there after all of it",
  lines()[1],
  "▾ " .. vim.fn.fnamemodify(dir, ":t") .. "/"
)

eq("nothing at warning level in the whole run", loud(), {})
remove_spec()
-- ── a node that starts open, and its source registered again ──────────────────
-- (the plugin behind a source is set up a second time: testing.nvim's view of the tests showed its
-- one spec folder closed after that)
for _, how in ipairs({ "list", "lazy", "late" }) do
  local name = "opens_" .. how
  local dir_id = name .. ":dir"
  local function kids()
    return {
      {
        id = dir_id,
        label = "only",
        kind = "dir",
        open = true,
        children = { { id = name .. ":leaf", label = "leaf", kind = "note" } },
      },
    }
  end
  local function register_opens()
    local children = kids()
    if how == "lazy" then
      -- a root that is asked and answers at once
      children = function(_, cb)
        cb(kids())
      end
    elseif how == "late" then
      -- ... and one that answers a moment later
      children = function(_, cb)
        vim.defer_fn(function()
          cb(kids())
        end, 10)
      end
    end
    return registry.source({
      name = name,
      title = "Opens",
      root = function()
        return { id = name .. ":root", label = "Opens", children = children }
      end,
    })
  end
  local function is_open()
    return view.tree:node(dir_id) ~= nil and view.tree:is_expanded(dir_id)
  end
  ---Wait until the node is there and open (a root that answers later, a queue that is busy).
  local function opens()
    return vim.wait(2000, is_open, 10)
  end
  ---Wait until the node is there, then let what follows its arrival run.
  local function arrived()
    vim.wait(2000, function()
      return view.tree:node(dir_id) ~= nil
    end, 10)
    settle(60)
  end
  local remove_opens = register_opens()
  native.setup(vim.tbl_extend("force", native.options(), { views = {} }))
  ok(how .. ": (the view of the source shows)", (view:show(name)))
  settle(60)
  ok(how .. ": a node that says open = true starts open", opens())
  -- registered again while its view is on screen: taken away and brought back
  remove_opens()
  remove_opens = register_opens()
  settle(60)
  eq(how .. ": (still the view of the source)", view.view_name, name)
  ok(how .. ": registered again while on screen: the node is open", opens())
  -- ... registered over itself, without being taken away first
  register_opens()
  settle(60)
  ok(how .. ": registered over itself: the node is open", opens())
  -- ... and while another view is on screen
  view:show("files")
  remove_opens()
  remove_opens = register_opens()
  settle(60)
  view:show(name)
  settle(60)
  ok(how .. ": registered again while the files were shown: open when its view comes back", opens())
  -- closed by hand it stays closed, as long as the source is the same registration
  view:collapse(dir_id)
  view:show("files")
  view:show(name)
  arrived()
  ok(how .. ": closed by hand: closed when the view comes back", not is_open())
  view:refresh()
  settle(60)
  arrived()
  ok(how .. ": ... and after a refresh", not is_open())
  view:show("files")
  remove_opens()
end

-- the flag comes with a later answer, and nothing else about the node changes: no row is written,
-- and the node is opened all the same (a view of tests that learns only then that there is one folder)
do
  local says_open, emit = false, nil
  local remove_later = registry.source({
    name = "opens_later",
    title = "Later",
    root = function()
      return {
        id = "opens_later:root",
        label = "Later",
        children = {
          {
            id = "opens_later:dir",
            label = "only",
            kind = "dir",
            open = says_open or nil,
            children = { { id = "opens_later:leaf", label = "leaf", kind = "note" } },
          },
        },
      }
    end,
    subscribe = function(_, e)
      emit = e
      return function()
        emit = nil
      end
    end,
  })
  native.setup(vim.tbl_extend("force", native.options(), { views = {} }))
  ok("(the view of the source shows)", (view:show("opens_later")))
  settle(60)
  ok("a node that does not say open starts closed", not view.tree:is_expanded("opens_later:dir"))
  says_open = true
  emit.reset()
  ok(
    "the flag comes with a later answer: the node is opened",
    vim.wait(1000, function()
      return view.tree:is_expanded("opens_later:dir")
    end, 10)
  )
  eq("... and its content is on screen", lines()[#lines()], "leaf")
  view:show("files")
  remove_later()
end

-- A node that was open, comes once without children and without the word, and then says
-- `open = true` again: that is a new request (a pipeline step that was red, runs again, is red again).
do
  local shape, emit = "red", nil
  local remove_steps = registry.source({
    name = "steps",
    title = "Steps",
    root = function()
      local step = { id = "steps:lint", label = "lint", kind = "step" }
      if shape == "red" then
        step.open = true
        step.children = { { id = "steps:finding", label = "finding", kind = "note" } }
      end
      return { id = "steps:root", label = "Steps", children = { step } }
    end,
    subscribe = function(_, e)
      emit = e
      return function()
        emit = nil
      end
    end,
  })
  native.setup(vim.tbl_extend("force", native.options(), { views = {} }))
  settle(60)
  ok("(the view shows)", (view:show("steps")))
  ok("a red step starts open", vim.tbl_contains(lines(), "finding"))
  shape = "queued"
  emit.reset()
  settle(60)
  ok("it runs again: no findings, nothing to open", not vim.tbl_contains(lines(), "finding"))
  shape = "red"
  emit.reset()
  ok(
    "red again: it is open again, nobody closed it by hand",
    vim.wait(1000, function()
      return vim.tbl_contains(lines(), "finding")
    end, 10)
  )
  -- closed by hand it stays closed while it keeps saying open = true
  view:collapse("steps:lint")
  emit.reset()
  settle(60)
  ok("closed by hand and asked again: it stays closed", not vim.tbl_contains(lines(), "finding"))
  -- ... until it has come once without the word
  shape = "queued"
  emit.reset()
  settle(60)
  shape = "red"
  emit.reset()
  ok(
    "after a round without findings a red step opens again",
    vim.wait(1000, function()
      return vim.tbl_contains(lines(), "finding")
    end, 10)
  )
  view:show("files")
  remove_steps()
end

-- ── the open nodes of a view of sources, read and set ──────────────────────────
-- (what a session stores next to the open folders of the files)
do
  ---@param name string
  local function register_groups(name)
    return registry.source({
      name = name,
      title = "Groups",
      root = function()
        return {
          id = name .. ":root",
          label = "Groups",
          children = {
            {
              id = name .. ":a",
              label = "a",
              kind = "group",
              children = {
                {
                  id = name .. ":a1",
                  label = "a1",
                  kind = "group",
                  children = { { id = name .. ":a1x", label = "x", kind = "note" } },
                },
              },
            },
            {
              id = name .. ":b",
              label = "b",
              kind = "group",
              -- read when it is opened, and it answers a moment later
              children = function(_, cb)
                vim.defer_fn(function()
                  cb({
                    {
                      id = name .. ":b1",
                      label = "b1",
                      kind = "group",
                      children = { { id = name .. ":b1x", label = "y", kind = "note" } },
                    },
                  })
                end, 10)
              end,
            },
            {
              id = name .. ":c",
              label = "c",
              kind = "group",
              open = true,
              children = { { id = name .. ":c1", label = "z", kind = "note" } },
            },
          },
        }
      end,
    })
  end
  local remove_groups = register_groups("groups")
  local remove_later = register_groups("groups2")
  native.setup(vim.tbl_extend("force", native.options(), { views = {} }))

  eq("the files have paths for this: no ids", adapter.get_open_nodes("files"), nil)
  eq("a name no view has: nothing is known", adapter.get_open_nodes("no-such-view"), nil)
  eq("the files cannot be set this way", adapter.set_open_nodes("files", {}), false)
  eq("a view that was never shown: nothing is known", adapter.get_open_nodes("groups"), nil)

  ok("(the view shows)", (view:show("groups")))
  eq(
    "the open nodes of the view on screen: the head and the node that starts open",
    adapter.get_open_nodes(),
    { "groups:root", "groups:c" }
  )
  view:expand("groups:a")
  view:expand("groups:a1")
  eq(
    "top to bottom, a folder before what is in it",
    adapter.get_open_nodes("groups"),
    { "groups:root", "groups:a", "groups:a1", "groups:c" }
  )

  -- set: what is not named is closed, what is named is opened, also below a node read later
  eq(
    "set_open_nodes answers true",
    adapter.set_open_nodes(
      "groups",
      { "groups:root", "groups:b", "groups:b1", 7, {}, "groups:gone" }
    ),
    true
  )
  ok(
    "a node below a folder that answers later is opened when it arrives",
    vim.wait(2000, function()
      return view.tree:node("groups:b1") ~= nil and view.tree:is_expanded("groups:b1")
    end, 10)
  )
  eq(
    "exactly the named nodes are open (an id that is none is passed over)",
    adapter.get_open_nodes("groups"),
    { "groups:root", "groups:b", "groups:b1" }
  )
  eq("... and the lines follow", lines()[#lines() - 1], "y")
  eq("... the cursor is on a row of the view", view.tree:row_of(view.cursor_id) ~= nil, true)
  -- the section head can be closed this way too
  adapter.set_open_nodes("groups", {})
  eq("nothing named: the head is closed", adapter.get_open_nodes("groups"), {})
  eq("... one line is left", #lines(), 1)
  adapter.set_open_nodes("groups", { "groups:root", "groups:a" })
  eq("... and opened again", adapter.get_open_nodes("groups"), { "groups:root", "groups:a" })

  -- the source registers again (its plugin is set up a second time, or only now): the view is built
  -- again in place, and what was open is open again, also what was opened or closed by hand
  view:expand("groups:a1")
  remove_groups()
  remove_groups = register_groups("groups")
  settle(80)
  eq("(still that view)", view.view_name, "groups")
  eq(
    "the source registered again: the same nodes are open",
    adapter.get_open_nodes("groups"),
    { "groups:root", "groups:a", "groups:a1" }
  )
  ok(
    "... the node that starts open and was closed stays closed",
    not view.tree:is_expanded("groups:c")
  )
  adapter.set_open_nodes("groups", {})
  remove_groups()
  remove_groups = register_groups("groups")
  settle(80)
  eq(
    "a head that was closed stays closed over a new registration",
    adapter.get_open_nodes("groups"),
    {}
  )
  adapter.set_open_nodes("groups", { "groups:root", "groups:a" })

  -- a view that was not shown yet takes them over when it is
  view:show("files")
  eq(
    "set for a view never shown: true",
    adapter.set_open_nodes("groups2", { "groups2:root", "groups2:a", "groups2:a1" }),
    true
  )
  eq(
    "... read back before it is shown",
    adapter.get_open_nodes("groups2"),
    { "groups2:root", "groups2:a", "groups2:a1" }
  )
  eq("(the files are still on screen)", view.view_name, "files")
  view:show("groups2")
  eq(
    "shown: those nodes are open, the one that starts open by itself is not",
    adapter.get_open_nodes(),
    { "groups2:root", "groups2:a", "groups2:a1" }
  )
  ok("... on screen", vim.tbl_contains(lines(), "x"))
  -- a view that is built and not on screen
  view:show("files")
  adapter.set_open_nodes("groups", { "groups:root", "groups:c" })
  eq("set while the files are shown: read back", adapter.get_open_nodes("groups"), {
    "groups:root",
    "groups:c",
  })
  view:show("groups")
  ok("... and on screen when the view comes back", vim.tbl_contains(lines(), "z"))
  ok("... what was open before is closed", not vim.tbl_contains(lines(), "a1"))
  -- everything closed is a list, not "nothing known"
  adapter.set_open_nodes("groups", {})
  eq("everything closed by hand answers an empty list", adapter.get_open_nodes("groups"), {})
  view:show("files")
  eq("... also while the view is not on screen", adapter.get_open_nodes("groups"), {})
  -- a view nobody registered yet: its plugin is set up after the session was loaded
  eq(
    "ids set for a name no view has yet are kept",
    adapter.set_open_nodes("groups3", { "groups3:root", "groups3:a", math.huge, 0 / 0 }),
    true
  )
  eq(
    "... and read back (a number that is none is passed over)",
    adapter.get_open_nodes("groups3"),
    { "groups3:root", "groups3:a" }
  )
  local remove_third = register_groups("groups3")
  native.setup(vim.tbl_extend("force", native.options(), { views = {} }))
  settle(60)
  ok("(the view of the source that came late shows)", (view:show("groups3")))
  eq(
    "registered later and shown: those nodes are open, the one that starts open by itself is not",
    adapter.get_open_nodes(),
    { "groups3:root", "groups3:a" }
  )
  view:show("files")
  remove_groups()
  remove_later()
  remove_third()
end

remove_other()
vim.notify = real_notify
native.reset()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_sources_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
