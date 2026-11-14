# Configuration

**How defaults work:** every feature is enabled unless it's marked opt-in in
[docs/FEATURES/](FEATURES/README.md). You never write
`enabled = true` to *get* a feature — you only ever write `enabled = false` to
turn one off, or `enabled = true` to switch on one of the opt-in few. Omitting a
feature entirely leaves it at its default (on) with its default options.

```lua
-- Minimal — the full feature set, default keymaps, nothing to wire up:
require("filetree").setup({ adapter = "neotree" })
```

**Mistakes are reported, not swallowed.** `setup()` checks every option you pass
— top-level keys, feature names, and each `features.<name>` body against that
feature's own schema. An unknown option (`features.trash.confrim`), a value of
the wrong type (`max_history = "50"`), one outside its range (`debounce_ms = -1`)
or outside its allowed set (`mode = "permenant"`), and a feature body that is not
a table at all (`features.trash = true`) each produce a warning naming the
option — with a *did you mean* hint for a typo — and the option falls back to its
default. The same list is in `:checkhealth filetree`.

## Full option reference

The block below shows the tunable options of a representative selection with
their defaults. `enabled` is shown only to make each feature's default state
explicit — you can drop the line in your own config.

```lua
require("filetree").setup({
  adapter = "auto",   -- "neotree" | "nvimtree" | "auto"
  debug   = false,    -- true → show internal debug notifications (troubleshooting)

  -- One-time "which CLI tools does this plugin want, and why" popup on first
  -- setup() after install (via lib.nvim.deps). false disables it here, in the
  -- spec passed to setup() — no vim.g needed. See the root README.
  deps_popup = true,

  -- Ignore list: hide common dirs/files from the tree by default.
  -- true (default) → built-in list (.git, node_modules, …)
  -- false          → show everything
  -- string[]       → custom list, overrides the built-in defaults
  ignore_list = true,

  -- Confirmation prompts for destructive/bulk actions (paste, delete,
  -- rename_batch). Shipped defaults: paste/rename_batch = no prompt,
  -- delete = PROMPTS (trashing is harder to notice/undo than a move or
  -- rename, e.g. from a mis-click or an accidental multi-mark delete).
  -- nil (default) leaves each feature's own default alone. true/false
  -- applies to all three at once; a table applies per action. A feature's
  -- own `features.<name>.confirm`, if you set it explicitly, always wins
  -- over this switch.
  --   confirmations = false                            -- no prompts at all
  --   confirmations = { delete = false }                -- opt out of the delete prompt only
  confirmations = nil,

  -- Style for batch-operation progress indicators (trash, paste, …) — see
  -- "Progress indicators" below.
  progress_style = "auto",  -- "auto" | "notify" | "statusline" | "fidget" | "float" | "kit"

  -- The own tree, used with adapter = "native" (see docs/FEATURES/BACKENDS.md).
  -- native = {
  --   position = "left",        -- "left" | "right" | "top" | "bottom" | "float" | "current"
  --   width = 32,
  --   height = 15,              -- of a tree at the top or bottom
  --   hijack_netrw = true,      -- `nvim <dir>` / `:edit <dir>` shows the tree in that window
  --   group_empty_dirs = true,  -- a/b/c/ as one line
  --   icons = true,
  --   max_entries = 20000,      -- per folder; 0 = no limit
  --   watch = true,             -- follow the disk, read only what changed
  --   search_max = 1000,        -- hits a search (filter) shows at most
  --   view_bar = true,          -- the views (files, buffers, git ...) as tabs in the winbar
  --   views = nil,              -- e.g. { { "files" }, { name = "work", "buffers", "git" } }
  -- },

  -- Sources, decorators and actions for the own tree (see docs/api.md,
  -- "Sources, decorators and actions"). Lists of entries; a later
  -- setup() replaces what an earlier one listed. Same as calling
  -- require("filetree").source / .decorator / .action yourself.
  -- sources    = {},
  -- decorators = {},
  -- actions    = {},

  -- Named roots that portable paths are written with — see "Env roots" below.
  -- A created symlink's messages come out as `$REPOS_DIR/foo.nvim/x.lua` /
  -- `$NVIM_CONFIG_DIR/lua/x.lua` instead of `E:/repos/foo.nvim/x.lua`; `[e` and
  -- Markdown links with insert_path = "env" use that form. `[a`, the other
  -- absolute copies and insert_path = "absolute" stay real.
  env_roots = {
    enable      = true,                 -- false → plain absolute paths everywhere
    -- vars     = { "REPOS_DIR" },      -- environment variables whose value is a root
    --                                  -- (the default; setting it REPLACES the list)
    nvim_config = true,                 -- $NVIM_CONFIG_DIR = stdpath("config"), no env var needed
    extra       = {                     -- more roots: name = path | function
      -- WKDBOOKS = "E:/repos/WKDBooks",
      -- NOTES    = function() return vim.fn.expand("~/notes") end,
    },
  },

  -- Cap on how many nodes one walk of the rendered tree collects. Only a
  -- guard against a single directory expanded with tens of thousands of
  -- entries; the walk is already bounded by what is expanded.
  max_visible_nodes = 5000,

  -- Reference engine: what happens to markdown links and require()/import
  -- statements when a file is renamed, moved or deleted. One block for every
  -- fileops feature — see FEATURES/FILEOPS.md#references for the full story.
  refs = {
    enabled   = true,
    providers = { markdown = true, lua = true, python = true, ts_js = false },
    on_rename = "ask",    -- "ask" (chooser) | "auto" (just do it) | "off"
    on_move   = "ask",
    on_delete = "ask",    -- trash: offer to blank dangling links to REF!
    copy      = false,    -- a copy leaves the original in place: nothing breaks
    picker    = "auto",   -- "auto" | "telescope" | "fzf-lua" | "quickfix"
    prefer_lsp = true,    -- skip the textual code providers when a language
                          -- server already applied a workspace edit
    wiki_links = false,   -- also scan [[wiki]]-style markdown links
    experimental = {      -- in-development reference features, each opt-in
      plaintext = {        -- rewrite bare paths in prose / code comments
        enabled  = false,  -- (a match is rewritten only when it resolves to
        comments = true,   --  exactly the moved file); see FEATURES/FILEOPS.md
      },                   --  #references. extensions/comment_extensions
    },                     --  override the provider's built-in lists.
    scan = {
      root              = "project",  -- "project" (nearest root) | "cwd"
      respect_gitignore = true,
      max_files         = 5000,       -- cap for the ripgrep-free fallback walk
      timeout_ms        = 3000,
    },
    report = {            -- `:Filetree references` / `:Filetree refs unused`
      view = "popup",     -- "popup" | "picker" (telescope / fzf-lua / quickfix)
      -- extensions = { "png", "jpg" },  -- what `refs unused` considers (default: asset allowlist)
      max_files = 5000,   -- files one `refs unused` sweep checks at most
    },
    undo = true,          -- `:Filetree refs undo` reverts the last rewrite
    undo_depth = 10,      -- how many rewrites stay undoable; the stack holds
                          -- only the replaced line content, so raising is cheap
  },

  features = {
    -- ── On by default ──────────────────────────────────────────────────────
    layout_guard = {
      enabled  = true,        -- default: on
      delay_ms = 50,
    },

    buffer_cycle = {
      enabled     = true,        -- default: on
      keymap_next = "<C-n>",     -- next buffer in the adjacent editor window
      keymap_prev = "<C-p>",     -- previous buffer in the adjacent editor window
    },

    preview = {
      enabled     = true,      -- default: on
      mode        = "buffer",  -- "buffer": show file in the editor window (default)
                               -- "float":  floating window next to the tree
      highlight   = true,      -- syntax/treesitter highlighting in the preview
      keymap      = "<Tab>",   -- text/dir: toggle preview; image/PDF: dispatch
      keymap_open = "<CR>",    -- image/PDF: dispatch; other: adapter default
      max_lines   = 40,        -- float mode: lines to read
      max_bytes   = 1048576,   -- buffer mode: larger files are not loaded (0 = no limit);
                               -- binary files are never loaded, a notice says why
      max_width   = 80,        -- float mode
      max_height  = 25,        -- float mode
      wrap        = false,     -- float mode: line wrapping
      image = {
        backend = "auto",     -- "snacks" | "image.nvim" | "system" | false
      },
      pdf = {
        backend = "pdfport",  -- "pdfport" | "system" | false
      },
      system_exts = { "msg", "eml", "oft" },
                              -- opened with the OS default app (Outlook) on
                              -- <CR>/<Tab> instead of as a binary buffer; {} = off
    },

    cursor_hide = {
      enabled = true,   -- default: on — hide block cursor in tree window
      -- Tree filetypes come from the active adapter's `filetypes` capability
      -- when it declares one (neo-tree, nvim-tree ship it); otherwise a
      -- superset covering all known trees is used as a fallback.
    },

    tree_reset = {
      enabled = true,   -- default: on — <Esc> clears preview + filter + live_search
      keymap  = "<Esc>",
    },

    context_menu = {
      enabled = true,            -- default: on
      keymap  = "<RightMouse>",  -- false disables the trigger without disabling the
                                  -- feature (e.g. to wire your own via
                                  -- filetree.integrations.menu.items() instead)
      -- Opens the menu at the mouse via ui.contextmenu, which draws
      -- with nvzone/menu if installed or its own kit renderer otherwise --
      -- no third-party plugin required either way. WHICH entries appear is
      -- controlled by the top-level `menu` config below, not here.
    },

    buffer_save = {
      enabled        = true,      -- default: on
      keymap_adjacent = "<C-s>",  -- save last adjacent editor buffer
      keymap_node    = "<M-s>",   -- save buffer matching node under cursor
      force          = true,      -- use write! (vs update)
    },

    window_size_cycler = {
      enabled = true,            -- default: on
      keymap  = "w",
      sizes   = { 30, 50, 15 },  -- normal → large → small → normal
    },

    open_in_fm = {
      enabled = true,            -- default: on
      keymap  = "<leader>fm",    -- show node in the system file manager
      reveal  = true,            -- false: open the containing dir without selecting
      -- command = "thunar",     -- launcher override (auto-detected per OS)
      -- reuse_existing = false, -- Windows: navigate an open Explorer window instead
    },

    marks = {
      enabled = true,            -- default: on
      order   = "marked",        -- "marked": every consumer (copy path incl. `[e`, gy,
                                 -- fileops) gets the paths in mark order; "tree": sorted by path
      auto_clear_ms = 60000,     -- clear all marks after this much idle time; 0 = never
    },

    file_clipboard = {
      enabled       = true,      -- default: on
      keymap        = "gy",      -- copy the FILES (marked, else the cursor node) to the OS clipboard
      preview_limit = 5,         -- names listed in the notification
    },

    shell_run = {
      enabled     = true,        -- default: on
      keymap      = "i",         -- prompt + run shell command in node directory
      close_on_ok = true,        -- auto-close terminal when command exits 0
      split       = "split",     -- "split" | "vsplit"
      height      = 12,
    },

    open_replace = {
      enabled = true,             -- default: on
      keymap          = "O",      -- open over the editor window; old buffer stays listed
      keymap_swap     = "<C-M-CR>", -- ... and close the old buffer, taking its slot
      keymap_swap_alt = false,    -- optional second swap key
      close_tree      = true,     -- close the tree after `keymap`
      swap_close_tree = false,    -- ... and after a swap
      keep_position   = true,     -- new buffer takes the replaced one's bufferline slot
                                  -- (needs a tabline that keeps `vim.t.bufs`)
    },

    reveal_alt = {
      enabled = true,  -- default: on
      keymap  = "B",   -- reveal alternate buffer (#) in tree
    },

    window_style = {
      enabled            = true,   -- default: on
      statusline         = true,   -- default: on — blank statusline in tree windows;
                                    -- re-applied on FileType, BufWinEnter, and WinEnter
                                    -- so a statusline plugin re-asserting itself on the
                                    -- same window doesn't win the race
      highlights_isolate = false,  -- true → link tree HL groups to editor's Normal/NormalNC
    },

    -- ── Off by default (opt-in) ───────────────────────────────────────────
    cwd_sync = {
      enabled          = false,  -- default: off
      debounce_ms      = 150,
      parent_levels    = 0,     -- how far the tree-reveal call itself ascends
      keep_focus       = true,  -- keep focus in the editor window after reveal
      change_dir       = true,  -- actually chdir to the target dir — never prompts
      reveal           = true,  -- also reveal/root the tree ourselves. Set to FALSE only if
                                -- your adapter's underlying plugin already follows the cwd on
                                -- its own (neo-tree bind_to_cwd+follow_current_file, nvim-tree
                                -- update_focused_file) — otherwise the two reveals fight and
                                -- the tree lands on the file's parent. netrw/oil/mini_files have
                                -- no such native feature — leave this true for them. See the
                                -- per-adapter table below.
      use_project_root = true,  -- target the detected project root, not just the file's dir
      root_markers     = { ".git" },  -- anchor the cwd to the nearest ancestor holding one
                                      -- of these (cached per-dir); avoids frequent cwd jumps.
                                      -- Pass a bigger list to widen it, or false to disable
                                      -- (then falls back to use_project_root / parent dir).
    },

    project_root = {
      enabled  = true,   -- default: on
      markers  = { ".git", "package.json", "Cargo.toml", "go.mod", "*.rockspec", --[[ … ]] },
      fallback = "parent",  -- "parent" (the file's own dir) | "cwd", used when no marker is found
      cache    = true,      -- cache resolved roots per directory for the session (see below)
      max_cache_entries = 1000,  -- directories held before the cache is cleared in one shot
    },

    current_hl = {
      enabled     = false,    -- default: off
      file_hl     = { fg = "#7aa2f7", bold = true },
      parent_hl   = { fg = "#565f89" },
      debounce_ms = 100,
    },

    safety = {
      enabled     = false,    -- default: off (backup API, no keymaps)
      backup_dir  = nil,      -- default: stdpath("data")/filetree/backups
      max_backups = 5,
      dry_run     = false,
    },

    handle_guard = {
      enabled = false,  -- default: off — patches a neo-tree internal (fs_watch) +
                         -- closes libuv handles it owns, to fix a sporadic Windows
                         -- file-lock at the source (watcher_quarantine only hides
                         -- the error). neo-tree adapter + Windows/WSL only; a no-op
                         -- elsewhere. No keymaps — inspect with `:Filetree handles`.
    },

    tree_integrity = {
      enabled = true,   -- default: on — wraps nui's Tree:set_nodes so neo-tree's
                        -- node index cannot be corrupted by a subtree being
                        -- re-set with live nodes ("Error setting nodes: attempt
                        -- to index local 'node' (a nil value)", repeating on
                        -- every render until the tree is re-opened). No-op on a
                        -- healthy tree; neo-tree adapter only.
      silent  = true,   -- false → debug note whenever a corrupt subtree is healed
    },

    -- Numbered quick-pick mode: label the visible entries, type a number to open
    -- it. See docs/FEATURES/NAVIGATION.md#quickpick-opt-in.
    quickpick = {
      enabled = false,              -- default: off (two global keys + a mode that silences the tree's keys)
      keymap = "<leader>;",         -- global; a count roots the tree that many folders above the file
      keymap_cwd = "<leader>:",     -- global; tree rooted at the cwd. false = leave a trigger unmapped
      content = "all",              -- numbered at start: "all" | "files" | "folders"
      open_mode = "edit",           -- without a prefix key: "edit" | "split" | "vsplit" | "tab"
      width = 2,                    -- digits per label, 1..3 (2 = 00..99 on screen)
      timeout_ms = 5000,            -- idle time that ends the mode; 0 = never
      silence_nvim_mappings = true, -- every other tree-buffer key is <Nop> while the mode runs
      label_pos = "overlay",        -- "overlay" | "inline" | "right_align" | "eol"
      indicator = true,             -- badge showing open mode, content kind, typed digits
      indicator_position = { "nvim", "top", "center" }, -- { "nvim"|"filetree", "top"|"bottom", "left"|"center"|"right" }
      keys = {                      -- each: a key, a list of keys, or false
        edit = "e", split = "s", vsplit = "v", tab = "t",
        cycle = "c",                -- all -> files -> folders
        cancel = { "<Esc>", "<C-c>" },
        backspace = { "<BS>", "<C-h>" },
        scroll_down = "j", scroll_up = "k",
        page_down = "<C-d>", page_up = "<C-u>",
      },
      hl_number = "FiletreeQuickpickNumber",       -- default link: Search
      hl_typed = "FiletreeQuickpickTyped",         -- default link: IncSearch
      hl_indicator = "FiletreeQuickpickIndicator", -- default link: PmenuSel
    },

    -- auto_resize is also off by default — see "Default-disabled features".
  },

  -- Override the adapter's (neotree/nvim-tree) own native keymaps.
  -- false → <Nop>   string → remap target
  -- Example: noop neotree's built-in `i` (toggle-info) so shell_run can use it
  adapter_keymaps = {
    -- ["i"] = false,
  },

  -- Sister plugins filetree may hand work to. All opt-OUT (default true), all
  -- soft: an absent plugin is never an error. See "pickers.nvim integration".
  integrations = {
    pickers = true,   -- false keeps find_files / grep_in_dir off pickers.nvim
    ui_menu = true,   -- false keeps ui.nvim's right-click menu from offering "Open/Close filetree"
  },
})
```

## Env roots

`env_roots` names the directories that **portable paths are written with**.
A path under one of them is written `$NAME/rest` instead of `E:/repos/rest`,
so the text — a pasted link, a message, a path copied with `[e` — means the
same on a machine where that directory sits on another drive or under another
home.

| Root | Where it comes from |
|---|---|
| `$REPOS_DIR` | the environment variable of that name (`vars`) |
| `$NVIM_CONFIG_DIR` | `vim.fn.stdpath("config")` — no environment variable needed (`nvim_config = false` drops it) |
| your own | `extra = { NAME = "/abs/path" }`, a plain path or a function returning one (it may start with `~`, `$VAR`, `${VAR}` or `%VAR%`) — no environment variable needed; a name here overrides a `vars` entry of the same name |
| shared | the roots of [lib.nvim's named-roots registry](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/fs/roots/README.md): your `require("lib.nvim.fs.roots").setup({ extra = … })` and roots other plugins register |

filetree's `env_roots` is a layer over that registry: `vars`, `extra` and
`nvim_config` apply to filetree's calls only and never change the registry's
own configuration, while the registry's roots are visible here too. Without
`vars`, the registry's list is used (default `{ "REPOS_DIR" }`).

An unset variable is skipped, and when roots nest the **deepest** match wins.
A value is a root only when it is an absolute path that is not a whole drive
or the filesystem root (`C:/`, `/`), and a name must be letters, digits and
underscores (`MY-DIR` is ignored); `:checkhealth filetree` warns about an
`env_roots` entry that is no root. `$NVIM_CONFIG_DIR` is always
`stdpath("config")`, also when it is listed in `vars`. `.` and `..` in a path
are resolved before it is folded, so `$REPOS_DIR/../x` is never written. A
typed path (`:Filetree symlink`) may name a root as `$NAME`, `${NAME}` or
`%NAME%`.

What goes through it:

- `:Filetree copy env_rooted` (`[e`) — always, also with `enable = false`
- Markdown links inserted with `insert_path = "env"` — always, like `[e`
- `:Filetree symlink` — the typed target is expanded (`$REPOS_DIR/x`,
  `$NVIM_CONFIG_DIR/x`, `$YOURS/x`), the messages show the env form, and the
  link's own target text is chosen portably — see
  [Link Create](FEATURES/FILEOPS.md#link-create)

What does **not**: a path you copy as absolute — `:Filetree copy absolute` /
`dirname` / `project_root` (`[a`, `]a`, `[R`) and `:Filetree filelist files
abs` / `dirs abs` (`[f`, `[F`) write the real path, since asking for the
absolute path while a `$NAME` form has a key of its own (`[e`) means asking
for the real one. Neither does everything relative by definition (`relative`,
`buffer_relative`, `project_relative`, Markdown links relative to the buffer),
nor a Markdown link inserted with `insert_path = "absolute"` (the real path),
nor everything that needs the real path (`uri`, open-with, the file manager,
the OS file clipboard, shell commands).

Switch it off with `env_roots = { enable = false }` — the links and messages
above then show the plain absolute path again; `[e` still folds, it is asked
for by name.

```lua
require("filetree").setup({
  env_roots = {
    vars  = { "REPOS_DIR", "WORK_DIR" },      -- replaces the default { "REPOS_DIR" }
    extra = { WKDBOOKS = "E:/repos/WKDBooks" },
  },
})
```

## pickers.nvim integration

With [pickers.nvim](https://github.com/WKDSteve/pickers.nvim) installed,
`find_files` (`f`) and `grep_in_dir` (`gr`) hand the node's directory to it
instead of driving a picker of their own; `tf` / `tg` force it. Engine choice,
`find.*` flags and entry actions are then the ones the rest of your setup uses.
Nothing needs wiring, and **it is on by default**. It is used only when all
three hold:

1. pickers.nvim is installed (and recent enough to ship
   `pickers.integrations.filetree`; an older one counts as absent);
2. `integrations.pickers` is not `false` here;
3. `filetree = { enabled = false }` is not set in pickers.nvim's config.

`:checkhealth filetree` says which of the three holds.

If any of them fails, `f` / `gr` fall back silently to telescope / fzf-lua /
mini.pick / the builtin backend. `tf` / `tg` say "pickers.nvim not available",
since they asked for it explicitly.

```lua
require("filetree").setup({ integrations = { pickers = false } })
require("pickers").setup({ filetree = { enabled = false } })  -- the other end
```

## ui.nvim right-click menu

ui.nvim's `ui.menu` offers one row, "Open filetree" / "Close filetree", from any
ordinary buffer. It asks `require("filetree.integrations.menu").enabled()`
first: `false` when `integrations.ui_menu = false` or `menu.enable = false`.
`items()` / `submenu()` / `window_entry()` keep working for any other host either
way.

```lua
require("filetree").setup({ integrations = { ui_menu = false } })
```

## Adapters

| Name | Plugin | Status |
|---|---|---|
| `"neotree"` | neo-tree.nvim | Supported |
| `"nvimtree"` | nvim-tree.lua | Supported |
| `"netrw"` | Built-in | Supported |
| `"oil"` | oil.nvim | Supported |
| `"mini_files"` | mini.files | Supported |
| `"auto"` | First available, tried in the order above | Default |

### cwd_sync `reveal` per adapter

Whether `cwd_sync.reveal` should be `true` or `false` depends on whether the
underlying tree **plugin** (not filetree.nvim) has its own built-in feature
that follows the current buffer independently of filetree — when it does, that
feature and cwd_sync's own reveal race each other on every buffer switch:

| Adapter | Native "follow cwd" feature | `reveal` |
|---|---|---|
| `neotree` | `filesystem.follow_current_file.enabled` + `filesystem.bind_to_cwd = true` | `false` |
| `nvimtree` | `update_focused_file.enable = true` (leave `update_root` at its default `false` — see caveat) | `false` |
| `netrw` | none | `true` (default) |
| `oil` | none | `true` (default) |
| `mini_files` | none | `true` (default) |

For `netrw`/`oil`/`mini_files` cwd_sync's own reveal is the only thing that
does this job — leaving `reveal = false` there means switching to a file in a
different project never gets revealed at all.

> **Caveat (tested):** nvim-tree's `update_focused_file.update_root.enable` is
> *not* a drop-in equivalent of neo-tree's `bind_to_cwd`. neo-tree's
> `bind_to_cwd` is reactive — it just follows whatever cwd cwd_sync already set.
> nvim-tree's `update_root` actively drives the cwd itself, falling back to
> **the file's own directory** (not a project root) when nothing else matches —
> so with it enabled, nvim-tree overwrites cwd_sync's git-root-anchored cwd on
> every switch, regardless of `reveal`. Leave `update_root` at its default
> `false` if you want `root_markers` to win.

See [docs/filetree.txt §5.3](../doc/filetree.txt) for the full explanation and a
worked neo-tree example.

## Ignore list

filetree.nvim hides common filesystem clutter from the tree by default — `.git`,
`node_modules`, build artefacts, caches, and similar. Toggle with the adapter's
native "show hidden" key (neotree: `H`).

```lua
require("filetree").setup({
  -- true (default) — use built-in list; also reads from lib.nvim if available
  ignore_list = true,

  -- false — disable hiding entirely, show all items
  ignore_list = false,

  -- string[] — custom list; overrides the built-in defaults completely
  ignore_list = { ".git", "node_modules", ".venv" },
})
```

**Built-in hidden names** (when `ignore_list = true`):
`.git`, `.github`, `.hg`, `.svn`, `node_modules`, `.pnpm-store`, `.yarn`,
`.venv`, `.direnv`, `__pycache__`, `.mypy_cache`, `.pytest_cache`, `.cache`,
`.sass-cache`, `build`, `dist`, `out`, `target`, `bin`, `obj`, `zig-cache`,
`zig-out`, `.DS_Store`, `thumbs.db`, `.vscode`, `.idea`

**Toggle at runtime** — use your adapter's built-in toggle:

| Adapter | Key | Action |
|---------|-----|--------|
| neo-tree | `H` | `toggle_hidden` — shows/hides all filtered items |
| nvim-tree | `H` | `toggle_dotfiles` |
