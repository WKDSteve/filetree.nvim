---@module 'filetree.features.infra.file_watcher'
---@brief Watch the tree root for filesystem changes and auto-refresh.
---@description
--- Uses vim.uv.fs_event (libuv) to watch the tree root directory.
--- On Windows this maps to ReadDirectoryChangesW (recursive by default).
--- On POSIX it uses inotify/kqueue with non-recursive polling fallback.
---
--- Debounces rapid bursts of events before calling adapter.refresh().
--- Re-arms the watcher when the tree root changes (via set_root adapter call).
---
--- Config:
---   enabled         boolean
---   debounce_ms     integer    Event debounce delay (default 500ms).
---   watch_recursive boolean    Watch subdirectories too (default true).
---   ignore_events   string[]   uv event types to skip (default {}).
---
--- Commands (via :Filetree dispatcher):
---   :Filetree watcher enter [ms]
---   :Filetree watcher exit

local notify = require("filetree.util.notify").create("[filetree.file_watcher]")

local au = require("filetree.util.autocmd")
local tree_attach = require("filetree.util.tree_attach")
local lib_debounce = require("lib.nvim.debounce")
local M = {}

---@type FiletreeFileWatcherConfig
local DEFAULTS = {
  enabled = false,
  debounce_ms = 500,
  watch_recursive = true,
  ignore_events = {},
}

---@type FiletreeFileWatcherConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.file_watcher` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  debounce_ms = { "number", min = 0 },
  watch_recursive = "boolean",
  ignore_events = { "table", of = "string" },
}

---@type FiletreeAdapter?
local _adapter = nil

local _handle = nil -- uv fs_event handle
---@type Lib.Debounce.Handle|nil # built in M.setup()
local _debounce = nil
local _watched = nil -- current watched path

-- ── uv helpers ────────────────────────────────────────────────────────────────

local function uv()
  return vim.uv or vim.loop
end

local function stop_handle()
  if _handle then
    pcall(function()
      _handle:stop()
    end)
    pcall(function()
      _handle:close()
    end)
    _handle = nil
  end
end

local function stop_timer()
  if _debounce then _debounce.cancel() end
end

local function do_refresh()
  if _adapter and _adapter.refresh then pcall(_adapter.refresh) end
end

local function trigger_refresh()
  if not _debounce then return end
  if _debounce then _debounce.call() end
end

-- ── Watch ─────────────────────────────────────────────────────────────────────

local function watch(path)
  stop_handle()
  if not path or vim.fn.isdirectory(path) == 0 then return end
  _watched = path

  _handle = uv().new_fs_event()
  if not _handle then
    notify.warn("fs_event not available on this platform")
    return
  end

  local flags = { recursive = _cfg.watch_recursive }
  local ok, err = pcall(function()
    _handle:start(path, flags, function(err2, fname, events)
      if err2 then return end
      -- Skip ignored event types
      for _, ignored in ipairs(_cfg.ignore_events) do
        if events and events[ignored] then return end
      end
      trigger_refresh()
    end)
  end)

  if not ok then
    notify.warn("Could not watch " .. path .. ": " .. tostring(err))
    stop_handle()
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Start watching a specific path (replaces current watcher).
---@param path? string  Defaults to current tree root or cwd.
function M.enter(path)
  if not path then
    if _adapter and _adapter.get_current_node then
      local node = _adapter.get_current_node()
      if node then
        path = vim.fn.isdirectory(node.path or "") == 1 and node.path
          or vim.fn.fnamemodify(node.path or "", ":h")
      end
    end
    path = path or vim.fn.getcwd()
  end
  watch(path)
  notify.info("Watching: " .. path)
end

---Stop the current watcher.
function M.exit()
  stop_handle()
  stop_timer()
  _watched = nil
  notify.info("File watcher stopped")
end

---@return string?
function M.watched_path()
  return _watched
end

---@return boolean
function M.is_active()
  return _handle ~= nil
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreeFileWatcherConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  -- The own tree follows the disk itself and reads only the folders that changed; this feature's
  -- answer to any event is a refresh of the whole tree, which would undo exactly that.
  if adapter.name == "native" and require("filetree.native").options().watch ~= false then
    return
  end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  if _debounce then _debounce.cancel() end
  _debounce = lib_debounce.new(do_refresh, _cfg.debounce_ms)

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_file_watcher", true)

  -- Start watching when the tree opens, re-watch when DirChanged
  tree_attach.on_attach(function()
    local root = vim.fn.getcwd()
    if not _handle then watch(root) end
  end)

  au.acmd("DirChanged", {
    group = _augroup,
    desc = "[filetree] Re-point the filesystem watcher at the new working directory",
    callback = function()
      watch(vim.fn.getcwd())
    end,
  })
end

function M.teardown()
  stop_handle()
  stop_timer()
  _adapter = nil
  _watched = nil
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
