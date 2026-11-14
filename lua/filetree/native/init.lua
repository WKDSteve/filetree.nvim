---@module 'filetree.native'
---@brief The own tree: which view belongs to which tab, and opening files from it.
---@description
--- Entry point of the backend `native`. A tab has at most one view; it is created when the tree is
--- first asked for in that tab and keeps its state while its window is closed.
---
--- Key responsibilities:
--- - `current()` / `ensure()`: the view of the current tab
--- - `open_path(view, path, mode)`: open a file from the tree in an editor window, never in the tree's
--- - `setup(opts)`: the options of the `native` block of `filetree.setup()`
---
--- The adapter contract is `filetree.adapter.native`; the window is `filetree.native.view`.

local View = require("filetree.native.view")
local list = require("filetree.native.fs.list")

local api = vim.api

local M = {}

---@class Filetree.Native.Opts
---@field position? "left"|"right"|"top"|"bottom"|"float"|"current"  Where the tree opens by default (default "left").
---@field width? integer  Width of a side tree (default 32).
---@field height? integer  Height of a tree at the top or bottom (default 15).
---@field hijack_netrw? boolean  A folder opened as a buffer (`nvim <dir>`, `:edit <dir>`) shows the tree in that window (default true).
---@field group_empty_dirs? boolean  Draw a chain of folders that hold one folder each as one line (default true).
---@field icons? boolean  File and folder icons (default true; without a Nerd Font none are drawn).
---@field max_entries? integer  Entries shown per folder; a last line says how many more there are (default 20000, 0 = no limit).
---@field watch? boolean  Follow changes on disk while the tree is shown and read only the folders that changed (default true).
---@field search_max? integer  Hits a search shows at most; a last line says how many more there are (default 1000).

---@type Filetree.Native.Opts
local DEFAULTS = {
  position = "left",
  width = 32,
  height = 15,
  hijack_netrw = true,
  group_empty_dirs = true,
  icons = true,
  max_entries = 20000,
  watch = true,
  search_max = 1000,
}

---@type Filetree.Native.Opts
local options = vim.deepcopy(DEFAULTS)

---@type table<integer, Filetree.View>  tabpage -> view
local views = {}

---@param opts? Filetree.Native.Opts
function M.setup(opts)
  options = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  M.hijack_netrw(options.hijack_netrw ~= false)
end

---Show a folder that is opened as a buffer as the tree, in the same window, the way netrw would.
---@param buf integer
---@return boolean shown
function M.show_dir_buffer(buf)
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return false end
  local name = api.nvim_buf_get_name(buf)
  if name == "" or vim.fn.isdirectory(name) == 0 then return false end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then return false end
  local dir = list.norm(vim.fn.fnamemodify(name, ":p"))
  api.nvim_set_current_win(win)
  local view = M.ensure(dir)
  if view.root ~= dir then
    if view:is_open() then view:close() end
    view:set_root(dir)
  end
  view:open("current")
  -- the folder buffer was only the way in; it is nothing to go back to
  if api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) == -1 then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  if view._prev_buf == buf then view._prev_buf = nil end
  return true
end

---Turn the netrw replacement on or off. With it on, netrw's own folder listing is not used: its
---autocommands are taken out when it is loaded (they would draw over the tree first).
---@param on boolean
function M.hijack_netrw(on)
  local group = api.nvim_create_augroup("filetree_native_netrw", { clear = true })
  if not on then return end
  pcall(api.nvim_clear_autocmds, { group = "FileExplorer" })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    nested = true,
    desc = "[filetree] A folder opened as a buffer shows the own tree",
    callback = function(ev)
      if require("filetree.adapter").get() == nil then return end
      if require("filetree.adapter").get().name ~= "native" then return end
      vim.schedule(function()
        M.show_dir_buffer(ev.buf)
      end)
    end,
  })
end

---@return Filetree.Native.Opts
function M.options()
  return options
end

---The test for the names the ignore list hides, as it stands now.
---@return fun(name: string, path: string): boolean
local function ignored()
  return require("filetree.util.ignore").predicate()
end

---The view of the current tab, or nil when the tree was never asked for in it.
---@return Filetree.View|nil
function M.current()
  local tab = api.nvim_get_current_tabpage()
  local view = views[tab]
  if view then return view end
  -- tabs that are gone give their view back
  for known, gone in pairs(views) do
    if not api.nvim_tabpage_is_valid(known) then
      views[known] = nil
      gone:dispose()
    end
  end
  return nil
end

---The view of the current tab; created at `root` (default: the working directory) when there is none.
---@param root? string
---@return Filetree.View
function M.ensure(root)
  local view = M.current()
  if view then return view end
  view = View.new({
    root = root or vim.fn.getcwd(),
    position = options.position,
    width = options.width,
    height = options.height,
    group_empty = options.group_empty_dirs,
    icons = options.icons,
    max_entries = options.max_entries,
    watch = options.watch,
    search_max = options.search_max,
    hide = ignored,
  })
  views[api.nvim_get_current_tabpage()] = view
  return view
end

---The view that draws `buf`, in whichever tab.
---@param buf integer
---@return Filetree.View|nil
function M.of_buf(buf)
  return View.of_buf(buf)
end

---Every view there is.
---@return Filetree.View[]
function M.all()
  return vim.tbl_values(views)
end

---Forget every view and close its window and buffer. For tests and for a change of backend.
function M.reset()
  for _, view in pairs(views) do
    pcall(view.close, view)
    pcall(view.dispose, view)
  end
  views = {}
  list.invalidate()
  require("filetree.native.fs.watch").stop_all()
  require("filetree.native.decor").stop()
  require("filetree.native.action").reset()
end

---A window a file can be opened in: not the tree, not a float, not a special buffer.
---@param view Filetree.View
---@return integer|nil
local function editor_window(view)
  ---@param win integer
  local function usable(win)
    if not api.nvim_win_is_valid(win) or win == view.win then return false end
    if api.nvim_win_get_config(win).relative ~= "" then return false end
    local buf = api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == "" and View.of_buf(buf) == nil
  end
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= 0 and usable(previous) then return previous end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
  return nil
end

---@type table<string, string>
local COMMANDS = { edit = "edit", split = "split", vsplit = "vsplit", tab = "tabedit" }

---Open a file from the tree.
---@param view Filetree.View
---@param path string
---@param mode? FiletreeOpenMode
---@param win? integer  Open it in this window (a window picker's answer) instead of choosing one.
---@return boolean
function M.open_path(view, path, mode, win)
  mode = mode or "edit"
  local escaped = vim.fn.fnameescape(path)
  if mode == "tab" then return (pcall(vim.cmd, "tabedit " .. escaped)) end

  if view.position == "current" and view:is_open() then
    -- the tree sits in an editor window: the file takes its place
    view.win = nil
    return (pcall(vim.cmd, (COMMANDS[mode] or "edit") .. " " .. escaped))
  end

  -- a floating tree is in the way of the file it opens
  if view.position == "float" and view:is_open() then view:close() end
  local target = (win and api.nvim_win_is_valid(win) and win ~= view.win) and win
    or editor_window(view)
  if not target then
    local adapter = require("filetree.adapter").get()
    target = require("filetree.util.window").open_editor_window(adapter, { empty = true })
  end
  if not target then return false end

  if mode == "preview" then
    -- shown in the editor window, the focus stays in the tree
    return (
      pcall(api.nvim_win_call, target, function()
        vim.cmd("keepalt edit " .. escaped)
      end)
    )
  end
  -- Leave the tree window first and open the file from the editor window, the order a user's own
  -- `<C-w>l :edit` has: whoever watches for "a file was opened from the tree" (close_on_open) sees
  -- WinLeave of the tree before BufWinEnter of the file.
  api.nvim_set_current_win(target)
  if not pcall(vim.cmd, (COMMANDS[mode] or "edit") .. " " .. escaped) then return false end
  return true
end

return M
