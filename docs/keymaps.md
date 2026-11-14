# Keymaps

All tree-buffer keymaps, defaults, and how to remap or disable them:
→ [docs/BINDINGS/KEYMAPS.md](BINDINGS/KEYMAPS.md)

**Machine-readable catalog:** [docs/BINDINGS.lua](BINDINGS.lua) returns every
keymap, `:Filetree` sub-command and autocmd as data
(`require("filetree.bindings").catalog()`), sourced from `lua/filetree/bindings/`
and the command dispatcher so it never drifts.

**which-key:** if [which-key.nvim](https://github.com/folke/which-key.nvim) is
installed, `setup()` registers leader-group labels automatically (v2 and v3 APIs);
individual tree keys carry a `desc` so which-key shows them out of the box.

> **`?` cheatsheet:** filetree's own paged cheatsheet (filetree keys, other keys,
> commands, and -- when two actions claim one key -- conflicts; `<Tab>` turns the
> page) is bound on every adapter, neo-tree included, and reads the keys that are
> actually bound. `:Filetree keys` moves a doubly-claimed key. See
> [the cheatsheet section](BINDINGS/KEYMAPS.md#the--cheatsheet-per-source-keys-conflicts).

## Remap filetree feature keys:

```lua
require("filetree").setup({
  keymaps = {
    ["gs"]    = "<leader>gs",   -- rename live_search key
    ["<leader>mc"] = false,     -- disable marks clear
    ["<Tab>"] = "<leader>pv",   -- move preview to <leader>pv
  },
})
```

## The own tree's keys (`adapter = "native"`)

The own tree brings only the keys that make it a tree; everything else in the
table of [`BINDINGS/KEYMAPS.md`](BINDINGS/KEYMAPS.md) is a feature key and works
on it as on any backend.

| Key | Action |
| --- | --- |
| `<CR>`, `o`, `<2-LeftMouse>` | open the file in an editor window, or open/close the folder |
| `l` | open the folder or file; on an open folder, go to its first entry |
| `h` | close the folder, or go to the parent folder |
| `C` | close the folder the entry lies in |
| `z` | close every folder |
| `R` | read the folders again |
| `H` | show or hide the names of the ignore list |
| `-` | show the parent folder as the root (`tree_traverse`'s `-` does the same when it is on) |
| `sw` | open the file in a window you pick (`ui.windowpicker`) |
| `q` | close the tree |

**One table for every key.** On the own tree a key is an entry of its action
table: the tree's own keys, the features' keys, the actions other plugins
register and those of the view's source. When several claim one key, the first
that applies to the node under the cursor runs (an action of the source first,
then the higher `priority`, then a feature before another plugin's action before
the tree's own). When none applies, one line says why, e.g. `gC: needs a file`.
Marked nodes (`m`) are the selection an action gets. `?` opens on the page
**here**: exactly the actions that apply to the node under the cursor, with the
key that reaches each one there; the context menu lists the same.
`:Filetree action <name>` runs one by name (`<Tab>` lists them).

Switch one off or point it elsewhere with `adapter_keymaps`, as for any backend:
`adapter_keymaps = { H = false }`. A key mapped like that, or by another plugin,
stays as it is: the table does not take it back.

## Noop an adapter (neotree) built-in key:

```lua
require("filetree").setup({
  -- disable neotree's native `i` (toggle node info) so shell_run can use it
  adapter_keymaps = { ["i"] = false },
  features = {
    shell_run = { enabled = true, keymap = "i" },
  },
})
```
