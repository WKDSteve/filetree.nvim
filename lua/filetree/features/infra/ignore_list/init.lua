---@module 'filetree.features.infra.ignore_list'
---@brief Hide common filesystem clutter (.git, node_modules, …) from the tree by default.
---@description
--- Injects a list of basenames into the adapter's native hide mechanism so they
--- do not appear in the tree at all.  Toggle via the adapter's built-in
--- show-hidden key (e.g. `H` in neo-tree, which toggles filtered_items.visible).
---
--- Precedence for the name list (highest first):
---   1. User supplies `ignore_list = { ".git", … }` → uses that array verbatim.
---   2. Otherwise → require("lib.nvim.fs.ignore.list").basenames (a hard dependency).
---
--- Config (driven from top-level `ignore_list` in FiletreeConfig, not from features):
---   enabled  boolean     true = hide; false = skip entirely.
---   names    string[]?   nil = resolve from lib.nvim.
---
--- Toggle at runtime: use the adapter's own "toggle hidden" mechanism.
---   neotree  → `H` (toggle_hidden) shows/hides everything in filtered_items.
---   nvimtree → `H` (toggle_dotfiles) shows/hides dot-files.
---   Others   → filetree falls back to extmark-dim (same as ignore_patterns).

local bufevents = require("filetree.util.bufevents")
local au = require("filetree.util.autocmd")
local lib_ignore_list = require("lib.nvim.fs.ignore.list")
local M = {}

---Option schema (see `filetree.config.schema`): exactly what
---`features.ignore_list` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  names = { "table", of = "string" },
}

---Resolve the effective name list: user override → lib.nvim.
---@param user_names string[]? explicit list from config; nil = use lib.nvim's
---@return string[]
local function resolve_names(user_names)
  return user_names or lib_ignore_list.basenames
end

---Resolve Lua-pattern rules (file basenames like `.log`/`.pyc`, not covered by
---exact basenames) from lib.nvim. These only matter to path-output actions,
---not the tree display this feature otherwise drives.
---@return string[]
local function resolve_patterns()
  return lib_ignore_list.patterns
end

-- ── Path-output predicate (copy_file_list, markdown_links, …) ───────────────
-- Same resolved names/patterns this feature hides in the tree, exposed as a
-- `filetree.util.fs`-shaped `ignore_fn(name): boolean` so recursive
-- path-output actions skip `.git`, `node_modules`, etc. too, without a second
-- copy of the ignore rules. nil while disabled (or before setup() runs) so
-- `M.predicate()` correctly ignores nothing until this feature is live.
---@type table<string, true>?
local _names_set = nil
---@type string[]
local _patterns = {}

-- ── Adapter-specific hide injection ──────────────────────────────────────────

---Merge `names` into a filtered_items hide_by_name value, in place, returning
---a dict (`{name = true, …}`).
---
---neo-tree's own `filesystem.setup()` converts `hide_by_name` from the
---user-facing `string[]` shape into this dict shape (`utils.list_to_dict`) so
---that its render-time filter (`file-items.lua`: `f.hide_by_name[name]`) is an
---O(1) lookup — and it does this conversion exactly once, during its own
---setup(), which normally runs *before* filetree's (event="VeryLazy"). Adding
---entries as if `hide_by_name` were still an array (`ipairs` + `#+1` append, the
---previous implementation here) silently does nothing: neo-tree's filter never
---iterates the table, it only ever indexes it by name, so array-shaped entries
---are invisible to it. This must always end up dict-shaped, regardless of
---whether neo-tree already converted it (dict), the user pre-set it in their
---own neo-tree opts (array, not yet converted), or it was never set (nil).
---@param existing table?  Current filtered_items.hide_by_name value (any shape, or nil).
---@param names    string[]
---@return table<string, true>
local function merge_hide_by_name(existing, names)
  local dict = {}
  if type(existing) == "table" then
    for k, v in pairs(existing) do
      if type(k) == "string" then
        dict[k] = v -- already dict-shaped (converted by neo-tree)
      elseif type(v) == "string" then
        dict[v] = true -- still array-shaped (not yet converted)
      end
    end
  end
  for _, name in ipairs(names) do
    dict[name] = true
  end
  return dict
end

---Inject names into neo-tree's filtered_items.hide_by_name (both the merged
---config, for future states, and any already-open state) and refresh.
---@param names string[]
---@param adapter FiletreeAdapter
local function apply_neotree(names, adapter)
  -- The merged neo-tree config lives on require("neo-tree").config after its
  -- setup() has run (require("neo-tree.config") does NOT exist in v3.x).
  local ok, nt = pcall(require, "neo-tree")
  local ncfg = ok and (nt.config or (type(nt.ensure_config) == "function" and nt.ensure_config()))
    or nil
  if not ncfg or not ncfg.filesystem then
    -- neo-tree.setup() hasn't run yet (e.g. lazy=false startup race).
    -- Retry once after VimEnter when all plugin configs have executed.
    au.acmd("VimEnter", {
      once = true,
      callback = function()
        vim.defer_fn(function()
          apply_neotree(names, adapter)
        end, 50)
      end,
    })
    return
  end

  -- 1. Future states: neo-tree deepcopies from this config template.
  ncfg.filesystem.filtered_items = ncfg.filesystem.filtered_items or {}
  local fi = ncfg.filesystem.filtered_items
  -- Guaranteed non-nil by the assignment just above; LuaLS does not carry
  -- that narrowing through the field re-read.
  ---@cast fi table
  fi.hide_by_name = merge_hide_by_name(fi.hide_by_name, names)
  -- Force-hide, even if the user's own neo-tree opts already set
  -- `visible = true` (e.g. a leftover personal preference): `visible = true`
  -- disables the hide_by_name filter entirely, so hidden clutter would show
  -- by default and only get hidden after a manual `H` toggle -- defeating
  -- this feature's whole purpose of hiding common clutter by default.
  fi.visible = false

  -- 2. Already-open state(s): patch live filtered_items directly, in case
  -- neo-tree already built its filesystem-source state from the config
  -- before we got here (shares the config's nested tables in some neo-tree
  -- versions, but not reliably across all of them — patch explicitly either way).
  local ok_mgr, mgr = pcall(require, "neo-tree.sources.manager")
  if ok_mgr and type(mgr._get_all_states) == "function" then
    for _, state in ipairs(mgr._get_all_states()) do
      if state.filtered_items then
        state.filtered_items.hide_by_name =
          merge_hide_by_name(state.filtered_items.hide_by_name, names)
        state.filtered_items.visible = false
      end
    end
  end

  if type(adapter.refresh) == "function" then
    vim.defer_fn(function()
      pcall(adapter.refresh)
    end, 100)
  end
end

-- ── Dim fallback (for adapters without a native hide API) ─────────────────────

local _ns = vim.api.nvim_create_namespace("filetree_ignore_list")

---@param names string[]
---The own tree's decorator for ignored names; nil on every other backend.
---@type Filetree.Decorate.Nodes|nil
local _decor = nil

local function apply_dim(names)
  local set = {}
  for _, n in ipairs(names) do
    set[n:lower()] = true
  end

  local function render(bufnr)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, _ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      local name = (line:match("([^/\\%s]+)%s*$") or ""):lower()
      if name ~= "" and set[name] then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, i - 1, 0, {
          line_hl_group = "Comment",
          priority = 89,
        })
      end
    end
  end

  -- Was pattern-filtered to `neo-tree://*`/`NvimTree_*`, i.e. filtered in C.
  -- The `:tree` scope is the same question asked from Lua, and the ~30 us it
  -- costs on a TextChanged that is not in the tree is not a number anyone
  -- perceives -- see `filetree.util.bufevents`.
  bufevents.register("ignore_list", { "BufEnter:tree", "TextChanged:tree" }, {
    desc = "[filetree] Dim ignored entries in the tree",
    load = function(ctx)
      render(ctx.buf)
    end,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeIgnoreListConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end

  local names = resolve_names(config.names)
  if #names == 0 then return end

  _names_set = {}
  for _, name in ipairs(names) do
    _names_set[name] = true
  end
  _patterns = resolve_patterns()

  if _decor then _decor.remove() end
  _decor = nil
  if adapter.name == "neotree" then
    apply_neotree(names, adapter)
  elseif adapter.name == "native" then
    -- by the node's own name: the dimming below reads the name off the end of the line, where the
    -- own tree writes `/` behind a folder
    local ignored = M.predicate()
    _decor = require("filetree.util.decorate").by_node(
      adapter,
      { name = "ignored", slot = "name", priority = 10 },
      function(node)
        local name = node.path and node.path:match("([^/]+)$") or nil
        if name and ignored(name) then return { hl = "Comment" } end
        return nil
      end
    )
  else
    apply_dim(names)
  end
end

---Ignore predicate for `filetree.util.fs.collect_files`/`collect_folders`'s
---`ignore_fn(name): boolean` parameter, built from the same resolved
---basenames + patterns this feature hides in the tree. Ignores nothing when
---the feature is disabled, so path-output actions transparently follow the
---same on/off toggle as the tree display (one config knob, not two).
---@return fun(name: string): boolean
function M.predicate()
  if not _names_set then
    return function()
      return false
    end
  end
  local names, patterns = _names_set, _patterns
  return function(name)
    if names[name] then return true end
    for _, pat in ipairs(patterns) do
      if name:match(pat) then return true end
    end
    return false
  end
end

function M.teardown()
  bufevents.unregister("ignore_list")
  if _decor then _decor.remove() end
  _decor = nil
  _names_set = nil
  _patterns = {}
end

return M
