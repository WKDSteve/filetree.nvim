---@module 'filetree.native.decor.store'
---@brief Badges by path, with what every folder above them adds up to.
---@description
--- A folder that was never opened has no child nodes in the tree, yet it has to show "3 changed". So
--- the roll-up is not computed from tree nodes but kept here: every badge with a status is counted at
--- each ancestor of its path, and taken off again when it goes. Asking a folder is a table lookup.
---
--- Key responsibilities:
--- - `set(path, badge)` / `replace(map)`: change badges, answer the paths whose display changed
--- - `get(path)`: the badge of a path itself
--- - `rollup(path)`: worst status, count per status and total of everything below a folder
---
--- Pure: no editor call. Paths come in normalized (`/`-separated, one spelling per file); that is the
--- caller's job, the same one node ids already need. One store per decorator.

local M = {}

--- Rank of a status the severity list does not name: behind every one it does.
local UNRANKED = 2 ^ 52

---@class Filetree.Decor.Rollup
---@field status string|nil  Worst status below (by `severity`), nil when nothing below has one.
---@field counts table<string, integer>  Paths below, per status.
---@field total integer  Paths below that carry a status.

---@class Filetree.Decor.Store
---@field private _badges table<string, Filetree.Badge>
---@field private _counts table<string, table<string, integer>>  folder -> status -> paths below
---@field private _rank table<string, integer>
---@field private _root string|nil
local Store = {}
Store.__index = Store

---The folders above `path`, nearest first. Climbing stops at `root` (the last one answered) or at the
---top of the path (`/`, `C:`).
---@param path string
---@param root string|nil
---@return string[]
local function ancestors(path, root)
  local out = {}
  local current = path
  while current ~= root do
    local parent = current:match("^(.*)/[^/]+$")
    if not parent then break end
    if parent == "" then parent = "/" end
    out[#out + 1] = parent
    current = parent
  end
  return out
end

---Add `delta` to the count of `status` at every folder above `path`.
---@private
---@param path string
---@param status string
---@param delta integer
---@param changed table<string, true>
function Store:_count(path, status, delta, changed)
  for _, folder in ipairs(ancestors(path, self._root)) do
    local counts = self._counts[folder]
    if not counts then
      counts = {}
      self._counts[folder] = counts
    end
    local n = (counts[status] or 0) + delta
    counts[status] = n > 0 and n or nil
    if next(counts) == nil then self._counts[folder] = nil end
    changed[folder] = true
  end
end

---@private
---@param path string
---@param badge Filetree.Badge|nil
---@param changed table<string, true>
function Store:_put(path, badge, changed)
  local old = self._badges[path]
  if old == badge then return end
  local old_status = old and old.status or nil
  local new_status = badge and badge.status or nil
  self._badges[path] = badge
  changed[path] = true
  if old_status == new_status then return end
  if old_status then self:_count(path, old_status, -1, changed) end
  if new_status then self:_count(path, new_status, 1, changed) end
end

---@param changed table<string, true>
---@return string[]
local function keys_of(changed)
  local out = vim.tbl_keys(changed)
  table.sort(out)
  return out
end

---Set or remove (`nil`) the badge of one path.
---@param path string
---@param badge Filetree.Badge|nil
---@return string[] changed  The paths whose display changed: `path` and, when its status changed, its ancestors. Sorted.
function Store:set(path, badge)
  local changed = {}
  self:_put(path, badge, changed)
  return keys_of(changed)
end

---Replace every badge at once (a new `git status`): paths missing from `map` lose theirs.
---@param map table<string, Filetree.Badge>
---@return string[] changed  Sorted; empty when nothing differs.
function Store:replace(map)
  local changed = {}
  for path in pairs(self._badges) do
    if map[path] == nil then self:_put(path, nil, changed) end
  end
  for path, badge in pairs(map) do
    local old = self._badges[path]
    -- a new table with the same content is no change: a refresh that found nothing new redraws nothing
    if not (old and vim.deep_equal(old, badge)) then self:_put(path, badge, changed) end
  end
  return keys_of(changed)
end

---The badge of a path itself, or nil.
---@param path string
---@return Filetree.Badge|nil
function Store:get(path)
  return self._badges[path]
end

---What lies below a folder: worst status, paths per status, total. Nil when nothing below has a status.
---@param path string
---@return Filetree.Decor.Rollup|nil
function Store:rollup(path)
  local counts = self._counts[path]
  if not counts then return nil end
  local worst, worst_rank, total = nil, math.huge, 0
  for status, n in pairs(counts) do
    total = total + n
    -- a status the severity list does not name ranks behind every one it does; ties go by name, so
    -- the answer does not depend on pairs() order
    local r = self._rank[status] or UNRANKED
    if r < worst_rank or (r == worst_rank and worst ~= nil and status < worst) then
      worst, worst_rank = status, r
    end
  end
  return { status = worst, counts = vim.deepcopy(counts), total = total }
end

---How many paths carry a badge.
---@return integer
function Store:size()
  return vim.tbl_count(self._badges)
end

---Create a store.
---@param opts? { severity?: string[], root?: string }  `severity`: statuses, worst first; `root`: counting stops at this folder (it is the last one counted).
---@return Filetree.Decor.Store
function M.new(opts)
  opts = opts or {}
  local rank = {}
  for i, status in ipairs(opts.severity or {}) do
    rank[status] = i
  end
  return setmetatable({ _badges = {}, _counts = {}, _rank = rank, _root = opts.root }, Store)
end

return M
