# Installation

## Requirements

| | |
| --- | --- |
| Neovim | **0.11+** — `vim.system()` and `vim.uv` are used unguarded, and lib.nvim itself requires 0.11 |
| [lib.nvim](https://github.com/WKDSteve/lib.nvim) | required — the `:Filetree`/`:Ft` command layer is built on `usercmd.composer`, and `require("filetree")` cannot succeed without it. Every other use (notify, `find_root`, keymaps, autocmds, …) requires it the same way; none of them has a local fallback. The yes/no and choice dialogs ask through its `ui.dialog` (`dialog.yesno`: a lib.nvim from 2026-10-28 or newer; `:checkhealth filetree` says if it is older) |
| [ui.nvim](https://github.com/WKDSteve/ui.nvim) | required — `ui.kit` backs the select dialogs, the dialogs' buttons (through lib.nvim's `ui.dialog`), trash undo, marks, filter, live search, the cheatsheet and more; `setup()` throws if it's missing, the same way a missing `lib.nvim` does. Only the context-menu feature's own `ui.contextmenu` submodule degrades to a single notify (not an error) on its own, and only when `ui.nvim` is installed but predates that submodule — see [Integrations](integrations.md) |
| One of [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) or [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) | required — netrw, oil.nvim and mini.files are supported as additional adapters, not as the primary one |

Optional, each detected at runtime and degrading to nothing when absent:

| | |
| --- | --- |
| `trash-put` / `gio` | The trash feature; without one, delete is a real delete |
| `rg` (ripgrep) | Grep-in-dir and the reference scan |
| [pdfport.nvim](https://github.com/WKDSteve/pdfport.nvim) | `.pdf` nodes rendered into a buffer |
| [images.nvim](https://github.com/WKDSteve/images.nvim) | The [image viewer](FEATURES/UI.md#image-viewer) on `<CR>`: zoom, pan, cut-out parts, `gs`/`gy`. It in turn wants a terminal that draws OSC 1337 images (WezTerm, iTerm2, Konsole), **ImageMagick** (`magick`) for zoom/cut/save/copy, `'mouse'` for the wheel and drags, and a current lib.nvim for `gy` (image clipboard) |
| [pickers.nvim](https://github.com/WKDSteve/pickers.nvim) | `f` (find files) and `gr` (grep) on a node run through it — your engine, your `find` flags, and the picked file is revealed in the tree; otherwise telescope, fzf-lua, mini.pick or a built-in fallback. On by default, opt-out on both ends — see [pickers.nvim integration](configuration.md#pickersnvim-integration) |
| [which-key.nvim](https://github.com/folke/which-key.nvim) | Labels for the keymap set |
| [nvzone/menu](https://github.com/nvzone/menu) | Renders the context menu if installed; `ui.kit.menu` draws it otherwise, so right-click works either way — see [Integrations](integrations.md) |
| [gitsuite.nvim](https://github.com/WKDSteve/gitsuite.nvim) | Git Status decorations refresh immediately on a branch switch or conflict resolution instead of waiting for the next write/focus change — see [Integrations](FEATURES/INTEGRATIONS.md#git-status) |

The CLI tools above are declared in [install.json](install.json) and read by
lib.nvim's
[deps module](https://github.com/WKDSteve/lib.nvim/blob/main/lua/lib/nvim/deps/README.md).
A popup explains what is missing the first time `setup()` runs after
installing; `:Lib deps show filetree.nvim` repeats it any time, and it is
folded into `:checkhealth filetree`. Turn the popup off in this plugin's own
spec with `deps_popup = false`, or globally with
`vim.g.lib_nvim_deps_disable_first_run = true`.

## Installation methods

filetree.nvim must load **after** your tree plugin's own config runs, so pick a
load point like `event = "VeryLazy"` (lazy.nvim) or place the `setup()` call after
the tree plugin is configured. Only **one** tree plugin is needed; `lib.nvim`
and `ui.nvim` are both declared dependencies.

### lazy.nvim

```lua
{
  "WKDSteve/filetree.nvim",
  event = "VeryLazy",   -- load AFTER the tree plugin's config function runs
  dependencies = {
    "WKDSteve/lib.nvim",        -- shared helpers
    "WKDSteve/ui.nvim",         -- right-click context menu (ui.contextmenu)
    "nvim-neo-tree/neo-tree.nvim", -- or: "nvim-tree/nvim-tree.lua"
  },
  config = function()
    require("filetree").setup({ adapter = "neotree" })
  end,
}
```

### packer.nvim

```lua
use {
  "WKDSteve/filetree.nvim",
  after    = "neo-tree.nvim",   -- ensure the tree plugin is configured first
  requires = {
    "WKDSteve/lib.nvim",
    "WKDSteve/ui.nvim",
    "nvim-neo-tree/neo-tree.nvim", -- or: "nvim-tree/nvim-tree.lua"
  },
  config = function()
    require("filetree").setup({ adapter = "neotree" })
  end,
}
```

### vim-plug

```vim
Plug 'WKDSteve/lib.nvim'
Plug 'WKDSteve/ui.nvim'
Plug 'nvim-neo-tree/neo-tree.nvim'   " or: Plug 'nvim-tree/nvim-tree.lua'
Plug 'WKDSteve/filetree.nvim'
```

Then, after neo-tree/nvim-tree is set up (e.g. in an `init.lua` sourced later):

```lua
require("filetree").setup({ adapter = "neotree" })
```

### mini.deps

```lua
local add, now = MiniDeps.add, MiniDeps.now
add({
  source  = "WKDSteve/filetree.nvim",
  depends = { "WKDSteve/lib.nvim", "WKDSteve/ui.nvim", "nvim-neo-tree/neo-tree.nvim" },
})
now(function()
  require("filetree").setup({ adapter = "neotree" })
end)
```

## See also

- [Configuration](configuration.md) — full option reference and adapter selection.
- [Quick start](quickstart.md) — the shortest possible setup snippet.
