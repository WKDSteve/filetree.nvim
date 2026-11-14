-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive_nav_spec.lua -- the navigation and infrastructure features on the own tree, each
-- through its key or the event it reacts to, on a real tree window: `project_root`, `cwd_sync`,
-- `cwd_mode`, `reveal_alt`, `diff`, `no_name_guard`, `layout_guard`, `hooks_api`, `safety` and
-- `:Filetree wholocks`.
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_nav_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
-- the backups of `safety`: beside the fixture, never in the data directory of the person running this
local backups = vim.fn.tempname() .. "_ft_backups"
local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_nav_spec",
  -- two projects, each marked by a package.json: the fixture itself and `sub` in it
  files = {
    "lua/mod/a.lua",
    "lua/mod/b.lua",
    "lua/init.lua",
    "docs/guide.md",
    "README.md",
    "package.json",
    "sub/package.json",
    "sub/x.lua",
  },
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    cwd_sync = { enabled = true, debounce_ms = 10 },
    cwd_mode = { enabled = true, persist = false, indicator = { enabled = false } },
    safety = { enabled = true, backup_dir = backups },
    trash = { enabled = true, mode = "permanent", confirm = false, use_safety = true },
    layout_guard = { enabled = true, delay_ms = 10 },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local tree_win = T.adapter.get_winid()

local function cwd()
  return T.norm(vim.fn.getcwd())
end
local function current()
  local node = T.adapter.get_current_node()
  return node and node.name or nil
end
---Show a file in the editor window, the way a user opens it there.
local function edit(rel)
  -- cwd_sync holds still for two seconds after the cursor moved in the tree (the user is finding
  -- their way there); the spec does not wait them out
  T.filetree.feature("cwd_sync").pause(0)
  vim.api.nvim_set_current_win(T.editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. rel))
end

-- ── project_root ───────────────────────────────────────────────────────────────
local project_root = T.filetree.feature("project_root")
eq(
  "project_root finds the project a file belongs to",
  T.norm(project_root.find(dir .. "/sub/x.lua")),
  dir .. "/sub"
)
eq("... the outer one for a file of it", T.norm(project_root.find(dir .. "/lua/init.lua")), dir)

-- ── cwd_sync: a file of another project moves the cwd and the root of the tree ─
edit("sub/x.lua")
T.wait(function()
  return cwd() == dir .. "/sub" and T.norm(T.adapter.get_root_path() or "") == dir .. "/sub"
end, 4000)
eq("cwd_sync moves the cwd to the project of the file", cwd(), dir .. "/sub")
eq("... and roots the tree there", T.norm(T.adapter.get_root_path()), dir .. "/sub")
T.wait(function()
  return current() == "x.lua"
end, 3000)
eq("... with the cursor on the file", current(), "x.lua")
eq("... the focus stays in the editor window", vim.api.nvim_get_current_win(), T.editor_win)
edit("README.md")
T.wait(function()
  return cwd() == dir and T.norm(T.adapter.get_root_path() or "") == dir
end, 4000)
eq(
  "a file of the outer project brings both back",
  { cwd(), T.norm(T.adapter.get_root_path()) },
  { dir, dir }
)

-- ── cwd_mode: L cycles the mode, gp locks the cwd on a folder ──────────────────
local cwd_mode = T.filetree.feature("cwd_mode")
local mode_before = cwd_mode.mode()
T.tree()
local before = T.mark()
feed("L")
ok(
  ("L moves to the next cwd mode (%s -> %s)"):format(mode_before, cwd_mode.mode()),
  cwd_mode.mode() ~= mode_before
)
ok("... and says which", T.told("cwd mode: " .. cwd_mode.mode(), before))
cwd_mode.set_mode(mode_before)

T.on("lua")
feed("gp")
eq("gp locks the cwd on the folder under the cursor", cwd_mode.mode(), "lock")
eq("... that folder", T.norm(cwd_mode.root() or ""), dir .. "/lua")
edit("sub/x.lua")
T.settle(400)
eq("under the lock a file of another project does not move the cwd", cwd(), dir .. "/lua")
ok("unlock gives the mode back", cwd_mode.unlock() and cwd_mode.mode() == mode_before)
edit("README.md")
T.wait(function()
  return cwd() == dir and T.norm(T.adapter.get_root_path() or "") == dir
end, 4000)
eq("... and the cwd follows the file again", cwd(), dir)

-- ── reveal_alt: B goes to the file that was open before ────────────────────────
edit("lua/mod/a.lua")
edit("docs/guide.md")
T.wait(function()
  return current() == "guide.md"
end, 3000)
T.tree()
before = T.mark()
feed("B")
T.wait(function()
  return current() == "a.lua"
end, 3000)
eq("B puts the tree's cursor on the alternate file", current(), "a.lua")
eq("... without a complaint", T.loud(before), {})

-- ── diff: D stages a file, D on a second one compares them ─────────────────────
T.on("README.md")
feed("D")
eq(
  "D stages the file under the cursor",
  T.norm(T.filetree.feature("diff").staged() or ""),
  dir .. "/README.md"
)
T.on("docs/guide.md")
feed("D")
local diffed = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.wo[win].diff then
    diffed[#diffed + 1] =
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), ":t")
  end
end
table.sort(diffed)
eq("D on a second file opens the two side by side", diffed, { "README.md", "guide.md" })
ok("... and not in the tree window", not vim.wo[tree_win].diff)
eq("... which still shows the tree", vim.api.nvim_win_get_buf(tree_win), T.buf)
T.filetree.feature("diff").close()
-- back to one editor window
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if
    win ~= tree_win
    and win ~= T.editor_win
    and vim.api.nvim_win_get_config(win).relative == ""
  then
    pcall(vim.api.nvim_win_close, win, true)
  end
end
if not vim.api.nvim_win_is_valid(T.editor_win) then
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= tree_win then T.editor_win = win end
  end
end

-- ── hooks_api and safety: a delete announces itself and leaves a backup ────────
local hooks = T.filetree.feature("hooks_api")
local heard = {}
local hook_before = hooks.on("before_delete", function(data)
  heard[#heard + 1] = "before " .. vim.fn.fnamemodify(data.path, ":t")
end)
local hook_after = hooks.on("after_delete", function(data)
  heard[#heard + 1] = ("after %s %s"):format(vim.fn.fnamemodify(data.path, ":t"), tostring(data.ok))
end)
local safety = T.filetree.feature("safety")
local backups_before = #safety.list_backups()
T.on("lua/mod/b.lua")
feed("d")
T.wait(function()
  return not T.exists("lua/mod/b.lua") and #heard == 2
end, 5000)
eq("d deletes the node (mode permanent, no question)", T.exists("lua/mod/b.lua"), false)
eq(
  "hooks_api: the subscribers hear of it, before and after",
  heard,
  { "before b.lua", "after b.lua true" }
)
eq("safety: a backup of the file was made first", #safety.list_backups(), backups_before + 1)
T.wait(function()
  return not T.shown("lua/mod/b.lua")
end, 4000)
ok("... and the tree drops the node", not T.shown("lua/mod/b.lua"))
hooks.off(hook_before)
hooks.off(hook_after)

-- ── :Filetree wholocks ─────────────────────────────────────────────────────────
before = T.mark()
local said_ok =
  pcall(vim.cmd, "silent Filetree wholocks " .. vim.fn.fnameescape(dir .. "/README.md"))
T.wait(function()
  return T.told("README.md", before)
end, 15000)
ok("wholocks reports on a file with the own tree active", said_ok and T.told("README.md", before))
eq("... without a warning", T.loud(before), {})

-- ── no_name_guard: a stray [No Name] window goes back to a real buffer ─────────
vim.api.nvim_set_current_win(T.editor_win)
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
vim.cmd("enew")
T.wait(function()
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(T.editor_win)) ~= ""
end, 2000)
ok(
  "no_name_guard shows a real buffer in a window that got an empty one",
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(T.editor_win)) ~= ""
)
eq("... and leaves the tree window alone", vim.api.nvim_win_get_buf(tree_win), T.buf)

-- ── layout_guard: the tree is never the only window ────────────────────────────
vim.api.nvim_win_close(T.editor_win, true)
T.wait(function()
  return #vim.api.nvim_tabpage_list_wins(0) == 2
end, 2000)
local wins = vim.api.nvim_tabpage_list_wins(0)
eq("layout_guard opens an editor window when the last one closed", #wins, 2)
eq("... the tree stays on its side", { wins[1], T.adapter.get_position() }, { tree_win, "left" })
eq("... at its width", vim.api.nvim_win_get_width(tree_win), 36)

eq("no prompt went unanswered", T.unanswered, 0)
eq("no warning or error in the whole run", T.loud(), {})

vim.fn.delete(backups, "rf")
T.finish()
