---@module 'filetree.native.view'
---@brief One tree window of the own tree: its model, its buffer, its cursor.
---@description
--- A view owns a `lib.nvim.tree` instance over the `files` source, the buffer its rows are written to
--- and the window that shows it. What is open, where the cursor is and how the listing is sorted
--- belong to the view and survive closing the window; what is on disk comes from the shared directory
--- cache (`filetree.native.fs.list`).
---
--- Key responsibilities:
--- - Apply the tree's splices to the buffer: one `nvim_buf_set_lines` per changed range
--- - Keep the cursor on its node (by id) when lines above it come and go
--- - Draw highlights for the visible lines only (decoration provider, ephemeral extmarks)
--- - Open, close and place the window: `left`, `right`, `float`, `current`
---
--- The buffer text is indent, expander, icon and name (`filetree.native.render.line`). Features
--- reach a view through `filetree.adapter.native`, not through this module.

local tree_core = require("lib.nvim.tree")
local list = require("filetree.native.fs.list")
local files = require("filetree.native.source.files")
local watch = require("filetree.native.fs.watch")
local render = require("filetree.native.render.line")
local columns = require("filetree.native.render.columns")
local decor = require("filetree.native.decor")
local pane_mod = require("filetree.native.pane")

local api = vim.api

local M = {}

M.FILETYPE = "filetree"

local NS = api.nvim_create_namespace("filetree_native")
local AUGROUP = api.nvim_create_augroup("filetree_native_view", { clear = true })

--- Tree highlight group -> the editor group it links to by default.
---@type table<string, string>
M.HL = {
  FiletreeDirectory = "Directory",
  FiletreeName = "Normal",
  FiletreeIndent = "NonText",
  FiletreeExpander = "NonText",
  FiletreeRoot = "Title",
  FiletreeFolderIcon = "Directory",
  FiletreeMore = "Comment",
  FiletreeOpened = "Special",
  FiletreeModified = "DiagnosticWarn",
}

--- Node kinds that are a line of text and no entry: no icon, no badge, drawn like a comment.
---@type table<string, true>
local QUIET = { more = true, unavailable = true, note = true }

---@type table<integer, Filetree.View>  buffer -> view
local by_buf = {}
---@type table<string, string>  icon name -> highlight group, created once
local icon_groups = {}
---@type (fun(bufnr: integer?))[]
local render_listeners = {}
---@type fun()  Defined with the drawing code below.
local redraw_views
---@type table<integer, integer>  window -> columns its text may use, read once per redraw
local text_width = {}

---@class Filetree.View
---@field root string  Normalized root directory.
---@field buf integer?
---@field win integer?
---@field position FiletreeTreePosition
---@field tree Lib.Tree
---@field sort { kind: "name"|"size"|"mtime", descending: boolean }
---@field hide_ignored boolean
---@field cursor_id string?
---@field root_error string?  Why the root could not be read, when it could not.
---@field view_name string  The view on screen: "files", or the name of a view of registered sources.
---@field private _panes table<string, Filetree.Pane>  The trees of the other views, by view name.
---@field private _pane Filetree.Pane?  The one on screen; nil while the files are shown.
---@field private _files_cursor any  Where the cursor of the files was when another view took over.
---@field private _deferred (fun())[]  Changes of the file listing asked for while another view was shown.
---@field private _relist_pending boolean?  One of them is "build the listing again".
---@field actions Filetree.Action.Table?  Every key of the buffer (`filetree.native.action`).
---@field _feature_maps table<string, table>?  The feature mappings the action table took over, by lhs.
---@field _running table<string, table<string, true>>?  Per key, the actions running on it right now.
---@field _foreign table<string, true>?  Keys the user or another plugin mapped on the buffer: the table leaves them alone.
---@field width integer
---@field height integer  Of a tree at the top or bottom.
---@field private _sync boolean
---@field private _loaded table<string, true>  Folder ids whose children were read.
---@field private _alias table<string, string>  A folder inside a merged line -> the id of that line.
---@field private _prev_buf integer?  The buffer a `current` view replaced.
---@field private _watches table<string, fun()>  Watched folder -> give the reference back.
---@field private _unsubscribe_watch fun()?
---@field private _reading table<string, boolean>  Folder ids being read again: true = read once more after this one.
---@field private _generation integer  Counts the trees this view has built.
---@field main Lib.Tree  The tree of the files; `tree` is what is on screen (the same, or the hits of a search).
---@field private _known table<string, true>  Every path the view has made a node of.
---@field private _known_dirs table<string, true>
---@field private _search Filetree.View.Search?
---@field private _search_gen integer?
---@field private _main_cursor string?  Where the cursor of the main tree was when the search began.
---@field private _seen_closed boolean?  The window was closed at least once.
---@field private _opts Filetree.View.Opts
---@field private _loader_fn fun(node: Filetree.Node, cb: fun(list?: Filetree.Node[], err?: string))
local View = {}
View.__index = View

---@class Filetree.View.Search
---@field query string
---@field hits string[]  The hits that are shown, `max` at most.
---@field total integer  Every hit, shown or not.
---@field dirs table<string, true>
---@field known table<string, true>  The hits from what the view had read; the listing does not count them twice.
---@field max integer
---@field done boolean
---@field pending boolean
---@field cancel? fun()

---@class Filetree.View.Opts
---@field root string
---@field position? FiletreeTreePosition
---@field width? integer
---@field height? integer  Height of a tree at the top or bottom.
---@field group_empty? boolean
---@field hide? fun(): fun(name: string, path: string): boolean  Answers the test for the names `hide_ignored` hides; asked once per listing.
---@field icons? boolean  false: no icons at all.
---@field max_entries? integer  Entries shown per folder (see `Filetree.Files.Opts`).
---@field watch? boolean  Follow changes on disk while the tree is shown (default true).
---@field search_max? integer  Hits a search shows at most (default 1000).
---@field search_tier? "fd"|"rg"|"lua"  Force how a search lists files (specs).
---@field views? fun(): Filetree.View.Spec[]  The views there are, in the order of the view bar (default: the files only).

---One view: a name and the sources it shows, one section each.
---@class Filetree.View.Spec
---@field name string
---@field sources string[]

local function define_highlights()
  for group, link in pairs(M.HL) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---@param row Lib.Tree.Row
---@return string|nil glyph
---@return string|nil hl
local function icon_of(row)
  local node = row.node
  if QUIET[node.kind] then return nil, nil end
  -- a source's own glyph for the node wins over what the name would get
  if type(node.icon) == "string" and node.icon ~= "" then return node.icon, nil end
  local nerd = require("lib.nvim.ui.nerd_font").available()
  if row.expandable or node.kind == "dir" then
    -- a group of a source (no path) is no folder: its expander says enough
    if not nerd or not (node.kind == "dir" or node.path) then return nil, nil end
    return row.expanded and "" or "", "FiletreeFolderIcon"
  end
  -- a leaf that is no file (a symbol, a terminal) has no file type to draw
  if not node.path then return nil, nil end
  local icons = require("lib.nvim.ui.icons")
  local glyph, color, name = icons.get(row.node.label, nil, { fallback = "" })
  if not glyph or glyph == "" then return nil, nil end
  local key = name or "Default"
  local group = icon_groups[key]
  if not group then
    -- once per icon name: defining a group forces a full redraw, so never while drawing a line twice
    group = icons.hl_group(key, color)
    icon_groups[key] = group
  end
  return glyph, group
end

---@param self Filetree.View
---@return Filetree.LineOpts
local function line_opts(self)
  return {
    icon = self._opts.icons ~= false and icon_of or nil,
    trailing_slash = true,
  }
end

---@param self Filetree.View
---@param row Lib.Tree.Row
---@return Filetree.Line
local function line_of_row(self, row)
  local line = render.render(row, line_opts(self))
  local kind = row.node.kind
  -- the head of a section stands where the root of the files stands
  local head = row.id == self.root or (self._pane ~= nil and row.depth == 0)
  local whole = (QUIET[kind] and "FiletreeMore") or (head and "FiletreeRoot") or nil
  if whole then
    for _, span in ipairs(line.spans) do
      if span.col_start >= line.name_start then span.hl = whole end
    end
  end
  return line
end

-- ── model ──────────────────────────────────────────────────────────────────────

---@private
---@return fun(name: string, path: string): boolean
function View:_hide()
  if not self.hide_ignored or not self._opts.hide then
    return function()
      return false
    end
  end
  -- asked once per listing, not once per entry: the factory may be costly (it resolves a feature)
  return self._opts.hide()
end

---The lazy `children` of every folder node of this view.
---@private
---@return fun(node: Filetree.Node, cb: fun(list?: Filetree.Node[], err?: string))
function View:_loader()
  local loader
  loader = function(node, cb)
    local dir = node.path
    local function done(entries, err)
      if not entries then
        cb(nil, err)
        return
      end
      self._loaded[node.id] = true
      self:_watch_dir(dir)
      cb(self:_nodes(dir, entries, loader))
    end
    -- The cache may hold this folder from a look into it (merging `a/b/c` reads ahead). Without a
    -- watcher on it nobody would have said that it changed since: read it now.
    if not watch.covers(dir) then list.invalidate(dir) end
    if self._sync then
      done(list.list_sync(dir))
    else
      list.list(dir, done)
    end
  end
  return loader
end

---@private
---@param dir string
---@param entries Filetree.Fs.Entry[]
---@param loader function
---@return Filetree.Node[]
function View:_nodes(dir, entries, loader)
  local nodes = files.nodes(entries, {
    dir = dir,
    max_entries = self._opts.max_entries,
    loader = loader,
    sort = self.sort,
    hide = self:_hide(),
    group_empty = self._opts.group_empty,
  })
  for _, node in ipairs(nodes) do
    if node.path then
      self._known[node.path] = true
      if node.kind == "dir" then self._known_dirs[node.path] = true end
    end
    local chain = node.data and node.data.chain
    if chain then
      for i = 1, #chain - 1 do
        self._alias[chain[i]] = node.id
      end
      if not watch.recursive then
        -- every folder of the line decides what the line is; none of them is loaded
        for _, member in ipairs(chain) do
          self:_watch_dir(member)
        end
      end
    end
  end
  return nodes
end

---Run `fn` with folders read synchronously, so that what it expands is there when it returns.
---@private
---@param fn fun()
function View:_now(fn)
  local was = self._sync
  self._sync = true
  local ok, err = pcall(fn)
  self._sync = was
  if not ok then error(err, 0) end
end

---@private
function View:_build()
  self:_drop_search()
  self._loaded, self._alias, self._reading = {}, {}, {}
  self._known, self._known_dirs = {}, {}
  self._generation = (self._generation or 0) + 1
  -- the handles belong to the folders of the old tree; a view that was following keeps following
  local following = self._unsubscribe_watch ~= nil
  self:_unwatch()
  local root = self.root
  self._loader_fn = self:_loader()
  -- The root is read here and handed over as a list: the tree core counts a root as open from the
  -- start, so it never asks a lazy root for its children.
  local entries, err = list.list_sync(root)
  local built
  self.root_error = entries == nil and err or nil
  self._loaded[root] = true
  built = tree_core.new({
    root = {
      id = root,
      label = root == "/" and "" or list.basename(root),
      kind = "dir",
      path = root,
      children = self:_nodes(root, entries or {}, self._loader_fn),
    },
    on_change = function(changes)
      -- an answer for a tree this view no longer shows (the root changed while a folder was read)
      if self.main == built then self:_apply_main(changes) end
    end,
  })
  self.main = built
  -- another view on screen stays on screen: the files are rebuilt underneath it
  if not self._pane then self.tree = built end
  if following then self:_watch() end
end

-- ── following the disk ─────────────────────────────────────────────────────────

---@private
---@param dir string
function View:_watch_dir(dir)
  if not self._unsubscribe_watch or self._watches[dir] then return end
  self._watches[dir] = (watch.watch(dir))
end

---Start following the folders this view has read. Called when its window appears.
---@private
function View:_watch()
  if self._opts.watch == false or self._unsubscribe_watch then return end
  self._unsubscribe_watch = watch.subscribe(function(dirs)
    self:_changed(dirs)
  end)
  self:_watch_dir(self.root)
  if not watch.recursive then
    for id in pairs(self._loaded) do
      local node = self.main:node(id)
      if node and node.path then self:_watch_dir(node.path) end
    end
    for member, id in pairs(self._alias) do
      self:_watch_dir(member)
      self:_watch_dir(id)
    end
  end
end

---Stop following; the handles close when no other view holds them.
---@private
function View:_unwatch()
  if self._unsubscribe_watch then
    self._unsubscribe_watch()
    self._unsubscribe_watch = nil
  end
  for _, unwatch in pairs(self._watches or {}) do
    unwatch()
  end
  self._watches = {}
end

---Folders changed on disk: read again the ones this view has read, and no other.
---@private
---@param dirs string[]
function View:_changed(dirs)
  local seen = {}
  for _, dir in ipairs(dirs) do
    list.invalidate(dir)
    local id = self:id_of(dir)
    -- a folder of a merged line `a/b/c` (the innermost one too, while it is not loaded): what has
    -- to be listed again is the folder the line is in
    local node = self.main:node(id)
    local merged = node and node.data and node.data.chain ~= nil
    if id ~= dir or (merged and not self._loaded[id]) then id = self.main:parent(id) or id end
    if self._loaded[id] and not seen[id] then
      seen[id] = true
      self:refresh_dir(id)
    end
  end
end

---Read the folder `path` lies in again, when this view has read it (an operation on `path` is done).
---A folder the view never read has nothing on screen to bring up to date.
---@param path string
---@return boolean reading
function View:refresh_path(path)
  local parent = list.parent(list.norm(path))
  if not parent or not list.inside(self.root, parent) then return false end
  local id = self:id_of(parent)
  if not (self._loaded[id] and self.main:node(id)) then return false end
  self:refresh_dir(id)
  return true
end

---Read one folder again, without blocking, and take over what changed. At most one read per folder
---runs; a change that arrives meanwhile is answered by one more read after it, however many there were.
---@param id string  The id of a folder this view has read.
function View:refresh_dir(id)
  if self._reading[id] ~= nil then
    self._reading[id] = true
    return
  end
  local node = self.main:node(id)
  if not node or not node.path then return end
  self._reading[id] = false
  local generation = self._generation
  local dir = node.path
  list.invalidate(dir)
  list.list(dir, function(entries)
    -- the view shows another tree by now: this answer belongs to none of its folders
    if generation ~= self._generation then return end
    local again = self._reading[id]
    self._reading[id] = nil
    if not self.main:node(id) then return end
    self:sync_cursor()
    if entries then
      self:_apply_main(self.main:merge_children(id, self:_nodes(dir, entries, self._loader_fn)))
    elseif id ~= self.root then
      self._loaded[id] = nil
      self:_apply_main(self.main:remove(id))
    end
    if again then self:refresh_dir(id) end
  end)
end

-- ── buffer ─────────────────────────────────────────────────────────────────────

---@private
---@return integer buf
function View:_ensure_buf()
  if self.buf and api.nvim_buf_is_valid(self.buf) then return self.buf end
  local buf = api.nvim_create_buf(false, true)
  self.buf = buf
  by_buf[buf] = self
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  -- set before FileType, so that whoever reacts to the filetype can already ask which view this is
  vim.b[buf].filetree_view = self.view_name
  require("filetree.native.action").attach(self, buf)
  self:_draw_all()
  vim.bo[buf].filetype = M.FILETYPE
  api.nvim_create_autocmd("CursorMoved", {
    group = AUGROUP,
    buffer = buf,
    callback = function()
      if
        self.win
        and api.nvim_win_is_valid(self.win)
        and api.nvim_get_current_win() == self.win
      then
        local row = self.tree:row(api.nvim_win_get_cursor(self.win)[1])
        self.cursor_id = row and row.id or self.cursor_id
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = AUGROUP,
    buffer = buf,
    callback = function()
      by_buf[buf] = nil
      if self.buf == buf then
        self.buf, self.win = nil, nil
      end
    end,
  })
  return buf
end

---@private
---@param from integer  1-based first row.
---@param count integer
---@return string[]
function View:_texts(from, count)
  local out = {}
  for i = from, from + count - 1 do
    local row = self.tree:row(i)
    out[#out + 1] = row and line_of_row(self, row).text or ""
  end
  return out
end

---@private
---@param fn fun(buf: integer)
function View:_write(fn)
  local buf = self.buf
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn, buf)
  vim.bo[buf].modifiable = false
  if not ok then error(err, 0) end
end

---@private
function View:_draw_all()
  self:_write(function(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, self:_texts(1, self.tree:count()))
  end)
  self:_after_draw()
end

---Write every line again from the model, without reading the disk.
function View:redraw()
  if self.buf and api.nvim_buf_is_valid(self.buf) then self:_draw_all() end
end

---Write rows of the main tree, when it is the one on screen. While a search is laid over it, the
---main tree keeps changing underneath (a folder read again) and the buffer shows the hits.
---@private
---@param changes Lib.Tree.Splice[]
function View:_apply_main(changes)
  if self.tree == self.main then self:_apply(changes) end
end

---Forget a search without drawing: the tree it lies over is about to be replaced.
---@private
function View:_drop_search()
  local search = self._search
  if not search then return end
  self._search = nil
  self._search_gen = (self._search_gen or 0) + 1
  if search.cancel then search.cancel() end
  self._main_cursor = nil
end

---Write the rows the tree reported as changed.
---@private
---@param changes Lib.Tree.Splice[]
function View:_apply(changes)
  if #changes == 0 then return end
  local buf = self.buf
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  self:_write(function()
    for _, c in ipairs(changes) do
      -- rows are read back from the tree as it is now; a later splice of the same batch corrects what an
      -- earlier one read too early, and the line count is checked below
      api.nvim_buf_set_lines(
        buf,
        c.from - 1,
        c.from - 1 + c.old_count,
        false,
        self:_texts(c.from, c.new_count)
      )
    end
  end)
  if api.nvim_buf_line_count(buf) ~= math.max(1, self.tree:count()) then
    self:_draw_all()
    return
  end
  self:_after_draw()
end

---@private
function View:_after_draw()
  -- nodes of a source that start open: their rows are written by a call of _apply of their own
  if self._pane then self._pane:open_pending() end
  self:_place_cursor()
  local buf = self.buf
  for _, fn in ipairs(render_listeners) do
    pcall(fn, buf)
  end
end

---Take the node under the window's cursor as the one the cursor belongs to. Called before the model
---changes: a cursor moved by `nvim_win_set_cursor` reports `CursorMoved` only later, and the rows it
---was moved on are about to shift.
function View:sync_cursor()
  local win = self.win
  if not win or not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= self.buf then
    return
  end
  local row = self.tree:row(api.nvim_win_get_cursor(win)[1])
  if row then self.cursor_id = row.id end
end

---Move the cursor of the tree window to a line; the node there is the one it belongs to from now on.
---@param line integer  1-based.
---@return boolean
function View:set_cursor(line)
  local row = self.tree:row(line)
  if not row then return false end
  self.cursor_id = row.id
  self:_place_cursor()
  return true
end

---Put the window's cursor back on the node it belongs to.
---@private
function View:_place_cursor()
  local win = self.win
  if not win or not api.nvim_win_is_valid(win) or not self.cursor_id then return end
  local row = self.tree:row_of(self.cursor_id)
  if not row then
    -- the node is gone: stay on the line, or on the last one
    row = math.min(api.nvim_win_get_cursor(win)[1], math.max(1, self.tree:count()))
    local at = self.tree:row(row)
    self.cursor_id = at and at.id or nil
  end
  if api.nvim_win_get_cursor(win)[1] ~= row then pcall(api.nvim_win_set_cursor, win, { row, 0 }) end
end

-- ── window ─────────────────────────────────────────────────────────────────────

---@param win integer
---@param fixed false|"width"|"height"  A docked window: pinned width (side) or height (top, bottom) and buffer.
local function window_options(win, fixed)
  -- [0]: local to this window and this buffer, the window's own defaults stay as they are (a file
  -- opened into the same window later, or a split off it, must not inherit a tree's options)
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.spell = false
  wo.list = false
  wo.cursorline = true
  wo.signcolumn = "auto"
  wo.foldcolumn = "0"
  -- a tree has nothing to fold, and an inherited 'foldexpr' is evaluated once per line and change
  wo.foldmethod = "manual"
  wo.foldenable = false
  if fixed then
    if fixed == "height" then
      wo.winfixheight = true
    else
      wo.winfixwidth = true
    end
    if vim.fn.exists("&winfixbuf") == 1 then wo.winfixbuf = true end
  end
end

---Is the window of this view on screen (in the current tab)?
---@return boolean
function View:is_open()
  local win = self.win
  if not win or not api.nvim_win_is_valid(win) then return false end
  if api.nvim_win_get_buf(win) ~= self.buf then return false end
  return api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage()
end

---Show the view. An open view at another position is moved there.
---@param position? FiletreeTreePosition  Default: where it was last.
---@param focus? boolean  Enter the tree window (default true).
---@return boolean
function View:open(position, focus)
  position = position or self.position
  if self:is_open() then
    if position == self.position then
      if focus ~= false then api.nvim_set_current_win(self.win) end
      return true
    end
    self:close()
  end
  define_highlights()
  decor.start(redraw_views)
  local buf = self:_ensure_buf()
  local origin = api.nvim_get_current_win()
  local win
  if position == "float" then
    local width = math.max(20, math.min(80, vim.o.columns - 8))
    local height = math.max(5, vim.o.lines - 8)
    win = api.nvim_open_win(buf, focus ~= false, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      border = "rounded",
      title = " " .. list.basename(self.root) .. " ",
      title_pos = "center",
    })
    window_options(win, false)
  elseif position == "current" then
    win = origin
    self._prev_buf = api.nvim_win_get_buf(win)
    api.nvim_win_set_buf(win, buf)
    window_options(win, false)
  elseif position == "top" or position == "bottom" then
    -- a full-width split at the top or bottom edge, like a quickfix list
    win = api.nvim_open_win(buf, focus ~= false, {
      split = position == "top" and "above" or "below",
      win = -1,
      height = self.height,
    })
    window_options(win, "height")
  else
    -- A full-height split at the edge, made without entering it: a tree that is only shown
    -- (`focus = false`) must not look like a window the user was in and left.
    win = api.nvim_open_win(buf, focus ~= false, {
      split = position == "right" and "right" or "left",
      win = -1,
      width = self.width,
    })
    window_options(win, "width")
  end
  self.win, self.position = win, position
  if position ~= "current" then
    -- closed by `:q`, by a closed tab or by another plugin: the same end as close()
    api.nvim_create_autocmd("WinClosed", {
      group = AUGROUP,
      pattern = tostring(win),
      once = true,
      callback = function()
        if self.win == win then self:_window_gone() end
      end,
    })
  end
  self:_place_cursor()
  if self._pane then
    -- nothing was followed while the window was away: ask the sources again, then follow them
    if self._seen_closed then self._pane:reload() end
    self._pane:start()
  end
  local was_watching = self._unsubscribe_watch ~= nil
  self:_watch()
  if self._seen_closed and not was_watching and self._unsubscribe_watch then
    -- nothing was followed while the window was away: read what this view shows again, in the background
    list.invalidate()
    for id in pairs(self._loaded) do
      self:refresh_dir(id)
    end
  end
  return true
end

---Take the view off the screen. Its state stays.
---@return boolean
function View:close()
  local win = self.win
  if not self:is_open() or not win then return false end
  if self.position == "current" then
    local back = self._prev_buf
    if back and api.nvim_buf_is_valid(back) then
      api.nvim_win_set_buf(win, back)
    else
      api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
    end
  else
    local others = 0
    for _, other in ipairs(api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(win))) do
      if other ~= win and api.nvim_win_get_config(other).relative == "" then others = others + 1 end
    end
    if self.position == "float" or others > 0 then
      pcall(api.nvim_win_close, win, true)
    else
      -- the only window of its tab: closing it would close the tab (or fail in the last tab), so
      -- the window stays and shows an empty buffer
      if vim.fn.exists("&winfixbuf") == 1 then vim.wo[win][0].winfixbuf = false end
      vim.wo[win][0].winfixwidth = false
      vim.wo[win][0].winfixheight = false
      api.nvim_win_call(win, function()
        vim.cmd("enew")
      end)
    end
  end
  self:_window_gone()
  return true
end

---The window is off the screen: stop following the disk until it is shown again.
---@private
function View:_window_gone()
  self.win = nil
  self._seen_closed = true
  self:_unwatch()
  if self._pane then self._pane:stop() end
end

---Give up everything this view holds: its handles and its buffer. The view is not usable afterwards.
function View:dispose()
  self:_window_gone()
  for _, pane in pairs(self._panes) do
    pane:stop()
  end
  self._panes, self._pane = {}, nil
  local buf = self.buf
  if buf and api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  self.buf = nil
end

-- ── nodes and lines ────────────────────────────────────────────────────────────

---The id a path is shown under: its own, or the merged line it is part of.
---@param path string  Normalized.
---@return string
function View:id_of(path)
  if self._pane then
    local shown = self._pane:id_of(path)
    if shown ~= nil then return shown end
    return path
  end
  local id = self._alias[path]
  -- a merged line that was split or removed since leaves its folders their own ids again
  if id and self.main:node(id) then return id end
  return path
end

---@param line integer  1-based.
---@return Lib.Tree.Row|nil
function View:row(line)
  return self.tree:row(line)
end

---@param path string  Normalized.
---@return integer|nil line  1-based.
function View:line_of(path)
  return self.tree:row_of(self:id_of(path))
end

---The row under the cursor of the tree window (the remembered one while the window is closed).
---@return Lib.Tree.Row|nil
function View:current()
  if self:is_open() and self.win then return self.tree:row(api.nvim_win_get_cursor(self.win)[1]) end
  local line = self.cursor_id and self.tree:row_of(self.cursor_id)
  return line and self.tree:row(line) or nil
end

---Open a folder. Read at once, so its children are rows when this returns.
---@param id string
---@return boolean
function View:expand(id)
  self:sync_cursor()
  local row = self.tree:row_of(id)
  if not row or not self.tree:row(row).expandable then return false end
  self:_now(function()
    self:_apply(self.tree:expand(id))
  end)
  return true
end

---@param id string
---@return boolean
function View:collapse(id)
  self:sync_cursor()
  if id == self.root or not self.tree:is_expanded(id) then return false end
  self:_apply(self.tree:collapse(id))
  return true
end

---Open or close the folder on a row; a folder being read is left alone.
---@param id string
function View:toggle(id)
  self:sync_cursor()
  if self.tree:is_expanded(id) then
    self:collapse(id)
  else
    local row = self.tree:row_of(id)
    if row and self.tree:row(row).expandable then self:_apply(self.tree:expand(id)) end
  end
end

---Make a path a row: open every folder on the way from the root, then put the cursor on it.
---@param path string  Normalized; below the root.
---@return boolean found
function View:reveal(path)
  if self._pane then
    -- another view: the path is a row where a source shows a node for it, and nowhere else
    local id = self._pane:id_of(path)
    if id == nil then return false end
    self:sync_cursor()
    self:_apply(self.tree:reveal(id))
    if not self.tree:row_of(id) then return false end
    self.cursor_id = id
    self:_place_cursor()
    return true
  end
  if not list.inside(self.root, path) then return false end
  local chain = {}
  local current = path
  while current and current ~= self.root do
    table.insert(chain, 1, current)
    current = list.parent(current)
  end
  self:_now(function()
    for i = 1, #chain - 1 do
      local id = self:id_of(chain[i])
      if self.tree:node(id) and not self.tree:is_expanded(id) then
        self:_apply(self.tree:expand(id))
      end
    end
  end)
  local id = self:id_of(path)
  if not self.tree:row_of(id) then return false end
  self.cursor_id = id
  self:_place_cursor()
  return true
end

---Close every folder; with `keep`, the folders on the way to that path stay open.
---@param keep? string  Normalized path.
function View:collapse_all(keep)
  self:sync_cursor()
  if self._pane then
    -- the sections stay open: closed, they would hide that the view has anything in it
    local heads = {}
    for _, section in ipairs(self._pane:sections()) do
      heads[section.id] = true
    end
    local at = self.cursor_id
    while at ~= nil and not heads[at] do
      at = self.tree:parent(at)
    end
    self:_apply(self.tree:collapse_all())
    for _, section in ipairs(self._pane:sections()) do
      self:_apply(self.tree:expand(section.id))
    end
    if at ~= nil then self.cursor_id = at end
    self:_place_cursor()
    if keep then self:reveal(keep) end
    return
  end
  -- the top-level entry the cursor is under, found while its ancestors are still rows
  local top = nil
  local current = self.cursor_id
  while current and current ~= self.root do
    top = current
    current = self.tree:parent(current)
  end
  local first = self.tree:row(2)
  self.cursor_id = top or (first and first.id) or self.root
  self:_apply(self.tree:collapse_all())
  if keep then self:reveal(keep) end
end

---The folders that are open, outermost first.
---@return string[]
function View:expanded_paths()
  local out = {}
  for id in pairs(self._loaded) do
    if id ~= self.root and self.main:is_expanded(id) then
      local node = self.main:node(id)
      if node then out[#out + 1] = node.path end
    end
  end
  table.sort(out, function(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end)
  return out
end

---Open the given folders (the ones that still exist).
---@param paths string[]
function View:expand_paths(paths)
  if self._pane then
    -- folders of the files: opened when the files are shown again
    self._deferred[#self._deferred + 1] = function()
      self:expand_paths(paths)
    end
    return
  end
  self:clear_search()
  self:sync_cursor()
  local sorted = vim.list_slice(paths)
  table.sort(sorted, function(a, b)
    return #a < #b
  end)
  local keep = self.cursor_id
  for _, path in ipairs(sorted) do
    local norm = list.norm(path)
    if self:reveal(norm) then self:expand(self:id_of(norm)) end
  end
  self.cursor_id = keep
  self:_place_cursor()
end

-- ── search ─────────────────────────────────────────────────────────────────────
-- The hits of a search are a tree of their own, laid over the view. The main tree is never touched
-- by it: what is open there, where its cursor was, what it has read stays as it is, and clearing the
-- search shows it again. There is nothing to restore, so nothing a late answer could undo.

---@param query string
---@return fun(rel: string): boolean
local function matcher(query)
  -- every word has to occur; lower case matches both cases, an upper-case letter makes it exact
  local exact = query:find("%u") ~= nil
  local words = vim.split(exact and query or query:lower(), "%s+", { trimempty = true })
  return function(rel)
    local text = exact and rel or rel:lower()
    for _, word in ipairs(words) do
      if not text:find(word, 1, true) then return false end
    end
    return true
  end
end

---The hits as nodes: every folder on the way to a hit, folders first, all of them open.
---@param root string
---@param label string
---@param hits string[]  Normalized paths below `root`.
---@param dirs table<string, true>  Which of the hits are folders.
---@param more integer  Hits that are not shown.
---@return Filetree.Node root_node
---@return table<string, true> expanded
local function overlay_nodes(root, label, hits, dirs, more)
  local nodes = { [root] = { id = root, label = label, kind = "dir", path = root, children = {} } }
  local expanded = { [root] = true }
  local function folder(path)
    local node = nodes[path]
    if node then return node end
    node = { id = path, label = list.basename(path), kind = "dir", path = path, children = {} }
    nodes[path] = node
    expanded[path] = true
    table.insert(folder(list.parent(path) or root).children, node)
    return node
  end
  for _, path in ipairs(hits) do
    if dirs[path] then
      folder(path)
    elseif not nodes[path] then
      local node = { id = path, label = list.basename(path), kind = "file", path = path }
      nodes[path] = node
      table.insert(folder(list.parent(path) or root).children, node)
    end
  end
  for _, node in pairs(nodes) do
    if node.children then
      table.sort(node.children, function(a, b)
        if (a.kind == "dir") ~= (b.kind == "dir") then return a.kind == "dir" end
        local la, lb = a.label:lower(), b.label:lower()
        if la ~= lb then return la < lb end
        return a.label < b.label
      end)
    end
  end
  if more > 0 then
    table.insert(nodes[root].children, {
      id = root .. "//more",
      label = ("… %d more hits (showing %d, narrow the search)"):format(more, #hits),
      kind = "more",
    })
  end
  return nodes[root], expanded
end

---Draw the hits found so far.
---@private
function View:_search_draw()
  local search = self._search
  if not search then return end
  search.pending = false
  local state = search.done and "" or " …"
  local label = ("%s  /%s  %d%s"):format(
    list.basename(self.root),
    search.query,
    search.total,
    state
  )
  local root_node, expanded =
    overlay_nodes(self.root, label, search.hits, search.dirs, search.total - #search.hits)
  self.tree = tree_core.new({ root = root_node, expanded = expanded })
  -- the cursor goes to the first hit unless it is on one that is still there
  if not (self.cursor_id and self.tree:row_of(self.cursor_id) and self.cursor_id ~= self.root) then
    local first = nil
    for i = 2, self.tree:count() do
      local row = self.tree:row(i)
      if row.node.kind == "file" then
        first = row.id
        break
      end
    end
    self.cursor_id = first or (self.tree:row(2) and self.tree:row(2).id) or self.root
  end
  self:_draw_all()
end

---Show the entries whose path below the root contains every word of `query`: at once from what the
---view has read, and from every folder below the root as the listing comes in. An empty query clears.
---@param query string
---@return boolean searching
function View:search(query)
  query = vim.trim(query or "")
  if query == "" then
    self:clear_search()
    return false
  end
  -- the search lists files below the root; another view has no folder to search
  if self._pane then return false end
  if not self._search then
    self:sync_cursor()
    self._main_cursor = self.cursor_id
  elseif self._search.cancel then
    self._search.cancel()
  end
  self._search_gen = (self._search_gen or 0) + 1
  local gen = self._search_gen
  local matches = matcher(query)
  local prefix = #list.join(self.root, "")
  ---@type Filetree.View.Search
  local search = {
    query = query,
    hits = {},
    total = 0,
    dirs = {},
    known = {},
    max = self._opts.search_max or 1000,
    done = false,
    pending = false,
  }
  self._search = search
  ---@param paths string[]
  ---@param from_view boolean  Paths the view has read (else: from the listing).
  local function add(paths, from_view)
    for _, path in ipairs(paths) do
      if (from_view or not search.known[path]) and matches(path:sub(prefix + 1)) then
        if from_view then search.known[path] = true end
        search.total = search.total + 1
        -- beyond the limit a hit is only counted: a one-letter query in a huge tree keeps no list
        if #search.hits < search.max then
          search.hits[#search.hits + 1] = path
          if from_view and self._known_dirs[path] then search.dirs[path] = true end
        end
      end
    end
  end
  -- what the view has read and is still in the tree (a file deleted since is no hit)
  local known = {}
  for path in pairs(self._known) do
    if self.main:node(self:id_of(path)) then
      known[#known + 1] = path
    else
      self._known[path], self._known_dirs[path] = nil, nil
    end
  end
  table.sort(known)
  add(known, true)
  search.cancel = require("filetree.native.fs.deep").files(self.root, function(batch)
    -- an answer of a search that was replaced or cleared never reaches the screen
    if gen ~= self._search_gen or self._search ~= search then return end
    local before = search.total
    add(batch, false)
    if search.total ~= before and not search.pending then
      search.pending = true
      vim.defer_fn(function()
        if gen == self._search_gen and self._search == search then self:_search_draw() end
      end, 60)
    end
  end, function()
    if gen ~= self._search_gen or self._search ~= search then return end
    search.done = true
    self:_search_draw()
  end, self._opts.search_tier and { tier = self._opts.search_tier } or nil)
  self:_search_draw()
  return true
end

---Leave the search: the main tree is shown again, as it was. Safe to call without a search.
---@return boolean cleared
function View:clear_search()
  local search = self._search
  if not search then return false end
  self._search = nil
  self._search_gen = (self._search_gen or 0) + 1
  if search.cancel then search.cancel() end
  self.tree = self.main
  self.cursor_id = self._main_cursor
  self._main_cursor = nil
  if self.buf and api.nvim_buf_is_valid(self.buf) then self:_draw_all() end
  return true
end

---The search in force, or nil.
---@return { query: string, hits: integer, done: boolean }|nil
function View:searching()
  local search = self._search
  if not search then return nil end
  return { query = search.query, hits = search.total, done = search.done }
end

-- ── whole-tree changes ─────────────────────────────────────────────────────────

---Read every folder that was read before again and take over what changed. Open folders stay open.
function View:refresh()
  self:sync_cursor()
  if self._pane then
    self._pane:reload()
    self:_after_draw()
    return
  end
  list.invalidate()
  local ids = vim.tbl_keys(self._loaded)
  table.sort(ids, function(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end)
  self._alias = {}
  local changed = false
  for _, id in ipairs(ids) do
    local node = self.main:node(id)
    if not node then
      self._loaded[id] = nil
    else
      local entries = list.list_sync(node.path)
      local changes
      if entries then
        changes = self.main:merge_children(id, self:_nodes(node.path, entries, self._loader_fn))
      else
        self._loaded[id] = nil
        changes = self.main:remove(id)
      end
      -- applied per folder: the splices of one operation are in terms of the rows as that operation
      -- left them, and the next folder's would be read against a tree that has moved on
      changed = changed or #changes > 0
      self:_apply_main(changes)
    end
  end
  -- a refresh may change nothing on screen and still has to reach whoever decorates the tree
  if not changed and self.tree == self.main then self:_after_draw() end
end

---Build the tree again from the cache: for a change of what is listed (sort order, hidden names).
---@private
function View:_relist()
  if self._pane then
    -- once, however often the listing changed meanwhile
    if not self._relist_pending then
      self._relist_pending = true
      self._deferred[#self._deferred + 1] = function()
        self._relist_pending = nil
        self:_relist()
      end
    end
    return
  end
  self:sync_cursor()
  local open = self:expanded_paths()
  local cursor = self.cursor_id
  self:_build()
  self:_draw_all()
  self:expand_paths(open)
  if cursor and self.tree:row_of(cursor) then
    self.cursor_id = cursor
    self:_place_cursor()
  end
end

---Show another directory.
---@param root string
---@return boolean
function View:set_root(root)
  root = list.norm(root)
  if root == self.root then return true end
  local stat = vim.uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then return false end
  self.root = root
  if self._pane then
    -- a source is asked with the root of the view: the one on screen is asked again now, the others
    -- when they are shown
    self._files_cursor = nil
    self:_build()
    self:sync_cursor()
    self._pane:reload()
    return true
  end
  self.cursor_id = nil
  self:_build()
  if self.buf and api.nvim_buf_is_valid(self.buf) then self:_draw_all() end
  return true
end

---@param kind "name"|"size"|"mtime"
---@param descending? boolean
function View:set_sort(kind, descending)
  self.sort = { kind = kind, descending = descending == true }
  self:_relist()
end

---Show or hide the names `opts.hide` matches.
---@param hidden boolean
function View:set_hide_ignored(hidden)
  if self.hide_ignored == hidden then return end
  self.hide_ignored = hidden
  self:_relist()
end

-- ── views ──────────────────────────────────────────────────────────────────────
-- A view is what the window shows: the files, or the nodes of registered sources. Switching replaces
-- the tree on screen the way a search does and touches neither the window nor the files' tree, so
-- position and width stay, and the files come back as they were left.

---@type Filetree.View.Spec
local FILES = { name = "files", sources = { "files" } }

---@param spec Filetree.View.Spec
---@return boolean
local function is_files(spec)
  return #spec.sources == 1 and spec.sources[1] == "files"
end

---The views there are, in the order of the view bar.
---@return Filetree.View.Spec[]
function View:views()
  local specs = self._opts.views and self._opts.views() or nil
  if type(specs) ~= "table" or #specs == 0 then return { FILES } end
  return specs
end

---The editor buffer the tree belongs to: the one in the window a file would open in.
---@return integer|nil
function View:alt_buf()
  ---@param win integer
  ---@return integer|nil
  local function editor_buf(win)
    if not win or win == 0 or not api.nvim_win_is_valid(win) or win == self.win then return nil end
    if api.nvim_win_get_config(win).relative ~= "" then return nil end
    local buf = api.nvim_win_get_buf(win)
    if by_buf[buf] ~= nil or vim.bo[buf].buftype ~= "" then return nil end
    return buf
  end
  if self.position == "current" and self._prev_buf and api.nvim_buf_is_valid(self._prev_buf) then
    return self._prev_buf
  end
  local buf = editor_buf(api.nvim_get_current_win())
    or editor_buf(vim.fn.win_getid(vim.fn.winnr("#")))
  if buf then return buf end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    buf = editor_buf(win)
    if buf then return buf end
  end
  return nil
end

---What a source or an action of this view is called with.
---@param source? string  The source in question.
---@return Filetree.Ctx
function View:ctx(source)
  return {
    root = self.root,
    cwd = list.norm(vim.fn.getcwd()),
    win = self.win or 0,
    view = self.view_name,
    source = source,
    alt_buf = self:alt_buf(),
  }
end

---The source a node of the tree on screen came from.
---@param id any
---@return string
function View:source_of(id)
  if not self._pane then return "files" end
  return (id ~= nil and self._pane:source_of(id)) or self._pane.sources[1]
end

---The sources of the view on screen.
---@return string[]
function View:sources()
  if not self._pane then return { "files" } end
  return vim.list_slice(self._pane.sources)
end

---The sections of the view on screen: one per source, with whether it could load. Empty for the files.
---@return Filetree.Pane.Section[]
function View:sections()
  return self._pane and self._pane:sections() or {}
end

---@private
---@param spec Filetree.View.Spec
---@return Filetree.Pane
function View:_pane_of(spec)
  local pane = self._panes[spec.name]
  if pane and vim.deep_equal(pane.sources, spec.sources) then
    -- nothing was followed while another view was shown, and the root directory may be another one:
    -- ask the sources again, open nodes stay open
    pane:reload()
    return pane
  end
  if pane then pane:stop() end
  pane = pane_mod.new(spec.name, spec.sources, {
    ctx = function(source)
      return self:ctx(source)
    end,
    before = function()
      if self._pane == pane then self:sync_cursor() end
    end,
    apply = function(changes)
      if self._pane ~= pane then return end
      self.tree = pane.tree
      self:_apply(changes)
    end,
    redraw = function()
      if self._pane ~= pane then return end
      self.tree = pane.tree
      if self.buf and api.nvim_buf_is_valid(self.buf) then self:_draw_all() end
    end,
  })
  self._panes[spec.name] = pane
  return pane
end

---Show another view in this window. The window stays where it is and as wide as it is; every view
---keeps its own cursor and its open nodes.
---@param name string
---@return boolean ok
---@return string|nil reason
function View:show(name)
  local spec = nil
  local names = {}
  for _, candidate in ipairs(self:views()) do
    names[#names + 1] = candidate.name
    if candidate.name == name then spec = candidate end
  end
  if not spec then
    return false, ("no view %q (views: %s)"):format(tostring(name), table.concat(names, ", "))
  end
  if name == self.view_name and (is_files(spec) or self._pane) then return true, nil end
  self:sync_cursor()
  self:clear_search()
  if self._pane then
    self._pane.cursor_id = self.cursor_id
    self._pane:stop()
  else
    self._files_cursor = self.cursor_id
  end
  self.view_name = name
  if is_files(spec) then
    self._pane = nil
    self.tree = self.main
    self.cursor_id = self._files_cursor
    local deferred = self._deferred
    self._deferred = {}
    for _, fn in ipairs(deferred) do
      fn()
    end
  else
    local pane = self:_pane_of(spec)
    self._pane = pane
    self.tree = pane.tree
    local first = pane.tree:row(1)
    self.cursor_id = pane.cursor_id or (first and first.id) or nil
    if self:is_open() then pane:start() end
  end
  local buf = self.buf
  if buf and api.nvim_buf_is_valid(buf) then
    vim.b[buf].filetree_view = name
    self:_draw_all()
    require("filetree.native.action").reload(self)
    pcall(api.nvim_exec_autocmds, "User", {
      pattern = "FiletreeView",
      modeline = false,
      data = { buf = buf, view = name },
    })
  end
  return true, nil
end

---A source was registered, replaced or removed: a view that shows it asks it again.
---@param source string
function View:source_changed(source)
  for _, pane in pairs(self._panes) do
    if vim.tbl_contains(pane.sources, source) then
      if pane == self._pane then
        self:sync_cursor()
        local started = pane:started()
        pane:stop()
        pane:build()
        if started then pane:start() end
        self.tree = pane.tree
        if self.buf and api.nvim_buf_is_valid(self.buf) then self:_draw_all() end
      end
      -- a view that is not on screen asks its sources when it is shown
    end
  end
end

-- ── module ─────────────────────────────────────────────────────────────────────

---@param opts Filetree.View.Opts
---@return Filetree.View
function M.new(opts)
  ---@type Filetree.View
  local self = setmetatable({
    root = list.norm(opts.root),
    position = opts.position or "left",
    width = opts.width or 32,
    height = opts.height or 15,
    sort = { kind = "name", descending = false },
    hide_ignored = false,
    _sync = false,
    _loaded = {},
    _alias = {},
    _watches = {},
    _reading = {},
    _known = {},
    _known_dirs = {},
    _generation = 0,
    _opts = opts,
    view_name = "files",
    _panes = {},
    _deferred = {},
  }, View)
  self:_build()
  return self
end

---The view a buffer belongs to.
---@param buf integer
---@return Filetree.View|nil
function M.of_buf(buf)
  return by_buf[buf]
end

---Call `fn(bufnr)` after a view wrote its buffer. Returns an unsubscribe function.
---@param fn fun(bufnr: integer?)
---@return fun()
function M.on_render(fn)
  render_listeners[#render_listeners + 1] = fn
  return function()
    for i, listener in ipairs(render_listeners) do
      if listener == fn then
        table.remove(render_listeners, i)
        break
      end
    end
  end
end

---Ask every open tree window to draw again (its lines are untouched, only what is drawn on them).
redraw_views = function()
  for _, view in pairs(by_buf) do
    local win = view.win
    if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == view.buf then
      -- `valid = false` re-runs the decoration provider for the window without touching the buffer
      if not pcall(api.nvim__redraw, { win = win, valid = false }) then vim.cmd("redraw") end
    end
  end
end

---Draw the highlights and badges of one buffer line as ephemeral extmarks. Called by the decoration
---provider for each line on screen; nothing is stored in the buffer.
---@param buf integer
---@param lnum integer  0-based.
---@param win? integer  The window being drawn; its width decides which badges fit.
---@return integer drawn  How many highlights and badges were placed (0 for a buffer that is no tree).
function M.decorate_line(buf, lnum, win)
  local view = by_buf[buf]
  local row = view and view.tree:row(lnum + 1)
  if not view or not row then return 0 end
  local line = line_of_row(view, row)
  local drawn = 0
  local function mark(col, opts)
    opts.ephemeral = true
    -- counted whether or not it could be placed: outside a redraw an ephemeral mark is refused
    drawn = drawn + 1
    pcall(api.nvim_buf_set_extmark, buf, NS, lnum, col, opts)
  end
  for _, span in ipairs(line.spans) do
    mark(span.col_start, { end_col = span.col_end, hl_group = span.hl, priority = 90 })
  end

  local node = row.node
  if QUIET[node.kind] then return drawn end
  local badges = decor.badges(node, row.expandable or node.kind == "dir")

  local right = {}
  -- what the source itself says about the node (a count, a line number), at the far right
  if type(node.columns) == "table" then
    for _, text in ipairs(node.columns) do
      text = tostring(text)
      if text ~= "" then
        right[#right + 1] = {
          text = text,
          hl = "FiletreeMore",
          width = vim.fn.strdisplaywidth(text),
          slot = "column",
          priority = 0,
        }
      end
    end
  end
  if #badges == 0 and #right == 0 then return drawn end

  for _, badge in ipairs(badges) do
    if badge.slot == "name" then
      if badge.hl then
        mark(line.name_start, { end_col = line.name_end, hl_group = badge.hl, priority = 95 })
      end
    elseif badge.slot == "line" then
      if badge.hl then mark(0, { line_hl_group = badge.hl, priority = 80 }) end
    elseif badge.slot == "sign" and row.depth > 0 and badge.text and badge.text ~= "" then
      -- over the first cell of the indent: the tree has no sign column, and a row below the root
      -- starts with blanks
      mark(
        0,
        { virt_text = { { badge.text, badge.hl } }, virt_text_pos = "overlay", priority = 100 }
      )
    elseif badge.text and badge.text ~= "" then
      right[#right + 1] = {
        text = badge.text,
        hl = badge.hl,
        width = vim.fn.strdisplaywidth(badge.text),
        -- a sign has no column of its own in this tree: it stands with the badges
        slot = badge.slot == "column" and "column" or "badge",
        priority = badge.priority,
      }
    end
  end
  if #right == 0 then return drawn end
  -- badges stand next to the name, columns at the far right, each kind in registration order
  local ordered = {}
  for _, slot in ipairs({ "badge", "column" }) do
    for _, item in ipairs(right) do
      if item.slot == slot then ordered[#ordered + 1] = item end
    end
  end
  right = ordered

  local width = win and text_width[win]
  if not width then
    width = 80
    if win and api.nvim_win_is_valid(win) then
      local info = vim.fn.getwininfo(win)[1]
      width = api.nvim_win_get_width(win) - (info and info.textoff or 0)
    end
  end
  local layout = columns.layout(width, vim.fn.strdisplaywidth(line.text), right)
  if #layout.items > 0 then
    local chunks = {}
    for _, item in ipairs(layout.items) do
      chunks[#chunks + 1] = { " " .. item.text, item.hl }
    end
    mark(0, { virt_text = chunks, virt_text_pos = "right_align", priority = 100 })
  end
  return drawn
end

-- Highlights for the lines on screen only: a status change or a scroll costs the visible rows, never
-- the whole tree.
api.nvim_set_decoration_provider(NS, {
  on_win = function(_, win, buf)
    if by_buf[buf] == nil then return false end
    -- once per redraw of the window, not once per line
    local info = vim.fn.getwininfo(win)[1]
    text_width[win] = api.nvim_win_get_width(win) - (info and info.textoff or 0)
    return true
  end,
  on_line = function(_, win, buf, lnum)
    M.decorate_line(buf, lnum, win)
  end,
})

api.nvim_create_autocmd("ColorScheme", { group = AUGROUP, callback = define_highlights })

return M
