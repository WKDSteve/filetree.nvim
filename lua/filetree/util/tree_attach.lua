---@module 'filetree.util.tree_attach'
--- Central "on tree buffer" dispatcher for per-buffer setup (keymaps).
---
--- Instead of every feature registering its own `FileType` autocmd to bind
--- tree-buffer keymaps, features register a callback here and a single FileType
--- autocmd runs them all (scheduled, past the adapter's own keymap setup, with a
--- buffer-validity guard done once, centrally).
---
--- Lifecycle (driven by filetree.setup):
---   1. reset()            — clear callbacks (start of setup)
---   2. on_attach(fn)      — each enabled feature registers in its setup()
---   3. install(adapter)   — create the single FileType autocmd (end of setup)
---
--- `fn` receives the tree buffer number: `fn(buf)`.

local au = require("filetree.util.autocmd")
local sources = require("filetree.sources")

local M = {}

---@class FiletreeTreeAttachCallback
---@field fn fun(buf: integer)
---@field feature string|nil  # Consulted against `filetree.sources`; nil = every source.

---@type FiletreeTreeAttachCallback[]
local _callbacks = {}
---@type integer?
local _augroup = nil

---Clear all registered callbacks. Called at the start of setup so a re-setup
---does not accumulate stale bindings.
function M.reset()
  _callbacks = {}
end

---Register a callback to run once for each tree buffer when it attaches.
---
---`feature` opts the callback into the source check: neo-tree draws its
---filesystem, buffer list, git status, symbol outline and diagnostics list
---through one `neo-tree` filetype, so "on a tree buffer" is five different
---trees. A feature named in `filetree.sources` runs only on the ones it lists;
---anything else runs everywhere, as all of them did before.
---@param fn fun(buf: integer)
---@param feature string|nil
function M.on_attach(fn, feature)
  if type(fn) == "function" then _callbacks[#_callbacks + 1] = { fn = fn, feature = feature } end
end

---Install the single FileType autocmd that dispatches to all callbacks.
---Idempotent: clears and recreates its augroup. Call after all features'
---setup() have registered.
---@param adapter FiletreeAdapter
function M.install(adapter)
  au.del_group(_augroup)
  _augroup = au.group("filetree_tree_attach", true)

  local pattern = (adapter and type(adapter.filetypes) == "table" and #adapter.filetypes > 0)
      and adapter.filetypes
    or { "neo-tree", "NvimTree" }

  au.acmd("FileType", {
    group = _augroup,
    pattern = pattern,
    desc = "[filetree] Run every feature's tree-buffer setup when a tree buffer attaches",
    callback = function(ev)
      local buf = ev.buf
      -- Defer past the adapter's own buffer-local keymap setup, then run every
      -- registered feature callback once for this buffer.
      --
      -- The deferral also makes the source readable: neo-tree sets
      -- `b:neo_tree_source` in its renderer, which is after FileType -- nil in
      -- this callback, "filesystem" by the next tick (measured 2026-09-02).
      -- So the tick this has needed all along is exactly the one that makes a
      -- per-source decision possible here.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local source = sources.of_buffer(buf)
        for _, cb in ipairs(_callbacks) do
          if cb.feature == nil or sources.allows(cb.feature, source) then pcall(cb.fn, buf) end
        end
        -- every feature has bound its keys: the own tree reads them into its action table
        vim.api.nvim_exec_autocmds("User", {
          pattern = "FiletreeAttached",
          modeline = false,
          data = { buf = buf },
        })
      end)
    end,
  })
end

---Tear down the dispatcher (full teardown; re-setup uses reset()+install()).
function M.teardown()
  au.del_group(_augroup)
  _augroup = nil
  _callbacks = {}
end

return M
