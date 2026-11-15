---@module 'filetree.native.action.features'
---@brief What a feature key of the own tree is: which feature, which of its actions, and whether it changes files.
---@description
--- A feature binds its keys on the tree buffer itself; the action table reads them back from the
--- buffer (`filetree.native.action`, `sync`) and would know them by their key only. Here is what the
--- table writes on each such entry, so that every reader of the table (the cheatsheet, the menu, the
--- catalog a model picks from) finds it in one place:
---
--- - `keys(buf)`: feature and action of every filetree key on a tree buffer, from the keymap registry
--- - `read_only(feature, action)`: does this action change no file
--- - `READ_ONLY`: the features and actions that only read
---
--- A feature can say it itself: a key registered with `mutates = false` (or `true`) is taken at its
--- word, before the list is asked. A key nobody can name counts as changing.

local M = {}

--- Feature actions that change no file (the rest of a feature not named here counts as changing):
--- `true` for every action of the feature, or a set of its action names. An action that starts
--- another program (a PDF in the system viewer, a browser) is not on it: who runs it for somebody
--- else asks first.
---@type table<string, true|table<string, true>>
M.READ_ONLY = {
  open_variants = true,
  cwd_mode = true,
  tree_traverse = true,
  reveal_alt = true,
  collapse_all = true,
  sort_cycle = true,
  source_switcher = true,
  window_size_cycler = true,
  buffer_cycle = true,
  marks = true,
  node_info = true,
  -- `open` (its <CR>) hands some files to the program of the system
  preview = { toggle = true },
  filter = true,
  live_search = true,
  find_files = true,
  grep_in_dir = true,
  spotlight_node = true,
  breadcrumbs = true,
  cheatsheet = true,
  path_copy = true,
  lua_require_copy = true,
  -- `link_insert` writes into the editor buffer
  markdown_links = { link = true, link_recursive = true, link_from_marked = true },
  -- `save` writes a file
  copy_file_list = { files_abs = true, files_rel = true, dirs_abs = true, dirs_rel = true },
  -- `system` and `terminal` start another program, as mdview_open starts a browser: those ask
  pdf_open = { text = true, picker = true },
}

---Whether a feature action changes no file, by the list.
---@param feature string
---@param action string
---@return boolean
function M.read_only(feature, action)
  local entry = M.READ_ONLY[feature]
  if entry == true then return true end
  return type(entry) == "table" and entry[action] == true
end

---@class Filetree.Action.FeatureKey
---@field feature string  The feature the key belongs to (`open_variants`).
---@field action string  The name the feature gave the key (`vsplit`).
---@field mutates boolean  It changes files, or starts another program: asked for before it runs on somebody's behalf.

---Feature and action of every filetree key on a tree buffer, by the canonical form of the key.
---@param buf integer|nil
---@return table<string, Filetree.Action.FeatureKey>
function M.keys(buf)
  local out = {}
  local ok, keymap = pcall(require, "lib.nvim.bindings.keymap")
  if not ok or type(keymap.registered) ~= "function" then return out end
  local canon = require("filetree.util.key_conflicts").canon
  local all = keymap.registered()
  local surfaces = {}
  for surface in pairs(all) do
    if surface:match("^filetree/") then surfaces[#surfaces + 1] = surface end
  end
  -- one order, so a key two features claim is named the same way every time
  table.sort(surfaces)
  for _, surface in ipairs(surfaces) do
    local feature = surface:match("^filetree/([^/]+)")
    for _, e in ipairs(all[surface] or {}) do
      local modes = type(e.mode) == "table" and e.mode or { e.mode or "n" }
      if
        feature
        and e.lhs
        and e.name
        and vim.tbl_contains(modes, "n")
        and (e.buffer == nil or e.buffer == buf)
      then
        local mutates = not M.read_only(feature, e.name)
        -- the feature's own word wins over the list
        if type(e.mutates) == "boolean" then mutates = e.mutates end
        local lhs_list = type(e.lhs) == "table" and e.lhs or { e.lhs }
        for _, lhs in ipairs(lhs_list) do
          local id = canon(lhs)
          -- the buffer's own record wins over a global one of the same key
          if not out[id] or e.buffer == buf then
            out[id] = { feature = feature, action = e.name, mutates = mutates }
          end
        end
      end
    end
  end
  return out
end

return M
