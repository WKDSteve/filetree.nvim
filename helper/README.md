# filetree-helper

The helper process of the own tree of filetree.nvim (`adapter = "native"`, option
`native.fs.helper`): a small read-only program the tree hands three kinds of work to, as a third tier
behind its file-system layer. Without it the tree does all of this itself. Users: see
[the helper process](../docs/FEATURES/BACKENDS.md#the-helper-process) and `:help filetree-native-helper`.
Started as a prototype to measure whether it is worth a second code base (concept section 10.6); the
numbers and the decision are below and in the task `filetree.nvim/native-fs-helper-measure`.

## What it does

One child process per Neovim, msgpack-RPC over stdin/stdout:

| Work | How | Used by |
| --- | --- | --- |
| deep listing (search) | a parallel walk with the ignore rules of `rg` (`ignore` crate); lists what `fd` lists for `native/fs/deep.lua` | `native/fs/deep.lua` |
| size of a folder | a parallel walk without ignore rules, everything counted (as `du`) | `features/ui/size_info` |
| recursive watch | `notify`: one recursive watch per root (on Linux new folders are added as they appear) | `native/fs/watch.lua`, on systems without recursive libuv handles (Linux) |
| git status | gitoxide in the process; after the first answer only the delta | nothing: measured, `git` is as fast |

Every request carries a generation number, every answer carries the generation of its request. The
protocol (version 1) is described at the top of `src/main.rs`; the Lua side is
`lua/filetree/native/fs/helper.lua`.

What it never does: open a socket, start a process, write to the file system, read file contents other
than ignore files and what git keeps below `.git`. It ends when its stdin closes (that is, with Neovim).

## Build, test, measure

```bash
cargo build --release --manifest-path helper/Cargo.toml
```

```bash
cargo test --release --manifest-path helper/Cargo.toml
```

`require("filetree.native.fs.helper").build()` does the build and copies the program to `helper/bin/`,
where `"auto"` finds it; without cargo it downloads the release program. The CI
(`.github/workflows/helper.yml`) builds and tests it on Windows, Linux and macOS, runs
`TESTS/native_helper_spec.lua` against it, keeps the programs as artifacts and attaches them to a
release for every tag `helper-v*`.

```bash
nvim --clean --headless -u NONE -l helper/bench/bench.lua helper/target/release/filetree-helper 5 <root> [<root> ...]
```

```bash
nvim --clean --headless -u NONE -l helper/bench/watch.lua helper/target/release/filetree-helper
```

`bench.lua` times every tier from the call until the last answer is on the editor's main loop; it only
reads. `watch.lua` checks whether a change in a folder the tree never opened is reported.

Without the protocol: `filetree-helper walk <root> [--print]`, `filetree-helper size <dir>`,
`filetree-helper status <root> [--print]`.

## Measured (2026-11-15)

STEVESPC (i5-12400F, 12 threads), Windows 11 and WSL 2 (ext4), the machine quiet apart from a browser
and an editor. Milliseconds, median of 5 runs (Linux: 3), from the call until the last answer is on
the main loop. `fd` and `rg` called directly; through a scoop shim each start costs 40 to 70 ms more.

| Work | Root | fd | rg | Lua | helper |
| --- | --- | ---: | ---: | ---: | ---: |
| deep listing | lib.nvim (1449 files) | 106 | 50 | 37 | 14.5 |
| deep listing | testing.nvim (836) | 84 | 36 | 25 | 8.2 |
| deep listing | tasks-vault (6872) | 134 | 69 | 137 ¹ | 16.5 |
| deep listing | 100 000 files | 378 | 256 | 158 | 55 |
| deep listing | 100 000 files, Linux | 109 | 77 | 108 | 29 |
| recursive sizes | tasks-vault | | | 817 | 16 |
| recursive sizes | 100 000 files | | | 4469 | 56 |
| recursive sizes | 100 000 files, Linux | | | 409 | 46 |
| git status | lib.nvim / testing.nvim | git 83 / 75 | | | 38 / 18 |
| git status | tasks-vault | git 90 | | | 64 |
| git status | 100 000 files, 10 changed | git 106 | | | 148 |
| git status | 100 000 files, Linux | git 70 | | | 67 |

¹ The Lua walk knows no `.gitignore`: it lists 15 460 paths there.

Recursive watch (`bench/watch.lua`): on Windows both the Lua watcher and the helper report a change in
a closed folder two levels down and in a folder made after the watch started; on Linux the Lua watcher
reports neither, the helper both.

Against the threshold of concept section 10.6 (factor 2 over tier 2 in one row, or a capability Lua
lacks): the deep listing beats `fd` by 4 to 10 times and `rg` by 3 to 5 times on every root, recursive
sizes are 9 to 80 times faster than the Lua walk, and the recursive watch on Linux is the capability.
The git status is no reliable gain (slower than `git` at 100 000 files).

Decision (author, 2026-11-15): build it out narrow, before the trial period: deep listing, sizes and
the Linux watch; the git status stays with `git`. The size row above was measured with the walk's own
sizes; the size column now uses a walk without ignore rules (everything counted, as `du`).
