-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_watch_spec.lua -- the own tree follows the disk: a change made outside the editor shows
-- without a refresh, only the folder that changed is read again (and only one the tree has read), a
-- burst costs one or two reads, open folders stay open; the handles are counted, shared between views,
-- closed with the window and released for an operation; a folder with an event storm is held back.
--
--   nvim --clean --headless -u NONE -l TESTS/native_watch_spec.lua

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

local list = require("filetree.native.fs.list")
local watch = require("filetree.native.fs.watch")
local native = require("filetree.native")
require("filetree.config").setup({})
local adapter = require("filetree.adapter.native")

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_watch_%d"):format(base, vim.uv.hrtime() % 1e9)
local function mkfile(rel)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
  return path
end
mkfile("open/a.lua")
mkfile("open/deep/x.lua")
mkfile("closed/c.lua")
mkfile("chain/only/leaf.lua")
mkfile("top.lua")

local function lines()
  return vim.api.nvim_buf_get_lines(adapter.get_bufnr(), 0, -1, false)
end
---Wait until `path` is (or is no longer) a row of the tree.
local function shown(path, want)
  if want == nil then want = true end
  vim.wait(6000, function()
    return (adapter.get_node_line(path) ~= nil) == want
  end, 25)
  return adapter.get_node_line(path) ~= nil
end
local function settle(ms)
  vim.wait(ms or 400, function()
    return false
  end)
end

eq("no handle before a tree is shown", watch.count(), 0)
adapter.toggle_at("left", { dir = dir })
adapter.expand_node({ path = dir .. "/open" })
local win = adapter.get_winid()
ok("showing the tree opens a handle", watch.count() >= 1)
if watch.recursive then
  eq("one recursive handle for the root", watch.watched(), { dir })
else
  ok("one handle per folder the tree has read", vim.tbl_contains(watch.watched(), dir .. "/open"))
end
-- a watcher is not live the instant it was started (FSEvents registers from another thread)
settle(600)

-- ── a change outside the editor shows by itself ────────────────────────────────
mkfile("new_top.lua")
ok("a new file in the root appears without a refresh", shown(dir .. "/new_top.lua"))
mkfile("open/b.lua")
ok("a new file in an open folder appears", shown(dir .. "/open/b.lua"))
eq("the open folder is still open", adapter.get_node_line(dir .. "/open/a.lua") ~= nil, true)
vim.fn.delete(dir .. "/top.lua")
eq("a deleted file disappears", shown(dir .. "/top.lua", false), false)

-- ── only folders the tree has read are read again ──────────────────────────────
settle()
local scans = list.stats.scans
mkfile("closed/d.lua")
settle(800)
eq("a change in a folder that was never opened reads nothing", list.stats.scans, scans)
adapter.expand_node({ path = dir .. "/closed" })
ok(
  "... and is there when the folder is opened",
  adapter.get_node_line(dir .. "/closed/d.lua") ~= nil
)

-- ── a burst costs one read, or two ─────────────────────────────────────────────
settle()
scans = list.stats.scans
for i = 1, 60 do
  mkfile(("open/burst_%02d.lua"):format(i))
end
ok("all 60 files of a burst appear", shown(dir .. "/open/burst_60.lua"))
settle(600)
local burst_scans = list.stats.scans - scans
say(("  info 60 files written in a row: %d read(s) of the folder"):format(burst_scans))
ok(
  ("the burst is answered by a few reads, not one per file (%d)"):format(burst_scans),
  burst_scans >= 1 and burst_scans <= 6
)

-- ── the cursor stays on its node while rows come and go above it ───────────────
adapter.scroll_to_line(adapter.get_node_line(dir .. "/new_top.lua"))
mkfile("aaa_first.lua")
ok("the new first entry appears", shown(dir .. "/aaa_first.lua"))
eq("the cursor is still on its node", adapter.get_current_node().name, "new_top.lua")

-- ── a folder inside a merged line ──────────────────────────────────────────────
local merged = adapter.get_node_line(dir .. "/chain/only")
eq("chain/only is one line", lines()[merged], "  ▸ chain/only/")
mkfile("chain/sibling.lua")
vim.wait(6000, function()
  local line = adapter.get_node_line(dir .. "/chain")
  return line ~= nil and lines()[line] == "  ▸ chain/"
end, 25)
eq(
  "a second entry in the outer folder splits the merged line",
  lines()[adapter.get_node_line(dir .. "/chain")],
  "  ▸ chain/"
)

-- ── a removed folder that was open ─────────────────────────────────────────────
adapter.expand_node({ path = dir .. "/open/deep" })
vim.fn.delete(dir .. "/open/deep", "rf")
eq("an open folder that is deleted goes with its rows", shown(dir .. "/open/deep", false), false)

-- ── handles: shared, closed with the window, released for an operation ─────────
local held = watch.count()
vim.cmd("tabnew")
adapter.toggle_at("left", { dir = dir })
if watch.recursive then
  eq("a second view of the same root shares the handle", watch.count(), held)
else
  ok("a second view of the same root opens no second handle on the root", watch.count() <= held + 1)
end
adapter.close()
vim.cmd("tabclose")
ok("closing the second view leaves the first one watching", watch.count() >= 1)

local resume = watch.release(dir .. "/open")
if watch.recursive then
  eq("release of a folder below the watched root closes nothing", watch.count(), held)
else
  ok(
    "release closes the handles on the folder and below",
    not vim.tbl_contains(watch.watched(), dir .. "/open")
  )
end
resume()
local resume_root = watch.release(dir)
eq("release of the root closes every handle on it", watch.count(), 0)
resume_root()
ok("resume opens them again", watch.count() >= 1)
settle(600)
mkfile("after_release.lua")
ok("... and the tree follows again", shown(dir .. "/after_release.lua"))

vim.api.nvim_set_current_win(win)
adapter.close()
eq("closing the tree closes its handles", watch.count(), 0)
mkfile("while_closed.lua")
settle(300)
adapter.toggle_at("left")
ok(
  "a change made while the tree was closed shows when it is opened again",
  shown(dir .. "/while_closed.lua")
)
ok("the handle is back", watch.count() >= 1)

-- ── a folder with an event storm is held back ──────────────────────────────────
adapter.close()
watch.configure({ storm = 50, quiet_ms = 300, debounce_ms = 30 })
local reports = {}
local unsubscribe = watch.subscribe(function(dirs)
  reports[#reports + 1] = table.concat(dirs, ",")
end)
local quarantined = watch.stats.quarantined
for i = 1, 200 do
  watch.on_event(dir .. "/storm", ("f%d"):format(i))
end
watch.on_event(dir .. "/calm", "one")
settle(120)
eq("the calm folder is reported, the stormy one is not", reports, { dir .. "/calm" })
eq("the storm was noticed once", watch.stats.quarantined, quarantined + 1)
watch.on_event(dir .. "/storm", "more")
settle(150)
eq("events during the hold add no report", #reports, 1)
vim.wait(3000, function()
  return #reports >= 2
end, 25)
eq("after it went quiet the folder is reported once", reports[2], dir .. "/storm")
unsubscribe()
watch.on_event(dir .. "/calm", "two")
settle(120)
eq("after unsubscribe nothing arrives", #reports, 2)

-- ── watching can be switched off ───────────────────────────────────────────────
native.reset()
eq("reset closes every handle", watch.count(), 0)
native.setup({ watch = false })
adapter.toggle_at("left", { dir = dir })
eq("native.watch = false opens no handle", watch.count(), 0)

native.reset()
native.setup({})
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_watch_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
