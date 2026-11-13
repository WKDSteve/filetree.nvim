---@module 'filetree.native.render.line'
---@brief One tree row to the text of its buffer line and the highlighted ranges in it.
---@description
--- The buffer line of the own tree holds indent, expander, icon and name, nothing else: badges and
--- columns are virtual text (`filetree.native.render.columns` shares out the room for them). So a
--- status change never rewrites a line, and `/` or `y` in the tree see names only.
---
--- Key responsibilities:
--- - `render(row, opts)`: text plus spans, byte columns as extmarks want them
--- - A merged line `a/b/c` gets one span per folder, each carrying the id it stands for
---
--- Pure: no buffer, no window, no editor state. Drawing is `filetree.native.view`'s job.

local M = {}

---@type { open: string, closed: string, loading: string, none: string }
local EXPANDER = { open = "▾", closed = "▸", loading = "…", none = " " }

---@type { guide: string, expander: string, name: string, dir: string }
local HL = {
  guide = "FiletreeIndent",
  expander = "FiletreeExpander",
  name = "FiletreeName",
  dir = "FiletreeDirectory",
}

---Render one row.
---@param row Lib.Tree.Row
---@param opts? Filetree.LineOpts
---@return Filetree.Line
function M.render(row, opts)
  opts = opts or {}
  local hl = opts.hl or {}
  local expander = opts.expander or EXPANDER
  local indent = opts.indent or 2
  local parts, spans, col = {}, {}, 0

  ---@param text string
  ---@param group? string
  ---@param id? any
  local function put(text, group, id)
    if text == "" then return end
    parts[#parts + 1] = text
    if group then
      spans[#spans + 1] = { col_start = col, col_end = col + #text, hl = group, id = id }
    end
    col = col + #text
  end

  if row.depth > 0 and indent > 0 then
    local level = opts.guide and (opts.guide .. (" "):rep(indent - 1)) or (" "):rep(indent)
    put(level:rep(row.depth), opts.guide and (hl.guide or HL.guide) or nil)
  end

  local glyph = expander.none
  if row.loading then
    glyph = expander.loading
  elseif row.expandable then
    glyph = row.expanded and expander.open or expander.closed
  end
  put(glyph, hl.expander or HL.expander)
  put(" ")

  if opts.icon then
    local icon, icon_hl = opts.icon(row)
    if icon and icon ~= "" then
      put(icon, icon_hl)
      put(" ")
    end
  end

  -- a folder that turned out empty has nothing to expand, and is a folder all the same
  local is_dir = row.expandable or row.node.kind == "dir"
  local name_hl = is_dir and (hl.dir or HL.dir) or (hl.name or HL.name)
  local name_start = col
  -- a file name may hold a line break or a tab (Linux allows both); a buffer line may not hold the
  -- first and should not jump at the second. One byte for one byte, so every column stays right.
  local label = (tostring(row.node.label):gsub("%c", "?"))
  ---@type any[]|nil
  local chain = type(row.node.data) == "table" and row.node.data.chain or nil
  local segments = {}
  if type(chain) == "table" then
    for segment in (label .. "/"):gmatch("(.-)/") do
      segments[#segments + 1] = segment
    end
  end
  if chain and #segments > 1 and #segments == #chain then
    -- a merged line: each folder of `a/b/c` is its own span, so a click on `b` can mean `a/b`
    for i, segment in ipairs(segments) do
      put(segment, name_hl, chain[i])
      if i < #segments then put("/", name_hl) end
    end
  else
    put(label, name_hl)
  end
  if opts.trailing_slash and is_dir then put("/", name_hl) end

  return { text = table.concat(parts), spans = spans, name_start = name_start, name_end = col }
end

return M
