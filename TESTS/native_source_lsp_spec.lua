-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_source_lsp_spec.lua -- the sources `symbols` and `diagnostics` of the own tree (stage
-- E5). Pure: a server answer (hierarchy and flat list) to nodes, the symbol a line lies in, a list of
-- diagnostics to folders, files and leaves in severity order. In a real tree, with a language server
-- inside this process: the symbols of the editor buffer, a tree cursor that follows the editor's, an
-- edit, a buffer without a server; diagnostics set and cleared, what the adapter hands the features.
--
--   nvim --clean --headless -u NONE -l TESTS/native_source_lsp_spec.lua

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
local function loud()
  local out = {}
  for _, note in ipairs(notes) do
    if note.level >= vim.log.levels.WARN then out[#out + 1] = note.msg end
  end
  return out
end

-- ── symbols, pure ──────────────────────────────────────────────────────────────
local symbols = require("filetree.native.source.symbols")
local function range(first, last)
  return { start = { line = first, character = 0 }, ["end"] = { line = last, character = 0 } }
end
local function sym(name, kind, first, last, children)
  return {
    name = name,
    kind = kind,
    range = range(first, last),
    selectionRange = {
      start = { line = first, character = 6 },
      ["end"] = { line = first, character = 9 },
    },
    children = children,
  }
end
local hierarchy = {
  sym("M", 5, 0, 9, { sym("setup", 6, 1, 3), sym("run", 6, 5, 8, { sym("inner", 12, 6, 7) }) }),
  sym("helper", 12, 11, 12),
  sym("helper", 12, 14, 15),
}
local nodes = symbols.nodes(hierarchy, 7)
local function shape(list)
  return vim.tbl_map(function(node)
    return { node.id, node.kind, node.open, node.children and shape(node.children) or nil }
  end, list)
end
eq("a hierarchy: ids are name paths, a container of the first level starts open", shape(nodes), {
  {
    "symbols:7/M",
    "class",
    true,
    {
      { "symbols:7/M/setup", "method" },
      { "symbols:7/M/run", "method", nil, { { "symbols:7/M/run/inner", "function" } } },
    },
  },
  { "symbols:7/helper", "function" },
  { "symbols:7/helper#2", "function" },
})
eq("a symbol opens its buffer at its name", nodes[1].children[2].data, {
  bufnr = 7,
  lnum = 6,
  col = 6,
  first = 6,
  last = 9,
  depth = 1,
})
eq("no symbol has a path", { nodes[1].path, nodes[1].children[1].path }, {})
eq("the innermost symbol a line lies in", {
  symbols.at(nodes, 2),
  symbols.at(nodes, 7),
  symbols.at(nodes, 9),
  symbols.at(nodes, 10),
  symbols.at(nodes, 11),
  symbols.at(nodes, 15),
}, {
  "symbols:7/M/setup",
  "symbols:7/M/run/inner",
  "symbols:7/M/run",
  "symbols:7/M",
  nil,
  "symbols:7/helper#2",
})
local function info(name, kind, first, last, container)
  return {
    name = name,
    kind = kind,
    containerName = container,
    location = { uri = "file:///x", range = range(first, last) },
  }
end
eq(
  "a flat list with container names is the same tree",
  shape(symbols.nodes({
    info("M", 5, 0, 9),
    info("setup", 6, 1, 3, "M"),
    info("run", 6, 5, 8, "M"),
    info("helper", 12, 11, 12),
  }, 7)),
  {
    {
      "symbols:7/M",
      "class",
      true,
      { { "symbols:7/M/setup", "method" }, { "symbols:7/M/run", "method" } },
    },
    { "symbols:7/helper", "function" },
  }
)
eq("no answer, no nodes", { symbols.nodes(nil, 7), symbols.nodes({}, 7) }, { {}, {} })

-- ── diagnostics, pure ──────────────────────────────────────────────────────────
local diagnostics = require("filetree.native.source.diagnostics")
local function diag(path, lnum, severity, message)
  return { path = path, bufnr = 1, lnum = lnum, col = 2, severity = severity, message = message }
end
local tree = diagnostics.tree({
  diag("/p/lua/b.lua", 3, "hint", "a hint"),
  diag("/p/docs/x.md", 0, "warn", "a warning"),
  diag("/p/lua/a.lua", 9, "warn", "late warning"),
  diag("/p/lua/a.lua", 4, "error", "an error\n  on two lines"),
  diag("/p/lua/a.lua", 4, "error", "a second one at the same place"),
  diag("/p/top.lua", 0, "info", "some info"),
  diag("/elsewhere/z.lua", 0, "hint", "outside"),
}, "/p")
eq(
  "folders, files and diagnostics, the worst first, then by name, place and text",
  vim.tbl_map(function(folder)
    return {
      folder.label,
      vim.tbl_map(function(file)
        return {
          file.label,
          vim.tbl_map(function(leaf)
            return leaf.status .. " " .. leaf.columns[1] .. " " .. leaf.label
          end, file.children),
        }
      end, folder.children),
    }
  end, tree),
  {
    {
      "lua",
      {
        {
          "a.lua",
          {
            "error 5:3 a second one at the same place",
            "error 5:3 an error on two lines",
            "warn 10:3 late warning",
          },
        },
        { "b.lua", { "hint 4:3 a hint" } },
      },
    },
    { "docs", { { "x.md", { "warn 1:3 a warning" } } } },
    { ".", { { "top.lua", { "info 1:3 some info" } } } },
    { "/elsewhere", { { "z.lua", { "hint 1:3 outside" } } } },
  }
)
eq("a folder and a file carry their path, a diagnostic its place", {
  tree[1].path,
  tree[1].kind,
  tree[1].children[1].path,
  tree[1].children[1].kind,
  tree[1].children[1].children[1].path,
  tree[1].children[1].children[1].data.lnum,
}, { "/p/lua", "dir", "/p/lua/a.lua", "file", nil, 5 })
eq("two diagnostics at one place have two ids", {
  tree[1].children[1].children[1].id,
  tree[1].children[1].children[2].id,
}, { "diagnostics:/p/lua/a.lua:4:2:1", "diagnostics:/p/lua/a.lua:4:2:2" })
eq("none: one line", diagnostics.tree({}, "/p")[1].label, "no diagnostics")

-- ── fixture ────────────────────────────────────────────────────────────────────
local list = require("filetree.native.fs.list")
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_lsp_%d"):format(base, vim.uv.hrtime() % 1e9)
vim.fn.mkdir(dir .. "/lua", "p")
local mod_lines = {}
for i = 1, 16 do
  mod_lines[i] = "-- line " .. i
end
vim.fn.writefile(mod_lines, dir .. "/lua/mod.lua")
vim.fn.writefile({ "plain" }, dir .. "/notes.txt")
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/lua/mod.lua"))
local editor_win = vim.api.nvim_get_current_win()
local mod_buf = vim.api.nvim_get_current_buf()

-- a language server in this process: it answers the symbols above for every file
local asked = 0
local answer = hierarchy
local client_id = vim.lsp.start({
  name = "spec_ls",
  root_dir = dir,
  cmd = function()
    local closing = false
    return {
      request = function(method, _, callback)
        if method == "initialize" then
          callback(nil, { capabilities = { documentSymbolProvider = true } })
        elseif method == "textDocument/documentSymbol" then
          asked = asked + 1
          callback(nil, answer)
        else
          callback(nil, vim.NIL)
        end
        return true, 1
      end,
      notify = function()
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
      end,
    }
  end,
}, { bufnr = mod_buf })
vim.wait(2000, function()
  return #vim.lsp.get_clients({ bufnr = mod_buf, method = "textDocument/documentSymbol" }) > 0
end)
ok(
  "the server of the spec is attached",
  client_id ~= nil and #vim.lsp.get_clients({ bufnr = mod_buf }) == 1
)

local filetree = require("filetree")
ok(
  "setup with adapter = native",
  pcall(filetree.setup, {
    adapter = "native",
    deps_popup = false,
    native = { width = 50, watch = false },
    features = {
      session = { enabled = false },
      auto_reveal = { enabled = false },
      close_on_open = { enabled = false },
    },
  })
)
local adapter = filetree.adapter()
local native = require("filetree.native")
local bar = require("filetree.native.bar")

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
local function item_of(view, name)
  for _, item in ipairs(bar.items(view)) do
    if item.name == name then return item end
  end
end

adapter.toggle_at("left", { dir = dir })
settle(150)
local view = native.current()
vim.api.nvim_set_current_win(editor_win)

eq(
  "the views of the tree: the files and its four sources",
  vim.tbl_map(function(v)
    return v.name
  end, view:views()),
  { "files", "buffers", "git", "symbols", "diagnostics" }
)

-- ── symbols ────────────────────────────────────────────────────────────────────
eq(
  "symbols can load: the editor buffer has a server",
  { item_of(view, "symbols").available },
  { true }
)
view:show("symbols")
vim.wait(2000, function()
  return #lines() > 2
end)
local s = "symbols:" .. mod_buf
eq("the symbols of the editor buffer, the class open", lines(), {
  "▾ Symbols  mod.lua",
  "▾ M",
  "setup",
  "▸ run",
  "helper",
  "helper",
})
eq("the kind stands at the right of a symbol", view.tree:node(s .. "/M/run").columns, { "method" })

goto_id(view, s .. "/M/setup")
eq("a symbol is no file for the features", adapter.get_current_node(), nil)
feed("<CR>")
eq("<CR> on a symbol goes to its name in the editor window", {
  vim.api.nvim_get_current_win(),
  vim.api.nvim_get_current_buf(),
  vim.api.nvim_win_get_cursor(0),
}, { editor_win, mod_buf, { 2, 6 } })

-- the cursor of the editor moves the cursor of the tree
vim.api.nvim_win_set_cursor(editor_win, { 7, 0 })
vim.cmd("doautocmd CursorMoved")
vim.wait(1000, function()
  return view.cursor_id == s .. "/M/run/inner"
end)
eq("the tree follows the cursor to the innermost symbol, opening what is above it", {
  view.cursor_id,
  vim.api.nvim_win_get_cursor(view.win)[1],
  lines()[5],
}, { s .. "/M/run/inner", 5, "inner" })
vim.api.nvim_win_set_cursor(editor_win, { 12, 0 })
vim.cmd("doautocmd CursorMoved")
vim.wait(1000, function()
  return view.cursor_id == s .. "/helper"
end)
eq("... and on", view.cursor_id, s .. "/helper")

-- an edit asks again
answer = { sym("M", 5, 0, 9, { sym("setup", 6, 1, 3) }), sym("added", 12, 11, 12) }
local before = asked
vim.cmd("doautocmd TextChanged")
vim.wait(2000, function()
  return vim.tbl_contains(lines(), "added")
end)
eq("after an edit the symbols are asked again", { asked > before, lines() }, {
  true,
  { "▾ Symbols  mod.lua", "▾ M", "setup", "added" },
})

-- another editor buffer, without a server
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/notes.txt"))
vim.wait(2000, function()
  return #lines() == 1
end)
eq("a buffer without a server: the view says so", lines(), {
  "Symbols  [!] no language server with document symbols",
})
eq(
  "... and the bar marks it",
  { item_of(view, "symbols").available, item_of(view, "symbols").reason },
  {
    false,
    "no language server with document symbols",
  }
)
vim.cmd("buffer " .. mod_buf)
vim.wait(2000, function()
  return #lines() > 2
end)
eq("back in the file with a server its symbols are there again", lines()[2], "▾ M")

-- ── diagnostics ────────────────────────────────────────────────────────────────
vim.cmd("badd " .. vim.fn.fnameescape(dir .. "/notes.txt"))
local notes_buf = vim.fn.bufnr(dir .. "/notes.txt")
vim.fn.bufload(notes_buf)
local ns = vim.api.nvim_create_namespace("spec_diag")
vim.diagnostic.set(ns, mod_buf, {
  {
    lnum = 9,
    col = 0,
    severity = vim.diagnostic.severity.WARN,
    message = "unused",
    source = "spec",
  },
  { lnum = 3, col = 4, severity = vim.diagnostic.severity.ERROR, message = "broken" },
})
vim.diagnostic.set(ns, notes_buf, {
  { lnum = 0, col = 0, severity = vim.diagnostic.severity.HINT, message = "typo" },
})
view:show("diagnostics")
settle()
eq("by folder and file, the worst first; folders and files open", lines(), {
  "▾ Diagnostics",
  "▾ lua/",
  "▾ mod.lua",
  "broken",
  "unused",
  "▾ ./",
  "▾ notes.txt",
  "typo",
})
eq("the bar counts the diagnostics", item_of(view, "diagnostics").count, 3)
eq("the head adds up the worst", view.tree:agg("diagnostics:root").status, "error")
goto_id(view, "diagnostics:file:" .. dir .. "/lua/mod.lua")
eq("a file with diagnostics below it is still a file for the features", {
  adapter.get_current_node().path,
  adapter.get_current_node().type,
}, { dir .. "/lua/mod.lua", "file" })
goto_id(view, "diagnostics:dir:" .. dir .. "/lua")
eq("its folder is a folder", { adapter.get_current_node().path, adapter.get_current_node().type }, {
  dir .. "/lua",
  "directory",
})
local broken = ("diagnostics:%s/lua/mod.lua:3:4:1"):format(dir)
goto_id(view, broken)
eq("a diagnostic is no file", adapter.get_current_node(), nil)
ok(
  "... and its name has the color of its severity",
  (function()
    local view_mod = require("filetree.native.view")
    local got = false
    local real = vim.api.nvim_buf_set_extmark
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_buf_set_extmark = function(_, _, _, _, opts)
      if opts.hl_group == "DiagnosticError" then got = true end
      return 0
    end
    view_mod.decorate_line(view.buf, view.tree:row_of(broken) - 1, view.win)
    vim.api.nvim_buf_set_extmark = real
    return got
  end)()
)
feed("<CR>")
eq("<CR> on a diagnostic goes to its place", {
  vim.api.nvim_get_current_win(),
  vim.api.nvim_get_current_buf(),
  vim.api.nvim_win_get_cursor(0),
}, { editor_win, mod_buf, { 4, 4 } })

vim.diagnostic.set(ns, mod_buf, {})
vim.wait(2000, function()
  return #lines() == 4
end)
eq("diagnostics that go are gone from the view, without a key", lines(), {
  "▾ Diagnostics",
  "▾ ./",
  "▾ notes.txt",
  "typo",
})
vim.diagnostic.reset(ns)
vim.wait(2000, function()
  return #lines() == 2
end)
eq("none left: one line", lines(), { "▾ Diagnostics", "no diagnostics" })

view:show("files")
eq("nothing at warning level in the whole run", loud(), {})
pcall(function()
  vim.lsp.get_client_by_id(client_id):stop()
end)
vim.notify = real_notify
native.reset()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_source_lsp_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
