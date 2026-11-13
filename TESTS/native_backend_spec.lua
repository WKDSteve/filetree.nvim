-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_backend_spec.lua -- what the suites against a real neo-tree pin (collapse_all_backends,
-- sort_cycle_backends, quickpick_neotree, group_empty_dirs_collapse, the two-tabs part of adapter_lines),
-- against the own tree: collapse_on_toggle, the cursor staying on its entry through a re-sort, the
-- numbered quick-pick mode on a real tree window, `<S-CR>` on a folder and on a merged folder line, and
-- two trees live in two tabs at once.
--
--   nvim --clean --headless -u NONE -l TESTS/native_backend_spec.lua

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
-- 80x24 whatever the options say, and the next forced redraw writes past it (Neovim 0.12: a
-- segfault on Windows, a failed assertion in grid_line_flush in a debug build). The tree and the
-- editor windows fit into 80 columns.

-- Results go to stdout directly: print() in a headless run goes through the message area.
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

local list = require("filetree.native.fs.list")
local native = require("filetree.native")
local filetree = require("filetree")

local real_notify = vim.notify
local warnings = {}
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
    warnings[#warnings + 1] = tostring(msg)
  end
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
---Run the callback a key is bound to in the tree buffer. `<S-CR>` cannot be fed in a headless run (it
---arrives as `<CR>`), so the mapping is called the way the neo-tree suite of this case does it.
local function press(adapter_, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(adapter_.get_bufnr(), "n")) do
    if map.lhs == lhs and type(map.callback) == "function" then
      return (pcall(vim.api.nvim_win_call, adapter_.get_winid(), map.callback))
    end
  end
  return false
end
local function settle(ms)
  vim.wait(ms or 80, function()
    return false
  end)
end

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local work = ("%s/ft_backend_%d"):format(base, vim.uv.hrtime() % 1e9)
for _, rel in ipairs({
  "a/b/c/deep.lua",
  "a/b/side.lua",
  "a/near.lua",
  "x/y/z.lua",
  "x/x1.lua",
  "g/h/i/leaf.lua",
  "src/a.lua",
  "src/b.lua",
  "top.lua",
  "mid.lua",
  "big.lua",
}) do
  local path = work .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ rel == "big.lua" and ("x"):rep(500) or "x" }, path)
end
vim.cmd("cd " .. vim.fn.fnameescape(work))

local adapter
local function set_up(features)
  native.reset()
  filetree.setup({
    adapter = "native",
    deps_popup = false,
    features = vim.tbl_extend("force", {
      auto_reveal = { enabled = false },
      close_on_open = { enabled = false },
      session = { enabled = false },
    }, features),
  })
  adapter = filetree.adapter()
end
local function open_dirs()
  local out = {}
  for _, path in ipairs(adapter.get_expanded_paths() or {}) do
    out[#out + 1] = path:sub(#work + 2)
  end
  table.sort(out)
  return table.concat(out, ",")
end
local function lines()
  return vim.api.nvim_buf_get_lines(adapter.get_bufnr(), 0, -1, false)
end
local function editor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= adapter.get_winid() and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

-- ── collapse_on_toggle (collapse_all_backends) ─────────────────────────────────
set_up({ tree_toggle = { enabled = true, collapse_on_toggle = true } })
local tt = filetree.feature("tree_toggle")
local function open_on(rel)
  if adapter.is_open() then adapter.close() end
  local win = editor_window() or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(work .. "/" .. rel))
  tt.toggle("left")
  settle()
end
local function user_open(rel)
  adapter.expand_node({ path = work .. "/" .. rel })
end

open_on("top.lua")
user_open("x")
user_open("x/y")
eq("setup: x and x/y opened by hand", open_dirs(), "x,x/y")
open_on("a/b/c/deep.lua")
eq("reopen on deep.lua: only its chain stays open", open_dirs(), "a,a/b,a/b/c")
eq("... and the cursor is on the file", adapter.get_current_node().name, "deep.lua")

user_open("x")
vim.api.nvim_win_close(adapter.get_winid(), true)
vim.cmd("edit " .. vim.fn.fnameescape(work .. "/top.lua"))
tt.toggle("left")
settle()
eq("closed with nvim_win_close, reopened on top.lua: nothing below the root open", open_dirs(), "")

open_on("a/b/c/deep.lua")
user_open("x")
user_open("x/y")
ok("collapse_all(keep) on a live tree", adapter.collapse_all(work .. "/a/b/c/deep.lua"))
eq("... deep.lua's chain stays open, x and x/y close", open_dirs(), "a,a/b,a/b/c")

user_open("x")
local outside = vim.fn.tempname() .. "-outside.lua"
vim.fn.writefile({ "x" }, outside)
ok("collapse_all with a file outside the root", adapter.collapse_all(outside))
eq("... keeps nothing open", open_dirs(), "")
os.remove(outside)

open_on("a/b/c/deep.lua")
vim.api.nvim_set_current_win(adapter.get_winid())
adapter.collapse_all(nil)
eq("collapse_all(): every folder closed", open_dirs(), "")
eq(
  "... the cursor on the top-level entry it was under",
  adapter.get_current_node().path,
  work .. "/a"
)

-- a scratch buffer keeps nothing either
adapter.close()
vim.cmd("enew")
vim.bo.buftype = "nofile"
tt.toggle("left")
settle()
eq("toggled from a scratch buffer: nothing open", open_dirs(), "")
adapter.close()
vim.cmd("bwipeout!")

set_up({ tree_toggle = { enabled = true } })
tt = filetree.feature("tree_toggle")
open_on("top.lua")
user_open("x")
user_open("x/y")
open_on("a/b/c/deep.lua")
eq(
  "collapse_on_toggle off: x and x/y stay open next to a's chain",
  open_dirs(),
  "a,a/b,a/b/c,x,x/y"
)
adapter.close()

-- ── sort (sort_cycle_backends) ─────────────────────────────────────────────────
set_up({ tree_toggle = { enabled = true } })
adapter.toggle_at("left", { dir = work })
local function file_names()
  local out = {}
  for _, node in ipairs(adapter.get_visible_nodes("files")) do
    out[#out + 1] = node.name
  end
  return table.concat(out, ",")
end
eq(
  "get_sort before any sort: name ascending",
  adapter.get_sort(),
  { kind = "name", descending = false }
)
eq("rendered by name", file_names(), "big.lua,mid.lua,top.lua")
adapter.scroll_to_line(adapter.get_node_line(work .. "/mid.lua"))
local sort_cycle = filetree.feature("sort_cycle")
sort_cycle.cycle()
eq("by size, largest first", file_names():match("^[^,]+"), "big.lua")
eq(
  "cursor identity: still on mid.lua after the re-sort",
  adapter.get_current_node().name,
  "mid.lua"
)
user_open("a")
sort_cycle.cycle()
eq("a re-sort keeps open folders open", open_dirs(), "a")
sort_cycle.cycle()
adapter.collapse_node({ path = work .. "/a" })
eq("back to name", { adapter.get_sort().kind, file_names() }, { "name", "big.lua,mid.lua,top.lua" })
adapter.close()

-- ── <S-CR> on a folder and on a merged folder line (group_empty_dirs_collapse) ─
set_up({})
adapter.toggle_at("left", { dir = work })
settle() -- the features bind their keys one tick after the tree buffer got its filetype
local merged = adapter.get_node_line(work .. "/g/h/i")
eq("the chain g/h/i is one line", lines()[merged], "  ▸ g/h/i/")
adapter.scroll_to_line(merged)
feed("<CR>")
vim.wait(500, function()
  return adapter.get_node_line(work .. "/g/h/i/leaf.lua") ~= nil
end)
ok("<CR> on the merged line opens it", adapter.get_node_line(work .. "/g/h/i/leaf.lua") ~= nil)
adapter.scroll_to_line(merged)
ok("<S-CR> is bound in the tree", press(adapter, "<S-CR>"))
settle()
eq(
  "<S-CR> on the open merged line closes it",
  adapter.get_node_line(work .. "/g/h/i/leaf.lua"),
  nil
)
eq("... and the line is still the merged one", lines()[merged], "  ▸ g/h/i/")
local scans = list.stats.scans
adapter.scroll_to_line(adapter.get_node_line(work .. "/src"))
press(adapter, "<S-CR>")
settle()
eq("<S-CR> on a folder that was never opened reads nothing", list.stats.scans, scans)
ok("... and the folder is still there", adapter.get_node_line(work .. "/src") ~= nil)
adapter.close()

-- ── quickpick (quickpick_neotree) ──────────────────────────────────────────────
set_up({ quickpick = { enabled = true, timeout_ms = 0 } })
local qp = filetree.feature("quickpick")
vim.cmd("edit " .. vim.fn.fnameescape(work .. "/top.lua"))
local editor = vim.api.nvim_get_current_win()
---Labels drawn in the tree buffer, by 1-based line.
local function labels_of(buf)
  local ns = vim.api.nvim_get_namespaces()["filetree_quickpick"]
  local out = {}
  if not ns then return out end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local text = ""
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      text = text .. chunk[1]
    end
    out[mark[2] + 1] = text
  end
  return out
end
local function number_of(name)
  local buf = qp.snapshot().buf
  local labels = labels_of(buf)
  for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:find(name, 1, true) and labels[i] then return labels[i] end
  end
end

eq("the tree starts closed", { adapter.is_open() }, { false })
eq("start accepts", qp.start(), true)
local booted = vim.wait(3000, function()
  return qp.is_active()
end, 20)
ok("the mode starts once the tree is there", booted)
if booted then
  local snap = qp.snapshot()
  eq("focus is on the tree window", vim.api.nvim_get_current_win(), snap.win)
  local labels = labels_of(snap.buf)
  local text = vim.api.nvim_buf_get_lines(snap.buf, 0, -1, false)
  eq("the tree's own root line carries no label", labels[1], nil)
  local misaligned = {}
  for _, node in ipairs(adapter.get_visible_nodes(nil, snap.buf)) do
    if labels[node.line_number] and not text[node.line_number]:find(node.name, 1, true) then
      misaligned[#misaligned + 1] = node.name
    end
  end
  eq("every labelled line shows its node's own name", misaligned, {})
  ok("something is numbered", snap.count >= 4)

  local watched = { "s", "t", "v", "c", "j", "k", "<CR>", "<Esc>", "a", "d", "q", "x" }
  local function maps()
    local out = {}
    vim.api.nvim_buf_call(snap.buf, function()
      for _, lhs in ipairs(watched) do
        local map = vim.fn.maparg(lhs, "n", false, true)
        out[lhs] = next(map)
            and { rhs = map.rhs, desc = map.desc, nowait = map.nowait, cb = map.callback }
          or false
      end
    end)
    return out
  end
  qp.cancel()
  local before = maps()
  eq("cancel gives the focus back to the editor", vim.api.nvim_get_current_win(), editor)

  qp.start()
  ok("the open tree is numbered at once", qp.is_active())
  local count_before = qp.snapshot().count
  local src_no = number_of("src")
  ok("src has a number", src_no ~= nil)
  feed(src_no)
  local grew = vim.wait(3000, function()
    return qp.is_active() and qp.snapshot().count > count_before
  end, 20)
  ok("picking the folder shows its children and renumbers", grew)
  ok("the mode is still running after a folder", qp.is_active())

  vim.wait(2000, function()
    return qp.is_active() and number_of("a.lua") ~= nil
  end, 20)
  local a_no = number_of("a.lua")
  ok("a.lua has a number", a_no ~= nil)
  -- editor windows only: neither the tree nor the float the mode shows its state in
  local function editor_wins()
    local n = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local is_float = vim.api.nvim_win_get_config(win).relative ~= ""
      local is_tree = vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "filetree"
      if not is_float and not is_tree then n = n + 1 end
    end
    return n
  end
  local wins_before = editor_wins()
  if a_no then feed("v" .. a_no) end
  settle()
  ok("the mode ended", not qp.is_active())
  eq("the file is open", list.norm(vim.fn.expand("%:p")), work .. "/src/a.lua")
  ok("in a new split, not in the tree", editor_wins() > wins_before)
  ok("the current window is not the tree", vim.bo.filetype ~= "filetree")
  eq("the tree's own keys are back, exactly", maps(), before)
end
adapter.close()
vim.cmd("silent! only")

-- ── two trees in two tabs at once (adapter_lines) ──────────────────────────────
set_up({})
adapter.toggle_at("left", { dir = work .. "/a" })
local buf1, tab1 = adapter.get_bufnr(), vim.api.nvim_get_current_tabpage()
vim.cmd("tabnew")
adapter.toggle_at("left", { dir = work .. "/x" })
local buf2 = adapter.get_bufnr()
ok("each tab has its own tree buffer", buf1 ~= buf2)
eq("the ambient tree is the one of the current tab", adapter.get_root_path(), work .. "/x")
eq(
  "a line of the other tab's tree resolves through its buffer",
  adapter.get_node_at_line(buf1, 1).path,
  work .. "/a/b"
)
eq("... and this tab's through its own", adapter.get_node_at_line(buf2, 1).path, work .. "/x/y")
eq(
  "visible nodes of the other tab's buffer",
  adapter.get_visible_nodes(nil, buf1)[1].path,
  work .. "/a/b"
)
eq(
  "get_state(buf) is the tree of that buffer",
  { adapter.get_state(buf1).root, adapter.get_state(buf2).root },
  { work .. "/a", work .. "/x" }
)
local seen = {}
local unsubscribe = adapter.on_render(function(bufnr)
  seen[#seen + 1] = bufnr
end)
adapter.get_state(buf1):refresh() -- the tree of the tab that is not current redraws
eq("a redraw of the other tab's tree reports its own buffer", seen[1], buf1)
ok("... and never this tab's", not vim.tbl_contains(seen, buf2))
unsubscribe()
adapter.expand_node({ path = work .. "/x/y" })
eq(
  "expanding here leaves the other tab's tree alone",
  #vim.api.nvim_buf_get_lines(buf1, 0, -1, false),
  3
)
vim.cmd("tabclose")
eq(
  "back in the first tab, its tree answers",
  { vim.api.nvim_get_current_tabpage(), adapter.get_root_path() },
  { tab1, work .. "/a" }
)

eq("no warning in the whole run", warnings, {})

vim.notify = real_notify
native.reset()
vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(work, "rf")

say(("\nfiletree.nvim native_backend_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
