# filetree-helper (prototype, stage E3h)

A prototype of the helper process the own tree of filetree.nvim (`adapter = "native"`) may use as a
third tier behind its file-system layer. It is **not wired into the plugin**: nothing in `lua/` starts
it. It exists to measure whether a helper is worth a second code base (concept section 10.6); the
numbers and the decision are in the task `filetree.nvim/native-fs-helper-measure`.

## What it does

One child process per Neovim, msgpack-RPC over stdin/stdout:

| Work | How |
| --- | --- |
| deep listing (search, expand all) | a parallel walk with the ignore rules of `rg` (`ignore` crate); lists what `fd` lists for `native/fs/deep.lua` |
| recursive sizes | the same walk, one `stat` per file |
| recursive watch | `notify`: one recursive watch per root on every system (on Linux new folders are added as they appear) |
| git status | gitoxide in the process; after the first answer only the delta |

Every request carries a generation number, every answer carries the generation of its request. The
protocol is described at the top of `src/main.rs`.

What it never does: open a socket, start a process, write to the file system, read file contents other
than ignore files and what git keeps below `.git`. It ends when its stdin closes (that is, with Neovim).

## Build and measure

```bash
cargo build --release --manifest-path helper/Cargo.toml
```

```bash
nvim --clean --headless -u NONE -l helper/bench/bench.lua helper/target/release/filetree-helper 5 <root> [<root> ...]
```

```bash
nvim --clean --headless -u NONE -l helper/bench/watch.lua helper/target/release/filetree-helper
```

`bench.lua` times every tier from the call until the last answer is on the editor's main loop; it only
reads. `watch.lua` checks whether a change in a folder the tree never opened is reported.

Without the protocol: `filetree-helper walk <root> [--sizes] [--print]`, `filetree-helper status <root> [--print]`.
