---@module 'filetree.native.bar'
---@brief The view bar of the own tree: the views of a tree window as tabs in its winbar.
---@description
--- One tab per view (`View:views()`), the one on screen set off, a count next to a view whose sources
--- carry statuses, a view whose source cannot load dimmed with `[!]`. A click shows the view; so do
--- the tree's keys for the next and the previous one.
---
--- Key responsibilities:
--- - `items(view)`: what the bar says, as data (specs and `:checkhealth` read this)
--- - `render(items, width)`: the winbar string, pure; titles are cut when the window is narrow
--- - `update(view)`: write it, at most once per tick and only when it changed
---
--- The option is written local to the tree buffer in its window (`vim.wo[win][0]`), not through
--- `ui.winbar`: a file opened into the same window later must not inherit the bar.

local api = vim.api

local M = {}

--- Bar highlight group -> the editor group it links to by default.
---@type table<string, string>
M.HL = {
  FiletreeBar = "WinBar",
  FiletreeBarCurrent = "TabLineSel",
  FiletreeBarOther = "WinBarNC",
  FiletreeBarDim = "Comment",
  FiletreeBarCount = "DiagnosticWarn",
}

---@class Filetree.Bar.Item
---@field name string  The view.
---@field title string
---@field current boolean
---@field count integer?  Nodes that carry a status, when the view was built and has any.
---@field available boolean
---@field reason string?  Why not, when not.

---@param name string
---@return string
local function capitalized(name)
  return name:sub(1, 1):upper() .. name:sub(2)
end

---Can the sources of a view load right now? Asked without building the view: `available()` is a
---source's cheap answer by contract.
---@param spec Filetree.View.Spec
---@return boolean available
---@return string|nil reason
function M.available(spec)
  local registry = require("filetree.registry")
  local first_reason = nil
  local any = false
  for _, source in ipairs(spec.sources) do
    if source == "files" then
      any = true
    else
      local entry = registry.get("source", source)
      if not entry then
        first_reason = first_reason or ("no source %q is registered"):format(source)
      elseif type(entry.available) == "function" then
        local ok, can, reason = pcall(entry.available)
        if ok and can ~= false then
          any = true
        else
          first_reason = first_reason or (ok and reason or tostring(can)) or "not available"
        end
      else
        any = true
      end
    end
  end
  -- a view of several sections is worth showing as long as one of them has something
  if any then return true, nil end
  return false, first_reason or "not available"
end

---What the bar of a view says.
---@param view Filetree.View
---@return Filetree.Bar.Item[]
function M.items(view)
  local registry = require("filetree.registry")
  local out = {}
  for _, spec in ipairs(view:views()) do
    local entry = #spec.sources == 1 and registry.get("source", spec.sources[1]) or nil
    local available, reason = M.available(spec)
    out[#out + 1] = {
      name = spec.name,
      title = entry and entry.title or capitalized(spec.name),
      current = spec.name == view.view_name,
      count = view:count_of(spec.name),
      available = available,
      reason = reason,
    }
  end
  return out
end

---@param text string
---@return string
local function escaped(text)
  return (text:gsub("%%", "%%%%"))
end

---The text of one tab at a level of shortening: 0 the title, 1 three characters, 2 one.
---@param item Filetree.Bar.Item
---@param level integer
---@return string
local function label_of(item, level)
  if item.current or level == 0 then return item.title end
  return vim.fn.strcharpart(item.title, 0, level == 1 and 3 or 1)
end

---@param items Filetree.Bar.Item[]
---@param level integer
---@return string plain  What is on screen, without the highlight and click items.
---@return string line  The winbar string.
local function build(items, level)
  local plain, line = {}, { "%#FiletreeBar#" }
  for i, item in ipairs(items) do
    local group = item.current and "FiletreeBarCurrent"
      or (item.available and "FiletreeBarOther" or "FiletreeBarDim")
    local text = " " .. label_of(item, level)
    if not item.available then text = text .. " [!]" end
    local count = (item.count and item.count > 0) and (" " .. item.count) or ""
    plain[#plain + 1] = text .. count .. " "
    line[#line + 1] = ("%%%d@v:lua.__filetree_bar_click@%%#%s#%s"):format(i, group, escaped(text))
    if count ~= "" then line[#line + 1] = "%#FiletreeBarCount#" .. count end
    line[#line + 1] = ("%%#%s# %%X"):format(group)
  end
  line[#line + 1] = "%#FiletreeBar#"
  return table.concat(plain), table.concat(line)
end

---The winbar string for a list of views. The titles of the views that are not on screen are cut to
---three characters, then to one, as long as the bar is wider than the window.
---@param items Filetree.Bar.Item[]
---@param width integer  Columns of the window.
---@return string line  The winbar string ("" when there is nothing to switch between).
---@return string plain  The text of it.
function M.render(items, width)
  if #items < 2 then return "", "" end
  local plain, line = "", ""
  for level = 0, 2 do
    plain, line = build(items, level)
    if vim.fn.strdisplaywidth(plain) <= width then break end
  end
  return line, plain
end

---A click on a tab of the bar: the window under the mouse shows that view.
---@param index integer  The position of the view in the bar.
---@param _ integer  How often it was clicked.
---@param button string
function M.click(index, _, button)
  if button ~= "l" then return end
  local win = vim.fn.getmousepos().winid
  if not win or win == 0 or not api.nvim_win_is_valid(win) then return end
  local view = require("filetree.native.view").of_buf(api.nvim_win_get_buf(win))
  local spec = view and view:views()[index]
  if not view or not spec then return end
  view:show(spec.name)
end

-- a click item of 'winbar' can name a global function only
_G.__filetree_bar_click = function(index, clicks, button)
  M.click(index, clicks, button)
end

---@type table<integer, true>  Buffers whose bar is waiting to be written.
local pending = {}

---Write the bar of a view now.
---@param view Filetree.View
function M.write(view)
  local win = view.win
  if not win or not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= view.buf then
    return
  end
  local line = ""
  if view:bar_enabled() then line = (M.render(M.items(view), api.nvim_win_get_width(win))) end
  local wo = vim.wo[win][0]
  if wo.winbar ~= line then wo.winbar = line end
end

---Write the bar of a view soon: once per tick, however many rows changed in it.
---@param view Filetree.View
function M.update(view)
  local buf = view.buf
  if not buf or pending[buf] then return end
  pending[buf] = true
  vim.schedule(function()
    pending[buf] = nil
    if view.buf == buf then M.write(view) end
  end)
end

function M.define_highlights()
  for group, link in pairs(M.HL) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

return M
