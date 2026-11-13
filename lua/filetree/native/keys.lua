---@module 'filetree.native.keys'
---@brief The keys the own tree brings itself: open, fold, close, refresh.
---@description
--- Only what a tree needs to be a tree. Everything else (create, rename, trash, copy paths ...) is a
--- filetree feature and binds its own keys on the same buffer afterwards; a feature key on the same
--- left-hand side replaces the one set here.
---
--- Key responsibilities:
--- - `attach(view, buf)`: buffer-local keys, set before the buffer gets its filetype
--- - `activate(view)`: what `<CR>` does, for callers that want the same behaviour
---
--- The action table with `needs` / `when` of a later stage replaces this list.

local M = {}

---`<CR>` on a row: a folder opens or closes, a file opens in an editor window.
---@param view Filetree.View
---@param mode? FiletreeOpenMode
function M.activate(view, mode)
  local row = view:current()
  if not row then return end
  if row.expandable or row.node.kind == "dir" then
    if row.id ~= view.root then view:toggle(row.id) end
    return
  end
  if row.node.path then require("filetree.native").open_path(view, row.node.path, mode) end
end

---`h`: close the folder under the cursor, or go to the folder the entry lies in.
---@param view Filetree.View
local function close_or_parent(view)
  local row = view:current()
  if not row then return end
  if row.expanded and row.id ~= view.root then
    view:collapse(row.id)
    return
  end
  local parent = view.tree:parent(row.id)
  local line = parent and view.tree:row_of(parent)
  if line then view:set_cursor(line) end
end

---`l`: open the folder under the cursor, or the file.
---@param view Filetree.View
local function open_or_enter(view)
  local row = view:current()
  if not row then return end
  if (row.expandable or row.node.kind == "dir") and row.expanded then
    local line = view.tree:row_of(row.id)
    local below = line and view.tree:row(line + 1)
    if below and below.depth > row.depth then view:set_cursor(line + 1) end
    return
  end
  M.activate(view)
end

---@param view Filetree.View
---@param buf integer
function M.attach(view, buf)
  ---@param lhs string
  ---@param desc string
  ---@param fn fun()
  local function map(lhs, desc, fn)
    vim.keymap.set(
      "n",
      lhs,
      fn,
      { buffer = buf, nowait = true, silent = true, desc = "[filetree] " .. desc }
    )
  end

  map("<CR>", "Open the file, or open/close the folder", function()
    M.activate(view)
  end)
  map("<2-LeftMouse>", "Open the file, or open/close the folder", function()
    M.activate(view)
  end)
  map("o", "Open the file, or open/close the folder", function()
    M.activate(view)
  end)
  map("l", "Open the folder or file; on an open folder, go to its first entry", function()
    open_or_enter(view)
  end)
  map("h", "Close the folder, or go to the parent folder", function()
    close_or_parent(view)
  end)
  map("C", "Close the folder the entry lies in", function()
    local row = view:current()
    local parent = row and view.tree:parent(row.id)
    if row and row.expanded and row.id ~= view.root then
      view:collapse(row.id)
    elseif parent and parent ~= view.root then
      view:collapse(parent)
      local line = view.tree:row_of(parent)
      if line then view:set_cursor(line) end
    end
  end)
  map("z", "Close every folder", function()
    view:collapse_all()
  end)
  map("R", "Read the folders again", function()
    view:refresh()
  end)
  map("H", "Show or hide the names of the ignore list", function()
    view:set_hide_ignored(not view.hide_ignored)
  end)
  map("q", "Close the tree", function()
    view:close()
  end)
end

return M
