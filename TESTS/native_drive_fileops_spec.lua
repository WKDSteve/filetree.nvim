-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive_fileops_spec.lua -- the file operations on the own tree, each through its key on
-- a real tree window: `smart_create`, `smart_rename`, `move`, `trash`, `rename_batch`,
-- `create_from_template`, `link_create`, `open_replace`, `buffer_save`. After each one the tree has to
-- show the new state by itself: no feature asks the own tree for a refresh of everything.
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_fileops_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local bin, templates
local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_fileops_spec",
  before_setup = function(bench)
    -- The trash of the operating system, replaced by a folder next to the project: what the feature
    -- does around the one external call (confirm, release of the watchers, history, marks, the
    -- tree) is the real code.
    bin = bench.dir .. "_bin"
    vim.fn.mkdir(bin, "p")
    local platform = require("filetree.features.fileops.trash.platform")
    local function send(path)
      local moved = vim.uv.fs_rename(path, bin .. "/" .. vim.fn.fnamemodify(path, ":t"))
      return { ok = moved == true, err = moved and nil or "could not move" }
    end
    platform.available = function()
      return true
    end
    platform.send = function(path, cb)
      vim.schedule(function()
        cb(send(path))
      end)
    end
    platform.send_batch = function(paths, cb)
      vim.schedule(function()
        cb(vim.tbl_map(send, paths))
      end)
    end

    -- create_from_template asks through ui.kit's picker when there is one. Loaded once without it,
    -- the feature asks through the plain list, which the bench answers.
    templates = bench.dir .. "_templates"
    vim.fn.mkdir(templates, "p")
    vim.fn.writefile({ "# ${name}", "from the template" }, templates .. "/note.md")
    local kit = require("ui.kit")
    local picker = kit.picker
    kit.picker = nil
    require("filetree.features.fileops.create_from_template")
    kit.picker = picker
  end,
  -- Without the tree's own watcher (and without the feature that would stand in for it): what
  -- brings the tree up to date here is the announcement of the operation alone.
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    create_from_template = { enabled = true, prefer = "builtin" },
    link_create = { enabled = true, keymap = "gl", keymap_mark = "gk", keymap_paste = "gK" },
    open_replace = { enabled = true, close_tree = false },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
T.filetree
  .feature("create_from_template")
  .setup({ enabled = true, prefer = "builtin", template_dir = templates, keymap = "A" }, T.adapter)

---Count the refreshes of the whole tree a step asks for: on the own tree a file operation tells the
---tree which folder changed, it does not have everything read again.
local full_refreshes = 0
local real_refresh = T.adapter.refresh
T.adapter.refresh = function(...)
  full_refreshes = full_refreshes + 1
  return real_refresh(...)
end

local function current()
  local node = T.adapter.get_current_node()
  return node and T.norm(node.path) or nil
end
local function gone(rel)
  return T.wait(function()
    return not T.shown(rel)
  end, 5000)
end
local function appears(rel)
  return T.wait(function()
    return T.shown(rel)
  end, 5000)
end
local function editor_file()
  return T.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(T.editor_win)))
end

-- ── smart_create: a ────────────────────────────────────────────────────────────
T.on("docs")
T.answer("input", "new.md")
feed("a")
ok("a on a folder creates the file in it", T.exists("docs/new.md"))
ok("... the tree shows it", appears("docs/new.md"))
T.wait(function()
  T.tree()
  return current() == dir .. "/docs/new.md"
end, 3000)
eq("... and the tree's cursor is on it", current(), dir .. "/docs/new.md")
ok(
  "the prompt named the folder: " .. T.asked[#T.asked].prompt,
  T.asked[#T.asked].prompt:find("docs/", 1, true) ~= nil
)

T.on("lua/init.lua")
T.answer("input", "sub/")
feed("a")
eq(
  "a on a file creates next to it; a trailing / makes a folder",
  vim.fn.isdirectory(dir .. "/lua/sub"),
  1
)
ok("... the tree shows the folder", appears("lua/sub"))

T.on("lua/sub")
T.answer("input", false)
feed("a")
eq("a dismissed prompt creates nothing", vim.fn.readdir(dir .. "/lua/sub"), {})

-- ── smart_rename: r ────────────────────────────────────────────────────────────
vim.api.nvim_set_current_win(T.editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/docs/new.md"))
T.on("docs/new.md")
T.answer("input", "renamed.md")
feed("r")
T.wait(function()
  return T.exists("docs/renamed.md")
end, 5000)
eq("r renames the node", { T.exists("docs/renamed.md"), T.exists("docs/new.md") }, { true, false })
ok("... the tree shows the new name", appears("docs/renamed.md"))
ok("... and no longer the old one", gone("docs/new.md"))
eq("... the open buffer follows the file", editor_file(), dir .. "/docs/renamed.md")
eq("the prompt started from the old name", T.asked[#T.asked].default, "new.md")

-- a name that is taken: the feature asks, and "Cancel" leaves both files alone
T.on("docs/renamed.md")
T.answer("input", "guide.md")
T.answer("choice", "Cancel")
feed("r")
T.settle(300)
eq(
  "r onto a taken name asks first; Cancel keeps both",
  { T.exists("docs/renamed.md"), T.exists("docs/guide.md") },
  { true, true }
)

-- ── move: M ────────────────────────────────────────────────────────────────────
T.on("docs/renamed.md")
T.answer("input", "lua/sub/")
feed("M")
T.wait(function()
  return T.exists("lua/sub/renamed.md")
end, 5000)
eq(
  "M moves the node into the folder",
  { T.exists("lua/sub/renamed.md"), T.exists("docs/renamed.md") },
  { true, false }
)
ok("... the tree drops it from the old folder", gone("docs/renamed.md"))
T.on("lua/sub")
T.adapter.expand_node({ path = dir .. "/lua/sub" })
ok("... and shows it in the new one", appears("lua/sub/renamed.md"))

-- a folder that does not exist yet: asked for, then created
T.on("lua/sub/renamed.md")
T.answer("input", "archive/")
T.answer("choice", "Create")
feed("M")
T.wait(function()
  return T.exists("archive/renamed.md")
end, 5000)
ok("M into a folder that is not there creates it after a yes", T.exists("archive/renamed.md"))
ok("... the tree shows the new folder", appears("archive"))

-- marked nodes move together
T.on("lua/mod/a.lua")
feed("m")
T.on("lua/mod/b.lua")
feed("m")
T.answer("input", "archive")
feed("M")
T.wait(function()
  return T.exists("archive/a.lua") and T.exists("archive/b.lua")
end, 5000)
eq(
  "with marks, M moves all of them",
  { T.exists("archive/a.lua"), T.exists("archive/b.lua"), T.exists("lua/mod/a.lua") },
  { true, true, false }
)
eq("... and the marks are cleared", T.filetree.feature("marks").count(), 0)
ok("... the tree drops them from the old folder", gone("lua/mod/a.lua") and gone("lua/mod/b.lua"))

-- ── trash: d ───────────────────────────────────────────────────────────────────
T.on("archive/a.lua")
T.answer("confirm", false)
feed("d")
T.settle(400)
ok("d asks; No keeps the file", T.exists("archive/a.lua"))
T.on("archive/a.lua")
T.answer("confirm", true)
local before = T.mark()
feed("d")
T.wait(function()
  return not T.exists("archive/a.lua")
end, 5000)
eq(
  "d and Yes send the file to the trash",
  { T.exists("archive/a.lua"), vim.uv.fs_stat(bin .. "/a.lua") ~= nil },
  { false, true }
)
ok("... the tree drops it", gone("archive/a.lua"))
T.wait(function()
  return T.told("trash", before)
end)
ok("... and the feature says what it did", T.told("1", before))

-- marked nodes: one question for all of them
T.on("archive/b.lua")
feed("m")
T.on("archive/renamed.md")
feed("m")
T.answer("choice", "Delete all at once")
feed("d")
T.wait(function()
  return not T.exists("archive/b.lua") and not T.exists("archive/renamed.md")
end, 5000)
eq(
  "with marks, d asks once and trashes all of them",
  { T.exists("archive/b.lua"), T.exists("archive/renamed.md") },
  { false, false }
)
ok("... the tree drops them", gone("archive/b.lua") and gone("archive/renamed.md"))
eq("... and the marks are cleared", T.filetree.feature("marks").count(), 0)

-- ── copy_move: c / x stage, p pastes into the folder under the cursor ──────────
T.on("README.md")
feed("c")
T.on("docs")
feed("p")
T.wait(function()
  return T.exists("docs/README.md")
end, 5000)
eq(
  "c then p copies the node into the folder under the cursor",
  { T.exists("docs/README.md"), T.exists("README.md") },
  { true, true }
)
ok("... the tree shows the copy", appears("docs/README.md"))

T.on("docs/README.md")
feed("x")
T.on("lua/sub")
feed("p")
T.wait(function()
  return T.exists("lua/sub/README.md") and not T.exists("docs/README.md")
end, 5000)
eq(
  "x then p moves it",
  { T.exists("lua/sub/README.md"), T.exists("docs/README.md") },
  { true, false }
)
ok("... the tree drops it from the old folder", gone("docs/README.md"))
T.on("lua/sub")
T.adapter.expand_node({ path = dir .. "/lua/sub" })
ok("... and shows it in the new one", appears("lua/sub/README.md"))
feed("X")

-- ── rename_batch: <leader>rb ───────────────────────────────────────────────────
T.on("docs/guide.md")
feed("\\rb")
local batch_buf = vim.api.nvim_get_current_buf()
eq(
  "<leader>rb opens the rename buffer",
  vim.api.nvim_buf_get_name(batch_buf):match("filetree://rename$"),
  "filetree://rename"
)
local batch = vim.api.nvim_buf_get_lines(batch_buf, 0, -1, false)
local guide_line
for i, text in ipairs(batch) do
  if text == "guide.md" then guide_line = i end
end
ok(
  "... which lists the names the tree shows",
  guide_line ~= nil and vim.tbl_contains(batch, "README.md")
)
vim.api.nvim_buf_set_lines(batch_buf, guide_line - 1, guide_line, false, { "manual.md" })
vim.cmd("silent write")
T.wait(function()
  return T.exists("docs/manual.md")
end, 5000)
eq(
  "writing the buffer renames what was edited",
  { T.exists("docs/manual.md"), T.exists("docs/guide.md") },
  { true, false }
)
ok("... the tree shows the new name", appears("docs/manual.md") and gone("docs/guide.md"))
ok("... and the rename buffer is closed", not vim.api.nvim_buf_is_valid(batch_buf))

-- ── create_from_template: A ────────────────────────────────────────────────────
T.on("docs")
T.answer("select", T.item("note.md"))
T.answer("input", "meeting.md")
feed("A")
T.wait(function()
  return T.exists("docs/meeting.md")
end, 3000)
ok("A creates a file from the picked template", T.exists("docs/meeting.md"))
eq(
  "... with the template's text",
  T.exists("docs/meeting.md") and T.read("docs/meeting.md")[2] or nil,
  "from the template"
)
ok("... the tree shows it", appears("docs/meeting.md"))
eq(
  "... and it is opened in the editor window, not in the tree",
  editor_file(),
  dir .. "/docs/meeting.md"
)
eq("the tree window still shows the tree", vim.api.nvim_win_get_buf(T.adapter.get_winid()), T.buf)

-- ── link_create: mark and paste, and the prompt ────────────────────────────────
T.on("lua/init.lua")
feed("gk")
T.on("docs")
feed("gK")
T.wait(function()
  return T.exists("docs/init.lua")
end, 3000)
ok("the link keys mark a file and paste a link to it into a folder", T.exists("docs/init.lua"))
eq(
  "... which reads as the file it points to",
  T.exists("docs/init.lua") and T.read("docs/init.lua") or nil,
  T.read("lua/init.lua")
)
ok("... the tree shows the link", appears("docs/init.lua"))

T.on("archive")
T.answer("input", dir .. "/README.md")
T.answer("choice", "Hardlink")
feed("gl")
T.wait(function()
  return T.exists("archive/README.md")
end, 3000)
ok("the link key asks for a target and links it into the folder", T.exists("archive/README.md"))
ok("... the tree shows it", appears("archive/README.md"))

-- ── open_replace: O and the swap ───────────────────────────────────────────────
T.on("lua/init.lua")
feed("O")
T.settle()
eq("O opens the node over the editor window", editor_file(), dir .. "/lua/init.lua")
ok("... the tree stays open (close_tree = false)", T.adapter.is_open())
local replaced = vim.fn.bufnr(dir .. "/docs/meeting.md")
ok("... and the buffer that was there stays listed", replaced > 0 and vim.bo[replaced].buflisted)

local init_buf = vim.api.nvim_win_get_buf(T.editor_win)
T.on("docs/manual.md")
feed("<C-M-CR>")
T.settle(200)
eq("the swap key opens the node in the editor window", editor_file(), dir .. "/docs/manual.md")
ok(
  "... and closes the buffer it replaced",
  not (vim.api.nvim_buf_is_valid(init_buf) and vim.bo[init_buf].buflisted)
)
ok("... the tree stays open", T.adapter.is_open())

-- ── buffer_save: <C-s> and <M-s> ───────────────────────────────────────────────
local manual_buf = vim.api.nvim_win_get_buf(T.editor_win)
vim.api.nvim_buf_set_lines(manual_buf, 0, -1, false, { "saved from the tree" })
T.on("README.md")
feed("<C-s>")
eq(
  "<C-s> in the tree writes the buffer of the editor window",
  T.read("docs/manual.md"),
  { "saved from the tree" }
)
ok("... and the focus stays in the tree", vim.api.nvim_get_current_win() == T.adapter.get_winid())

local readme_buf = vim.fn.bufadd(dir .. "/README.md")
vim.fn.bufload(readme_buf)
vim.api.nvim_buf_set_lines(readme_buf, 0, -1, false, { "background buffer" })
T.on("README.md")
feed("<M-s>")
eq(
  "<M-s> writes the buffer of the node under the cursor",
  T.read("README.md"),
  { "background buffer" }
)

eq("no file operation asked the own tree to read everything again", full_refreshes, 0)
eq("no prompt went unanswered", T.unanswered, 0)
eq("no warning or error in the whole run", T.loud(), {})

T.adapter.refresh = real_refresh
vim.fn.delete(bin, "rf")
vim.fn.delete(templates, "rf")
T.finish()
