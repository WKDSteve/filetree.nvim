-- TESTS/container/trash_wsl_no_wslpath.lua -- runs INSIDE the Linux container (testing.container), started by
-- TESTS/trash_linux_container_spec.lua. The container shares the WSL2 kernel of the podman machine, so
-- is_wsl() is true although there is no wslpath: trashing must report a failure, not throw ENOENT.
-- Prints `WSL_NO_WSLPATH_OK` on success.

local repos = assert(arg and arg[1], "usage: trash_wsl_no_wslpath.lua <repos dir>")
vim.opt.rtp:prepend(repos .. "/lib.nvim")
vim.opt.rtp:prepend(repos .. "/filetree.nvim")

package.loaded["lib.nvim.cross.platform.is_wsl"] = function()
  return true
end

local platform = require("filetree.features.fileops.trash.platform")
-- A path on a Windows drive: only that one takes the wslpath + recycle bin route (a Linux-side path
-- goes to the Linux trash, see platform.wsl_windows_side). It need not exist: the missing wslpath is
-- reported before anything touches it.
local file = "/mnt/c/ft-wsl-no-wslpath/note.txt"

local result
local okc, err = pcall(platform.send, file, function(r)
  result = r
end)
assert(okc, "send threw: " .. tostring(err))
assert(
  vim.wait(5000, function()
    return result ~= nil
  end, 50),
  "no callback"
)
assert(
  result.ok == false and tostring(result.err):find("wslpath", 1, true),
  "expected a wslpath failure: " .. vim.inspect(result)
)
print("WSL_NO_WSLPATH_OK")
