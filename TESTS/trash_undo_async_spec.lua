-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/trash_undo_async_spec.lua -- `U` (undo of the last trash) never blocks the editor: the
-- restore program (PowerShell on Windows, gio or mv elsewhere) runs in the background, the outcome
-- follows by callback, a second `U` waits for the first and then takes the next entry of the
-- history, a program that cannot start says why and the next `U` still works, and the tree hears of
-- the restored file. No real program runs: `vim.system` is a stand-in whose `wait()` throws, so a
-- restore that blocks the editor is red here.
--
--   nvim --clean --headless -u NONE -l TESTS/trash_undo_async_spec.lua

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

-- What the undo module says, in order.
local said = {}
vim.notify = function(msg)
  said[#said + 1] = tostring(msg)
end
local function said_text()
  return table.concat(said, " | ")
end

-- A sandbox for the XDG trash of the Linux path: nothing outside the temp folder is touched.
local work = vim.fs.normalize(vim.fn.tempname()) .. "_undo_async"
vim.env.XDG_DATA_HOME = work .. "/data"
vim.fn.mkdir(work .. "/data/Trash/files", "p")
vim.fn.mkdir(work .. "/data/Trash/info", "p")
vim.fn.mkdir(work .. "/project", "p")

local gio_present = false
local real_executable = vim.fn.executable
vim.fn.executable = function(name)
  if name == "gio" then return gio_present and 1 or 0 end
  return real_executable(name)
end

-- The stand-in of vim.system records each start and never runs anything.
---@type { argv: string[], on_exit: fun(r: table), waited: boolean }[]
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
    kill = function() end,
    is_closing = function()
      return false
    end,
  }
end

---Let the stand-in program end and run what was scheduled.
local function exit(job, code, stderr)
  job.on_exit({ code = code, signal = 0, stdout = "", stderr = stderr or "" })
  vim.wait(50, function()
    return false
  end)
end

local undo = require("filetree.features.fileops.trash.undo")

local function record_windows(path)
  undo.record(path)
  undo.last().platform = "windows"
  undo.last().name = vim.fn.fnamemodify(path, ":t")
end

---@type { ok: boolean, err: string|nil, entry: table|nil }[]
local outcomes = {}
local function on_done(o, e, entry)
  outcomes[#outcomes + 1] = { ok = o, err = e, entry = entry }
end

-- ── Windows: PowerShell in the background ────────────────────────────────────
do
  starts, outcomes, said = {}, {}, {}
  record_windows("C:/Users/x/project/one.txt")
  undo.restore_last(on_done)
  eq("U starts the restore program once", #starts, 1)
  eq(
    "... by its bare name, without a shell",
    starts[1].argv[1],
    require("filetree.util.platform").powershell_exe()
  )
  eq("... and the editor did not wait for it", starts[1].waited, false)
  eq("... no outcome yet", #outcomes, 0)
  ok("... busy() says a restore runs", undo.busy())
  eq("... the entry stays in the history meanwhile", #undo.history(), 1)

  exit(starts[1], 0)
  eq("once PowerShell is done: one outcome", #outcomes, 1)
  eq("... restored", outcomes[1].ok, true)
  eq("... of that entry", outcomes[1].entry.original_path, "C:/Users/x/project/one.txt")
  ok("... said so", said_text():find("Restored: C:/Users/x/project/one.txt", 1, true) ~= nil)
  eq("... and the entry left the history", #undo.history(), 0)
  ok("... nothing runs any more", not undo.busy())
end

-- ── exit codes of the script keep their messages ─────────────────────────────
do
  starts, outcomes, said = {}, {}, {}
  record_windows("C:/Users/x/project/taken.txt")
  undo.restore_last(on_done)
  exit(starts[1], 3)
  eq("exit 3: not restored", outcomes[1].ok, false)
  ok(
    "... the target exists, said",
    tostring(outcomes[1].err):find("already exists", 1, true) ~= nil
  )
  ok("... as an error", said_text():find("Restore failed", 1, true) ~= nil)
  eq("... and the entry stays for another try", #undo.history(), 1)

  starts, outcomes = {}, {}
  undo.restore_last(on_done)
  exit(starts[1], 1)
  ok("exit 1: not in the bin", tostring(outcomes[1].err):find("not found", 1, true) ~= nil)
  starts, outcomes = {}, {}
  undo.restore_last(on_done)
  exit(starts[1], 2)
  ok("exit 2: could not move", tostring(outcomes[1].err):find("could not move", 1, true) ~= nil)
  starts, outcomes = {}, {}
  undo.restore_last(on_done)
  exit(starts[1], 7, "boom")
  -- run_argv reads stderr from the stream, which this stand-in does not feed: the code stands in
  eq("other codes: said with the code", outcomes[1].err, "PowerShell restore failed: exit code 7")
  -- clean up for the next case
  starts, outcomes = {}, {}
  undo.restore_last(on_done)
  exit(starts[1], 0)
  eq("history empty again", #undo.history(), 0)
end

-- ── two U in a row: one after the other, newest first ────────────────────────
do
  starts, outcomes, said = {}, {}, {}
  record_windows("C:/Users/x/project/older.txt")
  record_windows("C:/Users/x/project/newer.txt")
  undo.restore_last(on_done)
  undo.restore_last(on_done)
  eq("two U: only the first program runs", #starts, 1)
  ok("... for the newest entry", starts[1].argv[#starts[1].argv]:find("newer.txt", 1, true) ~= nil)

  -- a delete while the restore runs puts a newer entry in front
  record_windows("C:/Users/x/project/meanwhile.txt")
  exit(starts[1], 0)
  eq("the first is answered", outcomes[1] and outcomes[1].entry.name, "newer.txt")
  eq("... and taken off the history by identity, not by place", #undo.history(), 2)
  ok(
    "... the newer delete is still there",
    vim.iter(undo.history()):any(function(e)
      return e.name == "meanwhile.txt"
    end)
  )
  eq("then the second program starts", #starts, 2)
  ok(
    "... for the history's newest entry at its turn",
    starts[2].argv[#starts[2].argv]:find("meanwhile.txt", 1, true) ~= nil
  )
  exit(starts[2], 0)
  eq("both answered, in order", #outcomes, 2)
  starts, outcomes = {}, {}
  undo.restore_last(on_done)
  exit(starts[1], 0)
  eq("history empty again", #undo.history(), 0)
end

-- ── a program that cannot start says why, and the next U still works ─────────
do
  starts, outcomes, said = {}, {}, {}
  record_windows("C:/Users/x/project/nope.txt")
  record_windows("C:/Users/x/project/nope2.txt")
  start_error = "ENOENT: no such file or directory (cmd): 'powershell'"
  undo.restore_last(on_done)
  undo.restore_last(on_done)
  vim.wait(100, function()
    return #outcomes >= 2
  end)
  eq("missing program: both U answered", #outcomes, 2)
  eq("... not restored", outcomes[1].ok, false)
  ok("... with the reason", tostring(outcomes[1].err):find("ENOENT", 1, true) ~= nil)
  ok("... nothing left waiting", not undo.busy())
  start_error = nil
  starts, outcomes = {}, {}
  undo.restore_last(on_done)
  eq("next U starts again", #starts, 1)
  exit(starts[1], 0)
  undo.restore_last(on_done)
  exit(starts[2], 0)
  eq("history empty again", #undo.history(), 0)
end

-- ── a callback that raises does not stall the queue ──────────────────────────
do
  starts, outcomes, said = {}, {}, {}
  record_windows("C:/Users/x/project/a.txt")
  record_windows("C:/Users/x/project/b.txt")
  undo.restore_last(function()
    error("caller broke")
  end)
  undo.restore_last(on_done)
  exit(starts[1], 0)
  ok("a raising callback is reported", said_text():find("caller broke", 1, true) ~= nil)
  eq("... and the next restore still starts", #starts, 2)
  exit(starts[2], 0)
  eq("... and answers", #outcomes, 1)
end

-- ── a program that never ends: the time limit frees the queue ────────────────
do
  starts, outcomes, said = {}, {}, {}
  local limit = undo.TIMEOUT_MS
  undo.TIMEOUT_MS = 50
  record_windows("C:/Users/x/project/hangs.txt")
  record_windows("C:/Users/x/project/hangs2.txt")
  undo.restore_last(on_done)
  undo.restore_last(on_done)
  vim.wait(5000, function()
    return #outcomes >= 1
  end, 20)
  eq("a hanging PowerShell: answered after the time limit", outcomes[1] and outcomes[1].ok, false)
  ok(
    "... saying it did not finish",
    tostring(outcomes[1] and outcomes[1].err):find("did not finish within", 1, true) ~= nil
  )
  undo.TIMEOUT_MS = limit
  local ps = vim.tbl_filter(function(job)
    return job.argv[#job.argv]:find("hangs", 1, true) ~= nil
  end, starts)
  eq("... and the next U starts", #ps, 2)
  exit(ps[2], 0)
  eq("... and answers", #outcomes, 2)
  -- the first entry is still in the history (not restored): clear it for the cases below
  undo.restore_last(on_done)
  local last = starts[#starts]
  exit(last, 0)
  eq("history empty again", #undo.history(), 0)
end

-- ── a restore that raises before its program starts: answered, queue free ────
do
  starts, outcomes, said = {}, {}, {}
  local platform = require("filetree.util.platform")
  local real_exe = platform.powershell_exe
  platform.powershell_exe = function()
    error("no PowerShell here")
  end
  record_windows("C:/Users/x/project/raises.txt")
  undo.restore_last(on_done)
  platform.powershell_exe = real_exe
  eq("raised before the start: answered", outcomes[1] and outcomes[1].ok, false)
  ok(
    "... with the reason",
    tostring(outcomes[1] and outcomes[1].err):find("no PowerShell here", 1, true) ~= nil
  )
  ok("... nothing left waiting", not undo.busy())
  undo.restore_last(on_done)
  eq("... the next U starts", #starts, 1)
  exit(starts[1], 0)
  eq("history empty again", #undo.history(), 0)
end

-- ── empty history: said at once, nothing started ─────────────────────────────
do
  starts, outcomes, said = {}, {}, {}
  undo.restore_last(on_done)
  eq("empty history: nothing started", #starts, 0)
  eq("... answered", outcomes[1] and outcomes[1].ok, false)
  ok("... and said", said_text():find("Nothing to undo", 1, true) ~= nil)
end

-- ── Linux: gio first, mv when gio fails, both in the background ──────────────
do
  starts, outcomes, said = {}, {}, {}
  gio_present = true
  local name = "note.txt"
  vim.fn.writefile({ "x" }, work .. "/data/Trash/files/" .. name)
  vim.fn.writefile({ "[Trash Info]" }, work .. "/data/Trash/info/" .. name .. ".trashinfo")
  local original = work .. "/project/" .. name
  undo.restore({ platform = "linux", name = name, original_path = original }, on_done)
  eq("linux: gio is started", starts[1] and starts[1].argv[1], "gio")
  eq("... and not waited for", starts[1].waited, false)
  eq("... no outcome yet", #outcomes, 0)
  exit(starts[1], 1)
  eq("gio failed: mv is started next", starts[2] and starts[2].argv[1], "mv")
  eq("... still no outcome", #outcomes, 0)
  exit(starts[2], 0)
  eq("mv done: restored", outcomes[1] and outcomes[1].ok, true)
  eq(
    "... its .trashinfo is gone",
    vim.fn.filereadable(work .. "/data/Trash/info/" .. name .. ".trashinfo"),
    0
  )
  gio_present = false
end

-- ── the trash feature's U tells the tree ─────────────────────────────────────
do
  starts, outcomes, said = {}, {}, {}
  local heard = {}
  vim.api.nvim_create_autocmd("User", {
    pattern = "FiletreeChanged",
    callback = function(ev)
      heard[#heard + 1] = ev.data
    end,
  })
  record_windows("C:/Users/x/project/tree.txt")
  local trash = require("filetree.features.fileops.trash")
  local got
  trash.undo_last(function(o)
    got = o
  end)
  eq("trash.undo_last returns before the program ends", got, nil)
  eq("... nothing announced yet", #heard, 0)
  exit(starts[1], 0)
  eq("... then answers", got, true)
  eq("... and the tree hears of the file", heard[1] and heard[1].to, "C:/Users/x/project/tree.txt")
  eq("... as a create", heard[1] and heard[1].op, "create")
  -- a keymap hands its rhs no callback, or an argument of its own: neither raises
  record_windows("C:/Users/x/project/key.txt")
  said = {}
  trash.undo_last({ "not", "a", "callback" })
  exit(starts[2], 0)
  ok("a non-function argument is ignored", not said_text():find("after the restore", 1, true))
end

vim.fn.delete(work, "rf")
say(("\nfiletree.nvim trash_undo_async_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
