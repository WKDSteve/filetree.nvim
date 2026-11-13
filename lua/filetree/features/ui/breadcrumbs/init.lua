---@module 'filetree.features.ui.breadcrumbs'
---@brief Show the path from project root to the current node as breadcrumbs.
---@description
--- Three display modes (configurable):
---   "winbar"    Set &winbar of the editor window (requires Neovim 0.8+)
---   "float"     Small 1-line floating window anchored to the tree window top
---   "statusline" Provide M.component() for statusline integration
---
--- The breadcrumb string is rebuilt on CursorMoved in the tree buffer and
--- on BufEnter in any editor buffer (syncing the breadcrumb to the editor
--- file's path relative to the project root).
---
--- Format: root  /  parent  /  child  /  filename
--- The separator, max depth, and highlight groups are configurable.

local notify = require("filetree.util.notify").create("[filetree.breadcrumbs]")

local bufevents = require("filetree.util.bufevents")
local au = require("filetree.util.autocmd")
local ui_statusline = require("lib.nvim.ui.statusline")
local M = {}

---@type FiletreeBreadcrumbsConfig
local DEFAULTS = {
  enabled = false,
  mode = "winbar", -- "winbar"|"float"|"statusline"
  separator = "  ",
  max_depth = 5,
  hl_dir = "Comment",
  hl_file = "Normal",
  hl_sep = "NonText",
  winbar_hl = "WinBar",
}

---@type FiletreeBreadcrumbsConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.breadcrumbs` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  mode = { "string", enum = { "winbar", "float", "statusline" } },
  separator = "string",
  max_depth = { "number", min = 1 },
  hl_dir = "string",
  hl_file = "string",
  hl_sep = "string",
  winbar_hl = "string",
}

---@type FiletreeAdapter?
local _adapter = nil

---@type string  last computed breadcrumb string (plain text)
local _current = ""

---@type Lib.UI.Statusline.Segment?  float mode: managed via lib.nvim.ui.statusline
local _float = nil
---@type integer?  window the float is currently attached to
local _float_win = nil

-- ── Path → breadcrumb ─────────────────────────────────────────────────────────

---@param path string  Absolute file or directory path.
---@return string plain, string highlighted
local function build(path)
  if not path or path == "" then return "", "" end

  -- Relative base: the root cwd_mode holds, if any, else the project root of
  -- this very path. Under a lock the crumbs then count from the locked root —
  -- the same directory the tree is showing — instead of from whatever marker
  -- walk this individual file happens to sit under.
  local root = require("filetree.util.root").find(path)

  -- Compute parts relative to root
  local rel = path
  if root and path:sub(1, #root) == root then
    rel = path:sub(#root + 2) -- skip trailing slash
  end

  local parts = {}
  for part in (rel .. "/"):gmatch("([^/\\]+)[/\\]") do
    parts[#parts + 1] = part
  end
  -- The last element might be the filename (no trailing slash in original)
  if vim.fn.isdirectory(path) == 0 then
    -- last part is a file — already in parts from above (rel ends without /)
    -- Actually re-parse correctly:
    parts = {}
    for part in rel:gmatch("[^/\\]+") do
      parts[#parts + 1] = part
    end
  end

  -- Depth limit
  if #parts > _cfg.max_depth then
    local trimmed = { "…" }
    for i = #parts - (_cfg.max_depth - 1), #parts do
      trimmed[#trimmed + 1] = parts[i]
    end
    parts = trimmed
  end

  if #parts == 0 then return vim.fn.fnamemodify(root or path, ":t"), "" end

  local plain = table.concat(parts, _cfg.separator)

  -- Build highlighted string for winbar (%#HlGroup#text resets at end)
  local hl_parts = {}
  for i, p in ipairs(parts) do
    local is_last = (i == #parts)
    local hl = is_last and _cfg.hl_file or _cfg.hl_dir
    hl_parts[#hl_parts + 1] = "%#" .. hl .. "#" .. p
    if not is_last then hl_parts[#hl_parts + 1] = "%#" .. _cfg.hl_sep .. "#" .. _cfg.separator end
  end
  local highlighted = table.concat(hl_parts) .. "%#" .. _cfg.winbar_hl .. "#"

  return plain, highlighted
end

-- ── Display modes ─────────────────────────────────────────────────────────────

--- Write one window's winbar, through `ui.winbar`.
---
--- `vim.wo.winbar` is a surface with no notion of an owner, and this plugin
--- is not the only thing writing it: `my.nvim`'s breadcrumbs put a symbol
--- trail in the same place. ui.nvim introduced `ui.winbar.set()` to arbitrate
--- exactly that (its own doc comment has the full rationale, modelled on the
--- `vim.diagnostic.config()` ownership split), and my.nvim already
--- contributes through it. This plugin did not, so a `CursorMoved` in the
--- tree overwrote my.nvim's line in every editor window.
---
--- Bare, like every other ui.nvim touchpoint here: ui.nvim is a required
--- dependency (see docs/installation.md), and `ui.winbar` has been part of
--- it since before `ui.kit` was, which this plugin already bare-requires
--- everywhere else -- there is no ui.nvim install that has one without the
--- other, so there is nothing genuine left to degrade to here.
---@param win integer
---@param line string
---@return nil
local function set_winbar(win, line)
  require("ui.winbar").set(line, win)
end

local function update_winbar(highlighted, target_win)
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then return end
  -- Set winbar on all non-tree, non-floating windows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= target_win and vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "" then -- not floating
        local is_tree =
          require("filetree.util.buffer").is_tree_buffer(vim.api.nvim_win_get_buf(win))
        if not is_tree then set_winbar(win, " " .. highlighted) end
      end
    end
  end
end

local function close_float()
  if _float then
    pcall(_float.detach)
    _float = nil
  end
  _float_win = nil
end

---Anchored at the tree window's TOP row — a header, not a status bar — so
---this forces `mode = "float"` rather than "auto": "auto" would otherwise
---alternate between an always-last-row statusline and a top-anchored float
---depending on the user's `laststatus`, putting the crumbs in a different
---place depending on config they have no business caring about. Highlighting
---here was always a single `winbar_hl` for the whole line (unlike winbar
---mode's per-segment colouring), which is exactly what a badge's one `hl`
---already provides — nothing lost in the move.
local function update_float(plain)
  local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid() or nil
  if not tree_win or not vim.api.nvim_win_is_valid(tree_win) then
    close_float()
    return
  end

  if _float_win ~= tree_win then
    close_float()
    local segment, err = ui_statusline.attach(tree_win, {
      mode = "float",
      anchor = "top",
      align = "left",
      zindex = 10,
    })
    if not segment then
      notify.debug(err or "could not attach the breadcrumb float")
      return
    end
    _float = segment
    _float_win = tree_win
  end

  -- Nothing to write to when the window matched but no segment was ever
  -- attached (a failed attach above leaves `_float_win` unset and returns).
  if not _float then return end
  _float.set(" " .. plain, _cfg.winbar_hl)
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Recompute and display the breadcrumb for `path`.
---@param path string
function M.update(path)
  local plain, highlighted = build(path)
  _current = plain

  local mode = _cfg.mode
  if mode == "winbar" then
    local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid() or -1
    update_winbar(highlighted, tree_win)
  elseif mode == "float" then
    update_float(plain)
  end
  -- "statusline" mode: consumers call M.component()
end

---Return the current breadcrumb as a plain string (for statusline use).
---@return string
function M.component()
  return _current
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreeBreadcrumbsConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_breadcrumbs", true)

  -- Update when cursor moves in tree
  au.acmd("CursorMoved", {
    group = _augroup,
    pattern = "*",
    desc = "[filetree] Follow the tree node under the cursor with the breadcrumb",
    callback = function()
      if not require("filetree.util.buffer").is_tree_buffer() then return end
      if not _adapter then return end
      local node = _adapter.get_current_node()
      if node then M.update(node.path) end
    end,
  })

  -- Update when editor buffer changes
  bufevents.register("breadcrumbs", "BufEnter:editor", {
    desc = "[filetree] Sync the breadcrumb to the entered file",
    load = function(ctx)
      if vim.bo[ctx.buf].buftype ~= "" then return end
      local path = vim.api.nvim_buf_get_name(ctx.buf)
      if path and path ~= "" then M.update(path) end
    end,
  })

  -- Close float when tree is closed
  if _cfg.mode == "float" then
    au.acmd("WinClosed", {
      group = _augroup,
      callback = function(ev)
        if not _adapter then return end
        local tree_win = _adapter.get_winid and _adapter.get_winid() or -1
        if tonumber(ev.match) == tree_win then close_float() end
      end,
    })
  end
end

function M.teardown()
  bufevents.unregister("breadcrumbs")
  close_float()
  _current = ""
  _adapter = nil
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
