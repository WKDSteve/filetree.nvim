# Core

The two mechanisms most of the rest of the plugin is built on: the
adapter interface that makes every feature tree-agnostic, and the root/cwd
policy stack that decides where "here" is.

## Backend adapter abstraction

Every feature that needs to know "what tree plugin am I running against"
goes through one `FiletreeAdapter` interface instead of branching on the
adapter name. A feature calls `adapter.get_current_node()`,
`adapter.get_root_path()`, `adapter.set_root()`, etc.; five built-in
adapters (see [BACKENDS.md](BACKENDS.md)) implement that interface for
neo-tree, nvim-tree, netrw, oil.nvim and mini.files, and `M.register_adapter()`
lets a user or another plugin add a sixth without touching filetree's own
source. This is why a feature written once (marks, trash, cwd_mode, the PDF
bridge, ...) works identically across all five backends: it never contains
tree-specific code, only adapter calls.

- **Tab:** true
- **Module:** [`adapter/init.lua`](../../lua/filetree/adapter/init.lua) (`M.register`, `M.resolve`, `M.get`, `M.list`); interface contract in [`@types/adapter.lua`](../../lua/filetree/@types/adapter.lua) (`FiletreeAdapter`)
- **Config:** `opts.adapter` (`"neotree"|"nvimtree"|"netrw"|"oil"|"mini_files"|"auto"`, default `"auto"` — tries neotree → nvimtree → netrw → oil → mini_files, first `is_available()` wins)

### The interface

Every adapter implements the same required surface: `is_available`,
`is_open`, `get_winid`, `get_root_path`, `get_current_node`,
`get_visible_nodes`, `get_node_line`, `expand_node`, `collapse_node`,
`open_file`, `open_reveal`, `set_root`, `open_cwd`, `close`, `refresh`,
`scroll_to_line`, `highlight_node`/`unhighlight_node`. Methods must never
throw — a failure is a `false`/`nil` return plus an internal log, so one
badly-behaved backend can't take down a feature that calls into it.

A handful of **optional capabilities** let features degrade gracefully
when a backend doesn't support them: `filetypes` (buffer filetypes the
backend's tree uses, read by `cursor_hide`/`window_style`), `hl_groups`
(tree → editor highlight mapping, for `window_style.highlights_isolate`),
`toggle_at` (position-aware open/close), `redraw` (re-render without a
filesystem rescan, used by `opened_sync`), and `sign_node`/`unsign_node`
(sign-column marker, used by `current_hl`'s icon). An adapter that omits
one of these simply means the corresponding feature no-ops that part for
that backend, not that setup fails.

**Windows/WSL path note (verified caveat):** callers such as `cwd_sync`,
`auto_reveal` and `current_hl` source paths from
`vim.api.nvim_buf_get_name`/`expand("%:p")`, which can return forward-slash
paths on Windows even when a backend's own node paths are native-separator.
Any adapter that uses a path as a cache/lookup key must normalize it first
(`key_of()` in `adapter/neotree.lua` is the reference implementation) or
lookups silently miss on Windows.

## CWD Mode

A stateful root **policy** in front of `cwd_sync`: instead of re-deriving a
root from the focused buffer on every switch, `cwd_mode` decides *whether*
a switch should move the cwd/tree root at all, and holds that decision as
state. Six modes: `follow` (no policy — the default; `decide()` returns
`nil` and cwd_sync's own resolution chain applies unchanged), `project`
(holds the VCS root while the focused file lives inside it; a rootless
scratch file doesn't drag it away when `project.sticky` is on), `nearest`
(same shape, but the nearest *package* boundary — `package.json`,
`Cargo.toml`, `go.mod`, ... — for monorepo work), `lock` (pins the cwd to
one directory; a `lib.nvim.fs.dir_guard` reverts a foreign `:cd` from a
picker or session restore when `lock.enforce` is on), `manual` (nothing
automatic — only `+`/`-` or `:Filetree cwd ...` move it), and `tree_leads`
(the direction reversed: the tree root is authoritative and the cwd follows
it, so buffer switches move nothing).

Because the held root is real state, other features read
`cwd_mode.root()` instead of guessing from `getcwd()` —
`find_files`/`grep_in_dir`/`git_status`/`breadcrumbs` all resolve through
[`util/root.lua`](../../lua/filetree/util/root.lua) (held root → project_root
→ cwd), so a locked session greps the locked project rather than whatever
directory a picker last changed into. The active mode is shown as a badge
(bottom-left of the tree window by default) via `lib.nvim.ui.statusline`.

- **Tab:** true
- **Module:** [`features/nav/cwd_mode/init.lua`](../../lua/filetree/features/nav/cwd_mode/init.lua) (`M.decide`, `M.set_mode`, `M.root`, `M.cycle`, `M.lock`, `M.lock_here`, `M.unlock`, `M.status`, `M.badge`, `M.component`, `M.notify_manual_root`)
- **Config:** `opts.features.cwd_mode` — `enabled` (default `true`, but inert at `mode = "follow"`), `mode` (`follow|project|nearest|lock|manual|tree_leads`), `scope` (`global|tab|win`), `project.markers`/`nearest.markers`, `project.sticky`, `lock.enforce`, `lock.follow_manual_root`, `reveal_outside` (`skip|reveal`), `persist` (default `false`), `indicator.*` (`enabled`, `mode` (`auto|statusline|float`), `align` (`left|center|right`, default `left`), `show_path` (`never|lock|always`: append the pinned path, default `lock`), `style`: `text|short|numeric|icon`), `cycle` (default `{"follow","project","lock"}`)
- **Keymaps:** `L` cycle mode, `gp` lock cwd to node under cursor — see [docs/BINDINGS/KEYMAPS.md](../BINDINGS/KEYMAPS.md)
- **Usercmds:** `:Filetree cwd mode|scope|lock|here|unlock|toggle|status|forget` — see [docs/BINDINGS/USERCOMMANDS.md](../BINDINGS/USERCOMMANDS.md)

**A dependency worth knowing:** `project`/`nearest` mode's whole promise
(following the focused file as it crosses project/package boundaries) runs
through `cwd_sync`'s `BufEnter` hook calling `decide()`. `cwd_sync` is
off by default, so without it those two modes only seed the initial pin and
then do nothing on the next switch — indistinguishable from a plain lock
until files elsewhere stop moving the root. `set_mode()` warns once when
this happens; `lock` and `tree_leads` don't depend on `cwd_sync` (dir_guard
and `tree_traverse`'s manual re-root drive those directly).

## CWD Sync

The stateless executor `cwd_mode` asks before acting: on `BufEnter`/
`WinEnter`, silently `chdir` to the current file's project root — resolved
via `root_markers` (default `{".git"}`, cached) falling back to
`use_project_root` and then the file's own parent directory. Never prompts.

When `reveal = true` (the default), cwd_sync auto-pauses for 2 seconds once
the cursor enters the tree window, so the tree's own `<CR>`-driven open
can't race cwd_sync's reveal of the file it just opened.
`require("filetree").feature("cwd_sync").pause(5000)` pauses manually.

Whether `reveal` should be `true` or `false` depends on the adapter: neo-tree
(`filesystem.follow_current_file` + `bind_to_cwd`) and nvim-tree
(`update_focused_file.enable`) already follow the buffer natively, so
`reveal` should be `false` there to avoid two reveals racing; netrw/oil/
mini_files have no native equivalent, so `reveal` stays `true` for them (see
the per-adapter table in [docs/configuration.md](../configuration.md)).
Also: neo-tree's native "File not in cwd. Change cwd to ...?" prompt is
suppressed automatically the moment `setup({ adapter = "neotree" })` runs —
filetree wraps `command.execute` once so any at-risk call (from filetree or
from the user's own keymaps) gets `reveal_force_cwd = true`.

- **Module:** [`features/nav/cwd_sync/init.lua`](../../lua/filetree/features/nav/cwd_sync/init.lua)
- **Config:** `opts.features.cwd_sync` — `enabled` (default **false**, opt-in), `debounce_ms` (150), `parent_levels` (0), `keep_focus` (true), `change_dir` (true — never prompts), `reveal` (true, per-adapter caveat above), `use_project_root` (true), `root_markers` (`{".git"}`)

## Project Root

Shared, cached project-root detection used by `cwd_sync` and other
features that need "which project is this file in" without a policy
attached. Walks up from a file/directory for any of `markers` (`.git`,
`package.json`, `Cargo.toml`, `go.mod`, ... — a broad default list), returns
the deepest directory holding one, and falls back to the file's own parent
(or cwd, with `fallback = "cwd"`) when nothing is found. Every directory
resolved — not just the query directory, every intermediate directory
walked past en route — is cached for the session.

`cwd_mode.resolve()` is the plugin's one canonical marker-based walk when
`cwd_mode` is enabled; `project_root` (and `cwd_sync.root_markers`) is the
fallback path for a `cwd_mode`-less setup, so a repo running both doesn't
end up with the cwd anchored to the git root while a search scopes itself
to the nearest `package.json`.

- **Module:** [`features/infra/project_root/init.lua`](../../lua/filetree/features/infra/project_root/init.lua) (`M.clear_cache`, `M.add_markers`)
- **Config:** `opts.features.project_root` — `enabled` (default `true`), `markers`, `fallback` (`"parent"|"cwd"`), `cache` (default `true`)

## Ignore List

Hides common filesystem clutter from the tree by default — `.git`,
`.github`, `node_modules`, `.venv`, `__pycache__`, build/`dist`/`target`
directories, `.DS_Store`, editor dirs, and similar. Toggle at runtime with
the adapter's own native "show hidden" key (`H` on neo-tree/nvim-tree).

- **Module:** [`features/infra/ignore_list/init.lua`](../../lua/filetree/features/infra/ignore_list/init.lua)
- **Config:** top-level `opts.ignore_list` — `true` (default, built-in list, also reads `lib.nvim` config if present), `false` (show everything), or a `string[]` that fully replaces the built-in list

## Hooks API

Programmatic hook registration so other code (or a user's own config) can
react to tree events without patching filetree itself.

- **Module:** [`features/infra/hooks_api/init.lua`](../../lua/filetree/features/infra/hooks_api/init.lua)
- **Usercmds:** `:Filetree hooks events`, `:Filetree hooks clear [event]`

## Safety / Backup

An opt-in backup **API** with no keymaps of its own — enabling it has no
visible effect on its own; other features (`smart_rename`, `trash`) call
into it when their own `use_safety`/`use_safety` option is set. Copies a
file to a backup directory before a destructive op runs, with an optional
dry-run mode that only logs what would happen.

```lua
local safety = require("filetree").feature("safety")
local bak = safety.before_delete("/path/to/file.lua")
safety.before_move("/path/src.lua", "/path/dst.lua")
safety.list_backups()
safety.toggle_dry_run()
```

- **Module:** [`features/infra/safety/init.lua`](../../lua/filetree/features/infra/safety/init.lua), [`features/infra/safety/backup.lua`](../../lua/filetree/features/infra/safety/backup.lua)
- **Config:** `opts.features.safety` — `enabled` (default **false**), `backup_dir` (default `stdpath("data")/filetree/backups`), `max_backups` (5), `dry_run` (false)
- **Usercmds:** `:Filetree safety list`, `:Filetree safety dry-run`
