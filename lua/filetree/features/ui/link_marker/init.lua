---@module 'filetree.features.ui.link_marker'
---@brief Decorate symlinked tree nodes with an inline sign right before their
---own name, so a symlink reads differently from a plain file/directory at a
---glance -- and an optional eol marker naming the target.
---@description
--- Adapter-agnostic, same shape as `git_status`/`size_info`: walks the
--- rendered tree buffer line by line and asks the adapter for the node on
--- each line, then draws a small sign for any node the adapter reports as a
--- link. The sign itself is placed as an *inline* extmark right before the
--- node's own display name -- found fresh per render as the byte offset of
--- `node.name` on the line, since indent width and guide glyphs (box-drawing
--- guide lines, expand/collapse chevrons, devicons, ...) are backend/config-
--- dependent and not otherwise exposed to this adapter-agnostic feature: a
--- naive "first non-blank byte" used to land ON a guide character (e.g. the
--- "│" of a still-open ancestor) whenever one preceded the node's own icon,
--- splicing the sign into the *middle* of the guide run instead of past it
--- -- which visually detached that ancestor's guide line from its column and
--- made the symlink read as nested one level deeper than it actually is.
--- Anchoring on the name itself sidesteps guessing the guide/icon charset
--- entirely: whatever precedes the name (indent, guides, chevrons, icon)
--- stays exactly as the adapter drew it. Falls back to the old
--- first-non-blank heuristic on the rare line where `node.name` can't be
--- found verbatim (e.g. an adapter that truncates or decorates the name).
--- (`show_target`'s "-> target" text, when on, stays an eol marker -- an
--- inline path in front of the name would push the name itself around.)
---
--- Costs nothing extra per render: it reads `node.is_link`/`node.link_to`/
--- `node.link_broken`, fields the neo-tree and nvim-tree adapters already
--- populate from data their own backend held (see `adapter/neotree.lua`'s
--- `to_filetree_node` comment) — no `stat`/`readlink` call happens here. On
--- an adapter without `get_node_at_line` (netrw, oil.nvim, mini.files) this
--- silently draws nothing, the same "silently skipped" contract the other
--- line-resolved decorations use (see docs/FEATURES/BACKENDS.md).
---
--- A symlink whose target the adapter could not resolve (a dangling link)
--- gets the `broken` sign instead of `symlink` when the adapter can tell the
--- difference (neo-tree only — see the adapter comment); otherwise it is
--- shown as a plain symlink.
---
--- Hard links are deliberately NOT decorated here: telling a file with
--- `nlink > 1` apart from an ordinary file needs an actual `stat`, and every
--- one of its several names is an equal hard link — there is no single
--- dirent to flag as "the" hard link. That check belongs on demand, not on
--- every rendered line; see `node_info`'s "Links" line instead.

local au = require("filetree.util.autocmd")
local bufevents = require("filetree.util.bufevents")
local tree_attach = require("filetree.util.tree_attach")
local lib_debounce = require("lib.nvim.debounce")
local M = {}

---@type FiletreeLinkMarkerConfig
local DEFAULTS = {
  show_target = false,
  target_hl = "Comment",
  signs = {
    symlink = { text = "⇢", hl = "Special" },
    broken = { text = "⇢!", hl = "DiagnosticError" },
  },
}

---@type FiletreeLinkMarkerConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.link_marker` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  show_target = "boolean",
  target_hl = "string",
  signs = {
    "table",
    fields = {
      symlink = { "table", fields = { text = "string", hl = "string" } },
      broken = { "table", fields = { text = "string", hl = "string" } },
    },
  },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer  extmark namespace
local _ns = -1

---@type table?  debounce handle: { call, cancel }
local _render_debounce = nil

---Unsubscribe handle for `_adapter.on_render`, when the adapter supports it.
---@type fun()|nil
local _unsubscribe_render = nil

-- ── Rendering ─────────────────────────────────────────────────────────────────

---`bufnr`, when given, is the tree buffer to redraw -- passed by the
---adapter's `on_render` bridge with the bufnr of whichever tree pass just
---rendered, so THIS call decorates that one specifically instead of falling
---back to `_adapter.get_bufnr()`'s ambient "current tab" tree, which, with a
---second tree simultaneously live on another tab, can silently be the wrong
---one (see `adapter/neotree.lua`'s `on_render` doc comment). Omitted (the
---BufEnter/CursorMoved-driven calls below), the ambient lookup is already
---correct -- those only ever fire while actually on the tree's own tab.
---@param bufnr? integer
---The own tree's decorators for a link and for its target; nil on every other backend.
---@type Filetree.Decorate.Nodes|nil
local _decor = nil
---@type Filetree.Decorate.Nodes|nil
local _decor_target = nil

function M._render(bufnr)
  if not _adapter then return end
  -- the own tree asks the decorators with every line it draws
  if _decor then return end
  bufnr = bufnr or (_adapter.get_bufnr and _adapter.get_bufnr()) or -1
  if bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  if not _adapter.get_node_at_line then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for linenr = 0, #lines - 1 do
    local node = _adapter.get_node_at_line(bufnr, linenr)
    if node and node.is_link then
      local sign = (node.link_broken and _cfg.signs.broken) or _cfg.signs.symlink
      if sign then
        -- Byte offset of the node's own display name -- past indent,
        -- tree-guide characters, any expand/collapse chevron and the node's
        -- icon, all of which stay untouched and correctly aligned this way.
        -- Falls back to the first non-blank byte when the name can't be
        -- found verbatim (see module comment above).
        local line = lines[linenr + 1]
        local name_start = type(node.name) == "string"
          and node.name ~= ""
          and line:find(node.name, 1, true)
        local col = (name_start or line:find("%S") or 1) - 1
        pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, linenr, col, {
          virt_text = { { sign.text .. " ", sign.hl } },
          virt_text_pos = "inline",
          priority = 45,
        })
        if _cfg.show_target and type(node.link_to) == "string" and node.link_to ~= "" then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, linenr, -1, {
            virt_text = { { " -> " .. node.link_to, _cfg.target_hl } },
            virt_text_pos = "eol",
            priority = 45,
          })
        end
      end
    end
  end
end

---Clear all link-marker decorations.
function M.clear()
  if not _adapter then return end
  local bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or -1
  if bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  end
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreeLinkMarkerConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  _adapter = adapter
  _ns = vim.api.nvim_create_namespace("filetree_link_marker")
  local decorate = require("filetree.util.decorate")
  if _decor then _decor.remove() end
  if _decor_target then _decor_target.remove() end
  _decor = decorate.by_node(
    adapter,
    { name = "link", slot = "badge", priority = 45 },
    function(node)
      local data = node.data
      if not data or not data.is_link then return nil end
      local sign = (data.link_broken and _cfg.signs.broken) or _cfg.signs.symlink
      return sign and { text = sign.text, hl = sign.hl } or nil
    end
  )
  _decor_target = decorate.by_node(
    adapter,
    { name = "link_target", slot = "column", priority = 5 },
    function(node)
      local data = node.data
      if not _cfg.show_target or not data or not data.is_link then return nil end
      if type(data.link_to) ~= "string" or data.link_to == "" then return nil end
      return { text = "-> " .. data.link_to, hl = _cfg.target_hl }
    end
  )

  if _render_debounce then _render_debounce.cancel() end
  _render_debounce = lib_debounce.new(M._render, 50)

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_link_marker", true)

  bufevents.register("link_marker", "BufEnter:tree", {
    desc = "[filetree] Re-draw the tree's symlink markers",
    load = function()
      vim.defer_fn(M._render, 50)
    end,
  })

  -- ...and whenever the adapter re-renders the tree on ITS OWN schedule (a
  -- git-status fetch landing, a filesystem-watcher event, `follow_current_file`,
  -- or -- measured directly against a real neo-tree open -- its own filesystem
  -- source finishing its asynchronous scan just after the FIRST BufEnter-
  -- triggered render above). Without this, an extmark placed on one render
  -- gets wiped by the next such redraw (a full content replace, not an
  -- incremental edit, does not carry extmarks over) and only reappears once
  -- something else asks for a redraw -- which for a tree opened and never
  -- touched again would be never. Same mechanism, same comment, as `marks`'
  -- checkmarks. Optional: only adapters that expose `on_render` (currently
  -- neo-tree) get this; others fall back to BufEnter/CursorMoved alone.
  if type(adapter.on_render) == "function" then
    _unsubscribe_render = adapter.on_render(M._render)
  end

  -- Draw immediately on attach, not just on the next BufEnter/CursorMoved --
  -- `tree_attach.on_attach` also fires for a tree buffer that was ALREADY
  -- open when setup() ran (filetree.setup()'s startup FileType re-fire, see
  -- init.lua), which BufEnter:tree does not. Without this, a tree opened
  -- before filetree.nvim attached (or opened without ever moving focus into
  -- it) stayed unmarked until the user happened to focus or move the cursor
  -- inside it -- same trigger `git_status` uses for its own initial render,
  -- so both decorations stay in step on the same redraw.
  --
  -- A debounced buffer-local CursorMoved then keeps up with expand/collapse
  -- and navigation in between BufEnters.
  tree_attach.on_attach(function(buf)
    if _render_debounce then _render_debounce.call() end
    au.acmd("CursorMoved", {
      group = _augroup,
      buffer = buf,
      callback = function()
        if _render_debounce then _render_debounce.call() end
      end,
    })
  end)
end

function M.teardown()
  bufevents.unregister("link_marker")
  if _decor then _decor.remove() end
  if _decor_target then _decor_target.remove() end
  _decor, _decor_target = nil, nil
  M.clear()
  _adapter = nil
  if _unsubscribe_render then
    _unsubscribe_render()
    _unsubscribe_render = nil
  end
  if _render_debounce then
    _render_debounce.cancel()
    _render_debounce = nil
  end
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
