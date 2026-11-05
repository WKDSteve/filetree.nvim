---@module 'filetree.features.nav.tree_toggle'
---@brief Toggle the tree at a chosen position from anywhere: four global keys.
---@description
--- `<M-l>` opens (or closes) the tree on the left, `<M-r>` on the right,
--- `<M-f>` as a float, `<M-c>` in the current window -- and reveals the
--- current file on the way in, re-rooting to the cwd if it lives outside
--- the tree. This is the `:Neotree toggle position=… reveal reveal_force_cwd`
--- most configs end up writing four times, through the adapter instead, so
--- it works on every backend that can place its tree (`adapter.toggle_at`).
---
--- Opt-in: four global Alt keys are a claim on the keyboard this plugin
--- does not make unasked. Enable it and remap what collides.
---
--- Config:
---   enabled           boolean   (default false)
---   reveal            boolean   Reveal the current file when opening (default true).
---   reveal_force_cwd  boolean   Re-root to the cwd when the file is outside the tree (default true).
---   keymap_current    string?   Global key (default "<M-c>").
---   keymap_float      string?   Global key (default "<M-f>").
---   keymap_left       string?   Global key (default "<M-l>").
---   keymap_right      string?   Global key (default "<M-r>").
---   collapse_on_toggle boolean  Opening the tree first collapses every folder
---                               except the chain to the current file
---                               (default false; see `collapse_for_open`).
---   use_root_providers boolean  Opening the tree roots it at the folder a root
---                               provider (`filetree.roots`) names for the current
---                               file -- a case folder of casedesk.nvim, say --
---                               instead of the cwd (default true; no provider or
---                               no answer: nothing changes). A pinned root
---                               (cwd_mode `lock`/`manual`) wins over the provider.

local notify = require("filetree.util.notify").create("[filetree.tree_toggle]")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeTreeToggleConfig
local DEFAULTS = {
  enabled = false,
  reveal = true,
  reveal_force_cwd = true,
  keymap_current = "<M-c>",
  keymap_float = "<M-f>",
  keymap_left = "<M-l>",
  keymap_right = "<M-r>",
  collapse_on_toggle = false,
  use_root_providers = true,
}

---Option schema (see `filetree.config.schema`): exactly what
---`features.tree_toggle` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  reveal = "boolean",
  reveal_force_cwd = "boolean",
  keymap_current = "keymap",
  keymap_float = "keymap",
  keymap_left = "keymap",
  keymap_right = "keymap",
  collapse_on_toggle = "boolean",
  use_root_providers = "boolean",
}

---@type FiletreeTreeToggleConfig
local _cfg = vim.deepcopy(DEFAULTS)
---@type FiletreeAdapter|nil
local _adapter = nil

---@type FiletreeTreePosition[]
M.POSITIONS = { "left", "right", "float", "current" }

---Toggle the tree at `position`.
---@param position FiletreeTreePosition
---@return boolean ok
---@return string|nil err
function M.toggle(position)
  if not vim.tbl_contains(M.POSITIONS, position) then
    return false, ("unknown position %q (left, right, float, current)"):format(tostring(position))
  end
  local adapter = _adapter
  if not adapter then return false, "tree_toggle is not set up" end
  if type(adapter.toggle_at) ~= "function" then
    return false, ("the %s adapter cannot place its tree"):format(adapter.name)
  end
  local file = vim.api.nvim_buf_get_name(0)
  if _cfg.collapse_on_toggle == true then M.collapse_for_open(adapter, file) end
  local reveal = _cfg.reveal == true and file ~= ""
  local ok = adapter.toggle_at(position, {
    reveal = reveal,
    file = reveal and file or nil,
    reveal_force_cwd = reveal and _cfg.reveal_force_cwd == true,
    dir = M.provided_root(adapter, file),
  })
  if not ok then return false, "toggle failed" end
  return true, nil
end

---The root a registered provider (`filetree.roots`) names for `file`, when this
---toggle is about to OPEN the tree: inside a case folder the tree then shows
---that case and not every sibling case. nil closes nothing and changes nothing:
---the option off, no file, an open tree (the toggle closes it), no provider, or
---no answer for this file.
---
---A pinned root wins over a provider: with `cwd_mode` on `lock` or `manual` the
---tree opens at the pinned directory (`:Filetree cwd follow` hands the decision
---back to the provider).
---@param adapter FiletreeAdapter
---@param file string  The current buffer's name ("" for none).
---@return string|nil
function M.provided_root(adapter, file)
  if _cfg.use_root_providers ~= true or file == "" then return nil end
  if type(adapter.is_open) == "function" and adapter.is_open() == true then return nil end
  local roots = require("filetree.roots")
  if not roots.any() then return nil end
  local mode = require("filetree.features").require("cwd_mode")
  if mode and type(mode.mode) == "function" then
    local m = mode.mode()
    if m == "lock" or m == "manual" then
      local pinned = type(mode.pinned) == "function" and mode.pinned() or nil
      if pinned and pinned ~= "" then return pinned end
    end
  end
  return roots.resolve(file)
end

---The `collapse_on_toggle` step, run before every toggle: when the toggle is
---about to OPEN the tree, collapse its remembered state down to the folder
---chain of `file` (all of it when `file` is not a real file, e.g. a scratch,
---help or terminal buffer; a file outside the root keeps nothing either).
---
---On open, not on close: the tree can also be closed by other means (`:q` in
---its window, a layout change, another plugin) that never pass this key, and
---the state a close leaves behind survives until the next show. Collapsing on
---the way in catches every one of them; the reveal that follows re-opens
---nothing but the current file's chain. A toggle that closes the tree leaves
---its state alone. Without `collapse_all` (netrw, oil, mini.files) a no-op.
---
---A buffer counts as a file when it is a normal buffer (`buftype` empty) whose
---folder exists -- also a new file not written yet (`:e src/new.lua`), whose
---chain is as real as a saved one's. A scratch, help, terminal or plugin
---buffer keeps nothing.
---@param adapter FiletreeAdapter
---@param file string  The current buffer's name ("" for none).
---@param buftype? string  The current buffer's 'buftype' (default: read from it).
---@return boolean collapsed
function M.collapse_for_open(adapter, file, buftype)
  if type(adapter.collapse_all) ~= "function" then return false end
  local open = type(adapter.is_open) == "function" and adapter.is_open() == true
  if open then return false end
  if buftype == nil then buftype = vim.bo.buftype end
  local keep = nil
  if
    file ~= ""
    and buftype == ""
    and vim.fn.isdirectory(vim.fn.fnamemodify(file, ":h")) == 1
    and vim.fn.isdirectory(file) == 0
  then
    keep = file
  end
  local ok = adapter.collapse_all(keep)
  return ok == true
end

---@internal
---@param position FiletreeTreePosition
---@return fun()
local function toggler(position)
  return function()
    local ok, err = M.toggle(position)
    if not ok then notify.warn(err or "toggle failed") end
  end
end

---@param config FiletreeTreeToggleConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  if not _cfg.enabled then return end
  _adapter = adapter
  if type(adapter.toggle_at) ~= "function" then
    notify.warn(
      ("adapter %q cannot place its tree; tree_toggle binds nothing"):format(adapter.name)
    )
    return
  end

  bind.bind("tree_toggle/global", _cfg, {
    {
      name = "current",
      field = "keymap_current",
      rhs = toggler("current"),
      desc = "toggle tree in this window",
    },
    {
      name = "float",
      field = "keymap_float",
      rhs = toggler("float"),
      desc = "toggle tree as a float",
    },
    {
      name = "left",
      field = "keymap_left",
      rhs = toggler("left"),
      desc = "toggle tree on the left",
    },
    {
      name = "right",
      field = "keymap_right",
      rhs = toggler("right"),
      desc = "toggle tree on the right",
    },
  }, "global")
end

function M.teardown()
  for _, field in ipairs({ "keymap_current", "keymap_float", "keymap_left", "keymap_right" }) do
    local lhs = _cfg[field]
    if type(lhs) == "string" and lhs ~= "" then pcall(vim.keymap.del, "n", lhs) end
  end
  _adapter = nil
end

return M
