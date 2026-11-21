-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_helper_build_spec.lua -- `build_async()` of the helper process (`:Filetree helper
-- build`): cargo or curl run in the background and the editor never waits for them, a second build
-- is refused, a build can be cancelled (also by quitting Neovim), a failed or unstartable program
-- says why, and the helper is off while it runs. `build()` (the plugin manager's step) still blocks
-- and still works. No real cargo or curl: `vim.system` is a stand-in whose `wait()` throws, so a
-- build that blocks the editor is red here.
--
--   nvim --clean --headless -u NONE -l TESTS/native_helper_build_spec.lua

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

local uv = vim.uv
require("filetree.config").setup({})
local helper = require("filetree.native.fs.helper")
local lib = require("lib.nvim.fs.helper")

-- A sandbox for everything the build writes: the installed program never goes below the real
-- stdpath("data"), and "cargo" builds into $CARGO_TARGET_DIR.
local work = vim.fs.normalize(vim.fn.tempname()) .. "_helper_build"
local target = work .. "/install/" .. helper.binary_name()
local built = work .. "/target/release/" .. helper.binary_name()
vim.fn.mkdir(vim.fs.dirname(built), "p")
helper.default_path = function()
  return target
end
helper.asset_name = function()
  return "filetree-helper-test-asset"
end
vim.env.CARGO_TARGET_DIR = work .. "/target"
vim.env.NVIM_MACHINE_ROLE = nil

---@param path string
---@return string|nil
local function read(path)
  local fd = io.open(path, "rb")
  if not fd then return nil end
  local text = fd:read("*a")
  fd:close()
  return text
end
---@param path string
---@param text string
local function write(path, text)
  local fd = assert(io.open(path, "wb"))
  fd:write(text)
  fd:close()
end

-- cargo and curl are "there"; the stand-in of vim.system records each start and never runs anything.
local real_executable = vim.fn.executable
vim.fn.executable = function(name)
  if name == "cargo" or name == "curl" then return 1 end
  return real_executable(name)
end
local real_system = vim.system
---@type { argv: string[], on_exit: fun(r: table), killed: string|nil, waited: boolean }[]
local starts = {}
local start_error = nil ---@type string|nil
vim.system = function(argv, _, on_exit)
  if start_error then error(start_error) end
  local job = { argv = argv, on_exit = on_exit, waited = false }
  starts[#starts + 1] = job
  return {
    pid = 4242,
    wait = function()
      job.waited = true
      error("the editor waited for " .. argv[1])
    end,
    kill = function(_, signal)
      job.killed = signal
    end,
  }
end

---Let the stand-in program end (as libuv does: off the main loop's turn) and run what was scheduled.
---@param job table
---@param result table
local function exit(job, result)
  job.on_exit(vim.tbl_extend("keep", result, { signal = 0, stdout = "", stderr = "" }))
end
local function settle()
  vim.wait(50, function()
    return false
  end)
end

local outcome ---@type { ok: boolean, message: string }|nil
local function on_done(o, m)
  outcome = { ok = o, message = m }
end

-- ── cargo in the background ──────────────────────────────────────────────────
do
  starts, outcome = {}, nil
  local b = helper.build_async({}, on_done)
  ok("build_async() returns a build at once", b ~= nil)
  eq("... cargo was started once", #starts, 1)
  eq("... by its bare name, without a shell", starts[1].argv[1], "cargo")
  ok("... with --release", vim.tbl_contains(starts[1].argv, "--release"))
  eq("... and the editor did not wait for it", starts[1].waited, false)
  eq("... no outcome yet", outcome, nil)
  ok("... building() says so", helper.building())
  eq("... and the helper is off meanwhile (the Lua tiers serve)", lib.mode(), false)

  local second
  helper.build_async({}, function(o, m)
    second = { ok = o, message = m }
  end)
  eq("a second build is refused", second and second.ok, false)
  ok(
    "... saying why: " .. tostring(second and second.message),
    second and second.message:find("already running", 1, true) ~= nil
  )
  eq("... and starts nothing", #starts, 1)
  local sync_ok, sync_message = helper.build()
  eq("build() is refused too while one runs", sync_ok, false)
  ok("... saying why: " .. sync_message, sync_message:find("already running", 1, true) ~= nil)

  write(built, "the built program")
  exit(starts[1], { code = 0 })
  eq("the outcome waits for the main loop", outcome, nil)
  settle()
  eq("when cargo ends, the callback hears ok", outcome and outcome.ok, true)
  ok(
    "... naming where: " .. tostring(outcome and outcome.message),
    outcome and outcome.message:find(target, 1, true) ~= nil
  )
  eq("... the program is in place (from $CARGO_TARGET_DIR)", read(target), "the built program")
  ok("... building() is over", not helper.building())
  ok("... and the helper's mode is the option's again", lib.mode() ~= false)
end

-- ── cargo fails ──────────────────────────────────────────────────────────────
do
  starts, outcome = {}, nil
  helper.build_async({}, on_done)
  exit(starts[1], { code = 101, stderr = "error[E0425]: cannot find value\n" })
  settle()
  eq("a failed cargo build: not ok", outcome and outcome.ok, false)
  ok(
    "... with cargo's words: " .. tostring(outcome and outcome.message),
    outcome and outcome.message:find("E0425", 1, true) ~= nil
  )
  eq("... the installed program is untouched", read(target), "the built program")
  ok("... and the next build may start", not helper.building())
end

-- ── cancelled ────────────────────────────────────────────────────────────────
do
  starts, outcome = {}, nil
  write(built, "a newer program")
  helper.build_async({}, on_done)
  ok("cancel_build() while one runs: true", helper.cancel_build())
  eq("... the program is told to stop", starts[1].killed, "sigterm")
  exit(starts[1], { code = 1, signal = 15 })
  settle()
  eq(
    "... the callback hears it was cancelled",
    outcome,
    { ok = false, message = "build cancelled" }
  )
  eq("... nothing is installed", read(target), "the built program")
  eq("cancel_build() with none running: false", helper.cancel_build(), false)

  -- cargo ended on its own just before the cancel: its end is still on the way to the main loop
  starts, outcome = {}, nil
  helper.build_async({}, on_done)
  exit(starts[1], { code = 0 })
  helper.cancel_build()
  settle()
  eq(
    "a cancel that overtakes cargo's end still cancels",
    outcome,
    { ok = false, message = "build cancelled" }
  )
  eq("... and installs nothing", read(target), "the built program")
end

-- ── Neovim quits while it builds ─────────────────────────────────────────────
do
  starts, outcome = {}, nil
  helper.build_async({}, on_done)
  vim.api.nvim_exec_autocmds("VimLeavePre", {})
  eq("quitting Neovim stops the running cargo", starts[1].killed, "sigterm")
  exit(starts[1], { code = 1, signal = 15 })
  settle()
  eq("... and the build ends as cancelled", outcome and outcome.message, "build cancelled")
end

-- ── a program that cannot start ──────────────────────────────────────────────
do
  starts, outcome = {}, nil
  start_error = "ENOENT: no such file or directory"
  local b = helper.build_async({}, on_done)
  start_error = nil
  eq("cargo cannot start: no build is returned", b, nil)
  eq("... the callback has heard it already", outcome and outcome.ok, false)
  ok(
    "... with the reason: " .. tostring(outcome and outcome.message),
    outcome and outcome.message:find("ENOENT", 1, true) ~= nil
  )
  ok("... and nothing is left running", not helper.building())
end

-- ── the download ─────────────────────────────────────────────────────────────
do
  starts, outcome = {}, nil
  helper.build_async({ download = true }, on_done)
  eq("download = true: curl, not cargo", starts[1] and starts[1].argv[1], "curl")
  local part = starts[1].argv[vim.fn.index(starts[1].argv, "--output") + 2]
  eq("... into a .part file beside the target", part, target .. ".part")
  eq("... without waiting", starts[1].waited, false)
  write(part, "the downloaded program")
  exit(starts[1], { code = 0 })
  settle()
  eq("the download ends: ok", outcome and outcome.ok, true)
  eq("... and it is the program now", read(target), "the downloaded program")
  ok("... with no .part left", not uv.fs_stat(part))

  starts, outcome = {}, nil
  helper.build_async({ download = true }, on_done)
  write(part, "half of it")
  exit(starts[1], { code = 22, stderr = "curl: (22) The requested URL returned error: 404" })
  settle()
  eq("a failed download: not ok", outcome and outcome.ok, false)
  ok(
    "... with curl's words: " .. tostring(outcome and outcome.message),
    outcome and outcome.message:find("404", 1, true) ~= nil
  )
  ok("... the .part is gone", not uv.fs_stat(part))
  eq("... and the program is untouched", read(target), "the downloaded program")
end

-- ── build() still blocks, for the plugin manager ─────────────────────────────
do
  vim.system = function(argv)
    return {
      wait = function()
        write(built, "built while waiting")
        return { code = 0, signal = 0, stdout = "", stderr = "", argv = argv }
      end,
    }
  end
  local built_ok, message = helper.build()
  eq("build() waits and installs", built_ok, true)
  ok("... saying where: " .. message, message:find(target, 1, true) ~= nil)
  eq("... the program is in place", read(target), "built while waiting")
end

vim.system = real_system
vim.fn.executable = real_executable
helper.configure(nil)
vim.fn.delete(work, "rf")

say(("\nfiletree.nvim native_helper_build_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
