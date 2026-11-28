# filetree.nvim documentation

What is here, and which question each page answers. [The README](../README.md)
is the short version of all of it.

## Getting it running

| Page | Answers |
| --- | --- |
| [installation.md](installation.md) | What has to be there first ([Requirements](installation.md#requirements)), and a spec per plugin manager |
| [quickstart.md](quickstart.md) | The first thing to run after installing |
| [configuration.md](configuration.md) | Every option, and the rule behind the defaults: everything is on unless it is marked opt-in |
| [troubleshooting.md](troubleshooting.md) | What `:checkhealth` asks, and what to do when the answer is a warning |

## Using it

| Page | Answers |
| --- | --- |
| [what-you-get.md](what-you-get.md) | The 5–8 things worth knowing on day one, before reading anything else |
| [BINDINGS.md](BINDINGS.md) | The entry point to every keymap, `:Filetree` sub-command and autocommand — there are more than fit one readable page, so it hands off to [BINDINGS/](BINDINGS/) and says which page holds what |
| [commands.md](commands.md) | The `:Filetree` sub-command reference (the command name is configurable) |
| [keymaps.md](keymaps.md) | The tree-buffer keys, their defaults, and how to remap or switch one off |
| [menu.md](menu.md) | The context menu (the kit renderer), and what it offers |
| [integrations.md](integrations.md) | The same menu entries, exposed for your own trigger instead of the built-in one |
| [api.md](api.md) | Every Lua function a config or another plugin can call |
| [WORKFLOW.md](WORKFLOW.md) | The different question: not what each feature does, but how they combine once several of them exist at once |

## Why it is the way it is

| Page | Answers |
| --- | --- |
| [FEATURES/](FEATURES/README.md) | One page per area — the core, navigation, file operations, search and paths, the UI, the backends, and the integrations — each about the decision rather than the feature list |
| [around-it.md](around-it.md) | How this plugin's scope differs from its siblings in the collection |

## Here, but not prose

**`BINDINGS.lua`** is the same catalogue as `BINDINGS.md`, machine-readable: it
returns every keymap, sub-command and autocommand as data, for anything that
wants to render or check them. **`install.json`** declares the external tools
this plugin can use, for `:Lib deps show filetree.nvim`.

## Working on it

| Page | Answers |
| --- | --- |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Ground rules, project layout, and how to add an adapter or a feature |
