---@meta
---@module 'filetree.@types.config'
--- Type declarations for filetree.nvim's user-facing configuration table.

---@alias FiletreeBuiltinAlias
---| "Ft"       Short alias registered by default.
---| "FT"       Uppercase variant.
---| "Filetree" Original full name (use as alias when renaming).
---| "Tree"     Short alternative.
---| "NT"       "NeoTree" shorthand.
---| "FTree"    Verbose short form.

---@class FiletreeCommandConfig
---@field name    string                             Name for the user command (default: "Filetree").
---@field aliases (FiletreeBuiltinAlias|string)[]?   Aliases to also register. Omit to keep the default :Ft alias.

---@class FiletreeMenuConfig
---@field enable    boolean?  Provide nvzone/menu entries at all (default true).
---@field fileops   boolean?  create / rename / batch rename / move / template (default true).
---@field clipboard boolean?  copy / cut / paste (default true).
---@field delete    boolean?  trash (default true).
---@field open      boolean?  vsplit / split / tab / system app / file manager (default true).
---@field media     boolean?  image/PDF nodes only: preview / open externally / OCR / image info (default true).
---@field paths     boolean?  copy path / markdown link (default true).
---@field search    boolean?  find files / grep in dir (default true).
---@field info      boolean?  node info (default true).
---@field marks     boolean?  toggle / mark all / unmark all / clear / show marked (default true).
---@field window    boolean?  open/close the tree itself (default true).

--- The **resolved** configuration, as `config.get()` returns it and as every
--- consumer downstream of `setup()` receives it: `config.DEFAULTS`, then the
--- user's table, deep-merged and normalized. The nine fields DEFAULTS carries
--- are therefore always present -- which this class now says, instead of
--- marking every field optional and leaving each reader to re-check what
--- `setup()` already guaranteed. The five that DEFAULTS does not carry stay
--- optional, because nothing fills them in.
---
--- `FiletreeOpts` below is the partial shape a caller hands to `setup()`.
---@class FiletreeConfig
---@field adapter           FiletreeAdapterName|"auto"       Which adapter to use. "auto" picks the first available one.
---@field debug             boolean                          true -> show notifier.debug(...) messages for troubleshooting (default false).
---@field features          FiletreeFeaturesConfig
---@field keymaps           table<string,string|false>?      Global keymap remap: { ["<old>"] = "<new>" } or { ["<key>"] = false } to disable.
---@field adapter_keymaps   table<string,string|false>?      Override the adapter's own native keymaps: false -> <Nop>, string -> remap target. Applied after the adapter sets its keymaps. Example: { ["i"] = false } noops neotree's built-in `i` (toggle-info).
---@field command           FiletreeCommandConfig|string|nil User command name (string) or config table. Default: "Filetree" + "Ft" alias.
---@field autocmds          table<string,false>?             Disable per-feature autocmds: { auto_reveal = false }. Sets feature.autocmds_enabled = false.
---@field ignore_list       boolean|string[]                 true (default) = hide common dirs (.git, node_modules...); false = show all; string[] = custom list.
---@field menu              FiletreeMenuConfig               nvzone/menu integration entries (group-level opt-out; entries provided by filetree.integrations.menu).
---@field integrations      FiletreeIntegrationsConfig       Sister-plugin integrations (all opt-out, all soft).
---@field confirmations     boolean|FiletreeConfirmationsConfig|nil  Confirmable actions: paste/rename_batch default to *no* prompt, delete defaults to *prompt*. true/false applies to all three at once; a table applies per action, e.g. { delete = false } to opt out of just the delete prompt. A feature's own `features.<name>.confirm` (if explicitly set) always wins over this.
---@field deps_popup        boolean                          Show the lib.nvim.deps "declared tools" popup once, ever, on first setup() after install (default true; needs lib.nvim.deps -- a no-op without it).
---@field refs              FiletreeRefsConfig               Reference engine: what happens to markdown links and require()/import statements when a file is renamed, moved or deleted. See @types/refs.lua.
---@field progress_style    Lib.Progress.Style               Style for batch-operation progress indicators (trash, paste, ...): "auto" (default) | "notify" | "statusline" | "fidget" | "float" | "kit". Needs lib.nvim.progress -- a no-op without it.
---@field max_visible_nodes integer                          Cap on nodes collected from the rendered tree in one walk (default 5000). Only a guard against a pathologically large expanded directory; raise it if a picker or a marks operation ever reports being capped.
---@field env_roots         FiletreeEnvRoots                 Named roots (`$REPOS_DIR`, `$NVIM_CONFIG_DIR`, your own) that portable paths are written with: inserted links, symlink targets, the `[e` copy (absolute copies stay real). `enable = false` turns it off; `extra` adds roots. See docs/configuration.md.

---Named root directories folded into (and expanded out of) absolute paths --
---see `filetree.util.env_roots`. All fields optional.
---@class FiletreeEnvRoots
---@field enable?      boolean  Master switch (default true). false = every action that would write `$REPOS_DIR/x` writes the plain absolute path again.
---@field vars?        string[] Environment variable names whose value is a root (default `{ "REPOS_DIR" }`). Replaces the default list; an unset variable is skipped.
---@field nvim_config? boolean  Also fold `$NVIM_CONFIG_DIR`, backed by `vim.fn.stdpath("config")` -- no environment variable of that name needs to exist (default true).
---@field extra?       table<string, string|(fun(): string)>  More named roots, `NAME = "/abs/path"` (or a function returning one) -- no environment variable needed. A name here overrides a `vars` entry of the same name.

---@class FiletreeIntegrationsConfig
---@field pickers? boolean  Let find_files / grep_in_dir (and `tf`/`tg`) run through pickers.nvim when it is installed (default true). pickers.nvim has the matching switch `filetree = { enabled = false }`.
---@field ui_menu? boolean  Let ui.nvim's right-click menu (`ui.menu`) offer the "Open/Close filetree" row in ordinary buffers (default true). `filetree.integrations.menu` stays available to any other host.

--- What `require("filetree").setup({})` accepts: any subset of the above.
---@class FiletreeOpts
---@field adapter?          FiletreeAdapterName|"auto"       Which adapter to use. "auto" picks the first available one.
---@field debug             boolean?                         true → show notifier.debug(...) messages for troubleshooting (default false).
---@field features?         FiletreeFeaturesConfig
---@field keymaps           table<string,string|false>?      Global keymap remap: { ["<old>"] = "<new>" } or { ["<key>"] = false } to disable.
---@field adapter_keymaps   table<string,string|false>?      Override the adapter's own native keymaps: false → <Nop>, string → remap target. Applied after the adapter sets its keymaps. Example: { ["i"] = false } noops neotree's built-in `i` (toggle-info).
---@field command           FiletreeCommandConfig|string|nil User command name (string) or config table. Default: "Filetree" + "Ft" alias.
---@field autocmds          table<string,false>?             Disable per-feature autocmds: { auto_reveal = false }. Sets feature.autocmds_enabled = false.
---@field ignore_list       boolean|string[]|nil             true (default) = hide common dirs (.git, node_modules…); false = show all; string[] = custom list.
---@field menu              FiletreeMenuConfig?              nvzone/menu integration entries (group-level opt-out; entries provided by filetree.integrations.menu).
---@field integrations?    FiletreeIntegrationsConfig       Sister-plugin integrations (all opt-out, all soft).
---@field confirmations     boolean|FiletreeConfirmationsConfig|nil  Confirmable actions: paste/rename_batch default to *no* prompt, delete defaults to *prompt*. true/false applies to all three at once; a table applies per action, e.g. { delete = false } to opt out of just the delete prompt. A feature's own `features.<name>.confirm` (if explicitly set) always wins over this.
---@field deps_popup        boolean?                         Show the lib.nvim.deps "declared tools" popup once, ever, on first setup() after install (default true; needs lib.nvim.deps — a no-op without it).
---@field refs              FiletreeRefsConfig?              Reference engine: what happens to markdown links and require()/import statements when a file is renamed, moved or deleted. See @types/refs.lua.
---@field progress_style    Lib.Progress.Style?              Style for batch-operation progress indicators (trash, paste, …): "auto" (default) | "notify" | "statusline" | "fidget" | "float" | "kit". Needs lib.nvim.progress — a no-op without it.
---@field max_visible_nodes integer?                        Cap on nodes collected from the rendered tree in one walk (default 5000). Only a guard against a pathologically large expanded directory; raise it if a picker or a marks operation ever reports being capped.
---@field env_roots         FiletreeEnvRoots?                Named roots (`$REPOS_DIR`, `$NVIM_CONFIG_DIR`, your own) that portable paths are written with: inserted links, symlink targets, the `[e` copy (absolute copies stay real). `enable = false` turns it off; `extra` adds roots. See docs/configuration.md.

---@class FiletreeConfirmationsConfig
---@field paste        boolean?  copy_move's paste-staged-nodes prompt (default false).
---@field delete       boolean?  trash's send-to-trash prompt (default false).
---@field rename_batch boolean?  rename_batch's apply-plan prompt (default false).

---@class FiletreeFeaturesConfig
---@field ignore_list         FiletreeIgnoreListConfig?
---@field cursor_hide         FiletreeCursorHideConfig?
---@field tree_reset          FiletreeTreeResetConfig?
---@field open_replace        FiletreeOpenReplaceConfig?
---@field open_variants       FiletreeOpenVariantsConfig?
---@field reveal_alt          FiletreeRevealAltConfig?
---@field source_switcher     FiletreeSourceSwitcherConfig?
---@field tree_toggle         FiletreeTreeToggleConfig?
---@field collapse_all        FiletreeCollapseAllConfig?
---@field quickpick           FiletreeQuickpickConfig?
---@field buffer_save         FiletreeBufferSaveConfig?
---@field window_size_cycler  FiletreeWindowSizeCyclerConfig?
---@field open_in_fm          FiletreeOpenInFmConfig?
---@field shell_run           FiletreeShellRunConfig?
---@field layout_guard        FiletreeLayoutGuardConfig?
---@field no_name_guard       FiletreeNoNameGuardConfig?
---@field sidebar_guard       FiletreeSidebarGuardConfig?
---@field buffer_cycle        FiletreeBufferCycleConfig?
---@field cwd_sync            FiletreeCwdSyncConfig?
---@field cwd_mode            FiletreeCwdModeOpts?
---@field current_hl          FiletreeCurrentHlConfig?
---@field safety              FiletreeSafetyConfig?
---@field trash               FiletreeTrashConfig?
---@field watcher_quarantine  FiletreeWatcherQuarantineConfig?
---@field handle_guard        FiletreeHandleGuardConfig?
---@field tree_integrity      FiletreeTreeIntegrityConfig?
---@field marks               FiletreeMarksConfig?
---@field diff                FiletreeDiffConfig?
---@field context_menu        FiletreeContextMenuConfig?
---@field project_root        FiletreeProjectRootConfig?
---@field git_status          FiletreeGitStatusConfig?
---@field preview             FiletreePreviewConfig?
---@field rename_batch        FiletreeRenameBatchConfig?
---@field session             FiletreeSessionConfig?
---@field copy_move           FiletreeCopyMoveConfig?
---@field find_files          FiletreeFindFilesConfig?
---@field filter              FiletreeFilterConfig?
---@field grep_in_dir         FiletreeGrepInDirConfig?
---@field breadcrumbs         FiletreeBreadcrumbsConfig?
---@field lsp_diagnostics      FiletreeLspDiagnosticsConfig?
---@field size_info            FiletreeSizeInfoConfig?
---@field link_marker          FiletreeLinkMarkerConfig?
---@field broken_link_notify   FiletreeBrokenLinkNotifyConfig?
---@field opened_sync          FiletreeOpenedSyncConfig?
---@field cheatsheet           FiletreeCheatsheetConfig?
---@field create_from_template FiletreeCreateFromTemplateConfig?
---@field link_create           FiletreeLinkCreateConfig?
---@field auto_reveal          FiletreeAutoRevealConfig?
---@field auto_resize          FiletreeAutoResizeConfig?
---@field file_watcher         FiletreeFileWatcherConfig?
---@field hooks_api            FiletreeHooksApiConfig?
---@field open_with               FiletreeOpenWithConfig?
---@field file_clipboard          FiletreeFileClipboardConfig?
---@field pdf_open               FiletreePdfOpenConfig?
---@field mdview_open            FiletreeMdviewOpenConfig?
---@field pdf_create              FiletreePdfCreateConfig?
---@field compress                FiletreeCompressConfig?
---@field move                    FiletreeMoveConfig?
---@field smart_rename            FiletreeSmartRenameConfig?
---@field path_copy               FiletreePathCopyConfig?
---@field live_search             FiletreeLiveSearchConfig?
---@field node_info               FiletreeNodeInfoConfig?
---@field tree_traverse           FiletreeTreeTraverseConfig?
---@field lua_require_copy        FiletreeLuaRequireCopyConfig?
---@field spotlight_node          FiletreeSpotlightNodeConfig?
---@field sort_cycle              FiletreeSortCycleConfig?
---@field copy_file_list          FiletreeCopyFileListConfig?
---@field markdown_links          FiletreeMarkdownLinksConfig?
---@field smart_create            FiletreeSmartCreateConfig?
---@field window_style            FiletreeWindowStyleConfig?

-- ── layout_guard ──────────────────────────────────────────────────────────────

---@class FiletreeLayoutGuardConfig
---@field enabled    boolean
---@field delay_ms   integer   Milliseconds before guard fires after a window closes (default 50).

-- ── sidebar_guard ─────────────────────────────────────────────────────────────

---@class FiletreeSidebarGuardConfig
---@field enabled    boolean  Keep the tree in its sidebar: a foreign buffer that lands there
---                           is moved to an editor window and the tree is put back, instead of
---                           neo-tree reopening the sidebar on the wrong side (default true;
---                           neo-tree only, else a no-op).
---@field winfixbuf? boolean  Refuse the switch with `winfixbuf` instead of redirecting it
---                           (default false, Neovim 0.10+). The refusal also hits plugins that
---                           open a file without checking the flag — they get `E1513` and the
---                           file does not open — so the redirect is the default.

-- ── no_name_guard ─────────────────────────────────────────────────────────────

---@class FiletreeNoNameGuardConfig
---@field enabled  boolean  Redirect stray [No Name] editor windows to a real buffer (default true).
---                         Two passes: a BufWinEnter handler tied to the window actually being
---                         focused, plus a BufAdd/BufDelete/BufWipeout sweep across every window
---                         (all tabs) that also catches a stray buffer sitting in some OTHER window
---                         that never itself refires BufWinEnter. Both always skip the tree's own
---                         window.

-- ── cwd_sync ──────────────────────────────────────────────────────────────────

---@class FiletreeCwdSyncConfig
---@field enabled?          boolean
---@field debounce_ms?      integer   Debounce delay for buffer-change events (default 150).
---@field parent_levels?    integer   How many parent dirs to ascend when revealing (default 0).
---@field keep_focus?       boolean   Keep focus in the editor window after reveal (default true).
---@field change_dir?       boolean   Actually change Neovim's cwd (default true). Never prompts —
---                                  always applies silently.
---@field reveal?           boolean   Also reveal/root the tree from cwd_sync (default true). Set
---                                  false when the tree plugin already follows the cwd (e.g.
---                                  neo-tree bind_to_cwd + follow_current_file) so the two
---                                  reveals don't fight and land on the file's parent.
---@field use_project_root? boolean   Target the detected project root instead of the file's
---                                  immediate parent directory (default true; see project_root).
---@field root_markers?     string[]|false  Marker names to anchor the cwd to the nearest ancestor
---                                  containing one (default { ".git" }), via a cached lib.nvim
---                                  finder. FALLBACK ONLY: when the cwd_mode feature is enabled
---                                  (the default) its marker walk decides, so that the cwd and
---                                  every project-scoped feature agree on one root — configure
---                                  `cwd_mode.project.markers` instead. This applies when cwd_mode
---                                  is disabled. `false` disables it too (falls back to
---                                  use_project_root / parent dir).

-- ── cwd_mode ──────────────────────────────────────────────────────────────────

---Which root policy is active. See features/nav/cwd_mode.
---@alias FiletreeCwdModeName
---| "follow"     No policy — cwd_sync's own resolution applies unchanged.
---| "project"    Hold the current project root until a file outside it is opened.
---| "nearest"    Like "project", but the nearest package boundary instead of the VCS root.
---| "lock"       Pin the cwd to one directory; buffer switches never move it.
---| "manual"     Nothing automatic; explicit action only.
---| "tree_leads" The tree root is the truth and the cwd follows it, not the buffer.

---What cwd_mode wants cwd_sync to do for one buffer.
---@class FiletreeCwdDecision
---@field root   string?   Directory to use for BOTH the cwd and the tree root (nil = let cwd_sync resolve).
---@field chdir  boolean   May the cwd be changed to `root`?
---@field reveal boolean   May the tree be re-rooted / the file revealed?

--- Every field below is optional: the feature deep-extends its own defaults
--- with whatever the user passes, so a partial table is the normal case.

---@class FiletreeCwdModeProjectConfig
---@field markers   string[]? Root markers (default { ".git", ".hg", ".svn" }). Adding
---                           package.json/Cargo.toml turns this into nearest-package
---                           (monorepo) behaviour.
---@field skip_dirs string[]? Directory names that can never hold a root
---                           (default { "node_modules", ".venv", "vendor" }). A file inside
---                           one resolves to the project *above* it.
---@field max_depth integer?  Maximum levels to walk upward (default: unbounded).
---@field sticky    boolean?  Keep the current root when a file has none of its own —
---                           a scratch file in /tmp does not drag the session out (default true).

---@class FiletreeCwdModeNearestConfig
---@field markers string[]? Package-boundary markers for `nearest` mode (default
---                         package.json, Cargo.toml, go.mod, pyproject.toml,
---                         setup.py, *.rockspec, mix.exs, build.zig,
---                         CMakeLists.txt, and `.git` as a last resort).
---                         `skip_dirs` and `max_depth` are shared with `project`.

---@class FiletreeCwdModeLockConfig
---@field enforce            boolean?  Revert foreign cwd changes via lib.nvim.fs.dir_guard (default true).
---@field follow_manual_root boolean?  Re-rooting the tree by hand (`+`/`-`) moves the lock
---                                    instead of being reverted (default true).

---@alias FiletreeCwdModeIndicatorStyle
---| "text"    Full words: PROJECT, PKG, LOCK, MANUAL, TREE (default).
---| "short"   First-letter abbreviations: P, N, L, M, T.
---| "numeric" One digit per mode, 0 (follow) through 5 — the only style that
---            shows anything for `follow`, since the row's whole point is
---            "which of the N states am I in".
---| "icon"    A single Nerd Font glyph, no text.

---@class FiletreeCwdModeIndicatorConfig
---@field enabled        boolean? Show the mode badge in the tree window (default true).
---@field mode           Lib.UI.Statusline.Mode?  "auto" (default), "statusline" or "float".
---@field align          Lib.UI.Statusline.Align? Placement in the line (default "left").
---@field show_path      ("never"|"lock"|"always")?  Append the pinned path (default "lock").
---@field style          FiletreeCwdModeIndicatorStyle?  Which label table below is read (default "text").
---@field labels         table<FiletreeCwdModeName, string>?  Badge text per mode for style="text"; "" hides it.
---@field labels_short   table<FiletreeCwdModeName, string>?  Badge text per mode for style="short".
---@field labels_numeric table<FiletreeCwdModeName, string>?  Badge text per mode for style="numeric".
---@field icons          table<FiletreeCwdModeName, string>?  Badge text per mode for style="icon".
---@field hl             table<FiletreeCwdModeName, string>?  Highlight group per mode (shared across styles).

--- The **resolved** cwd_mode config, as the feature holds it after
--- `setup()`: `cwd_mode.DEFAULTS` deep-extended with whatever the user
--- passed. DEFAULTS carries every field below, so every field is present --
--- which is why the sub-tables are not optional here. Marking them optional
--- was what made `indicator` read as maybe-nil at five call sites inside
--- `badge_text()`, each of which then had to re-check a value `setup()`
--- had already guaranteed.
---
--- `FiletreeCwdModeOpts` below is the partial shape a caller passes in.
---@class FiletreeCwdModeConfig : FiletreeCwdModeOpts
---@field enabled          boolean
---@field mode             FiletreeCwdModeName Mode to start in (default "follow" — inert).
---@field scope            Lib.Fs.Chdir.Scope  Directory scope: "global" (default), "tab" or "win".
---@field project          FiletreeCwdModeProjectConfig
---@field nearest          FiletreeCwdModeNearestConfig
---@field lock             FiletreeCwdModeLockConfig
---@field reveal_outside   "skip"|"reveal"  What to do when the focused file is outside the held
---                                         root: leave the tree alone (default) or reveal anyway.
---@field persist          boolean  Remember mode, scope and a lock's pin per project
---                                 (lib.nvim.store.project), keyed by the directory
---                                 Neovim was started in. Default false.
---@field indicator        FiletreeCwdModeIndicatorConfig
---@field cycle            FiletreeCwdModeName[]  Order used by `:Filetree cwd toggle`.
---@field keymap_cycle     string  Tree-buffer key that cycles modes (default "L"; "" disables).
---@field keymap_lock_here string  Tree-buffer key that locks onto the node under the cursor (default "gp").

--- What `setup({ features = { cwd_mode = ... } })` accepts: any subset.
---@class FiletreeCwdModeOpts
---@field enabled?         boolean
---@field mode             FiletreeCwdModeName? Mode to start in (default "follow" — inert).
---@field scope            Lib.Fs.Chdir.Scope?  Directory scope: "global" (default), "tab" or "win".
---@field project          FiletreeCwdModeProjectConfig?
---@field nearest          FiletreeCwdModeNearestConfig?
---@field lock             FiletreeCwdModeLockConfig?
---@field reveal_outside   ("skip"|"reveal")?  What to do when the focused file is outside the held
---                                          root: leave the tree alone (default) or reveal anyway.
---@field persist          boolean?  Remember mode, scope and a lock's pin per project
---                                 (lib.nvim.store.project), keyed by the directory
---                                 Neovim was started in. Default false.
---@field indicator        FiletreeCwdModeIndicatorConfig?
---@field cycle            FiletreeCwdModeName[]?  Order used by `:Filetree cwd toggle`.
---@field keymap_cycle     string?  Tree-buffer key that cycles modes (default "L"; "" disables).
---@field keymap_lock_here string?  Tree-buffer key that locks onto the node under the cursor (default "gp").

-- ── current_hl ────────────────────────────────────────────────────────────────

---@class FiletreeCurrentHlConfig
---@field enabled?     boolean
---@field file_hl?     string|table  Highlight spec for the current file node.
---@field parent_hl?   string|table  Highlight spec for the parent directory node.
---@field debounce_ms? integer
---@field icon         string?  Sign-column marker placed on the current file's line (nil = off). e.g. "▸".
---@field icon_hl      string?  Highlight group for the icon (default: the file_hl group).

--- ── opened_sync ───────────────────────────────────────────────────────────────
---@class FiletreeOpenedSyncConfig
---@field enabled?     boolean
---@field debounce_ms? integer  Delay (ms) before re-rendering after a buffer open/close (default 60).

-- ── safety ────────────────────────────────────────────────────────────────────

---@class FiletreeSafetyConfig
---@field enabled?       boolean
---@field backup_dir     string?  Absolute path for backups. Defaults to stdpath("data")/filetree/backups.
---@field max_backups?   integer  Maximum number of backup copies kept per file (default 5).
---@field dry_run?       boolean  Log operations without executing them (default false).

-- ── trash ─────────────────────────────────────────────────────────────────────

---@class FiletreeTrashConfig
---@field enabled?             boolean
---@field mode?                "trash"|"permanent"  "trash" (OS trash/recycle bin, undoable via `U`/history) or "permanent" (fs delete, no undo). Default: "trash".
---@field confirm?             boolean  Ask before trashing (default true, unlike paste/rename_batch; see top-level `confirmations`).
---@field use_safety?          boolean  Create a backup before trashing (default false).
---@field dry_run?             boolean  Log without actually trashing (default false).
---@field max_history          integer? How many trash operations stay undoable (default 50; 0 = unlimited).
---@field check_markdown_refs? boolean  **Deprecated** — migrated to `refs.on_delete` (`false` → `"off"`). See @types/refs.lua.
---@field refs_picker_prefer?  "auto"|"telescope"|"fzf-lua"|"quickfix"  **Deprecated** — migrated to `refs.picker`.
---@field keymap               string?  Trash current node / all marked (default "d").
---@field keymap_undo          string?  Undo last trash operation (default "U").
---@field keymap_history       string?  Show trash history (default "<leader>th").

-- ── watcher_quarantine ────────────────────────────────────────────────────────

---@class FiletreeWatcherQuarantineConfig
---@field enabled?     boolean
---@field duration_ms? integer  Default quarantine duration in ms (default 500).
---@field silent?      boolean  Suppress quarantine notifications (default true).

-- ── handle_guard ──────────────────────────────────────────────────────────────

---@class FiletreeHandleGuardConfig
---@field enabled boolean  Install lib.nvim.neotree.watch so fileops can release
---                        neo-tree's directory-watcher handles before a
---                        rename/delete (fixes the Windows file-lock at the
---                        source, unlike watcher_quarantine which only hides the
---                        error). neo-tree adapter + Windows/WSL only; a no-op
---                        elsewhere. Opt-in (default off).

-- ── tree_integrity ────────────────────────────────────────────────────────────

---@class FiletreeTreeIntegrityConfig
---@field enabled? boolean  Wrap nui.nvim's `Tree:set_nodes` so re-setting a
---                         subtree with live nodes cannot corrupt neo-tree's
---                         node index ("Error setting nodes: attempt to index
---                         local 'node' (a nil value)", repeating until the tree
---                         is re-opened). neo-tree adapter only; default **on**.
---@field silent?  boolean  Suppress the debug note emitted when a corrupt
---                         subtree is healed (default true).

-- ── marks ─────────────────────────────────────────────────────────────────────

---@class FiletreeMarksConfig
---@field enabled?          boolean
---@field indicator?        string   Character shown before marked nodes (default "✓").
---@field hl_group?         string   Highlight group for the indicator (default "DiagnosticOk").
---@field keymap            string?  Toggle mark on current node (default "m").
---@field keymap_all        string?  Mark all files in current directory (default "]m").
---@field keymap_unmark_all string? Unmark all files in current directory (default "[m").
---@field keymap_clear      string?  Clear all marks (default "<leader>mc"; not "<C-m>", which is <CR>'s byte).
---@field keymap_show       string?  Show floating list of marked nodes (default "<leader>ms").
---@field keymap_goto       string?  Jump to the Nth marked node, count-prefixed (default "gm").
---@field keymap_next       string?  Jump to the next marked node, wrapping (default "]M").
---@field keymap_prev       string?  Jump to the previous marked node, wrapping (default "[M").
---@field auto_clear_ms     integer? Clear all marks after this many ms without mark activity
---                                  (toggle, mark/unmark all, visual mark, goto/next/prev, show);
---                                  default 60000 (60s). 0 disables the timeout.
---@field order             "marked"|"tree"? Order every consumer (copy path incl. `[e`, file lists, ops) gets the
---                                  marked paths in: "marked" (default) = the order they were marked,
---                                  re-marking moves a path to the end; "tree" = sorted by full path.

-- ── diff ──────────────────────────────────────────────────────────────────────

---@class FiletreeDiffConfig
---@field enabled  boolean
---@field split    "vsplit"|"split"  Layout for diff windows (default "vsplit").
---@field keymap   string?           Key inside tree to stage/diff current node (default "D").

-- ── context_menu ─────────────────────────────────────────────────────────────

---@class FiletreeContextMenuConfig
---@field enabled? boolean          Bind the mouse trigger (default true — opt-out).
---@field keymap   string|false?    Mouse trigger inside the tree buffer (default "<RightMouse>").
---                                 false disables the binding without disabling the feature outright.
---                                 Opens the menu through `ui.contextmenu` (nvzone/menu when it is
---                                 installed, `ui.kit.menu` otherwise) with the entries from
---                                 `filetree.integrations.menu.items()`; which entries appear is
---                                 controlled by the top-level `menu` config, not this one.
---                                 Only a click on a node row opens it; a click below the last
---                                 node, on the tree's statusline / separator or in another
---                                 window does nothing.

-- ── project_root ──────────────────────────────────────────────────────────────

---@class FiletreeProjectRootConfig
---@field enabled?          boolean
---@field markers?          string[]          Files/dirs that signal a project root.
---@field fallback?         "cwd"|"parent"    What to use when no root is found (default "parent").
---@field cache?            boolean           Cache resolved roots per directory for the session (default true).
---@field max_cache_entries integer?  How many directories the root cache holds before it is cleared in one shot (default 1000).

-- ── create_from_template ──────────────────────────────────────────────────────

---@alias FiletreeCreateFromTemplatePrefer
---| '"auto"'      Real fuzzy search + native content preview via pickers.nvim, when installed
---                 (its own telescope > fzf > snacks priority). Falls back to "builtin" otherwise.
---| '"telescope"' Force pickers.nvim's telescope engine.
---| '"fzf"'       Force pickers.nvim's fzf-lua engine.
---| '"snacks"'    Force pickers.nvim's snacks engine.
---| '"builtin"'   Always use the original kit.picker/vim.ui.select flow (plain substring match,
---                 no preview) — the only option that supports the <M-j>/<M-k> reorder keymaps.

---@class FiletreeCreateFromTemplateConfig
---@field enabled?      boolean
---@field keymap        string?   Key inside tree (default "A" — the smart_create "a" counterpart, template-driven).
---@field template_dir  string?   Custom template directory. Defaults to stdpath("data")/filetree/templates/.
---@field author        string?   Author name for ${author} substitution.
---@field open_after?   boolean   Open created file in editor (default true).
---@field prefer        FiletreeCreateFromTemplatePrefer?  Which picker renders template selection (default "auto").
---                                pickers.nvim is a soft dependency — absent, and this always behaves like "builtin".

-- ── auto_reveal ───────────────────────────────────────────────────────────────

---@class FiletreeAutoRevealConfig
---@field enabled?      boolean
---@field debounce_ms?  integer   Delay after BufEnter (default 150ms).
---@field ignore_ft?    string[]  Filetypes that never trigger reveal.
---@field only_if_open? boolean   Only reveal when tree window is visible (default true).
---@field sync_on_enter? boolean  Move the tree cursor onto the current file's node when the tree window is entered (default true).

-- ── lsp_diagnostics ──────────────────────────────────────────────────────────

---@class FiletreeLspDiagnosticsConfig
---@field enabled        boolean
---@field show_errors    boolean   Show error count (default true).
---@field show_warnings  boolean   Show warning count (default true).
---@field show_hints     boolean   Show hint count (default false).
---@field show_info      boolean   Show info count (default false).
---@field format         fun(counts: table): string?  Custom formatter. Return nil to hide. Default: per severity the `icons` entry, else the `vim.diagnostic.config().signs.text` glyph, else `E:`/`W:`/`H:`/`I:`, before each count.
---@field icons?         { error?: string, warning?: string, hint?: string, info?: string }  Badge prefix per severity; wins over `signs.text`, blank entries fall through.
---@field debounce_ms    integer   Delay after DiagnosticChanged (default 300ms).

-- ── size_info ─────────────────────────────────────────────────────────────────

---@class FiletreeSizeInfoConfig
---@field enabled     boolean
---@field show_files  boolean  Show file sizes (default true).
---@field show_dirs   boolean  Show directory sizes (default true).
---@field hl_group    string   Highlight group for size text (default "Comment").
---@field dir_async   boolean  Use `du`/PowerShell for dir sizes (default true).

-- ── link_marker ───────────────────────────────────────────────────────────────

---@class FiletreeLinkMarkerSign
---@field text string
---@field hl   string

---@class FiletreeLinkMarkerSigns
---@field symlink FiletreeLinkMarkerSign?  Sign for a resolvable symlink (default "⇢", hl "Special").
---@field broken  FiletreeLinkMarkerSign?  Sign for a dangling symlink, where the adapter can tell
---                                        (neo-tree only; default "⇢!", hl "DiagnosticError").

---@class FiletreeLinkMarkerConfig
---@field enabled?     boolean
---@field show_target? boolean  Also show the link's target after the sign (default false).
---@field target_hl?   string   Highlight group for the target text (default "Comment").
---@field signs?       FiletreeLinkMarkerSigns?

-- ── broken_link_notify ────────────────────────────────────────────────────────

---@class FiletreeBrokenLinkNotifyConfig
---@field enabled?  boolean  Warn when a just-opened buffer turns out to be a
---                          dangling symlink's target (default true). Opening one
---                          otherwise looks exactly like opening any other
---                          nonexistent path -- a silently empty `[New]` buffer,
---                          no hint why. Backend-agnostic: a single `BufNewFile`
---                          autocmd, not tied to the tree's own `<CR>` or any
---                          particular adapter, so it also catches `gf`, a plain
---                          `:edit`, etc.

-- ── grep_in_dir ───────────────────────────────────────────────────────────────

---@class FiletreeGrepInDirConfig
---@field enabled          boolean
---@field keymap           string?    Key in tree for grep with prompt (default "gr").
---@field keymap_cword     string?    Key in tree for grep cword (default nil, off).
---@field keymap_pickers   string?    Key in tree to force pickers.nvim specifically (default "tg").
---@field keymap_telescope string?    Key in tree to force telescope specifically (default nil, off).
---@field prefer           "auto"|"pickers"|"telescope"|"fzf-lua"|"builtin"
---@field hidden           boolean    Include hidden files (default false).
---@field extra_args       string[]   Additional args passed to rg/grep.

-- ── breadcrumbs ───────────────────────────────────────────────────────────────

---@class FiletreeBreadcrumbsConfig
---@field enabled?   boolean
---@field mode?      "winbar"|"float"|"statusline"  Display mode (default "winbar").
---@field separator? string   Part separator (default "  ").
---@field max_depth? integer  Max number of path segments (default 5).
---@field hl_dir?    string   Highlight group for directory parts (default "Comment").
---@field hl_file?   string   Highlight group for the file/leaf part (default "Normal").
---@field hl_sep?    string   Highlight group for separators (default "NonText").
---@field winbar_hl? string   Background group for the whole winbar (default "WinBar").

-- ── copy_move ─────────────────────────────────────────────────────────────────

---@class FiletreeCopyMoveKeymaps
---@field copy   string?  Stage for copy  (default "c")
---@field cut    string?  Stage for cut   (default "x")
---@field paste  string?  Paste staged    (default "p")
---@field show   string?  Show clipboard  (default "P")
---@field clear  string?  Clear clipboard (default "X")

---@class FiletreeCopyMoveConfig
---@field enabled?             boolean
---@field keymaps              FiletreeCopyMoveKeymaps?
---@field confirm?             boolean  Ask before paste (default false; see top-level `confirmations`).
---@field use_safety?          boolean  Create backup before move (default true).
---@field dry_run?             boolean  Log without executing (default false).
---@field check_markdown_refs? boolean  **Deprecated** — migrated to `refs.on_move` (`false` → `"off"`). See @types/refs.lua.
---@field refs_picker_prefer?  "auto"|"telescope"|"fzf-lua"|"quickfix"  **Deprecated** — migrated to `refs.picker`.

-- ── move ──────────────────────────────────────────────────────────────────────

---@class FiletreeMoveConfig
---@field enabled    boolean
---@field keymap     string?  Move current node / all marked nodes (default "M").
---@field use_safety boolean  Create a backup before moving (default true).
---@field dry_run    boolean  Log the plan without executing it (default false).

-- ── find_files ────────────────────────────────────────────────────────────────

---@class FiletreeFindFilesConfig
---@field enabled          boolean
---@field keymap_tree      string?  Key inside tree buffer (default "f").
---@field keymap_pickers   string?  Key to force pickers.nvim specifically (default "tf").
---@field keymap_telescope string?  Key to force telescope specifically (default nil, off).
---@field keymap_global    string?  Global normal-mode key (default nil).
---@field prefer           "auto"|"pickers"|"telescope"|"fzf-lua"|"mini.pick"|"builtin"
---@field reveal_on_open   boolean  Reveal selected file in tree (default true).
---@field hidden           boolean  Include hidden files (default false).

-- ── filter ────────────────────────────────────────────────────────────────────

---@class FiletreeFilterConfig
---@field enabled?         boolean
---@field keymap           string?  Key inside tree to enter filter mode (default "/").
---@field keymap_clear     string?  Key inside tree to clear an applied filter directly (default "<C-c>").
---@field case_sensitive?  boolean  Case-sensitive matching (default false).
---@field dim_hl_group?    string   Highlight group for non-matching lines (default "Comment").
---@field debounce_ms?     integer  Input debounce delay (default 80ms).

-- ── rename_batch ──────────────────────────────────────────────────────────────

---@class FiletreeRenameBatchConfig
---@field enabled?             boolean
---@field keymap               string?  Normal-mode key inside tree (default "<leader>rb").
---@field confirm?             boolean  Ask for confirmation before renaming (default false; see top-level `confirmations`).
---@field use_safety?          boolean  Create safety backup before renaming (default true).
---@field dry_run?             boolean  Log plan without executing (default false).
---@field check_markdown_refs? boolean  **Deprecated** — migrated to `refs.on_rename` (`false` → `"off"`). See @types/refs.lua.
---@field refs_picker_prefer?  "auto"|"telescope"|"fzf-lua"|"quickfix"  **Deprecated** — migrated to `refs.picker`.

-- ── session ───────────────────────────────────────────────────────────────────

---@class FiletreeSessionConfig
---@field enabled        boolean
---@field auto_save      boolean  Save on VimLeavePre and tree BufHidden (default true).
---@field auto_restore   boolean  Restore on first FileType neo-tree/NvimTree (default true).
---@field max_sessions   integer  Maximum stored project sessions (default 50).

-- ── git_status ────────────────────────────────────────────────────────────────

---@class FiletreeGitStatusSign
---@field text string
---@field hl   string

---@class FiletreeGitStatusConfig
---@field enabled?      boolean
---@field debounce_ms?  integer              Delay between write and re-query (default 300ms).
---@field show_ignored? boolean              Also show ignored files (default false).
---@field signs?        table<string, FiletreeGitStatusSign>?

-- ── preview ───────────────────────────────────────────────────────────────────

---@alias FiletreeImageBackend "auto"|"images.nvim"|"snacks"|"image.nvim"|"system"|false
---@alias FiletreePdfBackend   "pdfport"|"system"|false

---@class FiletreePreviewImageConfig
---@field backend FiletreeImageBackend  "auto" tries images.nvim → snacks → image.nvim → system (default "auto").
---@field float?  { width: number, height: number, viewport?: boolean }|false  <CR> opens images.nvim's zen float at this size (fractions of the editor; <S-Up>/<S-Down> in it step the size), with backend "auto"/"images.nvim" only; `viewport = false` opens it without zoom/pan/mouse/selection/save keys; false = the backend's own view (default { width = 0.66, height = 0.66, viewport = true }).

---@class FiletreePreviewPdfConfig
---@field backend FiletreePdfBackend  "pdfport" tries pdfport.nvim, falls back to system (default "pdfport").

---@class FiletreePreviewConfig
---@field enabled?             boolean
---@field mode?                "buffer"|"float"         Preview target: "buffer" shows the file in the editor window (default); "float" uses a floating window.
---@field highlight?           boolean                  Syntax/treesitter highlighting in the preview (default true).
---@field cursor_debounce_ms   integer?                 Debounce (ms) for the live-update while scrolling the tree (default 80).
---@field keymap               string?                  Normal-mode key: toggle text preview; dispatch image/PDF (default "<Tab>").
---@field keymap_open          string?                  Normal-mode key: dispatch image/PDF; adapter default for other nodes (default "<CR>").
---@field max_lines?           integer                  Max lines to read for text preview (default 40).
---@field max_bytes?           integer                  Buffer mode: a file larger than this many bytes is not loaded for the preview (a notice says so); binary files are never loaded. 0 = no size limit (default 1048576, 1 MiB).
---@field max_width?           integer                  Max floating window width in columns (default 80).
---@field max_height?          integer                  Max floating window height in lines (default 25).
---@field wrap?                boolean                  Enable line wrapping in the preview window (default false).
---@field keymap_scroll_up     string?                  Scroll preview up 1 line (default "<C-b>").
---@field keymap_scroll_down   string?                  Scroll preview down 1 line (default "<C-f>").
---@field keymap_scroll_up10   string?                  Scroll preview up 10 lines (default "<PageUp>").
---@field keymap_scroll_down10 string?                  Scroll preview down 10 lines (default "<PageDown>").
---@field image                FiletreePreviewImageConfig?  Image-open config.
---@field pdf                  FiletreePreviewPdfConfig?    PDF-open config.
---@field system_exts         string[]?                Extensions (any case, leading dot optional) opened with the OS default app on <CR>/<Tab> instead of as a buffer; {} = off (default { "msg", "eml", "oft" }).

-- ── ignore_list ───────────────────────────────────────────────────────────────

---@class FiletreeIgnoreListConfig
---@field enabled boolean     Hide the ignore list (default true). Toggle with adapter's native hide-hidden keymap (e.g. `H` in neotree).
---@field names   string[]?   Basenames to hide. nil = built-in defaults (or lib.nvim list when available).

-- ── file_watcher ─────────────────────────────────────────────────────────────

---@class FiletreeFileWatcherConfig
---@field enabled          boolean
---@field debounce_ms      integer   Event debounce before refresh (default 500ms).
---@field watch_recursive  boolean   Watch subdirectories (default true).
---@field ignore_events    string[]  uv event types to ignore.

-- ── hooks_api ─────────────────────────────────────────────────────────────────

---@class FiletreeHooksApiConfig
---@field enabled boolean

-- ── auto_resize ───────────────────────────────────────────────────────────────

---@class FiletreeAutoResizeBreakpoint
---@field cols  integer  Minimum editor column count to activate this width.
---@field width integer  Tree window width to use.

---@class FiletreeAutoResizeConfig
---@field enabled?     boolean
---@field breakpoints? FiletreeAutoResizeBreakpoint[]
---@field min_width?   integer  Absolute minimum (default 20).
---@field max_width?   integer  Absolute maximum (default 60).

-- ── open_with ─────────────────────────────────────────────────────────────────

---@class FiletreeOpenWithApp
---@field name    string    Display name.
---@field cmd     string    Executable.
---@field args    string[]? Extra args before path.
---@field keymap  string?   Optional tree keymap.

---@class FiletreeOpenWithConfig
---@field enabled  boolean
---@field keymap   string?              System-default open key (default "<leader>sm").
---@field apps     FiletreeOpenWithApp[]  Custom application entries.

-- ── file_clipboard ────────────────────────────────────────────────────────────

---@class FiletreeFileClipboardConfig
---@field enabled?        boolean
---@field keymap?         string    Copy the marked nodes (else the current one) to the OS clipboard as files (default "gy").
---@field preview_limit?  integer   Names listed in the notification (default 5).

-- ── pdf_open ──────────────────────────────────────────────────────────────────

---@alias FiletreePdfOpenMode
---| "buffer"    Extract PDF text into a buffer via pdfport.nvim.
---| "float"     Show extracted text in a floating window via pdfport.nvim.
---| "terminal"  Run pdfport.nvim's conversion in a terminal.
---| "system"    Open in the OS default PDF viewer (no external deps).
---| "picker"    Ask (pdfport.nvim's own chooser: every mode/backend it knows
---              about, plus "system application" — see `filetree.util.pdf`'s
---              `M.pick_open`). Falls back to the system viewer with no
---              prompt when pdfport.nvim is absent.

---@class FiletreePdfOpenConfig
---@field enabled         boolean
---@field default_mode    FiletreePdfOpenMode?  Mode for `keymap_open` (default "buffer"; falls back to system viewer when pdfport.nvim is absent).
---@field keymap_open     string|false?  Open the PDF under the cursor with `default_mode` (default "go").
---@field keymap_text     string|false?  Force text extraction into a buffer (default false, off).
---@field keymap_system   string|false?  Force the OS default viewer (default false, off).
---@field keymap_terminal string|false?  Force pdfport's terminal mode (default false, off).
---@field keymap_picker   string|false?  Ask how to open it — `default_mode = "picker"` (default false, off).

-- ── mdview_open ───────────────────────────────────────────────────────────────

---@class FiletreeMdviewOpenConfig
---@field enabled     boolean
---@field keymap_open string|false?  Open the markdown node under the cursor in mdview.nvim's browser preview (default "gM").

-- ── pdf_create ────────────────────────────────────────────────────────────────

---@class FiletreePdfCreateResult
---@field path    string    The input path this result is for.
---@field status  "ok"|"error"|"partial"|"skipped" "skipped" is filetree's own (no kind/producer); the rest mirror PdfPort.ResultStatus.
---@field output  string?   Created PDF path, when status == "ok".
---@field error   string?   Failure reason, when status == "error".

---@class FiletreePdfCreateConfig
---@field enabled     boolean
---@field keymap      string?   Create a PDF from the current node/marks/folder (default "gP").
---@field on_conflict "overwrite"|"suffix"|"error"?  Passed to pdfport.create() (default "suffix").
---@field confirm     boolean?  Ask (shared dialog) before creating (default true).

-- ── compress ──────────────────────────────────────────────────────────────────

---@class FiletreeCompressConfig
---@field enabled   boolean
---@field keymap    string|false?  Compress the current node / marked nodes (default "gz").
---@field multiple  "ask"|"each"|"together"?  Several nodes: one zip each, one for all, or ask (default "ask").

-- ── smart_rename ─────────────────────────────────────────────────────────────

---@class FiletreeSmartRenameConfig
---@field enabled?             boolean
---@field keymap               string?   Key inside tree (default "r").
---@field use_safety?          boolean   Create safety backup before rename (default true).
---@field dry_run?             boolean   Log without executing (default false).
---@field cursor?              "before_ext"|"end"  Prompt cursor: before the last extension (default) or at the end.
---@field update_references?   boolean   **Deprecated** — migrated to `refs.providers` (`false` turns the lua/python/ts_js providers off).
---@field check_markdown_refs? boolean   **Deprecated** — migrated to `refs.on_rename` (`false` → `"off"`). See @types/refs.lua.
---@field refs_picker_prefer?  "auto"|"telescope"|"fzf-lua"|"quickfix"  **Deprecated** — migrated to `refs.picker`.

-- ── path_copy ────────────────────────────────────────────────────────────────

---@class FiletreePathCopyConfig
---@field enabled?            boolean
---@field keymap_pick         string?  Opens format picker (default nil, off).
---@field keymap_abs          string|string[]|false|nil  Copy absolute path (default "[a"); a list binds several keys.
---@field keymap_dirname      string?  Copy absolute parent directory (default "]a").
---@field keymap_name         string?  Copy filename only (default nil, off).
---@field keymap_project_root string?  Copy absolute project root path (default "[R").
---@field keymap_project_rel  string?  Copy path relative to project root (default "]R").
---@field keymap_buffer_rel   string?  Copy path relative to the buffer open in the editor,
---                                    in `./x` / `../x` form (default "]b").
---@field keymap_env_root     string?  Copy absolute path with an env-var root folded in,
---                                    e.g. `$REPOS_DIR/foo.nvim/x.lua` (default "[e").
---@field root_markers?       string[]|false  Markers for project-root detection (default { ".git" }); false → use cwd.
---@field env_roots?          string[]  Env var names tried by `env_rooted`, longest match wins
---                                     (default { "REPOS_DIR" }); written without the `$`.
---@field nvim_config_root?   boolean  `env_rooted` also tries `$NVIM_CONFIG_DIR`, backed by
---                                    `vim.fn.stdpath("config")` rather than an actual
---                                    environment variable (default true).
---@field notify?             boolean  Show notification after copy (default true).

-- ── live_search ──────────────────────────────────────────────────────────────

---@class FiletreeLiveSearchConfig
---@field enabled?          boolean
---@field keymap            string?  Key to open live search (default "gs").
---@field match?            "name"|"path"  Match against filename or full path (default "name").
---@field hl_match?         string   Highlight for matched nodes (default "Search").
---@field hl_dim?           string   Highlight for non-matched nodes (default "Comment").
---@field commit_to_filter? boolean  Enter pushes query to filter feature (default true).
---@field debounce_ms?      integer  TextChanged debounce (default 80ms).

-- ── node_info ────────────────────────────────────────────────────────────────

---@class FiletreeNodeInfoConfig
---@field enabled?         boolean
---@field keymap           string|false?   Key inside tree (default "I"); false = no key.
---@field show_lines?      boolean   Show line count for files (default true).
---@field max_lines_size?  integer   Skip line count for files larger than this in bytes (default 5MB).
---@field max_entries      integer?  Cap for the recursive directory scan behind Items/Size (default 100000).
---@field references?     boolean   Append a "References (N)" section (who points at the file) when the file is referenced (default true).

-- ── cheatsheet ────────────────────────────────────────────────────────────────

---@class FiletreeCheatsheetConfig
---@field enabled boolean
---@field keymap  string?  Key inside tree (default "?"). No-op on the neotree adapter (native `?` already covers it via attach.lua).
---@field style?  string  Visual preset for the floating window, passed through to `ui.kit`'s theme system. The three names shared across this ecosystem (sessions.nvim, casedesk.nvim, ui.context, ...): `"classic"` (borderless), `"chip"` (flat, square-cornered), `"rounded_chip"` (bordered capsule) -- see `ui.kit.presets`. Any other `ui.kit.theme` preset name (built-in: `"solid"`, `"double"`, `"ascii"`, `"hacker"`, `"menu"`; or one registered via `ui.kit.theme.setup({presets=...})`) also works, passed straight through. Unset (default) applies no theme override at all, so a globally configured `ui.kit.theme.setup({default=...})` still wins.

-- ── tree_traverse ─────────────────────────────────────────────────────────────

---@class FiletreeTreeTraverseConfig
---@field enabled?      boolean
---@field keymap_up     string?   Navigate to parent directory (default "-").
---@field keymap_down   string?   Set current dir as root (default "+").
---@field keymap_next_sibling string|false?  Jump to the next node at the same depth, skipping the children of expanded folders (default "]s").
---@field keymap_prev_sibling string|false?  Jump to the previous node at the same depth (default "[s").
---@field sibling_wrap? boolean   Sibling jumps wrap around inside the parent folder instead of stopping at its first/last child (default false).
---@field sync_cwd?     boolean   Also change Vim's cwd (default false).

-- ── lua_require_copy ─────────────────────────────────────────────────────────

---@class FiletreeLuaRequireCopyConfig
---@field enabled   boolean
---@field keymap    string?   Key inside tree (default "rq").

-- ── sort_cycle ───────────────────────────────────────────────────────────────

---@class FiletreeSortCycleConfig
---@field enabled          boolean
---@field keymap_cycle     string?   Next sort criterion: name, size, modified (default "<leader>so").
---@field keymap_reverse   string?   Reverse the current criterion (default "<leader>sO").

-- ── spotlight_node ───────────────────────────────────────────────────────────

---@class FiletreeSpotlightNodeConfig
---@field enabled   boolean
---@field keymap    string?   Key inside tree (default "<leader>sp").

-- ── copy_file_list ────────────────────────────────────────────────────────────

---@class FiletreeCopyFileListConfig
---@field enabled?         boolean
---@field keymap_files_abs string?   Copy absolute file paths (default "[f").
---@field keymap_files_rel string?   Copy relative file paths (default "]f").
---@field keymap_dirs_abs  string?   Copy absolute dir paths  (default "[F").
---@field keymap_dirs_rel  string?   Copy relative dir paths  (default "]F").
---@field preview_limit?   integer   Max lines shown in notification (default 5).
---@field separator?       string    Separator between paths (default "\\n").

-- ── markdown_links ────────────────────────────────────────────────────────────

---@class FiletreeMarkdownLinksConfig
---@field enabled            boolean
---@field keymap             string?  Markdown link for current node (default "ML").
---@field keymap_recursive   string?  Markdown links recursively (default "MR").
---@field keymap_from_marked string?  Markdown links from marked nodes (default "MM").
---@field keymap_insert      string?  INSERT link(s) into the window you came from -- marked nodes if any, else the current one -- and put the cursor into the first link (default "MI").
---@field insert_path        "buffer"|"cwd"|"absolute"|"env"?  Link target spelling for `keymap_insert` (default "buffer": relative to the target buffer's directory; "absolute" = the real path; "env" = `$REPOS_DIR/…`/`$NVIM_CONFIG_DIR/…`, falling back to "buffer").
---@field env_roots          string[]?  Env vars tried for `insert_path = "env"` (default { "REPOS_DIR" }; `$NVIM_CONFIG_DIR` is always tried too).
---@field cursor             table?   lib.nvim.markdown.link_cursor options for the insert (`enable`, `startinsert`, `path_cursor`).

-- ── smart_create ──────────────────────────────────────────────────────────────

---@class FiletreeSmartCreateConfig
---@field enabled?             boolean
---@field keymap               string?   Key inside tree (default "a").
---@field auto_init_lua?       boolean   Dirs → create init.lua (default false).
---@field auto_types_template? boolean   @types dirs → ---@meta template (default false).
---@field auto_module_annot?   boolean   .lua files → ---@module annotation (default false).
---@field ask_clipboard?       boolean   Ask whether to paste clipboard content (default false).
---@field notify_level?        "verbose"|"short"|"off"  Success-message verbosity (default "verbose").
---                                     "verbose": "Created file/directory: <path>". "short": just
---                                     "Path: <path>". "off": no notification at all.

-- ── link_create ───────────────────────────────────────────────────────────────

---@class FiletreeLinkCreateConfig
---@field enabled       boolean
---@field keymap        string?   Key inside tree to prompt for a link target (default nil, off —
---                                use `:Filetree symlink`). Symlink vs. hardlink is chosen at prompt
---                                time via kit.confirm (directories only ever get a symlink).
---@field keymap_mark    string?  Key to mark a link source: the node under the cursor, else the
---                                focused editor buffer's file (default nil, off — use
---                                `:Filetree symlink mark [path]`).
---@field keymap_paste   string?  Key to paste the marked source as a link into the node under
---                                the cursor (default nil, off — use `:Filetree symlink paste`).
---                                Link kind is picked automatically, not prompted: directories
---                                always get a symlink; files get a hardlink on Windows (no
---                                elevation needed) and a symlink elsewhere.
---@field relative      "auto"|"always"|"never"?  What a created symlink stores as its target (default
---                                `"auto"`). `"auto"`: a RELATIVE target when the link and its target
---                                live under the same `env_roots` root (`$REPOS_DIR`, ...; filetree's
---                                own roots only, not ones other plugins registered) -- the
---                                link then survives the checkout sitting on another drive or
---                                under another home on another machine; an absolute target
---                                otherwise (a symlink cannot carry an environment variable).
---                                `"always"`: relative whenever a relative form exists (same drive).
---                                `"never"`: always absolute. Hardlinks are never relative.
---@field repair_roots   string[]?  Extra directories `:Filetree symlink repair`/`repairall`
---                                  searches for a broken link's moved target, on top of the
---                                  usual buffer dir/cwd/git root (default `{ "$REPOS_DIR" }`,
---                                  `$VAR`-expanded the shellout-free way every other config
---                                  path in this plugin is — same default `path_copy`'s own
---                                  `env_roots` already bakes in). Needed for a target that
---                                  lives in a sibling repo entirely outside the current
---                                  project — repair's own root-guessing has no way to reach
---                                  that on its own. Only searched as a SECOND pass, after the
---                                  fast default roots come up empty (see `link_create/init.lua`'s
---                                  `find_repair_candidates`) — measured at ~0.1s even against a
---                                  large (5.8k files/737MB) directory, so this is on by
---                                  default; `repair_search_slow_hint_ms` still warns if a
---                                  particular machine's filesystem makes it genuinely slow.
---                                  Never widened to Neovim's own cache/data/state dirs
---                                  regardless of this setting — see `link_create/init.lua`'s
---                                  `unsafe_roots()`. A caveat inherited from `vim.tbl_deep_extend`:
---                                  a user-supplied `repair_roots` shorter than the default is
---                                  merged BY INDEX, not replaced wholesale — `{}` or `{"x"}`
---                                  alone will not "clear" the `"$REPOS_DIR"` default, only an
---                                  override with an ACTUAL replacement path at every index
---                                  does. To turn this off entirely, disable the feature or
---                                  override with a path that genuinely resolves to nothing.
---@field repair_nvim_config_root  boolean?  Also search `stdpath("config")` as part of that
---                                           same second pass (default true — see `repair_roots`
---                                           above for why this is safe to default on; unlike
---                                           `path_copy`'s similarly-named `nvim_config_root`,
---                                           this is a filesystem walk, not a cheap prefix fold,
---                                           which is why it gets its own on-by-default flag
---                                           rather than being folded into `repair_roots`'s array
---                                           — a user-supplied `repair_roots` replaces that array
---                                           wholesale via `vim.tbl_deep_extend`, which would
---                                           otherwise risk silently dropping this default too).
---@field repair_search_progress  Lib.Progress.Style|false?  Progress indicator for that second
---                                           search pass (default `"auto"`: prefers fidget.nvim
---                                           if installed, else a plain notify — see
---                                           `lib.nvim.progress`). Set `"statusline"` to feed
---                                           `ui.nvim`'s statusline segment instead (needs the
---                                           `statusline` integration configured — see
---                                           `docs/installation.md`), or `false` to show nothing
---                                           at all. Never blocks the tree or any other window —
---                                           the search itself is async, so switching away and
---                                           doing something else while it runs is always fine.
---@field repair_search_slow_hint_ms  number|false?  Notify with a one-time, actionable hint
---                                           (how to narrow/disable `repair_roots`/
---                                           `.repair_nvim_config_root`) when that second search
---                                           pass takes longer than this many milliseconds
---                                           (default `2000`). `false` disables the hint.

-- ── cursor_hide ───────────────────────────────────────────────────────────────

---@class FiletreeCursorHideConfig
---@field enabled  boolean  Hide block cursor while tree window is focused (uses winhighlight, not global Cursor hl).
---@field force_cursorline  boolean?  Force `'cursorline'` on for as long as the block cursor is hidden, restoring whatever it was on leave (default true). Without this, anything that turns `'cursorline'` off while the real cursor is hidden -- another plugin's own focus-tracking autocmd, a colorscheme reset, `:e`/`:bd` racing the hide -- leaves the tree with no visible position indicator at all until the window is closed and reopened.

-- ── tree_reset ────────────────────────────────────────────────────────────────

---@class FiletreeTreeResetConfig
---@field enabled  boolean
---@field keymap   string?  Key in tree buffer (default "<Esc>"). Clears preview, filter, live-search, watcher quarantine, and search highlights.

-- ── open_replace ──────────────────────────────────────────────────────────────

---@class FiletreeOpenReplaceConfig
---@field enabled?         boolean
---@field keymap           string?   Replace key in tree buffer (default "O"): opens over the editor window, the previous buffer stays listed.
---@field keymap_swap      string?   Swap key (default "<M-CR>"): also closes the focused buffer and takes its bufferline slot.
---@field keymap_swap_alt  string?   Second swap key (default "<C-CR>"), for terminals that deliver it distinctly from <CR>.
---@field close_tree?      boolean   Close the tree after the replace key (default true).
---@field swap_close_tree? boolean   Close the tree after a swap (default false).
---@field keep_position?   boolean   Give the new buffer the replaced one's slot in `vim.t.bufs`, when a tabline plugin keeps that list (default true).

-- ── open_variants ─────────────────────────────────────────────────────────────

---@class FiletreeOpenVariantsConfig
---@field enabled          boolean
---@field keymap_vsplit    string?  Open in a vertical split (default "sg").
---@field keymap_split     string?  Open in a horizontal split (default "sv").
---@field keymap_tabnew    string?  Open in a new tab (default "st").
---@field keymap_badd      string?  Add to buffer list without switching focus (default "gb").
---@field keymap_badd_alt  string?  Same as keymap_badd (default "<S-CR>").

-- ── reveal_alt ────────────────────────────────────────────────────────────────

---@class FiletreeRevealAltConfig
---@field enabled  boolean
---@field keymap   string?  Key in tree buffer (default "B"). Reveals the alternate buffer (#) in the tree.

-- ── source_switcher ───────────────────────────────────────────────────────────

---@class FiletreeSourceSwitcherIcons
---@field family?  "nerd"|"codicons"|"common"  Glyph set. Left unset: "nerd" if `vim.g.have_nerd_font = true` is declared, else "common" (no font needed) -- an explicit value always wins.
---@field variant? "v1"|"v2"                   Glyph variant within the family (default "v1").
---@field length?  "long"|"short"              Name length in `display_name` (default "long").

---@class FiletreeSourceSwitcherConfig
---@field enabled?     boolean
---@field keymap_next? string|string[]|false   Key in tree buffer: next source, wrapping (default `"`).
---@field keymap_prev? string|string[]|false   Key in tree buffer: previous source (default `!`).
---@field keymap_pick? string|string[]|false   Global normal-mode key: pick a source from a list (default nil).
---@field sources?     string[]                Override the source list (default: neo-tree's configured `sources`).
---@field icons?       FiletreeSourceSwitcherIcons

-- ── tree_toggle (opt-in) ──────────────────────────────────────────────────────

---@class FiletreeTreeToggleConfig
---@field enabled?          boolean  Default false: four global Alt keys are opt-in.
---@field reveal?           boolean  Reveal the current file when opening (default true).
---@field reveal_force_cwd? boolean  Re-root to the cwd when that file lies outside the tree (default true).
---@field keymap_current?   string|string[]|false  Global key: toggle in the current window (default "<M-c>").
---@field keymap_float?     string|string[]|false  Global key: toggle as a float (default "<M-f>").
---@field keymap_left?      string|string[]|false  Global key: toggle on the left (default "<M-l>").
---@field keymap_right?     string|string[]|false  Global key: toggle on the right (default "<M-r>").
---@field collapse_on_toggle? boolean  Opening the tree through these keys or `:Filetree toggle` first collapses every folder except the chain to the current file (default false; needs an adapter with `collapse_all`).

-- ── collapse_all ──────────────────────────────────────────────────────────────

---@class FiletreeCollapseAllConfig
---@field enabled? boolean
---@field keymap?  string|string[]|false  Key in the tree buffer (default "W"): collapse every folder back to the root.

-- ── quickpick (opt-in) ────────────────────────────────────────────────────────

---@alias FiletreeQuickpickLabelPos "overlay"|"inline"|"right_align"|"eol"

---Where the open-mode badge sits: `{ reference, vertical, horizontal }`.
---  reference   "nvim" (the whole editor) | "filetree" (the tree window)
---  vertical    "top" | "bottom"
---  horizontal  "left" | "center" | "right"
---@alias FiletreeQuickpickPosition string[]

---Keys that work while the mode runs. Each a key, a list of keys or `false`.
---@class FiletreeQuickpickKeys
---@field edit?        string|string[]|false  Open mode edit (default "e").
---@field split?       string|string[]|false  Open mode split (default "s").
---@field vsplit?      string|string[]|false  Open mode vsplit (default "v").
---@field tab?         string|string[]|false  Open mode tab (default "t").
---@field cycle?       string|string[]|false  Cycle all -> files -> folders (default "c").
---@field cancel?      string|string[]|false  Leave the mode (default { "<Esc>", "<C-c>" }).
---@field backspace?   string|string[]|false  Drop the last typed digit (default { "<BS>", "<C-h>" }).
---@field scroll_down? string|string[]|false  One line down in the tree (default "j").
---@field scroll_up?   string|string[]|false  One line up (default "k").
---@field page_down?   string|string[]|false  Half a page down (default "<C-d>").
---@field page_up?     string|string[]|false  Half a page up (default "<C-u>").

---@class FiletreeQuickpickConfig
---@field enabled?               boolean  Default false: two global leader keys and a mode that takes over the tree's keys are opt-in.
---@field keymap?                string|string[]|false  Global key: number the tree (default "<leader>;"). A count roots it that many folders above the file.
---@field keymap_cwd?            string|string[]|false  Global key: number the tree rooted at the cwd (default "<leader>:").
---@field content?               "all"|"files"|"folders"  Which entries are numbered at start (default "all").
---@field open_mode?             "edit"|"split"|"vsplit"|"tab"  Open mode without a prefix key (default "edit").
---@field width?                 integer  Digits per label, 1..3 (default 2: 00..99 on screen).
---@field timeout_ms?            integer  Idle time that ends the mode; 0 = never (default 5000).
---@field silence_nvim_mappings? boolean  Map every other tree-buffer key to <Nop> while the mode runs (default true).
---@field label_pos?             FiletreeQuickpickLabelPos  Where a label is drawn (default "overlay").
---@field indicator?             boolean  Show the open-mode badge (default true).
---@field indicator_position?    FiletreeQuickpickPosition  Badge position (default { "nvim", "top", "center" }).
---@field keys?                  FiletreeQuickpickKeys
---@field hl_number?             string   Highlight group of a label (default "FiletreeQuickpickNumber", a link to Search).
---@field hl_typed?              string   Highlight group of the digits already typed (default "FiletreeQuickpickTyped", IncSearch).
---@field hl_indicator?          string   Highlight group of the badge (default "FiletreeQuickpickIndicator", PmenuSel).

-- ── buffer_save ───────────────────────────────────────────────────────────────

---@class FiletreeBufferSaveConfig
---@field enabled          boolean
---@field keymap_adjacent  string?   Save last adjacent editor buffer (default "<C-s>").
---@field keymap_node      string?   Save buffer matching node under cursor (default "<M-s>").
---@field force            boolean   Use write! (default true). false → update (no-op when unmodified).

-- ── buffer_cycle ──────────────────────────────────────────────────────────────

---@class FiletreeBufferCycleConfig
---@field enabled      boolean
---@field keymap_next  string?   Next buffer in adjacent editor window (default "<C-n>").
---@field keymap_prev  string?   Previous buffer in adjacent editor window (default "<C-p>").

-- ── window_size_cycler ────────────────────────────────────────────────────────

---@class FiletreeWindowSizeCyclerConfig
---@field enabled  boolean
---@field keymap   string?     Key in tree buffer (default "w").
---@field sizes    integer[]?  Width presets to cycle through (default { 30, 50, 15 }).

-- ── open_in_fm ────────────────────────────────────────────────────────────────

---@class FiletreeOpenInFmConfig
---@field enabled        boolean
---@field keymap         string?   Key in tree buffer (default "<leader>fm").
---@field command        string?   Override launch binary (auto-detected per OS by default).
---@field reveal         boolean?  Select a file node inside its parent directory (default true).
---                                false → open the containing directory without selecting
---                                anything. Directory nodes are navigated into either way.
---@field debug          boolean?  Verbose notify.debug() logging of every launch attempt — branch
---                                taken, argv, job id, and (only when this is on) the process's
---                                exit code/stderr. Default false. This feature only ever confirms
---                                that a process STARTED, never that it succeeded (a file manager
---                                is meant to be fire-and-forget) — turn this on to see what
---                                actually happened when a launch silently doesn't open anything.
---@field reuse_existing boolean?  Windows only. Navigate an already-open Explorer window to the
---                                target instead of spawning another. Not a literal new TAB
---                                (Explorer's own tab feature has no scripting hook to add one from
---                                outside) — a window, via Shell.Application's Navigate2. Forwarded
---                                to lib.nvim.cross.reveal_in_fm as `reuse`, which does the reuse
---                                and the raise in one asynchronous step; a file node cannot be
---                                selected this way, so it reuses the window on its parent
---                                directory. Default false.

-- ── shell_run ─────────────────────────────────────────────────────────────────

---@class FiletreeShellRunConfig
---@field enabled      boolean
---@field keymap       string?   Key in tree buffer (default "i").
---@field close_on_ok  boolean   Auto-close terminal when command exits 0 (default true).
---@field split        string?   "split" | "vsplit" (default "split").
---@field height       integer?  Terminal height in lines for horizontal split (default 12).

return {}
