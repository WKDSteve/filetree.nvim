-- TESTS/live/trash_macos.lua -- the macOS trash backends against the real tools, on a real Mac.
--
-- Not part of the suite (no `_spec` name): it really trashes files and drives Finder, which a headless
-- machine may refuse. Run by .github/workflows/macos-trash-live.yml, by hand there:
--
--   gh workflow run macos-trash-live.yml
--
-- Locally on a Mac:
--
--   nvim --clean --headless -u NONE -l TESTS/live/trash_macos.lua cli
--   nvim --clean --headless -u NONE -l TESTS/live/trash_macos.lua applescript
--
-- `cli` needs a `trash` executable. `applescript` hides any `trash` from platform.lua's executable()
-- check, the one stub here; osascript and Finder are real.
--
-- Each line says PASS, FAIL or UNVERIFIED. UNVERIFIED means this machine could not show the result
-- (no access to ~/.Trash, say), which is not a pass. Every spawn is logged with its exit code and stderr,
-- because platform.lua keeps neither.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(root)
for _, candidate in ipairs({
  vim.env.LIB_NVIM_DIR or "",
  vim.fn.fnamemodify(root, ":h") .. "/lib.nvim",
}) do
  if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(candidate)
    break
  end
end

if vim.fn.has("mac") ~= 1 then
  print("n/a  this checks the macOS backends")
  return
end

local mode = arg and arg[1] or "cli"
assert(mode == "cli" or mode == "applescript", "mode is cli or applescript, got " .. tostring(mode))

local uv = vim.uv or vim.loop
-- Above platform.lua's own limit for the three items of a blocked batch.
local TIMEOUT_MS = 120000

local failed, unverified = 0, 0
local function pass(name)
  print("PASS        " .. name)
end
local function fail(name, detail)
  failed = failed + 1
  print("FAIL        " .. name .. (detail and ("  -- " .. detail) or ""))
end
local function unknown(name, detail)
  unverified = unverified + 1
  print("UNVERIFIED  " .. name .. (detail and ("  -- " .. detail) or ""))
end

-- Records and logs every process the backend starts.
local spawns = {}
local real_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(argv, opts, on_exit)
  spawns[#spawns + 1] = argv
  print(("spawn: %s (%d args)"):format(argv[1], #argv - 1))
  return real_system(argv, opts, function(res)
    print(
      ("  exit %d, signal %d, stderr: %s"):format(
        res.code,
        res.signal or 0,
        vim.trim(res.stderr or "")
      )
    )
    on_exit(res)
  end)
end

if mode == "applescript" then
  local real_executable = vim.fn.executable
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.executable = function(name)
    if name == "trash" then return 0 end
    return real_executable(name)
  end
end

local platform = require("filetree.features.fileops.trash.platform")
print(
  ("mode %s, backend: %s, trash on PATH: %s"):format(
    mode,
    platform.backend_name(),
    vim.fn.exepath("trash")
  )
)

-- Below $HOME so the items land in ~/.Trash and not in another volume's trash folder.
local stamp = ("%d-%d"):format(os.time(), uv.os_getpid())
local work = ("%s/ft-trash-live-%s"):format(vim.env.HOME, stamp)
vim.fn.mkdir(work, "p")

---@param name string
---@return string path  A new file below `work`, its name unique to this run.
local function new_file(name)
  local path = ("%s/%s-%s"):format(work, stamp, name)
  vim.fn.writefile({ "x" }, path)
  return path
end

---@param path string
---@return boolean
local function exists(path)
  return uv.fs_lstat(path) ~= nil
end

---@param paths string[]
---@return TrashResult[]? results  nil when no answer came within the limit.
local function batch(paths)
  spawns = {}
  local results
  platform.send_batch(paths, function(r)
    results = r
  end)
  vim.wait(TIMEOUT_MS, function()
    return results ~= nil
  end, 50)
  return results
end

---Is each of `paths` in ~/.Trash? Reported, not assumed: the folder may be closed to this process.
---@param name string
---@param paths string[]
local function check_in_trash(name, paths)
  local trash = vim.env.HOME .. "/.Trash"
  local handle, err = uv.fs_scandir(trash)
  if not handle then
    return unknown(name .. ": in ~/.Trash", "cannot list it: " .. tostring(err))
  end
  local present = {}
  for entry in
    function()
      return (uv.fs_scandir_next(handle))
    end
  do
    present[entry] = true
  end
  local missing = {}
  for _, p in ipairs(paths) do
    local base = vim.fn.fnamemodify(p, ":t")
    if not present[base] then missing[#missing + 1] = base end
  end
  if #missing == 0 then
    pass(name .. ": in ~/.Trash")
  else
    unknown(name .. ": in ~/.Trash", "not listed: " .. table.concat(missing, " | "))
  end
end

---@param name string
local function check_one_call(name)
  local want = mode == "cli" and "trash" or "osascript"
  if #spawns == 1 and spawns[1][1] == want then
    pass(name .. ": one " .. want .. " call for the batch")
  else
    fail(name .. ": one " .. want .. " call for the batch", #spawns .. " spawn(s)")
  end
end

---A whole batch that is expected to succeed.
---@param name string
---@param paths string[]
local function plain_batch(name, paths)
  local results = batch(paths)
  if not results then return fail(name, "no answer within " .. TIMEOUT_MS .. " ms") end
  check_one_call(name)
  for i, p in ipairs(paths) do
    local base = vim.fn.fnamemodify(p, ":t")
    if results[i].ok and not exists(p) then
      pass(name .. ": gone, reported ok: " .. base)
    else
      fail(
        name .. ": " .. base,
        ("ok=%s err=%s still there=%s"):format(
          tostring(results[i].ok),
          tostring(results[i].err),
          tostring(exists(p))
        )
      )
    end
  end
  check_in_trash(name, paths)
end

-- 1. Several files.
plain_batch("plain names", { new_file("a.txt"), new_file("b.txt"), new_file("c.txt") })

-- 2. A folder among them.
local folder = new_file("folder-placeholder")
vim.fn.delete(folder)
vim.fn.mkdir(folder, "p")
vim.fn.writefile({ "x" }, folder .. "/inner.txt")
plain_batch("a folder in the batch", { new_file("d.txt"), folder })

-- 3. Names AppleScript has to escape.
plain_batch("spaces, quote, backslash", {
  new_file("with space.txt"),
  new_file('with"quote.txt'),
  new_file("with\\backslash.txt"),
  new_file('ends-with-both"\\'),
})

---One item of the batch cannot be trashed; only that one may be reported, the rest must go.
---@param name string
---@param blocked string
---@param others string[]
---@param undo fun()
local function blocked_batch(name, blocked, others, undo)
  local paths = { others[1], blocked, others[2] }
  local results = batch(paths)
  if not results then
    undo()
    return fail(name, "no answer within " .. TIMEOUT_MS .. " ms")
  end
  check_one_call(name)
  if results[2].ok == false and exists(blocked) then
    pass(name .. ": the blocked item is reported, err: " .. tostring(results[2].err))
  else
    fail(
      name .. ": the blocked item is reported",
      ("ok=%s still there=%s"):format(tostring(results[2].ok), tostring(exists(blocked)))
    )
  end
  for _, i in ipairs({ 1, 3 }) do
    local base = vim.fn.fnamemodify(paths[i], ":t")
    if results[i].ok and not exists(paths[i]) then
      pass(name .. ": not blocked by it: " .. base)
    else
      fail(
        name .. ": not blocked by it: " .. base,
        ("ok=%s still there=%s"):format(tostring(results[i].ok), tostring(exists(paths[i])))
      )
    end
  end
  undo()
end

-- 4. A locked file (the Finder "Locked" flag).
local locked = new_file("locked.txt")
vim.fn.system({ "chflags", "uchg", locked })
if vim.v.shell_error ~= 0 then
  unknown("locked file", "chflags uchg failed")
else
  blocked_batch("locked file", locked, { new_file("e.txt"), new_file("f.txt") }, function()
    vim.fn.system({ "chflags", "nouchg", locked })
  end)
end

-- 5. Permission taken away: the file's folder is read-only, so nothing can move it out.
local closed_dir = ("%s/%s-closed"):format(work, stamp)
vim.fn.mkdir(closed_dir, "p")
local closed = closed_dir .. "/" .. stamp .. "-closed.txt"
vim.fn.writefile({ "x" }, closed)
vim.fn.system({ "chmod", "555", closed_dir })
blocked_batch(
  "read-only parent folder",
  closed,
  { new_file("g.txt"), new_file("h.txt") },
  function()
    vim.fn.system({ "chmod", "755", closed_dir })
  end
)

vim.fn.delete(work, "rf")
print(
  ("\nfiletree.nvim trash_macos (%s): %d failed, %d unverified"):format(mode, failed, unverified)
)
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
