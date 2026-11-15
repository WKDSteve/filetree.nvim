-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_helper_spec.lua -- the helper process of the own tree (`native.fs.helper`, helper/):
-- which program is used and when none is (off, the workstation, a path that is not there); the deep
-- listing through it lists what the Lua walk lists and stops when cancelled; a folder's size counts
-- everything; on Linux its watch follows a closed folder and a folder made later; a helper that ends
-- hands an open listing to the next tier without a path twice, says so once, and its watches go back
-- to libuv handles.
--
--   nvim --clean --headless -u NONE -l TESTS/native_helper_spec.lua
--
-- The program: $FILETREE_HELPER_TEST, else helper/target/release/ or helper/bin/ of this repository
-- (`cargo build --release --manifest-path helper/Cargo.toml`). Without one the cases that need it say
-- n/a; the CI builds it on every system.

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
local function na(name, why)
  say(("  n/a  %s (%s)"):format(name, why))
end
local function settle(ms)
  vim.wait(ms or 100, function()
    return false
  end)
end

local uv = vim.uv
require("filetree.config").setup({})
local list = require("filetree.native.fs.list")
local deep = require("filetree.native.fs.deep")
local watch = require("filetree.native.fs.watch")
local helper = require("filetree.native.fs.helper")

-- ── which program, and when none ───────────────────────────────────────────────
do
  helper.configure(false)
  local exe, why = helper.find()
  eq("native.fs.helper = false: no program", exe, nil)
  ok("... and it says so: " .. tostring(why), why and why:find("false", 1, true) ~= nil)
  ok("... and the deep listing does not name the helper", (deep.tier()) ~= "helper")

  helper.configure("/no/such/filetree-helper")
  exe, why = helper.find()
  eq("a path that is not there: no program", exe, nil)
  ok("... and it names the path: " .. tostring(why), why and why:find("/no/such", 1, true) ~= nil)

  local role = vim.env.NVIM_MACHINE_ROLE
  vim.env.NVIM_MACHINE_ROLE = "Workstation"
  helper.configure("auto")
  exe, why = helper.find()
  eq('"auto" on the workstation: no program, whatever is installed', exe, nil)
  ok("... and it says why: " .. tostring(why), why and why:find("workstation", 1, true) ~= nil)
  local built, message = helper.build()
  eq("... and build() refuses there", built, false)
  ok("... saying so: " .. message, message:find("workstation", 1, true) ~= nil)
  vim.env.NVIM_MACHINE_ROLE = role

  helper.configure("auto")
  if not uv.fs_stat(helper.default_path()) then
    exe, why = helper.find()
    eq('"auto" without helper/bin/: no program', exe, nil)
    ok(
      "... and it says where it looked: " .. tostring(why),
      why and why:find("helper/bin", 1, true) ~= nil
    )
  else
    na('"auto" without helper/bin/', "helper/bin/ holds a program on this machine")
  end

  eq(
    "the release name for Linux on x86_64",
    helper.asset_name({ sysname = "Linux", machine = "x86_64" }),
    "filetree-helper-linux-x86_64"
  )
  eq(
    "... for Windows",
    helper.asset_name({ sysname = "Windows_NT", machine = "AMD64" }),
    "filetree-helper-windows-x86_64.exe"
  )
  eq(
    "... for macOS on Apple silicon",
    helper.asset_name({ sysname = "Darwin", machine = "arm64" }),
    "filetree-helper-macos-aarch64"
  )
  eq(
    "... none for a system the CI does not build for",
    helper.asset_name({ sysname = "Linux", machine = "armv7l" }),
    nil
  )
end

-- ── the program for the rest ───────────────────────────────────────────────────
local exe = vim.env.FILETREE_HELPER_TEST
if not exe or exe == "" then
  for _, candidate in ipairs({
    root .. "/helper/target/release/" .. helper.binary_name(),
    root .. "/helper/bin/" .. helper.binary_name(),
  }) do
    if uv.fs_stat(candidate) then
      exe = candidate
      break
    end
  end
end

local base = list.norm(uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_helper_%d"):format(base, uv.hrtime() % 1e9)

if not exe or not uv.fs_stat(exe) then
  na(
    "the helper process",
    "no program built (cargo build --release --manifest-path helper/Cargo.toml)"
  )
else
  helper.configure(exe)
  say("  info program " .. exe)

  -- a fixture without ignore rules: every tier must list the same files
  local function mkfile(rel, text)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ text or "x" }, path, "b")
  end
  for i = 1, 25 do
    for j = 1, 100 do
      mkfile(("d%02d/f%03d.txt"):format(i, j))
    end
  end
  mkfile("closed/deeper/keep.txt")
  mkfile(".git/HEAD", "ref")

  local function listing(tier)
    local found, done = {}, nil
    local cancel = deep.files(dir, function(batch)
      vim.list_extend(found, batch)
    end, function(success)
      done = success
    end, { tier = tier })
    vim.wait(10000, function()
      return done ~= nil
    end, 5)
    table.sort(found)
    return found, done, cancel
  end

  eq("the deep listing names the helper as its tier", (deep.tier()), "helper")
  local by_lua = listing("lua")
  local by_helper, done = listing("helper")
  eq("the helper lists what the Lua walk lists (2501 files, never .git)", #by_helper, #by_lua)
  eq("... the same paths", by_helper, by_lua)
  eq("... and says it is done", done, true)

  -- cancelled before any answer: nothing more reaches the caller
  do
    local batches, finished = 0, false
    local cancel = deep.files(dir, function()
      batches = batches + 1
    end, function()
      finished = true
    end, { tier = "helper" })
    cancel()
    settle(300)
    eq("a cancelled listing hands over nothing", batches, 0)
    eq("... and never says it is done", finished, false)
  end

  -- the size of a folder counts everything, `.git` too
  do
    local answer
    helper.request("size", dir, function(kind, payload)
      answer = { kind = kind, payload = payload }
      return false
    end)
    vim.wait(5000, function()
      return answer ~= nil
    end, 5)
    local want_files, want_bytes = 0, 0
    for _, path in ipairs(by_lua) do
      want_files = want_files + 1
      want_bytes = want_bytes + uv.fs_stat(path).size
    end
    -- `.git/HEAD` is not in the listing, but in the size
    want_files = want_files + 1
    want_bytes = want_bytes + uv.fs_stat(dir .. "/.git/HEAD").size
    eq("the size of a folder: every file", answer and answer.payload.files, want_files)
    eq("... and every byte", answer and answer.payload.bytes, want_bytes)

    -- the size column asks the helper, not `du` or PowerShell
    local spawned = {}
    local live_procs = require("filetree.util.live_procs")
    local real_spawn = live_procs.spawn
    ---@diagnostic disable-next-line: duplicate-set-field
    live_procs.spawn = function(cmd, ...)
      spawned[#spawned + 1] = cmd[1]
      return real_spawn(cmd, ...)
    end
    local bytes
    require("filetree.features.ui.size_info")._query_dir_size(dir, function(b)
      bytes = b
    end)
    vim.wait(5000, function()
      return bytes ~= nil
    end, 5)
    live_procs.spawn = real_spawn
    eq("the size column gets the size of a folder from the helper", bytes, want_bytes)
    eq("... without starting a process", spawned, {})
  end

  -- the watch: on Linux through the helper, recursive. Windows and macOS watch recursively with libuv;
  -- there the helper's watch is checked as Linux would use it (notify watches recursively everywhere)
  do
    if watch.native_recursive then
      eq(
        "Windows and macOS: libuv watches recursively, the helper does not watch",
        watch.by_helper(),
        false
      )
    end
    local native_recursive = watch.native_recursive
    watch.native_recursive = false
    local reported = {}
    local unsubscribe = watch.subscribe(function(dirs)
      for _, changed in ipairs(dirs) do
        reported[changed] = true
      end
    end)
    local unwatch = watch.watch(dir)
    settle(400)
    do
      eq("without recursive libuv handles the helper watches", watch.by_helper(), true)
      eq("... so a folder below the root is covered", watch.recursive, true)
      eq("... with one watch of the helper", watch.state().watchers[1].helper, true)
      mkfile("closed/deeper/new.txt")
      vim.fn.mkdir(dir .. "/later/sub", "p")
      settle(300)
      mkfile("later/sub/new.txt")
      vim.wait(3000, function()
        return reported[dir .. "/closed/deeper"] and reported[dir .. "/later/sub"]
      end, 20)
      ok(
        "a change in a closed folder two levels down is reported",
        reported[dir .. "/closed/deeper"]
      )
      ok("... and one in a folder made after the watch started", reported[dir .. "/later/sub"])
      -- the helper watches only once it has read the request: what comes right after the call is
      -- not lost (a file operation releases and resumes the watches around it)
      local resume = watch.release(dir)
      resume()
      reported = {}
      mkfile("right_after_resume.txt")
      vim.wait(3000, function()
        return reported[dir]
      end, 20)
      ok("a file made right after the watch was opened again is reported", reported[dir])
      vim.fn.delete(dir .. "/right_after_resume.txt")
    end
    unwatch()
    eq("the watch is given back", watch.count(), 0)

    -- the helper cannot watch a folder (on Linux: the inotify limit): handles per folder again
    do
      local told = {}
      local notify = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level)
        if tostring(msg):find("watched one by one", 1, true) then
          told[#told + 1] = { msg = msg, level = level }
        end
      end
      local real_request = helper.request
      local gen
      ---@diagnostic disable-next-line: duplicate-set-field
      helper.request = function(...)
        gen = real_request(...)
        return gen
      end
      local unwatch_err = watch.watch(dir)
      helper.request = real_request
      eq("a watch of the helper", watch.state().watchers[1].helper, true)
      -- answered in the helper's place: what notify says when inotify has no watch left
      helper.on("error", gen, "OS file watch limit reached")
      settle(100)
      local state = watch.state()
      eq("its error leaves the folder to a libuv handle", state.watchers[1].helper, nil)
      ok("... the error is kept: " .. tostring(state.helper_failed), state.helper_failed ~= nil)
      eq("... no more watches of the helper in this session", watch.by_helper(), false)
      eq("... so folders are watched one by one", watch.recursive, false)
      eq("... and it is said once, as a warning", #told == 1 and told[1].level, vim.log.levels.WARN)
      reported = {}
      mkfile("after_the_error.txt")
      vim.wait(3000, function()
        return reported[dir]
      end, 20)
      ok("... and the folder is still followed", reported[dir])
      vim.fn.delete(dir .. "/after_the_error.txt")
      vim.notify = notify
      unwatch_err()
      watch.stop_all()
      eq("stop_all forgets the error", watch.by_helper(), true)
    end
    unsubscribe()
    watch.native_recursive = native_recursive
    -- what the watch case made is not part of the listings below
    vim.fn.delete(dir .. "/closed/deeper/new.txt")
    vim.fn.delete(dir .. "/later", "rf")
  end

  -- the helper ends while a listing is on its way: the next tier lists the rest, no path twice
  do
    local found, finished = {}, nil
    -- the generation of the listing, to answer in the helper's place before it does
    local real_request = helper.request
    local gen
    ---@diagnostic disable-next-line: duplicate-set-field
    helper.request = function(...)
      gen = real_request(...)
      return gen
    end
    deep.files(dir, function(batch)
      vim.list_extend(found, batch)
    end, function(success)
      finished = success
    end, { tier = "helper" })
    helper.request = real_request
    -- a first batch of 100 paths arrives, then the helper is gone (stopped: the same path as an end)
    helper.on("files", gen, vim.list_slice(by_lua, 1, 100))
    helper.stop()
    vim.wait(10000, function()
      return finished ~= nil
    end, 5)
    eq("... and the listing says it is done", finished, true)
    local seen, twice = {}, 0
    for _, path in ipairs(found) do
      if seen[path] then twice = twice + 1 end
      seen[path] = true
    end
    eq(
      "a listing the helper left on the way is finished by the next tier",
      vim.tbl_count(seen),
      #by_lua
    )
    eq("... without a path twice", twice, 0)
  end

  -- the helper really ends (killed): the rest of the session runs on the Lua tiers, said once
  do
    local told = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      if tostring(msg):find("helper process", 1, true) then
        told[#told + 1] = { msg = msg, level = level }
      end
    end
    local unwatch = watch.watch(dir)
    local pid
    vim.wait(3000, function()
      pid = helper.state().pid
      return pid ~= nil or watch.native_recursive
    end, 10)
    if not pid then
      -- Windows and macOS: no watch of the helper; one listing starts it
      listing("helper")
      pid = helper.state().pid
    end
    ok("the helper runs: pid " .. tostring(pid), pid ~= nil)
    -- only the process this spec started
    uv.kill(pid, "sigkill")
    vim.wait(5000, function()
      return helper.state().lost ~= nil
    end, 10)
    settle(100)
    ok("its end is noticed: " .. tostring(helper.state().lost), helper.state().lost ~= nil)
    eq("... and said once", #told, 1)
    eq("... as a warning", told[1] and told[1].level, vim.log.levels.WARN)
    ok("the deep listing goes on without it", (deep.tier()) ~= "helper")
    local after = listing()
    eq("... and still lists everything", #after, #by_lua)
    if not watch.native_recursive then
      local state = watch.state()
      eq(
        "Linux: the watch is a libuv handle again",
        state.watchers[1] and state.watchers[1].helper,
        nil
      )
      eq("... and the watches are per folder again", watch.recursive, false)
    end
    listing("helper")
    eq("asked again, it is not started again", helper.state().pid, nil)
    eq("... and not said again", #told, 1)
    vim.notify = notify
    unwatch()
  end
end

helper.configure(nil)
watch.stop_all()
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_helper_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
