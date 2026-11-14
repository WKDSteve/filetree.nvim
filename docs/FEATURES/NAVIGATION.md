# Navigation

Moving the tree root, revealing files, cycling adjacent buffers, and
keeping the editor window layout sane. See [CORE.md](CORE.md) for the
root/cwd *policy* stack (`cwd_mode`, `cwd_sync`, `project_root`) that some
of these interact with.

## Tree Traverse

`-` navigates up to the parent directory, `+` sets the directory under the
cursor as the new tree root — via `adapter.set_root()` where supported,
falling back to `:cd` + `adapter.open_cwd()` otherwise. A manual re-root
here is reported to `cwd_mode.notify_manual_root()` when that feature is
active, so a `lock`/`project`/`tree_leads` policy moves its pin instead of
fighting the user's own `+`/`-` press.

`]s` / `[s` jump to the next / previous **sibling**: the next entry at the
same depth inside the same folder, skipping the children of an expanded
sibling folder, and never climbing out of the folder the cursor is in. A
count moves that many siblings. At the folder's last / first child the jump
stops (default) or, with `sibling_wrap = true`, wraps around. It is built on
the adapter contract (`get_current_node`, `get_visible_nodes`,
`scroll_to_line`) and so works the same on all five adapters; the flat
listings of mini.files, netrw and oil degrade to plain next / previous entry.
nvim-tree's own `<`/`>` keep working; `]s`/`[s` only shadow the
snacks.nvim scope motion inside the tree buffer.

- **Module:** [`features/nav/tree_traverse/init.lua`](../../lua/filetree/features/nav/tree_traverse/init.lua)
- **Keymaps:** `-` up, `+` down, `]s` next sibling, `[s` previous sibling
  (config fields `keymap_up`/`keymap_down`/`keymap_next_sibling`/`keymap_prev_sibling`,
  `false` disables one; `sibling_wrap` boolean, default `false`)
- **Usercmds:** `:Filetree traverse up`, `:Filetree traverse down`

## Auto Reveal

Scrolls to (or expands+reveals) the current file in the tree on every
buffer switch, **without ever changing the cwd itself** — that stays
`cwd_sync`'s job. Debounced (`debounce_ms`, default 150ms), auto-pauses
while the cursor is inside the tree window to avoid feedback loops.

For a file OUTSIDE the tree's current root, it re-roots the tree's own
display (not the cwd) to wherever the file resolves via the same directory
logic `cwd_sync` uses, by default (`follow_root`, default `true`) — skipped
when `cwd_sync` is already handling the reveal for that switch, since both
resolve the same directory. Set `follow_root = false` to go back to doing
nothing for a file outside the current root.

Entering the tree window (`<C-w>w`, `<C-h>`, a mouse click) also puts the
tree cursor on the current file's node (`sync_on_enter`, default `true`).
That reveal skips the debounce deliberately: without it, whether you landed
on the right node depended on whether the debounced `BufEnter` reveal had
already fired — switch buffers and step into the tree quickly enough and the
reveal found the cursor already in the tree, dropped itself, and left you
wherever you last were.

- **Module:** [`features/nav/auto_reveal/init.lua`](../../lua/filetree/features/nav/auto_reveal/init.lua)
- **Config:** `enabled` (default `true`), `debounce_ms` (150), `ignore_ft`, `only_if_open` (default `true`), `sync_on_enter` (default `true`), `follow_root` (default `true`)
- **Usercmds:** `:Filetree reveal`, `:Filetree reveal pause [ms]`, `:Filetree reveal resume`

## Reveal Alt

`B` resolves the alternate buffer (`#`) and calls `adapter.open_reveal()`
on it, adjusting the tree root if the file lives outside the current one —
the tree-buffer analogue of `:e #`.

- **Module:** [`features/nav/reveal_alt/init.lua`](../../lua/filetree/features/nav/reveal_alt/init.lua)
- **Keymaps:** `B` (config field `keymap`)

## Source Switcher (neo-tree, native)

neo-tree renders its filesystem, buffer list, git status, symbol outline,
diagnostics and (with neo-tree-tests-source) tests through one window.
Its own `<`/`>` re-open the tree at the *configured* position — not where
it is when you press the key in a float. This feature keeps the position:
`"`/`!` cycle to the next/previous source in place, `:Filetree source`
(or a global key) opens a floating list with each source's icon and name,
the current one marked and a `[!]` on one that cannot load right now
(`document_symbols` without an LSP client, an uninstalled optional source).

The pure half needs no `setup()`: `display_name(source, opts)` returns the
` <icon> <Name>` string neo-tree's `source_selector` wants, in three icon
families (`nerd`, `codicons`, `common` for a font without glyphs) and two
name lengths — so a host builds neo-tree's own opts from it. Leaving
`family` unset resolves to `"nerd"` only when `vim.g.have_nerd_font = true`
is declared, `"common"` otherwise; passing `family = "nerd"` explicitly (as
below) always renders Nerd Font glyphs, tofu boxes included if the terminal
font doesn't have them — the same convention `lib.nvim.ui.nerd_font` uses.

```lua
local sw = require("filetree.features.nav.source_switcher")
source_selector = {
  winbar = true,
  sources = sw.display_names({ "filesystem", "buffers", "git_status" }, { family = "nerd" }),
}
```

On the own tree (`adapter = "native"`) the same keys, commands and API drive
its [views](BACKENDS.md#views-and-sources): a view is what a source is there
(`files`, `buffers`, `git`, `symbols`, `diagnostics`, and what plugins
registered), the list is `native.views`, and the tree's view bar shows it. The
window is never touched there, so there is no position to keep. A view that
cannot load is shown all the same: its one line says why.

A silent no-op on the other adapters: one tree, nothing to switch.

- **Module:** [`features/nav/source_switcher/init.lua`](../../lua/filetree/features/nav/source_switcher/init.lua)
- **Keymaps:** `"` next, `!` previous (config fields `keymap_next`/`keymap_prev`, tree-local); `keymap_pick` (global, default unset)
- **Usercmds:** `:Filetree source [name|pick|next|prev|debug]`
- **Config:** `opts.features.source_switcher.sources` (override the list), `.icons = { family, variant, length }`

## Tree Toggle (opt-in)

Four global keys that open (or close) the tree at a chosen position and
reveal the current file on the way in, re-rooting to the cwd when the file
lies outside the tree: `<M-l>` left, `<M-r>` right, `<M-f>` float, `<M-c>`
in the current window. The `:Neotree toggle position=… reveal
reveal_force_cwd` most configs write four times, through
`adapter.toggle_at()` instead — so it works on every backend that can place
its tree, and refuses with a reason on one that cannot.

On neo-tree the adapter also heals one race: toggling again before the
previous toggle's debounced scan has settled makes `nvim_buf_set_name`
collide (E95) and leaves a blank, unfocusable tree window that re-errors on
every redraw. The adapter closes any never-rendered neo-tree window and
retries once, which is what pressing the key again used to do by hand.

Off by default: four global Alt keys are a claim on the keyboard the user
makes, not the plugin.

**`collapse_on_toggle`** (default **false**, on trial): every time one of these
keys (or `:Filetree toggle`) opens the tree, it first collapses every folder
except the chain from the root to the current buffer's file, so folders
opened by hand no longer pile up over a session. A buffer without a file
(scratch, help, terminal) or a file outside the root keeps nothing open. It
runs on the way **in**, not on close: the tree can also be closed by `:q` in
its window, a layout change or another plugin, none of which pass the key,
and the state that close leaves behind survives until the next show. The
reveal that follows re-opens exactly the current file's chain, in the same
redraw. A toggle that closes the tree leaves its state alone. Uses the
adapter's `collapse_all` (see [Collapse All](#collapse-all)); on netrw, oil
and mini.files there is nothing to collapse and the toggle runs as before.

**`use_root_providers`** (default **true**): when a key opens the tree and a
root provider ([`filetree.roots`](../../lua/filetree/roots.lua)) names a folder
for the current file, the tree is rooted there instead of at the cwd.
casedesk.nvim registers the case folder, so inside a case the tree shows that
case and not every sibling case. Without a provider, or outside a case, nothing
changes; a toggle that closes the tree is untouched.

- **Module:** [`features/nav/tree_toggle/init.lua`](../../lua/filetree/features/nav/tree_toggle/init.lua)
- **Keymaps:** `<M-c>`, `<M-f>`, `<M-l>`, `<M-r>` (global; config fields `keymap_current`, `keymap_float`, `keymap_left`, `keymap_right`)
- **Usercmds:** `:Filetree toggle [left|right|float|current]`
- **Config:** `opts.features.tree_toggle.enabled` (default **false**), `reveal` (true), `reveal_force_cwd` (true), `collapse_on_toggle` (false), `use_root_providers` (true)

## Close On Open (opt-in)

Opening a file from the tree (`<CR>`, double-click, `O`, the `open_variants`
keys) leaves the tree on screen, so it has to be closed by hand after every
open. With `close_on_open` the tree closes itself once the file is shown;
`<C-CR>` (Ctrl+Enter) opens the node exactly like `<CR>` and keeps the tree
open, for browsing several files in a row. Focus is in the editor window in
both cases.

An open from the tree is recognised without a backend hook: the tree window
loses focus and, within 400 ms, a normal file buffer is shown in a non-floating
window. A folder toggle never shows a buffer, previews live in a float, and a
`<C-w>l` into the editor followed later by `:edit` is outside the time window,
so none of them closes the tree. `open_replace` keeps the tree open for its own
keys when its `close_tree` / `swap_close_tree` say so. Backends that open in
their own window (oil, netrw, mini.files) are not affected.

**Breaking change (2026-11-05):** `open_replace`'s swap key moved from `<M-CR>`
(Alt+Enter is fullscreen in many terminals) to `<C-M-CR>`; its second key
`<C-CR>` is now the keep-open key here. Check that your terminal delivers
`<C-CR>` and `<C-M-CR>` as distinct keys.

- **Module:** [`features/nav/close_on_open/init.lua`](../../lua/filetree/features/nav/close_on_open/init.lua)
- **Keymaps:** `<C-CR>` (tree buffer; config field `keymap_keep`, `false` turns it off)
- **Config:** `opts.features.close_on_open.enabled` (default **false**), `keymap_keep` (`"<C-CR>"`)

## Sort Cycle

`<leader>so` cycles the tree's sort criterion (name, size, modified), `<leader>sO`
reverses it; `:Filetree sort` and `:Filetree sort reverse` do the same. The cursor
stays on its entry. neo-tree only (it needs the adapter methods `set_sort` and
`get_sort`); the other adapters report that they cannot sort. Off by default.

- **Module:** `lua/filetree/features/nav/sort_cycle/`
- **Keymaps:** `<leader>so`, `<leader>sO`

## Collapse All

`W` in the tree folds every open folder back to the root in one redraw;
the cursor lands on the top-level entry it was under. A thin front for the
optional adapter method `collapse_all(keep_path?)`: neo-tree's
`close_all_nodes` (its own `z`, which also forgets the folders neo-tree
remembers as opened by hand) and nvim-tree's `api.tree.collapse_all` (its
own `W`). `keep_path` keeps the folders on the way to that path open, which
is what `tree_toggle.collapse_on_toggle` passes. A new file not written yet
keeps its chain too (its folder exists); a scratch, help or terminal buffer
keeps nothing. The flat backends (netrw,
oil, mini.files) show one folder at a time and report "not applicable".

On neo-tree it acts on the tree of the current tab (also while that tree is
closed), never on a tree open on another tab. The chain is compared as
plain strings, so it runs through a linked folder (symlink or junction)
without resolving it. A `group_empty_dirs` line ("a/b/c") is refreshed after
the collapse, so it reads "a" again instead of staying merged.

`W` is bound only on tree buffers where it is still free: a `W` the tree
plugin or the user mapped there (a neo-tree `window.mappings` entry, say)
stays as it is, and one message says why `collapse_all` is not on it
(silently on nvim-tree, whose own `W` is collapse-all already).

- **Module:** [`features/nav/collapse_all/init.lua`](../../lua/filetree/features/nav/collapse_all/init.lua)
- **Keymaps:** `W` (tree-local; config field `keymap`)
- **Usercmds:** `:Filetree collapse`
- **Config:** `opts.features.collapse_all.enabled` (default true)

## Quickpick (opt-in)

A temporary *numbered quick-pick mode* over the tree. `<leader>;` puts a
two-digit label (`00`..`99`) on every entry that is visible in the tree
window; typing the number opens that entry, with no cursor movement and no
`<CR>`. Meant for "open that file, I can see it" — the common case where
moving the cursor to it is the slow part.

- **Open modes.** `s` / `v` / `t` before the first digit pick split / vsplit /
  new tab instead of the plain edit (`e` goes back); a badge shows the
  current choice. Once a digit is typed the mode is locked for that number;
  `<BS>` drops the digit and unlocks it.
- **Folders.** The number of a folder expands it (or collapses it, when it is
  open) and renumbers whatever is visible afterwards; the mode keeps running.
- **Content kind.** `c` cycles which entries carry a number: files and
  folders → files only → folders only. `content` sets the start value.
- **Typed digits narrow the labels.** After the first digit only labels that
  begin with it stay on screen, the typed part highlighted.
- **Starting it.** `<leader>;` numbers an open tree as it is; with the tree
  closed it opens it on the current file's folder first (reveal) and numbers
  it once it has rendered. A count roots it higher: `2<leader>;` puts the
  root two folders above the file (`parent_levels`). `<leader>:` roots it at
  the cwd. Both are also `:Filetree quickpick [levels]` / `:Filetree
  quickpick cwd`; `:Filetree quickpick cancel` leaves the mode.
- **Leaving.** `<Esc>` or `<C-c>`, `timeout_ms` (default 5 s) without a key,
  moving focus off the tree, closing it, or opening an entry. Everything is
  put back: the labels (extmarks), the badge, the timer, the autocmds, and
  every buffer-local key the tree plugin had on the keys the mode used —
  restored with its callback, `desc`, `nowait`, `silent` and `expr` intact.
  Focus returns to the window the mode was started from.
- **Silencing.** While the mode runs, `silence_nvim_mappings` (default true)
  maps every other key in the tree buffer to `<Nop>`, so a stray press cannot
  fire the tree plugin's own action (neo-tree binds `s`, `t`, `<CR>`, `a`, `d`
  there) or a global mapping. `false` takes over only the mode's own keys.
  `<Esc>` is never silenced.
- **Scrolling.** `j` / `k` / `<C-d>` / `<C-u>` move inside the tree without
  leaving the mode. Only entries inside the window's visible lines are
  numbered, and the numbers are redrawn from scratch — never patched — on
  scroll, resize, expand/collapse and whenever the tree re-renders itself.
- **Open target.** A file is opened from an *editor* window (a new one when
  there is none), never from the tree window, through `adapter.open_file(path,
  mode)`. The tree's own root line is never numbered.

It is built on the adapter contract alone (`get_visible_nodes`,
`expand_node`, `collapse_node`, `open_file`, `open_reveal`, `open_cwd`), so it
works on every backend that implements them; mini.files cannot expand
folders, so a folder number there says so and does nothing.

Off by default: two global leader keys and a mode that takes over the tree's
keys are a claim the user makes, not the plugin.

- **Module:** [`features/nav/quickpick/init.lua`](../../lua/filetree/features/nav/quickpick/init.lua) (lifecycle), [`logic.lua`](../../lua/filetree/features/nav/quickpick/logic.lua) (numbering and the input parser, pure), [`keys.lua`](../../lua/filetree/features/nav/quickpick/keys.lua) (buffer-local keys with exact restore)
- **Keymaps:** `<leader>;`, `<leader>:` (global; config fields `keymap`, `keymap_cwd`); in-mode keys in [KEYMAPS.md](../BINDINGS/KEYMAPS.md#quickpick-mode-keys)
- **Usercmds:** `:Filetree quickpick [levels]`, `:Filetree quickpick cwd`, `:Filetree quickpick cancel`
- **Config:** `opts.features.quickpick.enabled` (default **false**), `content` ("all"), `open_mode` ("edit"), `width` (2), `timeout_ms` (5000; 0 = never), `silence_nvim_mappings` (true), `label_pos` ("overlay"), `indicator` (true), `indicator_position` (`{ "nvim", "top", "center" }` = reference `nvim`|`filetree`, `top`|`bottom`, `left`|`center`|`right`), `keys` (see KEYMAPS.md), `hl_number` / `hl_typed` / `hl_indicator`
- **Highlights:** `FiletreeQuickpickNumber` (→ `Search`), `FiletreeQuickpickTyped` (→ `IncSearch`), `FiletreeQuickpickIndicator` (→ `PmenuSel`), all `default` links

```lua
require("filetree").setup({
  features = {
    quickpick = {
      enabled = true,
      content = "files", -- start with files only; `c` cycles
      timeout_ms = 3000,
      indicator_position = { "filetree", "bottom", "right" },
      keys = { cancel = { "<Esc>", "q" } },
    },
  },
})
```

## Auto Resize (opt-in)

Responsive tree sidebar width driven by `VimResized`: breakpoints map
editor column count to a tree width, defaulting to `<100 cols → 25`,
`<140 → 30`, `≥140 → 35` (the largest breakpoint ≤ current columns wins).
Off by default because it fights the manually-driven `window_size_cycler`
(on by default) — enabling both means every manual resize gets silently
reverted on the next `VimResized`.

- **Module:** [`features/nav/auto_resize/init.lua`](../../lua/filetree/features/nav/auto_resize/init.lua) (`M.set_width`)
- **Config:** `opts.features.auto_resize.enabled` (default **false**), `breakpoints`, `min_width` (20), `max_width` (60)
- **Usercmds:** `:Filetree resize [width]`

## Buffer Cycle

`<C-n>`/`<C-p>` cycle the buffer shown in the *adjacent* editor window
(like `:bnext`/`:bprevious`) while focus stays in the tree — verified
against a live neo-tree buffer to not collide with neo-tree's own default
`window.mappings` (unlike `<C-f>`/`<C-b>`, which neo-tree claims natively
for `scroll_preview`).

- **Module:** [`features/nav/buffer_cycle/init.lua`](../../lua/filetree/features/nav/buffer_cycle/init.lua)
- **Keymaps:** `<C-n>` next, `<C-p>` previous (config fields `keymap_next`/`keymap_prev`)

## Layout Guard

When the user closes every editor window but leaves the tree open, this
opens a new empty editor window automatically — fires on `BufDelete`,
`BufWipeout`, `WinClosed` — so the user is never trapped inside the tree
with nowhere to edit.

The new window is pinned to the screen edge **away from the tree**
(`:botright vsplit` for a left sidebar, `:topleft vsplit` for a right one),
via `util.window.open_editor_window()`. A bare `:vsplit` would instead
follow `'splitright'` relative to the tree window — which, at the moment the
guard fires, is the only window and therefore spans the full width — so with
the default `splitright = false` the new window appeared on the tree's left
and the sidebar was left sitting at the right edge of the screen. Because
the guard fires on `BufDelete`/`WinClosed`, that typically happened while a
picker float was up, which made it look like the tree randomly swapped sides
after using a picker. The side comes from `adapter.get_position()` (neo-tree
keeps it in its own state, so it is still known while the tree window is
closed), falling back to the tree window's actual column, and finally to a
plain `:vsplit` when the tree has no side at all (float / `current`). When
the guard fires while a floating window has focus, the split is made through
`nvim_win_call` so the float keeps focus.

The same helper backs the "no editor window exists yet" branch of
`open_variants`, `smart_create` and `create_from_template`, which had the
identical flip.

- **Module:** [`features/nav/layout_guard/init.lua`](../../lua/filetree/features/nav/layout_guard/init.lua)
- **Config:** `enabled` (default `true`), `delay_ms` (50)

## No Name Guard

Redirects a stray `[No Name]` editor window to a real open buffer (and
wipes the scratch one) rather than leaving it sitting alongside real
buffers. Two passes: `handle()` reacts to that window's own `BufWinEnter`
directly; `sweep()` additionally scans every window on `BufAdd`/
`BufDelete`/`BufWipeout` to catch a stray buffer that never itself refires
`BufWinEnter`. Both defer one tick and re-validate before acting, since
these events can fire mid-transition before Neovim settles the window's
replacement buffer. The tree's own window is always excluded, by
construction, so this can never race the tree plugin's own buffer
bookkeeping during open/close.

- **Module:** [`features/nav/no_name_guard/init.lua`](../../lua/filetree/features/nav/no_name_guard/init.lua)
- **Config:** `opts.features.no_name_guard.enabled` (default `true`)

## Sidebar Guard

Keeps the tree in its sidebar. A buffer that lands in the tree window — a
stray `:buffer N`, a mouse click on a tabline buffer (NvChad's tabufline,
bufferline, …) while the cursor is *inside* the tree, or another plugin's
`:edit` — is moved to a real editor window, and the tree is put back where
it was.

Without that, the swap displaces the tree, and neo-tree's own recovery
(`buffer_enter_event`) reopens the sidebar through a bare `:vsplit`: with
the default `splitright = false` the new file window lands to the *left* of
the tree and shoves the sidebar to the right. The repro is exactly "tree
open on the left, click a tabline buffer, tree jumps to the right".

The redirect serves both cases at once, because they are the same thing at
the API level: the only difference is what the caller meant, and nobody ever
means "put this file in the sidebar".

**`winfixbuf = true`** (off by default) swaps the redirect for the older
strategy: pin the window so the switch is *refused*. Callers that check the
flag (NvChad's `goto_buf`, neo-tree's own `open_file`) then route around it
by themselves, with no window shuffling at all. Callers that do not get

```
E1513: Cannot switch buffer. 'winfixbuf' is enabled
```

— and the file does not open. A plugin opening a README from its own picker
has no way to know a tree is focused, so that refusal broke reposcope,
lazygit and anything else driving `:edit` from a callback. It is kept as an
option for anyone who prefers a refusal to a redirect; the two do not
combine, since a refused switch never reaches the redirect.

Both strategies stand down for the one legitimate in-window buffer swap —
switching source via the `source_selector` winbar — which neo-tree brackets
with its `NEO_TREE_WINDOW_BEFORE_OPEN` / `_AFTER_OPEN` events.

neo-tree only. The redirect works on any Neovim; `winfixbuf = true`
additionally needs 0.10+ (`&winfixbuf`) and is a no-op below it.

- **Module:** [`features/nav/sidebar_guard/init.lua`](../../lua/filetree/features/nav/sidebar_guard/init.lua)
- **Config:** `opts.features.sidebar_guard.enabled` (default `true`), `opts.features.sidebar_guard.winfixbuf` (default **`false`** — the redirect; set `true` to pin with `winfixbuf` and refuse the switch instead)
