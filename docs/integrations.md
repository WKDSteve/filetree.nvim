# Integrations

`lua/filetree/integrations/` holds the bridges that expose filetree.nvim's
own actions to something outside the plugin's own trigger — the context menu
below. The pickers.nvim bridge (going the other way: filetree hands a directory
to a picker) has its own section at the end. See [FEATURES/INTEGRATIONS.md](FEATURES/INTEGRATIONS.md)
for the other direction instead: the features that connect filetree.nvim
outward to git, LSP, sessions and pdfport.nvim.

## Context menu

`filetree.integrations.menu` contributes context-aware entries in the context-menu entry shape, acting on the node
under the cursor. On the tree's own buffer filetree.nvim opens them itself
through `ui.contextmenu`, which needs no third-party menu plugin (its own
kit renderer draws them). A host —
typically your own `<RightMouse>` dispatcher, for buffers filetree.nvim does
not own — can still compose the same entries into its own menu:

```lua
local ft = require("filetree.integrations.menu")

local items = ft.items()   -- entries for the node under the cursor
local sub = ft.submenu()   -- or a single fly-out entry
```

Entries are self-gating: an action whose feature is disabled is omitted
rather than wired to something that would error when clicked. Opt out per
group via `config.menu` (`fileops`, `clipboard`, `delete`, `open`, `paths`,
`search`, `info`).

The full wiring — right-click out of the box, the kit-renderer extras
(highlighted node, edge-anchored popup), and every entry offered — is
[menu.md](menu.md).

## pickers.nvim

`find_files` (`f`, `tf`) and `grep_in_dir` (`gr`, `tg`) hand the directory of the
node under the cursor to [pickers.nvim](https://github.com/WKDSteve/pickers.nvim)
when it is installed, instead of driving a picker of their own. The bridge is
`filetree.util.pickers`, which calls `pickers.integrations.filetree` over there:

- **Engine and flags** are the ones the rest of your setup uses (telescope,
  fzf-lua or snacks; `find.hidden`/`no_ignore`/`follow`; entry actions).
- **The picked file is revealed in the tree** (`find_files.reveal_on_open`),
  through pickers.nvim's `on_select` hook. A pickers.nvim without the hook just
  opens the file.
- **Opt-out on both ends**, default on: `integrations.pickers = false` here,
  `filetree = { enabled = false }` in pickers.nvim. Either one makes `f`/`gr`
  fall back silently to telescope / fzf-lua / mini.pick / the built-in backend;
  `tf`/`tg` say "pickers.nvim not available", since they asked for it.
- `:checkhealth filetree` has a "pickers.nvim integration" section that says
  which of the conditions (installed, this switch, the other switch) holds.

Configuration: [configuration.md](configuration.md#pickersnvim-integration). The
pickers.nvim side is documented in its own
[FILETREE feature page](https://github.com/WKDSteve/pickers.nvim/blob/main/docs/FEATURES/FILETREE.md).
