---@module 'filetree.features.ui.window_style'
---@brief Cosmetic tweaks for tree windows: blank statusline + isolated highlights.
---@description
--- statusline is ON by default (set `statusline = false` to opt out);
--- highlights_isolate stays OFF by default (opt in explicitly):
---
---   statusline           Blank the statusline inside tree windows (a single
---                        space), so the sidebar has no cluttered status text.
---                        Re-applied on FileType, BufWinEnter, and WinEnter so
---                        a statusline plugin re-asserting itself on the same
---                        window doesn't win the race.
---   highlights_isolate   Link the tree's Normal / NormalNC / EndOfBuffer groups
---                        to the editor's own, so the sidebar shares the editor
---                        background instead of a plugin-specific one.
---
--- Note: could not be confirmed via headless Neovim testing in isolation
--- (no UIEnter without a real UI attached makes VeryLazy fire unpredictably
--- relative to a scripted test, so a host config's equivalent fallback
--- running in parallel confounded earlier headless checks either way).
--- Confirmed working - both effects - in real interactive use.
---
--- Adapter-agnostic: the tree filetypes and highlight-group names come from the
--- active adapter's optional `filetypes` / `hl_groups` capabilities, so this
--- works for any backend that declares them (neo-tree, nvim-tree ship them).
--- When an adapter omits them, a superset covering all known trees is used as a
--- harmless fallback.
---
--- Config:
---   enabled              boolean
---   statusline           boolean  Blank statusline in tree windows (default true).
---   highlights_isolate   boolean  Link tree HL groups to editor groups (default false).

local au = require("filetree.util.autocmd")
local tree_attach = require("filetree.util.tree_attach")
local M = {}

---@class FiletreeWindowStyleConfig
---@field enabled?            boolean
---@field statusline?         boolean
---@field highlights_isolate? boolean

---@type FiletreeWindowStyleConfig
local DEFAULTS = {
  enabled = false,
  statusline = true,
  highlights_isolate = false,
}

---@type FiletreeWindowStyleConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.window_style` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  statusline = "boolean",
  highlights_isolate = "boolean",
}

---@type integer?
local _augroup = nil
---@type FiletreeAdapter?
local _adapter = nil

-- Fallbacks used when the active adapter does not declare the capability.
local DEFAULT_FILETYPES = { "neo-tree", "NvimTree", "netrw", "oil", "minifiles", "filetree" }
local DEFAULT_HL_GROUPS = {
  NeoTreeNormal = "Normal",
  NeoTreeNormalNC = "NormalNC",
  NeoTreeEndOfBuffer = "EndOfBuffer",
  NvimTreeNormal = "Normal",
  NvimTreeNormalNC = "NormalNC",
  NvimTreeEndOfBuffer = "EndOfBuffer",
}

---Tree filetypes to target — the adapter's if declared, else the superset.
---@return string[]
local function tree_filetypes()
  local ft = _adapter and _adapter.filetypes
  if type(ft) == "table" and #ft > 0 then return ft end
  return DEFAULT_FILETYPES
end

---Blank the statusline in every tree window of the current tabpage.
local function apply_statusline()
  local want = {}
  for _, f in ipairs(tree_filetypes()) do
    want[f] = true
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) and want[vim.bo[buf].filetype] then
        vim.wo[win].statusline = " "
      end
    end
  end
end

---Link tree highlight groups to the editor's own so the sidebar blends in.
local function isolate_highlights()
  local groups = _adapter and _adapter.hl_groups
  if type(groups) ~= "table" or next(groups) == nil then groups = DEFAULT_HL_GROUPS end
  for group, target in pairs(groups) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = target })
  end
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeWindowStyleConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  _adapter = adapter
  if not _cfg.enabled then return end
  -- Nothing to do unless at least one effect is opted into.
  if not (_cfg.statusline or _cfg.highlights_isolate) then return end

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_window_style", true)

  if _cfg.statusline then
    tree_attach.on_attach(function()
      apply_statusline()
    end)
    -- Fallback re-application: some statusline plugins (re)assert their own
    -- value on BufWinEnter/WinEnter after FileType has already fired once for
    -- a given buffer, which would otherwise win the last-write race.
    au.acmd({ "BufWinEnter", "WinEnter" }, {
      group = _augroup,
      desc = "[filetree] Re-assert the tree's statusline after another plugin overwrote it",
      callback = function()
        vim.schedule(apply_statusline)
      end,
    })
  end

  if _cfg.highlights_isolate then
    au.acmd("ColorScheme", {
      group = _augroup,
      desc = "[filetree] Re-isolate the tree window's highlights after a colorscheme change",
      callback = function()
        vim.schedule(isolate_highlights)
      end,
    })
    vim.schedule(isolate_highlights)
  end
end

function M.teardown()
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
