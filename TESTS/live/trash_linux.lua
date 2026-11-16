-- TESTS/live/trash_linux.lua -- the Linux trash backends against the real tools, on a real Linux.
--
-- Not part of the suite (no `_spec` name): it really trashes files. Run by
-- .github/workflows/linux-trash-live.yml (Ubuntu), by hand there:
--
--   gh workflow run linux-trash-live.yml
--
-- Locally on Linux (not WSL: there the trash goes through the Windows recycle bin):
--
--   nvim --clean --headless -u NONE -l TESTS/live/trash_linux.lua gio
--   nvim --clean --headless -u NONE -l TESTS/live/trash_linux.lua trash-put
--   nvim --clean --headless -u NONE -l TESTS/live/trash_linux.lua xdg
--
-- In WSL (`wsl` mode) a file below /mnt/<drive> goes to the Windows recycle bin (wslpath and
-- PowerShell), a file of the Linux file system to the Linux trash (a wsl.localhost path has no
-- recycle bin, Windows would delete it for good): an ordinary delete and its undo, for both.
--
--   wsl.exe -e nvim --clean --headless -u NONE -l TESTS/live/trash_linux.lua wsl
--
-- `gio` needs gio, `trash-put` needs trash-cli. Each mode hides the tools platform.lua would prefer
-- over it from its executable() check, the one stub here; the tool that runs is real. `xdg` hides
-- both, so the batch is one `mv` into the XDG trash folder.
--
-- Each line says PASS, FAIL or UNVERIFIED. UNVERIFIED means this machine could not show the result,
-- which is not a pass. Every spawn is logged with its exit code and stderr, because platform.lua keeps
-- neither.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(root)
-- lib.nvim, and ui.nvim for the trash history's restore (it asks through ui.kit).
for _, dep in ipairs({ { "LIB_NVIM_DIR", "lib.nvim", "lib" }, { "UI_NVIM_DIR", "ui.nvim", "ui" } }) do
  for _, candidate in ipairs({
    vim.env[dep[1]] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep[2],
  }) do
    if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua/" .. dep[3]) == 1 then
      vim.opt.rtp:prepend(candidate)
      break
    end
  end
end

local mode = arg and arg[1] or "gio"
assert(
  mode == "gio" or mode == "trash-put" or mode == "xdg" or mode == "wsl",
  "mode is gio, trash-put, xdg or wsl, got " .. tostring(mode)
)

if mode == "wsl" and vim.fn.has("wsl") ~= 1 then
  print("n/a  wsl mode runs in WSL only")
  return
end
if mode ~= "wsl" and (vim.fn.has("linux") ~= 1 or vim.fn.has("wsl") == 1) then
  print("n/a  this checks the Linux backends (WSL trashes through Windows)")
  return
end
if (mode == "gio" or mode == "trash-put") and vim.fn.executable(mode) ~= 1 then
  print("n/a  " .. mode .. " is not installed")
  return
end

local uv = vim.uv or vim.loop
local TIMEOUT_MS = 60000

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
    if on_exit then on_exit(res) end
  end)
end

-- The tools platform.lua prefers over the one under test are hidden from it.
local hidden = ({
  gio = {},
  ["trash-put"] = { gio = true },
  xdg = { gio = true, ["trash-put"] = true },
  wsl = {},
})[mode]
local real_executable = vim.fn.executable
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.executable = function(name)
  if hidden[name] then return 0 end
  return real_executable(name)
end

local platform = require("filetree.features.fileops.trash.platform")
print(("mode %s, backend: %s"):format(mode, platform.backend_name()))

-- Below $HOME so the items land in the home trash and not in another volume's trash folder.
local stamp = ("%d-%d"):format(os.time(), uv.os_getpid())
local work = ("%s/ft-trash-live-%s"):format(vim.env.HOME, stamp)
vim.fn.mkdir(work, "p")
local trash_files = (vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")) .. "/Trash/files"

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

---Is each of `paths` in the XDG trash folder? Reported, not assumed.
---@param name string
---@param paths string[]
local function check_in_trash(name, paths)
  local missing = {}
  for _, p in ipairs(paths) do
    local base = vim.fn.fnamemodify(p, ":t")
    if not exists(trash_files .. "/" .. base) then missing[#missing + 1] = base end
  end
  if #missing == 0 then
    pass(name .. ": in " .. trash_files)
  else
    unknown(name .. ": in " .. trash_files, "not there: " .. table.concat(missing, " | "))
  end
end

---@param name string
local function check_one_call(name)
  local want = mode == "xdg" and "mv" or mode
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

---Undo of a real trash: the item goes to the trash through `platform.send`, then the trash
---history's restore (what `U` runs) must put it back at its old place.
---@param where string  the platform name the history records ("linux" or "wsl")
---@param dir string  the folder the item lives in
local function check_restore(where, dir)
  local name = "restore " .. where
  local path = ("%s/%s-restore me.txt"):format(dir, stamp)
  vim.fn.writefile({ "restore" }, path)
  local sent
  platform.send(path, function(r)
    sent = r
  end)
  vim.wait(TIMEOUT_MS, function()
    return sent ~= nil
  end, 50)
  if not (sent and sent.ok and not exists(path)) then
    return fail(name, "the trash itself failed: " .. vim.inspect(sent))
  end
  local undo = require("filetree.features.fileops.trash.undo")
  local ok, err = undo.restore({
    platform = where,
    name = vim.fn.fnamemodify(path, ":t"),
    original_path = path,
  })
  if ok and exists(path) and vim.fn.readfile(path)[1] == "restore" then
    pass(name .. ": back at its old place: " .. path)
  else
    fail(
      name .. ": " .. path,
      ("ok=%s err=%s back=%s"):format(tostring(ok), tostring(err), tostring(exists(path)))
    )
  end
end

if mode == "wsl" then
  -- Sequential, path by path: the items must be gone and reported ok. The Linux-side ones must be
  -- in the Linux trash; the recycle bin, where the /mnt/c one lands, this side cannot list.
  -- The Windows user's %TEMP%, as WSL sees it below /mnt/c.
  local win_tmp = vim.trim(vim.fn.system({
    "wslpath",
    "-u",
    vim.trim(vim.fn.system({ "powershell.exe", "-NoProfile", "-Command", "$env:TEMP" })),
  }))
  local mnt_dir = vim.fn.isdirectory(win_tmp) == 1 and (win_tmp .. "/ft-trash-live-" .. stamp)
    or nil
  if mnt_dir then vim.fn.mkdir(mnt_dir, "p") end
  local items = { new_file("a.txt"), new_file("with space.txt") }
  local wsl_folder = new_file("folder-placeholder")
  vim.fn.delete(wsl_folder)
  vim.fn.mkdir(wsl_folder, "p")
  vim.fn.writefile({ "x" }, wsl_folder .. "/inner.txt")
  items[#items + 1] = wsl_folder
  if mnt_dir then
    local f = mnt_dir .. "/" .. stamp .. "-on-c.txt"
    vim.fn.writefile({ "x" }, f)
    items[#items + 1] = f
  else
    unknown("a file below /mnt/c", "no " .. win_tmp)
  end
  local res = batch(items)
  if not res then
    fail("wsl delete", "no answer within " .. TIMEOUT_MS .. " ms")
  else
    for i, p in ipairs(items) do
      if res[i] and res[i].ok and not exists(p) then
        pass("wsl delete: gone, reported ok: " .. p)
      else
        fail(
          "wsl delete: " .. p,
          ("ok=%s err=%s still there=%s"):format(
            tostring(res[i] and res[i].ok),
            tostring(res[i] and res[i].err),
            tostring(exists(p))
          )
        )
      end
    end
  end
  check_restore("wsl", work)
  if mnt_dir then check_restore("wsl", mnt_dir) end
  check_in_trash("wsl delete, linux side", { items[1], items[2], items[3] })
  if mnt_dir then vim.fn.delete(mnt_dir, "rf") end
  vim.fn.delete(work, "rf")
  print(("\nfiletree.nvim trash_linux (wsl): %d failed, %d unverified"):format(failed, unverified))
  vim.cmd(failed > 0 and "cq" or "qa!")
  return
end

-- 1. Several files.
plain_batch("plain names", { new_file("a.txt"), new_file("b.txt"), new_file("c.txt") })

-- 2. A folder among them.
local folder = new_file("folder-placeholder")
vim.fn.delete(folder)
vim.fn.mkdir(folder, "p")
vim.fn.writefile({ "x" }, folder .. "/inner.txt")
plain_batch("a folder in the batch", { new_file("d.txt"), folder })

-- 3. Names a shell would trip over (argv needs no quoting, this shows it).
plain_batch("spaces, quote, backslash", {
  new_file("with space.txt"),
  new_file('with"quote.txt'),
  new_file("with\\backslash.txt"),
})

-- 4. Permission taken away mid-batch: the file's folder is read-only, so nothing can move it out.
--    Only that file may be reported; the rest of the batch must not be blocked by it.
local closed_dir = ("%s/%s-closed"):format(work, stamp)
vim.fn.mkdir(closed_dir, "p")
local closed = closed_dir .. "/" .. stamp .. "-closed.txt"
vim.fn.writefile({ "x" }, closed)
vim.fn.system({ "chmod", "555", closed_dir })
local others = { new_file("e.txt"), new_file("f.txt") }
local paths = { others[1], closed, others[2] }
local results = batch(paths)
if not results then
  fail("read-only parent folder", "no answer within " .. TIMEOUT_MS .. " ms")
elseif uv.getuid and uv.getuid() == 0 then
  unknown("read-only parent folder", "running as root, a read-only folder blocks nothing")
else
  check_one_call("read-only parent folder")
  if results[2].ok == false and exists(closed) then
    pass("read-only parent folder: the blocked item is reported, err: " .. tostring(results[2].err))
  else
    fail(
      "read-only parent folder: the blocked item is reported",
      ("ok=%s still there=%s"):format(tostring(results[2].ok), tostring(exists(closed)))
    )
  end
  for _, i in ipairs({ 1, 3 }) do
    local base = vim.fn.fnamemodify(paths[i], ":t")
    if results[i].ok and not exists(paths[i]) then
      pass("read-only parent folder: not blocked by it: " .. base)
    else
      fail(
        "read-only parent folder: not blocked by it: " .. base,
        ("ok=%s still there=%s"):format(tostring(results[i].ok), tostring(exists(paths[i])))
      )
    end
  end
end
vim.fn.system({ "chmod", "755", closed_dir })

check_restore("linux", work)

vim.fn.delete(work, "rf")
print(
  ("\nfiletree.nvim trash_linux (%s): %d failed, %d unverified"):format(mode, failed, unverified)
)
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
