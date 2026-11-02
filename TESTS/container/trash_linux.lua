-- TESTS/container/trash_linux.lua -- runs INSIDE the Linux container (testing.container), started by
-- TESTS/trash_linux_container_spec.lua:
--
--   nvim --headless --clean -u NONE -l TESTS/container/trash_linux.lua <repos dir>
--
-- Sends a file, a directory and a batch to the freestanding trash through the real tools of the image
-- (`gio trash`, then `trash-put`) and checks where the entries end up. Prints `TRASH_OK <backend>` on success.

local repos = assert(arg and arg[1], "usage: trash_linux.lua <repos dir>")
vim.opt.rtp:prepend(repos .. "/lib.nvim")
vim.opt.rtp:prepend(repos .. "/filetree.nvim")

-- The container shares the WSL2 kernel of the podman machine; without wslpath it must not count as WSL.
assert(not require("lib.nvim.cross.platform.is_wsl")(), "a Linux container on the WSL2 kernel is not WSL")

local platform = require("filetree.features.fileops.trash.platform")
local home = assert(vim.env.HOME)
local trash = (vim.env.XDG_DATA_HOME or (home .. "/.local/share")) .. "/Trash"

local function wait_for(fn)
  local result
  fn(function(r)
    result = r
  end)
  assert(
    vim.wait(15000, function()
      return result ~= nil
    end, 50),
    "the trash callback never ran"
  )
  return result
end

local function entries(sub)
  local names = {}
  for name in vim.fs.dir(trash .. "/" .. sub) do
    names[name] = true
  end
  return names
end

local work = home .. "/work"
vim.fn.mkdir(work .. "/folder", "p")
local file = work .. "/note.txt"
vim.fn.writefile({ "content" }, file)
vim.fn.writefile({ "inner" }, work .. "/folder/inner.txt")

-- one file
local res = wait_for(function(cb)
  platform.send(file, cb)
end)
assert(res.ok, "send failed: " .. tostring(res.err))
assert(vim.uv.fs_stat(file) == nil, "the file is still in place")
assert(entries("files")["note.txt"], "note.txt is not in the trash")
assert(entries("info")["note.txt.trashinfo"], "no .trashinfo for note.txt")

-- a batch: a directory and a second file
local second = work .. "/second.txt"
vim.fn.writefile({ "two" }, second)
local results = wait_for(function(cb)
  platform.send_batch({ work .. "/folder", second }, cb)
end)
assert(
  #results == 2 and results[1].ok and results[2].ok,
  "the batch failed: " .. vim.inspect(results)
)
assert(
  vim.uv.fs_stat(work .. "/folder") == nil and vim.uv.fs_stat(second) == nil,
  "batch entries are still in place"
)
local trashed = entries("files")
assert(trashed["folder"] and trashed["second.txt"], "the batch entries are not in the trash")
assert(vim.uv.fs_stat(trash .. "/files/folder/inner.txt"), "the directory lost its content")

print("TRASH_OK " .. tostring(platform.backend_name()))
