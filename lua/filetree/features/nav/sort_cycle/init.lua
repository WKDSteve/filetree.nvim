---@module 'filetree.features.nav.sort_cycle'
---@brief Cycle the tree's sort criterion (name, size, modified) and reverse it; the cursor stays on its entry.
---@description
--- A thin front for the optional adapter methods `set_sort` / `get_sort` (neo-tree drives its own
--- `state.sort`). Backends without them (nvim-tree, oil, mini.files, netrw) say so instead of
--- failing. The cursor identity restore lives in the adapter: it remembers the node under the
--- cursor before the re-sort and finds it again by path once the tree re-rendered.
---
--- Cycle order: name (ascending) -> size (largest first) -> modified (newest first) -> name.
---
--- Config:
---   enabled         boolean
---   keymap_cycle    string?  Next criterion (default "<leader>so").
---   keymap_reverse  string?  Flip the direction of the current criterion (default "<leader>sO").

local notify = require("filetree.util.notify").create("[filetree.sort_cycle]")
local bind = require("filetree.util.bind")

local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.sort_cycle` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap_cycle = "keymap",
  keymap_reverse = "keymap",
}

---@type FiletreeSortCycleConfig
local DEFAULTS = {
  enabled = false,
  keymap_cycle = "<leader>so",
  keymap_reverse = "<leader>sO",
}

---@type FiletreeSortCycleConfig
local _cfg = vim.deepcopy(DEFAULTS)

---@type FiletreeAdapter?
local _adapter = nil

local ORDER = { "name", "size", "mtime" }
local LABEL = { name = "name", size = "size", mtime = "modified" }

---Newest and largest first reads naturally; names run A to Z.
---@param kind string
---@return boolean
local function natural_descending(kind)
  return kind ~= "name"
end

---@return boolean supported
local function supported()
  if not _adapter then return false end
  if type(_adapter.set_sort) ~= "function" or type(_adapter.get_sort) ~= "function" then
    notify.info(("not applicable: the %s adapter cannot sort"):format(_adapter.name))
    return false
  end
  return true
end

---@param kind string
---@param descending boolean
---@return boolean ok
local function apply(kind, descending)
  local ok, reason = _adapter.set_sort(kind, descending)
  if not ok then
    notify.warn(reason or "sort failed")
    return false
  end
  local said = ("sorted by %s (%s)"):format(LABEL[kind], descending and "descending" or "ascending")
  -- the own tree showing another view: the order is the one of the files, the view keeps its own
  local view = require("filetree.util.other_view")(_adapter)
  if view then said = ("the files are %s; the view %q keeps its own order"):format(said, view) end
  notify.info(said)
  return true
end

---Switch to the next criterion.
---@return boolean ok
function M.cycle()
  if not supported() then return false end
  local current = _adapter.get_sort()
  local at = 0
  for i, kind in ipairs(ORDER) do
    if current and current.kind == kind then at = i end
  end
  local kind = ORDER[at % #ORDER + 1]
  return apply(kind, natural_descending(kind))
end

---Flip the direction of the criterion in force.
---@return boolean ok
function M.reverse()
  if not supported() then return false end
  local current = _adapter.get_sort() or { kind = "name", descending = false }
  return apply(current.kind, not current.descending)
end

---@param cfg FiletreeSortCycleConfig
---@param adapter FiletreeAdapter
function M.setup(cfg, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), cfg or {})
  _adapter = adapter

  bind.bind("sort_cycle", _cfg, {
    {
      name = "cycle",
      field = "keymap_cycle",
      desc = "next sort criterion",
      rhs = function()
        M.cycle()
      end,
    },
    {
      name = "reverse",
      field = "keymap_reverse",
      desc = "reverse the sort",
      rhs = function()
        M.reverse()
      end,
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
