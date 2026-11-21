-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/git_status_shared_spec.lua -- one `git status` per occasion (filetree.util.git_status):
-- requests without a known change share the running status or take an answer of a moment ago, a
-- change forces a newer one (and the older one's waiters get it too), a failure is not kept, and a
-- request can be dropped. Then the feature git_status: opening the tree (setup, then its buffer)
-- runs git once, not twice; a write runs it again; and the view git reuses the badges' answer but
-- asks again after `ga`. No real git: `vim.system` is a stand-in that counts the status starts and
-- whose `wait()` throws.
--
--   nvim --clean --headless -u NONE -l TESTS/git_status_shared_spec.lua

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

-- The stand-in of vim.system: records each start, runs nothing, its wait() throws.
---@type { argv: string[], on_exit: fun(r: table), killed: boolean, done: boolean }[]
local starts = {}
vim.system = function(argv, _, on_exit)
  local job = { argv = argv, on_exit = on_exit, killed = false, done = false }
  starts[#starts + 1] = job
  return {
    pid = 4242,
    wait = function()
      error("the editor waited for " .. argv[1])
    end,
    kill = function()
      job.killed = true
    end,
    is_closing = function()
      return job.done
    end,
  }
end

---The `git status` starts so far.
local function statuses()
  local out = {}
  for _, job in ipairs(starts) do
    if vim.tbl_contains(job.argv, "status") then out[#out + 1] = job end
  end
  return out
end

---How many stops were asked for: a `kill()` of a job, or (Windows) a `taskkill /PID` the stand-in
---recorded instead of running it.
local function stops()
  local n = 0
  for _, job in ipairs(starts) do
    if job.killed then n = n + 1 end
    if vim.tbl_contains(job.argv, "/PID") then n = n + 1 end
  end
  return n
end

---Let a stand-in end and run what was scheduled.
local function exit(job, code, stdout)
  job.done = true
  job.on_exit({ code = code or 0, signal = 0, stdout = stdout or "", stderr = "" })
  vim.wait(30, function()
    return false
  end)
end
local function settle()
  vim.wait(30, function()
    return false
  end)
end

local shared = require("filetree.util.git_status")
local clock = 1000
shared.now = function()
  return clock
end

local work = vim.fs.normalize(vim.fn.tempname()) .. "_gitshared"
local repo = work .. "/repo"
vim.fn.mkdir(repo .. "/.git", "p")
vim.fn.mkdir(repo .. "/src", "p")

-- ── the shared status ────────────────────────────────────────────────────────
do
  starts = {}
  local got = {}
  shared.status({ dir = repo }, nil, function(map)
    got[#got + 1] = map
  end)
  shared.status({ dir = repo .. "/" }, nil, function(map)
    got[#got + 1] = map
  end)
  eq("two requests without a change: one git status", #statuses(), 1)
  eq("... nobody answered yet", #got, 0)
  exit(statuses()[1], 0, " M src/a.lua\0")
  eq("... both answered by it", #got, 2)
  eq("... with its map", got[1]["src/a.lua"] and got[1]["src/a.lua"].code, " M")

  clock = clock + 500
  shared.status({ dir = repo }, nil, function(map)
    got[#got + 1] = map
  end)
  settle()
  eq("half a second later, no change: the answer is reused", #statuses(), 1)
  eq("... and handed over", #got, 3)

  clock = clock + shared.FRESH_MS
  shared.status({ dir = repo }, nil, function(map)
    got[#got + 1] = map
  end)
  eq("older than FRESH_MS: a new status", #statuses(), 2)
  exit(statuses()[2], 0, "")
  eq("... answered", #got, 4)

  -- a change: whatever started before it is too old
  local change = clock + 1
  clock = clock + 1
  shared.status({ dir = repo }, change, function() end)
  eq("a known change: a new status at once", #statuses(), 3)
end

-- ── a newer request takes over the older waiters ─────────────────────────────
do
  shared._reset()
  starts = {}
  local first, second
  shared.status({ dir = repo }, nil, function(map)
    first = map
  end)
  clock = clock + 10
  local stops_before = stops()
  shared.status({ dir = repo }, clock, function(map)
    second = map
  end)
  eq("a change while one runs: a second status", #statuses(), 2)
  ok("... the first is stopped", stops() > stops_before)
  exit(statuses()[1], 1) -- a killed process may still report
  eq("... and its late answer goes nowhere", first, nil)
  exit(statuses()[2], 0, "?? new.lua\0")
  ok("... both waiters get the newer answer", first ~= nil and second ~= nil and first == second)
end

-- ── a failure is not kept; a dropped request gets nothing ────────────────────
do
  shared._reset()
  starts = {}
  local got_err
  shared.status({ dir = repo }, nil, function(map, err)
    got_err = { map = map, err = err }
  end)
  exit(statuses()[1], 128)
  eq("failed status: no map", got_err.map, nil)
  shared.status({ dir = repo }, nil, function() end)
  eq("... and the next request starts again", #statuses(), 2)

  local called = false
  local req = shared.status({ dir = repo .. "/other" }, nil, function()
    called = true
  end)
  local stops_before = stops()
  req.stop()
  ok("dropping the only waiter stops the status", stops() > stops_before)
  exit(statuses()[3], 0)
  eq("... and nothing is answered", called, false)

  -- ignored files are another question
  shared.status({ dir = repo, ignored = true }, nil, function() end)
  ok("--ignored is asked apart", vim.tbl_contains(statuses()[#statuses()].argv, "--ignored"))
end

-- ── a status that raises before git runs is not joined later ─────────────────
do
  shared._reset()
  starts = {}
  local lib_git = require("lib.nvim.git")
  local real = lib_git.status_porcelain_async
  lib_git.status_porcelain_async = function()
    error("cannot start")
  end
  local got = "none"
  shared.status({ dir = repo }, nil, function(map, err)
    got = { map = map, err = err }
  end)
  lib_git.status_porcelain_async = real
  settle()
  ok("raised at the start: answered", got ~= "none" and got.map == nil)
  ok(
    "... with the reason",
    type(got) == "table" and tostring(got.err):find("cannot start", 1, true) ~= nil
  )
  shared.status({ dir = repo }, nil, function() end)
  eq("... and the next request starts git instead of joining the dead one", #statuses(), 1)
  exit(statuses()[1], 0)
end

-- ── the feature: opening the tree runs git once ──────────────────────────────
shared._reset()
starts = {}
vim.cmd.cd(vim.fn.fnameescape(repo))
local tree_attach = require("filetree.util.tree_attach")
tree_attach.install({ filetypes = { "filetree_spec_tree" } })
local git_status = require("filetree.features.git.git_status")
local adapter = {
  name = "spec",
  get_bufnr = function()
    return -1
  end,
}
do
  git_status.setup({ enabled = true, debounce_ms = 0 }, adapter)
  eq("setup asks git once", #statuses(), 1)
  -- the tree buffer attaches right after (its FileType), as when the tree opens
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "filetree_spec_tree"
  vim.wait(100, function()
    return false
  end)
  eq("the tree buffer attaching does not ask again", #statuses(), 1)
  exit(statuses()[1], 0, " M src/a.lua\0")

  clock = clock + 100
  vim.api.nvim_exec_autocmds("BufWritePost", { pattern = repo .. "/src/a.lua" })
  vim.wait(100, function()
    return #statuses() >= 2
  end)
  eq("a write asks again (a change)", #statuses(), 2)
  exit(statuses()[2], 0, "")

  clock = clock + 100
  vim.api.nvim_exec_autocmds("FocusGained", {})
  vim.wait(100, function()
    return #statuses() >= 3
  end)
  eq("focus back asks again (a terminal may have changed the repo)", #statuses(), 3)
  exit(statuses()[3], 0, "")

  clock = clock + 100
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf2].filetype = "filetree_spec_tree"
  vim.wait(100, function()
    return false
  end)
  eq("entering the tree again right after: no new git", #statuses(), 3)
  git_status.refresh()
  eq("an explicit refresh always asks", #statuses(), 4)
  exit(statuses()[4], 0, "")

  -- a change only the view git hears (a file operation: FiletreeChanged), then the tree buffer is
  -- entered: the badges must not take the answer from before it
  local unsubscribe = require("filetree.native.source.git").source().subscribe({}, {
    reset = function() end,
  })
  clock = clock + 100
  vim.api.nvim_exec_autocmds("User", { pattern = "FiletreeChanged", data = { op = "create" } })
  clock = clock + 10
  local buf3 = vim.api.nvim_create_buf(false, true)
  vim.bo[buf3].filetype = "filetree_spec_tree"
  vim.wait(100, function()
    return #statuses() >= 5
  end)
  eq("a change heard by the view only: the badges ask again too", #statuses(), 5)
  exit(statuses()[5], 0, "")
  unsubscribe()
  git_status.teardown()
end

-- ── the view git reuses the badges' answer, and asks after `ga` ──────────────
do
  shared._reset()
  starts = {}
  local source = require("filetree.native.source.git").source()
  local root_node = source.root({ root = repo })
  local got
  -- the badges asked a moment ago
  shared.status({ dir = repo }, nil, function() end)
  root_node.children(nil, function(nodes)
    got = nodes
  end)
  eq("view git while the badges' status runs: no second git", #statuses(), 1)
  exit(statuses()[1], 0, "?? src/new.lua\0")
  ok("... it gets the groups", got ~= nil and got[1].label == "Untracked")

  -- `ga`: git add, then the view asks again
  local refreshed = 0
  local stage = vim.iter(source.actions):find(function(a)
    return a.name == "git.stage"
  end)
  clock = clock + 50
  stage.run({ { path = repo .. "/src/new.lua", label = "src/new.lua" } }, {
    tree = {
      refresh = function()
        refreshed = refreshed + 1
        root_node.children(nil, function(nodes)
          got = nodes
        end)
      end,
    },
  })
  local add = starts[#starts]
  ok("ga starts git add", vim.tbl_contains(add.argv, "add"))
  clock = clock + 50
  exit(add, 0)
  eq("... then the view refreshes", refreshed, 1)
  eq("... with a new status (the index changed)", #statuses(), 2)
  exit(statuses()[2], 0, "A  src/new.lua\0")
  ok("... showing it staged", got ~= nil and got[1].label == "Staged")
end

vim.fn.delete(work, "rf")
say(("\nfiletree.nvim git_status_shared_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
