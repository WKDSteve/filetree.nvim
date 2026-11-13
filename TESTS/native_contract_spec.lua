-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_contract_spec.lua -- the contract of the own tree, without a window: the registry
-- re-export (`filetree.registry`, `require("filetree").source`, the `setup()` options), the pure line
-- renderer, the width share-out and the badge store with its folder roll-up. Also loads the example
-- source of docs/api.md, so the documented "under 40 lines" stays true and stays working.
--
--   nvim --clean --headless -u NONE -l TESTS/native_contract_spec.lua

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

local passed, failed = 0, 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end
local function ok(name, cond)
  eq(name, cond and true or false, true)
end

local function noop() end

-- ── registry: filetree is the name, lib.nvim holds the lists ───────────────────
local lib_registry = require("lib.nvim.tree.registry")
local registry = require("filetree.registry")
local filetree = require("filetree")
lib_registry.reset()

local function names(kind)
  return vim.tbl_map(function(entry)
    return entry.name
  end, registry.list(kind))
end

local src = {
  name = "demo",
  root = function()
    return { id = "demo:root", label = "demo" }
  end,
}
local remove = filetree.source(src)
ok("require('filetree').source registers", lib_registry.get("source", "demo") == src)
ok("filetree.registry.get reads the same list", registry.get("source", "demo") == src)
eq("the unregister function removes it", remove(), true)
eq("... from lib.nvim's list", lib_registry.get("source", "demo"), nil)

filetree.decorator({
  name = "deco",
  get = noop,
  subscribe = function()
    return noop
  end,
})
filetree.action({ name = "act", run = noop })
eq(
  "decorator and action land in their lists",
  { names("decorator"), names("action") },
  { { "deco" }, { "act" } }
)

local raised, msg = pcall(function()
  filetree.source({ name = "broken" })
end)
ok("an entry without root() is refused", not raised and tostring(msg):find("root%(%)") ~= nil)
ok(
  "the error names the caller, not the registry",
  tostring(msg):find("native_contract_spec", 1, true) ~= nil
)

local seen = {}
local stop = registry.subscribe(function(ev)
  seen[#seen + 1] = ev.kind .. ":" .. ev.name
end)
filetree.source({ name = "late", root = src.root })
eq("subscribe reports a later registration", seen, { "source:late" })
stop()

-- setup({ sources, decorators, actions }): registered, and replaced by the next setup()
lib_registry.reset()
local issues = registry.apply_setup({
  sources = { { name = "s1", root = src.root }, { name = "bad" } },
  actions = { { name = "a1", run = noop } },
})
eq(
  "apply_setup registers the valid entries",
  { names("source"), names("action") },
  { { "s1" }, { "a1" } }
)
ok(
  "... and reports the refused one by option and index",
  #issues == 1 and issues[1]:find("sources%[2%]") ~= nil
)
eq("a wrongly typed option is an issue", #registry.apply_setup({ sources = "nope" }), 1)
eq("... and the earlier setup's entries are gone", { names("source"), names("action") }, { {}, {} })
registry.apply_setup({ sources = { { name = "s2", root = src.root } } })
filetree.source({ name = "mine", root = src.root })
registry.apply_setup({})
eq("a setup() without the options removes only what setup() brought", names("source"), { "mine" })

-- the config layer lets the three options through
local config = require("filetree.config")
config.setup({ sources = { { name = "cfg", root = src.root } } })
eq("config: `sources` is a known option", config.issues(), {})
eq("config: the entry survives the merge", config.get().sources[1].name, "cfg")
ok("config: ... with its function", type(config.get().sources[1].root) == "function")

-- ── the example of docs/api.md loads and stays under 40 lines ──────────────────
lib_registry.reset()
local api = table.concat(vim.fn.readfile(root .. "/docs/api.md"), "\n")
local example = api:match("<!%-%- example:source %-%->\n```lua\n(.-)\n```")
ok("docs/api.md carries the marked example source", example ~= nil)
local example_lines = #vim.split(example or "", "\n", { plain = true })
ok("the example has under 40 lines (" .. example_lines .. ")", example_lines < 40)
local chunk, load_err = loadstring(example or "error('no example')", "docs/api.md example")
ok("the example compiles: " .. tostring(load_err), chunk ~= nil)
local ran, run_err = pcall(chunk)
ok("the example runs: " .. tostring(run_err), ran)
local todo = registry.get("source", "todo")
ok("the example registered its source", todo ~= nil)
local todo_root = todo.root({ root = root, cwd = root, win = 0, view = "todo" })
local groups
todo_root.children(todo_root, function(list)
  groups = list
end)
ok("its root answers groups", type(groups) == "table" and #groups == 2)
local items
groups[1].children(groups[1], function(list)
  items = list
end)
ok("a leaf of it carries a path", type(items[1].path) == "string")
eq("it brought one action of its own", todo.actions[1].needs, { "kind:todo" })

-- ── render.line: text and spans of one row ─────────────────────────────────────
local line = require("filetree.native.render.line")
local tree = require("lib.nvim.tree")

local t = tree.new({
  root = {
    id = "r",
    label = "r",
    children = {
      {
        id = "/p/lua",
        label = "lua",
        path = "/p/lua",
        children = {
          { id = "/p/lua/a.lua", label = "a.lua", path = "/p/lua/a.lua" },
          { id = "/p/lua/ä.lua", label = "ä.lua", path = "/p/lua/ä.lua" },
        },
      },
      {
        id = "/p/x/y/z",
        label = "x/y/z",
        path = "/p/x/y/z",
        kind = "dir",
        data = { chain = { "/p/x", "/p/x/y", "/p/x/y/z" } },
        children = function(_, cb)
          cb({})
        end,
      },
      { id = "/p/README.md", label = "README.md", path = "/p/README.md" },
    },
  },
  hide_root = true,
})
t:expand("/p/lua")

local plain = { expander = { open = "v", closed = ">", loading = "~", none = " " } }
local function text_of(i, opts)
  return line.render(t:row(i), opts or plain).text
end
eq("open folder", text_of(1), "v lua")
eq("child is indented by its depth", text_of(2), "    a.lua")
eq("merged folder line", text_of(4), "> x/y/z")
eq("leaf at depth 0", text_of(5), "  README.md")
eq("trailing slash on a folder only", {
  text_of(1, { expander = plain.expander, trailing_slash = true }),
  text_of(5, { expander = plain.expander, trailing_slash = true }),
}, { "v lua/", "  README.md" })
eq("indent width", text_of(2, { expander = plain.expander, indent = 4 }), "      a.lua")
eq("guides instead of blanks", text_of(2, { expander = plain.expander, guide = "|" }), "|   a.lua")

local with_icon = line.render(t:row(2), {
  expander = plain.expander,
  icon = function(row)
    return row.expandable and "D" or "F", "IconHl"
  end,
})
eq("icon between expander and name", with_icon.text, "    F a.lua")
eq(
  "name_start / name_end are byte columns of the name",
  with_icon.text:sub(with_icon.name_start + 1, with_icon.name_end),
  "a.lua"
)
local icon_span
for _, span in ipairs(with_icon.spans) do
  if span.hl == "IconHl" then icon_span = span end
end
eq("the icon has its own span", with_icon.text:sub(icon_span.col_start + 1, icon_span.col_end), "F")

local umlaut = line.render(t:row(3), plain)
eq("a multibyte name: name_end counts bytes", umlaut.name_end - umlaut.name_start, #"ä.lua")

local merged = line.render(t:row(4), plain)
local by_id = {}
for _, span in ipairs(merged.spans) do
  if span.id then by_id[span.id] = merged.text:sub(span.col_start + 1, span.col_end) end
end
eq(
  "each folder of a merged line has a span with its id",
  by_id,
  { ["/p/x"] = "x", ["/p/x/y"] = "y", ["/p/x/y/z"] = "z" }
)
ok("a folder name uses the directory group", merged.spans[#merged.spans].hl == "FiletreeDirectory")
eq("a file name uses the name group", line.render(t:row(5), plain).spans[2].hl, "FiletreeName")
eq("a chain that does not match the label is ignored", #line.render({
  id = "q",
  depth = 0,
  expandable = true,
  expanded = false,
  loading = false,
  agg = {},
  node = { id = "q", label = "a/b", data = { chain = { "only-one" } } },
}, plain).spans, 2)
eq(
  "a loading row shows the loading glyph",
  line.render({
    id = "q",
    depth = 0,
    expandable = true,
    expanded = true,
    loading = true,
    agg = {},
    node = { id = "q", label = "q" },
  }, plain).text,
  "~ q"
)
eq(
  "control characters in a name never reach the buffer line",
  line.render({
    id = "q",
    depth = 0,
    expandable = false,
    expanded = false,
    loading = false,
    agg = {},
    node = { id = "q", label = "a\nb\tc\r" },
  }, plain).text,
  "  a?b?c?"
)
eq("default glyphs", line.render(t:row(1)).text, "▾ lua")

-- ── render.columns: who keeps room when the window is narrow ───────────────────
local columns = require("filetree.native.render.columns")
local right_items = {
  { text = "M", width = 1, slot = "badge", priority = 10 },
  { text = "E2", width = 2, slot = "badge", priority = 5 },
  { text = "4.1K", width = 4, slot = "column", priority = 20 },
  { text = "Nov 3", width = 5, slot = "column", priority = 1 },
}
local function kept(layout)
  return vim.tbl_map(function(item)
    return item.text
  end, layout.items)
end
local wide = columns.layout(60, 20, right_items)
eq(
  "wide: everything fits",
  { kept(wide), wide.dropped, wide.name_width },
  { { "M", "E2", "4.1K", "Nov 3" }, 0, 20 }
)
local l1 = columns.layout(26, 20, right_items) -- 26 - 16 = 10 < 12: one has to go
eq("narrow: the column with the lowest priority goes first", kept(l1), { "M", "E2", "4.1K" })
local l2 = columns.layout(20, 20, right_items)
eq("narrower: both columns go before any badge", kept(l2), { "M", "E2" })
local l3 = columns.layout(14, 20, right_items)
eq("then the badge with the lower priority", kept(l3), { "M" })
local l4 = columns.layout(8, 20, right_items)
eq(
  "at the end only the name is left, cut to the width",
  { kept(l4), l4.name_width, l4.dropped },
  { {}, 8, 4 }
)
eq("a short name frees its room", columns.layout(20, 4, right_items).name_width, 4)
eq(
  "min_name = 0 never drops for the name's sake",
  columns.layout(16, 20, right_items, { min_name = 0 }).dropped,
  0
)
eq("no items: the name gets the line", columns.layout(10, 20, {}).name_width, 10)

local strwidth = vim.fn.strdisplaywidth
eq("truncate: fits", { columns.truncate("init.lua", 8, strwidth) }, { "init.lua", false })
eq(
  "truncate: cut with an ellipsis",
  { columns.truncate("init.lua", 5, strwidth) },
  { "init…", true }
)
eq(
  "truncate: multibyte characters stay whole",
  { columns.truncate("äöüäöü", 4, strwidth) },
  { "äöü…", true }
)
eq(
  "truncate: a double-width character counts two",
  { columns.truncate("日本語の", 5, strwidth) },
  { "日本…", true }
)
eq("truncate: width 1", { columns.truncate("abc", 1, strwidth) }, { "…", true })
eq("truncate: narrower than the ellipsis", {
  columns.truncate("abc", 1, function(s)
    return s == "…" and 2 or #s
  end),
}, { "", true })
eq("truncate: a byte that is no valid UTF-8 is kept, not dropped", {
  columns.truncate("a\255bcdef", 4, function(s)
    return s == "…" and 1 or #s
  end),
}, { "a\255b…", true })
eq("truncate: width 0", { columns.truncate("abc", 0, strwidth) }, { "", true })

-- ── decor.store: badges by path, folders add up what lies below ────────────────
local store = require("filetree.native.decor.store")
local s = store.new({ severity = { "conflict", "modified", "added" }, root = "/p" })

eq(
  "set answers the path and its folders up to the root",
  s:set("/p/lua/a.lua", { text = "M", status = "modified" }),
  { "/p", "/p/lua", "/p/lua/a.lua" }
)
s:set("/p/lua/deep/b.lua", { text = "A", status = "added" })
s:set("/p/docs/x.md", { text = "M", status = "modified" })
eq("get: the badge of the path itself", s:get("/p/lua/a.lua").text, "M")
eq("get: a folder has no badge of its own", s:get("/p/lua"), nil)
eq(
  "rollup of a folder never opened",
  s:rollup("/p/lua"),
  { status = "modified", counts = { modified = 1, added = 1 }, total = 2 }
)
eq("rollup of the root", s:rollup("/p").total, 3)
eq("rollup: worst by the severity list", s:rollup("/p/lua/deep").status, "added")
eq("rollup: nothing below", s:rollup("/p/empty"), nil)
eq("counting stops at the root", s:rollup("/"), nil)

eq("the same badge again changes nothing", s:set("/p/docs/x.md", s:get("/p/docs/x.md")), {})
eq(
  "a new text with the same status changes only the path",
  s:set("/p/docs/x.md", { text = "m", status = "modified" }),
  { "/p/docs/x.md" }
)
eq(
  "a new status changes the folders too",
  s:set("/p/docs/x.md", { text = "C", status = "conflict" }),
  { "/p", "/p/docs", "/p/docs/x.md" }
)
eq("... and wins the roll-up", s:rollup("/p").status, "conflict")
eq("removing a badge", s:set("/p/docs/x.md", nil), { "/p", "/p/docs", "/p/docs/x.md" })
eq("... empties its folder", s:rollup("/p/docs"), nil)
eq("... and the root counts one less", s:rollup("/p").total, 2)

eq(
  "a badge without a status is kept but not counted",
  { s:set("/p/note.txt", { text = "*" }), s:rollup("/p").total },
  { { "/p/note.txt" }, 2 }
)

local changed = s:replace({
  ["/p/lua/a.lua"] = { text = "M", status = "modified" }, -- same content, new table
  ["/p/new.lua"] = { text = "A", status = "added" },
})
eq(
  "replace: only what differs is reported",
  changed,
  { "/p", "/p/lua", "/p/lua/deep", "/p/lua/deep/b.lua", "/p/new.lua", "/p/note.txt" }
)
eq("replace: the store holds exactly the new map", s:size(), 2)
eq(
  "replace: roll-ups follow",
  s:rollup("/p"),
  { status = "modified", counts = { modified = 1, added = 1 }, total = 2 }
)
eq(
  "replace with the same map reports nothing",
  s:replace({
    ["/p/lua/a.lua"] = { text = "M", status = "modified" },
    ["/p/new.lua"] = { text = "A", status = "added" },
  }),
  {}
)
eq(
  "replace with nothing clears every count",
  { #s:replace({}), s:rollup("/p"), s:size() },
  { 4, nil, 0 }
)

-- without a root the count climbs to the top of the path, on both path shapes
local free = store.new()
free:set("C:/repos/x/a.lua", { status = "s" })
free:set("/home/u/a.lua", { status = "s" })
eq("a drive is the last folder counted", free:rollup("C:").total, 1)
eq("/ is the last folder counted", free:rollup("/").total, 1)
local unranked = store.new({ severity = { "known" } })
unranked:set("/a/x", { status = "zeta" })
unranked:set("/a/y", { status = "alpha" })
eq("unranked statuses: the first by name", unranked:rollup("/a").status, "alpha")
unranked:set("/a/z", { status = "known" })
eq("a ranked status beats an unranked one", unranked:rollup("/a").status, "known")

-- 10 000 paths: a roll-up is a lookup, a single change stays cheap
local big = store.new({ severity = { "modified" }, root = "/big" })
local map = {}
for i = 1, 10000 do
  map[("/big/d%d/e%d/f%d.lua"):format(i % 20, i % 300, i)] = { text = "M", status = "modified" }
end
big:replace(map)
eq("10k paths: the root counts them all", big:rollup("/big").total, 10000)
local t0 = vim.uv.hrtime()
for i = 1, 1000 do
  big:set(("/big/d%d/e%d/f%d.lua"):format(i % 20, i % 300, i), nil)
end
local per_change_ms = (vim.uv.hrtime() - t0) / 1e6 / 1000
ok(("10k paths: one change under 0.5 ms (%.4f ms)"):format(per_change_ms), per_change_ms < 0.5)
eq("... and the counts follow", big:rollup("/big").total, 9000)

-- pure: the render and store modules touch no window or buffer
for _, mod in ipairs({
  "native/render/line.lua",
  "native/render/columns.lua",
  "native/decor/store.lua",
}) do
  local source = table.concat(vim.fn.readfile(root .. "/lua/filetree/" .. mod), "\n")
  ok(
    mod .. " calls no vim.api / vim.fn / vim.cmd",
    not (source:find("vim%.api") or source:find("vim%.fn%.") or source:find("vim%.cmd"))
  )
end

lib_registry.reset()
print(("\nfiletree.nvim native_contract_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
