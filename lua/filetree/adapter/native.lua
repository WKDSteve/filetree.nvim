---@module 'filetree.adapter.native'
---@brief The adapter of filetree.nvim's own tree.
---@description
--- Implements `FiletreeAdapter` (see `filetree.@types.adapter`) on `filetree.native`, every required
--- and every optional method, so that each feature written against the contract runs on the own tree
--- as it does on a foreign one.
---
--- Key responsibilities:
--- - Translate between the contract (`FiletreeNode`, paths, 1-based lines) and a view's rows
--- - Resolve "the tree" to the view of the current tab, or to the view of a given buffer
---
--- Paths go in in any spelling and are normalized here (`fs.list.norm`); paths that come out are
--- `/`-separated. Nothing in this module talks to another tree plugin.

local registry = require("filetree.adapter")
local native = require("filetree.native")
local View = require("filetree.native.view")
local list = require("filetree.native.fs.list")

local api = vim.api

---@type FiletreeAdapter
local M = { name = "native" }

M.filetypes = { View.FILETYPE }
M.hl_groups = View.HL

local NS = api.nvim_create_namespace("filetree_native_marks")

---@param row Lib.Tree.Row
---@param line integer  1-based.
---@return FiletreeNode
local function to_node(row, line)
  local node = row.node
  local is_dir = row.expandable or node.kind == "dir"
  local data = node.data or {}
  local is_expanded = nil
  if is_dir then is_expanded = row.expanded end
  return {
    id = node.id,
    name = node.label,
    path = node.path or node.id,
    type = is_dir and "directory" or "file",
    depth = row.depth,
    line_number = line,
    is_expanded = is_expanded,
    is_link = data.is_link,
    link_to = data.link_to,
    link_broken = data.link_broken,
  }
end

---@param bufnr? integer
---@return Filetree.View|nil
local function view_of(bufnr)
  if bufnr then return native.of_buf(bufnr) end
  return native.current()
end

---@return boolean
function M.is_available()
  return true
end

---@return boolean open
---@return integer? bufnr
function M.is_open()
  local view = native.current()
  if view and view:is_open() then return true, view.buf end
  return false, nil
end

---@return integer?
function M.get_bufnr()
  local view = native.current()
  if view and view.buf and api.nvim_buf_is_valid(view.buf) then return view.buf end
  return nil
end

---@return integer?
function M.get_winid()
  local view = native.current()
  if view and view:is_open() then return view.win end
  return nil
end

---@return FiletreeTreePosition?
function M.get_position()
  local view = native.current()
  return view and view.position or native.options().position
end

---@return string?
function M.get_root_path()
  local view = native.current()
  return view and view.root or nil
end

---@param bufnr? integer
---@return Filetree.View?
function M.get_state(bufnr)
  return view_of(bufnr)
end

---@return FiletreeNode?
function M.get_current_node()
  local view = native.current()
  local row = view and view:current()
  if not view or not row or row.node.kind == "more" then return nil end
  return to_node(row, view.tree:row_of(row.id) or 1)
end

---@param filter? FiletreeFilterMode
---@param bufnr? integer
---@return FiletreeNode[]
function M.get_visible_nodes(filter, bufnr)
  local view = view_of(bufnr)
  if not view then return {} end
  local cap = require("filetree.config").get().max_visible_nodes or 5000
  local out = {}
  -- line 1 is the root: the label of the tree, not an entry of it
  for line = 2, view.tree:count() do
    if #out >= cap then break end
    local row = view.tree:row(line)
    -- the line that says a folder was cut is no entry
    if row.node.kind ~= "more" then
      local node = to_node(row, line)
      if
        filter == nil
        or filter == "all"
        or (filter == "files" and node.type == "file")
        or (filter == "folders" and node.type == "directory")
      then
        out[#out + 1] = node
      end
    end
  end
  return out
end

---@param path string
---@return integer?
function M.get_node_line(path)
  local view = native.current()
  if not view or type(path) ~= "string" then return nil end
  return view:line_of(list.norm(path))
end

---@param bufnr integer
---@param linenr integer  0-based.
---@return FiletreeNode?
function M.get_node_at_line(bufnr, linenr)
  local view = native.of_buf(bufnr)
  if not view or linenr < 1 then return nil end
  local row = view.tree:row(linenr + 1)
  if not row or row.node.kind == "more" then return nil end
  return to_node(row, linenr + 1)
end

---@param node FiletreeNode
---@return boolean
function M.expand_node(node)
  local view = native.current()
  if not view or not node then return false end
  local id = view:id_of(list.norm(node.path))
  if view.tree:is_expanded(id) then return true end
  return view:expand(id)
end

---@param node FiletreeNode
---@return boolean
function M.collapse_node(node)
  local view = native.current()
  if not view or not node then return false end
  return view:collapse(view:id_of(list.norm(node.path)))
end

---@param keep_path? string
---@return boolean ok
---@return string? reason
function M.collapse_all(keep_path)
  local view = native.current()
  if not view then return false, "no tree in this tab" end
  view:collapse_all(type(keep_path) == "string" and keep_path ~= "" and list.norm(keep_path) or nil)
  return true, nil
end

---@param path string
---@param mode? FiletreeOpenMode
---@return boolean
function M.open_file(path, mode)
  return native.open_path(native.ensure(), path, mode)
end

---Show the tree without entering it and put its cursor on `path`.
---@param path string
---@param parent_levels? integer
---@param root_dir? string
---@return boolean
function M.open_reveal(path, parent_levels, root_dir)
  if type(path) ~= "string" or path == "" then return false end
  path = list.norm(vim.fn.fnamemodify(path, ":p"))
  local view = native.ensure()
  local root = nil
  if root_dir and root_dir ~= "" then
    root = list.norm(vim.fn.fnamemodify(root_dir, ":p"))
  elseif (parent_levels or 0) > 0 then
    root = path
    for _ = 1, parent_levels do
      root = list.parent(root) or root
    end
  elseif
    path ~= view.root and path:sub(1, #list.join(view.root, "")) ~= list.join(view.root, "")
  then
    -- outside the tree that is shown: root it at the folder of the file
    root = path
  end
  if root then
    if vim.fn.isdirectory(root) ~= 1 then root = list.parent(root) or root end
    if not view:set_root(root) then return false end
  end
  if not view:open(nil, false) then return false end
  view:reveal(path)
  return true
end

---@param path string
---@return boolean
function M.set_root(path)
  if type(path) ~= "string" or path == "" then return false end
  return native.ensure(path):set_root(vim.fn.fnamemodify(path, ":p"))
end

---@return boolean
function M.open_cwd()
  -- a new view starts at the working directory; one that exists comes back as it was left (its
  -- root, its open folders), which is what a foreign tree does on "show"
  return native.ensure():open(nil, false)
end

---@param position FiletreeTreePosition
---@param opts? FiletreeToggleOpts
---@return boolean
function M.toggle_at(position, opts)
  opts = opts or {}
  local view = native.ensure(opts.dir)
  if view:is_open() and view.position == position then return view:close() end
  if opts.dir then view:set_root(vim.fn.fnamemodify(opts.dir, ":p")) end
  local file = opts.reveal and opts.file or nil
  if file and file ~= "" then
    file = list.norm(vim.fn.fnamemodify(file, ":p"))
    local inside = file:sub(1, #list.join(view.root, "")) == list.join(view.root, "")
    if not inside and opts.reveal_force_cwd then
      view:set_root(vim.fn.getcwd())
      inside = file:sub(1, #list.join(view.root, "")) == list.join(view.root, "")
    end
    if not inside then
      local dir = list.parent(file)
      if dir then view:set_root(dir) end
    end
  end
  if not view:open(position, true) then return false end
  if file and file ~= "" then view:reveal(file) end
  return true
end

---@return boolean
function M.close()
  local view = native.current()
  return view ~= nil and view:close()
end

---@return boolean
function M.refresh()
  local view = native.current()
  if not view then return false end
  view:refresh()
  return true
end

---@return boolean
function M.redraw()
  local view = native.current()
  if not view then return false end
  view:redraw()
  return true
end

local redraw_pending = false

---@return boolean
function M.redraw_soon()
  if not native.current() then return false end
  if not redraw_pending then
    redraw_pending = true
    vim.defer_fn(function()
      redraw_pending = false
      M.redraw()
    end, 30)
  end
  return true
end

---@param line integer
---@return boolean
function M.scroll_to_line(line)
  local view = native.current()
  if not view or not view:is_open() then return false end
  return view:set_cursor(math.max(1, line))
end

---@type table<string, integer>  path -> extmark id of its line highlight
local hl_marks = {}
---@type table<string, integer>  path -> extmark id of its sign
local sign_marks = {}

---@param marks table<string, integer>
---@param path string
---@param opts table
---@return boolean
local function mark(marks, path, opts)
  local view = native.current()
  local line = view and view:line_of(list.norm(path))
  if not view or not line or not view.buf then return false end
  local old = marks[path]
  if old then pcall(api.nvim_buf_del_extmark, view.buf, NS, old) end
  local ok, id = pcall(api.nvim_buf_set_extmark, view.buf, NS, line - 1, 0, opts)
  if ok then marks[path] = id end
  return ok
end

---@param marks table<string, integer>
---@param path string
---@return boolean
local function unmark(marks, path)
  local id = marks[path]
  if not id then return true end
  marks[path] = nil
  local view = native.current()
  if not view or not view.buf then return false end
  pcall(api.nvim_buf_del_extmark, view.buf, NS, id)
  return true
end

---@param path string
---@param hl_group string
---@return boolean
function M.highlight_node(path, hl_group)
  return mark(hl_marks, path, { line_hl_group = hl_group, priority = 150 })
end

---@param path string
---@return boolean
function M.unhighlight_node(path)
  return unmark(hl_marks, path)
end

---@param path string
---@param text string
---@param hl_group string
---@return boolean
function M.sign_node(path, text, hl_group)
  return mark(sign_marks, path, { sign_text = text, sign_hl_group = hl_group, priority = 150 })
end

---@param path string
---@return boolean
function M.unsign_node(path)
  return unmark(sign_marks, path)
end

---@param kind "name"|"size"|"mtime"
---@param descending? boolean
---@return boolean ok
---@return string? reason
function M.set_sort(kind, descending)
  local view = native.current()
  if not view then return false, "no tree in this tab" end
  view:set_sort(kind, descending)
  return true, nil
end

---@return { kind: "name"|"size"|"mtime", descending: boolean }?
function M.get_sort()
  local view = native.current()
  return view and vim.deepcopy(view.sort) or nil
end

---@return string[]|nil
function M.get_expanded_paths()
  local view = native.current()
  return view and view:expanded_paths() or nil
end

---@param paths string[]
---@return boolean
function M.expand_paths(paths)
  local view = native.current()
  if not view or type(paths) ~= "table" then return false end
  view:expand_paths(paths)
  return true
end

---@param callback fun(bufnr: integer?)
---@return fun() unsubscribe
function M.on_render(callback)
  return View.on_render(callback)
end

---The own tree needs no guard against a reveal fighting the cursor: its cursor belongs to a node.
---@return nil
function M.install_reveal_guard() end

registry.register(M)

return M
