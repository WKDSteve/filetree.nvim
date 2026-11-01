# Search & paths

Filtering, finding and grepping inside the tree, plus getting a node's
path — or its content, as a Markdown link — out of the tree and onto the
clipboard or into a buffer.

## Filter

Live-filters the tree listing as you type (`/`) — narrows what's shown
without leaving the tree, unlike find/grep below which open a separate
picker.

**Backend support.** neo-tree and nvim-tree narrow the listing for real,
each through its own filter: neo-tree's `state.search_pattern` plus a refresh,
nvim-tree's `Explorer.live_filter`. netrw, oil and mini.files have no filter of
their own, and the intended fallback — dimming the non-matching lines instead
of hiding them — needs the adapter to resolve a line to a node
(`get_node_at_line`, see
[Backends](BACKENDS.md#line-resolved-decorations)), which none of the three
implements. So `/` still does nothing there; implementing `get_node_at_line`
for them is what would fix it.

Both native branches were broken until 2026-09-17, and broken in a way worth
remembering: each wrapped its call in a bare `pcall` and reported success
regardless. neo-tree's `manager.filter_all` had been removed upstream, and
nvim-tree's `api.tree.search_node` takes no argument at all (it opens its own
`Search:` prompt and reveals a single file). So `/` raised, the error was
swallowed, the branch claimed to have handled it, and the dim fallback was
never reached — `/` silently did nothing on the two backends that had a filter.
`try_native_filter` now reports failure honestly, so a native path that breaks
again degrades to dimming instead of to nothing.

On neo-tree the filter drives the tree the adapter resolves (`adapter.get_state`:
the tree `/` was pressed in, else the live tree on the current tab, else one live
on a background tab), not neo-tree's ambient `manager.get_state("filesystem")`.
That one is always the current tab's state and creates an empty placeholder for
a treeless tab, so `:Filetree filter` run from a tab without a tree used to filter
that placeholder and leave the visible tree untouched (`TESTS/adapter_lines.lua`,
"the filter drives the live tree"). A closed tree is not opened by a filter or a
clear: it keeps the pattern and shows it the next time it opens.

- **Module:** `lua/filetree/features/search/filter/`
- **Keymaps:** `/`

## Live Search

Incremental search inside the tree (`gs`) — jumps between matches without
filtering the listing down, complementing `filter` rather than
duplicating it.

- **Module:** `lua/filetree/features/search/live_search/`
- **Keymaps:** `gs`

## Find Files

`f` finds files via whichever picker is available — pickers.nvim first, then
telescope, fzf-lua, mini.pick, or a built-in fallback — auto-detected. `tf`
forces pickers.nvim specifically. A telescope-only key is available through
`keymap_telescope` (off by default). The pickers.nvim path is opt-out on both
sides: `integrations.pickers = false` here, `filetree = { enabled = false }`
in pickers.nvim; see [pickers.nvim integration](../configuration.md#pickersnvim-integration).

With `reveal_on_open` (default on) the picked file is revealed in the tree, also when
the pick went through pickers.nvim (needs a pickers.nvim that ships the `on_select`
hook; an older one just opens the file).

- **Module:** `lua/filetree/features/search/find_files/`
- **Keymaps:** `f` (auto), `tf` (force pickers.nvim)

## Grep In Directory

`gr` greps inside the node's directory using the same auto-detected
picker as `find_files`; `tg` forces pickers.nvim specifically.

- **Module:** `lua/filetree/features/search/grep_in_dir/`
- **Keymaps:** `gr` (auto), `tg` (force pickers.nvim)

## Path Copy

Copies the node's absolute path or its parent directory's path
(`[a`/`]a`), or the path relative to the project root (`[R`/`]R`) — keys
covering the "I need this path somewhere else" cases without a prompt.

`absolute`, `dirname` and `project_root` write the **real** absolute path,
also with the top-level [`env_roots`](../configuration.md#env-roots) option
on: the `$NAME/rest` form has a key of its own, `[e` (below), so asking for
the absolute path means asking for the real one. `uri` keeps the real path
too.

Every format copies with forward slashes, on every OS — `sub/b.lua`, never
`sub\b.lua`. That is the same separator the tree, its prompts and its
notifications use, and the one this feature's own examples have always shown;
`fnamemodify` was quietly handing back native ones on Windows for `absolute`,
`relative`, `dirname`, `line` and `project_root`. Forward slashes work in
Neovim, in libuv and in every shell the clipboard is likely to land in — only
a literal `explorer.exe`/`cmd /c` invocation needs native ones, and those are
converted where they are invoked, not here.

On a symlink node, every format reads the link's own path — never resolved
to whatever it points at. Consistent with the rest of the plugin's symlink
handling (Copy/Move's paste creates a new symlink rather than a
dereferenced copy; Node Info shows the link's own path with the target on
a separate `Link to:` line, never substituted in). `:Filetree symlink
check` or Node Info's `I` is the way to see what a symlink resolves to.

Mark-aware: with nodes marked (see [Marks](INTEGRATIONS.md#marks)), every `path_copy`
keymap — including `pick` — copies one line per marked node instead of just
the node under the cursor. Same rule as `copy_move`/`trash`: marks win when
any are set, otherwise it's the cursor's node.

Two more answer the cases where neither the cwd nor the project root is
the right frame of reference:

`]b` copies the path **relative to the buffer open in the editor**, in
the `./x` / `../x` form a Markdown link target needs. This is the one
that makes a pasted link actually resolve: with the cwd at the repo
root, `docs/ROADMAP/ROADMAP.md` is correct in the root README and wrong
in `docs/ROADMAP/Notes.md`, where the same file is `./ROADMAP.md`. `]b`
reads the open buffer's directory instead of the cwd, so it is right in
both. The base is the editor window's file, then the alternate file
(`#`), then the cwd — so it still answers something when the tree is the
only window.

`[e` copies the **absolute** path, but folds a configured environment
variable back into its root: `$REPOS_DIR/filetree.nvim/lua/x.lua` rather
than `E:/repos/filetree.nvim/lua/x.lua`. Written into a note, that path
still means the same file on a machine where the checkout lives on
another drive. The variables to try are `env_roots` (default
`{ "REPOS_DIR" }`, written without the `$`), on top of the top-level
[`env_roots`](../configuration.md#env-roots) roots and the shared ones of
lib.nvim's named-roots registry; the deepest match wins, so
a `$REPOS_DIR` inside `$HOME` beats `$HOME`.

`nvim_config_root` (default `true`) additionally tries `$NVIM_CONFIG_DIR`,
backed by `vim.fn.stdpath("config")` — no environment variable of that name
has to actually be set. Without it, a node inside your own Neovim config
falls all the way through `env_roots` (it typically lives nowhere near
`$REPOS_DIR`) to the plain absolute path; with it, `[e` on
`~/.config/nvim/lua/plugins/foo.lua` copies
`$NVIM_CONFIG_DIR/lua/plugins/foo.lua`. Set it `false` to turn this off.
With no variable or `$NVIM_CONFIG_DIR` matching, the plain absolute path
comes back.

```lua
path_copy = {
  enabled = true,
  keymap_buffer_rel = "]b",
  keymap_env_root = "[e",
  -- Longest match wins; each name is written without the `$`.
  env_roots = { "REPOS_DIR", "XDG_CONFIG_HOME", "HOME" },
  nvim_config_root = true, -- also try $NVIM_CONFIG_DIR (stdpath("config"))
}
```

- **Module:** `lua/filetree/features/paths/path_copy/`
- **Keymaps:** `[a`, `]a`, `[R`, `]R`, `]b`, `[e`

## Lua Require Copy

`rq` copies the node as a `require("…")` string, resolved the same way
[FILEOPS.md](FILEOPS.md)'s `create_from_template` resolves its
`${module}` template variable — for a Lua file under a real `lua/`
directory, the canonical dotted module path.

- **Module:** `lua/filetree/features/paths/lua_require_copy/`
- **Keymaps:** `rq`

## Spotlight Node

`<leader>sp` turns the basename of the node under the cursor into a
`spotlight.nvim` token, so open logs and buffers that mention the file light up.
Soft dependency (a warning when spotlight.nvim is absent), off by default.

- **Module:** `lua/filetree/features/search/spotlight_node/`
- **Keymaps:** `<leader>sp`

## Copy File List

Copies a recursive listing of files and/or directories under the node —
`[f`/`]f` for files, `[F`/`]F` for directories — useful for pasting a
directory's contents into an issue, a prompt, or a script.

Mark-aware: with nodes marked (see [Marks](INTEGRATIONS.md#marks)), the
listing is collected from every marked node (deduplicated) instead of just
the one under the cursor — mark three directories, then `]f` copies the
combined relative file listing across all three.

- **Module:** `lua/filetree/features/paths/copy_file_list/`
- **Keymaps:** `[f`, `]f`, `[F`, `]F`

## Markdown Links

Copies the current node, a recursive listing, or every marked node as
Markdown links (`ML`/`MR`/`MM`) — for dropping references into a README
or a design doc directly from the tree, no manual path-to-link
formatting. `ML` is mark-aware: with nodes marked it links all of them
(one per line), same as `MM`; `MM` stays as an explicit marks-only keymap.

- **Module:** `lua/filetree/features/paths/markdown_links/`
- **Keymaps:** `ML`, `MR`, `MM`, `MI`

`MI` **inserts** instead of copying: marked nodes if any, else the current
node, go as `[name](path)` into the window you came from (one link inline, several
on lines of their own below the cursor line). The cursor lands in the first
link — in its empty title, or in the path when the title is filled — in insert
mode (`cursor = { enable, startinsert, path_cursor }`, see
`lib.nvim.markdown.link_cursor`). The path is spelled by `insert_path`:
`"buffer"` (default; relative to the *target* buffer, `./x` / `../x`), `"cwd"`,
`"absolute"` (the real path), or `"env"` (`$REPOS_DIR/…`, `$NVIM_CONFIG_DIR/…`, else `"buffer"`;
`env_roots` adds variables).
