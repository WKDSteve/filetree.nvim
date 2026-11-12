# TESTS/

Everything CI runs, plus the manual pass it cannot.

| | |
| --- | --- |
| [`smoke.lua`](smoke.lua) | integration: every feature module loads, opt-out defaults resolve, registry resolver + binding catalog work, every `:Filetree` route and positional argument has a text for the option float; repo hygiene: no code, test or doc file points into the author's private notes vault |
| [`units.lua`](units.lua) | unit: util layer, neo-tree adapter helpers, the reference engine's apply/undo layer and the chooser, and `context_menu`'s click handling (headless, so CI-gated): only a text row of the tree window opens the menu — not the row right below the last line, far below it, the statusline/separator/winbar (`line == 0`), the tabline (`winid == 0`) or another window; a wrapped last line counts on every one of its rows; a tree scrolled sideways (where `screenpos()` of the last line is off screen) still guards correctly |
| [`menu.lua`](menu.lua) | unit: `integrations/menu.lua`, against a stubbed `filetree` module |
| [`cwd_mode.lua`](cwd_mode.lua) | unit: the cwd/root policy feature, against a stub adapter and a temp tree |
| [`sidebar_guard.lua`](sidebar_guard.lua) | unit: `&winfixbuf` pinning of the tree window, neo-tree event (un)subscription, no-op on a non-neotree adapter |
| [`kit_slot.lua`](kit_slot.lua) | unit: `ui/kit_slot` registers the tree at `lib.nvim.ui.kit.sidebar.register_foreign` (stub adapter, real kit): a kit sidebar and the tree share one slot both ways, a floating tree takes none, the name option, teardown |
| [`nav_switch_toggle.lua`](nav_switch_toggle.lua) | unit: `source_switcher` (pick / cycle / display names for neo-tree sources, and the optional `tests` source being found by the module neo-tree-tests-source.nvim really ships, without loading neotest) and `tree_toggle` (global positional toggle keys), plus the neo-tree adapter's E95 self-heal in `toggle_at` and the bookkeeping of its `renderer.redraw` hook install (a failed wrap is never marked as installed; a reload re-points instead of stacking), `on_render`'s late install for a lazily-loaded neo-tree (armed after the retries, deleted on unsubscribe) and the `package.preload` hoist not poisoning a neo-tree that arrives later — against a stubbed `neo-tree` / `neo-tree.command` / `neo-tree.ui.renderer` |
| [`config_schema.lua`](config_schema.lua) | unit: the per-feature option schemas (`filetree.config.schema`) — the engine, the `setup()` paths (typo, wrong type, out-of-range, non-table body, the deprecated `refs` options), and a drift check that every feature module exports a `SCHEMA` accepting its own defaults and declaring every option it reads |
| [`create_from_template.lua`](create_from_template.lua) | unit: `create_from_template`'s template-first flow — `M.move` never crossing the `[custom]`/`[builtin]` boundary, header rows only for mixed sets, filename pre-filled from the picked template, and the reorderable picker's cursor kept off header rows (against a `ui.kit` picker double that owns a real results window); on the pickers.nvim path the four shipped `*.lua.tpl` templates are previewed as Lua (not smarty), while other `.tpl` files and user templates keep their filetype (against a `pickers.engines` stand-in) |
| [`cheatsheet.lua`](cheatsheet.lua) | unit: the paged `?` cheatsheet, the `integrations.pickers` opt-out (filetree keys / other buffer keys / commands, `<Tab>` paging and wrap-around, `<leader>` display) and the pickers.nvim bridge (`util/pickers`, soft dependency) against stand-in `pickers.*` modules |
| [`keys.lua`](keys.lua) | unit: keys claimed twice (`util/key_conflicts`) — the shipped defaults claim none with every keymap feature on; a forced clash is found, the live owner identified (incl. Ctrl keys, whose `lhsraw` Vim tags), recommended alternatives are free (prefix-safe, family-first), moving a claim rebinds open and later trees and yields the `setup()` fragment; the cheatsheet's conflicts page and its `<CR>` flow |
| [`file_clipboard.lua`](file_clipboard.lua) | unit: `features/system/file_clipboard` — what each platform's clipboard tool is handed (exact argv / stdin / environment) for awkward names (space, `&`, `'`, `$`, `[ ]`, umlauts, POSIX backslashes), `backend.run` (spawner arguments, exit code / signal / timeout / spawn failure, first-stderr-line, the absolute PowerShell path; once against a stubbed `vim.system`, once really spawning this nvim as a stand-in tool), the target choice (marks else the cursor node, marks left alone, stale paths skipped) and the messages with their levels, against a stubbed backend; plus an opt-in real Windows round trip (`FILETREE_TEST_REAL_CLIPBOARD=1`, overwrites the clipboard). The key and `:Filetree clipfiles` wiring is pinned in `keys.lua` |
| [`compress_spec.lua`](compress_spec.lua) | unit: `features/system/compress` — the argv `zip` and a bsdtar are handed (`zip` only from one folder, one `-C` per source for bsdtar, a name starting with `-` passed as `./name`), the naming (`<name>.zip` beside the source, `_2`/`_3` instead of overwriting, the answer to the `together` prompt, no zip inside a folder it compresses), the target choice (marks else the cursor node, stale marks dropped) against a stub adapter and marks; plus a real round trip with whichever tool the machine has (skipped without one): a folder with its contents and two marked files, sources left alone |
| [`who_locks.lua`](who_locks.lua) | unit: `features/infra/who_locks` — the `--json` report against a stubbed neo-tree `fs_watch` upvalue and a `lib.nvim.cross.fs.lock` double (watchers ok / unreachable / not loaded) |
| [`env_roots.lua`](env_roots.lua) | unit: the named-root layer (`util/env_roots`, top-level `env_roots` option) — `fold` (env var / `$NVIM_CONFIG_DIR` without a variable / user-defined roots, longest match, `enable = false`, `force`), `expand`, `remap` (a path recorded on another machine re-anchored under this one's roots), the config validation, and where it is applied: `path_copy`'s absolute formats and the absolute file lists staying real while `env_rooted` folds, the inserted Markdown link, a created symlink (relative inside one root, also when another plugin registered a root inside it, absolute across two, `relative = "never"/"always"`), and the refs engine's `$VAR` / `${VAR}` / `%VAR%` link targets (resolved, and refolded in the spelling they were written in) |
| [`marks_auto_clear.lua`](marks_auto_clear.lua) | unit: `features/org/marks`' idle timeout `marks.auto_clear_ms` — `touch()` on every mark-facing keymap handler and not on the read-only `is_marked`/`get_marked`/`count` checks (against a recording `lib.nvim.debounce` double), what the fired callback does (clear + one notify, silent on an empty set), `clear_all`/`teardown`/re-`setup()` cancelling the pending handle, `auto_clear_ms = 0` building none; once end to end with the real timer (idle clear and its checkmarks, re-arm restarts the full delay, `clear_all`/`teardown`/re-`setup()` leave no armed timer behind — counted via `uv.walk`). Also pins `mark_visual(true)` really unmarking |
| [`marks_order.lua`](marks_order.lua) | unit: `features/org/marks`' output order `marks.order` — default `"marked"` (three marks in scrambled order come back as set, unmark + re-mark moves to the end, bulk marks (mark all visible and a Visual selection) number only new nodes in tree order behind existing ones, folders and files mixed), `"tree"` (sorted by full path), schema rejects other values, `DEFAULTS` carries the default; end to end through `path_copy` (clipboard lines in mark order) |
| [`sibling_nav.lua`](sibling_nav.lua) | unit: `features/nav/tree_traverse`' sibling jumps (`]s`/`[s`) on a stub adapter — nested tree: the jump skips the children of an expanded sibling, stops at the parent's first/last child and never climbs out of the cursor's folder; count moves N siblings (clamped); `sibling_wrap = true` wraps inside the parent; a flat depth-1 listing (mini.files, netrw, oil) degrades to plain next/previous; schema declares the new options |
| [`quickpick.lua`](quickpick.lua) | unit: `features/nav/quickpick`, the numbered quick-pick mode -- the pure numbering and input parser (content filter, viewport range, ordering by rendered line, the 10^width cap, the tree's root never numbered, the prefix/digit/backspace state machine, indicator text and geometry); the order `get_visible_nodes` hands over per adapter (the real mini.files, oil and netrw adapters against stand-ins, neo-tree and nvim-tree as shaped doubles); and the lifecycle against a fake tree adapter that owns a real buffer and window, driven with `nvim_feedkeys` through the real buffer-local keys: start/open/prefixes, folder toggling and renumbering, content cycling, Esc, the idle timeout and its restart, silencing, exact restore of the tree's own mapping on a key the mode took over, focus loss / window close / buffer wipe, scroll and resize, boot of a closed tree (count, cwd, a tree that never opens), no leaked timer/autocmd/extmark/float, plus `setup()` wiring (global keys with a count, `:Filetree quickpick`, config validation) |
| [`quickpick_neotree.lua`](quickpick_neotree.lua) | integration: the same mode against a **real neo-tree**, in its own process -- boot of a closed tree, labels on the lines of the nodes they name, the tree's root line unlabelled, a never-opened folder really loading and renumbering, a `v`-prefixed open landing in a new split beside the editor, neo-tree's own buffer-local keys identical afterwards. Prints a skip without neo-tree; not part of CI |
| [`gaps.lua`](gaps.lua) | unit: fs-heavy and lifecycle modules `units.lua`/`smoke.lua` had not reached yet — see "gaps.lua" below |
| [`adapter_lines.lua`](adapter_lines.lua) | integration: the adapter's line→node mapping, against a **real neo-tree and a real nvim-tree** — the only suite that needs a tree plugin — plus three neo-tree-only regression pins: a background-tab redraw resolving the tree's own per-tab state (not whichever tab is current), two simultaneously live per-tab trees each resolving and decorating their own tree without bleeding into the other's, the right-click menu (`context_menu`, real kit menu) acting on the clicked node rather than the line neo-tree had remembered before the click and ignoring clicks below the last node / on line 0 / in another window, and the `is_expanded` tri-state of the node contract (`true`/`false` for a directory, `nil` for a file) on both backends |
| [`group_empty_dirs_collapse.lua`](group_empty_dirs_collapse.lua) | integration: `<S-CR>` (`open_variants.open_badd_or_collapse`) collapsing a neo-tree `group_empty_dirs` merged directory line, against a **real neo-tree** — drives the actual `<CR>`/`<S-CR>` buffer keymaps, not the adapter function directly |
| [`neotree_redraw_hook.lua`](neotree_redraw_hook.lua) | integration: the `renderer.redraw` monkeypatch (`adapter/neotree.lua`'s `install_redraw_hook`/`hoist_redraw_hook`) against a **real neo-tree**, run in its own process — real `copy_to_clipboard`/`cut_to_clipboard` (`y`/`x`) in the exact load order a lazily-loaded neo-tree.nvim gives, and the last-resort tab probe's ghost-state cleanup |
| [`neotree_collapse_redraw_coalesce.lua`](neotree_collapse_redraw_coalesce.lua) | integration: `adapter/neotree.lua`'s `M.redraw_soon()` coalescing helper against a **real neo-tree** — a burst of `redraw_soon()` calls settles into exactly one real `renderer.redraw`, `M.redraw()`/`collapse_node` stay synchronous and immediate. Investigated as part of the "modified" icon blinking on folder collapse; `opened_sync` (the original motivating caller) turned out not to need it and now calls `redraw()` directly, so no production call site uses `redraw_soon` today |
| [`collapse_all_backends.lua`](collapse_all_backends.lua) | integration: `adapter.collapse_all` and `tree_toggle.collapse_on_toggle` against a **real neo-tree** (and nvim-tree when installed) — folders opened by hand (neo-tree's own `toggle_directory`) close on the next open, only the current file's chain stays; also after a close by `nvim_win_close`; a file outside the root keeps nothing; `collapse_all()` lands on the top-level entry; with the option off the folders stay open as before; a `group_empty_dirs` line is back to its first folder; on nvim-tree the kept chain and the cursor on the top-level entry. Read back through neo-tree's own `renderer.get_expanded_nodes`. Not part of CI; the gated counterpart (which tab, a chain through a junction, another spelling of the root, the merged-line refresh) is in `units.lua` |
| [`sheets_spec.lua`](sheets_spec.lua) + [`sheets/`](sheets/) | test sheets (testing.nvim `testing.sheet`): the automated half of a live check, each sheet one case `sheet:<id>`, run by the RPC klicker in a child editor and compared with screen snapshots under `__snapshots__/sheets/`. `diag-badges-neotree.sheet.lua` puts a **real neo-tree** (child editor from [`minimal_init_sheet_neotree.lua`](minimal_init_sheet_neotree.lua)) under `lsp_diagnostics`: badges on the file nodes and the folders, still there after neo-tree's own redraw and a focus change, gone with the diagnostics. Gated on CI, which checks out neo-tree, nui and plenary at pinned commits for it — see "Test sheets" below |
| [`refs/`](refs/) | fixture-based: real on-disk multi-file projects, described below |
| [`MANUAL.md`](MANUAL.md) | the manual checklist for what a headless run cannot reach — real neo-tree, real floats, real clipboard |

## Running

The suite is run by [testing.nvim](https://github.com/WKDSteve/testing.nvim),
configured in [`.testing.lua`](../.testing.lua) (the `spec_pattern` lists the
files CI gates on: the files here carry no `_spec` suffix, and
`refs/run.lua` is a spec, not a runner). Every file is a self-running script
(dialect `script`): one child nvim per file, exit code and printed `[FAIL]`
lines are the verdict.

```
bash scripts/test.sh                      # every gated spec
bash scripts/test.sh --file keys          # only files whose name contains "keys"
bash scripts/test.sh --json ir.json       # also write the machine-readable result
```

`scripts/test.sh` finds testing.nvim, lib.nvim and ui.nvim via
`$TESTING_NVIM_DIR` / `$LIB_NVIM_DIR` / `$UI_NVIM_DIR`, `.deps/<name>`, a
sibling checkout `../<name>` or `stdpath("data")/lazy/<name>`, and exits 1
when one is missing. A single file can still be run directly, e.g.
`nvim -n --clean --headless -u NONE -l TESTS/keys.lua`; the real-neo-tree
suites below are not part of the gated set and are started that way.

All of them are headless and exit 0 on a pass. `.github/workflows/ci.yml`'s
`test` job gates on the stub-based suites above `adapter_lines.lua` in
the table, plus `refs/run.lua` and the test sheets. It checks out neo-tree/nui/plenary
(pinned) as siblings for the sheets; the four real-neo-tree suites (`adapter_lines.lua`,
`group_empty_dirs_collapse.lua`, `neotree_redraw_hook.lua`,
`neotree_collapse_redraw_coalesce.lua`) would find them there, but they are not in the
`spec_pattern` of `.testing.lua`, so CI does not run them. Adding them is a step of its own.
`quickpick_neotree.lua` is a fifth of the
same kind (it sits beside `quickpick.lua` in the table but CI does not run it).
All but those run against a
stub adapter and need no tree plugin; those four need neo-tree (plus
nui/plenary/devicons, and lib.nvim for the first) and print a skip instead
of failing when they are absent, because what they test needs a real
backend: `adapter_lines.lua`'s line→node mapping is precisely what a stub
cannot have, `group_empty_dirs_collapse.lua` exercises neo-tree's own
merge/replace machinery (`ui/renderer.lua`'s `group_empty_dirs` branch),
`neotree_redraw_hook.lua` needs a real, controllable `require()` order against
neo-tree's own modules that a stub cannot reproduce, and
`neotree_collapse_redraw_coalesce.lua` needs a real `<CR>`-driven directory
expand (async fs-scan) and a real `renderer.redraw` to wrap-count. `MANUAL.md`
describes each in more detail and carries the lib.nvim resolution notes.

`neotree_redraw_hook.lua` deliberately reloads core neo-tree modules and
controls their `require()` order, which no other suite in this repo may
safely do once it shares a process with other neo-tree-backed checks — so it
runs in its OWN `nvim -l` process rather than being folded into
`adapter_lines.lua`.

## Test sheets

A test sheet (`sheets/<name>.sheet.lua`, format in testing.nvim's `docs/SHEETS.md`) writes a
live check down as data: the steps a machine can do run with the suite, `judge` and `manual`
are what is left for a person. `testing sheets report` lists them (review inbox).

`sheets_spec.lua` is the only busted-dialect spec here (`.testing.lua` `dialect`). The neo-tree
sheet's child editor finds neo-tree.nvim, nui.nvim and plenary.nvim via `$NEO_TREE_NVIM_DIR` /
`$NUI_NVIM_DIR` / `$PLENARY_NVIM_DIR`, `.deps/<name>`, a sibling checkout `../<name>` or the
lazy.nvim directory of the real editor, and fails naming every place when one is missing. The
snapshots were taken with the commits CI pins in `.github/workflows/ci.yml`: a local neo-tree far
from those may draw the tree differently (update with `--update-snapshots` only after checking the
pin). The sheet turns neo-tree's window-size poll (`resize_timer_interval = -1`) and filetree's
`file_watcher` off: both keep a handle alive for ever and the editor would never settle.

## gaps.lua

Added in the test-coverage campaign's round 26 pass over this repo (129
`lua/` files is too large for one uniform pass — see the campaign handover
for the full accounting). Split into its own file rather than appended to
`units.lua`, which was already ~5000 lines. Same framework-free
`check`/`eq` harness and rtp/`TMP_ROOT` setup as `units.lua`.

Covers, with real (not merely load-time) assertions, in risk order:

- **fs ops / argv / error paths**: `util/conflict.lua` (collision-name
  generation, incl. dotfile and multi-dot-extension edge cases),
  `refs/pathutil.lua` (the reference engine's Windows-safe path core —
  backslash/forward-slash equivalence, case-insensitive comparison, the
  three `resolve_candidates()` target styles, `retarget()`'s per-style
  spelling, `remap_under()`'s directory-move cascade), `util/markdown_refs.lua`
  (disk + live-buffer patch layer, content-verified skip of a drifted line),
  `features/infra/safety/backup.lua` (real mkdir/copy/prune against a
  **stubbed `lib.nvim.cross.run_argv`** — no real `xcopy`/`cp` process
  spawned, but the real argv shape is asserted), `features/fileops/buffer_save`
  (force-save the adjacent editor buffer or the node under the cursor, incl.
  three no-crash error paths).
- **the refs↔fileops.nvim bridge**: a contract pin asserting
  `filetree.refs.outgoing_assets`/`outgoing_assets_mode` are still functions
  — the exact two-function presence check fileops.nvim's
  `integrations/filetree_assets.lua` uses to decide filetree.nvim is
  installed and current enough to cascade-delete assets through.
- **caching / state machines**: `features/infra/watcher_quarantine.lua`
  (enter/exit/is_active/is_path_quarantined, the `vim.notify` EPERM-swallow
  patch and its exact restore, `wrap()`'s error passthrough).
- **buffer/window lifecycle**: `features/fileops/open_replace.lua`
  (replace vs. swap, the modified-buffer refusal that avoids E89, the
  already-open-file short-circuit, the closed buffer's slot), `features/nav/layout_guard.lua`
  (a new editor window appears when the last one closes next to the tree;
  no-op when the tree itself is reported closed).
- **adapter helpers**: `adapter/mini_files.lua`, stubbed at `mini.files` in
  `package.loaded` — same pattern as the existing neo-tree adapter-helpers
  suite in `units.lua`, including the adapter's own documented doubled-slash
  quirk after a Windows drive letter.
- **no subprocess needed, previously untested**: `features/lsp/lsp_diagnostics.lua`
  (severity aggregation, incl. a directory node summing its children, and the
  default badge's prefix: the `icons` option, then the sign texts from
  `vim.diagnostic.config()`, then the `E:`/`W:` fallback) against real `vim.diagnostic.set()`; `features/compare/diff.lua` (stage/diff/
  diff_marked's exactly-2-marks gate); `features/git/git_status.lua`
  (`git status --porcelain` line parsing for every status code, incl. a
  quoted rename, against a **stubbed `vim.system`** — no real git process).

Deliberately not added in this pass (left for a later round, not because
they are exempt from the "raise coverage" goal):

- `features/system/shell_run.lua` (real `termopen`/`jobstart` terminal
  spawn), `features/system/open_with.lua` (a detached `vim.system` +
  `vim.ui.open`, meant to hand off to an OS app and not come back) — no
  stable stub seam short of replacing those vim.fn entry points wholesale.
- `features/system/pdf_create.lua`/`pdf_open.lua` — delegate to
  `util/pdf.lua`'s soft dependency on pdfport.nvim; not audited deeply
  enough this round to say whether that wrapper is cleanly stubbable the
  way `util/markdown_refs.lua`'s soft dependency was.
- `features/org/session.lua` — real fs read/write is straightforward to
  stub, but its `VimLeavePre`/`BufHidden` autosave timing and stdpath("data")
  override need more care than this pass's budget allowed.
- `util/usercmd.lua`, `util/progress.lua` — thin present/absent dependency
  wrappers (same shape as the existing "util.map / util.autocmd" section in
  `units.lua`); low risk, cheap to add, just not reached this round.
- `util/bind.lua` — already exercised indirectly by every feature's own
  keymap-binding tests; a dedicated suite would mostly repeat that coverage.

Round 26 also flagged `features/infra/file_watcher.lua`,
`features/nav/{auto_reveal,buffer_cycle,reveal_alt,tree_traverse}.lua`,
`features/paths/lua_require_copy.lua`, `features/search/{filter,live_search}.lua`,
and `features/ui/{window_style,window_size_cycler,cursor_hide,tree_reset,size_info,preview}.lua`
as confirmed genuinely untested beyond a load-time `require()`, for a later
round to pick up next. Round 27 (below) is that round, and closes all of
them.

### Round 27 (follow-up to round 26; still `gaps.lua`)

Closed every file round 26's list above deferred. Also re-audited round 26's
other skip reasons for rot before adding anything new: `features/system/shell_run.lua`,
`open_with.lua`, `pdf_create.lua`/`pdf_open.lua`, `org/session.lua`,
`util/usercmd.lua`, `util/progress.lua`, and `util/bind.lua` are all still
accurately described above — none gained a stub seam or a sibling-checkout
dependency since. neo-tree.nvim/nui.nvim/plenary.nvim/nvim-web-devicons are
real installs on a dev machine under `$LOCALAPPDATA/nvim-data/lazy`, and
`adapter_lines.lua`'s own candidate search already finds them there (that
suite is simply not one of the seven CI runs — it needs a real tree plugin
and prints a skip without one, which is what CI would get); nothing to close
there.

Covers, with real assertions, in risk order:

- **Windows path/separator + navigation** (highest risk: this is a file-tree
  UI with cursor/line navigation): `nav/auto_reveal.lua`'s `under_root()`
  exercised with a backslash-spelled adapter root against a forward-slash
  buffer path (both readings must agree it is inside), the `cursor_in_tree`
  guard (a forced `reveal_current()` while the cursor sits IN the tree must
  never fire `open_reveal`), and the `only_if_open` guard; `paths/lua_require_copy.lua`'s
  `copy_require_relative()` against the REAL `getcwd()` on this platform
  (Windows hands back backslashes regardless of how `:cd` was spelled);
  `nav/tree_traverse.lua`'s filesystem-root guard (walks to the real OS root
  via `fnamemodify(...,":h")`'s own fixed point, not a guessed drive-letter
  string) and its `cwd_mode.notify_manual_root` cross-feature notification.
- **keymap-bound features with no exported entry point**, driven through a
  real `filetree.setup()` plus a real `FileType`-fired tree buffer (the same
  mechanism `units.lua`'s own keymap-override tests use): `nav/reveal_alt.lua`
  (`B`, incl. the alternate-buffer-vanished guard), `ui/tree_reset.lua` (`<Esc>`
  fanning out to preview/filter/watcher_quarantine, real state checked before
  and after), `ui/window_style.lua` (statusline blanking + highlight
  isolation, incl. the WinEnter re-assert and an adapter-declared
  `filetypes`/`hl_groups` table replacing the default superset), `ui/cursor_hide.lua`
  (real `lib.nvim.ui.winhighlight` merge-in/strip-out on enter/leave),
  `ui/window_size_cycler.lua` (real window-width changes via
  `nvim_win_set_width`, incl. `2w` jumping straight to preset #2 instead of
  looping two steps, and an out-of-range count clamped to the last preset).
- **exported functions, called directly**: `nav/buffer_cycle.lua` (`<C-n>`/`<C-p>`
  cycling a REAL adjacent editor window while focus stays in the tree),
  `search/filter.lua` (extmark dimming, the native-backend-selected-but-not-installed
  fallback path this campaign's own regression note describes, and `enter()`
  via a stubbed `ui.kit.live_input`), `search/live_search.lua` (match="name"
  vs. match="path", and `commit_to_filter` handing the query to the real
  `filter` feature), `ui/size_info.lua` (real file sizes via `uv.fs_stat`,
  async directory sizes via a stubbed `vim.system` exercising the real
  POSIX/Windows command branch and its output parsing — the same seam this
  campaign already uses for `git_status.lua`), `ui/preview.lua` (float-mode
  text/hex/directory rendering in a real floating window, buffer-mode
  showing/restoring the adjacent editor window's buffer, the image/pdf
  dispatch guard with `backend = false`, buffer mode never loading a binary
  or over-`max_bytes` file (also while the cursor follows), the NUL probe for
  files of unknown type, and the exact argv of the Windows system-open).
- **libuv, for real, no stub**: `infra/file_watcher.lua` — a real
  `vim.uv.new_fs_event()` watching a real temp directory, a real file written
  into it, the debounced `adapter.refresh()` actually firing, and re-`setup()`
  not doubling its own `DirChanged` autocmd.

One genuine bug found and fixed directly, in test infrastructure rather than
shipped code: the `filetree.health` regression test above (pinned in round
26) simulates `lib.nvim.bindings.usercmd.composer` being unavailable and
calls `health.check()`, which itself does `pcall(require, "filetree")`. If
nothing in the process had required the bare `filetree` module before that
point, this was the first attempt — and `filetree.commands` requires
`composer` unconditionally (no pcall; see its own file header), so loading
`filetree` for the first time while composer is sabotaged throws for real.
`health.check()`'s own pcall swallows that fine, but Lua's module loader then
permanently caches `filetree` (and `filetree.commands`) as failed, so every
LATER `require("filetree")` in the same process fails with "loop or previous
error loading module" even after composer is restored right after — exactly
what broke this round's own `reveal_alt`/`window_style`/etc. sections the
first time *they* called the real `require("filetree")`. Fixed by clearing
those two cache entries once the health test finishes restoring its own
state, right where composer itself is restored.

Two more bugs, also in this test file rather than the plugin: `nav.reveal_alt`'s
test used `:edit` to bring a real alternate-file buffer into the SAME window
an about-to-be-current empty scratch tree buffer already occupied — Vim's own
`:edit` recycles the CURRENT buffer's number when it is empty/unnamed/unmodified,
which silently wiped the tree buffer's just-bound keymaps; fixed by editing
the other file *before* the tree buffer becomes current, and by switching a
second stand-in buffer in via `bufadd()` + `:buffer` (existing buffer
numbers, so no new-buffer-reuse) rather than a second `:edit`. `ui.window_size_cycler`'s
test resized a window that was the ONLY window in its tabpage — with no
sibling column to redistribute space from or to, `nvim_win_set_width` on it
is a no-op — fixed by adding a real sibling split first.

## refs/

Fixture-based regression tests that need real, on-disk multi-file projects —
too heavy for the unit-style checks above, which run against in-memory stubs.
Self-contained: fixtures plus a runnable `run.lua`.

Verifies the reference engine ([`lua/filetree/refs/`](../lua/filetree/refs/))
and the features that drive it: cross-file references — markdown links,
`require()`/`import` statements — must follow a file when it is renamed or
moved, and must NOT follow a similar-but-different name.

Run it from the repo root:

```
nvim --clean --headless -u NONE -l TESTS/refs/run.lua
```

For each language it copies `fixtures/<lang>/` to a scratch temp dir, renames
the "hub" module through the real feature (`smart_rename.rename_current()`
with a stubbed adapter and a stubbed `kit.input` — no tree plugin, no LSP
server, no floating window), and asserts every referencing file was rewritten
— plus a negative control that must stay untouched. It also covers the
directory-rename submodule cascade, the live-buffer patch (references in an
open buffer are patched in memory, not only on disk), the `M` move feature,
and `refs undo`.

The engine runs in `auto` mode there: the chooser is UI, covered by
`TESTS/units.lua`; this suite is about what lands on disk.

`refs/usage.lua` is the second, independent script here: it tests the batched
reference counter (`filetree.refs.usage`) on a scratch project -- once-, twice-
and never-referenced files, a look-alike name, a URL-encoded space, a file
linking to itself and a 400-path sweep that takes ripgrep's stdin pattern path --
with ripgrep and again through the walk fallback.

```
nvim --clean --headless -u NONE -l TESTS/refs/usage.lua
```

Currently covers Lua, Python, TS/JS (incl. `.tsx`/dynamic `import()`) and
Markdown (inline links, HTML `href=`, reference definitions).

To add another language: drop a `fixtures/<lang>/` tree with a project marker
file (anything in `project_root`'s marker list works — `.luarc.json`,
`pyproject.toml`, `package.json`, `Cargo.toml`, `go.mod`, ...) and add a
`LANGS` entry in `run.lua` pointing at the hub file and the files that
reference it. Note: a language needs a provider in
[`lua/filetree/refs/providers/`](../lua/filetree/refs/providers/) before a
fixture for it will do anything.
