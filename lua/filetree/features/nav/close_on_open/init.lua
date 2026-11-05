---@module 'filetree.features.nav.close_on_open'
---@brief Close the tree after a file was opened from it; `<M-CR>` opens and keeps it open.
---@description
--- Opening a file from the tree (`<CR>`, double-click, `O`, the `open_variants`
--- keys) leaves the tree on screen on every backend, so it has to be closed by
--- hand after each open. With this feature the tree closes itself once the file
--- is shown; `<M-CR>` (Alt+Enter) opens the node exactly like `<CR>` and leaves
--- the tree open, for browsing several files in a row. Focus is in the editor
--- window in both cases (as with a plain `<CR>`).
---
--- ### How an open from the tree is recognised
---
--- Backend-neutral, so it needs no hook into neo-tree / nvim-tree: the tree
--- window loses focus (`WinLeave`) and, within a split second, a normal file
--- buffer is shown in a non-floating window (`BufWinEnter`). A folder toggle
--- never shows a buffer, a preview lives in a float, and a `<C-w>l` into the
--- editor followed later by `:edit` is outside the time window -- none of them
--- closes the tree. Backends that never leave the tree window to open (oil,
--- netrw, mini.files replace their own window) do not trigger it: no-op there.
---
--- ### The keep-open key
---
--- `<M-CR>` sets a one-shot "keep" mark and feeds the tree's own `<CR>`, so the
--- backend does the opening; the mark makes the next open leave the tree alone.
--- It expires on its own (a folder never shows a buffer), so a `<M-CR>` on a
--- folder does not keep the following `<CR>` from closing. `open_replace` sets
--- the same mark for its keys when its own `close_tree` / `swap_close_tree`
--- says the tree stays (`M.hold`).
---
--- Config:
---   enabled      boolean  (default false)
---   keymap_keep  string?  Tree-buffer key: open and keep the tree open
---                         (default "<M-CR>"; false/"" turns the key off).

local au = require("filetree.util.autocmd")
local bind = require("filetree.util.bind")
local ftbuf = require("filetree.util.buffer")

local M = {}

---@type { enabled: boolean, keymap_keep: string|string[]|false }
local DEFAULTS = {
  enabled = false,
  keymap_keep = "<M-CR>",
}

---Option schema (see `filetree.config.schema`): exactly what
---`features.close_on_open` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap_keep = "keymap",
}

---How long after the tree lost focus a file shown in another window still
---counts as "opened from the tree".
local OPEN_WINDOW_MS = 400
---How long a keep mark lives when no open consumes it.
local HOLD_MS = 400

---@type { enabled: boolean, keymap_keep: string|string[]|false }
local _cfg = vim.deepcopy(DEFAULTS)
---@type FiletreeAdapter|nil
local _adapter = nil
---@type integer|nil
local _augroup = nil
---The tree window that lost focus last: { win, at }.
---@type { win: integer, at: integer }|nil
local _left = nil
---Bumped by every hold; a timer only clears the mark it set.
local _hold_gen = 0
local _holding = false

---@return integer
local function now_ms()
  return (vim.uv or vim.loop).now()
end

---Keep the tree open for the next open from it (one-shot, expires on its own).
function M.hold()
  _holding = true
  _hold_gen = _hold_gen + 1
  local gen = _hold_gen
  vim.defer_fn(function()
    if _hold_gen == gen then _holding = false end
  end, HOLD_MS)
end

---Close the tree and keep the focus where the open put it.
---@param editor_win integer
local function close_tree(editor_win)
  local adapter = _adapter
  if not adapter or type(adapter.close) ~= "function" then return end
  if type(adapter.is_open) == "function" and not adapter.is_open() then return end
  pcall(adapter.close)
  if vim.api.nvim_win_is_valid(editor_win) then pcall(vim.api.nvim_set_current_win, editor_win) end
end

---@param ev table  BufWinEnter autocmd args
local function on_buf_win_enter(ev)
  local left = _left
  if not left or now_ms() - left.at > OPEN_WINDOW_MS then return end
  -- The window we left must still be a tree: a mark left behind by a tree that
  -- has since been closed must not close the next one.
  if
    not vim.api.nvim_win_is_valid(left.win)
    or not ftbuf.is_tree_buffer(vim.api.nvim_win_get_buf(left.win))
  then
    _left = nil
    return
  end
  local win = vim.api.nvim_get_current_win()
  if win == left.win then return end
  if not vim.api.nvim_buf_is_valid(ev.buf) or ftbuf.is_tree_buffer(ev.buf) then return end
  if vim.bo[ev.buf].buftype ~= "" then return end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return end
  _left = nil
  if _holding then
    _holding = false
    return
  end
  -- After the open has finished: closing inside the autocmd would run the
  -- backend's close while it is still rendering the window it just left.
  vim.schedule(function()
    close_tree(win)
  end)
end

---`<M-CR>`: let the tree's own `<CR>` open the node, keeping the tree open.
local function keep_open()
  M.hold()
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "m", false)
end

---@param config { enabled?: boolean, keymap_keep?: string|string[]|false }
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  M.teardown()
  if not (config and config.enabled) then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  _augroup = au.group("filetree_close_on_open", true)
  au.acmd("WinLeave", {
    group = _augroup,
    desc = "[filetree] Remember that the tree window was just left",
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if ftbuf.is_tree_buffer(buf) then
        _left = { win = vim.api.nvim_get_current_win(), at = now_ms() }
      end
    end,
  })
  au.acmd("BufWinEnter", {
    group = _augroup,
    desc = "[filetree] Close the tree after a file was opened from it",
    callback = on_buf_win_enter,
  })

  bind.bind("close_on_open", _cfg, {
    {
      name = "keep_open",
      field = "keymap_keep",
      rhs = keep_open,
      desc = "open and keep the tree open",
    },
  })
end

function M.teardown()
  _cfg = vim.deepcopy(DEFAULTS)
  if _augroup then pcall(vim.api.nvim_del_augroup_by_id, _augroup) end
  _augroup = nil
  _adapter = nil
  _left = nil
  _holding = false
  _hold_gen = _hold_gen + 1
end

return M
