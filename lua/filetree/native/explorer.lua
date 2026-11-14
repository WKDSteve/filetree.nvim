---@module 'filetree.native.explorer'
---@brief The own tree as an explorer of `lib.nvim.explorer`, and its answer to fileops.nvim.
---@description
--- Two things other plugins ask "whatever tree is open", without knowing this one:
---
---   require("lib.nvim.explorer").current_path()  -- the path under the cursor of the tree window
---   require("lib.nvim.explorer").reload_all()    -- read the tree again
---
--- and one thing fileops.nvim says after each of its operations: `User FileopsChanged` with
--- `{ action, path }`, followed at once by `reload_all()`. The event names one path. Where that path
--- is all that changed (a file made, copied to, deleted), the folder it lies in is read again and the
--- reload that follows is skipped: it would read every open folder for the same answer. A rename or a
--- move names only where the file went, so there the reload does the work: once for however many
--- were asked for in one tick (a bulk rename of fifty files announces fifty).

local api = vim.api

local M = {}

---The name the tree goes by in `lib.nvim.explorer`.
M.NAME = "filetree"

local GROUP = "filetree_native_explorer"

---The actions of fileops.nvim that change nothing but the path they name.
---@type table<string, boolean>
local ONE_PATH = {
  new = true,
  saveas = true,
  writeto = true,
  mkdir = true,
  touch = true,
  copy = true,
  duplicate = true,
  delete = true,
}

---true between a `FileopsChanged` that was answered by reading one folder and the reload after it.
local answered = false
---true while a reload waits for the end of the tick.
local pending = false

---The path of the node under the cursor of the tree that draws `buf`. A node without a path (a
---symbol, a terminal, a heading) has none to give.
---@param buf integer
---@return string|nil
function M.current_path(buf)
  local view = require("filetree.native").of_buf(buf)
  local row = view and view:current()
  local path = row and row.node and row.node.path
  return type(path) == "string" and path ~= "" and path or nil
end

---Read every tree again, unless the change was answered already (see the module text). The read
---runs at the end of the tick, one for all reloads asked for until then.
function M.reload()
  if answered then
    answered = false
    return
  end
  if pending then return end
  pending = true
  vim.schedule(function()
    if not pending then return end
    pending = false
    for _, view in ipairs(require("filetree.native").all()) do
      pcall(view.refresh, view)
    end
  end)
end

---@param data { action?: string, path?: string }
local function on_fileops(data)
  answered = false
  local path = data.path
  if type(path) ~= "string" or path == "" then return end
  local views = require("filetree.native").all()
  for _, view in ipairs(views) do
    view:refresh_path(path)
    view:operation_done()
  end
  if not ONE_PATH[data.action] then return end
  answered = true
  -- fileops reloads in the same call; whoever fires the event without reloading must not make the
  -- next reload, whenever it comes, a no-op
  vim.schedule(function()
    answered = false
  end)
end

---Register at `lib.nvim.explorer` and listen to fileops.nvim. Safe to call again.
function M.register()
  local ok, explorer = pcall(require, "lib.nvim.explorer")
  if not ok or type(explorer.register) ~= "function" then return end
  explorer.register({
    name = M.NAME,
    filetypes = { require("filetree.native.view").FILETYPE },
    current_path = M.current_path,
    reload = M.reload,
  })
  local group = api.nvim_create_augroup(GROUP, { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FileopsChanged",
    desc = "[filetree] Read the folder of a file operation of fileops.nvim again",
    callback = function(ev)
      on_fileops(type(ev.data) == "table" and ev.data or {})
    end,
  })
end

---Leave `lib.nvim.explorer` and stop listening (`native.reset`, a change of backend).
function M.unregister()
  answered = false
  pending = false
  pcall(api.nvim_del_augroup_by_name, GROUP)
  local ok, explorer = pcall(require, "lib.nvim.explorer")
  if ok and type(explorer.unregister) == "function" then pcall(explorer.unregister, M.NAME) end
end

return M
