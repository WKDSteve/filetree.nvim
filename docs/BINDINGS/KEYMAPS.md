# filetree.nvim — Keymaps

All keymaps are buffer-local (tree window) unless marked **global**.
A `?` suffix means the field is optional; omit or set to `false` to disable.

Every one of them is declared as a named action through
[`lib.nvim.bindings.keymap`](https://github.com/WKDSteve/lib.nvim), which is
what lets a config field also hold a **list** of keys
(`keymap_abs = { "Y", "gy" }`) and what makes the `?` cheatsheet list the keys
you actually have rather than the ones this plugin ships with. Read them back
at runtime with `:lua vim.print(require("filetree.bindings").live())` —
`require("filetree.bindings").keymaps` is the shipped defaults instead.

> **neo-tree `?` cheatsheet:** filetree keymaps are shown there automatically
> (filetree injects them into neo-tree's mapping registry on `setup()`).
> For **nvim-tree** (`g?`) and other adapters the keymaps are set via the
> central tree-attach dispatcher, which is outside their help registry,
> so their built-in help will not list them (the keymaps still work — check with
> `:nmap` in the tree buffer). See
> [`?` cheatsheet integration](#the-cheatsheet) for details.

---

## Tree-buffer keymaps

| Key | Feature | Config field | Action |
|-----|---------|-------------|--------|
| `m` | marks | `keymap` | Toggle mark on current node |
| `]m` | marks | `keymap_all` | Mark all nodes in current directory |
| `[m` | marks | `keymap_unmark_all` | Unmark all nodes in current directory |
| `<leader>mc` | marks | `keymap_clear` | Clear all marks |
| `<leader>ms` | marks | `keymap_show` | Show floating list of marked nodes |
| `gm` | marks | `keymap_goto` | Go to the Nth marked node in render order (`Ngm`; a too-large count clamps to the last) |
| `]M` | marks | `keymap_next` | Next marked node, wrapping |
| `[M` | marks | `keymap_prev` | Previous marked node, wrapping |
| `"` | source_switcher | `keymap_next` | Next neo-tree source, keeping the tree's position. **neo-tree only** |
| `!` | source_switcher | `keymap_prev` | Previous neo-tree source, keeping the tree's position. **neo-tree only** |
| — | source_switcher | `keymap_pick` | **global**, unset by default: pick a neo-tree source from a list |
| `<M-c>` | tree_toggle | `keymap_current` | **global**, opt-in feature: toggle the tree in the current window, revealing the file |
| `<M-f>` | tree_toggle | `keymap_float` | **global**, opt-in feature: toggle the tree as a float |
| `<M-l>` | tree_toggle | `keymap_left` | **global**, opt-in feature: toggle the tree on the left |
| `<M-r>` | tree_toggle | `keymap_right` | **global**, opt-in feature: toggle the tree on the right |
| — | tree_toggle | `collapse_on_toggle` | not a key: with `true`, opening the tree through these keys first collapses every folder except the current file's chain |
| `<leader>;` | quickpick | `keymap` | **global**, opt-in feature: number the tree's visible entries, type a number to open it (`N<leader>;` roots the tree N folders above the file) |
| `<leader>:` | quickpick | `keymap_cwd` | **global**, opt-in feature: the same, with the tree rooted at the cwd |
| `W` | collapse_all | `keymap` | Collapse every folder back to the root (cursor on its top-level entry); not applicable on netrw/oil/mini.files; only bound where `W` is still free in the tree buffer |
| `-` | tree_traverse | `keymap_up` | Navigate to parent directory (×count) |
| `+` | tree_traverse | `keymap_down` | Set current dir as tree root (×count) |
| `]s` | tree_traverse | `keymap_next_sibling` | Next sibling at the same depth, skipping expanded folders' children (×count; stops at the end unless `sibling_wrap`) |
| `[s` | tree_traverse | `keymap_prev_sibling` | Previous sibling at the same depth (×count; stops at the start unless `sibling_wrap`) |
| `B` | reveal_alt | `keymap` | Reveal the alternate buffer (`#`) in the tree |
| `L` | cwd_mode | `keymap_cycle` | Cycle the cwd policy (follow → project → lock) |
| `gp` | cwd_mode | `keymap_lock_here` | Lock the cwd to the node under the cursor |
| `<C-n>` | buffer_cycle | `keymap_next` | Next buffer in the adjacent editor window (tree keeps focus) |
| `<C-p>` | buffer_cycle | `keymap_prev` | Previous buffer in the adjacent editor window (tree keeps focus) |
| `[a` | path_copy | `keymap_abs` | Copy the real absolute path to clipboard — the `$REPOS_DIR/…` form is `[e` (or all marked) |
| `]a` | path_copy | `keymap_dirname` | Copy absolute parent directory to clipboard (or all marked) |
| `[R` | path_copy | `keymap_project_root` | Copy absolute project root path to clipboard (or all marked) |
| `]R` | path_copy | `keymap_project_rel` | Copy path relative to project root, cwd-independent (or all marked) |
| `]b` | path_copy | `keymap_buffer_rel` | Copy path relative to the buffer open in the editor, `./x`/`../x` (or all marked) |
| `[e` | path_copy | `keymap_env_root` | Copy absolute path with an env-var root folded in, `$REPOS_DIR/…` or `$NVIM_CONFIG_DIR/…` (or all marked) |
| `d` | trash | `keymap` | Trash current node (or all marked). **`filesystem` source only** |
| `U` | trash | `keymap_undo` | Undo last trash operation. **`filesystem` source only** |
| `<leader>th` | trash | `keymap_history` | Show trash history. **`filesystem` source only** |
| `gs` | live_search | `keymap` | Open live search in tree |
| `I` | node_info | `keymap` | Show node info float |
| `rq` | lua_require_copy | `keymap` | Copy file as `require("…")` string |
| `<leader>sp` | spotlight_node | `keymap` | Spotlight the node's basename (spotlight.nvim) |
| `[f` | copy_file_list | `keymap_files_abs` | Copy recursive file list, absolute (or all marked) |
| `]f` | copy_file_list | `keymap_files_rel` | Copy recursive file list, relative (or all marked) |
| `[F` | copy_file_list | `keymap_dirs_abs` | Copy recursive dir list, absolute (or all marked) |
| `]F` | copy_file_list | `keymap_dirs_rel` | Copy recursive dir list, relative (or all marked) |
| `ML` | markdown_links | `keymap` | Copy `[name](path)` markdown link for the current node (or all marked) |
| `MR` | markdown_links | `keymap_recursive` | Copy markdown links recursively |
| `MM` | markdown_links | `keymap_from_marked` | Copy markdown links from all marked nodes |
| `MI` | markdown_links | `keymap_insert` | Insert markdown link(s) (marked nodes, else current) into the window you came from; cursor goes into the first link, insert mode |
| `a` | smart_create | `keymap` | Smart create file or directory |
| `/` | filter | `keymap` | Enter tree filter mode |
| `<C-c>` | filter | `keymap_clear` | Clear an applied filter directly |
| `<Tab>` | preview | `keymap` | Text/dir: toggle floating preview; image: open via backend; PDF: pdfport/system |
| `<CR>` | preview | `keymap_open` | Image: images.nvim float (`image.float`, `<S-Up>`/`<S-Down>` resize; zoom, pan, select, `gs`/`gy` and `?` in it are images.nvim's [zen window keys](https://github.com/WKDSteve/images.nvim/blob/main/docs/BINDINGS.md#zen-window), off with `image.float.viewport = false`), else the backend; PDF: open via backend; `system_exts` files (`.msg`, `.eml`, `.oft`): OS default app; other nodes: adapter's default `<CR>` |
| `<C-b>` | preview | `keymap_scroll_up` | Scroll float preview up 1 line (×count). Float mode only. |
| `<C-f>` | preview | `keymap_scroll_down` | Scroll float preview down 1 line (×count). Float mode only. |
| `<PageUp>` | preview | `keymap_scroll_up10` | Scroll float preview up 10 lines (×count); in buffer-mode preview, pages the previewed file instead via native `<PageUp>` |
| `<PageDown>` | preview | `keymap_scroll_down10` | Same as above, downward |
| `D` | diff | `keymap` | Diff current node |
| `<leader>sm` | open_with | `keymap` | Open with system default |
| `gy` | file_clipboard | `keymap` | Copy the FILES (all marked, else the current node) to the OS clipboard, so Ctrl+V pastes them into a chat, mail or file manager |
| `r` | smart_rename | `keymap` | Rename with LSP reference update |
| `M` | move | `keymap` | Move current node (or all marked) to a prompted destination |
| `A` | create_from_template | `keymap` | Create from template — pick a template first, then a filename pre-filled with its extension |
| `<RightMouse>` | context_menu | `keymap` | Open a right-click context menu via ui.contextmenu (nvzone/menu, or its own kit renderer) |
| `<leader>rb` | rename_batch | `keymap` | Open batch rename buffer |
| `f` | find_files | `keymap_tree` | Find files (telescope/fzf-lua/builtin) |
| `tf` | find_files | `keymap_pickers` | Find files, forcing pickers.nvim specifically |
| `gr` | grep_in_dir | `keymap` | Grep in node directory |
| `tg` | grep_in_dir | `keymap_pickers` | Grep, forcing pickers.nvim specifically |
| `c` | copy_move | `keymaps.copy` | Stage node for copy |
| `x` | copy_move | `keymaps.cut` | Stage node for cut |
| `p` | copy_move | `keymaps.paste` | Paste staged nodes |
| `P` | copy_move | `keymaps.show` | Show copy/cut clipboard |
| `X` | copy_move | `keymaps.clear` | Clear copy/cut clipboard |
| `sg` | open_variants | `keymap_vsplit` | Open current node in a vertical split |
| `sv` | open_variants | `keymap_split` | Open current node in a horizontal split |
| `st` | open_variants | `keymap_tabnew` | Open current node in a new tab |
| `gb` | open_variants | `keymap_badd` | Add current node to buffer list (no focus switch) |
| `<S-CR>` | open_variants | `keymap_badd_alt` | On a directory: collapse it. Otherwise same as `gb` |
| `O` | open_replace | `keymap` | Open current node over the editor window; the buffer that was there stays listed |
| `<M-CR>` | open_replace | `keymap_swap` | Open current node in place of the focused buffer: closes it and takes its bufferline slot |
| `<C-CR>` | open_replace | `keymap_swap_alt` | Same as `<M-CR>`, for terminals that deliver `<C-CR>` distinctly from `<CR>` |
| `<C-s>` | buffer_save | `keymap_adjacent` | Force-save the adjacent editor buffer |
| `<M-s>` | buffer_save | `keymap_node` | Force-save buffer matching node under cursor |
| `w` | window_size_cycler | `keymap` | Cycle tree width through presets (normal → large → small → …). With a count N (`3w`), jumps directly to preset N instead of stepping. |
| `<leader>fm` | open_in_fm | `keymap` | Open node directory in system file manager |
| `i` | shell_run | `keymap` | Prompt for a shell command, run in node directory |
| `go` | pdf_open | `keymap_open` | Open the PDF under the cursor with `default_mode` (pdfport / system reader) |
| `gP` | pdf_create | `keymap` | Create PDF(s) from the current node/marked nodes/folder via pdfport.nvim (confirms first) |
| `gz` | compress | `keymap` | Compress the current node / marked nodes to `.zip` (several nodes: one zip each or one for all) |

### Visual-mode keymaps

The only two this plugin binds in Visual mode. A line range over a rendered
tree is exactly a set of nodes, so marking a run of files is a motion rather
than one keypress per line.

| Key | Feature | Config field | Action |
|-----|---------|-------------|--------|
| `m` | marks | `keymap` | Mark every node in the selection |
| `[m` | marks | `keymap_unmark_all` | Unmark every node in the selection |

### Quickpick mode keys

Only while the opt-in [quickpick](../FEATURES/NAVIGATION.md#quickpick-opt-in)
mode runs (started by `<leader>;` / `<leader>:` above): temporary buffer-local
keys on the tree buffer, taken over for the duration and restored exactly
afterwards. They live in `features.quickpick.keys`; each is a key, a list of
keys or `false`. With `silence_nvim_mappings` (default) every other key in the
tree buffer does nothing until the mode ends.

| Key | Config field | Action |
|-----|--------------|--------|
| `0`-`9` | — | Type the label; the last digit (`width`, default 2) opens the entry, or expands/collapses it when it is a folder |
| `e` | `keys.edit` | Open mode: edit (the default) |
| `s` | `keys.split` | Open mode: horizontal split (only before the first digit) |
| `v` | `keys.vsplit` | Open mode: vertical split (only before the first digit) |
| `t` | `keys.tab` | Open mode: new tab (only before the first digit) |
| `c` | `keys.cycle` | Cycle the numbered entries: all → files → folders |
| `<BS>`, `<C-h>` | `keys.backspace` | Drop the last typed digit |
| `<Esc>`, `<C-c>` | `keys.cancel` | Leave the mode |
| `j` / `k` | `keys.scroll_down` / `keys.scroll_up` | One line down / up in the tree |
| `<C-d>` / `<C-u>` | `keys.page_down` / `keys.page_up` | Half a page down / up |

---

## Known conflicts

| Keys | Features | Notes |
|------|---------|-------|
| `/` | `filter` + neotree fuzzy finder | neotree uses `/` for its own search. Remap `filter.keymap` if using neotree. |
| `i` | `shell_run` + neotree built-in `i` (toggle node info) | filetree's `node_info` provides a better `I`; noop neotree's `i` via `adapter_keymaps`. |
| `m` | `marks` + neotree built-in `m` (move) | filetree binds `m` to marking, shadowing neo-tree's own move. filetree's `M` does the same job and updates references while it's at it. |

### Keys deliberately not used

`<C-m>`, `<C-i>` and `<C-[>` are the same bytes as `<CR>`, `<Tab>` and `<Esc>`
(0x0D, 0x09, 0x1B). Neovim keeps both spellings as separate mappings, but a
terminal only sends the *distinct* sequence for the Ctrl form when an extended
encoding is active ("CSI u"/modifyOtherKeys, or the Windows console) — without
one, the byte always resolves to `<CR>`/`<Tab>`/`<Esc>`, and it does so even
when nothing maps those at all. A mapping on the Ctrl spelling is therefore
not "shadowed", it is simply dead for most users.

`marks.keymap_clear` sat on `<C-m>` until 2026-08-30 for exactly that reason;
it defaults to `<leader>mc` now. `TESTS/smoke.lua` check 6 folds the three
pairs together and fails the build if two default-on tree keymaps land on one
physical key, so this cannot come back unnoticed.

---

## Overriding adapter (neotree) native keymaps

Use `adapter_keymaps` to noop or remap any key that the adapter (neotree) sets
natively — filetree.nvim applies these overrides after the adapter's own
buffer-local keymaps are in place.

```lua
require("filetree").setup({
  -- noop neotree's built-in `i` (toggle node info); our `node_info` uses `I`
  adapter_keymaps = {
    ["i"] = false,   -- false → <Nop>
  },
  features = {
    shell_run  = { enabled = true, keymap = "i" },
    node_info  = { enabled = true, keymap = "I" },
  },
})
```

`false` maps the key to `<Nop>`.  A string value remaps to that target key.

---

## Remapping keys

Use the top-level `keymaps` table to rename or disable any key globally across all features:

```lua
require("filetree").setup({
  keymaps = {
    -- rename
    ["gs"]   = "<leader>gs",   -- live_search: gs → <leader>gs
    -- disable
    ["<leader>mc"] = false,     -- marks.keymap_clear: disabled
  },
  features = { ... },
})
```

The remap runs after all feature configs are merged, so it overrides both defaults
and any per-feature overrides the user has set.

To remap a single feature only, set it directly in the feature config:

```lua
require("filetree").setup({
  features = {
    live_search = { enabled = true, keymap = "<leader>gs" },
  },
})
```

---

## The `?` cheatsheet, per-source keys, conflicts

### The cheatsheet

`?` opens filetree's own cheatsheet on every adapter, neo-tree included (it
replaces neo-tree's native `?`). It reads what is **actually bound** -- lib.nvim's
keymap registry for filetree's own keys, the buffer's keymaps for everything else --
so it cannot disagree with the keys the way a hand-kept list can. `<Tab>` /
`<S-Tab>` (or `1`..`4`) turn the pages:

1. **filetree** -- filetree's own keys by category, plus the global ones
2. **other keys** -- every other buffer-local key: the adapter's native ones and
   those other plugins attach (pickers.nvim, pdfport, ...)
3. **commands** -- the `:Filetree` sub-commands
4. **conflicts** -- only when two actions claim one key (see below)

neo-tree's native help built its list from `window.mappings`, and filetree used to
write its keys into that table so they would appear there. That injection is gone:
the list was hand-kept and lagged the features (a rebound `D` was shown as
neo-tree's own action), and because it ran after neo-tree's setup it overruled a
user's `window.mappings` for a key they had switched off in one source.
`require("filetree").attach(opts, config)` still exists so an existing config keeps
working, and returns `opts` untouched.

### Per-source keymaps

neo-tree draws its filesystem, buffer list, git status, symbol outline and
diagnostics list through one window and one `neo-tree` filetype, so "bind this
on tree buffers" means all five. A feature whose actions presuppose a
filesystem node says so in
[`lua/filetree/sources.lua`](../../lua/filetree/sources.lua), and is then not bound
anywhere else -- so the cheatsheet, which reads what is bound, does not list it
there either. Today that is `trash` (`d`, `U`, `<leader>th`), restricted to
`filesystem`: there is nothing to trash in a symbol outline, and `<leader>th` in
particular was shadowing whatever global binding a config had on that key while
offering nothing in exchange. An adapter without sources (nvim-tree) is unaffected:
no source means no restriction.

### Keys claimed twice

filetree's own features never share a default key, and `TESTS/keys.lua` checks that
against the keys actually bound, opt-in features included. You can still put two
actions on one key in your config. Vim does not complain: the second `:map` wins, and
which one is second depends on attach order, so the other action silently loses its
key.

`:Filetree keys` (or `<CR>` on the cheatsheet's **conflicts** page) lists every such
key, marks the action that owns it, and recommends free alternatives -- keys that are
not mapped on the buffer or globally, not claimed by another action, and not a prefix
of (or prefixed by) one, ranked by keeping the original's kind of key (a `<C-x>` stays a
ctrl key, a `gx` a g-key) and by how well the letters fit what the action does. Pick
the action to move and the new key: it moves on every open tree now and on later ones
for the session, and the `setup()` fragment that makes it permanent is copied to the
clipboard:

```lua
require("filetree").setup({ features = { pdf_open = { keymap_open = "go" } } })
```

### Notes

- A key filetree binds over one of neo-tree's own (`/`, `i`, `m`, ...) is a
  deliberate shadowing, listed under *Known conflicts* above -- not a claim by two
  filetree actions, so it is not on the conflicts page.
- Keys resolve from your feature config; a field set to `false` is skipped, and
  omitted fields fall back to the feature's default key.
