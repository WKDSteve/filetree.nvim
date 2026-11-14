-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_crossplugin_spec.lua -- the calls other plugins make into filetree.nvim, on the own
-- tree (stage E7, table 15.1 of the concept). Each block makes the call the way the plugin named
-- makes it; what the call does in detail has its own spec (`native_view_spec` for `open_reveal`,
-- `roots_spec`, `create_names_spec`, `refs/`, `native_explorer_spec` for fileops.nvim). Here the
-- question is whether the own tree answers at all, so that a change of backend breaks nobody.
--
--   gopath, ui.kit, images   require("filetree").adapter().open_reveal(path)
--   casedesk                 open_reveal(file, 0); a root provider; a name suggestion for `a`
--   tasks                    :Filetree open <dir>, as a command table
--   ui                       the filetype of the tree buffer; the entries for its context menu
--   fileops, gitsuite        filetree.refs, whatever the backend
--
--   nvim --clean --headless -u NONE -l TESTS/native_crossplugin_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_crossplugin_spec",
  files = {
    "lua/mod/a.lua",
    "lua/mod/b.lua",
    "lua/init.lua",
    "docs/guide.md",
    "README.md",
    "case/notes/n.md",
    "case/main.md",
  },
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    tree_traverse = { enabled = true },
    cwd_sync = { enabled = true, debounce_ms = 10 },
    cwd_mode = { enabled = true, persist = false, indicator = { enabled = false } },
  },
})
local eq, ok, dir = T.eq, T.ok, T.dir
local filetree = T.filetree

local function root()
  return T.norm(T.adapter.get_root_path() or "")
end
local function under_cursor()
  local node = T.adapter.get_current_node()
  return node and T.norm(node.path) or nil
end

-- ── ui: the filetype ───────────────────────────────────────────────────────────
-- ui.nvim reserves the tabline above the tree by this filetype (`tree_offset_ft = "filetree"`), and
-- the exclusion lists of my.nvim, sessions.nvim, insights.nvim and lib.nvim name it.
eq("the tree buffer has the filetype `filetree`", vim.bo[T.buf].filetype, "filetree")

-- ── gopath, ui.kit, images: open_reveal(path) ──────────────────────────────────
vim.api.nvim_set_current_win(T.editor_win)
T.adapter.close()
ok("the tree is closed", not T.adapter.is_open())
local adapter = filetree.adapter()
ok("open_reveal is a function of the active adapter", type(adapter.open_reveal) == "function")
ok("open_reveal(path) answers true", adapter.open_reveal(dir .. "/lua/mod/b.lua") == true)
ok("... the tree is open", T.adapter.is_open())
eq("... its cursor is on the file", under_cursor(), dir .. "/lua/mod/b.lua")
eq("... and the focus stayed in the editor", vim.api.nvim_get_current_win(), T.editor_win)

-- ── casedesk: open_reveal(file, 0) ─────────────────────────────────────────────
ok("open_reveal(file, 0) answers true", adapter.open_reveal(dir .. "/docs/guide.md", 0) == true)
eq("... the cursor is on the file", under_cursor(), dir .. "/docs/guide.md")
eq("... and the root stayed", root(), dir)
eq("a path that is none answers false", adapter.open_reveal(""), false)

-- ── tasks: :Filetree open <dir>, as a command table ────────────────────────────
ok(":Filetree exists as a command", vim.fn.exists(":Filetree") == 2)
local ran = pcall(vim.cmd, { cmd = "Filetree", args = { "open", dir .. "/lua" } })
ok(":Filetree open <dir> runs", ran)
ok(
  "... and roots the tree at the folder",
  T.wait(function()
    return root() == dir .. "/lua"
  end)
)
ran = pcall(vim.cmd, { cmd = "Filetree", args = { "open", dir .. "/lua/init.lua" } })
ok(":Filetree open <file> runs", ran)
ok(
  "... and reveals the file",
  T.wait(function()
    return under_cursor() == dir .. "/lua/init.lua"
  end)
)
T.adapter.set_root(dir)

-- ── casedesk: a root provider ──────────────────────────────────────────────────
local roots = require("filetree.roots")
roots.register("spec-case", function(path)
  path = T.norm(path)
  if path:sub(1, #dir + 6) == dir .. "/case/" or path == dir .. "/case" then
    return dir .. "/case"
  end
  return nil
end)
eq(
  "a registered provider answers for a file it knows",
  T.norm(roots.resolve(dir .. "/case/notes/n.md")),
  dir .. "/case"
)
filetree.feature("cwd_sync").pause(0)
vim.api.nvim_set_current_win(T.editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/case/notes/n.md"))
ok(
  "a file of the case roots the own tree at the case folder",
  T.wait(function()
    return root() == dir .. "/case"
  end, 3000)
)
roots.unregister("spec-case")
eq("without the provider nobody answers", roots.resolve(dir .. "/case/notes/n.md"), nil)
vim.cmd("cd " .. vim.fn.fnameescape(dir))
T.adapter.set_root(dir)

-- ── casedesk: a name suggestion for `a` ────────────────────────────────────────
local names = require("filetree.create_names")
names.register("spec-case", function(folder)
  return T.norm(folder) == dir .. "/case" and "round-2.md" or nil
end)
eq(
  "a registered suggestion is answered for its folder",
  names.suggest(dir .. "/case"),
  "round-2.md"
)
eq("... and for no other", names.suggest(dir .. "/docs"), nil)
names.unregister("spec-case")

-- ── ui: the entries for its context menu ───────────────────────────────────────
local menu = require("filetree.integrations.menu")
T.on("README.md")
ok("integrations.menu is enabled on the own tree", menu.enabled() == true)
local items = menu.items()
ok("... and answers entries for the node under the cursor", type(items) == "table" and #items > 0)
ok(
  "... one for the tree window itself",
  type(menu.window_entry(T.buf)) == "table" or menu.window_entry(T.buf) == nil
)

-- ── fileops, gitsuite: filetree.refs ───────────────────────────────────────────
local refs = require("filetree.refs")
for _, name in ipairs({ "scan", "register", "resolve", "for_delete", "status" }) do
  ok("filetree.refs." .. name .. " is there", type(refs[name]) == "function")
end
ok("refs.status() answers a table with the own tree active", type(refs.status()) == "table")

eq("nothing at warning level in the whole run", T.loud(), {})
T.finish()
