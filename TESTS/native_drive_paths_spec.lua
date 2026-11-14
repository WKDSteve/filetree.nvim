-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_drive_paths_spec.lua -- the path features on the own tree, each through its key on a
-- real tree window: `path_copy`, `copy_file_list`, `lua_require_copy`, `markdown_links`.
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_paths_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.env.FT_DRIVE_ROOT = nil
local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_paths_spec",
  before_setup = function(bench)
    -- `[e` folds a path under an environment variable: one that points at the project
    vim.env.FT_DRIVE_ROOT = bench.dir
  end,
  features = {
    path_copy = { enabled = true, env_roots = { "FT_DRIVE_ROOT" }, nvim_config_root = false },
    copy_file_list = { enabled = true, keymap_save = "]S" },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir

---What a key in the tree leaves in the register, as lines.
---@param keys string
---@return string[]
local function copy(keys)
  T.forget_copy()
  T.tree()
  feed(keys)
  local text = T.copied()
  return text == "" and {} or vim.split(text, "\n", { plain = true })
end
local function sorted(items)
  table.sort(items)
  return items
end
local marks = T.filetree.feature("marks")

-- ── path_copy ──────────────────────────────────────────────────────────────────
T.on("lua/mod/a.lua")
eq("[a copies the absolute path", copy("[a"), { dir .. "/lua/mod/a.lua" })
eq("]a copies the folder of the node", copy("]a"), { dir .. "/lua/mod" })
eq("]R copies the path below the project root", copy("]R"), { "lua/mod/a.lua" })
eq("[R copies the project root (no marker: the cwd)", vim.tbl_map(T.norm, copy("[R")), { dir })
eq("]b copies the path as seen from the open buffer", copy("]b"), { "./lua/mod/a.lua" })
eq("[e folds the root into its variable", copy("[e"), { "$FT_DRIVE_ROOT/lua/mod/a.lua" })
T.on("lua/mod")
eq("[a on a folder copies the folder", copy("[a"), { dir .. "/lua/mod" })

-- marked nodes win over the node under the cursor
T.on("lua/mod/a.lua")
feed("m")
T.on("lua/mod/b.lua")
feed("m")
T.on("README.md")
eq(
  "with marks, [a copies the marked paths",
  sorted(copy("[a")),
  { dir .. "/lua/mod/a.lua", dir .. "/lua/mod/b.lua" }
)
eq(
  "... and ML one markdown link per mark",
  sorted(copy("ML")),
  { "[a.lua](lua/mod/a.lua)", "[b.lua](lua/mod/b.lua)" }
)
eq(
  "MM copies the links of the marked nodes",
  sorted(copy("MM")),
  { "[a.lua](lua/mod/a.lua)", "[b.lua](lua/mod/b.lua)" }
)
marks.clear_all()
T.settle()

-- ── copy_file_list ─────────────────────────────────────────────────────────────
T.on("lua")
eq(
  "[f copies the files below the folder, absolute",
  sorted(copy("[f")),
  { dir .. "/lua/init.lua", dir .. "/lua/mod/a.lua", dir .. "/lua/mod/b.lua" }
)
eq(
  "]f copies them relative to the cwd",
  sorted(copy("]f")),
  { "lua/init.lua", "lua/mod/a.lua", "lua/mod/b.lua" }
)
eq(
  "[F copies the folders, the node's own first",
  sorted(copy("[F")),
  { dir .. "/lua", dir .. "/lua/mod" }
)
eq("]F copies them relative to the cwd", sorted(copy("]F")), { "lua", "lua/mod" })
T.on("lua/init.lua")
eq("]F on a file copies its folder", copy("]F"), { "lua" })
-- the list written to a file: the prompt names a file, the feature writes it
T.on("lua/mod")
T.answer("input", dir .. "/list.txt")
feed("]S")
T.wait(function()
  return T.exists("list.txt")
end)
eq(
  "the save key writes the list to the file that was named",
  sorted(T.exists("list.txt") and T.read("list.txt") or {}),
  { "lua/mod/a.lua", "lua/mod/b.lua" }
)
T.wait(function()
  return T.shown("list.txt")
end, 4000)
ok("... and the tree shows the new file by itself", T.shown("list.txt"))
vim.fn.delete(dir .. "/list.txt")

-- ── lua_require_copy ───────────────────────────────────────────────────────────
T.on("lua/mod/a.lua")
eq("rq copies the require() of a module", copy("rq"), { "require('mod.a')" })
T.on("lua/init.lua")
eq("rq on an init.lua names the folder above it", copy("rq"), { "require('init')" })
T.on("lua/mod")
eq(
  "rq on a folder copies one line per module below it",
  sorted(copy("rq")),
  { "require('mod.a')", "require('mod.b')" }
)
local before = T.mark()
T.on("README.md")
eq("rq on a file outside lua/ copies nothing", copy("rq"), {})
ok("... and says so", T.told("No Lua modules found", before))

-- ── markdown_links ─────────────────────────────────────────────────────────────
T.on("docs/guide.md")
eq("ML copies a markdown link to the node", copy("ML"), { "[guide.md](docs/guide.md)" })
T.on("lua")
eq(
  "MR copies a link for every file below the folder",
  sorted(copy("MR")),
  { "[a.lua](lua/mod/a.lua)", "[b.lua](lua/mod/b.lua)", "[init.lua](lua/init.lua)" }
)
before = T.mark()
eq("MM without marks copies nothing", copy("MM"), {})
ok("... and says so", T.told("No marked nodes", before))

-- MI writes the link into the window the tree was entered from
vim.api.nvim_set_current_win(T.editor_win)
T.on("docs/guide.md")
before = T.mark()
feed("MI")
vim.cmd("stopinsert")
local editor_buf = vim.api.nvim_win_get_buf(T.editor_win)
local inserted = table.concat(vim.api.nvim_buf_get_lines(editor_buf, 0, -1, false), "\n")
ok(
  "MI inserts the link into the editor window: " .. inserted,
  inserted:find("[guide.md](./docs/guide.md)", 1, true) ~= nil
)
ok("... and says how many", T.told("Inserted 1 markdown link(s)", before))
eq(
  "... into the buffer the tree came from",
  T.norm(vim.api.nvim_buf_get_name(editor_buf)),
  dir .. "/README.md"
)
vim.api.nvim_buf_call(editor_buf, function()
  vim.cmd("silent edit!")
end)

eq("no prompt went unanswered", T.unanswered, 0)
T.finish()
