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
---@field views? (string|Filetree.Native.ViewSpec)[]  The views of the tree, in the order of the view bar: `{ "files" }` is one view with one source, `{ name = "work", "buffers", "git" }` one view with two sections (default: the files, then one view per registered source).

---One entry of `native.views`: the sources of the view as list items, and its name.
---@class Filetree.Native.ViewSpec
---@field name? string  Default: the first source.
---@field [integer] string  A source name.

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
  -- `nvim <dir>` with filetree set up later (a lazy-loading plugin manager): that BufEnter is over,
  -- the folder buffer is already on screen
  vim.schedule(function()
    local adapter = require("filetree.adapter").get()
    if adapter and adapter.name == "native" then M.show_dir_buffer(api.nvim_get_current_buf()) end
  end)
end

---@return Filetree.Native.Opts
function M.options()
  return options
end

---The views of the tree, in the order of the view bar. With `native.views` set, exactly those; without,
---the files and one view per registered source, in registration order.
---@return Filetree.View.Spec[]
function M.views()
  local out, seen = {}, {}
  ---@param name any
  ---@param sources string[]
  local function add(name, sources)
    if type(name) ~= "string" or name == "" or seen[name] or #sources == 0 then return end
    seen[name] = true
    out[#out + 1] = { name = name, sources = sources }
  end
  if type(options.views) == "table" and #options.views > 0 then
    for _, spec in ipairs(options.views) do
      local sources = {}
      for _, source in ipairs(type(spec) == "table" and spec or { spec }) do
        if type(source) == "string" and source ~= "" then sources[#sources + 1] = source end
      end
      add(type(spec) == "table" and spec.name or sources[1], sources)
    end
  else
    add("files", { "files" })
    local ok, registered = pcall(require("filetree.registry").list, "source")
    for _, entry in ipairs(ok and registered or {}) do
      add(entry.name, { entry.name })
    end
  end
  if #out == 0 then add("files", { "files" }) end
  return out
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
    views = M.views,
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
---@type table<string, string>  The same modes for a buffer that is no file (a terminal).
local BUFFER_COMMANDS =
  { edit = "buffer", split = "sbuffer", vsplit = "vertical sbuffer", tab = "tab sbuffer" }

---Show a file or a buffer from the tree in an editor window.
---@param view Filetree.View
---@param commands table<string, string>  Mode -> the Ex command that shows the target.
---@param arg string  What the command is given: an escaped file name, or a buffer number.
---@param mode FiletreeOpenMode
---@param win? integer
---@return boolean ok
---@return integer|nil shown_in  The window the target is in now.
local function open_in_editor(view, commands, arg, mode, win)
  if mode == "tab" then
    local ok = pcall(vim.cmd, commands.tab .. " " .. arg)
    return ok, ok and api.nvim_get_current_win() or nil
  end

  if view.position == "current" and view:is_open() then
    -- the tree sits in an editor window: the file takes its place
    view.win = nil
    local ok = pcall(vim.cmd, (commands[mode] or commands.edit) .. " " .. arg)
    return ok, ok and api.nvim_get_current_win() or nil
  end

  -- a floating tree is in the way of the file it opens
  if view.position == "float" and view:is_open() then view:close() end
  local target = (win and api.nvim_win_is_valid(win) and win ~= view.win) and win
    or editor_window(view)
  if not target then
    local adapter = require("filetree.adapter").get()
    target = require("filetree.util.window").open_editor_window(adapter, { empty = true })
  end
  if not target then return false, nil end

  if mode == "preview" then
    -- shown in the editor window, the focus stays in the tree
    local ok = pcall(api.nvim_win_call, target, function()
      vim.cmd("keepalt " .. commands.edit .. " " .. arg)
    end)
    return ok, ok and target or nil
  end
  -- Leave the tree window first and open the file from the editor window, the order a user's own
  -- `<C-w>l :edit` has: whoever watches for "a file was opened from the tree" (close_on_open) sees
  -- WinLeave of the tree before BufWinEnter of the file.
  api.nvim_set_current_win(target)
  if not pcall(vim.cmd, (commands[mode] or commands.edit) .. " " .. arg) then return false, nil end
  return true, api.nvim_get_current_win()
end

---Open a file from the tree.
---@param view Filetree.View
---@param path string
---@param mode? FiletreeOpenMode
---@param win? integer  Open it in this window (a window picker's answer) instead of choosing one.
---@return boolean
function M.open_path(view, path, mode, win)
  return (open_in_editor(view, COMMANDS, vim.fn.fnameescape(path), mode or "edit", win))
end

---Open what a node stands for: its buffer (`data.bufnr`) or its file (`path`), at `data.lnum` /
---`data.col` when the source gave a place. A node with neither is nothing to open.
---@param view Filetree.View
---@param node Filetree.Node
---@param mode? FiletreeOpenMode
---@param win? integer
---@return boolean
function M.open_node(view, node, mode, win)
  local data = type(node.data) == "table" and node.data or {}
  local ok, shown_in = false, nil
  local bufnr = data.bufnr
  if type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr) then
    -- by number: a terminal has no file name, and a file open in a buffer is that buffer
    ok, shown_in = open_in_editor(view, BUFFER_COMMANDS, tostring(bufnr), mode or "edit", win)
  elseif type(node.path) == "string" then
    ok, shown_in =
      open_in_editor(view, COMMANDS, vim.fn.fnameescape(node.path), mode or "edit", win)
  end
  if ok and shown_in and type(data.lnum) == "number" then
    local last = api.nvim_buf_line_count(api.nvim_win_get_buf(shown_in))
    local lnum = math.max(1, math.min(data.lnum, last))
    pcall(api.nvim_win_set_cursor, shown_in, { lnum, math.max(0, tonumber(data.col) or 0) })
  end
  return ok
end

return M
