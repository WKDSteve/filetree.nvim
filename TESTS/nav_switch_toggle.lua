-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- nav_switch_toggle.lua — headless tests for the two features that came out
-- of a host's neo-tree config: `source_switcher` (pick / cycle / display
-- names for neo-tree's sources) and `tree_toggle` (position-aware global
-- toggle keys), plus the neo-tree adapter's E95 self-heal in `toggle_at` and
-- the bookkeeping of its `renderer.redraw` hook install and `on_render`'s late
-- install for a lazily-loaded neo-tree.
--
-- neo-tree itself is stubbed at `neo-tree` / `neo-tree.command`, so what is
-- asserted is what the features hand neo-tree and how they react to what it
-- answers -- never neo-tree's own behaviour.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/nav_switch_toggle.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root_dir = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root_dir)
local lib_candidates = {}
for _, env in ipairs({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" then lib_candidates[#lib_candidates + 1] = v end
end
lib_candidates[#lib_candidates + 1] = vim.fn.fnamemodify(root_dir, ":h") .. "/lib.nvim"
lib_candidates[#lib_candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"
for _, candidate in ipairs(lib_candidates) do
  if vim.fn.isdirectory(candidate .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(candidate)
    break
  end
end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  — " .. detail) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

-- ── The neo-tree stub ─────────────────────────────────────────────────────────

---@type table[]  every `execute` call, in order
local executed = {}
---@type string|nil  error to raise on the next `execute`, once
local fail_next = nil
local stub_neotree = { config = { sources = { "filesystem", "buffers", "git_status" } } }
local stub_command = {
  execute = function(opts)
    executed[#executed + 1] = vim.deepcopy(opts)
    if fail_next then
      local err = fail_next
      fail_next = nil
      error(err)
    end
  end,
}
package.preload["neo-tree"] = function()
  return stub_neotree
end
package.preload["neo-tree.command"] = function()
  return stub_command
end
package.loaded["neo-tree"] = stub_neotree
package.loaded["neo-tree.command"] = stub_command

local function last()
  return executed[#executed]
end

-- ── source_switcher: the pure half ────────────────────────────────────────────

local sw = require("filetree.features.nav.source_switcher")
do
  -- No declared Nerd Font (this headless suite never sets
  -- vim.g.have_nerd_font) and no explicit `family`: the default resolves to
  -- "common" -- real ASCII-bracket icons, not the empty string a hardcoded
  -- "nerd" default would produce without a font to render it.
  local had_nerd_font_global = vim.g.have_nerd_font
  vim.g.have_nerd_font = nil
  eq(
    "display_name: undeclared font defaults to common",
    sw.display_name("buffers"),
    " [BUF] Buffers"
  )
  eq("icon: undeclared font defaults to common", sw.icon("filesystem"), "[DIR]")

  -- Explicit family = "nerd" always renders real glyphs (non-empty, exactly
  -- one display cell) regardless of vim.g.have_nerd_font -- an explicit
  -- request is honoured, not silently downgraded.
  local nerd_icon = sw.icon("git_status", { family = "nerd" })
  check("icon: explicit nerd family is a real, non-empty glyph", nerd_icon ~= "", nerd_icon)
  eq("icon: explicit nerd family renders one display cell", vim.fn.strdisplaywidth(nerd_icon), 1)

  -- Declaring the font flips the *default* (no explicit family) over to nerd.
  vim.g.have_nerd_font = true
  local default_icon = sw.icon("git_status")
  eq(
    "icon: declared font defaults to nerd",
    default_icon,
    sw.icon("git_status", { family = "nerd" })
  )
  vim.g.have_nerd_font = had_nerd_font_global

  eq(
    "display_name: common short",
    sw.display_name("git_status", { family = "common", length = "short" }),
    " [GIT] GIT"
  )
  eq("display_name: unknown source falls back to its name", sw.display_name("foo"), " foo")
  eq(
    "display_name: netman module path maps to its icon key",
    sw.display_name("netman.ui.neo-tree", { family = "common" }),
    " [NET] Network"
  )
  eq(
    "display_name: unknown family falls back to the same resolution as unset",
    sw.display_name("tests", { family = "nope" }),
    sw.display_name("tests")
  )
  local list = sw.display_names({ "filesystem", "tests" }, { family = "common", variant = "v2" })
  eq("display_names: keeps order", list[2].source, "tests")
  eq("display_names: formats each", list[1].display_name, " [F] File System")
  eq("icon: glyph only", sw.icon("filesystem", { family = "common" }), "[DIR]")
end

-- ── source_switcher: with a stub adapter ──────────────────────────────────────

local stub_adapter = {
  name = "neotree",
  get_position = function()
    return "right"
  end,
  toggle_at = function() end,
}
do
  sw.setup({ enabled = true }, stub_adapter)
  local list = sw.sources()
  eq("sources come from neo-tree's config", #list, 3)
  eq("...in its order", list[3], "git_status")

  sw.setup({ enabled = true, sources = { "buffers", "filesystem" } }, stub_adapter)
  eq("a configured source list wins", #sw.sources(), 2)
  eq("...and is copied, not aliased", sw.sources()[1], "buffers")

  -- A list that names document_symbols, so its loadability -- not its
  -- membership -- is what the two checks below exercise.
  sw.setup(
    { enabled = true, sources = { "buffers", "filesystem", "document_symbols" } },
    stub_adapter
  )
  local ok, why = sw.loadable("document_symbols")
  check("document_symbols without an LSP client is not loadable", ok == false and why ~= nil, why)
  check("filesystem is always loadable", sw.loadable("filesystem"))

  executed = {}
  local ok_sw, err = sw.switch("filesystem")
  check("switch to a known source succeeds", ok_sw, err)
  eq("...asks neo-tree to show it", last().source, "filesystem")
  eq("...at the adapter's position when called outside a tree", last().position, "right")
  eq("...without a reveal", last().reveal, false)

  local ok_unknown, err_unknown = sw.switch("nope")
  check(
    "an unknown source is refused",
    ok_unknown == false and err_unknown:find("unknown source") ~= nil,
    err_unknown
  )
  local ok_ds, err_ds = sw.switch("document_symbols")
  check(
    "a source that cannot load is refused with the reason",
    ok_ds == false and err_ds:find("cannot show") ~= nil,
    err_ds
  )

  -- Cycling from outside a tree starts at filesystem.
  sw.setup({ enabled = true }, stub_adapter)
  executed = {}
  sw.next()
  eq("next from outside a tree: filesystem -> buffers", last().source, "buffers")
  executed = {}
  sw.prev()
  eq("prev from outside a tree wraps: filesystem -> git_status", last().source, "git_status")

  -- Inside a tree buffer: the window's own position is kept via "current".
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neo-tree"
  vim.b[buf].neo_tree_source = "buffers"
  vim.api.nvim_set_current_buf(buf)
  eq("current() reads the tree's source", sw.current(), "buffers")
  executed = {}
  sw.next()
  eq("next inside the tree: buffers -> git_status", last().source, "git_status")
  eq("...replacing the tree window in place", last().position, "current")
  vim.wait(50, function()
    return false
  end)
  local switched_focus = vim.api.nvim_get_current_buf() == buf and 1 or 0
  eq("...and focus stays in the tree window", switched_focus, 1)

  local info = sw.info()
  eq("info names where the list came from", info.source_list_from, "neo-tree")
  eq("info carries the loadability map", info.loadable.filesystem, "ok")

  -- A non-neo-tree adapter binds nothing and switches nothing.
  local other = { name = "nvimtree" }
  local ok_setup = pcall(sw.setup, { enabled = true }, other)
  check("setup on another adapter is a silent no-op", ok_setup)
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
end

-- ── source_switcher: the optional `tests` source ──────────────────────────────
-- neo-tree-tests-source.nvim ships no Lua module of its own name -- only
-- `neo-tree.sources.tests` (plus a neotest consumer). The availability check
-- used to `require("neo-tree-tests-source")`, which resolves nowhere, so the
-- switcher called the source "not installed" on every machine that had it.
-- The stand-in plugin below has the real one's layout: the source module and
-- nothing named after the plugin.
--
-- The check must also leave neotest alone: a host may load neotest only right
-- before the source first renders, and listing the sources is not rendering.
do
  -- A name unique to this process: two runs at once (two terminals, parallel
  -- agents) would otherwise delete and rewrite each other's stand-in plugin.
  local dir = (vim.fn.tempname() .. "-nt-tests-source-rtp"):gsub("\\", "/")
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir .. "/lua/neo-tree/sources/tests", "p")
  vim.fn.writefile({ 'return { name = "tests" }' }, dir .. "/lua/neo-tree/sources/tests/init.lua")

  local neotest_required = false
  package.preload["neotest"] = function()
    neotest_required = true
    return {}
  end
  local configured = stub_neotree.config.sources

  -- 1. the plugin is absent: refused with the reason, not offered by default
  sw.setup({ enabled = true, sources = { "filesystem", "tests" } }, stub_adapter)
  local ok_absent, why_absent = sw.loadable("tests")
  check(
    "tests source: not loadable while its plugin is absent",
    ok_absent == false and tostring(why_absent):find("not installed", 1, true) ~= nil,
    why_absent
  )
  executed = {}
  local ok_sw_absent, err_absent = sw.switch("tests")
  check(
    "tests source: ... and a switch to it is refused with that reason",
    ok_sw_absent == false and tostring(err_absent):find("not installed", 1, true) ~= nil,
    err_absent
  )
  eq("tests source: ... without asking neo-tree for anything", #executed, 0)

  sw.setup({ enabled = true }, stub_adapter)
  stub_neotree.config.sources = nil -- no configured list: the fallback decides
  check(
    "tests source: the fallback list leaves it out while absent",
    not vim.tbl_contains(sw.sources(), "tests"),
    table.concat(sw.sources(), ", ")
  )

  -- 2. the plugin is installed
  vim.opt.rtp:prepend(dir)
  check(
    "tests source: the fallback list offers it once installed",
    vim.tbl_contains(sw.sources(), "tests"),
    table.concat(sw.sources(), ", ")
  )
  local ok_present, why_present = sw.loadable("tests")
  check("tests source: loadable once installed", ok_present == true, why_present)
  eq("tests source: info reports it as ok", sw.info().loadable.tests, "ok")

  executed = {}
  local ok_sw, err_sw = sw.switch("tests")
  check("tests source: a switch to it succeeds", ok_sw, err_sw)
  eq("tests source: ... asking neo-tree to show it", last() and last().source, "tests")

  check("tests source: none of this required neotest", not neotest_required)
  eq("tests source: ... nor left it loaded", package.loaded["neotest"], nil)

  -- 3. only "module not found" means "not installed": a source module that is
  -- there but throws while loading is reported as exactly that.
  package.loaded["neo-tree.sources.tests"] = nil
  vim.fn.writefile(
    { 'error("boom from the source module")' },
    dir .. "/lua/neo-tree/sources/tests/init.lua"
  )
  local ok_throws, why_throws = sw.loadable("tests")
  eq("tests source: a module that throws is not loadable", ok_throws, false)
  check(
    "tests source: ... and the reason is the failure, not 'not installed'",
    tostring(why_throws):find("failed to load", 1, true) ~= nil
      and tostring(why_throws):find("boom from the source module", 1, true) ~= nil
      and tostring(why_throws):find("not installed", 1, true) == nil,
    why_throws
  )

  -- LuaJIT leaves a "loading" sentinel behind a throwing require, so only the
  -- FIRST probe sees the real error. The reason must survive the later probes
  -- (pick() probes every entry, then switch() probes again), not degrade to
  -- "loop or previous error loading module".
  local _, why_again = sw.loadable("tests")
  local _, why_third = sw.loadable("tests")
  for i, why in ipairs({ why_again, why_third }) do
    check(
      "tests source: probe #" .. (i + 1) .. " of a throwing module keeps the real reason",
      tostring(why):find("boom from the source module", 1, true) ~= nil
        and tostring(why):find("loop or previous error", 1, true) == nil,
      why
    )
  end
  sw.setup({ enabled = true, sources = { "filesystem", "tests" } }, stub_adapter)
  local ok_sw_throws, err_sw_throws = sw.switch("tests")
  check(
    "tests source: switch() after earlier probes carries the real reason",
    ok_sw_throws == false
      and tostring(err_sw_throws):find("boom from the source module", 1, true) ~= nil,
    err_sw_throws
  )
  sw.setup({ enabled = true }, stub_adapter)

  -- 3b. The source module is there but ITS OWN dependency is missing: a
  -- "module 'X' not found" for some other X is a load failure, not "not
  -- installed" -- and only its first line is reported (the rest is the whole
  -- search-path dump).
  package.loaded["neo-tree.sources.tests"] = nil
  vim.fn.writefile(
    { 'require("neotest-missing-dep")' },
    dir .. "/lua/neo-tree/sources/tests/init.lua"
  )
  local ok_dep, why_dep = sw.loadable("tests")
  eq("tests source: a missing dependency is not loadable", ok_dep, false)
  check(
    "tests source: ... and the reason is the failure, not 'not installed'",
    tostring(why_dep):find("failed to load", 1, true) ~= nil
      and tostring(why_dep):find("not installed", 1, true) == nil,
    why_dep
  )
  check("tests source: ... on one line", tostring(why_dep):find("\n", 1, true) == nil, why_dep)

  vim.fn.writefile({ 'return { name = "tests" }' }, dir .. "/lua/neo-tree/sources/tests/init.lua")
  package.loaded["neo-tree.sources.tests"] = nil
  check("tests source: a source that loads again is loadable again", (sw.loadable("tests")))
  package.loaded["neo-tree.sources.tests"] = nil

  -- 4. neo-tree itself comes first: probing a source module before neo-tree is
  -- up would make a lazy-loaded neo-tree run its own config() in the middle of
  -- the probe, and a require of that module from there hits a require loop.
  local loaded_nt, preload_nt = package.loaded["neo-tree"], package.preload["neo-tree"]
  package.loaded["neo-tree"], package.preload["neo-tree"] = nil, nil
  local ok_no_nt, why_no_nt = sw.loadable("tests")
  package.loaded["neo-tree"], package.preload["neo-tree"] = loaded_nt, preload_nt
  eq("tests source: not loadable without neo-tree", ok_no_nt, false)
  check(
    "tests source: ... and the reason names neo-tree",
    tostring(why_no_nt):find("neo-tree is not loaded", 1, true) ~= nil,
    why_no_nt
  )
  eq(
    "tests source: ... without having required the source module",
    package.loaded["neo-tree.sources.tests"],
    nil
  )

  -- 4b. A lazy-loaded neo-tree is only a LOADER until its first require (lazy.nvim
  -- is a package searcher, not an entry in package.loaded): the probe has to
  -- require it -- not peek at package.loaded -- and before the source module.
  local order = {}
  _G.__ft_order = order
  vim.fn.writefile(
    { 'table.insert(_G.__ft_order, "source") return { name = "tests" }' },
    dir .. "/lua/neo-tree/sources/tests/init.lua"
  )
  package.loaded["neo-tree"] = nil
  package.loaded["neo-tree.sources.tests"] = nil
  package.preload["neo-tree"] = function()
    order[#order + 1] = "neo-tree"
    return stub_neotree
  end
  local ok_lazy, why_lazy = sw.loadable("tests")
  package.loaded["neo-tree"], package.preload["neo-tree"] = loaded_nt, preload_nt
  vim.fn.writefile({ 'return { name = "tests" }' }, dir .. "/lua/neo-tree/sources/tests/init.lua")
  package.loaded["neo-tree.sources.tests"] = nil
  _G.__ft_order = nil
  check("tests source: a lazy-loaded neo-tree is loadable", ok_lazy == true, why_lazy)
  eq(
    "tests source: ... neo-tree was loaded before the source module",
    table.concat(order, ","),
    "neo-tree,source"
  )

  stub_neotree.config.sources = configured
  package.preload["neotest"] = nil
  package.loaded["neo-tree.sources.tests"] = nil
  vim.opt.rtp:remove(dir)
  vim.fn.delete(dir, "rf")
end

-- ── source_switcher: neo-tree merges its config lazily ────────────────────────
-- neo-tree v3 only stores what `setup()` was given; `config` stays nil until
-- the first command merges it. `peek_config()` is its cheap way to read a key
-- meanwhile. Without it the switcher offered its hard-coded fallback list (and
-- `switch()` handed neo-tree a source it does not know) until the first :Neotree.
do
  local saved_config, saved_peek = stub_neotree.config, stub_neotree.peek_config
  sw.setup({ enabled = true }, stub_adapter)

  stub_neotree.config = nil
  stub_neotree.peek_config = function()
    return { sources = { "filesystem", "git_status" } }
  end
  local list = sw.sources()
  eq("lazy config: the user's configured list is used before the first merge", #list, 2)
  eq("lazy config: ... in its order", list[2], "git_status")
  eq("lazy config: info names neo-tree as the origin", sw.info().source_list_from, "neo-tree")

  -- Already merged: peek_config hands the merged table back.
  stub_neotree.peek_config = function()
    return { sources = { "buffers" } }
  end
  eq("lazy config: a merged list is read the same way", sw.sources()[1], "buffers")

  -- A user config without a `sources` key: the fallback decides, as before.
  stub_neotree.peek_config = function()
    return {}
  end
  eq("lazy config: no `sources` key falls back to the built-ins", sw.sources()[1], "filesystem")
  eq("lazy config: ... and info says so", sw.info().source_list_from, "fallback")

  -- A peek_config that throws never takes the switcher down with it.
  stub_neotree.peek_config = function()
    error("neo-tree is mid-setup")
  end
  stub_neotree.config = { sources = { "filesystem", "buffers", "git_status" } }
  eq("lazy config: a throwing peek_config falls back to `config`", #sw.sources(), 3)

  stub_neotree.config, stub_neotree.peek_config = saved_config, saved_peek
end

-- ── tree_toggle ───────────────────────────────────────────────────────────────

local tt = require("filetree.features.nav.tree_toggle")
do
  local calls = {}
  local adapter = {
    name = "neotree",
    toggle_at = function(position, opts)
      calls[#calls + 1] = { position = position, opts = opts }
      return true
    end,
  }
  local file = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "x" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))

  tt.setup({ enabled = true }, adapter)
  local ok, err = tt.toggle("left")
  check("toggle left succeeds", ok, err)
  eq("...with the position", calls[1].position, "left")
  eq("...revealing the current file", calls[1].opts.file, vim.api.nvim_buf_get_name(0))
  check("...reveal on", calls[1].opts.reveal == true)
  check("...reveal_force_cwd on by default", calls[1].opts.reveal_force_cwd == true)

  tt.setup({ enabled = true, reveal = false }, adapter)
  tt.toggle("float")
  check(
    "reveal = false: no reveal, no file",
    calls[2].opts.reveal == false and calls[2].opts.file == nil
  )

  local ok_bad, err_bad = tt.toggle("bottom")
  check(
    "an unknown position is refused",
    ok_bad == false and err_bad:find("unknown position") ~= nil,
    err_bad
  )

  eq("the four global keys are bound", vim.fn.maparg("<M-l>", "n") ~= "", true)
  eq(
    "...all of them",
    vim.fn.maparg("<M-c>", "n") ~= ""
      and vim.fn.maparg("<M-f>", "n") ~= ""
      and vim.fn.maparg("<M-r>", "n") ~= "",
    true
  )

  tt.teardown()
  eq("teardown unbinds them", vim.fn.maparg("<M-l>", "n"), "")

  local no_toggle = { name = "netrw" }
  tt.setup({ enabled = true }, no_toggle)
  local ok_np, err_np = tt.toggle("left")
  check(
    "an adapter without toggle_at is refused",
    ok_np == false and err_np:find("cannot place") ~= nil,
    err_np
  )
  eq("...and binds nothing", vim.fn.maparg("<M-l>", "n"), "")

  tt.setup({ enabled = false }, adapter)
  eq("disabled: nothing bound", vim.fn.maparg("<M-l>", "n"), "")
  os.remove(file)
end

-- ── tree_toggle.use_root_providers ────────────────────────────────────────────

do
  local roots = require("filetree.roots")
  local case_dir = vim.fn.tempname()
  vim.fn.mkdir(case_dir .. "/assets", "p")
  local inside = case_dir .. "/assets/note.md"
  vim.fn.writefile({ "x" }, inside)
  local outside = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "x" }, outside)

  local is_open = false
  ---@type table[]
  local calls = {}
  local adapter = {
    name = "neotree",
    is_open = function()
      return is_open
    end,
    toggle_at = function(position, opts)
      calls[#calls + 1] = { position = position, opts = opts }
      return true
    end,
  }
  -- A casedesk-like provider: answers for files under `case_dir` only.
  roots.register("spec.case", function(path)
    if path:gsub("\\", "/"):find(case_dir:gsub("\\", "/"), 1, true) then return case_dir end
    return nil
  end)

  tt.setup({ enabled = true }, adapter)
  vim.cmd("edit " .. vim.fn.fnameescape(inside))
  tt.toggle("left")
  eq("inside a case: the provider's folder becomes the tree root", calls[1].opts.dir, case_dir)

  vim.cmd("edit " .. vim.fn.fnameescape(outside))
  tt.toggle("left")
  eq("outside a case: no dir, the old root", calls[2].opts.dir, nil)

  vim.cmd("edit " .. vim.fn.fnameescape(inside))
  is_open = true
  tt.toggle("left")
  eq("a toggle that closes the tree passes no dir", calls[3].opts.dir, nil)
  is_open = false

  tt.setup({ enabled = true, use_root_providers = false }, adapter)
  tt.toggle("left")
  eq("use_root_providers = false: no dir even inside a case", calls[4].opts.dir, nil)

  roots.unregister("spec.case")
  tt.setup({ enabled = true }, adapter)
  tt.toggle("left")
  eq("no provider registered: no dir", calls[5].opts.dir, nil)

  tt.teardown()
  os.remove(outside)
  vim.fn.delete(case_dir, "rf")
end

-- ── tree_toggle.collapse_on_toggle ────────────────────────────────────────────

do
  ---@type { keep: string|false }[]
  local collapses = {}
  local order = {}
  local is_open = false
  local adapter = {
    name = "neotree",
    is_open = function()
      return is_open
    end,
    collapse_all = function(keep)
      collapses[#collapses + 1] = { keep = keep or false }
      order[#order + 1] = "collapse"
      return true
    end,
    toggle_at = function()
      order[#order + 1] = "toggle"
      return true
    end,
  }
  local file = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "x" }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local current = vim.api.nvim_buf_get_name(0)

  tt.setup({ enabled = true }, adapter)
  tt.toggle("left")
  eq("collapse_on_toggle off by default: the state stays as it was", #collapses, 0)

  tt.setup({ enabled = true, collapse_on_toggle = true }, adapter)
  order = {}
  tt.toggle("left")
  eq("on: opening collapses once", #collapses, 1)
  eq("...keeping the current file's chain", collapses[1].keep, current)
  eq("...before the toggle reveals it", table.concat(order, ","), "collapse,toggle")

  is_open = true
  tt.toggle("left")
  eq("a toggle that closes the tree leaves its state alone", #collapses, 1)
  is_open = false

  vim.cmd("enew")
  tt.toggle("left")
  eq("a buffer without a file: collapsed too", #collapses, 2)
  eq("...keeping nothing", collapses[2].keep, false)

  vim.cmd("enew")
  vim.bo.buftype = "nofile"
  vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-scratch")
  tt.toggle("right")
  eq("a scratch buffer (buftype=nofile) keeps nothing", collapses[3].keep, false)

  -- A new file not written yet: its folder exists, so its chain is kept.
  local new_dir = vim.fn.tempname()
  vim.fn.mkdir(new_dir .. "/src", "p")
  vim.cmd("edit " .. vim.fn.fnameescape(new_dir .. "/src/new.lua"))
  local new_name = vim.api.nvim_buf_get_name(0)
  tt.toggle("left")
  eq("a new, unsaved file keeps its chain", collapses[4].keep, new_name)
  vim.fn.delete(new_dir, "rf")

  local flat = {
    name = "netrw",
    toggle_at = function()
      return true
    end,
  }
  tt.setup({ enabled = true, collapse_on_toggle = true }, flat)
  local ok_flat, err_flat = tt.toggle("left")
  check(
    "an adapter without collapse_all just toggles (not applicable, no error)",
    ok_flat,
    err_flat
  )

  tt.teardown()
  os.remove(file)
end

-- ── collapse_all: key, command, not applicable ───────────────────────────────

do
  local ca = require("filetree.features.nav.collapse_all")
  local keeps = {}
  local adapter = {
    name = "neotree",
    collapse_all = function(keep)
      keeps[#keeps + 1] = keep or false
      return true
    end,
  }
  ca.setup({ enabled = true }, adapter)
  local ok = ca.collapse()
  check("collapse_all collapses everything", ok and keeps[1] == false)

  ca.setup({ enabled = true }, { name = "oil" })
  local ok_none, why = ca.collapse()
  check(
    "an adapter without collapse_all is reported as not applicable",
    ok_none == false and why:find("^not applicable") ~= nil,
    why
  )

  for _, name in ipairs({ "oil", "netrw", "mini_files" }) do
    local flat_adapter = require("filetree.adapter." .. name)
    local ok_f, why_f = flat_adapter.collapse_all()
    check(
      ("the flat %s adapter says not applicable"):format(name),
      ok_f == false and type(why_f) == "string" and why_f:find("^not applicable") ~= nil,
      why_f
    )
  end
  ca.teardown()
end

-- ── neo-tree adapter: toggle_at and the E95 self-heal ─────────────────────────

do
  package.loaded["filetree.adapter.neotree"] = nil
  local nt = require("filetree.adapter.neotree")
  executed = {}
  check(
    "toggle_at succeeds against the stub",
    nt.toggle_at("left", { reveal = true, file = "/x.lua", reveal_force_cwd = true })
  )
  eq("...as a focus+toggle", last().action, "focus")
  check("...toggle set", last().toggle == true)
  eq("...reveal_file passed", last().reveal_file, "/x.lua")
  check("...reveal_force_cwd passed", last().reveal_force_cwd == true)

  executed = {}
  nt.toggle_at("left", { reveal = false, reveal_force_cwd = true })
  check("reveal_force_cwd needs reveal", last().reveal_force_cwd == false)

  -- A dead, never-rendered neo-tree window is what E95 leaves behind.
  local dead = vim.api.nvim_create_buf(false, true)
  vim.bo[dead].filetype = "neo-tree"
  vim.cmd("vsplit")
  local dead_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(dead_win, dead)
  vim.cmd("wincmd p")

  executed = {}
  fail_next = "Vim:E95: Buffer with this name already exists"
  local ok_heal = nt.toggle_at("left", {})
  check("first execute fails, the retry succeeds", ok_heal)
  eq("...two executes in total", #executed, 2)
  check(
    "...the unnamed neo-tree window was closed in between",
    not vim.api.nvim_win_is_valid(dead_win)
  )

  executed = {}
  fail_next = "Vim:E95: still"
  -- Both attempts fail: the second error is reported, false returned.
  local orig_exec = stub_command.execute
  stub_command.execute = function(opts)
    executed[#executed + 1] = opts
    error("Vim:E95: again")
  end
  local ok_twice = nt.toggle_at("left", {})
  stub_command.execute = orig_exec
  fail_next = nil
  check("both attempts failing returns false", ok_twice == false)
  eq("...after exactly one retry", #executed, 2)
end

-- ── redraw-hook install: a failed wrap must not read as "installed" ─────────
-- `install_redraw_hook` used to mark `renderer` as wrapped BEFORE it wrapped
-- anything. With `renderer.redraw` not (yet) a function the wrap failed, but
-- the mark stayed -- so the retry loop's next attempt saw "already wrapped",
-- reported success, and `on_render` subscribers were never notified.
do
  local renderer = { redraw = "not a function yet" }
  package.loaded["neo-tree.ui.renderer"] = renderer
  package.loaded["neo-tree.events"] = {
    AFTER_RENDER = "after_render",
    subscribe = function() end,
    unsubscribe = function() end,
  }
  package.loaded["filetree.adapter.neotree"] = nil
  local nt = require("filetree.adapter.neotree") -- load-time hoist attempts (and fails) the wrap

  eq("hook: a failed wrap leaves no 'wrapped' mark behind", renderer._filetree_notify_redraw, nil)

  local real_calls = 0
  renderer.redraw = function()
    real_calls = real_calls + 1
    return "result"
  end
  local seen = {}
  local unsubscribe = nt.on_render(function(bufnr)
    seen[#seen + 1] = bufnr == nil and "nil" or bufnr
  end)

  eq(
    "hook: once redraw is a function, the retry really wraps it",
    type(renderer.redraw),
    "function"
  )
  check("hook: ... marking the renderer only now", renderer._filetree_notify_redraw ~= nil)
  eq("hook: the wrapper forwards the original's result", renderer.redraw({}), "result")
  eq("hook: ... after running the original redraw", real_calls, 1)
  eq("hook: ... and notifies the subscriber (nil bufnr: no live window)", seen[1], "nil")

  -- A second install (hot reload, setup() re-run) repoints, never re-wraps.
  local wrapped = renderer.redraw
  package.loaded["filetree.adapter.neotree"] = nil
  local nt2 = require("filetree.adapter.neotree")
  local seen2 = 0
  nt2.on_render(function()
    seen2 = seen2 + 1
  end)
  eq("hook: a reloaded module does not stack a second wrapper", renderer.redraw, wrapped)
  renderer.redraw({})
  eq("hook: ... and the reloaded generation's subscribers fire", seen2, 1)
  eq("hook: ... exactly once per redraw", real_calls, 2)

  unsubscribe()
  package.loaded["neo-tree.ui.renderer"] = nil
  package.loaded["neo-tree.events"] = nil
  package.loaded["filetree.adapter.neotree"] = nil
end

-- ── on_render: a neo-tree that loads AFTER the retries ran out ──────────────
-- `on_render` retries the install in the background for a few seconds
-- (`M._retry`, shortened here). A lazy neo-tree.nvim first opened after that
-- used to leave the subscription dead for the rest of the session; it now
-- waits for the first `neo-tree` buffer (`FileType`) and installs then.
do
  local LATE_GROUP = "filetree_neotree_late_install"
  local function late_autocmds()
    local ok, found = pcall(vim.api.nvim_get_autocmds, { group = LATE_GROUP, event = "FileType" })
    return ok and #found or 0
  end
  local function neotree_absent()
    package.loaded["neo-tree.ui.renderer"] = nil
    package.loaded["neo-tree.events"] = nil
    package.preload["neo-tree.ui.renderer"] = nil
    package.preload["neo-tree.events"] = nil
  end
  local function neotree_arrives()
    local renderer = { redraw = function() end }
    package.loaded["neo-tree.events"] = {
      AFTER_RENDER = "after_render",
      subscribe = function() end,
      unsubscribe = function() end,
    }
    package.loaded["neo-tree.ui.renderer"] = renderer
    return renderer
  end
  local function tree_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "neo-tree"
    return buf
  end
  local function fresh_adapter()
    neotree_absent()
    package.loaded["filetree.adapter.neotree"] = nil
    local nt = require("filetree.adapter.neotree")
    nt._retry.limit, nt._retry.interval_ms = 2, 10
    return nt
  end

  -- 1. arrives late; a FileType that is too early leaves it armed
  local nt = fresh_adapter()
  local seen = {}
  nt.on_render(function(bufnr)
    seen[#seen + 1] = bufnr == nil and "nil" or bufnr
  end)
  vim.wait(300, function()
    return late_autocmds() > 0
  end, 10)
  eq("late: retries spent -> one FileType autocmd armed", late_autocmds(), 1)

  tree_buffer() -- neo-tree still not requirable: nothing installs
  vim.wait(100, function()
    return #seen > 0
  end, 10)
  eq("late: a FileType before neo-tree is requirable notifies nobody", #seen, 0)
  eq("late: ... and stays armed for the next one", late_autocmds(), 1)

  local renderer = neotree_arrives()
  local buf = tree_buffer()
  vim.wait(500, function()
    return #seen > 0
  end, 10)
  eq("late: the first tree buffer installs the hooks and notifies once", #seen, 1)
  eq("late: ... with that buffer", seen[1], buf)
  eq("late: ... the autocmd is gone afterwards", late_autocmds(), 0)
  check("late: renderer.redraw is wrapped for real", renderer._filetree_notify_redraw ~= nil)
  renderer.redraw({})
  eq("late: ... and the subscriber now gets redraw signals", #seen, 2)
  tree_buffer()
  vim.wait(60, function() end, 10)
  eq("late: further tree buffers do not re-notify", #seen, 2)

  -- 2. unsubscribing while still armed disarms it for good
  nt = fresh_adapter()
  local seen2 = 0
  local unsubscribe = nt.on_render(function()
    seen2 = seen2 + 1
  end)
  vim.wait(300, function()
    return late_autocmds() > 0
  end, 10)
  eq("late/unsubscribe: armed", late_autocmds(), 1)
  unsubscribe()
  eq("late/unsubscribe: the autocmd is deleted", late_autocmds(), 0)
  renderer = neotree_arrives()
  tree_buffer()
  vim.wait(100, function()
    return seen2 > 0
  end, 10)
  eq("late/unsubscribe: neo-tree arriving afterwards notifies nobody", seen2, 0)
  eq("late/unsubscribe: ... and nothing got wrapped for it", renderer._filetree_notify_redraw, nil)

  -- 3. the preload hoist must not poison a neo-tree that arrives later.
  -- LuaJIT parks a "loading" sentinel in package.loaded before it runs a
  -- loader and never clears it when the loader throws. The hoist's loader
  -- threw whenever neo-tree was not on the runtimepath yet -- which the
  -- install retries above trigger by requiring the renderer early -- so
  -- neo-tree's OWN later require died with "loop or previous error loading
  -- module" for the rest of the session.
  local dir = (vim.fn.tempname() .. "-nt-late-rtp"):gsub("\\", "/")
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir .. "/lua/neo-tree/ui", "p")
  vim.fn.writefile(
    { 'return { marker = "real renderer", redraw = function() return "real" end }' },
    dir .. "/lua/neo-tree/ui/renderer.lua"
  )
  vim.fn.writefile({ "return {}" }, dir .. "/lua/neo-tree/events.lua")

  fresh_adapter()
  check(
    "hoist: armed at load while neo-tree is absent",
    package.preload["neo-tree.ui.renderer"] ~= nil
  )
  local ok_early = pcall(require, "neo-tree.ui.renderer") -- what the install retries do
  eq("hoist: an early require fails like any missing module", ok_early, false)
  eq("hoist: ... leaving no loading sentinel behind", package.loaded["neo-tree.ui.renderer"], nil)
  check(
    "hoist: ... and re-armed for the real first load",
    package.preload["neo-tree.ui.renderer"] ~= nil
  )

  vim.opt.rtp:prepend(dir) -- neo-tree "gets lazy-loaded"
  local ok_real, real = pcall(require, "neo-tree.ui.renderer")
  check("hoist: neo-tree's own require then succeeds", ok_real, tostring(real))
  eq("hoist: ... returning the real module", ok_real and real.marker, "real renderer")
  check(
    "hoist: ... already wrapped (the hoist's whole point)",
    ok_real and real._filetree_notify_redraw ~= nil
  )
  eq("hoist: ... and the wrapper forwards to the real redraw", ok_real and real.redraw({}), "real")

  vim.opt.rtp:remove(dir)
  vim.fn.delete(dir, "rf")

  neotree_absent()
  package.loaded["filetree.adapter.neotree"] = nil
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
