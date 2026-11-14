---@module 'filetree.features.ui.cheatsheet'
---@brief `?` cheatsheet — a paged floating window with every key and command
---that is active on the current tree.
---@description
--- Pages (`<Tab>` / `<S-Tab>` or the page number switch):
---   0. here       -- own tree only, shown first: the actions of its table that
---                    apply to the node under the cursor, with the key that
---                    reaches each one there (`filetree.native.action`)
---   1. filetree   -- filetree.nvim's own keymaps, grouped by category
---   2. other keys -- every other buffer-local key on the tree buffer: the
---                    adapter's native ones (neo-tree, nvim-tree, ...) and the
---                    ones other plugins of this ecosystem add (pickers.nvim
---                    entry actions, pdfport, ...)
---   3. commands   -- the `:Filetree` sub-commands
---   4. conflicts  -- only when two filetree actions claim the same key: which
---                    one is live, free alternatives; `<CR>` moves one
---                    (`util.key_conflicts`)
---
--- It used to skip neo-tree, on the argument that neo-tree's native `?` is
--- already complete. It was not: that list was built from a hand-kept table that
--- lagged the features, so a key filetree rebinds (`D`) was listed under the
--- native action it had replaced. This one reads what is **actually bound** --
--- lib.nvim's keymap registry for page 1, the buffer's own keymaps for page 2 --
--- so it cannot disagree with the keys.
---
--- nvim-tree's `g?` rebuilds its list on a throwaway buffer and never sees keys
--- bound outside `on_attach`; netrw's `?` is a static page; so the other
--- adapters have no equivalent hook either. One adapter-agnostic implementation
--- instead of a bespoke integration per adapter.

local map = require("filetree.util.map")
local kit = require("ui.kit")
local kit_presets = require("ui.kit.presets")
local bind = require("filetree.util.bind")
local key_conflicts = require("filetree.util.key_conflicts")

local M = {}

---@type FiletreeCheatsheetConfig
local DEFAULTS = {
  enabled = true,
  keymap = "?",
}

---@type FiletreeCheatsheetConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.cheatsheet` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  style = "string",
}

---Maps this ecosystem's shared chip vocabulary (`ui.kit.presets`) onto the
---general `ui.kit.theme` preset names that actually carry a border/highlight
---definition -- "chip" (flat, square-cornered) maps to "solid" (Neovim's
---square-cornered `single` border style), matching `ui.kit.presets`' own
---aliases (`rect`/`square`/`block` -> `"chip"`).
---@type table<string, string>
local CHIP_TO_THEME = {
  classic = "minimal",
  chip = "solid",
  rounded_chip = "rounded",
}

---@internal
---Resolve `_cfg.style` to a `ui.kit.theme` preset name, or nil (no override,
---so a globally configured `ui.kit.theme.setup({default=...})` still wins).
---One of this ecosystem's three shared chip names maps to its underlying
---theme preset; anything else (a built-in `ui.kit.theme` preset this module
---does not know by a special name, e.g. `"double"`/`"ascii"`/`"hacker"`/
---`"menu"`, or a caller's own custom-registered one) passes through as-is.
---@return string?
local function resolve_theme()
  if not _cfg.style then return nil end
  local canonical = kit_presets.normalize(_cfg.style, "filetree.cheatsheet")
  return CHIP_TO_THEME[canonical] or canonical
end

---@type Ui.Kit.Surface|nil
local _surf = nil

---@class FiletreeCheatsheetPage
---@field title string
---@field lines string[]
---@field action? fun()   # What `<CR>` does on this page.
---@field hint?   string  # Footer text for it.

---@type FiletreeCheatsheetPage[]
local _pages = {}
---@type integer
local _page = 1

local function close_win()
  if _surf then _surf:close() end
end

---@internal
---Which category a feature belongs to, from the feature registry.
---@return table<string, string>
local function category_of()
  local ok, registry = pcall(require, "filetree.features")
  local out = {}
  if ok and type(registry.FEATURES) == "table" then
    for name, entry in pairs(registry.FEATURES) do
      out[name] = entry.category
    end
  end
  return out
end

---@class FiletreeCheatsheetRow
---@field lhs  string
---@field desc string

---@internal
---Lay rows out as `<lhs>  <desc>` lines under a header, lhs column aligned.
---@param lines string[]           # Appended to.
---@param header string
---@param rows FiletreeCheatsheetRow[]
---@param widest integer
local function emit_group(lines, header, rows, widest)
  table.sort(rows, function(a, b)
    return a.lhs < b.lhs
  end)
  lines[#lines + 1] = " " .. header
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format("  %-" .. widest .. "s  %s", r.lhs, r.desc)
  end
  lines[#lines + 1] = ""
end

---@internal
---A stable string for an entry's mode (a string, or a list for a multi-mode
---action), for de-duplicating rows.
---@param mode string|string[]
---@return string
local function mode_id(mode)
  return type(mode) == "table" and table.concat(mode, ",") or tostring(mode)
end

---@internal
---`feature:action` of a registry entry.
---@param surface string
---@param e Lib.Keymap.Registered
---@return string
local function claim_id(surface, e)
  return (surface:match("^filetree/([^/]+)") or "?") .. ":" .. e.name
end

---Page 1: filetree's own keymaps, one header per category, one row per key
---that is actually bound right now.
---
---Read back from the registry rather than from a catalog of defaults, so a
---remapped or disabled key shows up as what it is. A key two actions claim is
---listed once, as the action that owns it, and flagged.
---@param buf integer
---@param conflicts FiletreeKeyConflict[]
---@return string[]
local function build_filetree_page(buf, conflicts)
  local ok_reg, registry = pcall(require, "filetree.features")
  local order = (ok_reg and registry.CATEGORY_ORDER) or {}
  local cat_of = category_of()

  -- lhs id -> the claim that owns it (nil when unknown), and who else wants it.
  ---@type table<string, { active: string|nil, others: string[] }>
  local clash = {}
  for _, c in ipairs(conflicts) do
    local active = c.active and (c.active.feature .. ":" .. c.active.action) or nil
    local others = {}
    for _, claim in ipairs(c.claims) do
      local id = claim.feature .. ":" .. claim.action
      if id ~= active then others[#others + 1] = claim.feature end
    end
    clash[mode_id(c.claims[1].mode) .. " " .. c.lhs] = { active = active, others = others }
  end

  local lines = {}
  local widest = 0

  ---@type table<string, FiletreeCheatsheetRow[]>
  local rows_by_cat = {}
  ---@type table<string, boolean>
  local seen = {}

  for _, item in ipairs(key_conflicts.entries(buf)) do
    -- "filetree/<feature>" is tree-scoped, "filetree/<feature>/global" is bound
    -- everywhere (the tree-toggle keys); other sub-surfaces are not keymaps of
    -- their own.
    local feature = item.key:match("^filetree/([^/]+)$")
    local global_feature = item.key:match("^filetree/([^/]+)/global$")
    local e = item.entry
    if (feature or global_feature) and e.bound and e.lhs then
      local id = mode_id(e.mode) .. " " .. e.lhs
      local c = clash[id]
      -- One row per key, not per registration (a buffer-local preset is
      -- registered again for every tree buffer that attaches) -- and for a key
      -- two actions claim, the owner's row, not whichever registered first.
      local mine = not c or c.active == nil or c.active == claim_id(item.key, e)
      if mine and not seen[id] then
        seen[id] = true
        local cat = global_feature and "global" or cat_of[feature] or "other"
        rows_by_cat[cat] = rows_by_cat[cat] or {}
        -- The registry's `desc` carries the plugin prefix, which every row
        -- here would repeat. Capitalized because a cheatsheet row is a
        -- sentence about the key, not a fragment of one.
        local desc = (e.desc or e.name):gsub("^filetree: ", ""):gsub("^%l", string.upper)
        if c then
          desc = desc .. ("  [also wanted by %s -- page 4]"):format(table.concat(c.others, ", "))
        end
        table.insert(rows_by_cat[cat], { lhs = e.lhs, desc = desc })
        if #e.lhs > widest then widest = #e.lhs end
      end
    end
  end

  ---@type string[]
  local cats = {}
  for _, cat in ipairs(order) do
    cats[#cats + 1] = cat
  end
  -- Anything whose feature the registry does not classify still gets shown,
  -- after the known categories, rather than silently dropped.
  cats[#cats + 1] = "global"
  cats[#cats + 1] = "other"

  for _, cat in ipairs(cats) do
    local rows = rows_by_cat[cat]
    if rows and #rows > 0 then
      emit_group(lines, cat == "global" and "global (everywhere)" or cat, rows, widest)
    end
  end
  return lines
end

---@internal
---Show a leading `<leader>` as such rather than as the character it expands to.
---@param lhs string  # As `nvim_buf_get_keymap` reports it (only <Space> comes raw).
---@return string
local function unexpand_leader(lhs)
  local leader = vim.g.mapleader
  if type(leader) ~= "string" or leader == "" then leader = "\\" end
  if lhs:sub(1, #leader) == leader then lhs = "<leader>" .. lhs:sub(#leader + 1) end
  return (lhs:gsub(" ", "<Space>"))
end

---@internal
---Every bound filetree key of `buf`, in the one canonical raw form
---(`key_conflicts.canon`), so page 2 can tell which buffer keymaps page 1
---already lists.
---@param buf integer
---@return table<string, true>
local function filetree_keys(buf)
  local out = {}
  for _, item in ipairs(key_conflicts.entries(buf)) do
    local e = item.entry
    if e.bound and e.lhs then out[key_conflicts.canon(e.lhs)] = true end
  end
  return out
end

---Page 2: every other buffer-local normal-mode key of the tree buffer.
---
---Whatever the adapter mapped natively plus what other plugins attached
---(pickers.nvim's entry actions, pdfport, ...) -- the keys that are not
---filetree's own and therefore not in the registry.
---@param buf integer
---@return string[]
local function build_other_page(buf)
  local lines = {}
  if not vim.api.nvim_buf_is_valid(buf) then return { " (no tree buffer)" } end

  local ours = filetree_keys(buf)
  ---@type FiletreeCheatsheetRow[]
  local rows = {}
  local widest = 0
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    -- `<Plug>` targets and `<SNR>` internals are plumbing, and a key filetree
    -- itself bound is page 1's row (the registry is the better label).
    if
      not ours[key_conflicts.canon_live(m)]
      and not m.lhs:match("^<Plug>")
      and not m.lhs:match("^<SNR>")
    then
      local desc = m.desc
      if not desc or desc == "" then
        if m.callback then
          desc = "(lua function)"
        elseif m.rhs == nil or m.rhs == "" or m.rhs:lower() == "<nop>" then
          desc = "(disabled)"
        else
          desc = m.rhs
        end
      end
      -- A row is one buffer line: an rhs (or a desc) with a newline in it would
      -- make `nvim_buf_set_lines` refuse the whole page.
      desc = desc:gsub("[%c]+", " ")
      -- neo-tree labels its native keys with the bare command name
      -- ("toggle_hidden"); as a sentence that reads better with spaces.
      if desc:match("^[%l%d_]+$") then desc = desc:gsub("_", " ") end
      desc = desc:gsub("^%l", string.upper)
      local lhs = unexpand_leader(m.lhs)
      rows[#rows + 1] = { lhs = lhs, desc = desc }
      if #lhs > widest then widest = #lhs end
    end
  end

  if #rows == 0 then return { " (no other buffer-local keys)" } end
  emit_group(lines, "buffer-local, from the adapter and other plugins", rows, widest)
  return lines
end

---Page 3: the `:Filetree` sub-commands.
---@return string[]
local function build_commands_page()
  local ok, commands = pcall(require, "filetree.commands")
  if not ok or type(commands.command_paths) ~= "function" then
    return { " (commands unavailable)" }
  end

  local name = type(commands.command_name) == "function" and commands.command_name() or "Filetree"

  local lines = { " :" .. name .. " <sub-command>", "" }
  local group
  for _, path in ipairs(commands.command_paths()) do
    local head = path:match("^(%S+)")
    if head ~= group then
      if group then lines[#lines + 1] = "" end
      group = head
    end
    lines[#lines + 1] = "  :" .. name .. " " .. path
  end
  lines[#lines + 1] = ""
  return lines
end

---Page 4: keys two actions claim, the live one marked, free alternatives for
---each. Only built when there is something to say.
---@param buf integer
---@param conflicts FiletreeKeyConflict[]
---@return string[]
local function build_conflicts_page(buf, conflicts)
  local lines = {}
  for _, c in ipairs(conflicts) do
    lines[#lines + 1] = (" %s  is claimed by %d actions"):format(c.lhs, #c.claims)
    for _, claim in ipairs(c.claims) do
      local live = c.active
        and c.active.feature == claim.feature
        and c.active.action == claim.action
      local alternatives = key_conflicts.suggest(c.buf or buf, claim, 4)
      lines[#lines + 1] = ("   %s %s   move to: %s"):format(
        live and "*" or "-",
        key_conflicts.label(claim, nil),
        table.concat(alternatives, "  ")
      )
    end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = " * is the action the key does right now; the other cannot be reached by it."
  return lines
end

---Page "here", own tree only: exactly the actions of its table that apply to the node under the
---cursor, each with the key that reaches it there. The rows come from the table the keys are bound
---from (rule UI-20), so a key listed here does what the row says on this node.
---@param view Filetree.View
---@return string[]
local function build_here_page(view)
  local entries = require("filetree.native.action").applicable(view)
  local row = view:current()
  local label = row and (row.node.label or tostring(row.id)) or "(no entry)"
  ---@type FiletreeCheatsheetRow[]
  local rows = {}
  local widest = 1
  for _, e in ipairs(entries) do
    local lhs = e.key or "-"
    local desc = (e.action.desc or e.action.name):gsub("[%c]+", " ")
    if not e.key then desc = desc .. "  (:Filetree action " .. e.action.name .. ")" end
    if e.action.origin == "source" or e.action.origin == "plugin" then
      desc = desc .. "  [" .. e.action.origin .. "]"
    end
    rows[#rows + 1] = { lhs = lhs, desc = desc }
    if #lhs > widest then widest = #lhs end
  end
  local lines = {}
  if #rows == 0 then return { " nothing applies to " .. label, "" } end
  emit_group(lines, "on " .. label, rows, widest)
  return lines
end

---@internal
---Build every page for the given tree buffer.
---@param buf integer
---@return FiletreeCheatsheetPage[]
local function build_pages(buf)
  local conflicts = key_conflicts.find(buf)
  ---@type FiletreeCheatsheetPage[]
  local pages = {
    { title = "filetree", lines = build_filetree_page(buf, conflicts) },
    { title = "other keys", lines = build_other_page(buf) },
    { title = "commands", lines = build_commands_page() },
  }
  -- the own tree knows what applies where: that page comes first
  local native_view = package.loaded["filetree.native.view"]
    and require("filetree.native.view").of_buf(buf)
  if native_view and native_view.actions then
    table.insert(pages, 1, { title = "here", lines = build_here_page(native_view) })
  end
  if #conflicts > 0 then
    pages[#pages + 1] = {
      title = "conflicts",
      lines = build_conflicts_page(buf, conflicts),
      hint = "<CR> move a key",
      action = function()
        close_win()
        key_conflicts.resolve(buf)
      end,
    }
  end
  return pages
end

---@internal
---One page's buffer lines: the tab strip, then the page, then the footer.
---Every page is padded to the tallest one so the float never resizes while
---paging.
---@param height integer  # Rows of page body to pad to.
---@return string[]
local function render(height)
  local tabs = {}
  for i, p in ipairs(_pages) do
    tabs[#tabs + 1] = string.format(i == _page and "[%d %s]" or " %d %s ", i, p.title)
  end
  local lines = { " " .. table.concat(tabs, " "), "" }
  local page = _pages[_page]
  for i = 1, height do
    lines[#lines + 1] = page.lines[i] or ""
  end
  lines[#lines + 1] = " <Tab>/<S-Tab> page   "
    .. (page.hint and (page.hint .. "   ") or "")
    .. "q / <Esc> close"
  return lines
end

---@type integer  # Namespace for the active-tab highlight below.
local _ns = vim.api.nvim_create_namespace("filetree_cheatsheet")

---@internal
---Highlight the active tab's `[N title]` bracket on the tab strip (line 1)
---with `ui.kit.theme`'s "selection" role -- `"KitSelection"`, the same fixed
---global group `ui.kit`'s other surfaces paint a currently-selected row
---with. Already materialized for whatever theme this surface resolved to:
---`kit.viewer()` -> `surface.open()` -> `theme.apply()` runs before this is
---ever called, for every code path that opens or repaints the float.
---@param bufnr integer
local function paint_active_tab(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, 1)
  local line1 = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  local s, e = line1:find("%[%d+ [^%]]*%]")
  if s then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, 0, s - 1, {
      end_col = e,
      hl_group = "KitSelection",
    })
  end
end

---@internal
---@param delta integer
---@param height integer
local function turn(delta, height)
  if not _surf or not _surf:is_valid() then return end
  _page = (_page - 1 + delta) % #_pages + 1
  _surf:set_lines(render(height))
  paint_active_tab(_surf.bufnr)
  vim.api.nvim_win_set_cursor(_surf.winid, { 1, 0 })
end

---Show or toggle (any key closes; a second `?` closes too) the cheatsheet.
function M.show()
  if _surf and _surf:is_valid() then
    close_win()
    return
  end

  _pages = build_pages(vim.api.nvim_get_current_buf())
  _page = 1

  local body_h, content_w = 1, 30
  for _, p in ipairs(_pages) do
    body_h = math.max(body_h, #p.lines)
    for _, l in ipairs(p.lines) do
      content_w = math.max(content_w, vim.fn.strdisplaywidth(l))
    end
  end
  local lines = render(body_h)
  local max_w = math.floor(vim.o.columns * 0.9)
  local max_h = math.floor(vim.o.lines * 0.8)

  _surf = kit.viewer({
    lines = lines,
    title = "filetree.nvim keymaps",
    filetype = "filetree_cheatsheet",
    width = math.min(content_w + 2, max_w),
    height = math.min(#lines, max_h),
    theme = resolve_theme(),
  })
  if not _surf then return end
  _surf:on_close(function()
    _surf = nil
  end)
  paint_active_tab(_surf.bufnr)

  local opts = { buffer = _surf.bufnr, nowait = true, silent = true }
  map("n", "<Tab>", function()
    turn(1, body_h)
  end, opts)
  map("n", "<S-Tab>", function()
    turn(-1, body_h)
  end, opts)
  for i = 1, #_pages do
    map("n", tostring(i), function()
      turn(i - _page, body_h)
    end, opts)
  end
  -- The page decides what <CR> does (only the conflicts page has an action).
  map("n", "<CR>", function()
    local page = _pages[_page]
    if page and page.action then page.action() end
  end, opts)

  -- kit.viewer's own nice_quit only binds q/<Esc>; also close on a second
  -- press of the toggle key itself (e.g. a second `?`).
  if _cfg.keymap and _cfg.keymap ~= "q" and _cfg.keymap ~= "<Esc>" then
    map("n", _cfg.keymap, close_win, opts)
  end
end

function M.close()
  close_win()
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeCheatsheetConfig
---@param _adapter FiletreeAdapter
function M.setup(config, _adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), config)
  if not _cfg.keymap then return end

  bind.bind("cheatsheet", _cfg, {
    { name = "show", field = "keymap", rhs = M.show, desc = "keymap cheatsheet" },
  })
end

function M.teardown()
  close_win()
end

return M
