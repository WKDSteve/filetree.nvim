# Around it

How filetree.nvim's scope relates to its closest siblings in the collection.

## fileops.nvim

[fileops.nvim](https://github.com/WKDSteve/fileops.nvim) — the same file
operations without a tree in front of them, from any buffer. It fires `User
FileopsChanged` and reloads every tree registered at `lib.nvim.explorer`; the
own tree (`adapter = "native"`) is registered there and reads the folder the
operation touched ([backends](FEATURES/BACKENDS.md#after-a-file-operation)),
so the two stay in agreement without depending on each other.

## pdfport.nvim

[pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim) — the PDF bridge:
a `.pdf` node opens rendered in a buffer instead of shelling out to a system
reader.

## images.nvim

[images.nvim](https://github.com/WKDSteve/images.nvim) — the same idea for
image nodes in the preview pane.

## reposcope.nvim

[reposcope.nvim](https://github.com/WKDSteve/reposcope.nvim) — clones a
repository; this is how you read it afterwards without leaving Neovim.

## ui.nvim

[ui.nvim](https://github.com/WKDSteve/ui.nvim) — three contact points,
each with this plugin as the producer and ui.nvim as the consumer. The
right-click context menu is drawn by `ui.contextmenu` (see
[menu.md](menu.md)). Its statusline renders the cwd-mode badge from
`filetree.feature("cwd_mode").badge()`, the documented external-statusline
API, and refreshes on `User FiletreeCwdModeChanged`; the capsule and
history dots around the text are ui.nvim's own. And the breadcrumb trail in
`"winbar"` mode goes through `ui.winbar.set()` when ui.nvim is installed,
so it no longer overwrites other winbar producers — see
[Breadcrumbs](FEATURES/UI.md#breadcrumbs).

## my.nvim

[my.nvim](https://github.com/WKDSteve/my.nvim) — the other winbar
producer: a symbol trail (LSP or Tree-sitter) for the current buffer, in the
same `vim.wo.winbar` this plugin's breadcrumbs write to. Both hand their
line to `ui.winbar` when it is there, so neither overwrites the other;
without ui.nvim, whichever wrote last wins, and `mode = "float"` or
`mode = "statusline"` keeps this plugin off the surface.

## Dependency shape

All of the above are soft: without them everything else works unchanged.
[lib.nvim](https://github.com/WKDSteve/lib.nvim), one tree plugin and
[ui.nvim](https://github.com/WKDSteve/ui.nvim) for the context menu
(which degrades to a notify without it) are the real dependencies — see
[Requirements](installation.md#requirements).
