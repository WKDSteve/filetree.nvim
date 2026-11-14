---@module 'filetree.commands'
--- Central :Filetree command dispatcher with tab-completion.
---
--- Registers a single :Filetree command (built via lib.nvim.bindings.usercmd.composer)
--- that dispatches to all feature modules. TREE is the single source of
--- truth for dispatch, <Tab> completion, and M.command_paths(); composer
--- routes are derived from it, not duplicated.
---
--- Usage:
---   :Filetree <subcommand> [sub-subcommand] [args...]
---
--- Examples:
---   :Filetree trash undo
---   :Filetree git refresh
---   :Filetree filter foo bar
---   :Filetree reveal pause 2000
---   :Filetree traverse goto <dir>
---   :Filetree open <dir-or-file>

local usercmd = require("filetree.util.usercmd")
local composer = require("lib.nvim.bindings.usercmd.composer")
local notify = require("filetree.util.notify").create("[filetree]")

local M = {}

-- ── Feature accessor (lazy, only works after setup()) ─────────────────────────

---@internal
---Resolve a loaded feature module by name (nil when unavailable/before setup()).
---@param name string
---@return table?
local function ft(name)
  local ok, main = pcall(require, "filetree")
  if not ok then return nil end
  return main.feature(name)
end

---@internal
---Resolve the active adapter (nil before/without a completed setup()).
---@return FiletreeAdapter?
local function get_adapter()
  local ok, main = pcall(require, "filetree")
  if not ok then return nil end
  return main.adapter()
end

---@internal
---Split the arguments of a report command into its optional path and its
---flags (`--picker` / `--popup` / `--all`). A path with spaces arrives as
---several words and is re-joined.
---@param args string[]
---@return string? path, { view?: "popup"|"picker", all?: boolean } opts
local function parse_report_args(args)
  local words, opts = {}, {}
  for _, a in ipairs(args) do
    if a == "--all" then
      opts.all = true
    elseif a == "--picker" then
      opts.view = "picker"
    elseif a == "--popup" then
      opts.view = "popup"
    else
      words[#words + 1] = a
    end
  end
  return #words > 0 and table.concat(words, " ") or nil, opts
end

-- ── Command tree ──────────────────────────────────────────────────────────────
-- Leaf values: function(rest_args: string[])
-- Interior values: table of sub-commands
-- Special key "": default action when no sub-command is given/matched

---@type table<string, any>
local TREE = {

  -- ── own tree: an action of its table by name ────────────────────────────────
  -- `:Filetree action <name> [key=value ...]`: what the action's key does, on the selection or the
  -- node under the cursor; says in one line why when it does not apply there.
  action = function(args)
    local view = require("filetree.native").current()
    if not (view and view.actions) then
      notify.info('action: the own tree (adapter = "native") is not open in this tab')
      return
    end
    local name = args[1]
    if not name or name == "" then
      notify.info("action: which one? :Filetree action <Tab> lists them")
      return
    end
    local named = {}
    for i = 2, #args do
      local k, v = args[i]:match("^([%w_]+)=(.*)$")
      if k then named[k] = v end
    end
    require("filetree.native.action").run(view, name, next(named) and named or nil)
  end,

  -- ── trash ───────────────────────────────────────────────────────────────────
  trash = {
    undo = function(_)
      local f = ft("trash")
      if f then f.undo_last() end
    end,
    history = function(_)
      local f = ft("trash")
      if f then f.show_history() end
    end,
    ["dry-run"] = function(_)
      local f = ft("trash")
      if f then f.toggle_dry_run() end
    end,
  },

  -- ── copy/move + batch rename ────────────────────────────────────────────────
  --
  -- `trash` and `safety` already had a runtime dry-run toggle; these two, the
  -- destructive bulk operations, were config-only.
  copymove = {
    ["dry-run"] = function(_)
      local f = ft("copy_move")
      if f then f.toggle_dry_run() end
    end,
  },
  -- `renamebatch`, not `rename`: `rename` is already a leaf command further
  -- down (it opens the batch-rename buffer). Declaring a table under the same
  -- key here would just be overwritten by it, silently — which is exactly
  -- what happened on the first attempt.
  renamebatch = {
    ["dry-run"] = function(_)
      local f = ft("rename_batch")
      if f then f.toggle_dry_run() end
    end,
  },

  -- ── marks ───────────────────────────────────────────────────────────────────
  marks = {
    clear = function(_)
      local f = ft("marks")
      if f then f.clear_all() end
    end,
    show = function(_)
      local f = ft("marks")
      if f then f.show() end
    end,
    all = function(_)
      local f = ft("marks")
      if f then f.mark_all_visible() end
    end,
  },

  -- ── diff ────────────────────────────────────────────────────────────────────
  diff = {
    marked = function(_)
      local f = ft("diff")
      if f then f.diff_marked() end
    end,
    close = function(_)
      local f = ft("diff")
      if f then f.close() end
    end,
  },

  -- ── git (git_status) ─────────────────────────────────────────────────────────
  git = {
    refresh = function(_)
      local f = ft("git_status")
      if f then f.refresh() end
    end,
  },

  -- ── safety ──────────────────────────────────────────────────────────────────
  safety = {
    list = function(_)
      local f = ft("safety")
      if f then f.list_backups() end
    end,
    ["dry-run"] = function(_)
      local f = ft("safety")
      if f then f.toggle_dry_run() end
    end,
  },

  -- ── session ─────────────────────────────────────────────────────────────────
  session = {
    save = function(_)
      local f = ft("session")
      if f then f.save() end
    end,
    restore = function(_)
      local f = ft("session")
      if f then f.restore() end
    end,
    clear = function(_)
      local f = ft("session")
      if f then f.clear() end
    end,
  },

  -- ── find ────────────────────────────────────────────────────────────────────
  -- :Filetree find [dir]
  find = function(args)
    local f = ft("find_files")
    if f then f.find(args[1]) end
  end,

  -- ── grep ────────────────────────────────────────────────────────────────────
  -- :Filetree grep [pattern]
  grep = function(args)
    local f = ft("grep_in_dir")
    if f then f.grep(nil, #args > 0 and table.concat(args, " ") or nil) end
  end,

  -- ── filter ──────────────────────────────────────────────────────────────────
  -- :Filetree filter           → open floating input
  -- :Filetree filter <query>   → apply query directly
  -- :Filetree filter clear     → clear current filter
  filter = {
    [""] = function(args)
      local f = ft("filter")
      if not f then return end
      if #args > 0 then
        f.apply(table.concat(args, " "))
      else
        f.enter()
      end
    end,
    clear = function(_)
      local f = ft("filter")
      if f then f.clear() end
    end,
  },

  -- ── size ────────────────────────────────────────────────────────────────────
  size = {
    refresh = function(_)
      local f = ft("size_info")
      if f then f.refresh() end
    end,
  },

  -- ── rename ──────────────────────────────────────────────────────────────────
  rename = function(_)
    local f = ft("rename_batch")
    if f then f.open() end
  end,

  -- ── keys ────────────────────────────────────────────────────────────────────
  -- :Filetree keys   → keys claimed by more than one action; pick one to move
  keys = function(_)
    require("filetree.util.key_conflicts").resolve()
  end,

  -- ── template ────────────────────────────────────────────────────────────────
  template = function(_)
    local f = ft("create_from_template")
    if f then f.open_current() end
  end,

  -- ── link_create ─────────────────────────────────────────────────────────────
  -- :Filetree symlink              → prompt for a target, choose Symlink/Hardlink
  -- :Filetree symlink mark [path]  → mark a source (node/buffer/path, no prompt)
  -- :Filetree symlink paste        → paste the marked source, link kind by OS
  -- :Filetree symlink check [path] → report whether it's a symlink, and if broken
  -- :Filetree symlink checkall     → same, over every marked node (else cursor)
  -- :Filetree symlink repair [path] → search + relink a broken symlink's target
  -- :Filetree symlink repairall    → same, over every marked node (else cursor)
  -- :Filetree symlink delete       → remove marked symlinks (else cursor node)
  --
  -- Named `symlink`, not `link`: `link` collided with the unrelated `mdlink`
  -- (Markdown-link-string) command under the same :Filetree verb — one is a
  -- filesystem operation, the other text generation.
  symlink = {
    [""] = function(_)
      local f = ft("link_create")
      if f then f.create() end
    end,
    mark = function(args)
      local f = ft("link_create")
      if f then f.mark(#args > 0 and table.concat(args, " ") or nil) end
    end,
    paste = function(_)
      local f = ft("link_create")
      if f then f.paste() end
    end,
    check = function(args)
      local f = ft("link_create")
      if f then f.check(#args > 0 and table.concat(args, " ") or nil) end
    end,
    checkall = function(_)
      local f = ft("link_create")
      if f then f.check_all() end
    end,
    repair = function(args)
      local f = ft("link_create")
      if f then f.repair(#args > 0 and table.concat(args, " ") or nil) end
    end,
    repairall = function(_)
      local f = ft("link_create")
      if f then f.repair_all() end
    end,
    delete = function(_)
      local f = ft("link_create")
      if f then f.delete() end
    end,
  },

  -- ── reveal ──────────────────────────────────────────────────────────────────
  -- :Filetree reveal           → reveal current buffer
  -- :Filetree reveal pause [ms]
  -- :Filetree reveal resume
  reveal = {
    [""] = function(_)
      local f = ft("auto_reveal")
      if f then f.reveal_current() end
    end,
    pause = function(a)
      local f = ft("auto_reveal")
      if f then f.pause(tonumber(a[1]) or 2000) end
    end,
    resume = function(_)
      local f = ft("auto_reveal")
      if f then f.resume() end
    end,
  },

  -- ── cwd_mode ────────────────────────────────────────────────────────────────
  -- :Filetree cwd mode <name>   (completion comes from the enum route below)
  -- :Filetree cwd lock [dir]
  -- :Filetree cwd here | unlock | toggle | status
  cwd = {
    mode = function(a)
      local f = ft("cwd_mode")
      if f then f.set_mode(a[1] or "") end
    end,
    scope = function(a)
      local f = ft("cwd_mode")
      if f then f.set_scope(a[1] or "") end
    end,
    lock = function(a)
      local f = ft("cwd_mode")
      if f then f.lock(a[1]) end
    end,
    here = function(_)
      local f = ft("cwd_mode")
      if f then f.lock_here() end
    end,
    unlock = function(_)
      local f = ft("cwd_mode")
      if f then f.unlock() end
    end,
    toggle = function(_)
      local f = ft("cwd_mode")
      if f then f.cycle() end
    end,
    status = function(_)
      local f = ft("cwd_mode")
      if f then f.status() end
    end,
    forget = function(_)
      local f = ft("cwd_mode")
      if f then f.forget() end
    end,
  },

  -- ── source_switcher (neo-tree only) ─────────────────────────────────────────
  -- :Filetree source            pick from a list
  -- :Filetree source <name>     switch to a source by name
  -- :Filetree source next|prev  cycle
  -- :Filetree source debug      print what the switcher sees
  source = {
    [""] = function(a)
      local f = ft("source_switcher")
      if not f then return end
      if a[1] and a[1] ~= "" then
        local ok, err = f.switch(a[1])
        if not ok then notify.warn(err or "switch failed") end
      else
        f.pick()
      end
    end,
    pick = function(_)
      local f = ft("source_switcher")
      if f then f.pick() end
    end,
    next = function(_)
      local f = ft("source_switcher")
      if f then f.next() end
    end,
    prev = function(_)
      local f = ft("source_switcher")
      if f then f.prev() end
    end,
    debug = function(_)
      local f = ft("source_switcher")
      if f then f.debug() end
    end,
  },

  -- ── collapse_all ────────────────────────────────────────────────────────────
  -- :Filetree collapse   collapse every folder back to the root
  collapse = function(_)
    local f = ft("collapse_all")
    if not f then
      notify.warn("collapse_all is off (features.collapse_all.enabled = false)")
      return
    end
    f.run()
  end,

  -- ── sort_cycle ──────────────────────────────────────────────────────────────
  -- :Filetree sort            next sort criterion (name, size, modified)
  -- :Filetree sort reverse    flip the direction
  sort = {
    [""] = function(_)
      local f = ft("sort_cycle")
      if f then f.cycle() end
    end,
    reverse = function(_)
      local f = ft("sort_cycle")
      if f then f.reverse() end
    end,
  },

  -- ── tree_toggle (opt-in) ────────────────────────────────────────────────────
  -- :Filetree toggle [left|right|float|current]   (default: left)
  toggle = function(args)
    local f = ft("tree_toggle")
    if not f then
      notify.warn("tree_toggle is off (features.tree_toggle.enabled = true turns it on)")
      return
    end
    local ok, err = f.toggle(args[1] or "left")
    if not ok then notify.warn(err or "toggle failed") end
  end,

  -- ── quickpick (opt-in) ──────────────────────────────────────────────────────
  -- :Filetree quickpick [levels]   number the tree (levels = folders above the file to root at)
  -- :Filetree quickpick cwd        number the tree rooted at the cwd
  -- :Filetree quickpick cancel     leave the mode
  quickpick = {
    [""] = function(a)
      local f = ft("quickpick")
      if not f then
        notify.warn("quickpick is off (features.quickpick.enabled = true turns it on)")
        return
      end
      f.start({ parent_levels = tonumber(a[1]) or 0 })
    end,
    cwd = function(_)
      local f = ft("quickpick")
      if not f then
        notify.warn("quickpick is off (features.quickpick.enabled = true turns it on)")
        return
      end
      f.start({ cwd = true })
    end,
    cancel = function(_)
      local f = ft("quickpick")
      if f then f.cancel() end
    end,
  },

  -- ── resize ──────────────────────────────────────────────────────────────────
  -- :Filetree resize [width]
  resize = function(args)
    local f = ft("auto_resize")
    if f then f.set_width(tonumber(args[1])) end
  end,

  -- ── watcher ─────────────────────────────────────────────────────────────────
  watcher = {
    enter = function(a)
      local f = ft("watcher_quarantine")
      if f then f.enter(tonumber(a[1])) end
    end,
    exit = function(_)
      local f = ft("watcher_quarantine")
      if f then f.exit() end
    end,
  },

  -- ── copy-move ───────────────────────────────────────────────────────────────
  clipboard = {
    show = function(_)
      local f = ft("copy_move")
      if f then f.show() end
    end,
    clear = function(_)
      local f = ft("copy_move")
      if f then f.clear() end
    end,
    copy = function(_)
      local f = ft("copy_move")
      if f then f.stage_copy() end
    end,
    cut = function(_)
      local f = ft("copy_move")
      if f then f.stage_cut() end
    end,
    paste = function(_)
      local f = ft("copy_move")
      if f then f.paste() end
    end,
  },

  -- ── breadcrumbs ──────────────────────────────────────────────────────────────
  breadcrumbs = {
    update = function(_)
      local f = ft("breadcrumbs")
      if f then
        local path = vim.api.nvim_buf_get_name(0)
        if path ~= "" then f.update(path) end
      end
    end,
  },

  -- ── open_with ────────────────────────────────────────────────────────────────
  -- :Filetree open <dir-or-file>  → open the tree focused/rooted on that path
  -- :Filetree open system         → open current node with the OS default app
  -- :Filetree open pick           → pick an app to open the current node with
  -- :Filetree open app <name>     → open the current node with a named app
  --
  -- A literal path spelled exactly "system"/"pick"/"app" can't reach the default
  -- branch below -- same collision class as symlink/mdlink noted above.
  open = {
    [""] = function(args)
      if #args == 0 then
        notify.warn(
          "Filetree open: give a directory/file path, or use 'system' | 'pick' | 'app <name>'"
        )
        return
      end
      local path = table.concat(args, " ")
      if vim.fn.isdirectory(path) == 1 then
        local f = ft("tree_traverse")
        if f then f.go_to(path) end
        return
      end
      if vim.fn.filereadable(path) == 1 then
        local ad = get_adapter()
        if not ad or type(ad.open_reveal) ~= "function" then
          notify.warn("adapter does not support open_reveal")
          return
        end
        ad.open_reveal(path, 0)
        return
      end
      notify.warn("not a file or directory: " .. path)
    end,
    system = function(_)
      local f = ft("open_with")
      if f then f.open_system() end
    end,
    pick = function(_)
      local f = ft("open_with")
      if f then f.pick() end
    end,
    app = function(a)
      local f = ft("open_with")
      if f then f.open_app(a[1] or "") end
    end,
  },

  -- ── file_clipboard ───────────────────────────────────────────────────────────
  -- :Filetree clipfiles  → copy the marked nodes (else the current one) to the OS
  --                        clipboard as files, ready for Ctrl+V in another app
  clipfiles = function(_)
    local f = ft("file_clipboard")
    if f then f.copy() end
  end,

  -- ── compress ──────────────────────────────────────────────────────────────────
  -- :Filetree compress [each|together]  → zip the marked nodes (else the current one)
  compress = {
    [""] = function(_)
      local f = ft("compress")
      if f then f.compress() end
    end,
    each = function(_)
      local f = ft("compress")
      if f then f.compress("each") end
    end,
    together = function(_)
      local f = ft("compress")
      if f then f.compress("together") end
    end,
  },

  -- ── open_variants ─────────────────────────────────────────────────────────────
  openas = {
    vsplit = function(_)
      local f = ft("open_variants")
      if f then f.open_vsplit() end
    end,
    split = function(_)
      local f = ft("open_variants")
      if f then f.open_split() end
    end,
    tabnew = function(_)
      local f = ft("open_variants")
      if f then f.open_tabnew() end
    end,
    badd = function(_)
      local f = ft("open_variants")
      if f then f.open_badd() end
    end,
  },

  -- ── mdrefs (trash's quickfix references-picker fallback) ────────────────────
  mdrefs = {
    confirm = function(_)
      require("filetree.util.refs_picker").qf_confirm()
    end,
    cancel = function(_)
      require("filetree.util.refs_picker").qf_cancel()
    end,
  },

  -- ── references (who points at this file) ────────────────────────────────────
  -- :Filetree references [--picker|--popup] [path]
  --   the sites that reference the file under the cursor (or `path`), in a
  --   popup or a picker; <CR> jumps. Same as `:Filetree refs list`.
  references = function(args)
    local path, opts = parse_report_args(args)
    require("filetree.refs.report").references(path, opts)
  end,

  -- ── refs (reference engine) ─────────────────────────────────────────────────
  refs = {
    list = function(args)
      local path, opts = parse_report_args(args)
      require("filetree.refs.report").references(path, opts)
    end,
    -- :Filetree refs unused [--all] [dir]  → files under `dir` (default: the
    -- node under the cursor, else the asset roots) that nothing references;
    -- pick some and they go to the trash. --all lifts the asset-extension filter.
    unused = function(args)
      local path, opts = parse_report_args(args)
      require("filetree.refs.report").unused(path, opts)
    end,
    undo = function(_)
      require("filetree.refs").undo()
    end,
    status = function(_)
      notify.info(table.concat(require("filetree.refs").status(), "\n"))
    end,
  },

  -- ── markdown_links ─────────────────────────────────────────────────────────────
  mdlink = {
    [""] = function(_)
      local f = ft("markdown_links")
      if f then f.link_current() end
    end,
    recursive = function(_)
      local f = ft("markdown_links")
      if f then f.link_recursive() end
    end,
    marked = function(_)
      local f = ft("markdown_links")
      if f then f.link_from_marked() end
    end,
    insert = function(_)
      local f = ft("markdown_links")
      if f then f.insert_current() end
    end,
  },

  -- ── hooks_api ─────────────────────────────────────────────────────────────
  hooks = {
    events = function(_)
      local f = ft("hooks_api")
      if not f then return end
      local evs = f.events()
      if #evs == 0 then
        notify.info("No hooks registered")
      else
        local lines = {}
        for _, ev in ipairs(evs) do
          lines[#lines + 1] = string.format("  %s (%d)", ev, f.count(ev))
        end
        notify.info("Hooks:\n" .. table.concat(lines, "\n"))
      end
    end,
    clear = function(a)
      local f = ft("hooks_api")
      if not f then return end
      f.clear(a[1])
      notify.info("Hooks cleared" .. (a[1] and (" for: " .. a[1]) or ""))
    end,
  },

  -- ── smart_rename ─────────────────────────────────────────────────────────────
  smartrename = function(_)
    local f = ft("smart_rename")
    if f then f.rename_current() end
  end,

  -- ── move ─────────────────────────────────────────────────────────────────────
  -- :Filetree move [destination]   (no argument → prompt)
  move = function(args)
    local f = ft("move")
    if f then f.move(#args > 0 and table.concat(args, " ") or nil) end
  end,

  -- ── path_copy ─────────────────────────────────────────────────────────────────
  copy = {
    absolute = function(_)
      local f = ft("path_copy")
      if f then f.copy_absolute() end
    end,
    relative = function(_)
      local f = ft("path_copy")
      if f then f.copy_relative() end
    end,
    name = function(_)
      local f = ft("path_copy")
      if f then f.copy_name() end
    end,
    absolute_raw = function(_)
      local f = ft("path_copy")
      if f then f.copy_absolute_raw() end
    end,
    dirname = function(_)
      local f = ft("path_copy")
      if f then f.copy_dirname() end
    end,
    uri = function(_)
      local f = ft("path_copy")
      if f then f.copy_uri() end
    end,
    line = function(_)
      local f = ft("path_copy")
      if f then f.copy_line() end
    end,
    stem = function(_)
      local f = ft("path_copy")
      if f then f.copy_stem() end
    end,
    project_root = function(_)
      local f = ft("path_copy")
      if f then f.copy_project_root() end
    end,
    project_relative = function(_)
      local f = ft("path_copy")
      if f then f.copy_project_relative() end
    end,
    buffer_relative = function(_)
      local f = ft("path_copy")
      if f then f.copy_buffer_relative() end
    end,
    env_rooted = function(_)
      local f = ft("path_copy")
      if f then f.copy_env_rooted() end
    end,
    pick = function(_)
      local f = ft("path_copy")
      if f then f.pick() end
    end,
  },

  -- ── live_search ──────────────────────────────────────────────────────────────
  search = {
    [""] = function(_)
      local f = ft("live_search")
      if f then f.open() end
    end,
    clear = function(_)
      local f = ft("live_search")
      if f then f.clear() end
    end,
  },

  -- ── smart_create ──────────────────────────────────────────────────────────────
  create = function(_)
    local f = ft("smart_create")
    if f then f.create() end
  end,

  -- ── copy_file_list ────────────────────────────────────────────────────────────
  filelist = {
    files = {
      abs = function(_)
        local f = ft("copy_file_list")
        if f then f.copy_files_abs() end
      end,
      rel = function(_)
        local f = ft("copy_file_list")
        if f then f.copy_files_rel() end
      end,
    },
    dirs = {
      abs = function(_)
        local f = ft("copy_file_list")
        if f then f.copy_dirs_abs() end
      end,
      rel = function(_)
        local f = ft("copy_file_list")
        if f then f.copy_dirs_rel() end
      end,
    },
    save = function(_)
      local f = ft("copy_file_list")
      if f then f.save_files() end
    end,
  },

  -- ── lua_require_copy ─────────────────────────────────────────────────────────
  require = {
    [""] = function(_)
      local f = ft("lua_require_copy")
      if f then f.copy_require() end
    end,
    relative = function(_)
      local f = ft("lua_require_copy")
      if f then f.copy_require_relative() end
    end,
  },

  -- ── tree_traverse ─────────────────────────────────────────────────────────────
  traverse = {
    up = function(_)
      local f = ft("tree_traverse")
      if f then f.up() end
    end,
    down = function(_)
      local f = ft("tree_traverse")
      if f then f.down() end
    end,
    ["goto"] = function(args)
      local f = ft("tree_traverse")
      if f then f.go_to(args[1]) end
    end,
  },

  -- ── node_info ────────────────────────────────────────────────────────────────
  info = {
    [""] = function(_)
      local f = ft("node_info")
      if f then f.show_current() end
    end,
    close = function(_)
      local f = ft("node_info")
      if f then f.close() end
    end,
  },

  -- ── handle_guard ─────────────────────────────────────────────────────────────
  handles = function(_)
    local f = ft("handle_guard")
    if not f then
      notify.info("handle_guard is not enabled")
      return
    end
    if not f.installed() then
      notify.info(
        "handle_guard enabled but not installed here "
          .. "(needs the neo-tree adapter on Windows/WSL)"
      )
      return
    end
    local list = f.handles()
    if #list == 0 then
      notify.info("No neo-tree watcher handles currently tracked")
      return
    end
    local lines = { string.format("Tracked watcher handles (%d):", #list) }
    for _, h in ipairs(list) do
      -- A watcher on a path that no longer exists is the leak signature.
      local flag = h.exists and "" or "  ⚠ path gone (leaked watcher)"
      lines[#lines + 1] = string.format("  %s %s%s", h.active and "●" or "○", h.path, flag)
    end
    notify.info(table.concat(lines, "\n"))
  end,

  -- ── health ───────────────────────────────────────────────────────────────────
  health = function(_)
    vim.cmd("checkhealth filetree")
  end,
}

-- ── TREE → composer routes ───────────────────────────────────────────────────
-- TREE stays the single source of truth (also read by M.command_paths()
-- below, unchanged); routes are derived from it fresh on every M.setup()
-- rather than duplicated by hand, so the two can never drift.
--
-- Composer's tree.walk greedily consumes literal path tokens and stops at
-- the deepest node reached; if that node has its OWN route (registered from
-- a `[""]` default key here) it dispatches there with whatever tokens didn't
-- match as ctx.rest — which is exactly the original dispatch()'s "unknown
-- sub-command falls through to the default handler with all args" behavior
-- for filter/reveal/mdlink/search/info/require (all `[""]`-bearing groups),
-- reproduced for free by composer's own walk, not re-implemented here.

---@internal
--- One-line texts per sub-command path (see command_descs.lua), for the composer option float and docs.
---@type table<string, string>
local descs = require("filetree.command_descs")

---@internal
---Recursively walk a TREE-shaped table, appending a composer route per leaf function.
---@param node table
---@param path string[]
---@param routes table[]
local function walk_tree(node, path, routes)
  for key, val in pairs(node) do
    local child_path = path
    if key ~= "" then
      child_path = vim.deepcopy(path)
      child_path[#child_path + 1] = key
    end
    if type(val) == "function" then
      routes[#routes + 1] = {
        path = child_path,
        desc = descs[table.concat(child_path, " ")],
        run = function(ctx)
          val(ctx.rest)
        end,
      }
    elseif type(val) == "table" then
      walk_tree(val, child_path, routes)
    end
  end
end

---@internal
---Build the composer route list from TREE. A few leaves are special-cased so
--- their arguments get types (directory completion, a closed set of mode
--- names) instead of the generic tree-key walking; every other leaf just
--- forwards ctx.rest into the unchanged TREE function, exactly like before.
--- The typed routes still call the TREE function, so TREE stays the single
--- source of truth for M.command_paths() and for what actually runs.
---@return table[]
local function build_routes()
  local routes = {}
  local walked = vim.tbl_extend("force", {}, TREE)
  walked.find = nil
  -- Shallow-copy the group before removing its typed leaves — the outer
  -- tbl_extend copies references, so deleting in place would mutate TREE.
  walked.cwd = vim.tbl_extend("force", {}, TREE.cwd)
  walked.cwd.mode = nil
  walked.cwd.scope = nil
  walked.cwd.lock = nil
  walked.traverse = vim.tbl_extend("force", {}, TREE.traverse)
  walked.traverse["goto"] = nil
  walked.action = nil
  walk_tree(walked, {}, routes)

  -- the names of the actions of the own tree open in this tab, for <Tab>
  require("lib.nvim.bindings.usercmd.composer.argtypes").register("FILETREE_ACTION", {
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      local view = require("filetree.native").current()
      local out = {}
      for _, action in ipairs(view and view.actions and view.actions:list() or {}) do
        if action.name:sub(1, #arg_lead) == arg_lead then out[#out + 1] = action.name end
      end
      return out
    end,
  })
  routes[#routes + 1] = {
    path = { "action" },
    args = {
      {
        name = "name",
        type = "FILETREE_ACTION",
        desc = "An action of the own tree open in this tab (<Tab> lists them)",
      },
    },
    desc = "Run an action of the own tree by name, on the selection or the node under the cursor",
    run = function(ctx)
      local args = { ctx.args.name }
      for _, t in ipairs(ctx.rest) do
        args[#args + 1] = t
      end
      TREE.action(args)
    end,
  }

  routes[#routes + 1] = {
    path = { "find" },
    args = { { name = "dir", type = "DIR", optional = true } },
    desc = "Find files (optionally scoped to a directory)",
    run = function(ctx)
      local args = {}
      if ctx.args.dir ~= nil then args[1] = ctx.args.dir end
      for _, t in ipairs(ctx.rest) do
        args[#args + 1] = t
      end
      TREE.find(args)
    end,
  }

  routes[#routes + 1] = {
    path = { "wholocks" },
    args = { { name = "path", type = "PATH", optional = true } },
    desc = "Diagnose who is holding a file open (Windows EBUSY/EPERM); --json for structured output",
    run = function(ctx)
      local as_json = false
      for _, t in ipairs(ctx.rest) do
        if t == "--json" then as_json = true end
      end
      local path = ctx.args.path
      if path == "--json" then
        path, as_json = nil, true
      end
      require("filetree.features.infra.who_locks").run(path, as_json)
    end,
  }

  routes[#routes + 1] = {
    path = { "cwd", "mode" },
    args = {
      {
        name = "name",
        type = "STRING",
        enum = { "follow", "project", "nearest", "lock", "manual", "tree_leads" },
        desc = "Root policy that decides where the cwd and the tree root sit",
        enum_desc = {
          follow = "No policy: the usual per-buffer root resolution",
          project = "Hold the project root until a file outside it opens",
          nearest = "Like project, but the nearest package boundary",
          lock = "Pin the cwd to one directory; buffer switches never move it",
          manual = "Nothing automatic; only explicit actions change it",
          tree_leads = "The tree root leads and the cwd follows it",
        },
      },
    },
    desc = "Set the cwd/root policy (follow | project | nearest | lock | manual | tree_leads)",
    run = function(ctx)
      TREE.cwd.mode({ ctx.args.name })
    end,
  }

  routes[#routes + 1] = {
    path = { "cwd", "scope" },
    args = {
      {
        name = "name",
        type = "STRING",
        enum = { "global", "tab", "win" },
        desc = "Which directory the cwd policy changes",
        enum_desc = {
          global = "The global directory (:cd)",
          tab = "The tab-local directory (:tcd)",
          win = "The window-local directory (:lcd)",
        },
      },
    },
    desc = "Set the directory scope of the cwd policy (:cd | :tcd | :lcd)",
    run = function(ctx)
      TREE.cwd.scope({ ctx.args.name })
    end,
  }

  routes[#routes + 1] = {
    path = { "cwd", "lock" },
    args = { { name = "dir", type = "DIR", optional = true } },
    desc = "Lock the cwd to a directory (default: the current one)",
    run = function(ctx)
      TREE.cwd.lock({ ctx.args.dir })
    end,
  }

  routes[#routes + 1] = {
    path = { "traverse", "goto" },
    args = { { name = "dir", type = "DIR" } },
    desc = "Change the tree root to a given directory",
    run = function(ctx)
      TREE.traverse["goto"]({ ctx.args.dir })
    end,
  }

  return routes
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type string[]
local _registered_commands = {}

---@param cfg FiletreeCommandConfig|string|nil  A name, a config table, or nothing.
function M.setup(cfg)
  -- Re-setup is idempotent: composer's usercmd.create overwrites an existing
  -- command of the same name safely, but cfg can change the NAME between
  -- calls (custom cfg.name/aliases) — without tearing down first, a renamed
  -- setup() would leave the old name(s) registered and stale alongside the
  -- new one. So: drop whatever this module registered last time, then
  -- recreate under (possibly different) names.
  M.teardown()

  -- Determine name(s) to register.
  -- cfg.command = "Ft"                  → just :Ft
  -- cfg.command = { name="Ft", aliases={"Filetree"} } → :Ft and :Filetree
  local names = {}
  if type(cfg) == "string" then
    names[1] = cfg
  elseif type(cfg) == "table" then
    names[1] = cfg.name or "Filetree"
    for _, a in ipairs(cfg.aliases or { "Ft" }) do
      names[#names + 1] = a
    end
  else
    -- Out of the box: both :Filetree and the short :Ft alias work.
    names[1] = "Filetree"
    names[2] = "Ft"
  end

  -- One shared route list across every name (same pattern as replacer.nvim's
  -- :Replace/:Replacer) — composer.verb() only reads the spec to build a
  -- route tree, it doesn't mutate it, so reusing one table across multiple
  -- verb registrations is safe.
  local spec = { desc = "filetree.nvim — unified command interface", routes = build_routes() }

  local seen = {}
  for _, cmd_name in ipairs(names) do
    if not seen[cmd_name] then
      seen[cmd_name] = true
      composer.verb(cmd_name, spec)
      _registered_commands[#_registered_commands + 1] = cmd_name
    end
  end
end

---The primary command name registered by the last M.setup() ("Filetree" unless
---the user renamed it), for display in docs and the cheatsheet.
---@return string
function M.command_name()
  return _registered_commands[1] or "Filetree"
end

---Unregister every :Filetree/:Ft command variant registered by the last M.setup().
function M.teardown()
  for _, cmd_name in ipairs(_registered_commands) do
    usercmd.del(cmd_name)
  end
  _registered_commands = {}
end

---Walk the command TREE and return every sub-command path as a string, sorted.
---The dispatcher's TREE is the single source of truth, so this never drifts from
---what is actually registered. Default-action (`""`) keys are skipped.
---@return string[]  e.g. { "trash undo", "git refresh", "marks show", … }
function M.command_paths()
  local out = {}
  local function walk(node, prefix)
    for key, val in pairs(node) do
      if key ~= "" then
        local path = prefix == "" and key or (prefix .. " " .. key)
        if type(val) == "table" then
          walk(val, path)
        else
          out[#out + 1] = path
        end
      end
    end
  end
  walk(TREE, "")
  table.sort(out)
  return out
end

return M
