---@module 'filetree.features.fileops.create_from_template'
--- Create files from user-defined templates with variable substitution.
---
--- Templates are stored as plain files in a configurable directory
--- (default: stdpath("data")/filetree/templates/).
--- Each file in that directory is a template; its filename is the template
--- name shown in the picker.
---
--- Template variables (replaced on creation):
---   ${filename}   Basename of the new file (without extension)
---   ${ext}        Extension of the new file (without dot)
---   ${date}       Current date in YYYY-MM-DD format
---   ${year}       Current year
---   ${month}      Current month (01-12)
---   ${day}        Current day (01-31)
---   ${time}       Current time in HH:MM:SS
---   ${author}     Value of config.author or $USER/$USERNAME
---   ${module}     For a destination under a real lua/ directory: the canonical
---                 Lua module path via lib.nvim.lua_ls.get_module_path (the
---                 same resolver filetree's own lua_require_copy is built on
---                 — not reimplemented here), e.g. lua/plugins/test.lua ->
---                 "plugins.test". Otherwise a generic dotted path from the
---                 project root (any language) — e.g. src/foo/Bar.cs ->
---                 "src.foo.Bar".
---
--- Workflow:
---   1. Press "A" in tree (the smart_create "a" counterpart) — or :Filetree template
---   2. Pick a template FIRST — the full list, grouped by [custom]/[builtin]
---      (see "Display grouping" below)
---   3. Enter the new filename, pre-filled with the template's own filename
---      (extension included) so the destination always keeps the extension
---      the picked template's content actually is — no more "check.md" filled
---      with a C++ template's content: whatever extension you don't
---      deliberately change stays the template's own
---   4. File is created in the current node's directory (now that both the
---      template and the destination path are known, ${module} and every
---      other variable resolve against the real destination) and opened
---
--- Adding your own templates: drop a file into the template directory (default
--- stdpath("data")/filetree/templates/) — its filename becomes the template
--- name — or call M.add_template(name, content) programmatically.
---
--- Display grouping: the builtin picker (see "Picker backend" below) groups
--- the list under a "[custom]" and a "[builtin]" header instead of tagging
--- every single built-in entry — a per-item "name  [builtin]" marker on every
--- row not authored by the user was pure repetition once the list mixes both.
--- Headers are only shown when both kinds are actually present; a directory
--- with only built-ins (the common case before you've added your own) stays a
--- plain, unlabelled list. Headers are cosmetic and never selectable.
---
--- Reordering: while the picker is open (query empty, i.e. not mid-filter),
--- <M-j>/<M-k> move the highlighted template down/up. The order is persisted
--- to a `.order.json` sidecar in the template directory, so it survives
--- restarts; a never-reordered or newly-added template is appended
--- alphabetically after the ones with an explicit position. A move never
--- crosses the [custom]/[builtin] boundary (there is no "up" out of the
--- bottom of one group into the other) — the persisted order is itself kept
--- grouped custom-then-builtin, in step with the display, so a move is never
--- silently absorbed by a boundary it can't actually cross.
---
--- Picker backend (`indicator`-style `prefer` config, default "auto"): when
--- pickers.nvim is installed, the template list goes through it instead of
--- the built-in kit.picker — real fuzzy matching (not the plain substring
--- match kit.picker does) plus a native content preview of the highlighted
--- template (telescope's own file previewer, snacks', or fzf-lua's, via
--- pickers.nvim's `Pickers.Item` preview support). Trade-off: pickers.nvim's
--- `pick_item()` has no concept of custom in-picker keymaps, so the
--- <M-j>/<M-k> reorder keymaps above only work through the built-in picker —
--- set `prefer = "builtin"` to keep reordering instead of fuzzy search +
--- preview. pickers.nvim is a genuinely optional third-party plugin
--- (pcall-required): absent, or `prefer = "builtin"`, and this falls back
--- to the original kit.picker/vim.ui.select flow unchanged. ui.nvim itself
--- is not optional — see the `kit`/`has_kit_picker` comment below.
---
--- Keymap (default): "A" in tree buffer.

local notify = require("filetree.util.notify").create("[filetree.create_from_template]")
local path_u = require("filetree.util.path")
local bufutil = require("filetree.util.buffer")
local win_u = require("filetree.util.window")
local json = require("lib.nvim.fs.json")

local map = require("filetree.util.map")
local ui_select = require("filetree.util.select")
local ui_confirm = require("filetree.util.confirm")

-- ui.kit is a hard dependency of this plugin (LUA-01): M.open() below
-- bare-requires it unconditionally too, so a pcall here bought no real
-- resilience, only an inconsistent read of whether it's optional. What
-- genuinely varies is whether THIS install's ui.kit is new enough to expose
-- the lower-level `picker` component (it exposes the results window/cursor
-- the reorder keymaps need — the simple `filetree.util.select` shim does
-- not); the reorderable picker falls back to the plain ui_select flow (no
-- reordering) on an older ui.nvim that predates it.
local kit = require("ui.kit")
local has_kit_picker = type(kit.picker) == "function"

-- Optional: real fuzzy search + native content preview via pickers.nvim's
-- Pickers.Item support, instead of kit.picker's plain substring match and no
-- preview at all. Soft dependency, same pattern as the kit check above —
-- absent, and pick_template() falls back to the kit.picker/ui_select flow.
local _ok_pickers, pickers_engines = pcall(require, "pickers.engines")
local has_pickers = _ok_pickers
  and type(pickers_engines) == "table"
  and type(pickers_engines.load) == "function"

local M = {}

---@type FiletreeCreateFromTemplateConfig
local DEFAULTS = {
  enabled = false,
  keymap = "A",
  template_dir = nil, -- defaults to stdpath("data")/filetree/templates/
  author = nil, -- defaults to $USER/$USERNAME
  open_after = true, -- open file in editor after creation
  prefer = "auto", -- auto | telescope | fzf | snacks | builtin
}

---@type FiletreeCreateFromTemplateConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.create_from_template` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  template_dir = "string",
  author = "string",
  open_after = "boolean",
  prefer = { "string", enum = { "auto", "telescope", "fzf", "snacks", "builtin" } },
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Template directory ────────────────────────────────────────────────────────

---@internal
local function template_dir()
  local dir = _cfg.template_dir or (vim.fn.stdpath("data") .. "/filetree/templates")
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  return dir
end

---Directory of templates shipped WITH filetree.nvim itself (several per
---common language), found via 'runtimepath' rather than a path computed
---relative to this file — works regardless of how the plugin was installed
---(git clone, local dir checkout, symlink, …), same mechanism
---ftplugin/syntax/doc rely on. Namespaced under lua/filetree/… (not a generic
---top-level "templates/") so an unrelated plugin can never collide with it.
---Living under lua/ does mean lua_ls, luacheck, stylua and the test tooling
---would take a `.lua` template for source (its ${...} placeholders do not
---parse, a spec template contains busted calls). So the shipped Lua templates
---carry a `.tpl` suffix on disk (`lua_class.lua.tpl`); `scan_dir` strips it,
---so the template is still called `lua_class.lua` and the new file keeps
---its `.lua` extension. The other tools also skip this directory (.luarc.json
---workspace.ignoreDir, .luacheckrc, .styluaignore). A picker preview derives
---its syntax from the file NAME, and `*.tpl` alone means smarty, so
---`register_tpl_filetype` (below) tells Neovim these four are Lua. Cached:
---'rtp' doesn't change mid-session in normal use, and this is the picker's hot path.
---@internal
---@return string?
local _builtin_dir
local function builtin_dir()
  if _builtin_dir ~= nil then return _builtin_dir ~= false and _builtin_dir or nil end
  local found = vim.api.nvim_get_runtime_file("lua/filetree/assets/templates/", true)
  _builtin_dir = found[1] or false
  return found[1]
end

-- ── Variable substitution ─────────────────────────────────────────────────────

---@internal
local function author()
  if _cfg.author and _cfg.author ~= "" then return _cfg.author end
  return vim.env.USER or vim.env.USERNAME or "unknown"
end

-- The canonical, already-implemented path -> Lua module resolver (also what
-- filetree's own lua_require_copy feature is conceptually doing by hand) —
-- reuse it rather than re-deriving the same "/lua/…/init.lua -> foo.bar"
-- logic a third time.
local get_lua_module_path = require("lib.nvim.lua_ls.get_module_path")
local bind = require("filetree.util.bind")

---Dotted module/namespace path for `${module}`.
---
---For a destination genuinely under a `lua/` directory, defers entirely to
---`lib.nvim.lua_ls.get_module_path` — the shared resolver, not reimplemented
---here. That function returns nil for anything not under `lua/` (by design:
---it is Lua-specific), in which case this falls back to a generic path
---relative to the project root (any language) — e.g. src/foo/Bar.cs ->
---"src.foo.Bar" — stripping whatever extension the destination actually has.
---@internal
---@param abs_path string
---@return string
local function module_path(abs_path)
  local canonical = get_lua_module_path(abs_path)
  if canonical then return canonical end

  local ok_pr, pr = require("filetree.features").load("project_root")
  local root
  if ok_pr and pr and type(pr.find) == "function" then root = pr.find(abs_path) end
  root = root or vim.fn.getcwd() -- project_root.find() may return nil (no marker found)
  local rel = path_u.relative(abs_path, root)
  rel = rel:gsub("%.[^./\\]+$", "") -- strip whatever extension is actually there
  return (rel:gsub("[/\\]", "."):gsub("%.init$", "")) -- parens: gsub returns (str, count)
end

---@internal
---@param content string
---@param new_path string
---@return string
local function substitute(content, new_path)
  local base = vim.fn.fnamemodify(new_path, ":t:r") -- name without ext
  local ext = vim.fn.fnamemodify(new_path, ":e")
  local now = os.date("*t")
  local vars = {
    filename = base,
    ext = ext,
    date = os.date("%Y-%m-%d"),
    year = tostring(now.year),
    month = string.format("%02d", now.month),
    day = string.format("%02d", now.day),
    time = os.date("%H:%M:%S"),
    author = author(),
    module = module_path(new_path),
  }
  return (
    content:gsub("%${(%w+)}", function(key)
      return vars[key] or ("${" .. key .. "}")
    end)
  )
end

-- ── Display order (persisted, user-reorderable) ─────────────────────────────────
-- A sidecar file rather than encoding order in filenames, so reordering never
-- touches the template files themselves. `.`-prefixed so it never lists as a
-- template itself (vim.fn.readdir has no dotfile-hiding on Windows, hence the
-- explicit skip in raw_templates() below rather than relying on that).

---@internal
local function order_file()
  return template_dir() .. "/.order.json"
end

---Back up `order_file()`'s current on-disk content to `<path>.corrupt`, once,
---so a broken-but-present file never turns into silent data loss the next
---time `save_order()` writes a fresh order over it. Not re-written if a
---backup already exists (an earlier corruption caught on a previous load).
---@internal
---@param path string  `order_file()`, resolved once by the caller
local function backup_corrupt_order(path)
  local backup_path = path .. ".corrupt"
  if vim.fn.filereadable(backup_path) == 1 then return end
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and type(lines) == "table" then pcall(vim.fn.writefile, lines, backup_path) end
end

---"No order saved yet" (nothing to load -- fine, list_templates() falls back
---to alphabetical) and "order file present but unreadable/undecodable" are
---NOT the same situation: `M.move()` normalizes to the FULL current template
---list and calls `save_order()`, which unconditionally overwrites
---`order_file()` with that normalized list. Collapsing "corrupt" to the same
---empty result as "missing" means the very next reorder silently discards
---whatever custom order the file held (transient write failure, hand edit,
---partial write from a crash) with no trace it ever existed. A present-but-
---broken file is therefore backed up before being treated as empty, and
---reported, instead of failing quietly.
---@internal
---@return string[]
local function load_order()
  local path = order_file() -- once: every call stats template_dir()
  if vim.fn.filereadable(path) == 0 then return {} end -- nothing saved yet: not an error

  local decoded, err = json.read(path)
  if type(decoded) == "table" and type(decoded.order) == "table" then return decoded.order end

  backup_corrupt_order(path)
  notify.warn(
    "Template order file is unreadable or corrupt; falling back to alphabetical order (original kept at "
      .. path
      .. ".corrupt): "
      .. tostring(err)
  )
  return {}
end

---`json.write` reports failure through its return value (`false, err`), it
---does not throw -- so `pcall`'s own status alone would call every failed
---write a success, and `M.move` would then claim a reorder that never
---reached disk.
---@internal
---@param order string[]
---@return boolean ok
local function save_order(order)
  local ok, wrote, err = pcall(json.write, order_file(), { order = order })
  if ok and wrote == true then return true end
  notify.warn("Could not save the template order: " .. tostring(ok and err or wrote))
  return false
end

-- ── Template list ─────────────────────────────────────────────────────────────

---List template files (name + path) directly in `dir`, alphabetical.
---In the shipped (`builtin`) directory a trailing `.tpl` is not part of the
---template name: `lua_class.lua.tpl` is the template `lua_class.lua`. The
---user's own directory is taken literally.
---@internal
---@param dir string
---@param builtin boolean
---@return {name:string, path:string, builtin:boolean}[]
local function scan_dir(dir, builtin)
  local ok, entries = pcall(vim.fn.readdir, dir)
  if not ok then return {} end
  local tmpl = {}
  for _, e in ipairs(entries) do
    if not e:match("^%.") then -- skip .order.json and any other dotfile
      local full = dir .. "/" .. e
      if vim.fn.filereadable(full) == 1 then
        local name = e
        if builtin and #e > 4 and e:sub(-4) == ".tpl" then name = e:sub(1, -5) end
        tmpl[#tmpl + 1] = { name = name, path = full, builtin = builtin }
      end
    end
  end
  table.sort(tmpl, function(a, b)
    return a.name < b.name
  end)
  return tmpl
end

---Templates on disk, alphabetical — the order-agnostic source of truth for
---"what templates exist". `list_templates()` below layers the persisted
---display order on top of this.
---
---Merges the built-in templates shipped with filetree.nvim (several per
---common language, read-only — never written to by add_template/M.move) with the
---user's own template_dir(). A user template with the SAME NAME as a
---built-in shadows it entirely (name and content), the usual override-layer
---pattern — so customizing a shipped default is just: drop a same-named file
---into your own template_dir().
---@internal
---@return {name:string, path:string, builtin:boolean}[]
local function raw_templates()
  local user = scan_dir(template_dir(), false)

  local bdir = builtin_dir()
  local builtin = bdir and scan_dir(bdir, true) or {}

  local by_name, out = {}, {}
  for _, t in ipairs(user) do
    by_name[t.name] = t
  end
  for _, t in ipairs(builtin) do
    if not by_name[t.name] then by_name[t.name] = t end
  end
  for name in pairs(by_name) do
    out[#out + 1] = name
  end
  table.sort(out)

  local tmpl = {}
  for _, name in ipairs(out) do
    tmpl[#tmpl + 1] = by_name[name]
  end
  return tmpl
end

---Templates in display order: the persisted order first (skipping any entry
---that no longer exists on disk), then any template without an explicit
---position — new or never-reordered — appended alphabetically.
---@internal
---@return {name:string, path:string, builtin:boolean?}[]
local function list_templates()
  local all = raw_templates()
  local by_name = {}
  for _, t in ipairs(all) do
    by_name[t.name] = t
  end

  local ordered, seen = {}, {}
  for _, name in ipairs(load_order()) do
    local t = by_name[name]
    if t and not seen[name] then
      ordered[#ordered + 1] = t
      seen[name] = true
    end
  end
  for _, t in ipairs(all) do
    if not seen[t.name] then
      ordered[#ordered + 1] = t
      seen[t.name] = true
    end
  end
  return ordered
end

---Split `templates` into its custom (non-builtin) and builtin entries,
---each preserving their relative order from `templates`. The shared basis
---for both the grouped picker display (`build_rows` below) and `M.move`'s
---own persisted order, so the two are never out of step with each other.
---@internal
---@param templates {name:string, path:string, builtin:boolean?}[]
---@return {name:string, path:string, builtin:boolean?}[] custom
---@return {name:string, path:string, builtin:boolean?}[] builtin
local function partition_by_category(templates)
  local custom, builtin = {}, {}
  for _, t in ipairs(templates) do
    if t.builtin then
      builtin[#builtin + 1] = t
    else
      custom[#custom + 1] = t
    end
  end
  return custom, builtin
end

---Move `name` up (-1) or down (+1) one position, WITHIN its own category
---(custom or builtin) — never across the [custom]/[builtin] boundary the
---picker displays, since a cross-category swap would reorder the persisted
---list without any visible effect (the display always groups custom before
---builtin regardless of how they interleave underneath), which would make
---the keymap look like it silently did nothing. No-op (false) at either the
---overall or the category boundary, or when `name` doesn't exist.
---
---Persists the FULL list every time, always as custom-block then
---builtin-block (mirroring `build_rows`'s own grouping) — not just the
---touched category — so the order file never drifts back into an
---interleaved shape that a later render would have to un-group again.
---@param name string
---@param delta -1|1
---@return boolean moved
function M.move(name, delta)
  local custom, builtin = partition_by_category(list_templates())

  local group, at
  for i, t in ipairs(custom) do
    if t.name == name then
      group, at = custom, i
      break
    end
  end
  if not group then
    for i, t in ipairs(builtin) do
      if t.name == name then
        group, at = builtin, i
        break
      end
    end
  end
  if not group then return false end

  local target = at + delta
  if target < 1 or target > #group then return false end
  group[at], group[target] = group[target], group[at]

  local full = {}
  for _, t in ipairs(custom) do
    full[#full + 1] = t.name
  end
  for _, t in ipairs(builtin) do
    full[#full + 1] = t.name
  end
  return save_order(full)
end

-- ── Creation ──────────────────────────────────────────────────────────────────

---@internal
---@param tmpl_path string
---@param dest_path string
---@return boolean ok
local function create_from(tmpl_path, dest_path)
  local ok, lines = pcall(vim.fn.readfile, tmpl_path)
  if not ok then
    notify.error("Cannot read template: " .. tmpl_path)
    return false
  end
  local content = table.concat(lines, "\n")
  local rendered = substitute(content, dest_path)
  local rendered_lines = {}
  for l in (rendered .. "\n"):gmatch("([^\n]*)\n") do
    rendered_lines[#rendered_lines + 1] = l
  end
  -- Remove trailing empty line added by the split
  if rendered_lines[#rendered_lines] == "" and #rendered_lines > 1 then
    table.remove(rendered_lines)
  end

  -- A name typed with a subdirectory ("sub/x.lua" -- accepted by M.open)
  -- needs its parent to exist first: writefile() does not create it.
  local parent = vim.fn.fnamemodify(dest_path, ":h")
  if vim.fn.isdirectory(parent) == 0 then vim.fn.mkdir(parent, "p") end

  -- writefile() reports failure by THROWING (E482: missing parent, dest is a
  -- directory, permission), not by returning non-zero -- so an unguarded call
  -- would surface as a raw Lua error out of the input callback.
  local ok_write, rc = pcall(vim.fn.writefile, rendered_lines, dest_path)
  if not ok_write or rc ~= 0 then
    notify.error("Could not write: " .. dest_path .. (ok_write and "" or (": " .. tostring(rc))))
    return false
  end
  return true
end

-- ── Picker flow ───────────────────────────────────────────────────────────────

---Display label for a single template row. No more per-item "[builtin]"
---marker — the builtin picker conveys that distinction with the "[custom]"/
---"[builtin]" section headers `build_rows` inserts below instead (repeating
---the same marker on every single builtin row was pure noise once the list
---mixes both kinds); the pickers.nvim path (`pick_template_via_pickers`,
---which cannot render header rows without polluting its own fuzzy match)
---still just shows the plain name.
---@internal
---@param t {name:string, builtin:boolean?}
---@return string
local function display_name(t)
  return t.name
end

---Rows for the builtin picker's display: a flat `{text, tmpl}[]`, `tmpl` nil
---for the two cosmetic "[custom]"/"[builtin]" header rows. Headers are
---inserted ONLY when `templates` actually holds both kinds — a directory
---with just built-ins (or, in principle, just custom ones) stays a plain,
---unlabelled list exactly as before, since there is nothing to distinguish.
---Custom is listed before builtin — see the module docstring's "Display
---grouping" note — matching the order `M.move` itself persists in, so the
---two never disagree about where the boundary sits.
---@internal
---@param templates {name:string, path:string, builtin:boolean?}[]
---@return {text:string, tmpl:({name:string, path:string, builtin:boolean?})?}[]
local function build_rows(templates)
  local custom, builtin = partition_by_category(templates)
  local rows = {}

  if #custom > 0 and #builtin > 0 then
    rows[#rows + 1] = { text = "[custom]" }
    for _, t in ipairs(custom) do
      rows[#rows + 1] = { text = display_name(t), tmpl = t }
    end
    rows[#rows + 1] = { text = "[builtin]" }
    for _, t in ipairs(builtin) do
      rows[#rows + 1] = { text = display_name(t), tmpl = t }
    end
  else
    for _, t in ipairs(templates) do
      rows[#rows + 1] = { text = display_name(t), tmpl = t }
    end
  end

  return rows
end

---Plain, non-reorderable picker (fallback when the ui kit's `picker`
---component is unavailable — e.g. lib.nvim absent, or the kit's own mount
---failed). Picking a header row (nil `tmpl`) re-opens the same picker rather
---than silently closing on nothing — headers aren't real choices, but a
---`vim.ui.select`-shaped picker has no notion of a disabled row to prevent
---landing on one in the first place.
---@internal
---@param templates {name:string, path:string, builtin:boolean?}[]
---@param on_select fun(tmpl: {name:string, path:string, builtin:boolean?})
local function pick_template_plain(templates, on_select)
  ui_select(build_rows(templates), {
    prompt = "Templates",
    format_item = function(row)
      return row.text
    end,
  }, function(row)
    if not row then return end
    if not row.tmpl then
      pick_template_plain(templates, on_select)
      return
    end
    on_select(row.tmpl)
  end)
end

---Reorderable picker: <CR> selects (as before), <M-j>/<M-k> move the
---highlighted template down/up while the filter is empty — persisted
---immediately via M.move(). Filtering by typing still works (kit.picker's
---own query→on_change), it just can't be combined with reordering in the
---same keystroke, since "move" is only well-defined against the full,
---unfiltered order; a filtered list also drops the [custom]/[builtin]
---headers (`build_rows`) and shows a flat match list instead, same reasoning.
---@internal
---@param templates {name:string, path:string, builtin:boolean?}[]
---@param on_select fun(tmpl: {name:string, path:string, builtin:boolean?})
local function pick_template_reorderable(templates, on_select)
  local list = templates -- current template set (post-filter), always flat
  local rows = {} -- current display rows -- may include header rows when unfiltered

  local function render(handle)
    -- Read the query straight from `handle` rather than caching a separate
    -- "filtering" flag: a flag set only inside on_change can drift from what
    -- the picker is actually showing (e.g. this initial pre-any-on_change
    -- call), and there is no upside to a second copy of the same fact.
    rows = (handle.query() ~= "")
        and vim.tbl_map(function(t)
          return { text = display_name(t), tmpl = t }
        end, list)
      or build_rows(list)

    local lines = {}
    for _, row in ipairs(rows) do
      lines[#lines + 1] = row.text
    end
    handle.set_results(lines)

    -- Headers ("[custom]"/"[builtin]") are cosmetic, not real choices, but
    -- kit.picker's results list has no notion of a disabled row to keep the
    -- cursor off one — unlike pick_template_plain's vim.ui.select fallback,
    -- which re-opens itself when a header gets picked, `on_submit` below
    -- just silently does nothing for one. Row 1 IS a header ("[custom]")
    -- whenever any custom template exists, so a bare <CR> right after
    -- opening the picker would otherwise land on it. Nudge the cursor onto
    -- the next real template row whenever a (re)render leaves it sitting on
    -- a header — every header is immediately followed by at least one real
    -- row (see build_rows: a header is only emitted for a non-empty group).
    local results = handle.slots.results
    if results and results:is_valid() then
      local cur = vim.api.nvim_win_get_cursor(results.winid)[1]
      if rows[cur] and not rows[cur].tmpl then
        for i = cur, #rows do
          if rows[i].tmpl then
            pcall(vim.api.nvim_win_set_cursor, results.winid, { i, 0 })
            break
          end
        end
      end
    end
  end

  -- Forward-declared: `on_change` below closes over `handle`, but on the
  -- right-hand side of a `local handle = kit.picker(...)` statement the new
  -- local isn't in scope yet — that nested closure would resolve `handle` as
  -- a global (always nil) instead of an upvalue. Declaring it first, then
  -- assigning, makes the closures capture the real local.
  local handle
  handle = kit.picker({
    on_change = function(query)
      if query == "" then
        list = templates
      else
        local q = query:lower()
        list = vim.tbl_filter(function(t)
          return t.name:lower():find(q, 1, true) ~= nil
        end, templates)
      end
      render(handle)
    end,
    on_submit = function(idx)
      local row = rows[idx]
      if row and row.tmpl then
        on_select(row.tmpl)
      elseif row then
        -- Defense in depth alongside the cursor nudge in render() and the
        -- header-skipping handle.move below: kit.picker's submit closes the
        -- picker BEFORE it calls on_submit, so a header that still gets
        -- submitted (a race with a render) would otherwise just dismiss the
        -- picker. Re-open it instead, as pick_template_plain does. Deferred
        -- so the closing picker's own teardown (stopinsert) has finished.
        vim.schedule(function()
          pick_template_reorderable(templates, on_select)
        end)
      end
    end,
  })
  if not handle then
    pick_template_plain(templates, on_select)
    return
  end
  render(handle)

  -- <C-n>/<C-p>/<Up>/<Down> all call `handle.move(delta)` through the handle
  -- table at keypress time, so wrapping it here is what keeps the cursor from
  -- resting on a header while browsing (render() only covers re-renders).
  -- Keep stepping in the same direction past any header; bounded by #rows,
  -- and every header is followed by a real row (see build_rows).
  local raw_move = handle.move
  handle.move = function(delta)
    raw_move(delta)
    local win = handle.slots.results
    if not (win and win:is_valid()) then return end
    for _ = 1, #rows do
      local row = rows[vim.api.nvim_win_get_cursor(win.winid)[1]]
      if not row or row.tmpl then return end
      raw_move(delta)
    end
  end

  local function current_idx()
    local results = handle.slots.results
    if not (results and results:is_valid()) then return nil end
    return vim.api.nvim_win_get_cursor(results.winid)[1]
  end

  local function move(delta)
    if handle.query() ~= "" then
      notify.info("Clear the filter to reorder templates")
      return
    end
    local idx = current_idx()
    local row = idx and rows[idx]
    local tmpl = row and row.tmpl
    if not tmpl or not M.move(tmpl.name, delta) then return end

    templates = list_templates() -- reload: reflects the just-persisted order
    list = templates
    render(handle)

    -- Find where `tmpl` landed in the just-rebuilt rows, rather than
    -- assuming `idx + delta`: a header row can sit between the old and new
    -- position (e.g. moving the last custom entry down persisted-wise, even
    -- though `M.move` itself never lets a move cross the group boundary),
    -- so the row one position away isn't reliably the row `tmpl` moved to.
    local target = idx
    for i, r in ipairs(rows) do
      if r.tmpl and r.tmpl.name == tmpl.name then
        target = i
        break
      end
    end
    local results = handle.slots.results
    if results and results:is_valid() then
      pcall(vim.api.nvim_win_set_cursor, results.winid, { target, 0 })
    end
  end

  local mo = { buffer = handle.slots.prompt.bufnr, nowait = true }
  map({ "i", "n" }, "<M-j>", function()
    move(1)
  end, mo, "Filetree: move template down")
  map({ "i", "n" }, "<M-k>", function()
    move(-1)
  end, mo, "Filetree: move template up")
end

---Make `vim.filetype.match` call the shipped `*.lua.tpl` templates Lua. The
---previewers behind pickers.nvim (snacks, telescope) take the preview's syntax
---from the file NAME, and Neovim reads a bare `*.tpl` as smarty, so without
---this the four Lua templates would be previewed with smarty highlighting.
---Scoped to this plugin's own `assets/templates/` directory: any other `.tpl`
---file, and a user's own template, keeps whatever filetype it had. Idempotent
---(registered once per session) and global by nature of `vim.filetype.add`,
---which also gives the shipped templates Lua highlighting when opened for editing.
---`vim.filetype.add` anchors a pattern itself (`^...$`), so none is written
---here; `/+` because the template path is `<dir>` .. "/" .. `<name>` and `<dir>`
---may already end in a separator (`templates//lua_class.lua.tpl`).
---@internal
local _tpl_filetype_registered = false
local function register_tpl_filetype()
  if _tpl_filetype_registered then return end
  _tpl_filetype_registered = true
  pcall(vim.filetype.add, {
    pattern = { [".*/filetree/assets/templates/+[^/]+%.lua%.tpl"] = "lua" },
  })
end

---Delegate to pickers.nvim for real fuzzy search + a native content preview
---of the highlighted template. Loses the <M-j>/<M-k> reorder keymaps that
---`pick_template_reorderable` has — pickers.nvim's `pick_item()` has no
---concept of custom in-picker keymaps; `prefer = "builtin"` keeps reordering
---instead. Each item carries the original template descriptor under `tmpl`
---(alongside the `text`/`file` fields pickers.nvim itself reads) purely so
---`on_select` gets it back directly — pickers.nvim always passes an item
---through unchanged, so this needs no lookup-by-label the way a plain
---string list would.
---@internal
---@param templates {name:string, path:string, builtin:boolean?}[]
---@param on_select fun(tmpl: {name:string, path:string, builtin:boolean?})
---@return boolean ok  false when no engine could be loaded — caller should fall back
local function pick_template_via_pickers(templates, on_select)
  -- "builtin" means "do not go through pickers.nvim at all", and
  -- `engines.load` has no engine by that name. The caller checks it too; this
  -- is the check that holds when the function is called from anywhere else.
  local prefer = _cfg.prefer
  if prefer == "builtin" then return false end
  ---@cast prefer "auto"|"fzf"|"snacks"|"telescope"|nil
  local engine_mod = pickers_engines.load(prefer)
  if not engine_mod then return false end

  register_tpl_filetype()
  local items = {}
  for i, t in ipairs(templates) do
    items[i] = { text = display_name(t), file = t.path, tmpl = t }
  end

  engine_mod.pick_item({
    prompt = "Templates",
    items = items,
    on_select = function(item)
      if type(item) == "table" and item.tmpl then on_select(item.tmpl) end
    end,
  })
  return true
end

---@internal
---@param templates {name:string, path:string, builtin:boolean?}[]
---@param on_select fun(tmpl: {name:string, path:string, builtin:boolean?})
local function pick_template(templates, on_select)
  if #templates == 0 then
    notify.warn("No templates in: " .. template_dir())
    return
  end

  if
    _cfg.prefer ~= "builtin"
    and has_pickers
    and pick_template_via_pickers(templates, on_select)
  then
    return
  end

  if has_kit_picker then
    pick_template_reorderable(templates, on_select)
  else
    pick_template_plain(templates, on_select)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Open the template picker FIRST, then prompt for the filename — pre-filled
---with the picked template's own filename (extension included) — then
---create the file, in that order. Picking the template before the name is
---known is what fixes the old name-first flow's actual bug: with the name
---typed first (e.g. "check.md") and the picker then merely FILTERED by its
---extension, nothing stopped a fallback-to-full-list pick of a template
---whose real extension didn't match (a `.cpp` template, still with `.md` as
---the destination) — the file got that template's content under an
---extension that didn't fit it, so its buffer opened with the wrong
---filetype. Pre-filling the name from the chosen template's own filename
---means the destination's extension defaults to the one the content is
---actually written for; the user can still rename the base part (or the
---extension, deliberately) before submitting.
---@param dest_dir string  Absolute destination directory.
function M.open(dest_dir)
  pick_template(list_templates(), function(tmpl)
    require("ui.kit").input({
      title = "New file from "
        .. tmpl.name
        .. " (in "
        .. vim.fn.fnamemodify(dest_dir, ":t")
        .. "): ",
      default = tmpl.name,
      on_submit = function(name)
        -- Surrounding whitespace is never intended (Windows would silently
        -- drop a trailing space or dot from the name, so what gets created
        -- would differ from what the "Created:" message reports).
        name = name and vim.trim(name) or ""
        if name == "" then return end
        name = path_u.slashify(name) -- accept "/" or "\" if creating into a subdir
        if name:sub(-1) == "/" then
          notify.warn("Give a filename, not just a directory: " .. name)
          return
        end
        local dest = dest_dir .. "/" .. name

        local function proceed()
          if create_from(tmpl.path, dest) then
            notify.info("Created: " .. name .. " (from " .. tmpl.name .. ")")
            local changed = require("filetree.util.changed")
            changed.emit("create", nil, dest)
            changed.refresh(_adapter)
            if _cfg.open_after then
              -- Open in a real editor window, never the tree window itself (loading
              -- a buffer into the tree's own window fights its window-management
              -- autocmds and can hang Neovim — see smart_create/duplicate_node).
              local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid()
              local win = bufutil.find_editor_win(tree_win)
              if win then
                vim.api.nvim_set_current_win(win)
              else
                -- Opposite side of the tree, not wherever 'splitright' points.
                win_u.open_editor_window(_adapter)
              end
              vim.cmd("edit " .. vim.fn.fnameescape(dest))
            end
          end
        end

        if vim.fn.filereadable(dest) == 1 then
          ui_confirm({
            question = "File exists. Overwrite?",
            on_choice = function(yes)
              if yes then proceed() end
            end,
          })
        else
          proceed()
        end
      end,
    })
  end)
end

---Open picker at the current tree node's directory.
function M.open_current()
  if not _adapter then return end
  local node = _adapter.get_current_node()
  local dir = node
      and (node.type == "directory" and node.path or vim.fn.fnamemodify(node.path, ":h"))
    or vim.fn.getcwd()
  M.open(dir)
end

---Return all available templates.
---@return {name:string, path:string, builtin:boolean?}[]
function M.list()
  return list_templates()
end

---Add a template programmatically.
---@param name    string  Template filename.
---@param content string  Template content.
function M.add_template(name, content)
  local dir = template_dir()
  local path = dir .. "/" .. name
  local lines = {}
  for l in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = l
  end
  vim.fn.writefile(lines, path)
  notify.info("Template added: " .. name)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeCreateFromTemplateConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("create_from_template", _cfg, {
    { name = "create", field = "keymap", rhs = M.open_current, desc = "create from template" },
  })
end

function M.teardown()
  _adapter = nil
end

return M
