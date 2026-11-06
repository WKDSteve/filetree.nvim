> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# filetree.nvim

```
  ███████╗██╗██╗     ███████╗████████╗██████╗ ███████╗███████╗
  ██╔════╝██║██║     ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔════╝
  █████╗  ██║██║     █████╗     ██║   ██████╔╝█████╗  █████╗
  ██╔══╝  ██║██║     ██╔══╝     ██║   ██╔══██╗██╔══╝  ██╔══╝
  ██║     ██║███████╗███████╗   ██║   ██║  ██║███████╗███████╗
  ╚═╝     ╚═╝╚══════╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝
                              .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://wkdsteve.github.io/wkd/p/filetree/)

> Part of the [wkd](https://wkdsteve.github.io/wkd/) family — see this plugin's [page](https://wkdsteve.github.io/wkd/p/filetree/) on the site.

**Adapter-agnostic filetree features for Neovim.** Works with neo-tree.nvim,
nvim-tree.lua, netrw, oil.nvim and mini.files through one adapter interface, so
changing tree plugins costs you the plugin, not the workflow you built on top
of it.

**Screenshots, readable.** `<CR>` on an image opens an
[image viewer](docs/FEATURES/UI.md#image-viewer): zoom into the corner that
matters (Alt + wheel at the pointer), drag the picture around, cut a part into
a window of its own at full resolution, and save it (`gs`) or copy it to the
clipboard (`gy`). Needs [images.nvim](https://github.com/WKDSteve/images.nvim),
an image-capable terminal (WezTerm, iTerm2, Konsole) and ImageMagick — see
[Requirements](docs/installation.md#requirements).

---

## Documentation

Start at [docs/README.md](docs/README.md) — what's where, and which question
each page answers.

### The Basics

- [Requirements](docs/installation.md#requirements) — Neovim version, required and optional plugins.
- [Installation](docs/installation.md) — every plugin manager.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### Configuration & Commands

- [What you get with the defaults](docs/what-you-get.md) — the things worth knowing on day one.
- [All options](docs/configuration.md) — every `setup()` option and its default.
- [Commands](docs/commands.md) / [Bindings cheatsheet](docs/BINDINGS.md) — the `:Filetree` command tree and every keymap/autocommand at a glance.
- [Keymaps](docs/keymaps.md) — the tree-buffer keys, and how to remap or disable one.
- [Lua API](docs/api.md) — the public API, and how to register a custom adapter.

### The Rest

- [Features](docs/FEATURES/README.md) — every feature by category, the default-disabled ones, and deep dives into the core.
- [Around it](docs/around-it.md) — how this plugin's scope differs from its siblings in the collection.
- [Menu integration](docs/menu.md) — the context menu, and using filetree.nvim's actions in your own.
- [Integrations](docs/integrations.md) — the same menu entries, exposed for your own trigger.
- [Workflow](docs/WORKFLOW.md) — how the features combine once several are on at the same time.
- [Health check](docs/troubleshooting.md) — what `:checkhealth filetree` reports, and what to do about a warning.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add an adapter or a feature.
- [Feedback](https://github.com/WKDSteve/filetree.nvim/issues) — bugs, features, usage questions; broader discussion fits the [discussions board](https://github.com/WKDSteve/filetree.nvim/discussions).

`:help filetree` is the same reference inside the editor.

---

## License

MIT — see [LICENSE](LICENSE).
