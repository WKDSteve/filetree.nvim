---@module 'filetree.native.source.files_section'
---@brief The directory tree as one section of a view that also shows other sources.
---@description
--- The files view is a tree of its own (`filetree.native.view` owns it: `View.main`). A view that
--- lists `files` next to other sources (`{ name = "work", "buffers", "files" }`) is one tree of
--- sections (`filetree.native.pane`), and there the files are a source like the others: a root node
--- with lazy folders, and a subscription that says which folder changed.
---
--- What it shares with the files view, so that the two never disagree about the disk:
--- - the listing cache (`fs.list`) and the one place that turns entries into nodes (`source.files`)
--- - the watcher handles (`fs.watch`, reference-counted) and the event of a finished file operation
---   (`User FiletreeChanged`)
--- - the view's sort order, its test for hidden names, `max_entries` and the entries kept past it
---
--- What it has of its own: which folders it has read, and which merged line (`a/b/c`) a folder is
--- part of. One per view of sections; nothing here touches `View.main`.
---
--- Key responsibilities:
--- - `entry`: the `Filetree.Source` the pane asks (`root`, `subscribe`); not in the registry
--- - `id_of(path)`: the id a path is shown under (its own, or the merged line it is part of)
--- - `loaded`: the folders read, for "which folders are open"

local list = require("filetree.native.fs.list")
local service = require("filetree.native.fs.service")
local watch = require("filetree.native.fs.watch")
local files = require("filetree.native.source.files")

local api = vim.api

local M = {}

---@class Filetree.FilesSection
---@field entry Filetree.Source
---@field loaded table<string, true>  Ids of the folders that were read.
---@field private _alias table<string, string>  A folder inside a merged line -> the id of that line.
---@field private _chains table<string, string[]>  Listed folder -> the folders its listing put into `_alias`.
---@field private _view Filetree.View
---@field private _unwatch table<string, fun()>?  Watched folder -> give the reference back; nil while not followed.
local Section = {}
Section.__index = Section

---The id a path is shown under: its own, or the merged line it is part of.
---@param path string  Normalized.
---@return string
function Section:id_of(path)
  return self._alias[path] or path
end

---@private
---@param dir string
function Section:_watch_dir(dir)
  local held = self._unwatch
  if not held or held[dir] then return end
  held[dir] = watch.watch(dir)
end

---The nodes of one folder, with the lazy loader on every folder among them.
---@private
---@param dir string
---@param entries Filetree.Fs.Entry[]
---@param loader function
---@return Filetree.Node[]
function Section:_nodes(dir, entries, loader)
  local view = self._view
  local nodes = files.nodes(entries, {
    dir = dir,
    max_entries = view._opts.max_entries,
    keep = view._kept,
    loader = loader,
    sort = view.sort,
    hide = view:_hide(),
    group_empty = view._opts.group_empty,
  })
  -- what this folder's listing merged last time is not merged any more unless it says so again
  for _, member in ipairs(self._chains[dir] or {}) do
    self._alias[member] = nil
  end
  local members = {}
  self._chains[dir] = members
  for _, node in ipairs(nodes) do
    local chain = node.data and node.data.chain
    if chain then
      for i = 1, #chain - 1 do
        self._alias[chain[i]] = node.id
        members[#members + 1] = chain[i]
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

---@private
---@return fun(node: Filetree.Node, cb: fun(list?: Filetree.Node[], err?: string))
function Section:_loader()
  local loader
  loader = function(node, cb)
    local dir = node.path
    local function done(entries, err)
      if not entries then
        cb(nil, err)
        return
      end
      self.loaded[node.id] = true
      self:_watch_dir(dir)
      cb(self:_nodes(dir, entries, loader))
    end
    -- without a handle on it nobody would have said that the folder changed since it was cached
    if not watch.covers(dir) then service.invalidate(dir) end
    if self._view._sync then
      done(service.list_sync(dir))
    else
      service.list(dir, done)
    end
  end
  return loader
end

---The folder whose listing has to be read again when `dir` changed: `dir` itself, or, for a folder
---of a merged line, the folder that line stands in (the line may be another one now).
---@private
---@param dir string
---@return string
function Section:_stale(dir)
  local line = self._alias[dir]
  if line then return list.parent(self:_first_of(line, dir)) or dir end
  return dir
end

---The outermost folder of the merged line `line` (the one `dir` is part of).
---@private
---@param line string
---@param dir string
---@return string
function Section:_first_of(line, dir)
  local first = dir
  for member, id in pairs(self._alias) do
    if id == line and #member < #first then first = member end
  end
  return first
end

---@param view Filetree.View
---@return Filetree.FilesSection
function M.new(view)
  ---@type Filetree.FilesSection
  local self = setmetatable({ loaded = {}, _alias = {}, _chains = {}, _view = view }, Section)
  local loader = self:_loader()

  self.entry = {
    name = "files",
    title = "Files",
    root = function(ctx)
      local root = ctx.root
      return {
        id = root,
        label = root == "/" and "" or list.basename(root),
        kind = "dir",
        path = root,
        children = loader,
      }
    end,
    subscribe = function(ctx, emit)
      local root = ctx.root
      ---@param dir string
      local function changed(dir)
        if not list.inside(root, dir) then return end
        service.invalidate(dir)
        local stale = self:_stale(dir)
        if stale ~= dir then service.invalidate(stale) end
        emit.invalidate(self:id_of(stale))
      end

      local unsubscribe = nil
      if view._opts.watch ~= false then
        self._unwatch = {}
        self:_watch_dir(root)
        if not watch.recursive then
          for id in pairs(self.loaded) do
            self:_watch_dir(id)
          end
        end
        unsubscribe = watch.subscribe(function(dirs)
          for _, dir in ipairs(dirs) do
            changed(dir)
          end
        end, function()
          -- The watch that covered everything below the root is gone (the helper process ended).
          -- What was held for a folder below the root was one more reference to that watch: given
          -- back, and taken again as a handle of the folder's own.
          for dir, unwatch in pairs(self._unwatch or {}) do
            if dir ~= root then
              unwatch()
              self._unwatch[dir] = nil
            end
          end
          for id in pairs(self.loaded) do
            self:_watch_dir(id)
          end
          for _, members in pairs(self._chains) do
            for _, member in ipairs(members) do
              self:_watch_dir(member)
            end
          end
        end)
      end
      -- a finished file operation of filetree.nvim: the folders it names, also without a watcher
      local group =
        api.nvim_create_augroup(("filetree_files_section_%d"):format(vim.uv.hrtime()), {})
      api.nvim_create_autocmd("User", {
        group = group,
        pattern = "FiletreeChanged",
        callback = function(ev)
          local data = type(ev.data) == "table" and ev.data or {}
          -- by key: a create has no `from`, and a list with a hole ends at the hole
          for _, key in ipairs({ "from", "to" }) do
            local path = data[key]
            if type(path) == "string" and path ~= "" then
              local dir = list.parent(list.norm(path))
              -- a target folder the operation made itself is new to its parent
              while
                dir
                and dir ~= root
                and list.inside(root, dir)
                and not self.loaded[self:id_of(dir)]
              do
                dir = list.parent(dir)
              end
              if dir then changed(dir) end
            end
          end
        end,
      })
      return function()
        if unsubscribe then unsubscribe() end
        pcall(api.nvim_del_augroup_by_id, group)
        for _, unwatch in pairs(self._unwatch or {}) do
          unwatch()
        end
        self._unwatch = nil
      end
    end,
  }
  return self
end

return M
