-- TESTS/trash_restore_linux_spec.lua -- undo of a Linux trash without gio.
--
-- trash-put and the XDG `mv` fallback put an item into ~/.local/share/Trash/files just like gio,
-- but the restore only looked there when gio was installed: without gio `U` always failed. The
-- trash folder is a temporary XDG_DATA_HOME here and the `mv` is done in-process, so this runs on
-- any system; the real tools are TESTS/live/trash_linux.lua.
--
--   nvim --clean --headless -u NONE -l TESTS/trash_restore_linux_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ { "LIB_NVIM_DIR", "lib.nvim", "lib" }, { "UI_NVIM_DIR", "ui.nvim", "ui" } }) do
  for _, dir in ipairs({
    vim.env[dep[1]] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep[2],
    vim.fn.stdpath("data") .. "/lazy/" .. dep[2],
  }) do
    if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/" .. dep[3]) == 1 then
      vim.opt.rtp:prepend(vim.fs.normalize(dir))
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
    print(("  FAIL %s  -- got %s, want %s"):format(name, tostring(got), tostring(want)))
  end
end

local work = vim.fn.tempname():gsub("\\", "/")
vim.env.XDG_DATA_HOME = work .. "/data"
local files = work .. "/data/Trash/files"
local info = work .. "/data/Trash/info"
vim.fn.mkdir(files, "p")
vim.fn.mkdir(info, "p")
vim.fn.mkdir(work .. "/project", "p")

-- No gio on this machine; `mv` moves in-process.
local real_executable = vim.fn.executable
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.executable = function(name)
  if name == "gio" then return 0 end
  return real_executable(name)
end
local argvs = {}
package.loaded["lib.nvim.cross.run_argv"] = {
  run_blocking = function(argv)
    argvs[#argvs + 1] = argv
    if argv[1] ~= "mv" then return false, "exit code 1" end
    local ok = vim.uv.fs_rename(argv[2], argv[3])
    return ok == true, ok and nil or "exit code 1"
  end,
}
-- what the undo module says, in order
local said = {}
package.loaded["filetree.util.notify"] = {
  create = function()
    return setmetatable({}, {
      __index = function()
        return function(msg)
          said[#said + 1] = tostring(msg)
        end
      end,
    })
  end,
}

local undo = require("filetree.features.fileops.trash.undo")

-- trash-put left the item and its record in the trash.
local original = work .. "/project/note with space.txt"
vim.fn.writefile({ "x" }, files .. "/note with space.txt")
vim.fn.writefile({ "[Trash Info]" }, info .. "/note with space.txt.trashinfo")
local ok, err = undo.restore({
  platform = "linux",
  name = "note with space.txt",
  original_path = original,
})
eq("without gio: restore reports ok", ok, true)
eq("without gio: no error", err, nil)
eq("without gio: the file is back", vim.fn.filereadable(original), 1)
eq("without gio: gone from the trash", vim.fn.filereadable(files .. "/note with space.txt"), 0)
eq(
  "without gio: its .trashinfo is gone too",
  vim.fn.filereadable(info .. "/note with space.txt.trashinfo"),
  0
)

-- Something new stands at the old place: it is not overwritten.
vim.fn.writefile({ "old" }, files .. "/taken.txt")
local taken = work .. "/project/taken.txt"
vim.fn.writefile({ "new" }, taken)
argvs = {}
ok = undo.restore({ platform = "linux", name = "taken.txt", original_path = taken })
eq("occupied: restore refuses", ok, false)
eq("occupied: the new file stays", vim.fn.readfile(taken)[1], "new")
eq("occupied: nothing was moved", #argvs, 0)

-- WSL: a Linux-side file comes back from the Linux trash, not from the Windows recycle bin.
local wsl_file = work .. "/project/wsl.txt"
vim.fn.writefile({ "w" }, files .. "/wsl.txt")
argvs = {}
ok = undo.restore({ platform = "wsl", name = "wsl.txt", original_path = wsl_file })
eq("wsl, linux side: restored from the Linux trash", ok, true)
eq("wsl, linux side: by mv", argvs[1] and argvs[1][1], "mv")

-- WSL: a file below /mnt/c is looked up in the recycle bin by its Windows path.
argvs = {}
undo.restore({ platform = "wsl", name = "c.txt", original_path = "/mnt/c/Users/x/c.txt" })
local script = argvs[1] and argvs[1][#argvs[1]] or ""
eq(
  "wsl, windows side: the recycle bin is asked for the Windows path",
  script:find([[C:\Users\x\c.txt]], 1, true) ~= nil,
  true
)
eq("wsl, windows side: not for the Linux spelling", script:find([[\mnt\c]], 1, true), nil)

-- `U` with an empty history says so instead of nothing.
said = {}
eq("empty history: nothing was recorded here", undo.last(), nil)
local undone = undo.restore_last()
eq("empty history: nothing restored", undone, false)
eq(
  "empty history: the user is told",
  table.concat(said, " "):find("Nothing to undo", 1, true) ~= nil,
  true
)

vim.fn.delete(work, "rf")
print(("\nfiletree.nvim trash_restore_linux_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
