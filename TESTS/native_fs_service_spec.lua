-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_fs_service_spec.lua -- the one place the own tree asks the file system through
-- (`filetree.native.fs.service`): the state of a folder (fresh, loading, dirty, error) along its
-- life, the counts `fs_state()` hands out, and the read that is overtaken by `invalidate`: it is
-- neither cached nor handed out, the folder is read once more first.
--
--   nvim --clean --headless -u NONE -l TESTS/native_fs_service_spec.lua

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
local function say(text)
  io.stdout:write(text, "\n")
end
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
local list = require("filetree.native.fs.list")
local service = require("filetree.native.fs.service")

local base = list.norm(uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_service_%d"):format(base, uv.hrtime() % 1e9)
local function write(rel)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
end
write("a/one.lua")
write("b/two.lua")

---@param entries Filetree.Fs.Entry[]?
---@return string[]
local function names(entries)
  local out = {}
  for _, entry in ipairs(entries or {}) do
    out[#out + 1] = entry.name
  end
  table.sort(out)
  return out
end
---@param fn fun(): boolean
local function wait(fn)
  return vim.wait(3000, fn, 5)
end
---@return { fresh: integer, loading: integer, dirty: integer, error: integer }
local function counts()
  local states = service.states()
  return {
    fresh = states.fresh,
    loading = states.loading,
    dirty = states.dirty,
    error = states.error,
  }
end

service.invalidate()

-- ── the life of a folder ───────────────────────────────────────────────────────
eq("a folder nobody asked for has no state", service.status(dir), nil)
eq("... and none are counted", counts(), { fresh = 0, loading = 0, dirty = 0, error = 0 })
service.invalidate(dir)
eq("invalidating it gives it none", service.status(dir), nil)

local answer = nil
service.list(dir, function(entries)
  answer = entries
end)
eq("asked for: loading", service.status(dir), "loading")
eq("... it is among the folders being read", service.reading(), { dir })
eq("... nothing is cached yet", service.cached(dir), nil)
ok(
  "(the read answers)",
  wait(function()
    return answer ~= nil
  end)
)
eq("answered: fresh", service.status(dir), "fresh")
eq("... with its entries", names(answer), { "a", "b" })
eq("... which are the cached ones", service.cached(dir), answer)
eq("... nothing is being read", service.reading(), {})

local scans = list.stats.scans
local again = nil
service.list(dir, function(entries)
  again = entries
end)
eq("a fresh folder answers at once", again, answer)
eq("... without a read", list.stats.scans, scans)

service.invalidate(dir)
eq("invalidated: dirty", service.status(dir), "dirty")
eq("... and no longer cached", service.cached(dir), nil)
write("c/three.lua")
eq("read now: the folder as it is", names((service.list_sync(dir))), { "a", "b", "c" })
eq("... and fresh again", service.status(dir), "fresh")

-- ── a folder that cannot be read ───────────────────────────────────────────────
local gone = dir .. "/gone"
local entries, err = service.list_sync(gone)
eq("a folder that is not there: no entries", entries, nil)
ok("... and a reason", type(err) == "string" and err ~= "")
local state, why = service.status(gone)
eq("... its state is error", state, "error")
eq("... with that reason", why, err)
eq("the counts name it", counts(), { fresh = 1, loading = 0, dirty = 0, error = 1 })
eq("... and list it with the reason", service.states().errors, { { dir = gone, error = err } })
local late, late_err = false, nil
service.list(gone, function(got, got_err)
  late, late_err = got == nil, got_err
end)
ok("asked again without blocking: read again, the same answer", wait(function()
  return late
end) and type(late_err) == "string")
eq("... still error", (service.status(gone)), "error")
vim.fn.mkdir(gone, "p")
eq("the folder is there now: readable", names((service.list_sync(gone))), {})
eq("... fresh, the reason is gone", { service.status(gone) }, { "fresh" })

-- ── fs_state() hands the counts out ────────────────────────────────────────────
local fs = require("filetree").fs_state()
eq("fs_state().folders: the counts", { fs.folders.fresh, fs.folders.error }, { 2, 0 })

-- ── a read that is overtaken ───────────────────────────────────────────────────
-- The read of `a` is held back: it answers with what the folder held BEFORE a file was added and
-- the folder was invalidated. That answer must neither be cached nor handed out.
local a = dir .. "/a"
local real_scandir = uv.fs_scandir
local held = nil
local before = real_scandir(a)
uv.fs_scandir = function(path, cb)
  if cb and path == a and not held then
    held = cb
    return
  end
  return real_scandir(path, cb)
end
local overtaken = nil
service.list(a, function(got)
  overtaken = got
end)
ok("(the read of the folder is held back)", held ~= nil)
write("a/new.lua")
service.invalidate(a)
eq("invalidated while it is read: still loading", service.status(a), "loading")
local second = nil
service.list(a, function(got)
  second = got
end)
scans = list.stats.scans
held(nil, before)
ok(
  "(both who wait are answered)",
  wait(function()
    return overtaken ~= nil and second ~= nil
  end)
)
uv.fs_scandir = real_scandir
eq(
  "the one who asked first gets the folder as it is now",
  names(overtaken),
  { "new.lua", "one.lua" }
)
eq("... the one who asked after the change too", names(second), { "new.lua", "one.lua" })
eq("... that cost the stale read and one more", list.stats.scans, scans + 2)
eq("... and what is cached is the new listing", names(service.cached(a)), { "new.lua", "one.lua" })
eq("... the folder is fresh", service.status(a), "fresh")

-- ── forget everything ──────────────────────────────────────────────────────────
service.invalidate()
eq(
  "everything forgotten: no state is left",
  counts(),
  { fresh = 0, loading = 0, dirty = 0, error = 0 }
)
eq("... as if the folder had never been asked for", service.status(dir), nil)

-- ── deep and watch come through the service ────────────────────────────────────
ok("service.deep is the deep search", service.deep == require("filetree.native.fs.deep"))
ok("service.watch is the watcher", service.watch == require("filetree.native.fs.watch"))
eq("an unknown key is nil", service.nothing, nil)

vim.fn.delete(dir, "rf")
say(("\nfiletree.nvim native_fs_service_spec: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
