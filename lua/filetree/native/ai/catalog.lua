---@module 'filetree.native.ai.catalog'
---@brief What the model is told: the actions of the tree view (the catalog) and where the tree stands.
---@description
--- The catalog is the action table of the view (decision L11 of the concept): the model picks from what
--- the tree can do anyway. Every entry gets a stable name: the tree's own and other plugins' actions keep
--- theirs, a filetree feature's key (`feature:sg` in the table) is named after the feature and its action
--- (`open_variants.vsplit`), which the table writes on the entry, so the name does not depend on the key.
---
--- Whether an entry changes files decides whether a plan runs at once or asks first:
---
---   the tree's own actions          read only (open, fold, views, root)
---   another plugin's or a source's  read only when it says `mutates = false`; without a word it asks
---   a filetree feature's key        read only when the feature is on the list below; any other one,
---                                   or a key whose feature cannot be told, counts as changing files
---
--- So a feature that is new or unknown here never runs without the question. An action with
--- `ai = false` is not in the catalog; neither are the features on `NEVER` (a shell command, keys that
--- take over the keyboard).
---
--- The context holds names and paths only, never what is in a file.

local list = require("filetree.native.fs.list")
local service = require("filetree.native.fs.service")

local M = {}

--- Features a plan never names: a shell command (or a script run in a terminal), global keys and modes that take over the keyboard.
---@type table<string, true>
M.NEVER =
  { shell_run = true, term_run = true, quickpick = true, tree_toggle = true, context_menu = true }

--- Paths the context lists at most.
M.MAX_PATHS = 400
--- Marked entries the context lists at most.
M.MAX_SELECTION = 50

---@class Filetree.Ai.Item
---@field name string  The name the model uses.
---@field action string  The name in the action table of the view.
---@field desc string
---@field args? table<string, { values?: string[], default?: string, desc?: string }>
---@field mutates boolean
---@field needs? string[]
---@field feature? string  The filetree feature the key belongs to.

---The catalog of a view.
---@param view Filetree.View
---@return Filetree.Ai.Item[] items  In the rank order of the table.
---@return table<string, Filetree.Ai.Item> by_name
function M.build(view)
  local items, by_name = {}, {}
  local t = view.actions
  if not t then return items, by_name end
  for _, action in ipairs(t:list()) do
    local item = nil
    if action.ai ~= false then
      if action.origin == "feature" then
        -- the table says which feature a key is and whether it changes files
        -- (`filetree.native.action.features`)
        local feature = action.feature
        if feature and not M.NEVER[feature] then
          item = {
            name = feature .. "." .. tostring(action.feature_action),
            feature = feature,
            mutates = action.mutates ~= false,
          }
        elseif not feature then
          -- a key nobody can name: offered, but it asks first
          item = { name = action.name, mutates = true }
        end
      else
        item = {
          name = action.name,
          -- the tree's own actions change no file; another one runs without the question only
          -- when it says so (`mutates = false`): one that says nothing may change anything
          mutates = action.origin ~= "builtin" and action.mutates ~= false,
          args = type(action.args) == "table" and action.args or nil,
        }
      end
    end
    if item and not by_name[item.name] then
      item.action = action.name
      item.desc = type(action.desc) == "string" and action.desc or action.name
      item.needs = action.needs
      items[#items + 1] = item
      by_name[item.name] = item
    end
  end
  return items, by_name
end

---Every path the tree knows below its root, without reading anything: the rows of the tree, then the
---folders the cache has read, breadth first.
---@param view Filetree.View
---@param cap? integer
---@return table<string, boolean> known  Path -> is a folder.
---@return string[] order
function M.known(view, cap)
  cap = cap or M.MAX_PATHS
  local known, order = {}, {}
  local root = view.root
  local function add(path, is_dir)
    if known[path] ~= nil or #order >= cap then return end
    if not list.inside(root, path) then return end
    known[path] = is_dir and true or false
    order[#order + 1] = path
  end
  add(root, true)
  local i = 1
  while #order < cap do
    local row = view.tree and view.tree:row(i)
    if not row then break end
    local node = row.node
    if node and type(node.path) == "string" then
      add(list.norm(node.path), node.kind == "dir" or row.expandable == true)
    end
    i = i + 1
  end
  local queue, at = { root }, 1
  while at <= #queue and #order < cap do
    local entries = service.cached(queue[at])
    at = at + 1
    for _, entry in ipairs(entries or {}) do
      add(entry.path, entry.is_dir)
      if entry.is_dir then queue[#queue + 1] = entry.path end
    end
  end
  return known, order
end

---The marked paths of the view, else nil.
---@return string[]|nil
function M.marked()
  local ok, filetree = pcall(require, "filetree")
  local marks = ok and filetree.feature and filetree.feature("marks") or nil
  if not (marks and type(marks.get_marked) == "function") then return nil end
  local out = {}
  for _, path in ipairs(marks.get_marked() or {}) do
    out[#out + 1] = list.norm(path)
  end
  return #out > 0 and out or nil
end

---Where the tree stands, in names only.
---@param view Filetree.View
---@param known table<string, boolean>  Path -> is a folder.
---@param order string[]  The known paths.
---@return table
function M.context(view, known, order)
  local rel_of = require("filetree.native.ai.plan").rel_of
  local root = view.root
  local function rel(path)
    if list.inside(root, path) then
      local r = rel_of(root, path)
      return r == "" and "." or r
    end
    return path
  end
  local row = view:current()
  local cursor = nil
  if row and row.node then
    cursor = type(row.node.path) == "string" and rel(list.norm(row.node.path))
      or tostring(row.node.label or row.node.id)
  end
  local selection = {}
  for _, path in ipairs(M.marked() or {}) do
    if #selection >= M.MAX_SELECTION then break end
    selection[#selection + 1] = rel(path)
  end
  local paths = {}
  for _, path in ipairs(order) do
    -- a folder ends in "/": the model can tell where a file may go
    if path ~= root then paths[#paths + 1] = rel(path) .. (known[path] and "/" or "") end
  end
  return {
    root = root,
    cwd = list.norm(vim.fn.getcwd()),
    view = view.view_name,
    cursor = cursor,
    selection = selection,
    paths = paths,
  }
end

--- What the model is told to do. The rules are checked again on the answer: this text only saves a
--- round trip, it is not what keeps a plan safe.
M.SYSTEM = table.concat({
  "You turn a request about a file tree into a plan of the tree's own actions.",
  'Answer with JSON only: a list of steps [{"action": "<name>", "target": "<path>", "args": {}}].',
  "Use only action names from the catalog. Never invent an action, a path or an argument.",
  "target is a path relative to the root, taken from the list of known paths; leave it out to act on",
  "the selection or the entry under the cursor. args only as the catalog declares them.",
  'Use as few steps as possible. When nothing in the catalog fits, answer {"none": "<why>"}.',
}, "\n")

---The prompt for one request.
---@param items Filetree.Ai.Item[]
---@param context table
---@param text string
---@return string
function M.prompt(items, context, text)
  local catalog = {}
  for _, item in ipairs(items) do
    catalog[#catalog + 1] = {
      name = item.name,
      desc = item.desc,
      args = item.args,
      mutates = item.mutates,
      needs = item.needs,
    }
  end
  local where = context
  return table.concat({
    "Catalog:",
    vim.json.encode(catalog),
    "",
    "Tree:",
    vim.json.encode(where),
    "",
    "Request:",
    text,
  }, "\n")
end

return M
