# Public API

```lua
local ft = require("filetree")
ft.setup(config)
ft.adapter()            -- → FiletreeAdapter?
ft.config()             -- → FiletreeConfig
ft.feature("marks")     -- → feature module | nil
ft.register_adapter(a)  -- register custom adapter (before setup)
ft.is_initialized()     -- → boolean
ft.attach(opts, config) -- deprecated no-op: hands `opts` back untouched (filetree no longer
                        -- writes into neo-tree's window.mappings; the `?` cheatsheet lists the keys)
```

## Reference engine

```lua
local refs = require("filetree.refs")
refs.config()            -- → FiletreeRefsConfig
refs.status()            -- → string[]  (what `:Filetree refs status` prints)
refs.undo()              -- revert the last reference rewrite
refs.register(provider)  -- add a language provider

-- How often is each of these files referenced, and where? One sweep for the
-- whole set (a folder of screenshots), not one scan per path.
refs.usage.count(paths, { root = nil }, function(by_path, meta)
  -- by_path[path] = { count = n, refs = FiletreeRef[], files = string[] }
  -- meta = { providers = string[], files_scanned = n, cancelled = boolean }
end)
```

Driving it from your own file operation is a three-step contract — scan
before the mutation, mutate, then hand the result back:

```lua
local handle = refs.prefetch({ old_path }, { op = "move" })
handle.await(function(result)
  -- the scan is finished and saw the file at its OLD path
  do_the_move()
  refs.handle_result(result, { [old_path] = new_path }, { op = "move" })
end)
```

## Custom reference providers

```lua
require("filetree.refs").register({
  name = "rust",
  plan = function(old_path, ctx)      -- ctx = { root, is_dir, cfg }
    return {                          -- return nil to sit this one out
      needles    = { "…" },           -- fixed strings for the ripgrep pre-filter
      extensions = { "rs" },          -- files that may hold such a reference
      extract    = function(file, lineno, text) return { --[[ FiletreeRef… ]] } end,
      retarget   = function(ref, new_path) return "…" end,
    }
  end,
})
```

See [`lua/filetree/@types/refs.lua`](../lua/filetree/@types/refs.lua) for the
full annotated contract and
[`lua/filetree/refs/providers/`](../lua/filetree/refs/providers/) for the four
built-in implementations.

## Name suggestions for the create prompt

A plugin can pre-fill the name `smart_create` (`a`) asks for, for the folders it
knows. The first provider that answers wins; the prompt stays editable.

```lua
require("filetree.create_names").register("casedesk", function(dir)
  -- dir: the folder the new entry goes into, `/`-separated, no trailing slash
  if dir:match("/assets$") then return "03_2026-10-19/" end -- trailing / = a folder
end)
```

`unregister(id)` removes a provider, `suggest(dir)` asks them. Registering works
before or after `filetree.setup()`; a provider that raises is skipped.

## Root providers

A plugin can say which directory is the root for the files it knows, ahead of
the `.git` walk: a case folder inside a larger repository, say. `cwd_mode` asks
the providers first in every mode (so `project` holds that folder), and
`util.target_dir` asks them too, so they apply with cwd_mode off as well; the
cwd cwd_sync moves to and the root the tree is shown at follow from that. A
pinned root (`lock`, `manual`) still wins.

```lua
require("filetree.roots").register("casedesk.case", function(path)
  -- path: a file or a directory; return a directory, or nil to stay out of it
  local case = require("casedesk.registry").owning(path)
  return case and case.dir or nil
end)
```

The first provider with an answer wins, in registration order; a provider that
raises, or answers with something that is not an existing directory, is
skipped. `unregister(id)` removes one, `resolve(path)` asks them, `any()` says
whether one is registered. Registering works before or after `filetree.setup()`.

## Custom adapters

```lua
require("filetree").register_adapter({
  name             = "my_tree",
  is_available     = function() return true end,
  is_open          = function() return false, nil end,
  get_winid        = function() return nil end,
  get_root_path    = function() return nil end,
  get_current_node = function() return nil end,
  get_visible_nodes= function(_f) return {} end,
  get_node_line    = function(_p) return nil end,
  expand_node      = function(_n) return false end,
  collapse_node    = function(_n) return false end,
  open_file        = function(_p,_m) return false end,
  open_reveal      = function(_p,_l) return false end,
  open_cwd         = function() return false end,
  close            = function() return false end,
  refresh          = function() return false end,
  scroll_to_line   = function(_l) return false end,
  highlight_node   = function(_p,_h) return false end,
  unhighlight_node = function(_p) return false end,
})
require("filetree").setup({ adapter = "my_tree" })
```

See [`lua/filetree/@types/adapter.lua`](../lua/filetree/@types/adapter.lua) for the full annotated interface.
