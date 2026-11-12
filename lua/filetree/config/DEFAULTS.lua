---@module 'filetree.config.DEFAULTS'
--- Plugin-side default configuration.
---
--- The single source of truth for filetree.nvim's built-in defaults. User config
--- passed to `require("filetree").setup({})` is deep-merged on top of this table
--- (see `filetree.config`). Per-feature defaults that are not listed here live in
--- the feature module itself; this table only carries the cross-cutting options
--- and the few features whose defaults are worth surfacing centrally.

---@type FiletreeConfig
return {
  adapter = "auto",
  debug = false, -- true → show notifier.debug(...) messages (troubleshooting)
  ignore_list = true, -- hide .git, node_modules, etc. by default

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README.
  deps_popup = true,

  -- Style for batch-operation progress indicators (trash, paste, …).
  -- "auto" (default) picks fidget.nvim if installed, else notify. Set to
  -- "statusline" to feed lib.nvim.progress's headless statusline registry
  -- instead (`lib.nvim.progress.styles.statusline.active()`). No-op without
  -- lib.nvim.progress installed.
  progress_style = "auto",

  -- Cap on how many nodes one walk of the rendered tree collects. Only a
  -- guard against a single directory expanded with tens of thousands of
  -- entries; the walk is already bounded by what is expanded.
  max_visible_nodes = 5000,

  -- Named root directories that portable paths are written with: a symlink's
  -- target and its messages, a path copied with `[e` and a Markdown link
  -- inserted with insert_path = "env" come out as
  -- `$REPOS_DIR/foo.nvim/x.lua` / `$NVIM_CONFIG_DIR/lua/x.lua` instead of
  -- `E:/repos/foo.nvim/x.lua`, so the text (and the link) means the same on a
  -- machine where the checkout sits on another drive. Explicitly relative
  -- actions (`relative`, `buffer_relative`, Markdown links relative to the
  -- buffer), ones that need a real path (`uri`, open-with, the OS
  -- clipboard) and the absolute copies (`[a`, `]a`, `[R`, `[f`, `[F`,
  -- insert_path = "absolute") are not affected. See docs/configuration.md.
  env_roots = {
    enable = true, -- false: never fold, write plain absolute paths
    -- vars = { "REPOS_DIR" },  -- environment variables whose value is a root
    --                          -- (default; setting it REPLACES the list)
    nvim_config = true, -- $NVIM_CONFIG_DIR = stdpath("config"), no env var needed
    extra = {}, -- more roots: { WKDBOOKS = "E:/repos/WKDBooks", NOTES = function() ... end }
  },

  -- Reference engine: keeps markdown links and require()/import statements
  -- pointing at the right file after a rename/move/delete. One block for every
  -- fileops feature; see lua/filetree/refs/DEFAULTS.lua for the annotated
  -- table and docs/FEATURES/FILEOPS.md for the full description.
  refs = require("filetree.refs.DEFAULTS"),

  -- nvzone/menu integration (opt-in on the host side; entries provided by
  -- filetree.integrations.menu). Group-level opt-out; enable = false yields no
  -- entries. Entries whose feature is disabled are omitted automatically.
  menu = {
    enable = true,
    fileops = true, -- create / rename / batch rename / move / template
    clipboard = true, -- copy / cut / paste / copy to the system clipboard
    delete = true, -- trash
    open = true, -- vsplit / split / tab / system app / file manager
    media = true, -- image/PDF nodes only: preview / open externally / OCR / image info
    paths = true, -- copy path / markdown link
    search = true, -- find files / grep in dir
    info = true, -- node info
    marks = true, -- toggle / mark all / unmark all / clear / show marked
    window = true, -- open/close the tree itself
  },

  -- Sister plugins filetree may hand work to (all opt-OUT, all soft: an absent
  -- plugin is never an error). `pickers = false` keeps find_files / grep_in_dir
  -- off pickers.nvim (they fall back to telescope / fzf-lua / builtin); the
  -- matching switch on pickers.nvim's side is `filetree = { enabled = false }`.
  -- `ui_menu = false` keeps ui.nvim's right-click menu (ui.menu) from offering
  -- the "Open/Close filetree" row in ordinary buffers; `filetree.integrations.
  -- menu` itself (items/submenu/window_entry) stays available to other hosts.
  integrations = {
    pickers = true,
    ui_menu = true,
  },
  features = {
    layout_guard = {
      enabled = true,
      delay_ms = 50,
    },
    no_name_guard = {
      enabled = true,
    },
    -- The tree shares a sidebar slot with `lib.nvim.ui.kit` sidebars: opening one where
    -- the tree is takes the tree off the screen and closing it brings the tree back.
    -- See docs/FEATURES/UI.md#kit-slot.
    kit_slot = {
      enabled = true,
      name = "filetree",
    },
    -- Marks hand their paths to every consumer (copy path incl. `[e`, file lists,
    -- fileops, ...) in the order they were marked; "tree" = sorted by full
    -- path instead. See docs/FEATURES/INTEGRATIONS.md#marks.
    marks = {
      order = "marked",
    },
    -- Warn when a just-opened buffer turns out to be a dangling symlink's
    -- target -- otherwise indistinguishable from any other empty [New]
    -- buffer. See docs/FEATURES/UI.md#broken-link-notify.
    broken_link_notify = {
      enabled = true,
    },
    -- Keep the tree in its sidebar: a buffer that lands there (a stray
    -- `:buffer`, a tabline mouse-click, another plugin's `:edit`) is moved to
    -- an editor window and the tree is put back, instead of neo-tree reopening
    -- the sidebar on the wrong side. neo-tree only; a no-op otherwise.
    -- See docs/FEATURES/NAVIGATION.md#sidebar-guard.
    sidebar_guard = {
      enabled = true,
      -- Refuse the switch with `winfixbuf` rather than redirecting it. Off by
      -- default: it also refuses legitimate opens from plugins that do not
      -- check the flag, which then fail with `E1513` and do not open at all.
      winfixbuf = false,
    },
    cwd_sync = {
      enabled = false,
      debounce_ms = 150,
      parent_levels = 0,
      keep_focus = true,
      change_dir = true, -- actually chdir; never prompts
      reveal = true, -- also reveal/root the tree ourselves. Set false when the
      -- tree plugin already follows the cwd (e.g. neo-tree
      -- bind_to_cwd + follow_current_file) so we don't fight it.
      use_project_root = true, -- target the detected project root, not just the file's dir
      root_markers = { ".git" }, -- anchor cwd to nearest ancestor with one of these
      -- (cached); false disables. Prevents frequent cwd jumps.
    },
    -- Root policy in front of cwd_sync. Enabled but inert: mode "follow" means
    -- "no policy", and cwd_mode then stays out of cwd_sync's resolution
    -- entirely. Switch modes at runtime with :Filetree cwd …
    --
    -- The table itself lives with the feature, and is required rather than
    -- copied: this file used to carry a hand-maintained subset of it and had
    -- already fallen behind — `nearest`'s fifteen package markers, a whole
    -- mode's configuration surface, appeared here as if it did not exist. Same
    -- arrangement as `refs` above.
    cwd_mode = require("filetree.features.nav.cwd_mode.DEFAULTS"),
    current_hl = {
      enabled = false,
      file_hl = { fg = "#7aa2f7", bold = true },
      parent_hl = { fg = "#565f89" },
      debounce_ms = 100,
    },
    safety = {
      enabled = false,
      backup_dir = nil,
      max_backups = 5,
      dry_run = false,
    },
  },
}
