---@module 'filetree.features.ui.current_hl'
---@brief Highlight the current file and its parent directory in the tree.
---@description
--- On BufEnter/WinEnter events (debounced), the current file's line and its
--- parent directory's line are highlighted in the tree buffer using extmarks.
--- Highlight groups are resolved from the config spec which accepts hex colors,
--- linked groups ("link:GroupName"), or named colors ("red", "darkred", etc.).

local bufevents = require("filetree.util.bufevents")
local au = require("filetree.util.autocmd")
local lib_debounce = require("lib.nvim.debounce")
local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.current_hl` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  file_hl = "string|table",
  parent_hl = "string|table",
  debounce_ms = { "number", min = 0 },
  icon = "string",
  icon_hl = "string|table",
}

---@type integer?
local _augroup = nil

---@type FiletreeCurrentHlConfig
local _cfg = {}

---@type FiletreeAdapter?
local _adapter = nil

---Debounce handle built in M.setup() (needs `_cfg.debounce_ms`); `{ call, cancel }`.
---@type table?
local _debounce = nil

---@type string?  last highlighted file path
local _last_file = nil
---@type string?  last highlighted parent path
local _last_parent = nil

-- ── Highlight group resolution ────────────────────────────────────────────────

local function ensure_hl_group(name, spec)
  if type(spec) == "table" then
    vim.api.nvim_set_hl(0, name, spec)
    return name
  end
  if type(spec) ~= "string" then return nil end
  if spec:match("^#%x%x%x%x%x%x$") then
    vim.api.nvim_set_hl(0, name, { fg = spec, bold = true })
    return name
  end
  local linked = spec:match("^link:(.+)$")
  if linked then
    vim.api.nvim_set_hl(0, name, { link = linked })
    return name
  end
  -- named color fallback
  local ok = pcall(vim.api.nvim_set_hl, 0, name, { fg = spec, bold = true })
  if ok then return name end
  return nil
end

local FILE_HL = "FiletreeCurrentFile"
local PARENT_HL = "FiletreeCurrentParent"
local ICON_HL = "FiletreeCurrentIcon"

local function setup_hl_groups()
  ensure_hl_group(FILE_HL, _cfg.file_hl or { fg = "#7aa2f7", bold = true })
  ensure_hl_group(PARENT_HL, _cfg.parent_hl or { fg = "#565f89" })
  -- The icon gets its own group so it can be coloured independently of the
  -- line highlight; defaults to linking the file highlight.
  ensure_hl_group(ICON_HL, _cfg.icon_hl or ("link:" .. FILE_HL))
end

-- ── Highlight application ─────────────────────────────────────────────────────

---The own tree's decorators: the line of the current file and of its folder, and the icon.
---@type Filetree.Decorate.Paths|nil
local _decor_line = nil
---@type Filetree.Decorate.Paths|nil
local _decor_icon = nil

local function clear_old()
  if _last_file and _adapter then
    _adapter.unhighlight_node(_last_file)
    if _cfg.icon and type(_adapter.unsign_node) == "function" then
      _adapter.unsign_node(_last_file)
    end
  end
  if _last_parent and _adapter then _adapter.unhighlight_node(_last_parent) end
  _last_file = nil
  _last_parent = nil
end

local function apply()
  if not _adapter or not _adapter.is_open() then return end

  local path = vim.fn.expand("%:p")
  if path == "" or vim.fn.filereadable(path) == 0 then return end

  local parent = vim.fn.fnamemodify(path, ":h")

  if _decor_line then
    setup_hl_groups()
    _decor_line.set({ [path] = { hl = FILE_HL }, [parent] = { hl = PARENT_HL } })
    if _decor_icon then
      local has_icon = _cfg.icon and _cfg.icon ~= ""
      _decor_icon.set(has_icon and { [path] = { text = _cfg.icon, hl = ICON_HL } } or {})
    end
    return
  end

  clear_old()
  setup_hl_groups()

  _adapter.highlight_node(path, FILE_HL)
  _adapter.highlight_node(parent, PARENT_HL)

  -- Optional sign-column marker on the current file's line (distinguishes the
  -- focused buffer from the tree plugin's generic "opened files" colouring).
  if _cfg.icon and _cfg.icon ~= "" and type(_adapter.sign_node) == "function" then
    _adapter.sign_node(path, _cfg.icon, ICON_HL)
  end

  _last_file = path
  _last_parent = parent
end

local function debounced_apply()
  if _debounce then _debounce.call() end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---@param config FiletreeCurrentHlConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = config
  _adapter = adapter
  local decorate = require("filetree.util.decorate")
  if _decor_line then _decor_line.remove() end
  if _decor_icon then _decor_icon.remove() end
  _decor_line = decorate.by_path(adapter, { name = "current", slot = "line", priority = 20 })
  _decor_icon = decorate.by_path(adapter, { name = "current_icon", slot = "sign", priority = 90 })

  if _debounce then _debounce.cancel() end
  _debounce = lib_debounce.new(apply, _cfg.debounce_ms or 100)

  setup_hl_groups()

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_current_hl", true)

  bufevents.register("current_hl", { "BufEnter:*", "WinEnter:*", "BufWritePost:*" }, {
    desc = "[filetree] Highlight the current file's line in the tree",
    load = debounced_apply,
  })

  -- Re-apply after colorscheme changes
  au.acmd("ColorScheme", {
    group = _augroup,
    desc = "[filetree] Rebuild the current-file highlight groups after a colorscheme change",
    callback = function()
      setup_hl_groups()
      apply()
    end,
  })
end

function M.teardown()
  bufevents.unregister("current_hl")
  if _decor_line then _decor_line.remove() end
  if _decor_icon then _decor_icon.remove() end
  _decor_line, _decor_icon = nil, nil
  clear_old()
  if _debounce then
    if _debounce then _debounce.cancel() end
    _debounce = nil
  end
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
