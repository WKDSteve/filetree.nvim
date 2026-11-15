---@module 'filetree.native.embed'
---@brief The directory tree drawn into a buffer another plugin owns.
---@description
--- The tree window of filetree.nvim is a view with keys, a view bar, a cursor of its own and watcher
--- handles. Another plugin sometimes wants only the picture: a small tree of one folder in its own
--- float (the directory hover of hover.nvim), a float that cannot take the focus and is gone with the
--- next cursor move. That is this layout:
---
---   local tree = require("filetree.native").embed(buf, "/path/to/dir")
---   tree:move(1)            -- the selection one row down
---   tree:expand()           -- open the folder under the selection
---   tree:current()          --> { path, kind, id, line, ... }
---   tree:close()
---
--- It reads through the listing cache of the own tree and turns entries into nodes in the one place
--- the tree window does (`source.files`), so order, merged lines `a/b/c` and icons are the same.
---
--- What it leaves alone, on purpose: no keymap, no autocmd, no option of a window, no view bar. The
--- buffer and its window stay the caller's; the selection is a line of the buffer the caller may
--- read (`current().line`) and a highlight. It follows the disk only when asked (`watch = true`).
---
--- Key responsibilities:
--- - `open(buf, root, opts)`: draw, and hand back the handle
--- - Handle: `move`, `select`, `expand`, `collapse`, `toggle`, `current`, `rows`, `refresh`, `close`
--- - `close` gives back every watcher handle and clears what it drew; nothing else was ever taken

local tree_core = require("lib.nvim.tree")
local list = require("filetree.native.fs.list")
local service = require("filetree.native.fs.service")
local files = require("filetree.native.source.files")
local render = require("filetree.native.render.line")

local api = vim.api

local M = {}

local NS = api.nvim_create_namespace("filetree_native_embed")

---@type table<string, string>  icon name -> highlight group, created once
local icon_groups = {}

---@class Filetree.Embed.Opts
---@field show_root? boolean  Draw the folder itself as the first row (default false: its entries only).
---@field icons? boolean  File and folder icons (default true; drawn only with a Nerd Font declared).
---@field max_entries? integer  Entries shown per folder; a last line says how many more (default 200, 0 = no limit).
---@field group_empty? boolean  A chain of folders that hold one folder each is one line (default true).
---@field sort? { kind: "name"|"size"|"mtime", descending?: boolean }  Default: by name.
---@field hide? fun(name: string, path: string): boolean  Names not to list (default: none).
---@field watch? boolean  Follow changes on disk until `close` (default false).
---@field select? boolean  Keep a selection and highlight its line (default true).
---@field on_change? fun(handle: Filetree.Embed)  Called after the lines were written again (the caller may fit its window).

---@class Filetree.Embed.Current
---@field id string
---@field path string?
---@field kind string  "dir", "file", or "more" for the line that counts what is not shown.
---@field label string
---@field line integer  1-based line of the buffer.
---@field expandable boolean
---@field expanded boolean

---@class Filetree.Embed
---@field buf integer
---@field root string
---@field closed boolean
local Embed = {}
Embed.__index = Embed

---@param row Lib.Tree.Row
---@return string|nil glyph
---@return string|nil hl
local function icon_of(row)
  local node = row.node
  if node.kind == "more" then return nil, nil end
  if not require("lib.nvim.ui.nerd_font").available() then return nil, nil end
  if node.kind == "dir" then return row.expanded and "" or "", "FiletreeFolderIcon" end
  local icons = require("lib.nvim.ui.icons")
  local glyph, color, name = icons.get(node.label, nil, { fallback = "" })
  if not glyph or glyph == "" then return nil, nil end
  local key = name or "Default"
  local group = icon_groups[key]
  if not group then
    -- once per icon name: defining a group forces a full redraw
    group = icons.hl_group(key, color)
    icon_groups[key] = group
  end
  return glyph, group
end

---Write every line and its highlights again. The trees an embed shows are small (a hover float):
---one write is cheaper than keeping splices in step with a buffer somebody else owns.
---@private
function Embed:_draw()
  if self.closed or not api.nvim_buf_is_valid(self.buf) then return end
  local tree = self._tree
  local lines, spans = {}, {}
  local opts = { icon = self._opts.icons ~= false and icon_of or nil, trailing_slash = true }
  for i = 1, tree:count() do
    local line = render.render(tree:row(i), opts)
    lines[i] = line.text
    spans[i] = line.spans
    if tree:row(i).node.kind == "more" then
      for _, span in ipairs(line.spans) do
        if span.col_start >= line.name_start then span.hl = "FiletreeMore" end
      end
    end
  end
  local buf = self.buf
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, row_spans in ipairs(spans) do
    for _, span in ipairs(row_spans) do
      pcall(api.nvim_buf_set_extmark, buf, NS, i - 1, span.col_start, {
        end_col = span.col_end,
        hl_group = span.hl,
        priority = 90,
      })
    end
  end
  -- the selection belongs to a node: rows that came or went above it move it along
  if self._opts.select ~= false and tree:count() > 0 then
    local line = self._selected and tree:row_of(self._selected) or nil
    if not line then
      line = math.min(math.max(self._line or 1, 1), tree:count())
      self._selected = tree:row(line).id
    end
    self._line = line
    pcall(api.nvim_buf_set_extmark, buf, NS, line - 1, 0, {
      line_hl_group = "FiletreeEmbedSelection",
      priority = 80,
    })
  else
    self._selected, self._line = nil, nil
  end
  if type(self._opts.on_change) == "function" then pcall(self._opts.on_change, self) end
end

---@private
---@param dir string
---@param entries Filetree.Fs.Entry[]
---@return Filetree.Node[]
function Embed:_nodes(dir, entries)
  local limit = self._opts.max_entries
  if limit == nil then limit = 200 end
  return files.nodes(entries, {
    dir = dir,
    max_entries = limit,
    loader = self._loader,
    sort = self._opts.sort or { kind = "name" },
    hide = self._opts.hide,
    group_empty = self._opts.group_empty,
  })
end

---@private
function Embed:_build()
  local root = self.root
  self._loaded = { [root] = true }
  self._loader = function(node, cb)
    -- read at once: the caller draws a float that is on screen now, and reads `rows()` right after
    local entries, err = service.list_sync(node.path)
    if not entries then
      cb(nil, err)
      return
    end
    self._loaded[node.id] = true
    if self._watching then self:_watch_dir(node.path) end
    cb(self:_nodes(node.path, entries))
  end
  local entries, err = service.list_sync(root)
  self.error = entries == nil and err or nil
  self._tree = tree_core.new({
    root = {
      id = root,
      label = root == "/" and "" or list.basename(root),
      kind = "dir",
      path = root,
      children = self:_nodes(root, entries or {}),
    },
    hide_root = self._opts.show_root ~= true,
  })
end

---@private
---@param dir string
function Embed:_watch_dir(dir)
  if self._unwatch[dir] then return end
  self._unwatch[dir] = require("filetree.native.fs.watch").watch(dir)
end

---Read the folders that were read before again and draw. Open folders stay open.
function Embed:refresh()
  if self.closed then return end
  local tree = self._tree
  local ids = vim.tbl_keys(self._loaded)
  -- outermost first: a folder that is gone takes the ones below it with it
  table.sort(ids, function(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end)
  for _, id in ipairs(ids) do
    local node = tree:node(id)
    if not node then
      self._loaded[id] = nil
    else
      service.invalidate(node.path)
      local entries = service.list_sync(node.path)
      if entries then
        tree:merge_children(id, self:_nodes(node.path, entries))
      elseif id ~= self.root then
        self._loaded[id] = nil
        tree:remove(id)
      end
    end
  end
  self:_draw()
end

---The rows on screen, top to bottom.
---@return Filetree.Embed.Current[]
function Embed:rows()
  local out = {}
  if self.closed then return out end
  for i = 1, self._tree:count() do
    out[i] = self:_describe(i)
  end
  return out
end

---@private
---@param line integer
---@return Filetree.Embed.Current|nil
function Embed:_describe(line)
  local row = self._tree:row(line)
  if not row then return nil end
  return {
    id = row.id,
    path = row.node.path,
    kind = row.node.kind or "file",
    label = tostring(row.node.label),
    line = line,
    expandable = row.expandable == true,
    expanded = row.expanded == true,
  }
end

---The row of the selection; nil for an empty folder and without a selection.
---@return Filetree.Embed.Current|nil
function Embed:current()
  if self.closed or not self._line then return nil end
  return self:_describe(self._line)
end

---Move the selection by `delta` rows (it stops at the first and at the last row).
---@param delta integer
---@return Filetree.Embed.Current|nil current
function Embed:move(delta)
  if self.closed or self._tree:count() == 0 then return nil end
  return self:select((self._line or 1) + (tonumber(delta) or 0))
end

---Put the selection on a line (clamped to the rows there are) or on the row of a path.
---@param target integer|string  A 1-based line, or a path.
---@return Filetree.Embed.Current|nil current  nil for a path that is no row.
function Embed:select(target)
  if self.closed or self._tree:count() == 0 then return nil end
  local line
  if type(target) == "string" then
    line = self._tree:row_of(list.norm(target))
    if not line then return nil end
  else
    line = math.min(math.max(math.floor(tonumber(target) or 1), 1), self._tree:count())
  end
  self._line = line
  self._selected = self._tree:row(line).id
  self:_draw()
  return self:current()
end

---@private
---@param id? string  Default: the selection.
---@return string|nil
function Embed:_target(id)
  if id ~= nil then return self._tree:node(list.norm(id)) and list.norm(id) or nil end
  return self._selected
end

---Open a folder (default: the one under the selection).
---@param id? string  A path.
---@return boolean opened  false for a file, a folder that is open, and a path that is no row.
function Embed:expand(id)
  if self.closed then return false end
  local target = self:_target(id)
  local line = target and self._tree:row_of(target) or nil
  local row = line and self._tree:row(line) or nil
  if not row or not row.expandable or row.expanded then return false end
  self._tree:expand(target)
  self:_draw()
  return self._tree:is_expanded(target)
end

---Close a folder (default: the one under the selection).
---@param id? string  A path.
---@return boolean closed
function Embed:collapse(id)
  if self.closed then return false end
  local target = self:_target(id)
  if not target or target == self.root or not self._tree:is_expanded(target) then return false end
  self._tree:collapse(target)
  self:_draw()
  return true
end

---Open the folder under the selection, or close it when it is open.
---@param id? string  A path.
---@return boolean changed
function Embed:toggle(id)
  if self.closed then return false end
  local target = self:_target(id)
  if not target then return false end
  if self._tree:is_expanded(target) then return self:collapse(target) end
  return self:expand(target)
end

---Give everything back: the watcher handles, the highlights. The buffer is the caller's and stays,
---with the lines it has. The handle answers nothing afterwards. Safe to call twice.
function Embed:close()
  if self.closed then return end
  self.closed = true
  if self._unsubscribe then
    self._unsubscribe()
    self._unsubscribe = nil
  end
  for _, unwatch in pairs(self._unwatch) do
    unwatch()
  end
  self._unwatch = {}
  if api.nvim_buf_is_valid(self.buf) then api.nvim_buf_clear_namespace(self.buf, NS, 0, -1) end
end

---Draw the directory tree of `root` into `buf`.
---@param buf integer  A buffer of the caller (a scratch buffer of a float).
---@param root string  A directory.
---@param opts? Filetree.Embed.Opts
---@return Filetree.Embed|nil handle
---@return string|nil err  Why there is none: no such buffer, no such directory.
function M.open(buf, root, opts)
  if type(buf) ~= "number" or not api.nvim_buf_is_valid(buf) then return nil, "no such buffer" end
  if type(root) ~= "string" or root == "" then return nil, "no directory given" end
  root = list.norm(vim.fn.fnamemodify(root, ":p"))
  local stat = vim.uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then return nil, "not a directory: " .. root end
  -- The groups the lines are drawn with are the tree window's. Defined only while they are missing
  -- (no tree window was opened yet): defining a group forces a full redraw, and a hover opens often.
  if vim.tbl_isempty(api.nvim_get_hl(0, { name = "FiletreeEmbedSelection" })) then
    require("filetree.native.view").define_highlights()
  end

  ---@type Filetree.Embed
  local self = setmetatable({
    buf = buf,
    root = root,
    closed = false,
    _opts = opts or {},
    _unwatch = {},
    _watching = false,
  }, Embed)
  self:_build()
  if self._opts.watch == true then
    local watch = require("filetree.native.fs.watch")
    self._watching = true
    self:_watch_dir(root)
    if not watch.recursive then
      for id in pairs(self._loaded) do
        self:_watch_dir(id)
      end
    end
    self._unsubscribe = watch.subscribe(function(dirs)
      if self.closed then return end
      for _, dir in ipairs(dirs) do
        if list.inside(root, dir) then
          self:refresh()
          return
        end
      end
    end, function()
      -- The watch that covered everything below the root is gone (the helper process ended). What
      -- was held for a folder below the root was one more reference to that watch: given back,
      -- and taken again as a handle of the folder's own.
      if self.closed then return end
      for dir, unwatch in pairs(self._unwatch) do
        if dir ~= root then
          unwatch()
          self._unwatch[dir] = nil
        end
      end
      for id in pairs(self._loaded) do
        self:_watch_dir(id)
      end
    end)
  end
  self:_draw()
  return self, nil
end

return M
