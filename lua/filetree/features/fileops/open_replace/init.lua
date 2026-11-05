---@module 'filetree.features.fileops.open_replace'
--- Open the node under the cursor into an existing editor window, in the two
--- shapes that differ in what becomes of the buffer already sitting there.
---
---   `O`                 Replace: `:edit` over the editor window. The previous
---                       buffer stays in the buffer list, it just is not on
---                       screen any more.
---   `<C-M-CR>`          Swap: the previous buffer is closed as well, and the
---                       new file takes over the slot it held in the bufferline.
---
--- Swap is the one to reach for when the buffer list is a working set rather
--- than a history: opening five files to find the one you wanted otherwise
--- leaves four behind to close by hand.
---
--- ### Keeping the slot
---
--- That part needs a buffer list that has slots to keep. Neovim's own order is
--- the buffer numbers, and those only ever increase -- a file opened now can
--- never sort ahead of one opened earlier, and no API moves it, because there
--- is nothing to move: the order is not stored anywhere, it is derived. Tabline
--- plugins in the NvChad lineage solve this with `vim.t.bufs`, a per-tabpage
--- list they order themselves, and that list *can* be rewritten -- so the new
--- buffer is put back at the index the replaced one held.
---
--- Without such a list the swap still swaps; the new file simply lands wherever
--- its buffer number puts it, which is last. Nothing errors and nothing is
--- configured for it -- the list is either there or it is not.
---
--- The rewrite happens twice on purpose, once inline and once on the next tick.
--- `:edit` and `nvim_buf_delete` both drive the tabline plugin's own autocmds,
--- and whether those have finished appending the new buffer by the time this
--- returns is the plugin's business, not something to depend on. Placing the
--- buffer is idempotent, so the second pass either corrects a late append or
--- changes nothing.
---
--- Config:
---   enabled          boolean
---   keymap           string?   Replace key (default "O").
---   keymap_swap      string?   Swap key (default "<C-M-CR>"; plain `<M-CR>` is
---                              Alt+Enter, taken by terminals for fullscreen).
---   keymap_swap_alt  string?   Second swap key (default false; `<C-CR>` is the keep-open key of
---                              `close_on_open`).
---   close_tree       boolean   Close the tree after `keymap` (default true).
---   swap_close_tree  boolean   Close the tree after a swap (default false).
---   keep_position    boolean   Give the new buffer the replaced one's slot
---                              (default true).

local notify = require("filetree.util.notify").create("[filetree.open_replace]")
local bufutil = require("filetree.util.buffer")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeOpenReplaceConfig
local DEFAULTS = {
  enabled = false,
  keymap = "O",
  -- Two keys for one action, because which of them the terminal actually
  -- delivers is not ours to decide. Many terminals send plain <CR> for
  -- Ctrl+Enter, in which case <C-CR> simply never fires and the tree's own <CR>
  -- runs as always -- binding it costs nothing and wins wherever the terminal
  -- (or GUI) does distinguish them. Ctrl+Alt+Enter is first: plain Alt+Enter is
  -- the keep-open key of `close_on_open`.
  keymap_swap = "<C-M-CR>",
  keymap_swap_alt = false,
  close_tree = true,
  swap_close_tree = false,
  keep_position = true,
}

---@type FiletreeOpenReplaceConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.open_replace` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  keymap_swap = "keymap",
  keymap_swap_alt = "keymap",
  close_tree = "boolean",
  swap_close_tree = "boolean",
  keep_position = "boolean",
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

---@internal
---Absolute path of the node under the cursor, when it is a file.
---@return string?
local function current_file_path()
  local adapter = _adapter
  if not adapter then return nil end
  local node = adapter.get_current_node and adapter.get_current_node()
  if not node or node.type == "directory" then return nil end
  local p = node.path
  if not p or p == "" then return nil end
  return p
end

---@internal
---The editor window to open into -- never the tree's own.
---@return integer?
local function editor_target()
  local adapter = _adapter
  local tree_win = adapter and adapter.get_winid and adapter.get_winid() or nil
  return bufutil.find_editor_win(tree_win or vim.api.nvim_get_current_win())
end

---@internal
---Is `bufnr` still on screen in some window other than `except_win`? A buffer
---displayed elsewhere is not ours to close -- deleting it would leave that
---other window holding a fresh [No Name].
---@param bufnr integer
---@param except_win integer
---@return boolean
local function visible_elsewhere(bufnr, except_win)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if
      win ~= except_win
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == bufnr
    then
      return true
    end
  end
  return false
end

---@internal
---The tabline plugin's per-tabpage buffer order, when one is being kept.
---@return integer[]?
local function tabline_order()
  local t = vim.t.bufs
  if type(t) ~= "table" then return nil end
  return t
end

---@internal
---Index of `bufnr` in the tabline order, or nil when there is no such list or
---the buffer is not in it.
---@param bufnr integer
---@return integer?
local function slot_of(bufnr)
  local order = tabline_order()
  if not order then return nil end
  for i, b in ipairs(order) do
    if b == bufnr then return i end
  end
  return nil
end

---@internal
---Move `bufnr` to index `slot` of the tabline order, dropping any entry it
---already has there. Idempotent: running it again with the same arguments over
---the result it produced is a no-op.
---@param bufnr integer
---@param slot integer
local function place_at_slot(bufnr, slot)
  local order = tabline_order()
  if not order then return end

  local rest = {}
  for _, b in ipairs(order) do
    if b ~= bufnr then rest[#rest + 1] = b end
  end
  -- The replaced buffer is usually gone by now, so every entry after it has
  -- moved up one -- clamp rather than trust the remembered index.
  local at = math.max(1, math.min(slot, #rest + 1))
  table.insert(rest, at, bufnr)
  vim.t.bufs = rest
end

---@internal
---Open `path` in `win` and return the buffer that ended up there. Deliberately
---`:edit` rather than bufadd + nvim_win_set_buf: `:edit` is what every other
---open in this plugin does, and it fires the full BufAdd/BufEnter/BufReadPost
---sequence that tabline plugins, LSP attach and 'buflisted' all hang off.
---@param win integer
---@param path string
---@return integer? bufnr
local function edit_in(win, path)
  vim.api.nvim_set_current_win(win)
  local ok = pcall(function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end)
  if not ok then
    notify.warn("Could not open: " .. path)
    return nil
  end
  return vim.api.nvim_get_current_buf()
end

---@internal
---Tell `close_on_open` (when it is on) that the tree stays open for this open.
---Called BEFORE the file is shown, because that is when `close_on_open` decides.
---@param keep boolean
local function hold_tree(keep)
  if not keep then return end
  local mod = require("filetree.features").require("close_on_open")
  if mod and type(mod.hold) == "function" then mod.hold() end
end

---@internal
---@param close boolean
local function maybe_close_tree(close)
  local adapter = _adapter
  if close and adapter and type(adapter.close) == "function" then pcall(adapter.close) end
end

-- ── Actions ───────────────────────────────────────────────────────────────────

---Open the file under the cursor, replacing what the editor window shows. The
---buffer that was there stays in the buffer list.
function M.open_replace()
  local path = current_file_path()
  if not path then return end

  hold_tree(_cfg.close_tree == false)

  -- No editor window yet: fall through and let the edit below create one.
  local win = editor_target()
  if win then vim.api.nvim_set_current_win(win) end

  local ok = pcall(function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end)
  if not ok then
    notify.warn("Could not open: " .. path)
    return
  end

  maybe_close_tree(_cfg.close_tree ~= false)
end

---Open the file under the cursor in place of the focused editor buffer: the
---previous buffer is closed, and the new one takes its slot in the bufferline.
function M.open_swap()
  local path = current_file_path()
  if not path then return end

  local win = editor_target()
  if not win then
    -- Nothing is being replaced, so there is nothing to swap -- just open.
    return M.open_replace()
  end

  local old = vim.api.nvim_win_get_buf(win)
  hold_tree(_cfg.swap_close_tree ~= true)

  -- Already the file in question: focus it and stop, rather than reload it and
  -- delete the buffer we just opened.
  if vim.api.nvim_buf_get_name(old) == vim.fn.fnamemodify(path, ":p") then
    vim.api.nvim_set_current_win(win)
    maybe_close_tree(_cfg.swap_close_tree == true)
    return
  end

  -- Closing would discard the edits, and Neovim refuses it anyway (E89). Say so
  -- and do nothing at all -- opening the file but leaving the old buffer behind
  -- would silently be `O`, which is its own key.
  if vim.bo[old].modified then
    notify.warn(
      "Not swapping: "
        .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(old), ":t")
        .. " has unsaved changes (write it first, or use the replace key to keep it)"
    )
    return
  end

  local slot = _cfg.keep_position ~= false and slot_of(old) or nil

  local newbuf = edit_in(win, path)
  if not newbuf then return end

  if
    newbuf ~= old
    and vim.api.nvim_buf_is_valid(old)
    and vim.bo[old].buftype == ""
    and not visible_elsewhere(old, win)
  then
    pcall(vim.api.nvim_buf_delete, old, {})
  end

  if slot then
    place_at_slot(newbuf, slot)
    -- Again next tick, in case the tabline plugin appends on a deferred hook.
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(newbuf) then place_at_slot(newbuf, slot) end
    end)
  end

  maybe_close_tree(_cfg.swap_close_tree == true)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeOpenReplaceConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end

  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  _adapter = adapter

  bind.bind("open_replace", _cfg, {
    {
      name = "open_replace",
      field = "keymap",
      rhs = M.open_replace,
      desc = "open file replacing current editor buffer",
    },
    {
      name = "open_swap",
      field = "keymap_swap",
      rhs = M.open_swap,
      desc = "open file, closing the focused buffer and taking its slot",
    },
    {
      name = "open_swap_alt",
      field = "keymap_swap_alt",
      rhs = M.open_swap,
      desc = "open file, closing the focused buffer and taking its slot",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
