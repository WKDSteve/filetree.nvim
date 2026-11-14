# filetree.nvim — User Commands

filetree.nvim registers a single unified command (default `:Filetree`),
built via [`lib.nvim.bindings.usercmd.composer`](https://github.com/WKDSteve/lib.nvim),
with sub-command dispatch and tab-completion at every level. Out of the box,
the short alias `:Ft` also works — `:Ft marks show` is identical to
`:Filetree marks show`.

---

## Command name

The command name and its aliases are configurable:

```lua
-- Simple rename (replaces both default names, :Ft alias dropped)
require("filetree").setup({ command = "Foo" })

-- Rename + explicit aliases
require("filetree").setup({
  command = { name = "Ft", aliases = { "Filetree" } },
})

-- Keep :Filetree, drop the default :Ft alias
require("filetree").setup({
  command = { name = "Filetree", aliases = {} },
})
```

Default: `Filetree`, with `Ft` registered automatically as an alias.

---

## Sub-commands

### Marks
| Command | Action |
|---------|--------|
| `:Filetree marks clear` | Clear all marks |
| `:Filetree marks show` | Show floating list |
| `:Filetree marks all` | Mark all visible nodes |

### Source (neo-tree)
| Command | Action |
|---------|--------|
| `:Filetree source` | Pick a neo-tree source from a floating list |
| `:Filetree source <name>` | Switch to that source, keeping the tree's position |
| `:Filetree source next` / `prev` | Cycle, wrapping |
| `:Filetree source debug` | Print the source list, where it came from, and which sources can load |

### Toggle (opt-in feature)
| Command | Action |
|---------|--------|
| `:Filetree toggle [left\|right\|float\|current]` | Toggle the tree at that position (default `left`), revealing the current file |
| `:Filetree collapse` | Collapse every folder back to the root (`collapse_all`) |

### Quickpick (opt-in feature)
| Command | Action |
|---------|--------|
| `:Filetree quickpick [levels]` | Number the tree's visible entries and open one by typing its number; with the tree closed, reveal the current file first, rooted `levels` folders above it |
| `:Filetree quickpick cwd` | The same, with the tree rooted at the cwd |
| `:Filetree quickpick cancel` | Leave the mode |

### Diff
| Command | Action |
|---------|--------|
| `:Filetree diff marked` | Diff marked nodes |
| `:Filetree diff close` | Close diff windows |

### Git
| Command | Action |
|---------|--------|
| `:Filetree git refresh` | Refresh git status |

### Find / Grep
| Command | Action |
|---------|--------|
| `:Filetree find [dir]` | Find files (telescope/fzf-lua/builtin) |
| `:Filetree grep [pattern]` | Grep in the directory of the node under the cursor (else the project root): pickers.nvim, telescope or fzf-lua when installed (live), else ripgrep/grep into the quickfix list |

### Filter
| Command | Action |
|---------|--------|
| `:Filetree filter` | Open filter input |
| `:Filetree filter <query>` | Apply query directly |
| `:Filetree filter clear` | Clear current filter |

### Live search
| Command | Action |
|---------|--------|
| `:Filetree search` | Open live search |
| `:Filetree search clear` | Clear search highlighting |

### Session
| Command | Action |
|---------|--------|
| `:Filetree session save` | Save current session |
| `:Filetree session restore` | Restore session |
| `:Filetree session clear` | Clear saved session |

### Copy / Move
| Command | Action |
|---------|--------|
| `:Filetree clipboard show` | Show copy/cut clipboard |
| `:Filetree clipboard clear` | Clear clipboard |
| `:Filetree clipboard copy` | Stage current for copy |
| `:Filetree clipboard cut` | Stage current for cut |
| `:Filetree clipboard paste` | Paste staged nodes |

### Path copy
| Command | Action |
|---------|--------|
| `:Filetree copy absolute` | Copy the real absolute path (`$REPOS_DIR/…` form: `env_rooted`) |
| `:Filetree copy absolute_raw` | Copy the real absolute path (older name of `absolute`) |
| `:Filetree copy relative` | Copy relative path |
| `:Filetree copy name` | Copy filename |
| `:Filetree copy dirname` | Copy absolute parent directory |
| `:Filetree copy uri` | Copy as `file://` URI |
| `:Filetree copy line` | Copy path with line number |
| `:Filetree copy stem` | Copy stem (no extension) |
| `:Filetree copy project_root` | Copy the detected project root (cwd-independent) |
| `:Filetree copy project_relative` | Copy path relative to the project root |
| `:Filetree copy buffer_relative` | Copy path relative to the buffer open in the editor (`./x`, `../x`) |
| `:Filetree copy env_rooted` | Copy absolute path with an env-var root folded in (`$REPOS_DIR/…`) |
| `:Filetree copy pick` | Open format picker |

### Copy file list
| Command | Action |
|---------|--------|
| `:Filetree filelist files abs` | Copy recursive file list (absolute) |
| `:Filetree filelist files rel` | Copy recursive file list (relative) |
| `:Filetree filelist dirs abs` | Copy recursive dir list (absolute) |
| `:Filetree filelist dirs rel` | Copy recursive dir list (relative) |

### Files to the system clipboard
| Command | Action |
|---------|--------|
| `:Filetree clipfiles` | Copy the marked nodes (else the current one) to the OS clipboard as files, ready for Ctrl+V in another app |

### Compress to .zip
| Command | Action |
|---------|--------|
| `:Filetree compress` | Compress the marked nodes (else the current one) to `.zip`, like `gz` |
| `:Filetree compress each` | Every marked node to its own `<name>.zip`, without asking |
| `:Filetree compress together` | All marked nodes into one `.zip` (name asked) |

### Lua require copy
| Command | Action |
|---------|--------|
| `:Filetree require` | Copy as `require("…")` string |
| `:Filetree require relative` | Copy as relative require |

### Node info
| Command | Action |
|---------|--------|
| `:Filetree info` | Show node info float |
| `:Filetree info close` | Close info float |

### Smart create
| Command | Action |
|---------|--------|
| `:Filetree create` | Smart create file or directory |

### Link create
| Command | Action |
|---------|--------|
| `:Filetree symlink` | Prompt for a target path, create a symlink/hardlink to it in the current tree directory |
| `:Filetree symlink mark [path]` | Mark a link source (node/buffer/explicit path), no prompt |
| `:Filetree symlink paste` | Paste the marked source as a link, kind picked automatically |
| `:Filetree symlink check [path]` | Report whether the node/path is a symlink, and whether it's broken |
| `:Filetree symlink checkall` | Same, over every marked node (else the node under the cursor) |
| `:Filetree symlink repair [path]` | If broken, search the filesystem for a new target (via gopath.nvim, optional) and offer a picker, or delete/keep it |
| `:Filetree symlink repairall` | Same, over every broken symlink among the marked nodes (else the node under the cursor) |
| `:Filetree symlink delete` | Remove marked symlinks (else the node under the cursor) via trash — never a non-symlink, never the target |

### Rename
| Command | Action |
|---------|--------|
| `:Filetree rename` | Open batch rename buffer |
| `:Filetree smartrename` | Rename with LSP reference update |
| `:Filetree renamebatch dry-run` | Toggle dry-run for the batch rename at runtime (it was config-only before). Named `renamebatch`, not `rename`: `rename` is already a leaf command above, and a table under the same key would be silently overwritten by it |

### Dry-run toggles for the bulk operations
| Command | Action |
|---------|--------|
| `:Filetree copymove dry-run` | Toggle dry-run for copy/move at runtime — `trash` and `safety` always had one, these two destructive bulk operations were config-only |

### Move
| Command | Action |
|---------|--------|
| `:Filetree move` | Prompt for a destination and move the current node (or all marked) |
| `:Filetree move <dest>` | Move straight to `<dest>`, no prompt |

### References
| Command | Action |
|---------|--------|
| `:Filetree refs undo` | Revert the last reference rewrite |
| `:Filetree refs status` | Show engine state: modes, providers, ripgrep, pending undo |
| `:Filetree references [path]` | List where the file under the cursor (or `path`) is referenced; `<CR>` jumps to the site. `--picker` / `--popup` override `refs.report.view`. Same as `:Filetree refs list`. Given a directory it runs `refs unused` |
| `:Filetree refs unused [dir]` | List the files under `dir` (default: the cursor node, else the asset roots) that nothing references and trash a selection of them. Only asset-like files by default; `--all` lifts the filter |

### Tree traverse
| Command | Action |
|---------|--------|
| `:Filetree traverse up` | Navigate to parent directory |
| `:Filetree traverse down` | Set current dir as root |
| `:Filetree traverse goto <dir>` | Change tree root to a given directory |

### Trash
| Command | Action |
|---------|--------|
| `:Filetree trash undo` | Undo last trash operation |
| `:Filetree trash history` | Show trash history |
| `:Filetree trash dry-run` | Toggle dry-run mode |

### Open variants
| Command | Action |
|---------|--------|
| `:Filetree openas vsplit` | Open current node in a vertical split |
| `:Filetree openas split` | Open current node in a horizontal split |
| `:Filetree openas tabnew` | Open current node in a new tab |
| `:Filetree openas badd` | Add current node to buffer list (no focus switch) |

### Markdown links
| Command | Action |
|---------|--------|
| `:Filetree mdlink` | Copy a Markdown link for each marked node, else for the current one |
| `:Filetree mdlink recursive` | Markdown links for every file under current node |
| `:Filetree mdlink marked` | Markdown links for all marked nodes |
| `:Filetree mdlink insert` | Insert markdown link(s) (marked nodes, else current) into the editor window instead of the clipboard |

### Misc
| Command | Action |
|---------|--------|
| `:Filetree template` | Create file from template — pick a template first, then a filename pre-filled with its extension |
| `:Filetree open <dir-or-file>` | Open the tree focused on a directory or file |
| `:Filetree open system` | Open with system default |
| `:Filetree open pick` | Open with app picker |
| `:Filetree open app <name>` | Open with named app |
| `:Filetree reveal` | Reveal current buffer in tree |
| `:Filetree reveal pause [ms]` | Pause auto-reveal for `ms` milliseconds (default 2000); `reveal resume` ends it early |
| `:Filetree reveal resume` | Resume auto-reveal |
| `:Filetree resize [width]` | Set tree window width |
| `:Filetree cwd mode <name>` | Set the cwd policy: `follow`, `project`, `nearest`, `lock`, `manual`, `tree_leads` |
| `:Filetree cwd scope <name>` | Directory scope of the policy: `global`, `tab` or `win` |
| `:Filetree cwd lock [dir]` | Pin the cwd to `dir` (default: the current one) |
| `:Filetree cwd here` | Pin the cwd to the node under the cursor |
| `:Filetree cwd unlock` | Leave lock mode, back to the previous one |
| `:Filetree cwd toggle` | Cycle through the configured modes |
| `:Filetree cwd status` | Show the active mode, its scope, root and the cwd |
| `:Filetree cwd forget` | Drop the policy saved for this project (`persist`) |
| `:Filetree size refresh` | Refresh size annotations |
| `:Filetree breadcrumbs update` | Update breadcrumb display |
| `:Filetree safety list` | List safety backups |
| `:Filetree safety dry-run` | Toggle safety dry-run |
| `:Filetree watcher enter [ms]` | Enter watcher quarantine |
| `:Filetree watcher exit` | Exit watcher quarantine |
| `:Filetree action <name> [key=value ...]` | Own tree only: run an action of its table by name on the selection or the node under the cursor; says in one line why when it does not apply (`<Tab>` lists the actions) |
| `:Filetree keys` | List keys claimed by more than one filetree action (the active one marked), recommend free alternatives, and move the one you pick for this session; copies the `setup()` fragment that makes it permanent |
| `:Filetree wholocks [path] [--json]` | Diagnose who holds a file open (probe, Restart Manager holders, neo-tree watchers on its folder) |
| `:Filetree handles` | List tracked neo-tree watcher handles (`handle_guard`); flags any pointing at a path that no longer exists |
| `:Filetree hooks events` | List registered hook events |
| `:Filetree hooks clear [event]` | Clear hooks |
| `:Filetree health` | Run `:checkhealth filetree` |
