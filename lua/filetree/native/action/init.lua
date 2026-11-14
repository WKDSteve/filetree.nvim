---@module 'filetree.native.action'
---@brief The action table of the own tree, bound: every key of a tree buffer goes through it.
---@description
--- One `Filetree.Action.Table` per view, filled from four origins:
---
---   builtin  the tree's own keys (open, fold, close, refresh, ...)    this module
---   feature  the keys filetree features bound on the buffer           read back from the buffer
---   plugin   actions other plugins registered                        `lib.nvim.tree.registry`
---   source   actions of the source the view shows                    the source's `actions`
---
--- A key that only one feature claims stays that feature's own mapping. A key some other action claims
--- too gets a dispatcher: it asks the table which action applies to the node under the cursor
--- (`table.resolve`), runs it with the selection, or says in one line why nothing does ("d: needs a
--- file"). The feature's own mapping is kept as the run function of its entry, so it still does exactly
--- what it did.
---
--- Key responsibilities:
--- - `attach(view, buf)`: build the table, bind the builtin and registry keys (before FileType)
--- - `sync(view)`: read the feature keys of the buffer back into the table, take over shared keys
--- - `run_key(view, lhs)` / `run(view, name, args)`: what a key or `:Filetree action <name>` does
--- - `applicable(view)`: the actions for the node under the cursor (cheatsheet, menu)
--- - `selection(view)`: the marked nodes of this view, else the node under the cursor

local tbl = require("filetree.native.action.table")
local notify = require("filetree.util.notify").create("[filetree.native]")

local api = vim.api

local M = {}

--- The desc prefix of the mappings this module sets; anything else on the buffer is not ours.
M.PREFIX = "[filetree] "
--- The desc prefix lib.nvim's keymap registry writes for filetree's features.
local FEATURE_PREFIX = "filetree: "

-- ── builtin actions ────────────────────────────────────────────────────────────

---`<CR>` on a row: a folder opens or closes, a file opens in an editor window.
---@param view Filetree.View
---@param mode? FiletreeOpenMode
function M.activate(view, mode)
  local row = view:current()
  if not row then return end
  if row.node.kind == "more" then
    notify.info(
      "this list has more entries than it shows; raise native.max_entries or native.search_max"
    )
    return
  end
  if row.node.kind == "unavailable" then
    notify.info(row.node.label)
    return
  end
  if row.expandable or row.node.kind == "dir" then
    if row.id ~= view.root then view:toggle(row.id) end
    return
  end
  require("filetree.native").open_node(view, row.node, mode)
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

---`l`: open the folder under the cursor, or the file; on an open folder, go to its first entry.
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

---@param ctx Filetree.Action.Ctx
---@return Filetree.View
local function view_of(ctx)
  return ctx.tree --[[@as Filetree.View]]
end

---The tree's own actions. Every one acts on the node under the cursor; a feature on the same key
---ranks above them (see `table`), as a feature key replaced the tree's own one before this table.
---@return Filetree.Action[]
function M.builtins()
  return {
    {
      name = "open",
      key = { "<CR>", "o", "<2-LeftMouse>" },
      desc = "Open the file, or open/close the folder",
      menu = false,
      run = function(_, ctx)
        M.activate(view_of(ctx))
      end,
    },
    {
      name = "enter",
      key = "l",
      desc = "Open the folder or file; on an open folder, go to its first entry",
      menu = false,
      run = function(_, ctx)
        open_or_enter(view_of(ctx))
      end,
    },
    {
      name = "close_or_parent",
      key = "h",
      desc = "Close the folder, or go to the parent folder",
      menu = false,
      run = function(_, ctx)
        close_or_parent(view_of(ctx))
      end,
    },
    {
      name = "close_parent",
      key = "C",
      desc = "Close the folder the entry lies in",
      needs = { "path" },
      menu = false,
      run = function(_, ctx)
        local view = view_of(ctx)
        local row = view:current()
        local parent = row and view.tree:parent(row.id)
        if row and row.expanded and row.id ~= view.root then
          view:collapse(row.id)
        elseif parent and parent ~= view.root then
          view:collapse(parent)
          local line = view.tree:row_of(parent)
          if line then view:set_cursor(line) end
        end
      end,
    },
    {
      name = "collapse_all",
      key = "z",
      desc = "Close every folder",
      menu = false,
      run = function(_, ctx)
        view_of(ctx):collapse_all()
      end,
    },
    {
      name = "refresh",
      key = "R",
      desc = "Read the folders again, or ask the sources of the view again",
      run = function(_, ctx)
        view_of(ctx):refresh()
      end,
    },
    {
      name = "toggle_ignored",
      key = "H",
      desc = "Show or hide the names of the ignore list",
      needs = { "source:files" },
      run = function(_, ctx)
        local view = view_of(ctx)
        view:set_hide_ignored(not view.hide_ignored)
      end,
    },
    {
      name = "up",
      key = "-",
      desc = "Show the parent folder as the root",
      needs = { "source:files" },
      menu = false,
      run = function(_, ctx)
        local view = view_of(ctx)
        local parent = require("filetree.native.fs.list").parent(view.root)
        if parent then
          local from = view.root
          view:set_root(parent)
          view:reveal(from)
        end
      end,
    },
    {
      name = "open_picked",
      key = "sw",
      desc = "Open the file in a window you pick",
      needs = { "file" },
      run = function(_, ctx)
        local view = view_of(ctx)
        -- the file under the cursor, also with nodes marked: one window is picked for one file
        local row = view:current()
        local path = row and row.node.path
        if not path then return end
        local ok, picker = pcall(require, "ui.windowpicker")
        local win = ok and picker.pick() or nil
        if ok and not win then return end -- the pick was cancelled
        require("filetree.native").open_path(view, path, "edit", win)
      end,
    },
    {
      name = "view_next",
      key = '"',
      desc = "Show the next view (files, buffers, git, ...)",
      menu = false,
      run = function(_, ctx)
        view_of(ctx):cycle(1)
      end,
    },
    {
      name = "view_prev",
      key = "!",
      desc = "Show the previous view",
      menu = false,
      run = function(_, ctx)
        view_of(ctx):cycle(-1)
      end,
    },
    {
      name = "close",
      key = "q",
      desc = "Close the tree",
      menu = false,
      run = function(_, ctx)
        view_of(ctx):close()
      end,
    },
  }
end

-- ── the table of a view ────────────────────────────────────────────────────────

---The node under the cursor, nil on no row.
---@param view Filetree.View
---@return table|nil
local function cursor_node(view)
  local row = view:current()
  return row and row.node or nil
end

---What an action is checked and run with: the source is the one the node under the cursor came from
---(a view may show several, one section each).
---@param view Filetree.View
---@return Filetree.Action.Ctx
function M.ctx(view)
  local node = cursor_node(view)
  local source = view:source_of(node and node.id)
  local mutable = true
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  local entry = ok and registry.get("source", source) or nil
  if entry and entry.mutable == false then mutable = false end
  local ctx = view:ctx(source) --[[@as Filetree.Action.Ctx]]
  ctx.mutable = mutable
  -- `view` is the name of the view, as for a source; the view itself is `tree`
  ctx.tree = view
  return ctx
end

---Read the actions of other plugins and of the view's sources from the registry again.
---@param view Filetree.View
local function load_registry(view)
  local t = view.actions
  if not t then return end
  t:remove_origin("plugin")
  t:remove_origin("source")
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok then return end
  for _, action in ipairs(registry.list("action")) do
    pcall(t.add, t, action, "plugin")
  end
  for _, name in ipairs(view:sources()) do
    local source = registry.get("source", name)
    local need = "source:" .. name
    for _, action in ipairs(source and source.actions or {}) do
      -- an action a source brought is about that source's nodes: in a view with several sections it
      -- must not take a key on the rows of another one
      local own = vim.tbl_extend("force", {}, action)
      own.needs = vim.list_extend({ need }, action.needs or {})
      pcall(t.add, t, own, "source")
    end
  end
end

---The marked nodes of this view (marks feature), else the node under the cursor. Marked paths
---outside this view's tree, or not shown in it, are left out.
---@param view Filetree.View
---@return table[]
function M.selection(view)
  local out = {}
  local ok, filetree = pcall(require, "filetree")
  local marks = ok and filetree.feature and filetree.feature("marks") or nil
  if marks and type(marks.get_marked) == "function" then
    local norm = require("filetree.native.fs.list").norm
    for _, path in ipairs(marks.get_marked() or {}) do
      local id = view:id_of(norm(path))
      local node = view.tree:node(id)
      if node then out[#out + 1] = node end
    end
  end
  if #out == 0 then
    local node = cursor_node(view)
    if node then out[1] = node end
  end
  return out
end

---Run an action of the table on the selection.
---@param view Filetree.View
---@param action Filetree.Action
---@param args? table<string, string>
local function invoke(view, action, args)
  local ctx = M.ctx(view)
  local nodes = M.selection(view)
  -- every node of the selection has to fit, not only the one under the cursor
  for _, node in ipairs(nodes) do
    local ok, reason = tbl.check(action, node, ctx)
    if not ok then
      notify.info(("%s: %s (%s)"):format(action.name, reason, node.label or node.id))
      return
    end
  end
  local ok, err = pcall(action.run, nodes, ctx, args)
  if not ok then notify.error(("%s failed: %s"):format(action.name, tostring(err))) end
end

---What a key does in a view.
---@param view Filetree.View
---@param lhs string
function M.run_key(view, lhs)
  local t = view.actions
  if not t then return end
  -- An action that presses its own key again while it runs (a feature that wraps what was on the key
  -- before it, like preview's <CR>) reaches the next action of the key, not itself once more.
  view._running = view._running or {}
  local running = view._running[lhs] or {}
  local action, reason = t:resolve(lhs, cursor_node(view), M.ctx(view), running)
  if not action then
    notify.info(reason)
    return
  end
  running[action.name] = true
  view._running[lhs] = running
  local ok, err = pcall(invoke, view, action, nil)
  running[action.name] = nil
  if next(running) == nil then view._running[lhs] = nil end
  if not ok then error(err, 0) end
end

---Run an action by name (`:Filetree action <name>`); says why when it does not apply.
---@param view Filetree.View
---@param name string
---@param args? table<string, string>
---@return boolean ran
function M.run(view, name, args)
  local t = view.actions
  local action = t and t:get(name)
  if not action then
    notify.info(("no action %q in this tree"):format(name))
    return false
  end
  local ok, reason = tbl.check(action, cursor_node(view), M.ctx(view))
  if not ok then
    notify.info(("%s: %s"):format(name, reason))
    return false
  end
  invoke(view, action, args)
  return true
end

---The actions that apply to the node under the cursor, in rank order, each with the key that
---reaches it there (nil when another action takes all of its keys).
---@param view Filetree.View
---@return { action: Filetree.Action, key: string|nil }[]
function M.applicable(view)
  local t = view.actions
  if not t then return {} end
  local node, ctx = cursor_node(view), M.ctx(view)
  local out = {}
  for _, action in ipairs(t:applicable(node, ctx)) do
    local reached = nil
    for _, lhs in ipairs(tbl.keys_of(action)) do
      -- a key the user or another plugin mapped over reaches none of the table's actions
      if
        not (view._foreign and view._foreign[t:canon(lhs)]) and t:reaches(lhs, action, node, ctx)
      then
        reached = lhs
        break
      end
    end
    out[#out + 1] = { action = action, key = reached }
  end
  return out
end

-- ── keys on the buffer ─────────────────────────────────────────────────────────

---Is `lhs` the beginning of a longer key of the table (`d` of `dd`)?
---@param t Filetree.Action.Table
---@param lhs string
---@return boolean
local function starts_longer(t, lhs)
  local id = t:canon(lhs)
  for _, other in ipairs(t:keys()) do
    local longer = t:canon(other)
    if #longer > #id and longer:sub(1, #id) == id then return true end
  end
  return false
end

---Set the dispatcher on one key.
---@param view Filetree.View
---@param buf integer
---@param lhs string
local function bind(view, buf, lhs)
  local t = view.actions --[[@as Filetree.Action.Table]]
  local first = nil
  for _, action in ipairs(t:list()) do
    if t:claims(action, lhs) then
      first = action
      break
    end
  end
  vim.keymap.set("n", lhs, function()
    M.run_key(view, lhs)
  end, {
    buffer = buf,
    -- a key that begins a longer one has to wait for it: `d` while this view has a `dd`
    nowait = not starts_longer(t, lhs),
    silent = true,
    desc = M.PREFIX .. (first and first.desc or lhs),
  })
end

---Call a mapping read back from the buffer, as pressing its key would.
---@param m table  An entry of `nvim_buf_get_keymap`.
local function call_mapping(m)
  if m.callback then
    local result = m.callback()
    if m.expr == 1 and type(result) == "string" and result ~= "" then
      api.nvim_feedkeys(api.nvim_replace_termcodes(result, true, false, true), "n", false)
    end
    return
  end
  if m.rhs and m.rhs ~= "" then
    local keys = api.nvim_replace_termcodes(m.rhs, true, false, true)
    api.nvim_feedkeys(keys, m.noremap == 1 and "n" or "m", false)
  end
end

---The mapping's lhs in the form `vim.keymap.set` takes and the table's keys use.
---@param m table
---@return string
local function lhs_of(m)
  local lhs = m.lhs
  local leader = vim.g.mapleader
  if type(leader) ~= "string" or leader == "" then leader = "\\" end
  if lhs:sub(1, #leader) == leader and #lhs > #leader then
    lhs = "<leader>" .. lhs:sub(#leader + 1)
  end
  return (lhs:gsub(" ", "<Space>"))
end

---Read the feature keys of the buffer back into the table, and put the dispatcher on every key some
---action of another origin claims too. Safe to call again: it starts over from the buffer.
---@param view Filetree.View
function M.sync(view)
  local buf = view.buf
  local t = view.actions
  if not (t and buf and api.nvim_buf_is_valid(buf)) then return end
  view._feature_maps = view._feature_maps or {}
  local maps = view._feature_maps
  -- a mapping that is filetree's is a feature's: it becomes an entry of the table. Anything else that
  -- is not ours (the user's `adapter_keymaps`, another plugin) is foreign: that key stays as it is.
  local foreign = {}
  ---@type table<string, string>  canonical key -> the lhs of the dispatcher mapping on it
  local dispatched = {}
  for _, m in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
    local desc = m.desc or ""
    local lhs = lhs_of(m)
    local id = t:canon(lhs)
    if desc:sub(1, #FEATURE_PREFIX) == FEATURE_PREFIX then
      maps[id] = m
    elseif desc:sub(1, #M.PREFIX) == M.PREFIX then
      dispatched[id] = lhs
    else
      foreign[id] = true
      maps[id] = nil
    end
  end
  view._foreign = foreign
  t:remove_origin("feature")
  for _, m in pairs(maps) do
    local lhs = lhs_of(m)
    t:add({
      name = "feature:" .. lhs,
      key = lhs,
      desc = (m.desc or ""):sub(#FEATURE_PREFIX + 1):gsub("^%l", string.upper),
      run = function()
        call_mapping(m)
      end,
    }, "feature")
  end
  -- every key of another origin goes through the dispatcher; a key only a feature claims keeps its
  -- own mapping (nothing to decide)
  for _, lhs in ipairs(t:keys()) do
    local id = t:canon(lhs)
    local others = false
    for _, action in ipairs(t:list()) do
      if action.origin ~= "feature" and t:claims(action, lhs) then
        others = true
        break
      end
    end
    -- a feature's own mapping does not wait: while a longer key of the table begins with it (`d` and
    -- a source's `dd`), the key goes through the dispatcher, which does
    if (others or starts_longer(t, lhs)) and not foreign[id] then
      bind(view, buf, lhs)
      dispatched[id] = nil
    end
  end
  -- a dispatcher left on a key no other action claims any more (an action was unregistered): the
  -- feature's own mapping comes back, or the key is free again
  for id, lhs in pairs(dispatched) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    local m = maps[id]
    if m then api.nvim_buf_call(buf, function()
      vim.fn.mapset("n", false, m)
    end) end
  end
end

---The view shows other sources now: take their actions into the table and bind their keys.
---@param view Filetree.View
function M.reload(view)
  load_registry(view)
  M.sync(view)
end

---Build the table of a view and bind its keys on `buf`. Called before the buffer gets its filetype;
---the feature keys follow with `sync`, once the features have bound them.
---@param view Filetree.View
---@param buf integer
function M.attach(view, buf)
  local t = tbl.new(require("filetree.util.key_conflicts").canon)
  view.actions = t
  for _, action in ipairs(M.builtins()) do
    t:add(action, "builtin")
  end
  load_registry(view)
  for _, lhs in ipairs(t:keys()) do
    bind(view, buf, lhs)
  end
  M.listen()
end

local listening = false
---@type fun()|nil
local unsubscribe = nil

---Follow the registry and the features' attach, once for every view.
function M.listen()
  if listening then return end
  listening = true
  local group = api.nvim_create_augroup("filetree_native_actions", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FiletreeAttached",
    desc = "[filetree] Read the feature keys of a tree buffer into its action table",
    callback = function(ev)
      local buf = ev.data and ev.data.buf
      local view = buf and require("filetree.native.view").of_buf(buf)
      if view then M.sync(view) end
    end,
  })
  -- the end of the operation pipeline: only the folders the source and the target lie in are read again
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FiletreeChanged",
    desc = "[filetree] Read the folders of a finished file operation again",
    callback = function(ev)
      local data = ev.data or {}
      for _, view in ipairs(require("filetree.native").all()) do
        if type(data.from) == "string" then view:refresh_path(data.from) end
        if type(data.to) == "string" then view:refresh_path(data.to) end
      end
    end,
  })
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if ok then
    unsubscribe = registry.subscribe(function(ev)
      if ev.kind ~= "action" and ev.kind ~= "source" then return end
      vim.schedule(function()
        for _, view in ipairs(require("filetree.native").all()) do
          if ev.kind == "source" then view:source_changed(ev.name) end
          load_registry(view)
          M.sync(view)
        end
      end)
    end)
  end
end

---Forget the listeners (tests, `native.reset`).
function M.reset()
  listening = false
  pcall(api.nvim_del_augroup_by_name, "filetree_native_actions")
  if unsubscribe then
    unsubscribe()
    unsubscribe = nil
  end
end

return M
