-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive_views_spec.lua -- the feature keys in a view of the own tree that is not the
-- files. The keys are bound on the one tree buffer for all views (buffers, git, symbols,
-- diagnostics, what plugins register), so each has to do the right thing there:
--
--   on a node with a path   the feature acts on that file, as it does in the files view
--   on a node without one   (the head of a section, a group, a symbol) it says that there is nothing
--                           to act on, asks nothing and changes nothing
--   filter and sort         act on the listing of the files: they say so instead of looking as if
--                           they had worked on this view
--   create                  has no folder under the cursor: it asks, and names the folder it creates in
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_views_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_views_spec",
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    trash = { enabled = true, mode = "permanent", confirm = true },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local view = T.adapter.get_state()
local win = T.adapter.get_winid()

-- two files open in the editor window: they are the nodes of the buffers view
vim.api.nvim_set_current_win(T.editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/lua/mod/a.lua"))
T.tree()
local shown = view:show("buffers")
T.settle(200)
eq("the tree shows the buffers view", { shown, view.view_name }, { true, "buffers" })

---The line of the first row whose text contains `needle`.
local function line_of(needle)
  for i, text in ipairs(T.lines()) do
    if text:find(needle, 1, true) then return i end
  end
  return nil
end
---Put the cursor on a line of the view and press `keys`; what was said, asked and left behind.
---@return { said: string[], loud: string[], asked: integer, floats: integer }
local function press(line, keys)
  T.tree()
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.cmd("doautocmd CursorMoved")
  local from, asked = T.mark(), #T.asked
  feed(keys)
  T.settle(60)
  local said = {}
  for i = from, #T.notes do
    said[#said + 1] = T.notes[i].msg
  end
  local out = { said = said, loud = T.loud(from), asked = #T.asked - asked, floats = #T.floats() }
  T.close_floats()
  return out
end

local head = line_of("Buffers")
local a_line = line_of("a.lua")
ok("the view has a head and a line per buffer", head ~= nil and a_line ~= nil)
vim.api.nvim_win_set_cursor(win, { head, 0 })
eq("the head of a section is no entry for the features", T.adapter.get_current_node(), nil)
vim.api.nvim_win_set_cursor(win, { a_line, 0 })
eq(
  "a buffer of a file is one: a file with its path",
  { T.adapter.get_current_node().type, T.norm(T.adapter.get_current_node().path) },
  { "file", dir .. "/lua/mod/a.lua" }
)

-- ── on a node without a path every feature key says so and does nothing ────────
-- key -> a piece of what the feature says
local on_nothing = {
  { "[a", "No node under cursor" },
  { "]f", "No current node" },
  { "rq", "No current node" },
  { "ML", "No current node" },
  { "d", "No node selected" },
  { "r", "No node under cursor" },
  { "M", "No node selected" },
  { "c", "no node selected" },
  { "x", "no node selected" },
  { "m", "no node under cursor" },
  { "gy", "No current node" },
  { "I", "no current node" },
  { "\\sm", "No node under cursor" },
  { "\\fm", "No node under cursor" },
  { "\\sp", "No current node" },
  { "go", "No PDF under cursor" },
  { "gM", "No markdown file under cursor" },
  { "gz", "No node to compress" },
  { "D", "cursor is not on a file" },
  { "O", "No file under cursor" },
}
local files_before = vim.fn.glob(dir .. "/**", false, true)
T.forget_copy()
for _, case in ipairs(on_nothing) do
  local key, says = case[1], case[2]
  local got = press(head, key)
  local told = false
  for _, msg in ipairs(got.said) do
    if msg:find(says, 1, true) then told = true end
  end
  eq(
    ("%s on the head of a section says so, asks nothing, opens nothing"):format(key),
    { told, got.asked, got.floats },
    { true, 0, 0 }
  )
end
eq("... nothing was copied", T.copied(), "")
eq("... nothing was marked or staged", T.filetree.feature("marks").count(), 0)
eq("... and nothing on disk changed", vim.fn.glob(dir .. "/**", false, true), files_before)
eq("... the view is still the buffers", view.view_name, "buffers")

-- ── on a node with a path the features act on that file ────────────────────────
T.forget_copy()
press(a_line, "[a")
eq("[a on a buffer copies the path of its file", T.copied(), dir .. "/lua/mod/a.lua")
press(a_line, "ML")
eq("ML on a buffer copies a link to its file", T.copied(), "[a.lua](lua/mod/a.lua)")
local info = press(a_line, "I")
eq("I on a buffer opens the info of its file", { info.floats, info.loud }, { 1, {} })
T.filetree.feature("node_info").close()

-- a rename of the file behind a buffer: the file moves, the buffer follows, the view shows it
T.answer("input", "renamed.lua")
press(a_line, "r")
T.wait(function()
  return T.exists("lua/mod/renamed.lua") and line_of("renamed.lua") ~= nil
end, 5000)
eq(
  "r on a buffer renames its file",
  { T.exists("lua/mod/renamed.lua"), T.exists("lua/mod/a.lua") },
  { true, false }
)
ok("... and the view shows the buffer under its new name", line_of("renamed.lua") ~= nil)

-- a delete: asked for like in the files view, and the buffer leaves the view with its file
local renamed_line = line_of("renamed.lua")
T.answer("confirm", true)
press(renamed_line, "d")
T.wait(function()
  return not T.exists("lua/mod/renamed.lua") and line_of("renamed.lua") == nil
end, 5000)
eq("d on a buffer deletes its file after the question", T.exists("lua/mod/renamed.lua"), false)
ok("... and the buffer is gone from the view", line_of("renamed.lua") == nil)

-- ── filter: the search lists files, this view has none ─────────────────────────
head = line_of("Buffers")
local lines_before = T.lines()
local filtered = press(head, "/")
eq("/ opens no filter line in this view", filtered.floats, 0)
ok(
  "... and says that there is nothing to filter here: " .. tostring(filtered.said[1]),
  (filtered.said[1] or ""):find('nothing to filter in the view "buffers"', 1, true) ~= nil
)
local from = T.mark()
T.filetree.feature("filter").apply("readme")
ok("the filter called directly says the same", T.told("nothing to filter in the view", from))
eq("... and the view is as it was", T.lines(), lines_before)
eq("... no search runs behind it", view:searching(), nil)

-- ── sort: the order is the one of the files ────────────────────────────────────
local sort_before = T.adapter.get_sort()
local sorted = press(head, "\\so")
ok(
  "the sort key says that it sorted the files, not this view: " .. tostring(sorted.said[1]),
  (sorted.said[1] or ""):find('the view "buffers" keeps its own order', 1, true) ~= nil
)
eq("... the view is as it was", T.lines(), lines_before)
ok("... and the files have the new order", T.adapter.get_sort().kind ~= sort_before.kind)

-- ── create: no folder under the cursor, so the prompt names the one it takes ───
T.answer("input", "from_view.md")
local created = press(head, "a")
eq("a on the head of a section asks for a name", created.asked, 1)
ok(
  "... and names the folder it creates in (the root): " .. T.asked[#T.asked].prompt,
  T.asked[#T.asked].prompt:find("Create in ./", 1, true) ~= nil
)
ok("... where the file then is", T.exists("from_view.md"))

-- ── back in the files view everything is there ─────────────────────────────────
view:show("files")
T.settle(200)
T.wait(function()
  return T.shown("from_view.md")
end, 4000)
ok("the files view shows the file that was created from the other view", T.shown("from_view.md"))
T.on("lua/mod")
T.adapter.expand_node({ path = dir .. "/lua/mod" })
T.wait(function()
  return T.shown("lua/mod/b.lua")
end)
eq(
  "... and no longer the one that was renamed and deleted there",
  { T.shown("lua/mod/a.lua"), T.shown("lua/mod/renamed.lua") },
  { false, false }
)
T.tree()
local in_files = press(vim.api.nvim_win_get_cursor(win)[1], "/")
eq("in the files view / opens the filter line", in_files.floats, 1)
from = T.mark()
feed("\\so")
ok(
  "... and the sort key says what it sorted by, without the remark",
  T.told("sorted by", from) and not T.told("keeps its own order", from)
)

eq("no prompt went unanswered", T.unanswered, 0)
T.finish()
