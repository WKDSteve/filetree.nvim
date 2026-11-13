-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_perf_spec.lua -- the budgets of the own tree that are about change, not about opening
-- (those are in native_view_spec.lua): a status change of one node with 10 000 lines in the tree costs
-- no buffer write and stays under its budget; five changes a second in a folder of 2000 entries keep
-- at most one read of it running, and the editor's loop is never held up for long.
--
--   nvim --clean --headless -u NONE -l TESTS/native_perf_spec.lua
--   FILETREE_PERF_LONG=1 ... runs the storm for the 20 s of the concept instead of 6 s
--
-- Budgets are the concept's (section 17) on a development machine; on CI (env CI) they are five times
-- as wide, since shared runners are slower and noisier. The measured numbers are printed either way.

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
local function settle(ms)
  vim.wait(ms or 100, function()
    return false
  end)
end

local SLACK = vim.env.CI and 5 or 1
local function ms(ns)
  return ns / 1e6
end
local function median(values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  return sorted[math.ceil(#sorted / 2)]
end

vim.g.have_nerd_font = false

local list = require("filetree.native.fs.list")
local filetree = require("filetree")
require("filetree.config").setup({})
local adapter = require("filetree.adapter.native")
local buf_of = adapter.get_bufnr

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_perf_%d"):format(base, vim.uv.hrtime() % 1e9)
local function fill(folder, count)
  vim.fn.mkdir(dir .. "/" .. folder, "p")
  for i = 1, count do
    local fd = vim.uv.fs_open(("%s/%s/f%05d.txt"):format(dir, folder, i), "w", 420)
    vim.uv.fs_close(fd)
  end
end
fill("big", 10000)
fill("busy", 2000)

-- ── a status change at 10 000 lines ────────────────────────────────────────────
local status = {}
local emit
local remove = filetree.decorator({
  name = "perf_status",
  slot = "badge",
  roll_up = "worst",
  severity = { "bad", "good" },
  get = function(path)
    return status[path]
  end,
  all = function()
    return status
  end,
  subscribe = function(e)
    emit = e
    return function() end
  end,
})

adapter.toggle_at("left", { dir = dir })
adapter.expand_node({ path = dir .. "/big" })
local lines = vim.api.nvim_buf_line_count(buf_of())
ok("the tree shows the 10 000 entries: " .. lines .. " lines", lines > 10000)

local target = dir .. "/big/f05000.txt"
local tick = vim.api.nvim_buf_get_changedtick(buf_of())
local took = {}
for i = 1, 41 do
  status[target] = { text = (i % 2 == 0) and "B" or "G", status = (i % 2 == 0) and "bad" or "good" }
  local t0 = vim.uv.hrtime()
  emit({ target })
  took[#took + 1] = vim.uv.hrtime() - t0
  settle(5) -- the coalesced redraw runs
end
local status_ms = ms(median(took))
say(("  info a status change at %d lines: median %.3f ms"):format(lines, status_ms))
ok(("... under %d ms (median of 41)"):format(SLACK), status_ms < 1 * SLACK)
eq("... and not one buffer write", vim.api.nvim_buf_get_changedtick(buf_of()), tick)
remove()

-- ── five changes a second on 2000 entries ──────────────────────────────────────
adapter.collapse_node({ path = dir .. "/big" })
adapter.expand_node({ path = dir .. "/busy" })
settle(300)

-- count the reads of the busy folder that run at the same time
local busy = dir .. "/busy"
local in_flight, max_in_flight, reads = 0, 0, 0
local real_list = list.list
---@diagnostic disable-next-line: duplicate-set-field
list.list = function(path, cb, ...)
  if path ~= busy then return real_list(path, cb, ...) end
  reads = reads + 1
  in_flight = in_flight + 1
  max_in_flight = math.max(max_in_flight, in_flight)
  return real_list(path, function(...)
    in_flight = in_flight - 1
    return cb(...)
  end, ...)
end

-- how long the loop is held up: a 10 ms timer, and the longest gap between its calls
local gap_max, last = 0, vim.uv.hrtime()
local ticker = vim.uv.new_timer()
ticker:start(10, 10, function()
  local now = vim.uv.hrtime()
  gap_max = math.max(gap_max, now - last)
  last = now
end)

local seconds = vim.env.FILETREE_PERF_LONG and 20 or 6
local written = 0
local t_end = vim.uv.hrtime() + seconds * 1e9
while vim.uv.hrtime() < t_end do
  written = written + 1
  local fd = vim.uv.fs_open(("%s/storm_%04d.txt"):format(busy, written), "w", 420)
  vim.uv.fs_close(fd)
  settle(200)
end
local last_file = ("%s/storm_%04d.txt"):format(busy, written)
vim.wait(5000, function()
  return adapter.get_node_line(last_file) ~= nil
end, 25)
ticker:stop()
ticker:close()
list.list = real_list

say(
  ("  info %d s, %d files written, %d reads of the folder, longest gap in the loop %.1f ms"):format(
    seconds,
    written,
    reads,
    ms(gap_max)
  )
)
eq("at most one read of the folder runs at a time", max_in_flight, 1)
ok("not more reads than changes", reads <= written)
ok("the tree followed: the last file shows", adapter.get_node_line(last_file) ~= nil)
ok(
  ("the loop was never held up for more than %d ms"):format(100 * SLACK),
  ms(gap_max) < 100 * SLACK
)

require("filetree.native").reset()
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_perf_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
