---@module 'filetree.integrations.menu'
---@brief Context-menu entries for nvzone/menu (soft, opt-in integration).
---@description
--- filetree.nvim does not depend on a menu plugin. It *provides* a curated list
--- of entries in the shape nvzone/menu expects (`{ name, cmd, rtxt }` plus
--- `{ name = "separator" }`), wired to the filetree feature actions. A host —
--- typically the user's tree/RightMouse dispatcher — composes them for the tree
--- window, e.g.:
--- >
---   local items = require("filetree.integrations.menu").items()
---   require("menu").open(items, { mouse = true })
--- <
--- Entries are self-gating: an action whose feature is disabled (so
--- `require("filetree").feature(name)` is nil) is omitted, and whole groups can
--- be turned off via `config.menu` (see filetree.config.DEFAULTS). nvzone closes
--- the menu before running `cmd`, so the tree window/node is the active context —
--- exactly as if the corresponding keymap had been pressed.

local nerd = require("lib.nvim.ui.nerd_font")

local M = {}

---@internal
--- One glyph per entry, one cell each (see lib.nvim.ui.nerd_font -- shown
--- only when the user has declared `vim.g.have_nerd_font = true`; a plain
--- ASCII fallback otherwise, so the column always lines up either way).
--- Named by group, not by entry: several entries in the same group share a
--- family (e.g. every "open in X" is the same external-link glyph) rather
--- than each getting a bespoke one, which would say more than the icon
--- column is meant to.
---@type table<string, string>
local ICON = {
  create = nerd.glyph("F0415", "+"), -- plus
  rename = nerd.glyph("F03EB", "r"), -- pencil
  batch_rename = nerd.glyph("F0C60", "l"), -- format-list-bulleted
  move = nerd.glyph("F0BB1", "m"), -- swap-horizontal
  template = nerd.glyph("F0214", "n"), -- file-outline
  copy = nerd.glyph("F018F", "c"), -- content-copy
  cut = nerd.glyph("F0190", "x"), -- content-cut
  paste = nerd.glyph("F0192", "p"), -- content-paste
  trash = nerd.glyph("F01B4", "d"), -- trash-can
  open_external = nerd.glyph("F03CC", "o"), -- open-in-new
  copy_path = nerd.glyph("F018F", "c"), -- content-copy
  markdown_link = nerd.glyph("F0354", "M"), -- language-markdown
  search = nerd.glyph("F0349", "f"), -- magnify
  info = nerd.glyph("F02FC", "i"), -- information-outline
  preview = nerd.glyph("F0208", "v"), -- eye-outline
  ocr = nerd.glyph("F0A5B", "t"), -- text-recognition
  mark_on = nerd.glyph("F0C52", "m"), -- checkbox-marked-outline
  mark_off = nerd.glyph("F0131", "u"), -- checkbox-blank-outline
  mark_list = nerd.glyph("F0C60", "l"), -- format-list-bulleted
  window = nerd.glyph("F0855", "w"), -- dock-left
  filetree = nerd.glyph("F0641", "T"), -- file-tree
}

---@internal
--- Resolve a loaded feature module (nil when the feature is disabled/absent).
---@param name string
---@return table|nil
local function feature(name)
  local ok, main = pcall(require, "filetree")
  if not ok then return nil end
  return main.feature(name)
end

---@internal
--- Resolve the active tree adapter (nil when filetree isn't set up / no
--- adapter resolved yet). Unlike `feature()`, this isn't gated by a feature
--- name — open/close is core plugin identity, not something to disable.
---@return FiletreeAdapter|nil
local function get_adapter()
  local ok, main = pcall(require, "filetree")
  if not ok then return nil end
  local ok2, adapter = pcall(main.adapter)
  return (ok2 and adapter) or nil
end

---@internal
--- Build one menu entry, or nil when the feature/function is unavailable.
---@param name string   feature name
---@param fn string     function on the feature module
---@param label string  menu label
---@param rtxt? string  right-aligned hint (usually the default keymap)
---@param icon? string  leading glyph, drawn in its own column -- see ICON above
---@return table|nil
local function entry(name, fn, label, rtxt, icon)
  local f = feature(name)
  if not (f and type(f[fn]) == "function") then return nil end
  return {
    name = label,
    rtxt = rtxt,
    icon = icon,
    cmd = function()
      local ff = feature(name)
      if ff and type(ff[fn]) == "function" then ff[fn]() end
    end,
  }
end

---@internal
--- Append every non-nil entry to `out`, preceded by a separator when both
--- `out` and the incoming entries are non-empty. Returns whether anything
--- was added.
---
--- Takes varargs, not a table: a table CONSTRUCTOR with a nil in a
--- non-trailing slot (e.g. `{ entry(a), entry(b), entry(c) }` where `b` is
--- disabled) creates a "hole", and `ipairs` stops at the first one --
--- silently dropping every entry after it, even enabled ones. Varargs don't
--- have this problem: `select()` finds every argument at its true position
--- regardless of which others are nil.
---@param out table
---@vararg table|nil
---@return boolean added
local function add_group(out, ...)
  local n = select("#", ...)
  local compact = {}
  for i = 1, n do
    local e = select(i, ...)
    if e ~= nil then compact[#compact + 1] = e end
  end
  if #compact == 0 then return false end
  if #out > 0 then out[#out + 1] = { name = "separator" } end
  for _, e in ipairs(compact) do
    out[#out + 1] = e
  end
  return true
end

---@internal
--- "image" / "pdf" for the node under the cursor, nil for anything else (no node, no adapter,
--- `preview` disabled). Asked per `items()` call, so the group follows the clicked node.
---@return "image"|"pdf"|nil kind
---@return string? path
local function media_node()
  local adapter = get_adapter()
  local preview = feature("preview")
  if not (adapter and type(adapter.get_current_node) == "function") then return nil end
  if not (preview and type(preview.media_kind) == "function") then return nil end
  local ok, node = pcall(adapter.get_current_node)
  local path = ok and type(node) == "table" and node.path or nil
  local kind = preview.media_kind(path)
  return kind, kind and path or nil
end

---@internal
--- The Image/PDF group: only entries that work for the node's kind. OCR and image info come from
--- images.nvim (soft dependency, omitted without it); PDFs get preview and open externally.
---@param out table
local function add_media_group(out)
  local kind, path = media_node()
  if not kind then return end

  local function images_entry(fn, label, icon)
    local ok, images = pcall(require, "images")
    if not (ok and type(images[fn]) == "function") then return nil end
    return {
      name = label,
      icon = icon,
      cmd = function()
        images[fn](path)
      end,
    }
  end

  add_group(
    out,
    entry(
      "preview",
      "toggle_or_open",
      kind == "pdf" and "Preview PDF" or "Preview image",
      "<Tab>",
      ICON.preview
    ),
    entry("open_with", "open_system", "Open externally", nil, ICON.open_external),
    kind == "image" and images_entry("ocr", "OCR (recognise text)", ICON.ocr) or nil,
    kind == "image" and images_entry("info", "Image info", ICON.info) or nil
  )
end

---Whether a host that asks first (ui.nvim's `ui.menu`) may offer the
---"Open/Close filetree" row: `integrations.ui_menu` is not false and the `menu`
---group is not switched off. `items()`/`submenu()`/`window_entry()` themselves
---stay governed by `menu` alone, so other hosts are unaffected by `ui_menu`.
---@return boolean
function M.enabled()
  local ok, main = pcall(require, "filetree")
  local cfg = (ok and main.config()) or {}
  if (cfg.integrations or {}).ui_menu == false then return false end
  return (cfg.menu or {}).enable ~= false
end

---Single entry to open or close the tree, depending on whether it is
---currently open. Deliberately NOT part of `items()`'s node-action groups
---(rename/trash/copy/… only make sense against a node under the cursor,
---which a normal editor buffer does not have) -- exposed standalone so a
---host's normal-buffer context menu can offer "open the tree" without also
---dragging in the 18 tree-only actions. `items()` still includes the SAME
---entry under its own "window" group, since "close" is meaningful there too.
---@param bufnr? integer  Buffer to reveal when opening (defaults to the current buffer).
---@return table|nil
function M.window_entry(bufnr)
  local ok, main = pcall(require, "filetree")
  local mcfg = (ok and main.config() and main.config().menu) or {}
  if mcfg.enable == false or mcfg.window == false then return nil end

  local adapter = get_adapter()
  if not adapter then return nil end

  local is_open = type(adapter.is_open) == "function" and adapter.is_open()
  if is_open then
    if type(adapter.close) ~= "function" then return nil end
    return {
      name = "Close filetree",
      icon = ICON.window,
      cmd = function()
        adapter.close()
      end,
    }
  end

  if type(adapter.open_reveal) ~= "function" or type(adapter.open_cwd) ~= "function" then
    return nil
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  return {
    name = "Open filetree",
    icon = ICON.window,
    cmd = function()
      if path ~= "" and vim.fn.filereadable(path) == 1 then
        adapter.open_reveal(path)
      else
        adapter.open_cwd()
      end
    end,
  }
end

--- Build the filetree context-menu entries for the current tree node.
--- Returns an empty list when the integration (or every group) is disabled, so a
--- host can `vim.list_extend` it unconditionally.
---@return table[]
function M.items()
  local ok, main = pcall(require, "filetree")
  local mcfg = (ok and main.config() and main.config().menu) or {}
  if mcfg.enable == false then return {} end

  local out = {}
  local on = function(group)
    return mcfg[group] ~= false
  end

  if on("fileops") then
    add_group(
      out,
      entry("smart_create", "create", "Create file / dir", "a", ICON.create),
      entry("smart_rename", "rename_current", "Rename (LSP refs)", "r", ICON.rename),
      entry("rename_batch", "open", "Batch rename", "<leader>rb", ICON.batch_rename),
      entry("move", "move", "Move to…", "M", ICON.move),
      entry("create_from_template", "open_current", "New from template", "A", ICON.template)
    )
  end

  if on("clipboard") then
    add_group(
      out,
      entry("copy_move", "stage_copy", "Copy", "c", ICON.copy),
      entry("copy_move", "stage_cut", "Cut", "x", ICON.cut),
      entry("copy_move", "paste", "Paste", "p", ICON.paste),
      entry("file_clipboard", "copy", "Copy to system clipboard", "gy", ICON.copy)
    )
  end

  if on("delete") then
    add_group(out, entry("trash", "delete_current", "Trash", "d", ICON.trash))
  end

  if on("open") then
    add_group(
      out,
      entry("open_variants", "open_vsplit", "Open in vsplit", "sg", ICON.open_external),
      entry("open_variants", "open_split", "Open in split", "sv", ICON.open_external),
      entry("open_variants", "open_tabnew", "Open in tab", "st", ICON.open_external),
      entry("open_with", "open_system", "Open with system app", "<leader>sm", ICON.open_external),
      entry("open_in_fm", "open", "Reveal in file manager", "<leader>fm", ICON.open_external)
    )
  end

  if on("media") then add_media_group(out) end

  if on("paths") then
    add_group(
      out,
      entry("path_copy", "pick", "Copy path…", "[a", ICON.copy_path),
      entry("markdown_links", "link_current", "Markdown link", "ML", ICON.markdown_link)
    )
  end

  if on("search") then
    add_group(
      out,
      entry("find_files", "find", "Find files", "f", ICON.search),
      entry("grep_in_dir", "grep", "Grep in dir", "gr", ICON.search)
    )
  end

  if on("info") then
    add_group(
      out,
      entry("node_info", "show_current", "Node info", "I", ICON.info),
      -- Not gated through `entry()`/`feature()`: `:Inspect` is a builtin
      -- Neovim command, not a filetree feature -- shows the highlight/
      -- treesitter groups painted on the clicked tree line, which is
      -- exactly the tool a highlight bug on a node needs.
      {
        name = "Inspect",
        icon = ICON.info,
        cmd = function()
          pcall(vim.cmd, "Inspect")
        end,
      }
    )
  end

  if on("marks") then
    add_group(
      out,
      entry("marks", "toggle_current", "Toggle mark", "m", ICON.mark_on),
      entry("marks", "mark_all_visible", "Mark all visible", "]m", ICON.mark_on),
      entry("marks", "unmark_all_visible", "Unmark all visible", "[m", ICON.mark_off),
      entry("marks", "clear_all", "Clear marks", "<leader>mc", ICON.mark_off),
      entry("marks", "show", "Show marked nodes", "<leader>ms", ICON.mark_list)
    )
  end

  if on("window") then add_group(out, M.window_entry()) end

  return out
end

--- Convenience: the entries wrapped as a single nested submenu entry, for hosts
--- that prefer a "Filetree ▸" fly-out. Returns nil when there is nothing to show.
---@param label? string
---@return table|nil
function M.submenu(label)
  local items = M.items()
  if #items == 0 then return nil end
  return { name = label or "Filetree", icon = ICON.filetree, items = items }
end

return M
