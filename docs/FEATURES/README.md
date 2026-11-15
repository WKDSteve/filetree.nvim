# Features

filetree.nvim ships 50+ opt-out features organized around the plugin's own
`lua/filetree/features/<category>/<name>/` layout (the single source of
truth is `filetree.features.FEATURES` / `CATEGORY_ORDER` in
[`lua/filetree/features/init.lua`](../../lua/filetree/features/init.lua)).
This folder regroups those categories into fewer, reader-facing themes:

- **[CORE](CORE.md)** — the backend-adapter abstraction and the root/cwd
  policy stack (`cwd_mode`, `cwd_sync`, `project_root`) that most other
  features build on.
- **[BACKENDS](BACKENDS.md)** — the five tree-plugin adapters
  (neo-tree, nvim-tree, netrw, oil.nvim, mini.files) and the
  Windows/neo-tree-specific plumbing that keeps them from locking files.
- **[NAVIGATION](NAVIGATION.md)** — moving the tree root, revealing files,
  and window lifecycle around the tree.
- **[UI](UI.md)** — everything the tree window draws: preview, node info,
  breadcrumbs, sizes, styling, the cheatsheet.
- **[FILEOPS](FILEOPS.md)** — create, rename, copy/move, trash, and the
  reference engine that keeps links and imports pointing at the right file
  through all of it.
- **[SEARCH_AND_PATHS](SEARCH_AND_PATHS.md)** — filtering, finding, grepping,
  and copying paths/links out of the tree.
- **[AI](AI.md)** — the own tree asked in words or by voice: a sentence
  becomes its own actions through ai.nvim (off by default).
- **[INTEGRATIONS](INTEGRATIONS.md)** — external programs, git, LSP, diff,
  marks/session, and the PDF bridge to pdfport.nvim.

All features are **on by default** (opt-out); a short, deliberately-argued
list stays off until enabled — see [CORE.md](CORE.md) and
[BACKENDS.md](BACKENDS.md) for which ones and why. Every tree-buffer key is
remappable; the exhaustive machine-readable catalog is
[`docs/BINDINGS/KEYMAPS.md`](../BINDINGS/KEYMAPS.md) /
[`docs/BINDINGS.lua`](../BINDINGS.lua).
