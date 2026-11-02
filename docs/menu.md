# Menu

filetree.nvim ships a context menu, drawn through
[`ui.contextmenu`](https://github.com/WKDSteve/ui.nvim/blob/main/lua/ui/contextmenu/README.md) —
[nvzone/menu](https://github.com/nvzone/menu) if it's installed, or
`ui.kit.menu` (no third-party plugin, themed by whatever colorscheme
kit is already using) otherwise. Either way filetree.nvim itself does **not**
depend on nvzone/menu directly — the plugin *owns* its entries (create,
rename, copy/cut/paste, trash, open variants, path/markdown-link copy,
find/grep, node info, `:Inspect`, marks, open/close the tree itself); only
`lib.nvim` decides how they get drawn.

Entries are self-gating in a way that's worth trusting: `filetree.integrations.menu`
never lists an action whose feature function doesn't actually exist (disabled
feature, or an unknown name) — the entry is silently omitted rather than
wired to something that would error when clicked. `TESTS/smoke.lua` checks
every `(feature, function)` pair `items()` uses against the real feature
modules (not stubs), so a renamed/removed function fails CI instead of just
quietly dropping a menu entry; `TESTS/menu.lua` covers the gating/opt-out
logic itself against stubs.

## Right-click, out of the box

The `context_menu` feature binds `<RightMouse>` in the tree buffer and opens
the menu at the mouse — **on by default (opt-out)**, no wiring needed:

```lua
require("filetree").setup({
  -- omit entirely to just get it; here only to show the knobs:
  features = {
    context_menu = {
      enabled = true,          -- default true
      keymap  = "<RightMouse>", -- default; false disables the trigger without
                                 -- disabling the feature (e.g. if you'd rather
                                 -- wire your own trigger via items()/submenu()
                                 -- below — nothing else needs to change)
    },
  },
})
```

Right-click a node — that's the whole setup, with or without
[nvzone/menu](https://github.com/nvzone/menu) installed. `context_menu`
degrades to a single notify (not repeated, and not an error) only if
`ui.nvim` itself predates `ui.contextmenu`.

The menu acts on the node you clicked, not on wherever the cursor was. Only a
click on a node row counts: a right-click on the empty area below the last
node, on the tree's statusline or separator, or in another window does
nothing — no menu opens and the cursor stays put. `keymap` is a mouse trigger
(it reads the pointer position); to open the menu from a keyboard key, build
the trigger yourself as described below.

Every entry carries an icon (via `lib.nvim.ui.nerd_font`; a one-cell ASCII
fallback when `vim.g.have_nerd_font` isn't set), so the icon column lines up
whether or not a given entry has a glyph the same way `ui.contextmenu`
already draws it for every other consumer.

Two more things happen only with the kit renderer (`ui.contextmenu`'s
own fallback -- nvzone/menu exposes neither hook this needs):

- **The clicked node's line stays highlighted for as long as the menu is
  open**, so which node an entry would act on is never a guess. Cleared when
  the menu closes, or on the next real cursor move in the tree if the
  renderer never reports back that it closed at all (opening the menu
  itself moves focus to its own window, which must not count as "closed").
- **With the tree docked left or right, the menu opens beside the tree
  window instead of on top of it** — anchored to the tree window's own edge,
  so it can never cover (and hide) the row it just highlighted. With the
  tree floating or in the current window there is no fixed edge to dock
  against, so the menu falls back to opening at the click as before.

## Building your own trigger

The entries themselves live in `filetree.integrations.menu`, independent of
`context_menu`'s binding — useful if you want a different trigger (a keymap
instead of a click), or to merge filetree's entries into a combined menu
alongside other plugins':

```lua
local ft = require("filetree.integrations.menu")

-- inline entries for the current node (empty when disabled):
local items = ft.items()            -- { { name, cmd, rtxt }, … }

-- or a single fly-out entry:
local sub = ft.submenu()            -- { name = "  Filetree", items = {…} } | nil

-- e.g. your own trigger for the tree window:
--   require("ui.contextmenu").open(ft.items(), { mouse = true })
```

Entries are self-gating: an action whose feature is disabled is omitted, and
whole groups can be turned off. The menu closes before running an entry (both
renderers), so the tree node under the cursor is the active context — exactly
as if the keymap had been pressed. Opt-out per group via `config.menu` (this controls
WHICH entries appear, for both the built-in trigger and any of your own):

```lua
require("filetree").setup({
  menu = {
    enable    = true,
    fileops   = true, -- create / rename / batch rename / move / template
    clipboard = true, -- copy / cut / paste / copy to the system clipboard
    delete    = true, -- trash
    open      = true, -- vsplit / split / tab / system app / file manager
    media     = true, -- image/PDF nodes only: preview / open externally / OCR / image info
    paths     = true, -- copy path / markdown link
    search    = true, -- find files / grep in dir
    info      = true, -- node info + Inspect (`:Inspect`, highlight/treesitter groups at the click)
  },
})
```
