-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- smoke.lua — headless regression smoke test for filetree.nvim.
--
-- Runs the plugin against a stub adapter (no tree plugin required) and asserts
-- the core invariants: every feature module loads, the opt-out defaults resolve,
-- the registry resolver works, and the binding catalog is populated.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/smoke.lua
--
-- Exit code 0 = all checks passed; 1 = a check failed (message printed).

-- ── Locate the repo root relative to this file, put it (and lib.nvim) on rtp ──
-- ":p" resolves to absolute first, so `root` survives any later cwd change
-- (":h:h" alone would stay relative to invocation-time cwd).
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
-- lib.nvim is a declared dependency. Candidates in order: $LIB_NVIM_DIR (the one scripts/test.sh resolved first, so
-- this script tests the same lib.nvim as the rest of the suite), $FILETREE_LIB_NVIM,
-- $LIB_NVIM_PATH (the name lib.nvim's own resolve template uses, and the one
-- TESTS/refs/run.lua reads), a sibling checkout, then lazy.nvim's managed copy.
-- All four suites and refs/run.lua accept both variables, so one exported name
-- runs the whole suite. The sibling is what CI relies on (it checks lib.nvim
-- out next to this repo); the lazy fallback is what makes the suites runnable
-- from a git worktree, where "../lib.nvim" points inside .claude/worktrees/ and
-- does not exist.
local lib_candidates = {}
-- Appended one at a time rather than written as a table literal: an unset
-- `vim.env.X` is nil, and a nil inside a table constructor truncates the array
-- for ipairs -- with neither variable exported the whole list would be skipped
-- and the fallbacks below would never be reached.
for _, env in ipairs({ "LIB_NVIM_DIR", "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" then lib_candidates[#lib_candidates + 1] = v end
end
lib_candidates[#lib_candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/lib.nvim"
lib_candidates[#lib_candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"
for _, candidate in ipairs(lib_candidates) do
  if vim.fn.isdirectory(candidate .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(candidate)
    break
  end
end

-- ui.nvim is a declared dependency too: filetree.refs.ui requires("ui.kit")
-- unconditionally (not lazy, not pcall'd), and setup() below loads refs
-- eagerly -- same candidate order as lib.nvim above.
local ui_candidates = {}
for _, env in ipairs({ "UI_NVIM_DIR", "FILETREE_UI_NVIM", "UI_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" then ui_candidates[#ui_candidates + 1] = v end
end
ui_candidates[#ui_candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/ui.nvim"
ui_candidates[#ui_candidates + 1] = vim.fn.stdpath("data") .. "/lazy/ui.nvim"
for _, candidate in ipairs(ui_candidates) do
  if vim.fn.isdirectory(candidate .. "/lua/ui") == 1 then
    vim.opt.rtp:prepend(candidate)
    break
  end
end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  — " .. detail) or ""))
  end
end

-- ── Stub adapter: satisfies the interface, does nothing ──────────────────────
local function stub_adapter()
  return setmetatable({
    name = "stub",
    is_available = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })
end

local ft = require("filetree")
local reg = require("filetree.features")
ft.register_adapter(stub_adapter())

-- 1) every registered feature module loads at its (category) path
do
  local bad = {}
  for name, info in pairs(reg.FEATURES) do
    if not pcall(require, info.mod) then bad[#bad + 1] = name end
  end
  check("all feature modules load", #bad == 0, table.concat(bad, ", "))
end

-- 2) setup is clean and opt-out resolves (default-on minus the opt-in few)
--
-- Kept as a literal list rather than reading `init.lua`'s own DEFAULT_DISABLED
-- table: the point of this check is that the shipped default actually matches
-- what the docs/CHANGELOG promise, so it has to compare against an
-- independent expectation, not against the same table it would be verifying.
-- (This list drifted out of sync with init.lua's once before -- `size_info`
-- was missing from both, so the count-based check below matched by
-- coincidence while size_info rendered on every tree by default. Update both
-- lists together.)
local DEFAULT_OFF = {
  "cwd_sync",
  "current_hl",
  "safety",
  "auto_resize",
  "handle_guard",
  "size_info",
  "tree_toggle",
  "quickpick",
}
do
  local warnings = 0
  local orig = vim.notify
  -- A test double over typed `vim.*` surface: replacing the field is the
  -- point of the case, not a second definition of it.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m, l, o)
    if type(m) == "string" and m:find("filetree") and (l or 0) >= vim.log.levels.WARN then
      warnings = warnings + 1
    end
    return orig(m, l, o)
  end
  local ok = pcall(ft.setup, { adapter = "stub" })
  vim.notify = orig
  check("setup() runs without warnings", ok and warnings == 0, "warnings=" .. warnings)

  local total = vim.tbl_count(reg.FEATURES)
  local active = 0
  for name in pairs(reg.FEATURES) do
    if ft.feature(name) then active = active + 1 end
  end
  check(
    "opt-out active count = total - " .. #DEFAULT_OFF,
    active == total - #DEFAULT_OFF,
    ("active=%d total=%d"):format(active, total)
  )

  local off_ok = true
  for _, n in ipairs(DEFAULT_OFF) do
    if ft.is_feature_enabled(n) then off_ok = false end
  end
  check("all opt-in features are off by default", off_ok)
end

-- 3) explicit enable/disable overrides the default in both directions
do
  ft.setup({
    adapter = "stub",
    features = { marks = { enabled = false }, auto_resize = { enabled = true } },
  })
  check("explicit { enabled=false } disables a default-on feature", ft.feature("marks") == nil)
  check("explicit { enabled=true } enables a default-off feature", ft.feature("auto_resize") ~= nil)
  ft.setup({ adapter = "stub" })
end

-- 4) registry resolver
do
  check("registry.require resolves a feature", reg.require("preview") ~= nil)
  check(
    "registry.mod_path returns the category path",
    reg.mod_path("marks") == "filetree.features.org.marks",
    reg.mod_path("marks")
  )
  check("registry.require(unknown) is nil", reg.require("does_not_exist") == nil)
end

-- 5) binding catalog
do
  local b = require("filetree.bindings")
  local cat = b.catalog()
  check("catalog has usercommands (walked live)", #cat.usercommands > 50, "#=" .. #cat.usercommands)
  check("catalog has keymaps for several categories", vim.tbl_count(cat.keymaps) >= 8)
  check("catalog has autocmd entries", #cat.autocmds > 0)
  check(
    "docs/BINDINGS.lua returns the catalog",
    type(dofile(root .. "/docs/BINDINGS.lua")) == "table"
  )
end

-- 6) no two default-on, tree-scoped keymaps target the same physical key ────
-- Terminals cannot distinguish some key pairs from each other: a physical Tab
-- keypress and Ctrl-I send the identical byte ("<Tab>" == "<C-i>"), likewise
-- "<CR>" == "<C-m>" and "<Esc>" == "<C-[>". Two default-on features silently
-- fighting over one of these pairs is exactly the jump_list/preview bug that
-- made <Tab> preview toggle fall through to an unrelated global mapping
-- instead of firing — this guards against that class of bug recurring.
do
  local ALIASES = {
    ["<c-i>"] = "<tab>",
    ["<tab>"] = "<tab>",
    ["<c-m>"] = "<cr>",
    ["<cr>"] = "<cr>",
    ["<c-[>"] = "<esc>",
    ["<esc>"] = "<esc>",
  }
  local function canonical(lhs)
    -- Only fold via the specific known alias pairs (case-insensitively, since
    -- "<C-i>"/"<c-i>" are the same key spelled differently) — anything else
    -- must stay case-sensitive: "b" and "B" are genuinely different physical
    -- keypresses, not an alias.
    return ALIASES[lhs:lower()] or lhs
  end

  -- marks.keymap_clear used to sit on "<C-m>" and was listed here as an
  -- accepted exception, on the grounds that two exact single-key binds can
  -- only produce ordinary "last registration wins" shadowing -- one of the
  -- two still works, and the legacy neo-tree config had the same pairing
  -- without complaints.
  --
  -- That model is wrong, which is why the exception is gone rather than
  -- reworded. Measured on 0.12:
  --
  --   vim.keymap.set("n", "<CR>",  f)   -- both survive: the mapping table
  --   vim.keymap.set("n", "<C-m>", g)   -- holds TWO entries, not one
  --
  -- Neither overwrites the other, in either bind order -- so nothing is
  -- "shadowed". But feeding the byte a terminal actually sends for both keys
  -- (0x0D) always resolves to <CR>, and it still resolves to <CR> when
  -- nothing maps <CR> at all: it never falls through to the <C-m> entry.
  -- Reaching that entry needs the terminal to send a *distinct* sequence for
  -- Ctrl+M, which only an extended encoding ("CSI u"/modifyOtherKeys, or
  -- win32 console input) provides.
  --
  -- So the outcome was not "one of the two wins" but "<CR> always wins and
  -- marks.keymap_clear is dead on every terminal without CSI u" -- the
  -- silent-never-fires class this check exists to catch. The legacy config's
  -- lack of complaints is consistent with that: nobody reports a key that
  -- quietly does nothing. `keymap_clear` now defaults to "<leader>mc".
  -- filter.keymap_clear and copy_move.keymaps.clear used to both default to
  -- "<C-c>" and were waved through here as accepted. They are not any more: the
  -- clipboard clear is "X". Two features on one key is a key that silently does
  -- nothing (the later `:map` wins, and which one is later depends on attach
  -- order), so no pair is accepted; `TESTS/keys.lua` checks the same thing
  -- against the keys actually bound, opt-in features included.
  local ACCEPTED = {}

  local b = require("filetree.bindings")
  local seen = {} -- canonical key -> feature name that claimed it first
  local collisions = {}
  for _, entries in pairs(b.keymaps) do
    for _, e in ipairs(entries) do
      if e.scope == "tree" and not e.opt_in then
        local key = canonical(e.lhs)
        if seen[key] and seen[key] ~= e.feature then
          local a, z = seen[key], e.feature
          if a > z then
            a, z = z, a
          end
          local accepted_key = a .. ":" .. z .. ":" .. key
          if not ACCEPTED[accepted_key] then
            collisions[#collisions + 1] = ("%s (%s) vs %s (%s) both target %q"):format(
              seen[key],
              key,
              e.feature,
              e.lhs,
              key
            )
          end
        else
          seen[key] = e.feature
        end
      end
    end
  end
  check(
    "no default-on tree keymaps collide on an alias-equivalent physical key",
    #collisions == 0,
    table.concat(collisions, "; ")
  )
end

-- 7) the shared buffer-lifecycle dispatcher
--
-- Ten features used to own a BufEnter autocmd each; they now register with
-- `filetree.util.bufevents`. Two things have to hold, and neither is obvious
-- from reading one feature: a re-setup must not double them (a plain autocmd
-- got that for free from `augroup(clear = true)` — here it depends on every
-- teardown() calling unregister), and every handler needs a `desc`, because
-- there is now only one autocmd and the desc is all the generated bindings
-- table has left to print per handler.
do
  local bufevents = require("filetree.util.bufevents")
  local opts = {
    adapter = "stub",
    -- cwd_sync and current_hl are opt-in; enable them so all ten features
    -- are represented.
    features = { cwd_sync = { enabled = true }, current_hl = { enabled = true } },
  }

  ft.setup(opts)
  local first = bufevents.handlers()
  check("every feature registered a buffer-lifecycle handler", #first >= 10, "n=" .. #first)

  local no_desc = {}
  for _, h in ipairs(first) do
    if not h.desc or h.desc == "" then no_desc[#no_desc + 1] = table.concat(h.keys, ",") end
  end
  check("every handler has a desc", #no_desc == 0, table.concat(no_desc, "; "))

  local sorted = true
  for i = 2, #first do
    if first[i].priority < first[i - 1].priority then sorted = false end
  end
  check("handlers come back in priority order", sorted)

  ft.setup(opts)
  ft.setup(opts)
  local after = bufevents.handlers()
  check(
    "re-setup does not accumulate handlers",
    #after == #first,
    ("%d -> %d"):format(#first, #after)
  )

  -- One autocmd for all of them, plus the dispatcher's own BufWipeout cleanup.
  local au = require("lib.nvim.bindings.autocmd")
  local recs = au.registered({ group = "filetree_bufevents" })
  check("the ten handlers share two autocmds", #recs == 2, "n=" .. #recs)

  ft.setup({ adapter = "stub" })
end

-- 6) menu integration: every (feature, function) pair the context menu wires
-- up resolves to a REAL function on the real feature module, not just a
-- non-nil stub (unlike TESTS/menu.lua, which stubs "filetree" entirely).
-- `entry()`'s self-gating in filetree.integrations.menu means a renamed or
-- removed function silently DROPS the menu item instead of erroring -- this
-- is the guard against that going unnoticed. Mirrors the pairs `items()`
-- actually calls `entry()` with; keep the two lists in sync by hand.
do
  ft.setup({ adapter = "stub" })
  local MENU_PAIRS = {
    { "smart_create", "create" },
    { "smart_rename", "rename_current" },
    { "rename_batch", "open" },
    { "move", "move" },
    { "create_from_template", "open_current" },
    { "copy_move", "stage_copy" },
    { "copy_move", "stage_cut" },
    { "copy_move", "paste" },
    { "file_clipboard", "copy" },
    { "trash", "delete_current" },
    { "open_variants", "open_vsplit" },
    { "open_variants", "open_split" },
    { "open_variants", "open_tabnew" },
    { "open_with", "open_system" },
    { "open_in_fm", "open" },
    { "path_copy", "pick" },
    { "markdown_links", "link_current" },
    { "find_files", "find" },
    { "grep_in_dir", "grep" },
    { "node_info", "show_current" },
    { "marks", "toggle_current" },
    { "marks", "mark_all_visible" },
    { "marks", "unmark_all_visible" },
    { "marks", "clear_all" },
    { "marks", "show" },
  }
  local bad = {}
  for _, pair in ipairs(MENU_PAIRS) do
    local fname, fn = pair[1], pair[2]
    local mod = ft.feature(fname)
    if not (mod and type(mod[fn]) == "function") then bad[#bad + 1] = fname .. "." .. fn end
  end
  check(
    "context-menu (feature, function) pairs all resolve to real functions",
    #bad == 0,
    table.concat(bad, ", ")
  )
end

-- ── Every :Filetree route carries a description (composer option float, docs) ──
do
  local commands = require("filetree.commands")
  commands.setup("FiletreeSmokeDesc")
  local handle = require("lib.nvim.bindings.usercmd.composer").registry().FiletreeSmokeDesc
  local bare = {}
  for _, route in ipairs(handle:spec().routes) do
    if not route.desc or route.desc == "" then bare[#bare + 1] = table.concat(route.path, " ") end
  end
  check("every :Filetree route has a description", #bare == 0, table.concat(bare, ", "))
  -- ... and every text in command_descs.lua is the one a route carries (no dead entries). Matching
  -- the path alone is not enough: a hand-built route (`find`, `cwd mode`, ...) has its own `desc`,
  -- so an entry of the same path would exist but never be read.
  local by_path = {}
  for _, route in ipairs(handle:spec().routes) do
    by_path[table.concat(route.path, " ")] = route
  end
  local dead = {}
  for key, text in pairs(require("filetree.command_descs")) do
    local route = by_path[key]
    if not route or route.desc ~= text then dead[#dead + 1] = key end
  end
  table.sort(dead)
  check(
    "command_descs.lua has no entry a route does not read",
    #dead == 0,
    table.concat(dead, ", ")
  )

  -- ... and every positional argument says what it is for (`cwd mode <name>`, `cwd scope <name>`;
  -- DIR / PATH arguments explain themselves). A lib.nvim older than `help.undocumented` cannot
  -- answer: the check fails by name instead of being skipped (NEW-43).
  local composer = require("lib.nvim.bindings.usercmd.composer")
  if type(composer.help.undocumented) == "function" then
    local missing = {}
    for _, m in ipairs(composer.help.undocumented("FiletreeSmokeDesc", { args = true })) do
      missing[#missing + 1] = ("%s %s %s"):format(m.kind, m.route, m.name)
    end
    check(
      "every :Filetree flag and argument has a text",
      #missing == 0,
      table.concat(missing, ", ")
    )

    -- House style of the argument texts: one line, no trailing period, at most 80 characters, and
    -- every `enum_desc` key is a value the argument offers.
    local texts, malformed, stray = 0, {}, {}
    for _, route in ipairs(handle:spec().routes) do
      for _, arg in ipairs(route.args or {}) do
        local offered = {}
        for _, value in ipairs(arg.enum or arg.values or {}) do
          offered[value] = true
        end
        local all = { arg.desc }
        for value, text in pairs(arg.enum_desc or {}) do
          all[#all + 1] = text
          if not offered[value] then stray[#stray + 1] = arg.name .. "=" .. value end
        end
        for _, text in ipairs(all) do
          texts = texts + 1
          if text:find("\n", 1, true) or text:sub(-1) == "." or #text > 80 then
            malformed[#malformed + 1] = text
          end
        end
      end
    end
    check("argument texts were found (cwd mode, cwd scope)", texts >= 11)
    check(
      "argument texts are one line, no trailing period, <= 80 chars",
      #malformed == 0,
      table.concat(malformed, " | ")
    )
    check("argument enum_desc keys are real values", #stray == 0, table.concat(stray, ", "))
  else
    check(
      "every :Filetree flag and argument has a text",
      false,
      "lib.nvim lacks composer.help.undocumented: update lib.nvim"
    )
  end
  commands.teardown()
end

-- ── Repo hygiene: nothing points into the author's private notes vault ───────
-- This repo is public: a reference to the vault's folder or note names (in code, comments, tests or
-- docs alike) is a dead path for every reader. The needles are assembled so this file does not
-- match itself.
do
  local needles = { "wkdbook" .. "-myplugins", "Cascade_Delete" .. "_Assets" }
  -- Not part of the repo: VCS data, checked-out dependencies, parallel git worktrees, and the
  -- generated (git-ignored) module map under docs/map/.
  local skip_dirs =
    { [".git"] = true, [".deps"] = true, [".claude"] = true, ["node_modules"] = true }
  local text_ext =
    { lua = true, md = true, txt = true, json = true, yml = true, yaml = true, toml = true }
  local hits, scanned = {}, 0
  for rel, kind in
    vim.fs.dir(root, {
      depth = 10,
      skip = function(dir)
        return not skip_dirs[dir]
      end,
    })
  do
    local ext = rel:match("%.([%w_]+)$")
    if kind == "file" and ext and text_ext[ext] and not rel:find("^docs/map/") then
      local f = io.open(root .. "/" .. rel, "rb")
      if f then
        local body = f:read("*a")
        f:close()
        scanned = scanned + 1
        for _, needle in ipairs(needles) do
          if body:find(needle, 1, true) then hits[#hits + 1] = rel .. " -> " .. needle end
        end
      end
    end
  end
  check("hygiene: the text files of the repo were scanned", scanned > 100, "scanned " .. scanned)
  check("hygiene: no file refers to the private notes vault", #hits == 0, table.concat(hits, " | "))
end

-- ── Report ────────────────────────────────────────────────────────────────────
print(("\nfiletree.nvim smoke: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq") -- non-zero exit
else
  vim.cmd("qa!")
end
