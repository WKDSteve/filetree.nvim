---@module 'filetree.features.search.spotlight_node'
---@brief Spotlight the basename of the node under the cursor (soft dependency on spotlight.nvim).

local M = {}

---@type FiletreeSpotlightNodeConfig
local DEFAULTS = {
  enabled = false,
  keymap = "<leader>sp",
}

---@type FiletreeSpotlightNodeConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.spotlight_node` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
}

---@type FiletreeAdapter?
local _adapter = nil

local notify = require("filetree.util.notify").create("[filetree.spotlight_node]")
local bind = require("filetree.util.bind")

---Turn the basename of the current node into a spotlight token, so the open logs and
---buffers that mention the file light up. Adapter-agnostic: only `get_current_node`.
---@return boolean ok
function M.spotlight()
  if not _adapter then return false end
  local node = _adapter.get_current_node()
  if not node or not node.path then
    notify.warn("No current node")
    return false
  end
  local ok, spotlight = pcall(require, "spotlight")
  if not ok or type(spotlight.add) ~= "function" then
    notify.warn("spotlight.nvim is not installed")
    return false
  end
  local name = vim.fn.fnamemodify(node.path, ":t")
  if name == "" then
    notify.warn("Node has no name")
    return false
  end
  spotlight.add(name)
  return true
end

---@param cfg FiletreeSpotlightNodeConfig
---@param adapter FiletreeAdapter
function M.setup(cfg, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), cfg or {})
  _adapter = adapter

  bind.bind("spotlight_node", _cfg, {
    {
      name = "spotlight",
      field = "keymap",
      desc = "spotlight the node's name",
      rhs = function()
        M.spotlight()
      end,
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
