---@module 'filetree.native.render.columns'
---@brief Share out the width of a tree line between the name and what stands right of it.
---@description
--- Right of the name stand badges (git letter, diagnostics count) and columns (size, time). When the
--- window is too narrow for all of it, what goes first is decided here, once, for every line alike:
--- columns before badges, a lower priority before a higher one, and the name keeps `min_name` columns
--- until nothing else is left to drop.
---
--- Key responsibilities:
--- - `layout(width, name_width, items, opts)`: which items stay and how wide the name may be
--- - `truncate(text, width, strwidth)`: cut a name to a display width, with an ellipsis
---
--- Pure: widths come in as numbers, the display width function is handed in.

local M = {}

local ELLIPSIS = "…"

---@param item Filetree.RightItem
---@return integer
local function rank(item)
  -- columns go before badges; within a slot the lower priority goes first
  return (item.slot == "badge" and 1000000 or 0) + (item.priority or 0)
end

---Decide which items fit right of the name.
---@param width integer  The usable width of the line.
---@param name_width integer  What indent, icon and the full name need.
---@param items Filetree.RightItem[]
---@param opts? { gap?: integer, min_name?: integer }  `gap`: blanks before each item (default 1); `min_name`: the width the name keeps while anything can still be dropped (default 12).
---@return Filetree.RightLayout
function M.layout(width, name_width, items, opts)
  opts = opts or {}
  local gap = opts.gap or 1
  local wanted = math.min(name_width, opts.min_name or 12)

  local kept = {}
  local used = 0
  for i, item in ipairs(items) do
    kept[i] = true
    used = used + gap + item.width
  end

  -- drop the cheapest item until the name has the room it is owed
  local order = {}
  for i in ipairs(items) do
    order[i] = i
  end
  table.sort(order, function(a, b)
    local ra, rb = rank(items[a]), rank(items[b])
    if ra ~= rb then return ra < rb end
    return a > b -- same rank: the one further right goes first
  end)
  local dropped = 0
  for _, i in ipairs(order) do
    if width - used >= wanted then break end
    kept[i] = false
    used = used - gap - items[i].width
    dropped = dropped + 1
  end

  local out = {}
  for i, item in ipairs(items) do
    if kept[i] then out[#out + 1] = item end
  end
  return {
    name_width = math.max(0, math.min(name_width, width - used)),
    items = out,
    dropped = dropped,
  }
end

---Cut `text` to at most `width` display columns; a cut text ends in an ellipsis.
---@param text string
---@param width integer
---@param strwidth fun(s: string): integer  Display width of a string (Neovim's `strdisplaywidth`).
---@return string text
---@return boolean cut
function M.truncate(text, width, strwidth)
  if width <= 0 then return "", text ~= "" end
  if strwidth(text) <= width then return text, false end
  local room = width - strwidth(ELLIPSIS)
  local out = ""
  -- character by character: a display width is not a byte count
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if strwidth(out .. char) > room then break end
    out = out .. char
  end
  return out .. ELLIPSIS, true
end

return M
