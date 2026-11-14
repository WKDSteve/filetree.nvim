---@module 'filetree.native.pane'
---@brief The tree of one view that is not the directory tree: its sources as sections under a hidden root.
---@description
--- A view of the own tree shows the files (`filetree.native.view` owns that tree) or the nodes of
--- registered sources (`Filetree.Source`). This module builds the second kind: one `lib.nvim.tree`
--- whose hidden root has one child per source, the root node that source answered. A view with one
--- source and a view with several are the same thing here.
---
--- Key responsibilities:
--- - Ask every source for its root, show a source that cannot load as one line that says why
--- - Adopt the nodes a source hands over: which source an id came from, which id a path is shown under
--- - Turn `emit.push` / `emit.invalidate` / `emit.reset` of a source into splices of the tree
--- - Subscribe to the sources only while the window is shown (`start` / `stop`)
---
--- No buffer and no window: what a change means on screen is the caller's `hooks.apply`.

local tree_core = require("lib.nvim.tree")
local registry = require("filetree.registry")

local M = {}

---@class Filetree.Pane.Hooks
---@field ctx fun(source?: string): Filetree.Ctx  The context a source is called with.
---@field before? fun()  Called before the tree changes outside a call of the view (a source emitted).
---@field apply fun(changes: Lib.Tree.Splice[])  Rows changed; read them back from `pane.tree`.
---@field redraw fun()  `pane.tree` is another tree now: write every line again.
---@field focus? fun(id: any)  A source asks for the cursor on one of its nodes.

---@class Filetree.Pane.Section
---@field source string
---@field id any  The id of the root node of the section.
---@field available boolean
---@field reason? string  Why the source cannot be shown, when it cannot.
---@field title string

---@class Filetree.Pane
---@field name string  The name of the view.
---@field sources string[]
---@field tree Lib.Tree
---@field cursor_id any  Where the cursor was when the view was last left.
---@field private _hooks Filetree.Pane.Hooks
---@field private _sections Filetree.Pane.Section[]
---@field private _source_of table<any, string>
---@field private _by_path table<string, any>
---@field private _loaders table<any, function>
---@field private _loaded table<any, true>
---@field private _opened table<any, true>  Nodes with `open = true` that were opened once: closed by hand, they stay closed.
---@field private _pending_open table<any, true>  Such nodes that are waiting to be opened.
---@field private _stops (fun())[]
---@field private _started boolean
local Pane = {}
Pane.__index = Pane

--- The wrappers this module put in place of a node's lazy `children`, so that none is wrapped twice.
---@type table<function, true>
local wrapped = setmetatable({}, { __mode = "k" })

---@param entry Filetree.Source|nil
---@param name string
---@return string
local function title_of(entry, name)
  return entry and entry.title or (name:sub(1, 1):upper() .. name:sub(2))
end

---The line a source shows when it has no tree to give.
---@param view string
---@param name string
---@param title string
---@param reason string
---@return Filetree.Node
local function placeholder(view, name, title, reason)
  return {
    id = ("\0%s/%s"):format(view, name),
    label = ("%s  [!] %s"):format(title, reason),
    kind = "unavailable",
  }
end

---Take note of a node and of everything below it that is there already.
---@private
---@param source string
---@param entry Filetree.Source
---@param node Filetree.Node
---@param is_root? boolean
function Pane:_adopt(source, entry, node, is_root)
  local id = node.id
  self._source_of[id] = source
  if node.open == true and not self._opened[id] then
    self._opened[id] = true
    self._pending_open[id] = true
  end
  -- the last node handed over for a path: after a reload that is one of the fresh nodes, also when
  -- the file moved to another group and its old node is gone
  if type(node.path) == "string" then self._by_path[node.path] = id end
  local kids = node.children
  if type(kids) == "table" then
    for _, child in ipairs(kids) do
      self:_adopt(source, entry, child)
    end
    return
  end
  local load = nil
  if type(kids) == "function" then
    if wrapped[kids] then return end
    load = kids
  elseif kids == nil and type(entry.children) == "function" and (is_root or node.lazy == true) then
    load = function(n, cb)
      entry.children(n, self._hooks.ctx(source), cb)
    end
  end
  if not load then return end
  self._loaders[id] = load
  local wrapper = function(n, cb)
    -- looked up when it runs: a node that was kept over a reload asks the loader of its newest twin
    local current = self._loaders[n.id] or load
    current(n, function(list, err)
      if type(list) == "table" then
        self._loaded[n.id] = true
        for _, child in ipairs(list) do
          self:_adopt(source, entry, child)
        end
      end
      cb(list, err)
    end)
  end
  wrapped[wrapper] = true
  node.children = wrapper
end

---The root node of one source, adopted; a placeholder when the source is unknown, unavailable or raises.
---@private
---@param name string
---@return Filetree.Node root
---@return Filetree.Pane.Section section
function Pane:_root_of(name)
  local entry = registry.get("source", name)
  local title = title_of(entry, name)
  ---@param reason string
  local function unavailable(reason)
    local node = placeholder(self.name, name, title, reason)
    self._source_of[node.id] = name
    return node, { source = name, id = node.id, available = false, reason = reason, title = title }
  end
  if name == "files" then return unavailable("the files cannot be a section yet") end
  if not entry then return unavailable("no source of this name is registered") end
  if type(entry.available) == "function" then
    local ok, can, reason = pcall(entry.available)
    if not ok then return unavailable(tostring(can)) end
    if can == false then return unavailable(reason or "not available") end
  end
  local ok, root = pcall(entry.root, self._hooks.ctx(name))
  if not ok then return unavailable("root() failed: " .. tostring(root)) end
  if type(root) ~= "table" or root.id == nil then return unavailable("root() answered no node") end
  self:_adopt(name, entry, root, true)
  return root, { source = name, id = root.id, available = true, title = title }
end

---Build the tree from scratch: every source is asked for its root again.
function Pane:build()
  self._source_of, self._by_path, self._loaders, self._loaded = {}, {}, {}, {}
  self._opened, self._pending_open = {}, {}
  self._sections = {}
  local roots = {}
  local severity, aggregate = nil, nil
  for _, name in ipairs(self.sources) do
    local root, section = self:_root_of(name)
    roots[#roots + 1] = root
    self._sections[#self._sections + 1] = section
    local entry = registry.get("source", name)
    -- one tree has one severity order: the first source that names one decides
    if entry and not severity then severity = entry.severity end
    if entry and not aggregate and #self.sources == 1 then aggregate = entry.aggregate end
  end
  local hidden = { id = "\0view/" .. self.name, label = self.name, children = roots }
  local built
  local ok, tree = pcall(tree_core.new, {
    root = hidden,
    hide_root = true,
    severity = severity,
    aggregate = aggregate,
    on_change = function(changes)
      if self.tree == built then self._hooks.apply(changes) end
    end,
  })
  if not ok then
    -- two sources answered the same node id: say so in place of the tree, a view must not raise
    local node = placeholder(self.name, "error", self.name, tostring(tree))
    hidden = { id = "\0view/" .. self.name, label = self.name, children = { node } }
    self._sections = {
      {
        source = self.sources[1],
        id = node.id,
        available = false,
        reason = tostring(tree),
        title = self.name,
      },
    }
    tree = tree_core.new({ root = hidden, hide_root = true })
  end
  built = tree
  self.tree = tree
  -- a section starts open; a lazy root is asked for its children here
  for _, section in ipairs(self._sections) do
    tree:expand(section.id)
  end
  -- nothing is on screen yet: the nodes that start open are opened without reporting rows
  for id in pairs(self._pending_open) do
    if tree:node(id) then tree:expand(id) end
  end
  self._pending_open = {}
  if self.cursor_id ~= nil and not tree:node(self.cursor_id) then self.cursor_id = nil end
end

---Open the nodes that asked to start open and are in the tree by now. Called after rows were
---written: the nodes a lazy answer brought are registered only once that answer is taken over.
function Pane:open_pending()
  if next(self._pending_open) == nil then return end
  local pending = self._pending_open
  self._pending_open = {}
  for id in pairs(pending) do
    if self.tree:node(id) and not self.tree:is_expanded(id) then
      self:_apply(self.tree:expand(id))
    end
  end
end

---How many nodes of the view carry a status (changed files, failed tests, problems): the number the
---view bar shows. Read from the aggregates of the section heads, nothing is walked.
---@return integer
function Pane:count()
  local total = 0
  for _, section in ipairs(self._sections) do
    local agg = self.tree:agg(section.id)
    for _, n in pairs(agg and agg.counts or {}) do
      total = total + n
    end
  end
  return total
end

---@return Filetree.Pane.Section[]
function Pane:sections()
  return self._sections
end

---The source a node came from.
---@param id any
---@return string|nil
function Pane:source_of(id)
  return self._source_of[id]
end

---The id a path is shown under in this view, when it is shown.
---@param path string  Normalized.
---@return any|nil
function Pane:id_of(path)
  local id = self._by_path[path]
  if id ~= nil then
    local node = self.tree:node(id)
    if node and node.path == path then return id end
    self._by_path[path] = nil
  end
  return nil
end

---@private
---@param changes Lib.Tree.Splice[]
function Pane:_apply(changes)
  if #changes > 0 then self._hooks.apply(changes) end
end

---Bring the children of `id` in line with what its node carries or its loader answers now, and the
---same for every child below that has been read.
---@private
---@param id any
---@param node Filetree.Node  The node as the source hands it over now.
function Pane:_resync(id, node)
  local tree = self.tree
  ---@param list Filetree.Node[]
  local function take(list)
    if self.tree ~= tree or not tree:node(id) then return end
    -- applied per node: the splices of one merge are in terms of the rows as that merge left them
    self:_apply(tree:merge_children(id, list))
    for _, child in ipairs(list) do
      if type(child.children) == "table" or self._loaded[child.id] then
        self:_resync(child.id, child)
      end
    end
  end
  if type(node.children) == "table" then
    take(node.children)
  elseif self._loaded[id] and self._loaders[id] then
    self._loaders[id](node, function(list)
      if type(list) ~= "table" then return end
      local source = self._source_of[id]
      local entry = source and registry.get("source", source)
      if entry then
        for _, child in ipairs(list) do
          self:_adopt(source, entry, child)
        end
      end
      take(list)
    end)
  end
end

---Ask sources for their roots again and take over what changed; what is open stays open.
---@param source? string  Only this source (default: every source of the view).
function Pane:reload(source)
  for i, section in ipairs(self._sections) do
    if not source or section.source == source then
      local root, fresh = self:_root_of(section.source)
      if fresh.id ~= section.id or fresh.available ~= section.available then
        -- another root, or the source came or went: the sections are not the ones that were built
        local was_started = self._started
        self:stop()
        self:build()
        if was_started then self:start() end
        self._hooks.redraw()
        return
      end
      self._sections[i] = fresh
      -- also for a source that still cannot load: its reason may be another one
      self:_apply(self.tree:push({
        id = root.id,
        label = root.label,
        status = root.status,
        columns = root.columns,
      }))
      if fresh.available then self:_resync(root.id, root) end
    end
  end
end

---@private
---@param source string
---@return Filetree.Emit
function Pane:_emit(source)
  local tree = self.tree
  ---@return boolean
  local function live()
    return self.tree == tree and self._started
  end
  return {
    push = function(update)
      if not live() or type(update) ~= "table" then return end
      -- a source speaks for its own nodes: in a view with several sections the others are not its
      if self._source_of[update.id] ~= source then return end
      if self._hooks.before then self._hooks.before() end
      self:_apply(tree:push(update))
    end,
    invalidate = function(id, deep)
      if not live() then return end
      if self._hooks.before then self._hooks.before() end
      for _, section in ipairs(self._sections) do
        if section.id == id then
          self:reload(source)
          return
        end
      end
      local node = tree:node(id)
      if not node or self._source_of[id] ~= source then return end
      if self._loaded[id] and self._loaders[id] then
        self:_resync(id, node)
      else
        self:_apply(tree:invalidate(id, deep))
      end
    end,
    reset = function()
      if not live() then return end
      if self._hooks.before then self._hooks.before() end
      self:reload(source)
    end,
    focus = function(id)
      if not live() or not tree:node(id) or self._source_of[id] ~= source then return end
      if self._hooks.focus then self._hooks.focus(id) end
    end,
  }
end

---Follow the sources: called when the view is on screen. A source that raises in `subscribe` is named
---once and shown without live updates.
function Pane:start()
  if self._started then return end
  self._started = true
  for _, section in ipairs(self._sections) do
    -- a source that cannot load right now is followed too: only it knows when that changes
    local entry = registry.get("source", section.source)
    if entry and type(entry.subscribe) == "function" then
      local ok, stop =
        pcall(entry.subscribe, self._hooks.ctx(section.source), self:_emit(section.source))
      if ok and type(stop) == "function" then
        self._stops[#self._stops + 1] = stop
      elseif not ok then
        require("filetree.util.notify")
          .create("[filetree.native]")
          .warn(("source %s failed in subscribe(): %s"):format(section.source, tostring(stop)))
      end
    end
  end
end

---Stop following: the view is off the screen, a source costs nothing from here on.
function Pane:stop()
  if not self._started then return end
  self._started = false
  for _, stop in ipairs(self._stops) do
    pcall(stop)
  end
  self._stops = {}
end

---@return boolean
function Pane:started()
  return self._started
end

---@param name string  The name of the view.
---@param sources string[]
---@param hooks Filetree.Pane.Hooks
---@return Filetree.Pane
function M.new(name, sources, hooks)
  ---@type Filetree.Pane
  local self = setmetatable({
    name = name,
    sources = vim.list_slice(sources),
    _hooks = hooks,
    _sections = {},
    _source_of = {},
    _by_path = {},
    _loaders = {},
    _loaded = {},
    _opened = {},
    _pending_open = {},
    _stops = {},
    _started = false,
  }, Pane)
  self:build()
  return self
end

return M
