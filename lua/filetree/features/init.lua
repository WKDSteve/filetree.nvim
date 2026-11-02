---@module 'filetree.features'
--- Feature registry — the single source of truth mapping feature names to
--- their module paths and categories.
---
--- Every site that loads a feature *by name* — the setup loop and
--- cross-feature lookups — resolves through this
--- module. Feature files therefore live in
--- category subfolders (`features/<category>/<name>/`) without any consumer
--- hard-coding those paths: moving a feature between categories means editing
--- exactly one line here.

local M = {}

---@class FiletreeFeatureInfo
---@field mod      string  Lua module path of the feature.
---@field category string  Grouping category (also the on-disk subfolder).

---@type table<string, FiletreeFeatureInfo>
M.FEATURES = {
  -- ── nav: navigation, reveal, window lifecycle ──────────────────────────────
  tree_traverse = { mod = "filetree.features.nav.tree_traverse", category = "nav" },
  reveal_alt = { mod = "filetree.features.nav.reveal_alt", category = "nav" },
  auto_reveal = { mod = "filetree.features.nav.auto_reveal", category = "nav" },
  auto_resize = { mod = "filetree.features.nav.auto_resize", category = "nav" },
  cwd_sync = { mod = "filetree.features.nav.cwd_sync", category = "nav" },
  cwd_mode = { mod = "filetree.features.nav.cwd_mode", category = "nav" },
  layout_guard = { mod = "filetree.features.nav.layout_guard", category = "nav" },
  no_name_guard = { mod = "filetree.features.nav.no_name_guard", category = "nav" },
  sidebar_guard = { mod = "filetree.features.nav.sidebar_guard", category = "nav" },
  buffer_cycle = { mod = "filetree.features.nav.buffer_cycle", category = "nav" },
  source_switcher = { mod = "filetree.features.nav.source_switcher", category = "nav" },
  tree_toggle = { mod = "filetree.features.nav.tree_toggle", category = "nav" },
  sort_cycle = { mod = "filetree.features.nav.sort_cycle", category = "nav" },
  collapse_all = { mod = "filetree.features.nav.collapse_all", category = "nav" },
  quickpick = { mod = "filetree.features.nav.quickpick", category = "nav" },

  -- ── ui: cosmetic / display ─────────────────────────────────────────────────
  window_style = { mod = "filetree.features.ui.window_style", category = "ui" },
  window_size_cycler = { mod = "filetree.features.ui.window_size_cycler", category = "ui" },
  current_hl = { mod = "filetree.features.ui.current_hl", category = "ui" },
  cursor_hide = { mod = "filetree.features.ui.cursor_hide", category = "ui" },
  tree_reset = { mod = "filetree.features.ui.tree_reset", category = "ui" },
  preview = { mod = "filetree.features.ui.preview", category = "ui" },
  node_info = { mod = "filetree.features.ui.node_info", category = "ui" },
  breadcrumbs = { mod = "filetree.features.ui.breadcrumbs", category = "ui" },
  size_info = { mod = "filetree.features.ui.size_info", category = "ui" },
  link_marker = { mod = "filetree.features.ui.link_marker", category = "ui" },
  broken_link_notify = { mod = "filetree.features.ui.broken_link_notify", category = "ui" },
  opened_sync = { mod = "filetree.features.ui.opened_sync", category = "ui" },
  cheatsheet = { mod = "filetree.features.ui.cheatsheet", category = "ui" },
  context_menu = { mod = "filetree.features.ui.context_menu", category = "ui" },

  -- ── fileops: create / edit / move ──────────────────────────────────────────
  smart_create = { mod = "filetree.features.fileops.smart_create", category = "fileops" },
  copy_move = { mod = "filetree.features.fileops.copy_move", category = "fileops" },
  move = { mod = "filetree.features.fileops.move", category = "fileops" },
  rename_batch = { mod = "filetree.features.fileops.rename_batch", category = "fileops" },
  smart_rename = { mod = "filetree.features.fileops.smart_rename", category = "fileops" },
  create_from_template = {
    mod = "filetree.features.fileops.create_from_template",
    category = "fileops",
  },
  link_create = { mod = "filetree.features.fileops.link_create", category = "fileops" },
  trash = { mod = "filetree.features.fileops.trash", category = "fileops" },
  open_replace = { mod = "filetree.features.fileops.open_replace", category = "fileops" },
  open_variants = { mod = "filetree.features.fileops.open_variants", category = "fileops" },
  buffer_save = { mod = "filetree.features.fileops.buffer_save", category = "fileops" },

  -- ── search: filter / find / grep ───────────────────────────────────────────
  filter = { mod = "filetree.features.search.filter", category = "search" },
  live_search = { mod = "filetree.features.search.live_search", category = "search" },
  find_files = { mod = "filetree.features.search.find_files", category = "search" },
  grep_in_dir = { mod = "filetree.features.search.grep_in_dir", category = "search" },
  spotlight_node = { mod = "filetree.features.search.spotlight_node", category = "search" },

  -- ── paths: clipboard / path tools ──────────────────────────────────────────
  path_copy = { mod = "filetree.features.paths.path_copy", category = "paths" },
  lua_require_copy = { mod = "filetree.features.paths.lua_require_copy", category = "paths" },
  copy_file_list = { mod = "filetree.features.paths.copy_file_list", category = "paths" },
  markdown_links = { mod = "filetree.features.paths.markdown_links", category = "paths" },

  -- ── git ────────────────────────────────────────────────────────────────────
  git_status = { mod = "filetree.features.git.git_status", category = "git" },

  -- ── org: marks / organization ──────────────────────────────────────────────
  marks = { mod = "filetree.features.org.marks", category = "org" },
  session = { mod = "filetree.features.org.session", category = "org" },

  -- ── system: external programs ──────────────────────────────────────────────
  open_in_fm = { mod = "filetree.features.system.open_in_fm", category = "system" },
  open_with = { mod = "filetree.features.system.open_with", category = "system" },
  file_clipboard = { mod = "filetree.features.system.file_clipboard", category = "system" },
  shell_run = { mod = "filetree.features.system.shell_run", category = "system" },
  pdf_open = { mod = "filetree.features.system.pdf_open", category = "system" },
  mdview_open = { mod = "filetree.features.system.mdview_open", category = "system" },
  pdf_create = { mod = "filetree.features.system.pdf_create", category = "system" },
  compress = { mod = "filetree.features.system.compress", category = "system" },

  -- ── lsp: diagnostics / symbols ─────────────────────────────────────────────
  lsp_diagnostics = { mod = "filetree.features.lsp.lsp_diagnostics", category = "lsp" },

  -- ── compare: diff / directory comparison ───────────────────────────────────
  diff = { mod = "filetree.features.compare.diff", category = "compare" },

  -- ── infra: plumbing shared by other features ───────────────────────────────
  ignore_list = { mod = "filetree.features.infra.ignore_list", category = "infra" },
  project_root = { mod = "filetree.features.infra.project_root", category = "infra" },
  file_watcher = { mod = "filetree.features.infra.file_watcher", category = "infra" },
  watcher_quarantine = { mod = "filetree.features.infra.watcher_quarantine", category = "infra" },
  handle_guard = { mod = "filetree.features.infra.handle_guard", category = "infra" },
  tree_integrity = { mod = "filetree.features.infra.tree_integrity", category = "infra" },
  hooks_api = { mod = "filetree.features.infra.hooks_api", category = "infra" },
  safety = { mod = "filetree.features.infra.safety", category = "infra" },
}

---Display order of categories (for docs / health grouping).
---@type string[]
M.CATEGORY_ORDER = {
  "nav",
  "ui",
  "fileops",
  "search",
  "paths",
  "git",
  "org",
  "system",
  "lsp",
  "compare",
  "infra",
}

---Return the module path for a feature, or nil when the name is unknown.
---@param name string
---@return string?
function M.mod_path(name)
  local info = M.FEATURES[name]
  return info and info.mod or nil
end

---Load a feature module by name. Returns nil when the name is unknown or the
---module fails to load.
---@param name string
---@return table?
function M.require(name)
  local ok, mod = M.load(name)
  return ok and mod or nil
end

---Load a feature module by name, preserving `pcall`'s `(ok, module)` return so
---it is a drop-in for the old `pcall(require, "filetree.features.<name>")` call
---sites. Returns `(false, nil)` for an unknown name.
---@param name string
---@return boolean ok, table|nil mod
function M.load(name)
  local info = M.FEATURES[name]
  if not info then return false, nil end
  return pcall(require, info.mod)
end

---Return feature names grouped by category (each list sorted).
---@return table<string, string[]>
function M.by_category()
  local out = {}
  for name, info in pairs(M.FEATURES) do
    out[info.category] = out[info.category] or {}
    table.insert(out[info.category], name)
  end
  for _, list in pairs(out) do
    table.sort(list)
  end
  return out
end

return M
