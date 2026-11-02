---@module 'filetree.features.system.mdview_open'
--- Open the markdown file under the cursor in mdview.nvim's browser preview.
---
--- mdview.nvim is a SOFT dependency: absent, the key only warns. Like `pdf_open` this works
--- through filetree's own adapter, so it is tree-agnostic.
---
--- mdview's `open()` previews the *current buffer*, so the file is loaded into a buffer first
--- (without showing it in a window) and `open()` runs with that buffer made current for the call.
--- A buffer that was not loaded before is unlisted, so the preview does not leave an entry in
--- the buffer list. mdview needs a running session (`:MDView start`); without one it says so
--- itself, this module does not start a server.
---
--- Keymap (in tree buffer, opt-in via `enabled`):
---   gM   Open the markdown node under the cursor in the mdview browser preview.

local notify = require("filetree.util.notify").create("[filetree.mdview_open]")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeMdviewOpenConfig
local DEFAULTS = {
  enabled = false,
  keymap_open = "gM",
}

---@type FiletreeMdviewOpenConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.mdview_open` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap_open = "keymap",
}

---@type FiletreeAdapter?
local _adapter = nil

---@type table<string, true>
local MARKDOWN_EXTS = { md = true, markdown = true }

---True when `path` names a markdown file (by extension, case-insensitive).
---@param path string?
---@return boolean
function M.is_markdown(path)
  if type(path) ~= "string" then return false end
  local ext = path:match("%.([^./\\]+)$")
  return ext ~= nil and MARKDOWN_EXTS[ext:lower()] == true
end

---@internal
---Path of the markdown file under the cursor, or nil (skips folders / other files).
---@return string?
local function current_markdown()
  if not _adapter then return nil end
  local node = _adapter.get_current_node()
  local path = (node and node.type == "file") and node.path or nil
  if M.is_markdown(path) then return path end
  return nil
end

---Open the markdown file under the cursor in the mdview browser preview.
function M.open()
  local path = current_markdown()
  if not path then
    notify.warn("No markdown file under cursor")
    return
  end

  local ok, mdview = pcall(require, "mdview")
  if not (ok and type(mdview.open) == "function") then
    notify.warn("mdview.nvim is not installed")
    return
  end

  local was_known = vim.fn.bufexists(path) == 1 and vim.fn.bufloaded(path) == 1
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  if not was_known then vim.bo[bufnr].buflisted = false end

  vim.api.nvim_buf_call(bufnr, function()
    mdview.open()
  end)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeMdviewOpenConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("mdview_open", _cfg, {
    {
      name = "open",
      field = "keymap_open",
      rhs = M.open,
      desc = "open markdown in mdview preview",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
