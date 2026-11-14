-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_bar_spec.lua -- the view bar of the own tree (stage E5): the winbar string for a list of
-- views (pure: counts, `[!]`, cutting to the width), and in a real tree window: the views of
-- `native.views`, `"` and `!`, a count that follows the statuses of a source, a source that cannot
-- load, a click, a narrow window, a file that takes the tree's place, and the bar switched off.
--
--   nvim --clean --headless -u NONE -l TESTS/native_bar_spec.lua

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

-- ── the bar, pure ──────────────────────────────────────────────────────────────
local bar = require("filetree.native.bar")
local function item(name, extra)
  return vim.tbl_extend("force", {
    name = name,
    title = name:sub(1, 1):upper() .. name:sub(2),
    current = false,
    available = true,
  }, extra or {})
end
local five = {
  item("files", { current = true }),
  item("buffers"),
  item("git", { count = 3 }),
  item("symbols", { available = false, reason = "no LSP client" }),
  item("diagnostics", { count = 0 }),
}
local function plain(items, width)
  return select(2, bar.render(items, width))
end
eq(
  "every view by its title, a count where there is one, [!] where a source cannot load",
  plain(five, 80),
  " Files  Buffers  Git 3  Symbols [!]  Diagnostics "
)
eq(
  "too wide: the views that are not on screen are cut to three characters",
  plain(five, 34),
  " Files  Buf  Git 3  Sym [!]  Dia "
)
eq("... then to one", plain(five, 26), " Files  B  G 3  S [!]  D ")
five[1].current, five[3].current = false, true
eq("the view on screen keeps its title", plain(five, 34), " Fil  Buf  Git 3  Sym [!]  Dia ")
eq(
  "one view is nothing to switch between: no bar",
  { bar.render({ item("files") }, 80) },
  { "", "" }
)
local line = bar.render({ item("files", { current = true }), item("a%b") }, 80)
ok(
  "each tab is a click region with its position",
  line:find("%2@v:lua.__filetree_bar_click@", 1, true)
)
ok("the view on screen has its own highlight", line:find("%#FiletreeBarCurrent# Files", 1, true))
ok("a percent sign in a title is escaped", line:find(" A%%b", 1, true))

-- ── fixture ────────────────────────────────────────────────────────────────────
local list = require("filetree.native.fs.list")
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_bar_%d"):format(base, vim.uv.hrtime() % 1e9)
vim.fn.mkdir(dir .. "/lua", "p")
vim.fn.writefile({ "x" }, dir .. "/lua/a.lua")
vim.fn.writefile({ "x" }, dir .. "/README.md")
vim.cmd("cd " .. vim.fn.fnameescape(dir))
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))

local registry = require("lib.nvim.tree.registry")
local checks = { emit = nil, available = true }
local checks_source = {
  name = "checks",
  title = "Checks",
  root = function()
    return {
      id = "checks:root",
      label = "Checks",
      children = {
        { id = "checks:a", label = "a", status = "failed" },
        { id = "checks:b", label = "b", status = "passed" },
        { id = "checks:c", label = "c" },
      },
    }
  end,
  subscribe = function(_, emit)
    checks.emit = emit
    return function()
      checks.emit = nil
    end
  end,
}
local remove_checks = registry.source(checks_source)
local remove_gone = registry.source({
  name = "gone",
  root = function()
    return { id = "gone:root", label = "Gone" }
  end,
  available = function()
    if checks.available then return true end
    return false, "not today"
  end,
})

local filetree = require("filetree")
ok(
  "setup with adapter = native",
  pcall(filetree.setup, {
    adapter = "native",
    deps_popup = false,
    native = { width = 60, watch = false, views = { { "files" }, { "checks" }, { "gone" } } },
    features = {
      session = { enabled = false },
      auto_reveal = { enabled = false },
      close_on_open = { enabled = false },
    },
  })
)
local adapter = filetree.adapter()
local native = require("filetree.native")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function settle(ms)
  vim.wait(ms or 80, function()
    return false
  end)
end
---What the bar of the tree window says, without the highlight and click items.
local function shown(view)
  local text = vim.wo[view.win].winbar
  return (text:gsub("%%%d*@[^@]*@", ""):gsub("%%#[^#]*#", ""):gsub("%%X", ""):gsub("%%%%", "%%"))
end

adapter.toggle_at("left", { dir = dir })
settle(150)
local view = native.current()
local win = view.win

-- ── the bar in the tree window ─────────────────────────────────────────────────
eq("the bar lists the views of native.views", shown(view), " Files  Checks  Gone ")
ok(
  "the files are the view on screen",
  vim.wo[win].winbar:find("%#FiletreeBarCurrent# Files", 1, true)
)
eq("a view that was never shown has no count", bar.items(view)[2].count, nil)
eq("the bar belongs to the tree buffer in its window, not to the window", {
  vim.wo[win][0].winbar ~= "",
  vim.api.nvim_get_option_value("winbar", { scope = "global" }),
}, { true, "" })

vim.api.nvim_set_current_win(win)
feed('"')
settle()
eq('" shows the next view', view.view_name, "checks")
eq("its count is the nodes that carry a status", shown(view), " Files  Checks 2  Gone ")
ok(
  "... and it is the one set off now",
  vim.wo[win].winbar:find("%#FiletreeBarCurrent# Checks", 1, true)
)
eq("the window is the same and as wide", { view.win, vim.api.nvim_win_get_width(win) }, { win, 60 })

checks.emit.push({ id = "checks:c", status = "failed" })
settle()
eq("a status that changes changes the count, without a key", shown(view), " Files  Checks 3  Gone ")

feed('"')
settle()
eq('" again: the third view', view.view_name, "gone")
feed('"')
settle()
eq("... and around to the first", view.view_name, "files")
eq("the count of a view that was shown stays in the bar", shown(view), " Files  Checks 3  Gone ")
feed("!")
settle()
eq("! shows the previous view, wrapping", view.view_name, "gone")

-- a source that cannot load right now
checks.available = false
view:show("files")
settle()
eq("a view whose source cannot load is marked", shown(view), " Files  Checks 3  Gone [!] ")
ok("... and dimmed", vim.wo[win].winbar:find("%#FiletreeBarDim# Gone [!]", 1, true))
eq("its reason is in the items", bar.items(view)[3].reason, "not today")
feed("!")
settle()
eq("cycling passes it over", view.view_name, "checks")
settle()
eq("a view shown again shows what its source says now", shown(view), " Files  Checks 2  Gone [!] ")

-- a click
local real_mousepos = vim.fn.getmousepos
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.getmousepos = function()
  return { winid = win }
end
_G.__filetree_bar_click(3, 1, "l")
settle()
eq("a click on a tab shows that view, a view that cannot load too", view.view_name, "gone")
eq("... which says why on its one line", vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), {
  "  Gone  [!] not today",
})
_G.__filetree_bar_click(1, 1, "r")
eq("another mouse button does nothing", view.view_name, "gone")
_G.__filetree_bar_click(1, 1, "l")
settle()
eq("a click on the first tab: the files", view.view_name, "files")
vim.fn.getmousepos = real_mousepos
checks.available = true

-- the feature source_switcher drives the views of the own tree
local switcher = filetree.feature("source_switcher")
eq("its sources are the views", switcher.sources(), { "files", "checks", "gone" })
eq("its current one is the view on screen", switcher.current(), "files")
eq("it says where the list comes from", switcher.info().source_list_from, "native.views")
eq("switch() shows a view", { switcher.switch("checks"), view.view_name }, { true, "checks" })
eq("... and refuses a name that is none", { switcher.switch("nope") }, {
  false,
  'unknown source "nope" (known: files, checks, gone)',
})
checks.available = false
eq("it knows which view cannot load", { switcher.loadable("gone") }, { false, "not today" })
checks.available = true
eq("loadable again", { switcher.loadable("gone") }, { true })
vim.cmd("Filetree source files")
eq(":Filetree source <name> shows a view", view.view_name, "files")
vim.cmd("Filetree source next")
eq(":Filetree source next cycles", view.view_name, "checks")
view:show("files")
eq("the views of the own tree have the icons of their neo-tree twins", {
  switcher.icon("git", { family = "common" }),
  switcher.icon("files", { family = "common" }),
  switcher.icon("symbols", { family = "common" }),
}, { "[GIT]", "[DIR]", "[SYM]" })

-- narrow
vim.api.nvim_win_set_width(win, 16)
vim.cmd("doautocmd WinResized")
bar.write(view)
eq("in a narrow window the other titles are cut", shown(view), " Files  C 2  G ")
vim.api.nvim_win_set_width(win, 60)

-- a file that takes the tree's place does not inherit the bar
view:close()
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
view:open("current")
settle()
local same_win = view.win
ok("a tree in an editor window has the bar", vim.wo[same_win][0].winbar ~= "")
vim.api.nvim_set_current_win(same_win)
adapter.open_file(dir .. "/lua/a.lua")
settle()
eq("a file opened in its place has none", {
  list.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(same_win))),
  vim.wo[same_win].winbar,
}, { dir .. "/lua/a.lua", "" })

-- switched off
native.reset()
native.setup({ view_bar = false, watch = false, views = { { "files" }, { "checks" } } })
adapter.toggle_at("left", { dir = dir })
settle(150)
view = native.current()
eq("native.view_bar = false: no bar", vim.wo[view.win].winbar, "")
vim.api.nvim_set_current_win(view.win)
feed('"')
eq("... the keys still switch", view.view_name, "checks")

-- ── :checkhealth names the views ───────────────────────────────────────────────
checks.available = false
local health_lines = {}
local real_health = vim.health
---@diagnostic disable-next-line: duplicate-set-field
vim.health = setmetatable({
  ok = function(msg)
    health_lines[#health_lines + 1] = "ok " .. msg
  end,
  info = function(msg)
    health_lines[#health_lines + 1] = "info " .. msg
  end,
}, { __index = real_health })
native.setup({ watch = false, views = { { "files" }, { "checks" }, { "gone" } } })
require("filetree.health")._native_lines()
vim.health = real_health
checks.available = true
eq(
  "the health check lists the views, and the one that cannot load with its reason",
  vim.tbl_filter(function(entry)
    return entry:find("view", 1, true) ~= nil or entry:find("cannot load", 1, true) ~= nil
  end, health_lines),
  {
    "ok native: 3 view(s): files, checks, gone",
    "info native: cannot load right now: gone (not today)",
  }
)

-- ── a real click ───────────────────────────────────────────────────────────────
-- Without a UI the editor draws no winbar and knows no click regions (the clicks above call the
-- handler). A child editor with a UI attached is clicked on for real: this is what proves the
-- `%N@v:lua...@` items of the bar.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--clean", "-u", "NONE", "-n", "-i", "NONE" },
  { rpc = true }
)
local function in_child(code)
  return vim.rpcrequest(child, "nvim_exec_lua", code, {})
end
vim.rpcrequest(child, "nvim_ui_attach", 100, 30, { rgb = true })
vim.rpcrequest(child, "nvim_set_option_value", "runtimepath", vim.o.runtimepath, {})
ok(
  "a child editor with a UI shows a tree with two views",
  in_child(([[
    vim.g.have_nerd_font = false
    vim.o.mouse = "a"
    vim.cmd("cd " .. vim.fn.fnameescape(%q))
    vim.cmd("edit README.md")
    require("filetree").setup({
      adapter = "native",
      deps_popup = false,
      native = { watch = false, width = 40, views = { { "files" }, { "buffers" } } },
      features = {
        session = { enabled = false },
        auto_reveal = { enabled = false },
        close_on_open = { enabled = false },
      },
    })
    _G.view = require("filetree.native").ensure(%q)
    return _G.view:open("left", true)
  ]]):format(dir, dir))
)
---Click on a column of the bar of the child's tree window and answer the view it shows then.
local function click(col, want)
  local pos = in_child("vim.cmd('redraw'); return vim.fn.win_screenpos(_G.view.win)")
  for _, action in ipairs({ "press", "release" }) do
    vim.rpcrequest(child, "nvim_input_mouse", "left", action, "", 0, pos[1] - 1, pos[2] - 1 + col)
  end
  vim.wait(3000, function()
    return in_child("return _G.view.view_name") == want
  end, 30)
  return in_child("return _G.view.view_name")
end
vim.wait(3000, function()
  return in_child("return vim.wo[_G.view.win].winbar ~= ''")
end, 30)
-- the bar reads " Files  Buffers ": column 9 lies in the second tab, column 2 in the first
eq("a mouse click on the second tab shows that view", click(9, "buffers"), "buffers")
eq("... and one on the first tab the files again", click(2, "files"), "files")
vim.fn.jobstop(child)

eq("nothing at warning level in the whole run", loud(), {})
remove_checks()
remove_gone()
vim.notify = real_notify
native.reset()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_bar_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
