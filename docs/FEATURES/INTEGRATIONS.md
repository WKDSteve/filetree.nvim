# Integrations

Everything that connects the tree to something outside itself: git,
external programs, LSP, diffing, marks/session persistence, and the
PDF bridge to [pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim).

## Git Status

Decorates tree nodes with git status (modified/staged/untracked/…),
resolved per adapter — each backend surfaces this through its own native
mechanism rather than filetree.nvim reimplementing git status parsing.

**Backend support.** Drawn as extmarks on the node's own line, which needs
the adapter to say which node a given line holds (`get_node_at_line`). The
neo-tree and nvim-tree adapters implement it; netrw, oil and mini.files do
not, so this renders nothing there rather than misplacing anything.

**Refreshes on:** `BufEnter` (tree buffer), `BufWritePost` (any buffer),
`FocusGained`, and — optionally, no dependency either way —
[gitsuite.nvim](https://github.com/WKDSteve/gitsuite.nvim)'s `User
GitsuiteBranchSwitched`/`GitsuiteConflictsResolved` events, so a branch
switch or clearing the last conflict marker in a buffer updates the
decorations immediately instead of waiting for the next write or focus
change.

- **Module:** `lua/filetree/features/git/git_status/`

## Marks

Toggle a mark on the node under the cursor (`m`), batch mark/unmark
(`]m`/`[m`), clear every mark (`<leader>mc`) and list them
(`<leader>ms`) — the selection
mechanism several fileops features (trash, copy/move, copy_file_list)
build on for "act on more than one node at once".

**Marks come out in the order you marked them.** Every action that takes
the marked set — copy path (including `[e`, env-rooted), copy file list,
Markdown links, files to the OS clipboard, symlinks, copy/move, trash, PDF,
diff — gets the paths in mark
order, not tree order: mark `beins.md`, `zeins.md`, `eins.md` and `[e` puts
exactly those three lines, in that order, on the clipboard. Unmarking and
re-marking a node moves it to the end; a bulk mark (`]m`, Visual `m`)
numbers the newly marked nodes in tree order behind the existing ones.
Opt out with `features.marks.order = "tree"` (sorted by full path, the old
behavior). Default `"marked"`.

### Navigating and selecting marks (2026-08-24)

Marks were set one line at a time and, once set, had no way back to them.
Two additions close the flag/option audit's entries:

**Jumping.** `Ngm` goes to the Nth marked node in render order, `]M`/`[M`
cycle to the next/previous one, wrapping. Navigation follows the tree *as
rendered*, not `get_marked()`'s mark order — that is the right answer
for "what is marked" and the wrong one for moving around, and a marked node
inside a collapsed directory has no line to jump to at all. An out-of-range
count clamps to the last mark rather than erroring, the way `G` treats one.

**Visual-mode marking.** `m` over a selection marks every node in it, `[m`
unmarks. These are the only Visual-mode keymaps filetree binds, and the
audit's entry about there being none was really about this: a line range over
a rendered tree is exactly a set of nodes, which is the one thing a tree
buffer's Visual mode is good for. Marking a run of files no longer means
pressing `m` once per line.

Diffing two marked files against each other was listed as missing, but
`diff_marked()` has always done exactly that (it requires exactly two marks
and diffs them against one another, not against the current buffer) — nothing
to add.

### Auto-clear on idle (2026-09-25)

Marks used to live forever until an explicit `<leader>mc`, or until a batch
op that *consumed* them cleared them itself (trash/move/copy_move/diff do
this; the read-only consumers — PDF-from-marks, markdown_links, path_copy,
copy_file_list — deliberately don't, so the same marks can feed several of
those in a row). That is a footgun on its own: mark a batch, run one of the
read-only actions, get pulled away, come back much later and run an
unrelated single-node action expecting it to act on just the node under the
cursor — trash/move/copy_move all *prefer* the marked set over the cursor
node whenever anything is marked, so it silently acts on the long-stale
marks instead, with no visible reason why.

`marks.auto_clear_ms` (default `60000`) clears every mark after that many ms
without genuine mark activity — toggling, mark/unmark all, a Visual-mode
mark, jumping between marks, or opening the list — with a notify so the
"why did that just act on everything" moment has an obvious cause. Closing
and reopening the tree does **not** count as activity in either direction:
it neither resets the idle clock nor clears marks by itself, only elapsed
idle time does. Set to `0` to disable the timeout and go back to the old
"forever until cleared" behavior.

- **Module:** `lua/filetree/features/org/marks/` (`goto_mark`,
  `goto_adjacent_mark`, `mark_visual`)
- **Keymaps:** `m`, `]m`, `[m`, `<leader>mc`, `<leader>ms`, `gm`, `]M`, `[M`,
  plus `m`/`[m` in Visual mode
- **Config:** `marks.keymap_goto` (default `gm`), `marks.keymap_next`
  (`]M`), `marks.keymap_prev` (`[M`), `marks.auto_clear_ms` (default `60000`,
  `0` disables), `marks.order` (`"marked"` default, or `"tree"`)

## Session

Persists and restores tree state (root, expanded nodes, marks) across
Neovim sessions, so reopening a project brings the tree back roughly
where you left it rather than starting fresh every time.

- **Module:** `lua/filetree/features/org/session/`

## Open In File Manager

Shows the node in the system file manager — a file selected inside its
parent directory, a directory navigated straight into (`<leader>fm`).
Cross-platform (Explorer/Finder/xdg-open-based managers).

- **Module:** `lua/filetree/features/system/open_in_fm/`
- **Keymaps:** `<leader>fm`

## Open With

Opens the node with a configured external application (`<leader>sm`) —
for file types you want handled by a specific program rather than
Neovim's own `preview`/`open` path.

- **Module:** `lua/filetree/features/system/open_with/`
- **Keymaps:** `<leader>sm`
- **Config:** external-app mapping — see [configuration.md](../configuration.md)

## File Clipboard

`gy` puts the **files themselves** on the operating system's clipboard, so
Ctrl+V pastes them into a chat window, a mail, an upload dialog or a file
manager — without opening the OS file manager first. Mark three screenshots
with `m`, press `gy`, switch to the chat, Ctrl+V: three images.

It copies what Ctrl+C does in Explorer or Finder: a *file list*. That is
neither the text of the paths (`[a`, `[f` — see
[SEARCH_AND_PATHS.md](SEARCH_AND_PATHS.md)) nor filetree's own copy/cut
staging (`c`/`x`/`p`, which only `p` inside the tree can paste).

Targets: every marked node when any is marked, else the node under the
cursor. Directories go as directories; entries that no longer exist are
skipped and reported. The marks are left alone, so the same selection can
feed `path_copy` or `markdown_links` next.

| Platform | Tool | Status |
|----------|------|--------|
| Windows | `powershell.exe` (started by absolute path under `%SystemRoot%`) → `Set-Clipboard -LiteralPath` | tested, incl. umlauts, `&`, `'`, `[ ]`, `$` |
| macOS | `osascript` (`set the clipboard to {POSIX file …}`) | implemented, not yet run on a Mac |
| Linux | `wl-copy` (Wayland) or `xclip` (X11), MIME `text/uri-list` | implemented, not yet run on Linux; GNOME Files may want its own `x-special/gnome-copied-files` format |
| WSL | — | refused with a message |

No path is ever spliced into a script or a shell string; the tools receive
them as argv, stdin or an environment variable. A tool that does not finish
within 15 seconds is stopped and reported, and a failure shows the tool's first
error line (the full text goes to the debug log, `debug = true`). The Windows round trip can be
re-run with `FILETREE_TEST_REAL_CLIPBOARD=1` (see `TESTS/file_clipboard.lua`;
it overwrites the clipboard).

- **Module:** `lua/filetree/features/system/file_clipboard/`
- **Keymaps:** `gy` (config field `keymap`)
- **Commands:** `:Filetree clipfiles`
- **Config:** `opts.features.file_clipboard.keymap`, `.preview_limit` (names listed in the notification, default 5)

## Shell Run

`i` prompts for a shell command and runs it in the node's directory —
for one-off commands (`npm install`, `go build`) scoped to wherever the
cursor happens to be in the tree, no manual `cd` first.

- **Module:** `lua/filetree/features/system/shell_run/`
- **Keymaps:** `i`

## LSP Diagnostics

Decorates tree nodes with LSP diagnostic severity (error/warn/…) rolled
up from the files under them, so a directory with a broken file inside
it is visible without expanding into it first.

**Badge text.** By default each non-zero count is prefixed with, per
severity, the first non-blank of: the `icons` option
(`{ error = "…", warning = "…", hint = "…", info = "…" }`), the sign text
set in `vim.diagnostic.config({ signs = { text = { ... } } })` (keyed by
severity number or name), `E:`/`W:`/`H:`/`I:`. Surrounding whitespace is
trimmed, so a sign text of `" "` (signs shown as a number-column highlight
only) counts as blank, and so does a `signs` given as a function. Examples:
`✘ 2 ▲ 1`, `E:2 W:1`. `icons` is the way to get glyphs in the tree while the
sign column shows none. The texts are read on every redraw. Hints and infos are off by default (`show_hints`,
`show_info`); `format` replaces the default (`fun(counts): string?`, nil
hides the badge).

**Backend support.** Drawn as extmarks on the node's own line, which needs
the adapter to say which node a given line holds (`get_node_at_line`). The
neo-tree and nvim-tree adapters implement it; netrw, oil and mini.files do
not, so this renders nothing there rather than misplacing anything.

- **Module:** `lua/filetree/features/lsp/lsp_diagnostics/`

## Diff

`D` diffs the node under the cursor — against the working tree, a git
revision, or another node, depending on how it's invoked. Native
diffmode under the hood, nothing custom rendered.

- **Module:** `lua/filetree/features/compare/diff/`
- **Keymaps:** `D`

## PDF bridge (pdfport.nvim)

When [pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim) is
installed, `.pdf` nodes dispatched through `preview` ([UI.md](UI.md)) or
opened directly can route through pdfport's own backend fallback chain
(render into a buffer) instead of always shelling out to the system PDF
reader. Soft dependency — without pdfport.nvim installed, `.pdf` nodes
just open with the system reader, no prompt.

`pdf_open`'s default keymap (`go`) opens directly in `default_mode` (default
"buffer"), no prompt. Set `default_mode = "picker"` (or bind
`keymap_picker`) instead to get pdfport's own "open PDF as…" chooser —
every backend/mode pdfport knows about, plus "system application", which is
always offered even without pdfport.nvim installed (falls back to the
system reader directly, no empty prompt).

- **Module:** `lua/filetree/features/system/pdf_open/` (dispatch site,
  wired into `preview` — [UI.md](UI.md)); see
  [pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim) for the
  render side

## Markdown preview (mdview.nvim)

Opt-in feature `mdview_open` (`enabled = true`, key `gM`): opens the markdown file under the
cursor in [mdview.nvim](https://github.com/WKDSteve/mdview.nvim)'s browser preview without showing it
in a window first. mdview previews the current buffer, so the file is loaded into an unlisted buffer
for the call. A running mdview session is required (`:MDView start`); without one mdview says so,
and without mdview.nvim installed the key only warns (`:checkhealth filetree` notes it). Soft
dependency, like pdfport above.

- **Module:** `lua/filetree/features/system/mdview_open/`

## PDF Create

The write direction of the same bridge: `gP` turns the image, markdown,
text, HTML or office file(s) under the cursor into PDF(s). It always
confirms first — unlike PDF open, which only reads, this writes new files
to disk.

Targets are gathered in the same order as Trash and Copy / Move: marked
nodes if any are marked, where a marked directory expands to its own
creatable direct children; otherwise the node under the cursor — a file
means that one file, a directory means every direct child file pdfport
can convert. Non-recursive on purpose: "all files in the folder" is this
folder's own files, not a project-wide sweep.

One PDF is produced per input file, next to its source (`on_conflict =
"suffix"` by default) — a multi-file selection does not merge into one
document. Files pdfport has no producer for are skipped and reported in
the summary rather than treated as an error.

Off by default, and pdfport.nvim is a soft dependency: without it the
keymap warns and does nothing, rather than filetree requiring pdfport
just to load.

- **Module:** `lua/filetree/features/system/pdf_create/`
- **Keymaps:** `gP`
- **Config:** `features.pdf_create.enabled` (default `false`),
  `on_conflict` (default `"suffix"`), `confirm` (default `true`)

## Compress

`gz` zips the node under the cursor, or every marked node when any is
marked (`m`). A folder goes into the zip with its contents. One node
becomes `<name>.zip` beside it; for several, `multiple` decides: one zip
per node (`"each"`), one zip for all of them with the name asked
(`"together"`, default the folder name), or a question offering both
(`"ask"`, the default). An existing zip is never overwritten, the new one
becomes `<name>_2.zip`. The sources and the marks are left alone.

Typical use: a log or event dump too large for a commit (a pre-commit size
check), marked with `m` and zipped with `gz` before staging.

The archive is written by Info-ZIP `zip` when it is on `PATH`, else by a
bsdtar: Windows 10+ ships one as `System32\tar.exe` (Git for Windows' own
`tar` is GNU tar and cannot write zip), macOS as `tar`, elsewhere it is
`bsdtar`. `zip` only takes nodes from one folder into one archive; bsdtar
takes them from anywhere. With neither, `gz` only warns.

- **Module:** `lua/filetree/features/system/compress/`
- **Keymaps:** `gz`
- **Commands:** `:Filetree compress`, `:Filetree compress each`,
  `:Filetree compress together`
- **Config:** `features.compress.enabled` (default `true`),
  `multiple` (default `"ask"`: `"each"` / `"together"` / `"ask"`)
