-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, duplicate-set-field
-- TESTS/size_info_queue_spec.lua -- the queue of size_info for a process per folder (no helper):
-- at most `max_running` processes, one start per turn of the loop, none while the cursor moves in a
-- tree, a row that left the screen is dropped before its turn, and a burst of answers is drawn once.
-- The process start is stubbed: nothing is spawned.
--
--   nvim --clean --headless -u NONE -l TESTS/size_info_queue_spec.lua

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
  if got == want then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s want %s"):format(name, tostring(got), tostring(want)))
  end
end

require("filetree.native.fs.helper").configure(false)
local size_info = require("filetree.features.ui.size_info")
local live = require("filetree.util.live_procs")
local is_win = vim.fn.has("win32") == 1

-- ── stubs ─────────────────────────────────────────────────────────────────────
local orig = { spawn = live.spawn, render = size_info._render, visible = size_info._visible_paths }
local opts_before = vim.deepcopy(size_info._queue_opts)

---@type { cmd: string[], on_exit: fun(res: table), answered?: boolean }[]
local started = {}
live.spawn = function(cmd, _, on_exit)
  started[#started + 1] = { cmd = cmd, on_exit = on_exit }
  return {}
end
local renders = 0
size_info._render = function()
  renders = renders + 1
end

---Answer the i-th started process with a size of 4 KiB.
local function answer(i)
  started[i].on_exit({ code = 0, stdout = is_win and "4096" or "4\tx" })
end

local function settle(ms)
  vim.wait(ms or 30, function()
    return false
  end)
end

local function reset()
  -- empty the queue first (else an answer below starts the next one), then answer what still runs,
  -- so the running count of the module is back to zero
  size_info.refresh()
  for i = 1, #started do
    if not started[i].answered then
      started[i].answered = true
      answer(i)
    end
  end
  settle(20)
  size_info.refresh()
  assert(size_info._queue_state().running == 0, "reset: a process still counts as running")
  started, renders = {}, 0
end

local answers = {}
local function ask(path, droppable)
  size_info._query_dir_size(path, function(bytes)
    answers[path] = bytes or false
  end, droppable)
end

-- ── cap and one start per turn ────────────────────────────────────────────────
size_info._queue_opts.quiet_ms = 0
size_info._queue_opts.render_ms = 20
for i = 1, 5 do
  ask("/q/cap" .. i)
end
eq("nothing starts while the asking code still runs", #started, 0)
settle(60)
eq("at most two processes at a time", #started, 2)
eq("the rest waits in the queue", size_info._queue_state().queued, 3)
started[1].answered = true
answer(1)
settle(60)
eq("a free slot starts the next one", #started, 3)
eq("the answer reached its caller", answers["/q/cap1"], 4096)
reset()

-- ── a burst of answers is drawn once ──────────────────────────────────────────
ask("/q/burst1")
ask("/q/burst2")
settle(60)
renders = 0
started[1].answered, started[2].answered = true, true
answer(1)
answer(2)
settle(80)
eq("two answers in one burst: one redraw", renders, 1)
reset()

-- ── nothing starts while the cursor moves ─────────────────────────────────────
size_info._queue_opts.quiet_ms = 150
size_info._activity()
ask("/q/quiet")
settle(60)
eq("no start within quiet_ms of a cursor move", #started, 0)
settle(200)
eq("the start comes once the cursor rested", #started, 1)
size_info._queue_opts.quiet_ms = 0
reset()

-- ── a row that left the screen is dropped ─────────────────────────────────────
size_info._visible_paths = function()
  return { ["/q/on"] = true }
end
ask("/q/off1", true)
ask("/q/on", true)
ask("/q/off2", true)
ask("/q/direct") -- asked by code, not by a row: never dropped
settle(80)
local cmds = {}
for _, s in ipairs(started) do
  cmds[#cmds + 1] = table.concat(s.cmd, " ")
end
local all = table.concat(cmds, "\n")
eq("the row on screen is measured", all:find("/q/on", 1, true) ~= nil, true)
eq(
  "a row off screen is not",
  all:find("/q/off1", 1, true) == nil and all:find("/q/off2", 1, true) == nil,
  true
)
eq("a direct ask is kept", all:find("/q/direct", 1, true) ~= nil, true)
eq("the queue is empty after the drop", size_info._queue_state().queued, 0)
-- a dropped row asks again when it is back on screen
size_info._visible_paths = function()
  return { ["/q/off1"] = true }
end
reset()
ask("/q/off1", true)
settle(60)
eq("a dropped row is measured when it comes back", #started, 1)
reset()

-- ── a program that cannot start does not jam the queue ────────────────────────
size_info._visible_paths = orig.visible
live.spawn = function()
  error("ENOENT: no such program")
end
local notify = vim.notify_once
vim.notify_once = function() end
ask("/q/fail1")
ask("/q/fail2")
settle(80)
eq("a failed start answers its caller", answers["/q/fail1"], false)
eq("the next one is still tried", answers["/q/fail2"], false)
eq("no slot stays taken", size_info._queue_state().running, 0)
vim.notify_once = notify

-- ── restore ───────────────────────────────────────────────────────────────────
live.spawn = orig.spawn
size_info._render = orig.render
size_info._visible_paths = orig.visible
for k, v in pairs(opts_before) do
  size_info._queue_opts[k] = v
end
require("filetree.native.fs.helper").configure(nil)

print(("\nfiletree.nvim size_info_queue_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
