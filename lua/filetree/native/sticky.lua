---@module 'filetree.native.sticky'
---@brief The folders the top row lies in stay on top while the own tree is scrolled.
---@description
--- A float of one line per folder over the first rows of the tree window, at most `max` (the nearest
--- ones). It shows copies of the lines; their highlights and badges are drawn by the tree's own
--- decoration provider, which asks `source` which row of the tree a line of the float stands for.
---
--- - `update(view, max, reason)`: bring the float in line with where the window is scrolled to
--- - `close(view)`: take it away
--- - `state(view)`: what is pinned right now (rows of the tree, top to bottom)
--- - `click(view, pos)`: a mouse position on a pinned row jumps to that folder
---
--- Nothing is computed while the window shows the first row of the tree.

local api = vim.api

local M = {}

---@class Filetree.Sticky.State
---@field win integer  The float.
---@field buf integer  Its buffer.
---@field tree_buf integer  The buffer of the tree the lines are copied from.
---@field rows integer[]  The rows of the tree the float shows, top to bottom (1-based).
---@field text string  The lines it shows, joined: what is compared before anything is written.

---@type table<Filetree.View, Filetree.Sticky.State>
local shown = setmetatable({}, { __mode = "k" })

---@type table<integer, Filetree.Sticky.State>  buffer of a float -> what it shows
local by_buf = {}

---The rows of the folders row `line` lies in that stand above it, the nearest `max`, top to bottom.
---@param tree Lib.Tree
---@param line integer  1-based.
---@param max integer
---@return integer[]
local function ancestors(tree, line, max)
  local row = tree:row(line)
  if not row then return {} end
  local out = {}
  local id = tree:parent(row.id)
  while id ~= nil and #out < max do
    local at = tree:row_of(id)
    -- the hidden root has no row
    if at and at >= 1 and at < line then table.insert(out, 1, at) end
    id = tree:parent(id)
  end
  return out
end

---The rows to pin for a window whose first line is `top`. The float covers as many rows as it has
---lines, so the folders are those of the first row it leaves visible: asked again until the number
---of lines stays the same. An answer with fewer lines ends it: the row it was asked for lies less
---deep than the rows before it, its folders are folders of those rows too, and asking on would
---swing between the two.
---@param tree Lib.Tree
---@param top integer
---@param max integer
---@return integer[]
local function pins(tree, top, max)
  local rows = {}
  for _ = 1, max + 1 do
    local again = ancestors(tree, top + #rows, max)
    local settled = #again <= #rows
    rows = again
    if settled then break end
  end
  return rows
end

---@param view Filetree.View
function M.close(view)
  local state = shown[view]
  if not state then return end
  shown[view] = nil
  by_buf[state.buf] = nil
  if api.nvim_win_is_valid(state.win) then pcall(api.nvim_win_close, state.win, true) end
  if api.nvim_buf_is_valid(state.buf) then
    pcall(api.nvim_buf_delete, state.buf, { force = true })
  end
end

---What is pinned over the tree of `view` right now.
---@param view Filetree.View
---@return Filetree.Sticky.State?
function M.state(view)
  local state = shown[view]
  if state and api.nvim_win_is_valid(state.win) then return state end
  return nil
end

---Which buffer of a tree, and which of its rows, the lines of a float stand for.
---@param buf integer
---@return integer? tree_buf
---@return integer[]? rows
function M.source(buf)
  local state = by_buf[buf]
  if not state then return nil, nil end
  return state.tree_buf, state.rows
end

---Bring the pinned rows in line with where the tree window is scrolled to.
---@param view Filetree.View
---@param max integer  Folders pinned at most; 0 pins nothing.
---@param reason? "scroll"|"cursor"  What happened: decides how a cursor under the float gets out.
function M.update(view, max, reason)
  local win, buf = view.win, view.buf
  if
    max <= 0
    or not win
    or not buf
    or not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= buf
  then
    M.close(view)
    return
  end
  local top = vim.fn.line("w0", win)
  if top <= 1 then
    M.close(view)
    return
  end
  -- half of the window at most stays for the rows themselves
  max = math.min(max, math.floor((api.nvim_win_get_height(win) - 1) / 2))
  local rows = max > 0 and pins(view.tree, top, max) or {}
  if #rows == 0 then
    M.close(view)
    return
  end

  -- The cursor must not end under the float. After a scroll it is taken along, as Vim does with a
  -- cursor that leaves the window; after a move of the cursor the window follows it (by `max`, so
  -- that it is clear of the float however many rows that pins then).
  local cursor = api.nvim_win_get_cursor(win)[1]
  if cursor < top + #rows then
    if reason == "cursor" then
      local want = math.max(1, cursor - max)
      if want ~= top then
        api.nvim_win_call(win, function()
          vim.fn.winrestview({ topline = want })
        end)
        M.update(view, max, nil)
        return
      end
    elseif reason == "scroll" then
      view:set_cursor(math.min(top + #rows, view.tree:count()))
    end
  end

  local lines = {}
  for i, at in ipairs(rows) do
    lines[i] = api.nvim_buf_get_lines(buf, at - 1, at, false)[1] or ""
  end
  local text = table.concat(lines, "\n")
  local info = vim.fn.getwininfo(win)[1] or {}
  local config = {
    relative = "win",
    win = win,
    -- row 0 of a window is its winbar (the view bar)
    row = info.winbar or 0,
    col = 0,
    width = api.nvim_win_get_width(win),
    height = #rows,
  }

  local state = M.state(view)
  if state then
    state.rows = rows
    if state.text ~= text then
      api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
      state.text = text
    end
    local now = api.nvim_win_get_config(state.win)
    if now.height ~= config.height or now.width ~= config.width or now.row ~= config.row then
      pcall(api.nvim_win_set_config, state.win, config)
    end
    return
  end

  M.close(view)
  local float_buf = api.nvim_create_buf(false, true)
  vim.bo[float_buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  config.style = "minimal"
  config.focusable = false
  -- noautocmd: nobody may take this float for the tree (see the float of a cut name)
  config.noautocmd = true
  -- over the tree when the tree is a float itself, under the float of a cut name
  local tree_z = api.nvim_win_get_config(win).zindex
  config.zindex = tree_z and (tree_z + 1) or 40
  local okay, float = pcall(api.nvim_open_win, float_buf, false, config)
  if not okay then
    pcall(api.nvim_buf_delete, float_buf, { force = true })
    return
  end
  vim.wo[float][0].winhighlight = "NormalFloat:FiletreeSticky"
  vim.wo[float][0].wrap = false
  state = { win = float, buf = float_buf, tree_buf = buf, rows = rows, text = text }
  shown[view] = state
  by_buf[float_buf] = state
end

---The pinned row a mouse position is on, when it is on one.
---@param view Filetree.View
---@param pos table  `getmousepos()` result.
---@return integer? row  The row of the tree that is pinned there.
function M.row_at(view, pos)
  local state = M.state(view)
  if not state or type(pos) ~= "table" then return nil end
  local index = nil
  if pos.winid == state.win then
    -- a Neovim that hands the click to the float itself
    index = pos.winrow
  elseif pos.winid == view.win and view.win and api.nvim_win_is_valid(view.win) then
    -- the click went through the float: the line under it is the one the float covers
    index = pos.line - vim.fn.line("w0", view.win) + 1
  end
  return index and state.rows[index] or nil
end

---A click on a pinned row: put the cursor on that folder. The move itself is scheduled, this may be
---called from an expression mapping.
---@param view Filetree.View
---@param pos table  `getmousepos()` result.
---@return boolean handled  false when the position is on no pinned row.
function M.click(view, pos)
  local row = M.row_at(view, pos)
  if not row then return false end
  local target = view.tree:row(row)
  local id = target and target.id
  vim.schedule(function()
    local at = id ~= nil and view.tree:row_of(id) or nil
    if at and view.win and api.nvim_win_is_valid(view.win) then view:set_cursor(at) end
  end)
  return true
end

return M
