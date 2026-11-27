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
---@field entry? fun(source: string): Filetree.Source|nil  A source the view brings itself (the files); nil: ask the registry.
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
---@field private _above table<any, string>  Node id -> the path of the node itself or of the nearest node above it that has one.
---@field private _loaded table<any, true>  Lazy nodes that were asked for their children.
---@field private _asking boolean  A lazy node is being asked again right now, by `_reload`.
---@field private _answer Filetree.Node[]?  What the loader answered to that question, when it answered at once.
---@field private _opened table<any, true>  Nodes with `open = true` that were opened once: closed by hand, they stay closed, until they come once without saying it.
---@field private _pending_open table<any, true>  Such nodes that are waiting to be opened.
---@field private _asking_roots boolean?  The sources are being asked for their roots again (`reload`): nothing is opened until that is through.
---@field private _exact { want: table<any, true>, seen: table<any, true> }?  The last list `set_open` was given, and the nodes that were adopted since: a node it does not name stays closed when it first arrives.
---@field private _wanted table<any, true>  Nodes somebody asked to have open (`set_open`) that are not in the tree yet.
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
---@param above? string  The path of the nearest node above that has one.
function Pane:_adopt(source, entry, node, is_root, above)
  local id = node.id
  self._source_of[id] = source
  local exact = self._exact
  local first_since_set = exact ~= nil and not exact.seen[id]
  if exact then exact.seen[id] = true end
  if self._wanted[id] then
    -- somebody asked for it by name (`set_open`) before it was there
    self._wanted[id] = nil
    self._opened[id] = true
    self._pending_open[id] = true
  elseif node.open == true and not self._opened[id] then
    self._opened[id] = true
    -- A list of open nodes was set (`set_open`) and this node, which it does not name, arrives for
    -- the first time since: it stays closed. "Exactly these" holds for what comes later too (the
    -- groups of a source that answers after its view is shown, each saying `open = true`).
    if not (first_since_set and not self._exact.want[id]) then self._pending_open[id] = true end
  elseif node.open ~= true then
    -- It comes without the word: the next time it says `open = true` that is a new request (a step
    -- of a pipeline that was red, ran again without findings and is red again). A node closed by
    -- hand stays closed for as long as it keeps saying it.
    self._opened[id] = nil
  end
  -- the last node handed over for a path: after a reload that is one of the fresh nodes, also when
  -- the file moved to another group and its old node is gone
  -- A node that carries the path of a node above it is a place in that file (a test case under its
  -- spec file, a symbol), not the file: the path stays with the file, or `reveal` and "which line is
  -- this path on" would land on a row that is hidden while the file is closed.
  local own = type(node.path) == "string" and node.path or nil
  if own and own ~= above then self._by_path[own] = id end
  local below = own or above
  self._above[id] = below
  local kids = node.children
  if type(kids) == "table" then
    for _, child in ipairs(kids) do
      self:_adopt(source, entry, child, false, below)
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
  local wrapper = function(n, cb)
    load(n, function(list, err)
      local again = self._loaded[n.id] == true
      local at_once = self._asking
      if type(list) == "table" then
        self._loaded[n.id] = true
        for _, child in ipairs(list) do
          self:_adopt(source, entry, child, false, self._above[n.id])
        end
        if at_once then self._answer = list end
      end
      cb(list, err)
      -- An answer to "read again" that comes later: the tree has taken it over by now (and reported
      -- it), so the lazy nodes below that were read can be asked in their turn. An answer that
      -- comes at once is followed up by `_reload`, after its rows were written.
      if again and not at_once and type(list) == "table" then self:_reload_below(list) end
    end)
  end
  wrapped[wrapper] = true
  node.children = wrapper
end

---The entry of a source: the one the view brings itself, else the registered one.
---@private
---@param name string
---@return Filetree.Source|nil
function Pane:_entry(name)
  local own = self._hooks.entry and self._hooks.entry(name) or nil
  if own then return own end
  return registry.get("source", name)
end

---The root node of one source, adopted; a placeholder when the source is unknown, unavailable or raises.
---@private
---@param name string
---@return Filetree.Node root
---@return Filetree.Pane.Section section
function Pane:_root_of(name)
  local entry = self:_entry(name)
  local title = title_of(entry, name)
  ---@param reason string
  local function unavailable(reason)
    local node = placeholder(self.name, name, title, reason)
    self._source_of[node.id] = name
    return node, { source = name, id = node.id, available = false, reason = reason, title = title }
  end
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
---@param keep? boolean  The tree is built again in place (a source came, went or registered again): what was open is opened again, now or when it arrives, and what was closed by hand stays closed.
function Pane:build(keep)
  ---@type (string|number)[]?
  local open_before = nil
  ---@type table<any, boolean>
  local heads_before = {}
  if keep and self.tree then
    open_before = self:open_nodes()
    for _, section in ipairs(self._sections) do
      heads_before[section.id] = self.tree:is_expanded(section.id)
    end
  end
  self._source_of, self._by_path, self._loaded = {}, {}, {}
  self._above = {}
  -- kept with `keep`: a node that says `open = true` and was closed by hand does not open itself again
  self._opened = open_before and self._opened or {}
  self._pending_open = {}
  if open_before then
    -- what somebody asked to have open and has not arrived yet (`set_open`) stays asked for
    for _, id in ipairs(open_before) do
      self._wanted[id] = true
    end
  else
    -- another tree (the first build, another root): nothing is carried over
    self._wanted = {}
    self._exact = nil
  end
  self._sections = {}
  local roots = {}
  local severity, aggregate = nil, nil
  for _, name in ipairs(self.sources) do
    local root, section = self:_root_of(name)
    roots[#roots + 1] = root
    self._sections[#self._sections + 1] = section
    local entry = self:_entry(name)
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
  -- a section starts open (one that was closed before a build in place stays closed); a lazy root
  -- is asked for its children here
  for _, section in ipairs(self._sections) do
    if heads_before[section.id] ~= false then tree:expand(section.id) end
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
  -- while the sources are asked again the tree still holds the nodes as they were: a node that comes
  -- back with children is a leaf until they are mixed in, and opening a leaf does nothing
  if self._asking_roots or next(self._pending_open) == nil then return end
  local pending = self._pending_open
  self._pending_open = {}
  for id in pairs(pending) do
    if self.tree:node(id) and not self.tree:is_expanded(id) then
      self:_apply(self.tree:expand(id))
    end
  end
end

---The ids of the open nodes on screen, top to bottom (so a folder stands before what is in it).
---Section heads are among them. Only ids that can be written down: strings and numbers.
---@return (string|number)[]
function Pane:open_nodes()
  local out = {}
  local tree = self.tree
  for i = 1, tree:count() do
    local row = tree:row(i)
    local kind = type(row.id)
    if row.expanded and (kind == "string" or kind == "number") then out[#out + 1] = row.id end
  end
  return out
end

---Have exactly these nodes open: what is open and not named is closed (a section head too), what is
---named is opened, now or when it arrives (a node below a folder that is read later, a source that
---answers later). A node that is not named and arrives later stays closed the first time, also when
---it says `open = true`; when it says so again after a round without, it opens as always.
---@param ids (string|number)[]  As `open_nodes` answered them: a folder before what is in it.
function Pane:set_open(ids)
  local tree = self.tree
  local want = {}
  for _, id in ipairs(ids) do
    want[id] = true
  end
  -- from the bottom up: closing a row takes the rows below it away
  local open = self:open_nodes()
  for i = #open, 1, -1 do
    local id = open[i]
    if not want[id] and tree:node(id) then
      self._opened[id] = true
      self:_apply(tree:collapse(id))
    end
  end
  self._wanted = {}
  for _, id in ipairs(ids) do
    if tree:node(id) then
      self._opened[id] = true
      if not tree:is_expanded(id) then self:_apply(tree:expand(id)) end
    else
      self._wanted[id] = true
    end
  end
  -- what is in the tree by now has been dealt with; a node that arrives later and is not named
  -- stays closed the first time (`_adopt`)
  local seen = {}
  for id in pairs(self._source_of) do
    seen[id] = true
  end
  self._exact = { want = want, seen = seen }
  self:open_pending()
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

---Ask a lazy node that was read before for its children again and take the answer over; what is
---open below stays open (`Tree:reload`). The lazy nodes below it that were read are asked after it.
---@private
---@param id any
function Pane:_reload(id)
  local tree = self.tree
  self._asking, self._answer = true, nil
  local changes = tree:reload(id, { deep = true })
  local answer = self._answer
  self._asking, self._answer = false, nil
  self:_apply(changes)
  -- answered at once: its rows are written, now the level below (a later answer does this itself)
  if answer then self:_reload_below(answer) end
end

---The lazy nodes in `list` (and below the lists in it) that were read before: ask each again.
---@private
---@param list Filetree.Node[]
function Pane:_reload_below(list)
  for _, child in ipairs(list) do
    if type(child.children) == "table" then
      self:_reload_below(child.children)
    elseif self._loaded[child.id] and self.tree:node(child.id) then
      self:_reload(child.id)
    end
  end
end

---Bring the children of `id` in line with what its node carries or its loader answers now, and the
---same for every node below that has been read.
---@private
---@param id any
---@param node Filetree.Node  The node as the source hands it over now.
function Pane:_resync(id, node)
  local tree = self.tree
  if type(node.children) == "table" then
    -- the whole subtree came with the node: mixed in level by level, what is open stays open
    self:_apply(tree:merge_children(id, node.children, { deep = true }))
    self:_reload_below(node.children)
  elseif self._loaded[id] then
    -- the node of the tree asks through the loader of its newest twin
    local kept = tree:node(id)
    if kept and kept ~= node and type(node.children) == "function" then
      kept.children = node.children
    end
    self:_reload(id)
  end
end

---A node of `source` that left the tree is no longer "opened once": a node cannot be closed by hand
---while it is gone, so when it comes back saying `open = true` (the group Untracked after the last
---untracked file was staged and unstaged again) it opens as it did the first time.
---@private
---@param source string
function Pane:_forget_gone(source)
  local tree = self.tree
  for id in pairs(self._opened) do
    if self._source_of[id] == source and not tree:node(id) then self._opened[id] = nil end
  end
end

---Ask sources for their roots again and take over what changed; what is open stays open.
---@param source? string  Only this source (default: every source of the view).
function Pane:reload(source)
  self._asking_roots = true
  local rebuilt = self:_reload_sections(source)
  self._asking_roots = false
  -- the nodes that asked to be open, now that their children are in the tree; also when no row
  -- changed (a node that only gained the word)
  if not rebuilt then self:open_pending() end
end

---@private
---@param source? string
---@return boolean rebuilt  The tree was built again (and the view drawn).
function Pane:_reload_sections(source)
  for i, section in ipairs(self._sections) do
    if not source or section.source == source then
      local root, fresh = self:_root_of(section.source)
      if fresh.id ~= section.id or fresh.available ~= section.available then
        -- another root, or the source came or went: the sections are not the ones that were built
        local was_started = self._started
        self:stop()
        -- the source came or went: in place, what was open is open again. Another root is another
        -- tree: what was open is closed, as in the files view.
        self:build(fresh.id == section.id or not (fresh.available and section.available))
        if was_started then self:start() end
        self._asking_roots = false
        self._hooks.redraw()
        return true
      end
      self._sections[i] = fresh
      -- also for a source that still cannot load: its reason may be another one
      -- what the head no longer carries goes: a section whose count fell away must not show the old one
      local clear = {}
      for _, field in ipairs({ "status", "columns" }) do
        if root[field] == nil then clear[#clear + 1] = field end
      end
      self:_apply(self.tree:push({
        id = root.id,
        label = root.label,
        status = root.status,
        columns = root.columns,
        clear = clear,
      }))
      if fresh.available then self:_resync(root.id, root) end
      self:_forget_gone(section.source)
    end
  end
  return false
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
      if self._loaded[id] and type(node.children) == "function" then
        self:_reload(id)
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
    local entry = self:_entry(section.source)
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
    _above = {},
    _loaded = {},
    _asking = false,
    _opened = {},
    _pending_open = {},
    _wanted = {},
    _stops = {},
    _started = false,
  }, Pane)
  self:build()
  return self
end

return M
