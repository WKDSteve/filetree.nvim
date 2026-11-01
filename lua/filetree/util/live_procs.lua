---@module 'filetree.util.live_procs'
--- `vim.system` that does not outlive the editor.
---
--- Neovim does not stop a `vim.system` child when it exits (on POSIX; on Windows
--- libuv's job object does, but only for direct children, not for what a shim
--- such as Scoop's launches). A long-running archiver or `du` still going at
--- `:qa` would be left behind. `spawn` remembers the process until it exits and
--- `VimLeavePre` kills what is left.

local M = {}

---@type table<vim.SystemObj, true>
local live = {}
local hooked = false

local function ensure_hook()
  if hooked then return end
  hooked = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("filetree.live_procs", { clear = true }),
    desc = "filetree: stop external processes still running",
    callback = function()
      M.kill_all()
    end,
  })
end

---Same contract as `vim.system(cmd, opts, on_exit)` (it throws when the
---executable is missing), plus the exit bookkeeping.
---@param cmd string[]
---@param opts? vim.SystemOpts
---@param on_exit fun(res: vim.SystemCompleted)
---@return vim.SystemObj
function M.spawn(cmd, opts, on_exit)
  ensure_hook()
  local obj
  obj = vim.system(cmd, opts or {}, function(res)
    if obj then live[obj] = nil end
    on_exit(res)
  end)
  -- The exit callback is dispatched from the event loop, never while this function still runs.
  live[obj] = true
  return obj
end

---Kill every process `spawn` started that has not exited yet.
---@return integer killed
function M.kill_all()
  local n = 0
  for obj in pairs(live) do
    live[obj] = nil
    if pcall(obj.kill, obj, "sigkill") then n = n + 1 end
  end
  return n
end

---@return integer
function M.count()
  local n = 0
  for _ in pairs(live) do
    n = n + 1
  end
  return n
end

return M
