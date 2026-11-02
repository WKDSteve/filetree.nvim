---@module 'filetree.features.system.open_with'
--- Open tree nodes with external applications.
---
--- Two modes:
---   system  — uses the OS default handler (xdg-open / open / start)
---   custom  — user-defined app list with optional keymaps
---
--- Config:
---   enabled  boolean
---   keymap   string?  Key for system default open (default "<leader>sm").
---   apps     FiletreeOpenWithApp[]  List of custom app entries.
---
--- Example config:
---   apps = {
---     { name = "VSCode",   cmd = "code",    keymap = "ov" },
---     { name = "Nautilus", cmd = "nautilus", keymap = "on" },
---   }
---
--- Commands (via :Filetree dispatcher):
---   :Filetree open system
---   :Filetree open pick       (floating picker of configured apps)

local notify = require("filetree.util.notify").create("[filetree.open_with]")
local ui_select = require("filetree.util.select")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeOpenWithConfig
local DEFAULTS = {
  enabled = false,
  keymap = "<leader>sm",
  apps = {},
}

---@type FiletreeOpenWithConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.open_with` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  apps = {
    "table",
    of = {
      "table",
      fields = {
        name = "string",
        cmd = "string",
        args = { "table", of = "string" },
        keymap = "keymap",
      },
    },
  },
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Open helpers ──────────────────────────────────────────────────────────────

---@internal
---Run a configured app on `path` (detached; a non-zero exit is reported).
---@param cmd_parts string[]
---@param path string
local function open_with_cmd(cmd_parts, path)
  local full_cmd = vim.deepcopy(cmd_parts)
  full_cmd[#full_cmd + 1] = path
  vim.system(full_cmd, { detach = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        notify.error("Open failed (exit " .. result.code .. "): " .. (result.stderr or ""))
      end)
    end
  end)
end

---@internal
---Open `path` with the OS default handler (`lib.nvim.cross.open_default`).
---@param path string
local function system_open(path)
  local ok, err = require("lib.nvim.cross.open_default")(path)
  if not ok then notify.error("Open failed: " .. tostring(err)) end
end

---@internal
---@return string?
local function current_path()
  if not _adapter then return nil end
  local node = _adapter.get_current_node()
  return node and node.path or nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Open the current node with the system default application.
function M.open_system()
  local path = current_path()
  if not path then
    notify.warn("No node under cursor")
    return
  end
  system_open(path)
  notify.info("Opening: " .. vim.fn.fnamemodify(path, ":t"))
end

---Open the current node with a specific app by name or command.
---@param app_name string
function M.open_app(app_name)
  local path = current_path()
  if not path then
    notify.warn("No node under cursor")
    return
  end

  for _, app in ipairs(_cfg.apps) do
    if app.name == app_name or app.cmd == app_name then
      local cmd = { app.cmd }
      for _, a in ipairs(app.args or {}) do
        cmd[#cmd + 1] = a
      end
      open_with_cmd(cmd, path)
      notify.info(string.format("Opening with %s: %s", app.name, vim.fn.fnamemodify(path, ":t")))
      return
    end
  end
  notify.warn("Unknown app: " .. app_name)
end

---Open a floating picker to choose an application.
function M.pick()
  local path = current_path()
  if not path then
    notify.warn("No node under cursor")
    return
  end

  local apps = vim.list_slice(_cfg.apps)
  table.insert(apps, 1, { name = "System default", cmd = "_system" })

  ui_select(apps, {
    prompt = "Open with",
    format_item = function(a)
      return a.name
    end,
  }, function(app)
    if not app then return end
    if app.cmd == "_system" then
      system_open(path)
    else
      local cmd = { app.cmd }
      for _, a in ipairs(app.args or {}) do
        cmd[#cmd + 1] = a
      end
      open_with_cmd(cmd, path)
    end
    notify.info(string.format("Opening with %s: %s", app.name, vim.fn.fnamemodify(path, ":t")))
  end)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeOpenWithConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  ---@type FiletreeBindSpec[]
  local specs = {
    {
      name = "open_system",
      field = "keymap",
      rhs = M.open_system,
      desc = "open with system default",
    },
  }

  -- One action per configured application, named after it. The keys live in
  -- the app entries rather than in a `keymap_*` field, so each gets a
  -- one-field view of its own app table to read its lhs out of.
  for _, app in ipairs(_cfg.apps) do
    local app_copy = app
    specs[#specs + 1] = {
      name = "open_" .. tostring(app.name):lower():gsub("[^%w]+", "_"),
      field = "keymap",
      cfg = app,
      desc = "open with " .. app.name,
      rhs = function()
        M.open_app(app_copy.name)
      end,
    }
  end

  bind.bind("open_with", _cfg, specs)
end

function M.teardown()
  _adapter = nil
end

return M
