-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_files_section_spec.lua -- the directory tree as one section of a view that also shows
-- other sources (`views = { { name = "work", "buffers", "files" } }`): folders open and close, the
-- watcher and a file operation are taken over, reveal, the open folders, sort and search act on the
-- section, and the files view next to it stays what it was.
--
--   nvim --clean --headless -u NONE -l TESTS/native_files_section_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_files_section_spec",
  setup = {
    native = { views = { { "files" }, { name = "work", "buffers", "files" }, { "buffers" } } },
  },
  features = { file_watcher = { enabled = false } },
  files = {
    "lua/mod/a.lua",
    "lua/mod/b.lua",
    "lua/init.lua",
    "docs/guide.md",
    "chain/only/leaf.lua",
    "README.md",
  },
})
local eq, ok, dir = T.eq, T.ok, T.dir
local adapter = T.adapter
local list = require("filetree.native.fs.list")
local watch = require("filetree.native.fs.watch")

T.tree()
local view = adapter.get_state()
local files_before = T.lines()

---The 1-based line of the first row whose text contains `needle`.
local function line_of(needle)
  for i, text in ipairs(T.lines()) do
    if text:find(needle, 1, true) then return i end
  end
  return nil
end
local function has(rel)
  return adapter.get_node_line(dir .. "/" .. rel) ~= nil
end

-- ── the view ───────────────────────────────────────────────────────────────────
eq("the view of sections is shown", { view:show("work") }, { true })
T.settle(200)
ok("no line says that the files cannot be a section", line_of("cannot be a section") == nil)
ok("the buffers are a section", line_of("Buffers") ~= nil)
local head = line_of(vim.fn.fnamemodify(dir, ":t"))
ok("the directory tree is a section below them", head ~= nil and head > line_of("Buffers"))
ok("its top level is listed", has("lua") and has("docs") and has("README.md"))
ok("a chain of single folders is one line", line_of("chain/only") ~= nil)
eq("the sources of the view", view:sources(), { "buffers", "files" })
eq("a node of the section belongs to the files", view:source_of(dir .. "/lua"), "files")
eq(
  "both sections could load",
  vim.tbl_map(function(section)
    return section.available
  end, view:sections()),
  { true, true }
)
eq("nothing at warning level so far", T.loud(), {})

-- ── folders ────────────────────────────────────────────────────────────────────
ok("a folder opens", adapter.expand_node({ path = dir .. "/lua" }))
T.wait(function()
  return has("lua/init.lua")
end)
ok("... and shows its entries", has("lua/init.lua") and has("lua/mod"))
adapter.expand_node({ path = dir .. "/lua/mod" })
T.wait(function()
  return has("lua/mod/a.lua")
end)
eq("the open folders are the ones of the section", adapter.get_expanded_paths(), {
  dir .. "/lua",
  dir .. "/lua/mod",
})
ok("a folder closes", adapter.collapse_node({ path = dir .. "/lua/mod" }))
ok("... its entries are gone", not has("lua/mod/a.lua"))
eq("... and it is no longer among the open ones", adapter.get_expanded_paths(), { dir .. "/lua" })

-- ── reveal ─────────────────────────────────────────────────────────────────────
ok("reveal of a file in a closed folder", view:reveal(dir .. "/lua/mod/b.lua"))
eq("... puts the cursor on it", (adapter.get_current_node() or {}).path, dir .. "/lua/mod/b.lua")
ok("reveal through a merged line", view:reveal(dir .. "/chain/only/leaf.lua"))
eq("... lands on the file", (adapter.get_current_node() or {}).path, dir .. "/chain/only/leaf.lua")
eq("reveal of a path that is not there", view:reveal(dir .. "/lua/nope.lua"), false)

-- ── expand_paths ───────────────────────────────────────────────────────────────
adapter.collapse_all()
T.settle(50)
ok("collapse_all leaves the section head", line_of(vim.fn.fnamemodify(dir, ":t")) ~= nil)
ok("... and closes the folders", not has("lua/init.lua"))
eq("expand_paths answers true", adapter.expand_paths({ dir .. "/lua/mod", dir .. "/lua" }), true)
ok("... and opens them, outermost first", has("lua/mod/a.lua"))

-- ── the disk ───────────────────────────────────────────────────────────────────
ok("the section holds a watcher handle while it is shown", watch.covers(dir))
T.mkfile("lua/mod/new_from_outside.lua")
ok(
  "a file made outside the editor appears",
  T.wait(function()
    return has("lua/mod/new_from_outside.lua")
  end, 4000)
)
vim.uv.fs_unlink(dir .. "/lua/mod/new_from_outside.lua")
ok(
  "... and disappears when it is deleted",
  T.wait(function()
    return not has("lua/mod/new_from_outside.lua")
  end, 4000)
)

-- a finished file operation, announced the way the features announce it
vim.uv.fs_rename(dir .. "/lua/mod/b.lua", dir .. "/lua/mod/renamed.lua")
require("filetree.util.changed").emit(
  "move",
  dir .. "/lua/mod/b.lua",
  dir .. "/lua/mod/renamed.lua"
)
ok(
  "an announced rename is taken over",
  T.wait(function()
    return has("lua/mod/renamed.lua") and not has("lua/mod/b.lua")
  end, 4000)
)
vim.fn.mkdir(dir .. "/lua/made/inner", "p")
vim.fn.writefile({ "x" }, dir .. "/lua/made/inner/deep.lua")
require("filetree.util.changed").emit("create", nil, dir .. "/lua/made/inner/deep.lua")
ok(
  "a folder the operation made appears in the nearest folder that was read",
  T.wait(function()
    return line_of("made/inner") ~= nil
  end, 4000)
)

-- ── sort ───────────────────────────────────────────────────────────────────────
local function order()
  local a, r =
    adapter.get_node_line(dir .. "/lua/mod/a.lua"),
    adapter.get_node_line(dir .. "/lua/mod/renamed.lua")
  return a and r and (a < r)
end
eq("by name a.lua stands above renamed.lua", order(), true)
view:set_sort("name", true)
T.wait(function()
  return order() == false
end)
eq("descending order reaches the section at once", order(), false)
view:set_sort("name", false)
T.wait(function()
  return order() == true
end)
eq("... and back", order(), true)

-- ── search ─────────────────────────────────────────────────────────────────────
ok("a search starts in the view of sections", view:search("guide"))
T.wait(function()
  local s = view:searching()
  return s ~= nil and s.done
end, 8000)
ok("... and shows the hit from a folder that was never opened", has("docs/guide.md"))
ok("... the other section is not on screen meanwhile", line_of("Buffers") == nil)
eq("... a hit belongs to the files", view:source_of(dir .. "/docs/guide.md"), "files")
T.mkfile("lua/mod/during_search.lua")
T.settle(600)
ok(
  "a change during the search does not replace the hits",
  has("docs/guide.md") and line_of("Buffers") == nil
)
ok("clearing the search", view:clear_search())
T.settle(100)
ok("... brings the sections back", line_of("Buffers") ~= nil and has("lua"))
ok(
  "... with what changed meanwhile",
  T.wait(function()
    return has("lua/mod/during_search.lua")
  end, 4000)
)
eq("the view is still the one of sections", view.view_name, "work")

-- ── the root ───────────────────────────────────────────────────────────────────
ok("set_root to a folder below", view:set_root(dir .. "/lua"))
T.settle(200)
ok("... the section shows that folder", has("lua/init.lua") and not has("docs"))
ok("... and back", view:set_root(dir))
T.settle(200)
ok("... the section shows the project again", has("docs") and has("README.md"))
-- another root is another tree: what was open is closed, as in the files view
ok("... with its folders closed", not has("lua/init.lua"))
adapter.expand_paths({ dir .. "/lua", dir .. "/lua/mod" })
ok("... and they open again", has("lua/mod/a.lua"))

-- ── the files view next to it ──────────────────────────────────────────────────
eq("back to the files", { view:show("files") }, { true })
T.settle(100)
ok(
  "the files view shows the root and its entries",
  has("lua") and has("docs") and line_of("Buffers") == nil
)
ok("the section gave its handles back; the files view holds its own", watch.covers(dir))
eq("the files view is one view of files", view:sources(), { "files" })
ok("it had its own open folders all along", #files_before >= 1)
view:show("work")
T.settle(200)
ok("the view of sections comes back with its open folders", has("lua/mod/a.lua"))
view:show("buffers")
T.settle(100)
eq(
  "a view without the files has no files section: search answers false",
  view:search("guide"),
  false
)
eq("... and no open folders of its own", adapter.get_expanded_paths() ~= nil, true)
view:show("files")
T.settle(100)

-- ── closing ────────────────────────────────────────────────────────────────────
view:show("work")
T.settle(100)
adapter.close()
T.settle(100)
eq("a closed tree holds no handle", watch.count(), 0)
ok("the listing cache is the shared one", type(list.cached) == "function")

eq("nothing at warning level in the whole run", T.loud(), {})
T.finish()
