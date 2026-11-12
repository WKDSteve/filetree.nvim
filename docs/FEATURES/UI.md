# UI

Everything the tree window itself draws or decorates — preview, node info,
breadcrumbs, sizes, cursor/highlight styling, and the right-click context
menu. Backend-agnostic: every feature here works the same regardless of
which adapter (neo-tree/nvim-tree/netrw/oil.nvim/mini.files) is active,
since they operate on the tree buffer rather than a specific plugin's API.

## Preview

Toggles a live preview of the node under the cursor in the adjacent editor
window, or a floating window — updates as the cursor moves, no separate
open action needed. `<Tab>`/`<CR>` dispatch images/PDFs to their own
viewer instead of rendering raw bytes as text; `<PageUp>`/`<PageDown>` page
a long preview without leaving the tree.
With [images.nvim](https://github.com/WKDSteve/images.nvim) installed,
`<CR>` on an image opens the image viewer below; `<Tab>` keeps the inline
view.
Files whose extension is in `features.preview.system_exts`
(default `msg`, `eml`, `oft`, i.e. Outlook mails) go to the OS default app
instead; `{}` turns that off.

In the editor-window mode a binary file, or a file larger than
`features.preview.max_bytes` (default 1 MiB, `0` = no limit), is not loaded:
the window stays as it was and a one-line notice says why. The floating mode
hex-dumps binaries and reads only the first `max_lines` lines.

### Image viewer

`<CR>` on an image (a screenshot, a photo, a diagram) opens it in a centred
float — images.nvim's `:Image zen` window — sized at
`features.preview.image.float` (default
`{ width = 0.66, height = 0.66, viewport = true }` of the editor). It is made
for reading screenshots: zoom into the corner that matters, move around, cut
the part you need into a window of its own, save it or paste it somewhere
else.

| In the float | Does |
| --- | --- |
| `+` / `-`, Alt + mouse wheel | Zoom in / out; the wheel keeps the point under the pointer in place |
| `h` `j` `k` `l`, arrows / middle button held + drag | Move the visible part; `H` `J` `K` `L` to an edge |
| `0` | The whole picture again |
| Left button drag, or `v` + `hjkl` + `<CR>` | Open the marked part in a float of its own, at full resolution — works again inside it; `<BS>` goes back, `q` closes them all |
| `gs` | Save what is shown as a PNG next to the original (`<name>.crop-<x>-<y>-<w>x<h>.png`, never overwriting) |
| `gy` | Copy what is shown to the clipboard as an image |
| `<S-Up>` / `<S-Down>` | Grow / shrink the window (2/3, 90%, full screen) |
| `?` | Every key bound in the float, as it is configured |

The title shows the zoom factor and how deep you are in cut-out parts
(`shot.png · 2.3× · 2/2`). All keys are images.nvim's and are set in its
`display.zen.keys` — see
[images.nvim's BINDINGS, "Zen window"](https://github.com/WKDSteve/images.nvim/blob/main/docs/BINDINGS.md#zen-window).
`image.float.viewport = false` opens the float plain: just the picture, its
size keys, `?` and `q`.

What it needs (all optional; without them `<CR>` falls back to the inline
view, or the part that needs a tool says so once):

- [images.nvim](https://github.com/WKDSteve/images.nvim) — the float itself, with `backend = "auto"` (default) or `"images.nvim"`.
- A terminal that draws images through OSC 1337 — WezTerm (the one that works on native Windows), iTerm2, Konsole; elsewhere images.nvim falls back to block graphics.
- ImageMagick (`magick` on `PATH`) — zooming, cutting a part, `gs` and `gy`, since each view is a crop; without it the float still shows the whole picture.
- `'mouse'` including normal mode (`set mouse=a`) — the wheel and the drags.
- An up-to-date [lib.nvim](https://github.com/WKDSteve/lib.nvim) — `gy` uses its `cross.copy_image_to_clipboard` (PowerShell on Windows, `wl-copy`/`xclip` on Linux, `osascript` on macOS).

`image.float = false`, a `backend` other than `"auto"`/`"images.nvim"`, or an
images.nvim without the float gives `<CR>` the same view as `<Tab>`.

- **Module:** `lua/filetree/features/ui/preview/`
- **Keymaps:** `<Tab>`/`<CR>` (open/dispatch), `<PageUp>`/`<PageDown>`
  (scroll) — see [BINDINGS/KEYMAPS.md](../BINDINGS/KEYMAPS.md)

## Node Info

A float (`I`) reporting path, type, size, permission mode, and mtime for
the node under the cursor. For a file: line count. For a directory:
recursive item count plus aggregate size — computed on demand, not kept
live, so it reflects the tree at the moment you press the key.

A symlink's Type line says so (`file (symlink)`) and gets its own `Link to:`
line naming the target — flagged `(broken — target missing)` when the
target does not resolve, rather than the whole window falling back to "No
stat info" the way it used to (a plain `stat` alone sees nothing at all
through a dangling link). A file with more than one hard-linked name gets a
`(hardlink, N names)` note on its Type line instead: every one of its names
is an equal hard link, so this reads as "shares its data with N-1 other
name(s)", not "this one IS the hard link" — there is no single dirent to
single out that way.

**References.** For a file that something references, the float ends with a
`References (N)` section — one row per referencing file with its line
numbers (`docs/guide.md:12,40`), cut after 12 files / 6 lines each with a
pointer to `:Filetree references` for the full list. A file nobody
references gets no section at all, not even a heading. The scan is
asynchronous (a project-wide search): the float opens at once and is
reopened with the section when the count arrives; the count is cached for
30 seconds. Directories never scan. `node_info.references = false` turns the
section off. What counts as a reference is the reference engine's
(`refs.providers`).

- **Module:** `lua/filetree/features/ui/node_info/`
- **Keymaps:** `I`
- **Config:** `node_info.references` (default `true`)

## Link Marker

Marks a symlinked node in the tree listing so it reads differently from an
ordinary file/directory at a glance: a small `⇢` sign right before the
node's own name (`⇢!` for a symlink whose target could not be resolved),
optionally followed by its target at the end of the line when
`show_target = true`. The sign's position is found fresh per render, as the
byte offset of the node's own name on the line — past whatever indent,
tree-guide characters and icon the backend drew, not a fixed offset — so it
lines up correctly regardless of nesting depth or indent width, and never
splices into the middle of a guide line.

**On by default**, unlike most decorators here — it costs nothing extra per
render: it reads `is_link`/`link_to`/`link_broken` straight off data the
neo-tree and nvim-tree adapters already hold (neo-tree's own scan already
calls `uv.fs_readlink()` for every link it finds), not a filesystem `stat`
per node.

**Hard links are not decorated here.** Telling a file with more than one
name apart from an ordinary one needs an actual `stat`, and every one of
its names is an equal hard link — there is no single dirent to flag as *the*
hard link. See Node Info's `I` window for that instead, on demand rather
than on every rendered line.

**Backend support.** Same line-resolved-decoration contract as `size_info`
below: neo-tree and nvim-tree draw it, netrw/oil.nvim/mini.files don't.
Whether a dangling symlink gets its own `broken` sign also depends on the
backend: neo-tree already knows (it tried to resolve the link during its
own scan); nvim-tree does not expose that, so there a symlink always gets
the plain sign, working or not.

- **Module:** `lua/filetree/features/ui/link_marker/`
- **Config:** `opts.features.link_marker` — `show_target` (default **false**), `target_hl` (`"Comment"`), `signs.symlink` (`{text="⇢", hl="Special"}`), `signs.broken` (`{text="⇢!", hl="DiagnosticError"}`)

## Broken Link Notify

Link Marker's `⇢!` sign only exists in the tree — once a dangling symlink's
target is actually open in an editor window, that context is gone. Opening
one reads exactly like opening any other nonexistent path to Neovim: a
silent, empty `[New]` buffer, no error, no hint why it's empty.

Warns instead, once, the moment such a buffer is created: `BufNewFile`
fires exactly when Neovim could not read the path it was asked to open —
precisely the dangling-symlink case, since Neovim never resolves through
the link itself, so the buffer name IS the symlink's own path.

**Backend-agnostic by construction.** A single global autocmd, not tied to
the tree's own `<CR>` or any particular adapter — it catches neo-tree's
native open, `open_variants`' split/vsplit/tabnew, `open_replace`'s
edit/swap, `gf`, a plain `:edit`, all the same way, without any of them
needing to know this feature exists.

- **Module:** `lua/filetree/features/ui/broken_link_notify/`
- **Config:** `opts.features.broken_link_notify` — `enabled` (default **true**)

## Kit Slot

A `lib.nvim.ui.kit` sidebar on the left and a tree on the left stand next to each other, each unaware of the
other. This registers the tree at `lib.nvim.ui.kit.sidebar.register_foreign`, so the two agree on one slot:
opening a kit sidebar where the tree is takes the tree off the screen and remembers it, closing that sidebar
brings the tree back, and a tree opened by hand moves a kit sidebar in its slot out of the way the same way.

**Backend-agnostic.** Everything goes through the adapter (`get_winid`, `close`, `open_cwd`, `get_position`), so
it works the same for neo-tree, nvim-tree and the others. A tree that is not on a side (`float`, `current`) is
not a sidebar and takes no slot.

- **Module:** `lua/filetree/features/ui/kit_slot/`
- **Config:** `opts.features.kit_slot` — `enabled` (default **true**; set `false` to let a sidebar and the tree
  stand side by side), `name` (default `"filetree"`)

## Breadcrumbs

Shows the path from the tree root down to the current node, so a deeply
nested file's location is legible without scrolling up through every
parent directory.

**Sharing the winbar.** In `"winbar"` mode (the default) the trail is
written to every non-tree, non-floating window — and `vim.wo.winbar` is a
surface with no notion of an owner. `my.nvim`'s breadcrumbs put a symbol
trail in the same place, and ui.nvim's `ui.winbar.set()` exists to arbitrate
exactly that. This feature always goes through it, so the two no longer
overwrite each other. Use `mode = "float"` or `mode = "statusline"` to stay
off the surface entirely.

- **Module:** `lua/filetree/features/ui/breadcrumbs/`

## Size Info

Shows file/directory sizes inline in the tree listing.

**Off by default, opt-in** — purely cosmetic, and `dir_async` runs
`du`/`Get-ChildItem` per directory node once it renders, which is not
something to spring on someone who just wanted a tree.

**Backend support.** Drawn as extmarks on the node's own line, which needs
the adapter to say which node a given line holds (`get_node_at_line`). The
neo-tree and nvim-tree adapters implement it; netrw, oil and mini.files do
not, so this renders nothing there rather than misplacing anything.

- **Module:** `lua/filetree/features/ui/size_info/`
- **Config:** `opts.features.size_info` — `enabled` (default **false**, opt-in), `show_files` (true), `show_dirs` (true), `dir_async` (true — async `du -sb`/`Get-ChildItem` for directories; `false` skips directory sizes entirely rather than blocking), `hl_group` (`"Comment"`)

## Window Size Cycler

Cycles the tree window's width through a configured set of presets
(`w`) — a fixed, deliberate step instead of manual `<C-w>` resizing.

- **Module:** `lua/filetree/features/ui/window_size_cycler/`
- **Keymaps:** `w`

## Window Style

A blank statusline for the tree window (adapter-agnostic, on by default)
plus optional isolated tree highlight groups (opt-in), so the tree reads
as a distinct UI region rather than another ordinary buffer.

- **Module:** `lua/filetree/features/ui/window_style/`
- **Config:** isolated highlights are opt-in — see
  [configuration.md](../configuration.md)

## Cursor Hide

Hides the block cursor inside the tree window, resolved adapter-agnostic
via each adapter's own `filetypes` list rather than a single hardcoded
filetype check.

Hiding the real cursor only makes sense as long as something else marks the
current line — normally `'cursorline'`. `force_cursorline` (default `true`)
force-enables it on the tree window for exactly as long as the cursor stays
hidden, and restores whatever it was on leave, so the tree can never end up
with **no** visible position indicator at all (a plugin's own
cursorline-management autocmd racing this one, a colorscheme reset, …) —
that combination looks exactly like a lost cursor: movement, opening nodes
and closing the window all keep working, there is just nothing on screen
marking where you are. Set `force_cursorline = false` to go back to leaving
`'cursorline'` alone.

- **Module:** `lua/filetree/features/ui/cursor_hide/`
- **Config:** `enabled` (default `true`), `force_cursorline` (default `true`)

## Tree Reset

`<Esc>` in one keystroke clears the active preview, any live filter, and
an in-progress live search — the "get back to a plain tree" key.

- **Module:** `lua/filetree/features/ui/tree_reset/`
- **Keymaps:** `<Esc>`

## Opened-buffer Sync

Re-renders the tree whenever a buffer opens or closes, so the tree
plugin's own "this file is open" highlight stays in sync with reality
instead of only updating on the tree's own redraw triggers.

- **Module:** `lua/filetree/features/ui/opened_sync/`

## Current Highlight (opt-in)

Creates two highlight groups — `FiletreeCurrentFile` and
`FiletreeCurrentParent` — and applies them as extmarks on the tree buffer,
so the file backing the active editor window (and its parent directory)
stand out from the rest of the listing. Off by default: the shipped
colours are hardcoded and only suit some colorschemes; enable and
override the highlight groups yourself once you know they fit.

- **Module:** `lua/filetree/features/ui/current_hl/`
- **Config:** `features.current_hl.enabled = true`

## Cheatsheet

A paged float built from what is **actually bound** on the tree buffer, not
from a table of defaults — so a key filetree rebinds (`D` for diff, say) is
listed as what it does now. It works on every adapter, neo-tree included
(it replaces neo-tree's native `?`, whose list was built from a hand-kept table
that lagged the features). `<Tab>` / `<S-Tab>` (or `1`..`4`) turn the pages:

| Page | Content |
|------|---------|
| 1 `filetree` | filetree.nvim's own keymaps, grouped by category, plus the global ones |
| 2 `other keys` | every other buffer-local key: the adapter's native ones and those other plugins attach (pickers.nvim entry actions, pdfport, ...) |
| 3 `commands` | the `:Filetree` sub-commands |
| 4 `conflicts` | only when two actions claim one key: which one is live, free alternatives; `<CR>` moves one (`:Filetree keys`) |

**Design presets (`style`).** The float's border and highlighting come from
`ui.nvim`'s own `ui.kit.theme` preset system (the same one behind
`sessions.nvim`'s and `casedesk.nvim`'s chips) — set
`features.cheatsheet.style` to one of this ecosystem's three shared names:

| `style` | Look |
|---------|------|
| `"classic"` | borderless, plain text |
| `"chip"` | flat, square-cornered border |
| `"rounded_chip"` (or leave `style` unset) | rounded border — today's default look |

Any other `ui.kit.theme` preset name also works as-is — the built-ins are
`"solid"`, `"double"`, `"ascii"`, `"hacker"`, `"menu"` (see `ui.nvim`'s own
docs), or one you registered yourself via `ui.kit.theme.setup({presets =
{...}})`. The active page's tab in the tab strip is always highlighted with
the resolved theme's "selection" colour, regardless of `style`.

```lua
require("filetree").setup({
  features = { cheatsheet = { style = "chip" } },
})
```

- **Module:** `lua/filetree/features/ui/cheatsheet/`

## Context Menu

Right-click (`<RightMouse>`) opens a context menu through
`ui.contextmenu`, which draws with
[nvzone/menu](https://github.com/nvzone/menu) if it is installed, or its own
themed `ui.kit.menu` (no third-party plugin needed) otherwise —
either way, right-click works out of the box. With the kit renderer, the
clicked node's line is highlighted for as long as the menu stays open, and
with the tree docked left/right the menu opens beside it rather than on top
of it. Only a click on a node opens it: a right-click on the empty area below the
last node, on the tree's statusline or separator, or in another window does
nothing — no menu, and the cursor stays where it was. See
[docs/menu.md](../menu.md) for the entries offered and the full detail on both.

- **Module:** `lua/filetree/features/ui/context_menu/`
- **Keymaps:** `<RightMouse>`
- **Docs:** [menu.md](../menu.md)
