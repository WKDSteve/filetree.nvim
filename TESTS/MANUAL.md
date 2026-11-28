# filetree.nvim — manual integration test guide

A manual pass: neo-tree plus filetree.nvim, without a real user config.

---

## Automated tests

Headless, no tree plugin needed (stub adapter). Exit 0 = pass, 1 = fail.

- **[smoke.lua](smoke.lua)** — integration: every feature module loads, opt-out
  defaults resolve, registry resolver + binding catalog work.
- **[units.lua](units.lua)** — unit: the util layer (path, buffer, line_count,
  map/autocmd, select adapter) + neo-tree adapter helpers + the reference
  engine's apply/undo layer and the chooser each fileops feature drives.
- **[menu.lua](menu.lua)** — unit: `integrations/menu.lua` (context-menu
  entries). Stubs the top-level `filetree` module (`feature()`/`config()`) so it
  runs without a real adapter/tree window — the exact seam a host (RightMouse
  dispatcher) uses. Covers entries building, self-gating on feature
  availability, group-level opt-out (`config.menu`), the master `enable=false`
  switch, `cmd()` calling through, and `submenu()`.

- **[cwd_mode.lua](cwd_mode.lua)** — unit: the cwd/root policy feature. Decision
  logic per mode (follow/project/lock/manual), sticky project roots, lock
  enforcement against a foreign `:cd`, manual re-rooting, the mode cycle, the
  tree-window badge in both drawing strategies, and the `:Filetree cwd …`
  command wiring incl. enum completion. Uses a stub adapter and a temp tree.

- **[adapter_lines.lua](adapter_lines.lua)** — integration: the adapter's
  `get_node_at_line(bufnr, linenr)` and the four features that decorate a node
  line through it (git_status, lsp_diagnostics, size_info, copy_move's
  clipboard marker), plus `filter`'s dim fallback with the native filter
  forced off. The only suite that drives real backends: it opens a real
  neo-tree and a real nvim-tree over a real git repo, running the same
  assertions against each, and every check resolves the line an extmark
  actually landed on and compares it against the node that mark is about — an
  off-by-one resolves every line too, just to its neighbour, which is exactly
  the bug worth catching. It also pins the per-call cost, which is how a
  filesystem stat per node per render got caught.

  Each backend is skipped (exit 0, with a note) when it is not installed, so
  the suite is useful with either one alone. `$FILETREE_NEOTREE` and
  `$FILETREE_NVIMTREE` point at checkouts; `$FILETREE_ADAPTER_LINES=nvimtree`
  limits a run to one backend.

- **[group_empty_dirs_collapse.lua](group_empty_dirs_collapse.lua)** —
  integration: `<S-CR>` (`open_variants.open_badd_or_collapse`, dispatching to
  `adapter/neotree.lua`'s `collapse_node`) collapsing a neo-tree
  `group_empty_dirs` merged directory line — the "personal/All/Finish on one
  row" display for a chain of directories holding nothing but another single
  directory. Drives the real `<CR>`/`<S-CR>` buffer keymaps against a real
  neo-tree (not the adapter function directly, and not `fscommands.open()`
  either — confirmed by hand that call no-ops from a scripted context; only
  the actual bound keymap goes through neo-tree's real dispatch), over a real
  fixture tree, and asserts three things: `<CR>` merging one level at a time
  (`personal` → `personal\All` → `personal\All\Finish`), that a further `<CR>`
  on the merged line only ever drills deeper (the bug — no toggle back), and
  that `<S-CR>` gets it back to a plain collapsed `personal` line either way.
  The real merge/replace goes through an async fs scan that can noticeably
  outlast a short fixed sleep, so every step polls (up to 8s) instead.
  Needs neo-tree, nui, plenary, nvim-web-devicons and lib.nvim — same
  resolution rules as `adapter_lines.lua`, skips (exit 0) without them.

- **[neotree_redraw_hook.lua](neotree_redraw_hook.lua)** — integration: the
  `renderer.redraw` monkeypatch in `adapter/neotree.lua` (`install_redraw_hook`/
  `hoist_redraw_hook`), against a real neo-tree, run in its OWN `nvim -l`
  process (it deliberately reloads/controls the `require()` order of core
  neo-tree modules, which no other suite here may safely do once sharing a
  process with other neo-tree-backed checks). Part A pins the hardest case:
  neo-tree's own `sources/filesystem/commands.lua` captures `renderer.redraw`
  into a plain Lua local at ITS OWN module-load time, so `copy_to_clipboard`/
  `cut_to_clipboard` (`y`/`x` by default) bypass a field-only patch entirely —
  reproduced with the same relative load order a lazily-loaded neo-tree.nvim
  gives (filetree loads and installs its `package.preload` hoist first, neo-tree's
  own `setup()` — which is what captures the local — runs second), then calls
  the real commands and asserts link_marker's/marks' decorations survive.
  Part B pins that `get_state()`'s last-resort tab probe never leaves a
  permanent ghost `filesystem` state behind for a tab it only checked.
  Needs neo-tree, nui, plenary, nvim-web-devicons and lib.nvim — same
  resolution rules as `adapter_lines.lua`, skips (exit 0) without them.

- **[neotree_collapse_redraw_coalesce.lua](neotree_collapse_redraw_coalesce.lua)** —
  integration: `adapter/neotree.lua`'s `M.redraw_soon()` coalescing helper,
  originally added as part of investigating the "modified"/"opened" icon
  blinking near a folder node right after it collapses. `opened_sync` — the
  original motivating caller — was later found to not actually need it (its
  own debounce already reduces a burst of buffer events to one call, so a
  second debounce on top only added latency for zero coalescing benefit —
  see `opened_sync`'s doc comment) and now calls `redraw()` directly; no
  production call site uses `redraw_soon` today. This suite verifies the
  primitive itself, in isolation, against a real neo-tree: wraps the real,
  already filetree-patched `renderer.redraw` with a counting shim and
  asserts a burst of `redraw_soon()` calls settles into exactly one real
  redraw once the coalescing window elapses, that `M.redraw()` itself (what
  `collapse_node`/`expand_node` use directly) stays synchronous with no
  coalescing delay, and that a real `<CR>`-expand-then-collapse via
  `collapse_node` still redraws immediately. Needs neo-tree, nui, plenary,
  nvim-web-devicons and lib.nvim — same resolution rules as
  `adapter_lines.lua`, skips (exit 0) without them.

- **[create_from_template.lua](create_from_template.lua)** — unit: the
  template-first flow of `create_from_template`. `M.move` never crossing the
  `[custom]`/`[builtin]` boundary (both ends, plus the persisted custom-then-builtin
  order file), header rows only for mixed sets, the filename prompt pre-filled
  with the picked template's own name (extension included), `<M-j>`/`<M-k>`
  reordering with the cursor following the row, and the cursor nudged off header
  rows. Runs against a `ui.kit` picker double that owns a real results window,
  so the cursor logic is genuine; a real picker's look/feel stays manual.

- **[sidebar_guard.lua](sidebar_guard.lua)** — unit: the `nav/sidebar_guard`
  feature. A window carrying a `neo-tree` filetype buffer plus a stub adapter
  and a stubbed `neo-tree.events` exercise the default redirect (a foreign
  buffer in the sidebar is moved to an editor window and the tree put back),
  the opt-in `winfixbuf` pin, the
  BEFORE/AFTER_OPEN lift for source switching, teardown, and the non-neotree
  no-op.

- **[refs/run.lua](refs/run.lua)** — fixture-based: copies
  `TESTS/refs/fixtures/<lang>/` to a scratch dir and renames the hub module
  through the real feature, asserting every referencing file was rewritten and a
  similar-but-different name was not. Covers the directory-rename cascade, the
  live-buffer patch, `M` move and `refs undo`. Runs on either candidate-search
  path — ripgrep when present, the capped fallback walk when not.

  Each wait for the asynchronous scan allows 30 s (`FILETREE_REFS_TEST_WAIT_MS`
  changes it); a wait that runs out is reported as `FAIL TIMEOUT …` and ends the
  run instead of turning into wrong-content failures. The default stays below
  the 60 s testing.nvim gives the whole file (`timeouts.file_ms`), so the
  runner's kill does not swallow that line; `.testing.lua` passes the
  `FILETREE_REFS_TEST_*` variables through, so under `scripts/test.sh` a higher
  limit works too (add `--file-timeout <ms>` when it exceeds the file's
  budget). The scratch dir is unique
  per run (`%TEMP%`/`/tmp` + `filetree-refs-test-<pid>-<hrtime>`), removed on a
  green run and kept (path printed) on a red one.
  `FILETREE_REFS_TEST_SCAN_DELAY_MS` holds back every scan result to simulate
  a loaded machine, and `FILETREE_REFS_TEST_ONLY=<lang>` runs a single LANGS
  entry; [refs/slow_scan_spec.lua](refs/slow_scan_spec.lua) uses both.

  Before each mutation it also asserts that every fixture really contains the
  string its spec expects to be rewritten. That guard exists because a spec and
  its fixture once disagreed about `require "m"` vs `require("m")`: the
  "updated" check then looked for a string that could never appear while its
  "old reference gone" partner passed vacuously, which reads like the engine
  skipping a file one level deeper — and was filed and carried as an
  apply-layer defect for three weeks.

Run them one at a time. Every suite works in fixed scratch directories under
$TEMP, so two instances of the same suite (or two suites sharing a fixture
root) race each other over the same files -- concurrent runs fail with
buffer/path mismatches that look like feature bugs and are not.

CI's exact list and order is the `test` job in `.github/workflows/ci.yml`
(every stub-based suite plus `refs/run.lua`). The suites that need a real
neo-tree (`adapter_lines.lua` and the other `neotree_*`/`group_empty_dirs_*`
ones) are NOT run there — run them locally:

```
cd /path/to/filetree.nvim
nvim --clean --headless -u NONE -l TESTS/smoke.lua
nvim --clean --headless -u NONE -l TESTS/units.lua
nvim --clean --headless -u NONE -l TESTS/menu.lua
nvim --clean --headless -u NONE -l TESTS/adapter_lines.lua   # local only: needs neo-tree
nvim --clean --headless -u NONE -l TESTS/refs/run.lua
```

**lib.nvim resolution:** every suite here — the `.lua` files and
`refs/run.lua` — resolves lib.nvim the same way, taking the first of:

1. `$FILETREE_LIB_NVIM`
2. `$LIB_NVIM_PATH` (lib.nvim's own canonical variable name)
3. a sibling `../lib.nvim` checkout — what CI uses
4. lazy.nvim's managed copy under `stdpath("data")/lazy/lib.nvim`

Both names are accepted by every suite, so one export runs the whole directory.
`adapter_lines.lua` resolves neo-tree, nui, plenary and nvim-web-devicons by
the same rules (`$FILETREE_NEOTREE` for neo-tree), and skips rather than fails
when it cannot find them. A worktree checkout has no sibling `../lib.nvim`, so
export one of the variables above when running from one.
Set either to point somewhere else — e.g. a lib.nvim worktree carrying modules a
new feature depends on that are not merged yet:

```
FILETREE_LIB_NVIM=/path/to/lib.nvim/.claude/worktrees/<name> \
  nvim --clean --headless -u NONE -l TESTS/cwd_mode.lua
```

The lazy fallback is what makes the suites runnable from a git worktree: there
`../lib.nvim` resolves inside `.claude/worktrees/` and does not exist, so
without it a variable would have to be exported just to start.

---

## Setup

```
cd /path/to/filetree.nvim
nvim --clean -u TESTS/minimal_neotree.lua .
```

On the first start, lazy.nvim downloads neo-tree and its dependencies into
`%TEMP%/filetree-test/`. That takes about 30 seconds. Afterwards nvim starts
with the repository root as its working directory.

**State dir:** `%TEMP%/filetree-test/` (Windows) / `/tmp/filetree-test/` (Unix)
Delete that folder to start over from scratch.

---

## Global test keymaps

| Key           | Action                                          |
|---------------|-------------------------------------------------|
| `<C-e>`       | toggle neo-tree                                 |
| `<leader>e`   | reveal the current file in the tree             |
| `<leader>H`   | open `:checkhealth filetree`                    |
| `<leader>fa`  | print the active adapter in a notification      |
| `<leader>fn`  | print the current tree node via `vim.inspect()` (cursor must be in the tree) |

---

## Checklist

### 0. Groundwork — before anything else

| # | Test | Expected | Result |
|---|------|----------|--------|
| 0.1 | `:checkhealth filetree` | Every adapter line OK/WARN, no ERROR; every feature either "enabled" or "not configured" | |
| 0.2 | `<leader>fa` | `"Active adapter: neotree"` in the notification | |
| 0.3 | `<C-e>` → tree opens, then `<leader>fn` | A node table appears: `{ id = "...", name = "...", type = "file"\|"directory", path = "...", ... }` | |
| 0.4 | `<leader>fn` with no tree open | Notification: `"No node under cursor"` — no error, no stack trace | |

---

### A. Adapter basics — current_hl

Exercises: `get_current_node()`, `get_visible_nodes()`, extmarks.

| # | Test | Expected |
|---|------|----------|
| A.1 | Open the tree (`<C-e>`), move the cursor inside it | The current line has the `CursorLine` highlight; the parent directory has the `Visual` one |
| A.2 | Move up/down in the tree (`j`/`k`) | The highlight follows the cursor with a slight delay (100 ms debounce) |
| A.3 | Close the tree, open a different file in the editor | On the next tree open, the highlight sits on the current file |

---

### B. CWD / reveal

Exercises: autocommands, `adapter.open_reveal()`.

| # | Test | Expected |
|---|------|----------|
| B.1 | Open a file (`:e lua/filetree/init.lua`) | The tree scrolls to it on its own (auto_reveal) |
| B.2 | After B.1: `:pwd` in the editor | Shows the directory of the file opened last (cwd_sync) |
| B.3 | `<leader>e` with the cursor on a file in the editor | The tree opens with the current file marked |
| B.4 | Open a file in a subdirectory | The cwd moves to that file's directory; the tree focuses it |

---

### C. Virtual text / extmarks — marks + git_status

Exercises: `nvim_buf_set_extmark`, end-of-line virtual text.

**marks** (keymap `m` in the tree):

| # | Test | Expected |
|---|------|----------|
| C.1 | Cursor on a file in the tree, press `m` | A green `✓` appears at the end of the line |
| C.2 | Press `m` again on the same file | The `✓` disappears (toggle) |
| C.3 | Mark several files | All of them show `✓` at once |
| C.4 | Close and reopen the tree within the idle timeout | The marks are still there — closing/reopening neither clears them nor restarts the idle countdown (see C.4c) |
| C.4c | Mark several files, then do nothing with the marks for `marks.auto_clear_ms` (60 s by default; set it lower to save time). Don't press any mark key, `gm`, `]M`/`[M` or `<leader>ms` in the meantime | A `[filetree.marks]` notification "Marks auto-cleared after 60s idle" appears, the `✓` disappear, and `<leader>ms` then says "No nodes marked". Pressing any mark key before the time is up (e.g. `m` on another file) restarts the full countdown. `auto_clear_ms = 0` keeps the marks until `<leader>mc` |
| C.4b | Mark a file, then trigger a neo-tree-initiated redraw that filetree didn't ask for (`:Neotree refresh`, or just wait out an async git-status refresh) | The `✓` is still there — it must survive any render, not just filetree's own BufEnter/BufWritePost, and not just until "a second or so" passes |

**git_status** (automatic, no keymap needed):

| # | Test | Expected |
|---|------|----------|
| C.5 | Edit and save a file (`:w`) | After ~300 ms a `~` (modified) appears at the end of its tree line |
| C.6 | Create a new file (`:e TESTS/newfile.lua`, `:w`) | It shows `?` (untracked) in the tree |
| C.7 | `git add` in a terminal, then move the tree cursor | It shows `+` (staged) |

**link_marker** (automatic, no keymap needed, on by default):

| # | Test | Expected |
|---|------|----------|
| C.8 | Create a symlink in the tree's directory (`:Filetree symlink`, or `ln -s`/`mklink` outside Neovim) and reveal it | A `⇢` sign appears right before its icon/name, not at the end of the line |
| C.9 | Point a symlink at a path that does not exist (or delete/move the target after linking) | The sign becomes `⇢!`, in a different (error) highlight |
| C.10 | Set `features.link_marker = { show_target = true }`, restart, look at a symlink's line | The sign is followed by `-> <target path>` |
| C.11 | A plain (non-symlink) file or directory | No sign at all |

---

### D. Floating windows — node_info + preview

Exercises: `nvim_open_win`, buffer-local keymaps, close-on-`q`.

**node_info** (keymap `I` in the tree):

| # | Test | Expected |
|---|------|----------|
| D.1 | Cursor on a file, press `I` | A floating window with: path, type, size (bytes + MiB), permissions, mtime, line count |
| D.2 | `q` or `<Esc>` in the float | The window closes |
| D.3 | Press `I` again on the same file | The window closes (toggle: same path = close) |
| D.4 | `I` on a directory | The float shows type `directory` and no line count |
| D.5 | `I` on a very large file (>5 MB) | The line count reads `(skipped — file too large)` |
| D.6 | `I` on a symlink | `Type:` reads `... (symlink)`, and a `Link to:` line names the target |
| D.7 | `I` on a symlink whose target does not exist | The `Link to:` line adds `(broken — target missing)` |
| D.8 | `I` on a file with a second hard-linked name (`:Filetree symlink` → Hardlink, or `mklink /H` / `ln`) | `Type:` reads `... (hardlink, 2 names)` |
| D.8a | `I` on a screenshot that a markdown file links to | The float opens at once; a moment later it is reopened with a `References (N)` section listing the linking file(s) with line numbers |
| D.8b | `I` on a file nobody references, and on a directory | No `References` text at all (no heading, no placeholder) |
| D.8c | Run `:Filetree references` on the screenshot from D.8a, then `<CR>` on a row | A popup `N References: name`; `<CR>` opens the linking file in an editor window (not the tree) at that line |
| D.8d | `:Filetree refs unused assets` in a project with unreferenced screenshots | A picker of the unused files with their sizes; picking one and confirming asks the trash confirmation, and `U` restores it |

**preview** (keymap `<Tab>` in the tree — the default since phase 4):

| # | Test | Expected |
|---|------|----------|
| D.9 | Cursor on a Lua file, press `<Tab>` | A floating window with the file's content (max 100 lines) |
| D.10 | `q` closes the preview | |

---

### E. Input / search — filter + live_search

Exercises: `vim.ui.input`, floating prompt buffers, dimming.

**filter** (keymap `/` in the tree):

| # | Test | Expected |
|---|------|----------|
| E.1 | Press `/` in the tree | A floating input prompt appears |
| E.2 | Type `init` and press Enter | Non-matching nodes are dimmed (Comment highlight) |
| E.3 | `:Filetree filter clear` | Dimming is lifted, every node is normal again |

**live_search** (keymap `gs` in the tree):

| # | Test | Expected |
|---|------|----------|
| E.4 | Press `gs` in the tree | A floating prompt buffer at the bottom of the tree |
| E.5 | Type | Non-matching nodes dim live (~80 ms debounce) |
| E.6 | `<Esc>` | The prompt closes and the dimming is lifted |
| E.7 | Enter | The filter stays (commit_to_filter = true) |

---

### F. Clipboard / copy

Exercises: `vim.fn.setreg`, notifications.

**path_copy** (keymaps `<leader>yp`/`[a`/`]a`/`<leader>yn`/`]b`/`[e` in the tree):

| # | Test | Expected |
|---|------|----------|
| F.1 | `<leader>yp` | A floating picker with every format option |
| F.2 | `[a` | Notification `"Copied: /absolute/path"`; pasting with `<C-r>+` in the editor confirms it |
| F.3 | `]a` | The path relative to the cwd |
| F.4 | `<leader>yn` | The filename only |
| F.4a | Open `docs/ROADMAP/Notes.md` in the editor, then `]b` on `docs/ROADMAP/ROADMAP.md` | `./ROADMAP.md` — NOT the cwd-relative `docs/ROADMAP/ROADMAP.md` |
| F.4b | Same, but `]b` on `docs/BINDINGS.md` | `../BINDINGS.md` |
| F.4c | With `$REPOS_DIR` set and the repo under it, `[e` on any node | `$REPOS_DIR/filetree.nvim/…`, not the drive-letter path |
| F.4d | `[e` on a node outside every `env_roots` directory | The plain absolute path, no `$` prefix |

**copy_file_list** (keymaps `[f`/`]f`/`[F`/`]F` in the tree):

| # | Test | Expected |
|---|------|----------|
| F.5 | Cursor on a directory, `[f` | A notification previewing the first 5 absolute paths; `<C-r>+` in the editor shows all of them |
| F.6 | `]f` | Relative paths |
| F.7 | `[F` / `]F` | Directories only, recursively |
| F.8 | `[f` on a file rather than a directory | Just that one file — not an error |

**lua_require_copy** (keymap `rq` in the tree):

| # | Test | Expected |
|---|------|----------|
| F.9 | Cursor on `lua/filetree/init.lua`, `rq` | The clipboard holds `require('filetree')` |
| F.10 | Cursor on `lua/filetree/features/org/marks/init.lua`, `rq` | `require('filetree.features.org.marks')` |
| F.11 | Cursor on the directory `lua/filetree/features/`, `rq` | Every Lua module in that directory, in the clipboard |

---

### G. Navigation — tree_traverse

Exercises: `adapter.open_reveal()`, cwd sync.

| # | Test | Expected |
|---|------|----------|
| G.1 | Tree cursor on a file or folder, `-` | The tree root moves to the parent directory; notification `"cwd → /parent"` |
| G.2 | Tree cursor on a directory, `+` | That directory becomes the new root |
| G.3 | `:pwd` after G.1/G.2 | The cwd matches the new tree root |
| G.4 | `-` from the repository root | Moves to the repository's parent — not an error |

**buffer_cycle** (keymaps `<C-n>`/`<C-p>` in the tree):

| # | Test | Expected |
|---|------|----------|
| G.5 | At least 2 buffers open, focus in the tree, `<C-n>` | The editor window (not the tree) shows the next buffer; focus stays in the tree |
| G.6 | Then `<C-p>` | The editor window goes back to the previous buffer; focus stays in the tree |
| G.7 | No editor window at all (only the tree), `<C-n>` | Notification `"No editor window found"` — not an error |

---

### H. Find / grep menu

Exercises: the `vim.ui.select` fallback, the telescope/fzf cascade.

| # | Test | Expected |
|---|------|----------|
| H.1 | Cursor on a directory in the tree, `<M-p>` | A `vim.ui.select` picker with 2 options: `find_files` / `live_grep` |
| H.2 | Choose `find_files` | Telescope (or fzf-lua, or vim.ui.select) opens with cwd = that directory |
| H.3 | Choose `live_grep` | The grepper opens with cwd = that directory |
| H.4 | `<M-p>` on a file rather than a directory | Uses the file's parent directory as the cwd |
| H.5 | `find_files` with no picker installed | An input prompt appears: `"Filename pattern: "`; after typing, `vim.ui.select` shows the hits |

---

### I. Phase 3 — the remapping system

To enable these, uncomment the corresponding blocks in `minimal_neotree.lua`.

#### I.1 — keymap remap (`keymaps = { ["gs"] = "<leader>gs" }`):

| # | Test | Expected |
|---|------|----------|
| I.1 | Press `gs` in the tree | No live search — the key was remapped |
| I.2 | Press `<leader>gs` in the tree | Live search opens |

#### I.2 — keymap disable (`keymaps = { ["I"] = false }`):

| # | Test | Expected |
|---|------|----------|
| I.3 | Press `I` in the tree | Nothing happens (no node_info float) |
| I.4 | `:Filetree info` | The float opens — the command still works |

#### I.3 — command rename (`command = { name = "Ft", aliases = { "Filetree" } }`):

| # | Test | Expected |
|---|------|----------|
| I.5 | `:Ft marks show` | The marks float opens |
| I.6 | `:Filetree marks show` | Works too (alias) |
| I.7 | Tab completion on `:Ft<Tab>` | Subcommands are offered |

#### I.4 — autocmd disable (`autocmds = { auto_reveal = false }`):

| # | Test | Expected |
|---|------|----------|
| I.8 | Open a file (`:e lua/filetree/init.lua`) | The tree does NOT scroll to it (auto_reveal off) |
| I.9 | `<leader>e` | Reveal still works — manually, via the command |

---

### J. ignore_list + the `:Ft` alias

#### J.1 — ignore_list default (no config entry needed, on by default):

| # | Test | Expected |
|---|------|----------|
| J.1 | Open the tree | The `.git` folder is NOT visible — hidden from the start |
| J.2 | Press `H` in the tree | Every hidden item (including `.git`) is shown |
| J.3 | Press `H` again | Hidden again |

#### J.2 — ignore_list off (uncomment `ignore_list = false` in minimal_neotree.lua):

| # | Test | Expected |
|---|------|----------|
| J.4 | Open the tree | `.git` is visible |

#### J.3 — ignore_list with a custom list (`ignore_list = { ".git", "node_modules" }`):

| # | Test | Expected |
|---|------|----------|
| J.5 | Open the tree | Only `.git` and `node_modules` are hidden; other folders (e.g. `build`) are visible |

#### J.4 — the `:Ft` alias (always on, needs no config):

| # | Test | Expected |
|---|------|----------|
| J.6 | `:Ft marks show` | The marks float opens (identical to `:Filetree marks show`) |
| J.7 | `:Ft<Tab>` | Tab completion offers the subcommands |

---

### K. Cursor / reset / buffer save

**cursor_hide** (automatic when the tree opens):

| # | Test | Expected |
|---|------|----------|
| K.1 | `<C-e>` → open the tree | The block cursor is invisible in the tree window (blend=100) |
| K.2 | Switch to the editor (`<C-w>w`) | The cursor is visible again there |
| K.3 | Switch back into the tree | Hidden again |

**tree_reset** (keymap `<Esc>` in the tree):

| # | Test | Expected |
|---|------|----------|
| K.4 | A filter is active (e.g. `init` via `/`), then `<Esc>` | The filter is cleared, every node visible again |
| K.5 | A preview is open (`<Tab>`), then `<Esc>` | The preview closes |
| K.6 | Nothing active, `<Esc>` | No error, no stack trace |

**buffer_save** (`<C-s>` / `<M-s>` in the tree):

| # | Test | Expected |
|---|------|----------|
| K.7 | An editor buffer is modified but unsaved; switch into the tree and press `<C-s>` | Notification `"Saved: lua/filetree/..."`, and the buffer's `[+]` is gone |
| K.8 | `<C-s>` with no neighbouring editor window open | Notification `"No editor window found"` |
| K.9 | Cursor on `lua/filetree/init.lua` in the tree (its buffer open in the background), `<M-s>` | Saves exactly that buffer |
| K.10 | `<M-s>` on a file that is not open as a buffer | Notification `"File not loaded: ..."` |

---

### L. Preview — image/PDF dispatch

| # | Test | Expected |
|---|------|----------|
| L.1 | Cursor on a `.png`/`.jpg` in the tree, `<Tab>` | The system app opens the image (Explorer/Preview/eog); the preview float does NOT appear |
| L.2 | Cursor on a `.pdf` in the tree, `<Tab>` | pdfport.nvim opens it (or the system app, if pdfport is not installed) |
| L.3 | Cursor on a `.lua` in the tree, `<Tab>` | The floating text preview, as usual |
| L.4 | Cursor on a `.png`, `<CR>` | The system app opens the image |
| L.5 | Cursor on a `.lua`, `<CR>` | The adapter's own `<CR>` (expand/open) takes over |

---

### M. Window / system FM / shell

**window_size_cycler** (keymap `w` in the tree):

| # | Test | Expected |
|---|------|----------|
| M.1 | Press `w` in the tree | The width changes to 55 (large) |
| M.2 | `w` again | The width changes to 18 (small) |
| M.3 | `w` again | Back to 35 (normal) |

**open_in_fm** (keymap `<leader>fm` in the tree):

| # | Test | Expected |
|---|------|----------|
| M.4 | Cursor on a file, `<leader>fm` | The system file manager opens at the file's directory (Explorer/Finder/Nautilus) |
| M.5 | Cursor on a directory, `<leader>fm` | The file manager opens that directory |

**file_clipboard** (keymap `gy` in the tree; `:Filetree clipfiles`; context menu "Copy to system clipboard"):

| # | Test | Expected |
|---|------|----------|
| M.4a | Mark three `.png` files with `m`, press `gy` | A notification "Copied 3 file(s) to the system clipboard", listing the names; the marks stay |
| M.4b | Switch to a chat app (e.g. a browser chat or Teams) and press Ctrl+V | The three images appear as attachments |
| M.4c | Paste into an Explorer/Finder folder | The three files are copied there (the originals stay) |
| M.4d | Unmark everything, cursor on a directory, `gy`, paste into a file manager | The directory is copied with its content |
| M.4e | Mark a file, delete it outside nvim, `gy` | Warning "1 path(s) no longer exist"; if nothing else is marked, "No existing file to copy" |
| M.4f | A file name with umlauts, spaces and `&` | Pastes under exactly that name |

**shell_run** (keymap `i` in the tree — neo-tree's own `i` is nooped via `adapter_keymaps`):

| # | Test | Expected |
|---|------|----------|
| M.6 | Press `i` in the tree | A prompt appears: `$ (~path/to/node/dir) ` |
| M.7 | Type `echo hello` and press Enter | A horizontal split terminal opens, shows `hello`, and closes afterwards (close_on_ok=true) |
| M.8 | Type `ls -la` | The terminal shows the ls output and closes when it finishes |
| M.9 | Type a command that does not exist (e.g. `doesnotexist`) | The terminal stays open (exit code ≠ 0) |
| M.10 | `<Esc>` at the prompt with no command | Nothing happens, no error |

---

### N. adapter_keymaps — overriding neo-tree's own keymaps

| # | Test | Expected |
|---|------|----------|
| N.1 | In the tree: press `i` | The shell_run prompt opens (NOT neo-tree's run_command) |
| N.2 | In the tree: neo-tree's old `i` behaviour | Gone entirely / noop (adapter_keymaps noop is active) |

---

### O. tree_integrity — the nui `set_nodes` guard

Needs a real nui.nvim, so it cannot live in the headless suites (which run with
no tree plugin at all); `TESTS/units.lua` covers the pre-pass logic against a
hand-built stand-in for nui's node store.

Paste this into a scratch buffer of a session that has neo-tree loaded, then
`:setf lua` and `:source`. It builds a throwaway nui tree, hands the same live
nodes back to `set_nodes` — what neo-tree's `group_empty_dirs` branch does for a
lazily loaded single sub-folder — and prints what the node index looks like
afterwards:

```lua
local NuiTree = require("nui.tree")
local function mk(id, kids) return NuiTree.Node({ id = id, text = id }, kids) end
local tree = NuiTree({
  bufnr = vim.api.nvim_create_buf(false, true),
  nodes = { mk("root", { mk("docs", { mk("a", { mk("a1") }), mk("b") }) }) },
  get_node_id = function(n) return n.id end,
})
tree:set_nodes({ tree:get_node("root") })          -- the same live node, twice
local ids = vim.tbl_keys(tree.nodes.by_id); table.sort(ids)
print("by_id: " .. table.concat(ids, ","))
print("second set_nodes: " .. tostring((pcall(tree.set_nodes, tree, { tree:get_node("root") }))))
```

| # | Test | Expected |
|---|------|----------|
| O.1 | Run the snippet with `tree_integrity` enabled (the default) | `by_id: a,a1,b,docs,root` and `second set_nodes: true` |
| O.2 | `:lua print(require("filetree.features.infra.tree_integrity").installed())` after a tree buffer has been opened | `true` |
| O.3 | Re-run the snippet after `require("filetree").setup({ features = { tree_integrity = { enabled = false } } })` | `by_id: root` and `second set_nodes: false` — the upstream bug, unguarded |
| O.4 | With the guard back on: expand a directory that sits next to a grouped one-child chain (`a/b/c` shown as one line), repeatedly | No `[Neo-tree ERROR] Error setting nodes` in `:messages`, and the grouped chain still renders as one line |
| O.5 | `:checkhealth filetree` | `tree_integrity installed`, plus a healed count if this session hit the corruption |

---

### P. sidebar_guard — the tabline-hijack fix

`TESTS/sidebar_guard.lua` covers both strategies (the default redirect and the
opt-in `winfixbuf` pin) against a stubbed neo-tree; this checks the real
end-to-end behaviour with a tabline plugin installed (NvChad's tabufline,
bufferline.nvim, …).

| # | Test | Expected |
|---|------|----------|
| P.1 | `:lua =vim.wo[vim.fn.win_getid(vim.fn.winnr())].winfixbuf` with the cursor in the tree | `false` — the default no longer pins. `true` only with `winfixbuf = true` configured. |
| P.2 | Tree open on the **left**, focus inside the tree, click a buffer in the tabline | The file opens in an editor window; the tree stays put on the left, same width. It does **not** reopen on the right. |
| P.3 | Same, tree on the **right** | Symmetric — tree stays on the right. |
| P.4 | Switch source via the `source_selector` winbar (filesystem → buffers → git_status …) | Still works — the buffer swaps in place, no error, and the new source stays in the sidebar rather than being thrown into an editor window. |
| P.5 | Focus **inside the tree**, then run a plugin that opens a file from a callback — `:Reposcope dashboard` → pick a repo → open its README, or any `:lua vim.cmd.edit("…")` | The file opens in an editor window, focus follows it, the tree stays put. No `E1513`. This is what the old `winfixbuf` default broke. |
| P.6 | Repeat P.5 with `sidebar_guard = { winfixbuf = true }` | The refusal is back by choice: `E1513: Cannot switch buffer` and the file does not open. The tree still stays put. |
| P.7 | `require("filetree").setup({ features = { sidebar_guard = { enabled = false } } })`, then repeat P.2 | The old bug is back: the tree jumps to the other side. |

### Q. context_menu — the right-click menu

The wiring is pinned headlessly (`units.lua`: which clicks count, wrapped and
sideways-scrolled last lines; `adapter_lines.lua`: real neo-tree). What a
headless run cannot judge is how it looks and feels with a real pointer.

| # | Test | Expected |
|---|------|----------|
| Q.1 | Put the cursor far from a node (e.g. on the root), right-click a node further down | The menu opens at/beside the click, the clicked row is highlighted while it stays open, and picking an entry acts on THAT node, not the one the cursor was on |
| Q.2 | Close the menu with `<Esc>` | The highlight is gone |
| Q.3 | Right-click the empty area right below the last node, then far below it | Nothing happens: no menu, the cursor stays where it was |
| Q.4 | Right-click the tree window's statusline (if shown), its vertical separator and (with a winbar) the winbar | Nothing happens |
| Q.5 | With the tree focused, right-click in the editor window | Nothing opens from the tree's mapping, the cursor in the tree stays |
| Q.6 | Scroll the tree sideways (`zL`/wheel-right, long names), then right-click right below the last node | Still nothing; a click on the last node itself still opens the menu |
| Q.7 | Dock the tree left, then right (`:Filetree` window position) and right-click a node | The menu opens beside the tree and never covers the highlighted row |

### R. quickpick — the numbered quick-pick mode (opt-in)

Needs `features = { quickpick = { enabled = true } }`. The lifecycle is pinned
headlessly (`quickpick.lua` against a fake tree, `quickpick_neotree.lua` against
a real neo-tree). What no headless run reaches is a real terminal: how the
labels and the badge look over a real colorscheme, key timing, and the keys a
terminal actually sends.

| # | Test | Expected |
|---|------|----------|
| R.1 | Tree closed, in a file: `<leader>;` | The tree opens on the file's folder, every visible entry carries `00`, `01`, ... in front of its icon (and not over the icon), the tree has focus, the badge ` edit \| all \| __ ` shows where `indicator_position` says |
| R.2 | Type two digits of a file | The file opens in the editor window, the mode is gone: no labels, no badge, `j`/`k`/`s`/`<CR>` behave as neo-tree's again |
| R.3 | `<leader>;`, then `v`, then two digits | Opens in a vertical split; the badge showed `vsplit` after `v` |
| R.4 | `<leader>;`, type one digit, then `s` | Nothing changes mode (locked); `<BS>` then `s` switches to split |
| R.5 | `<leader>;`, type a folder's number | The folder expands, the entries below it are renumbered, the mode is still on; typing its number again collapses it |
| R.6 | `c` repeatedly | Labels move to files only, folders only, back to all; the badge follows |
| R.7 | Many entries (more than the window is high): `<C-d>`, `<C-u>`, `j`, `k`, and the mouse wheel | Labels follow what is on screen, restarting at `00` at the top |
| R.8 | Resize the terminal / the tree window while the mode is on | Labels and badge are redrawn for the new size |
| R.9 | Press `<Esc>`; separately wait out `timeout_ms`; separately click into the editor window | Each ends the mode cleanly: labels, badge and the silenced keys are gone |
| R.10 | While the mode is on press `a`, `d`, `<Space>`, `:` | Nothing happens (silenced) -- no neo-tree create/delete prompt, no command line |
| R.11 | `2<leader>;` from a file two folders deep, and `<leader>:` | The tree is rooted two folders above the file / at the cwd, then numbered |
| R.12 | Inside tmux and in a plain terminal: `<Esc>` ends the mode at once, and `<C-h>` / `<BS>` both drop a digit | Neither feels delayed or does the wrong thing |

---

## Known limits of this test environment

- **Telescope/fzf**: not installed, so `find_files`/`grep_in_dir` fall back to
  `vim.ui.select` — which is the expected behaviour.
- **No persistence** between sessions: `marks`, `session` and the rest write
  to `%TEMP%/filetree-test/data/nvim/filetree/`, which is emptied by
  `rm -rf /tmp/filetree-test`.
- **Windows symlinks need Developer Mode** (or an elevated Neovim) to create —
  without it, C.8-C.11 and D.6-D.8's `:Filetree symlink`/`ln -s`/`mklink` steps
  fail with `EPERM` and there is nothing to reveal in the tree. A hard link
  (`mklink /H`, D.8) needs neither.

---

## Typical failure signatures

| Symptom | Likely cause |
|---------|--------------|
| The tree keymaps are missing | The FileType autocommand did not fire — `:set ft?` in the tree buffer should say `neo-tree` |
| `adapter = nil` from `<leader>fa` | `setup()` failed — `:checkhealth filetree` says why |
| The EOL virtual text does not appear | `get_visible_nodes()` returned an empty list — check with `<leader>fn` whether `get_current_node()` returns anything at all |
| A floating window does not open | An `nvim_open_win` error — usually `width`/`height` = 0 because an adapter method returned nil |
| `rq` copies the wrong module | No `/lua/` found in the path — check the tree root path; it has to sit under a `lua/` directory |
