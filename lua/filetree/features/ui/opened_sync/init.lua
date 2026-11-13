---@module 'filetree.features.ui.opened_sync'
---@brief Keep the tree's "opened files" decoration in sync with real buffer state.
---@description
--- Tree plugins that colour the nodes of currently-open files (neo-tree's
--- `name.highlight_opened_files`, for instance) only re-evaluate that decoration
--- when they re-render — which does NOT reliably happen when you merely open or
--- close a buffer elsewhere. The result: a file you just closed still shows as
--- "open" in the tree until you manually close and reopen the tree.
---
--- This feature fixes that by asking the adapter for a cheap re-render
--- (`adapter.redraw()` — re-render from existing state, NO filesystem
--- rescan) shortly after a buffer is added, deleted, wiped, or (un)displayed.
--- Debounced (`debounce_ms`, default 60) so a burst of buffer events (e.g.
--- `:bufdo`, session restore) collapses into a single redraw, and a no-op
--- when the tree isn't open or the adapter can't redraw cheaply.
---
--- Deliberately calls `redraw()`, not `adapter.redraw_soon()`: this
--- feature's OWN debounce already reduces a burst to exactly one call, so a
--- second debounce layer on top would have nothing left to coalesce with —
--- pure added latency (`debounce_ms` + `redraw_soon`'s own window, ~90ms
--- instead of ~60ms by default) for zero benefit. `redraw_soon` exists for a
--- caller whose own trigger is NOT already debounced against anything else
--- (see `adapter/neotree.lua`'s doc comment on it).

local au = require("filetree.util.autocmd")
local lib_debounce = require("lib.nvim.debounce")
local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.opened_sync` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  debounce_ms = { "number", min = 0 },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer?
local _augroup = nil

---Debounce handle built in M.setup() (needs `_cfg.debounce_ms`); `{ call, cancel }`.
---@type table?
local _debounce = nil

---@type FiletreeOpenedSyncConfig
local _cfg = {}

---The own tree's decorators: the name of a file that is open in a buffer, and a mark on an unsaved one.
---A foreign tree draws these itself and only needs the redraw below.
---@type Filetree.Decorate.Paths|nil
local _decor_opened = nil
---@type Filetree.Decorate.Paths|nil
local _decor_modified = nil

local function redraw_now()
  if not _adapter then return end
  if _decor_opened and _decor_modified then
    local opened, modified = {}, {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buflisted
        and vim.bo[buf].buftype == ""
      then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" then
          opened[name] = { hl = "FiletreeOpened" }
          if vim.bo[buf].modified then
            modified[name] = { text = "[+]", hl = "FiletreeModified" }
          end
        end
      end
    end
    _decor_opened.set(opened)
    _decor_modified.set(modified)
    return
  end
  if not _adapter.is_open() then return end
  -- Not redraw_soon(): this module's own `_debounce` already collapses a
  -- burst of Buf* events into exactly one call here, so a second debounce
  -- layer around it would only ever add latency, never coalesce anything --
  -- see the module doc comment above.
  if type(_adapter.redraw) == "function" then pcall(_adapter.redraw) end
end

local function debounced_redraw()
  if _debounce then _debounce.call() end
end

---@param config FiletreeOpenedSyncConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  -- Nothing to sync if the adapter can't cheaply re-render.
  if type(adapter.redraw) ~= "function" then return end
  _cfg = config
  _adapter = adapter

  local decorate = require("filetree.util.decorate")
  if _decor_opened then _decor_opened.remove() end
  if _decor_modified then _decor_modified.remove() end
  _decor_opened = decorate.by_path(adapter, { name = "opened", slot = "name", priority = 30 })
  _decor_modified = decorate.by_path(adapter, { name = "modified", slot = "badge", priority = 75 })

  if _debounce then _debounce.cancel() end
  _debounce = lib_debounce.new(redraw_now, _cfg.debounce_ms or 60)

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_opened_sync", true)

  -- Buffer open/close/show/hide — the events that change which files count as
  -- "open". Deliberately NOT BufEnter (fires on every cursor-into-buffer and is
  -- far too chatty for a redraw); the set below already covers add/remove and
  -- window (un)display of a buffer.
  local events = { "BufAdd", "BufDelete", "BufWipeout", "BufWinEnter", "BufWinLeave" }
  -- the unsaved mark is this feature's on the own tree, so it has to hear of it there
  if _decor_modified then vim.list_extend(events, { "BufModifiedSet", "BufWritePost" }) end
  au.acmd(events, {
    group = _augroup,
    desc = "[filetree] Re-draw the tree's open-file markers when the buffer list changes",
    callback = debounced_redraw,
  })
  if _decor_opened then debounced_redraw() end
end

function M.teardown()
  if _decor_opened then _decor_opened.remove() end
  if _decor_modified then _decor_modified.remove() end
  _decor_opened, _decor_modified = nil, nil
  if _debounce then
    if _debounce then _debounce.cancel() end
    _debounce = nil
  end
  _adapter = nil
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
