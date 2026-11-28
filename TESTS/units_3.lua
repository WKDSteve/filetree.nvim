-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
---@diagnostic disable: missing-fields
-- Test doubles here implement only what the unit under test calls -- a full
-- FiletreeAdapter or FiletreeRef would be noise, not coverage.
-- units_3.lua — headless unit tests for filetree.nvim's util layer + adapter helpers.
--
-- Complements TESTS/smoke.lua (which is an integration test over the registry and
-- setup). This file exercises the reusable primitives directly.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/units_3.lua
--
-- Exit 0 = all passed, 1 = a check failed.

-- ":p" resolves to absolute *before* walking up two levels, so `root` stays
-- correct even if a test later changes Neovim's cwd (":h:h" alone would give a
-- path relative to invocation-time cwd, e.g. "." when run as `-l TESTS/units_3.lua`,
-- which breaks require() after any vim.fn.chdir()).
-- `---@diagnostic disable-next-line: duplicate-set-field` appears throughout
-- this file. Every one of them sits on a test double: a stdlib function, a
-- `package.loaded` entry or a platform probe is replaced for the length of one
-- case and put back right after it. Replacing a field LuaLS already knows is
-- exactly what the rule is for, and exactly what a double has to do -- so the
-- suppression is per line rather than per file, and each one marks a swap that
-- is undone a few lines further down.

-- (units.lua was split in three, `units.lua`, `units_2.lua`, `units_3.lua`, so that a run under
-- load stays well below the file limit of the runner; the three share this preamble.)

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
-- lib.nvim is a declared dependency. Candidates in order: $FILETREE_LIB_NVIM,
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
for _, env in ipairs({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
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

-- ui.nvim is a declared dependency too, same reasoning as lib.nvim above:
-- context_menu's require("ui.contextmenu")/require("ui.kit.menu") moved out
-- of lib.nvim.ui.kit/lib.nvim.contextmenu in the 2026-09 migration, so this
-- suite needs ui.nvim findable to exercise the real (non-degraded) path
-- rather than silently falling back to the "unavailable" branch instead.
local ui_candidates = {}
for _, env in ipairs({ "FILETREE_UI_NVIM", "UI_NVIM_PATH" }) do
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

-- filetree's setup() calls lib.nvim's deps.show_once(), whose "seen" flag lives
-- under stdpath("cache") -- on Windows that is $TEMP/nvim even with --clean. A
-- fresh $TEMP (testing.nvim's child sandbox, a new CI runner) therefore pops a
-- focused "external tools" float on the first setup(); its window is
-- 'winfixbuf', so every later :edit/:buffer in the suite dies with E1513.
-- The documented opt-out keeps the suite independent of the cache state.
vim.g.lib_nvim_deps_disable_first_run = true

-- Cross-platform scratch-dir root for the many `tmp = TMP_ROOT .. "/units-*"`
-- fixtures below. $TEMP is Windows-only; POSIX runners (incl. CI) don't set
-- it, which previously hard-errored ("attempt to concatenate a nil value").
--
-- Canonicalized, and that is load-bearing rather than tidiness: on Windows
-- $TEMP is the 8.3 short form (`C:/Users/STEFAN~1/...`) for any profile name
-- over eight characters, while the code under test resolves the same
-- directory to its long form. Comparing a chdir'd `getcwd()` against a path
-- built by concatenating the raw env var then fails on the spelling alone --
-- 41 cases in cwd_mode.lua and 2 here, none of them a real defect.
local TMP_ROOT = vim.env.TEMP or vim.env.TMPDIR or vim.env.TMP or "/tmp"
do
  local uv = vim.uv or vim.loop
  TMP_ROOT = (uv.fs_realpath(TMP_ROOT) or TMP_ROOT):gsub("\\", "/")
end

-- Headless CI runners (no X11/Wayland session) commonly have no clipboard
-- provider at all; without one, "+"/"*" register writes/reads don't
-- round-trip even in-memory. Probe once so clipboard-dependent fixtures
-- below can skip their content assertions rather than fail on an
-- environment limitation unrelated to the feature's own logic.
local _clip_probe = "__filetree_units_clipboard_probe__"
vim.fn.setreg("+", _clip_probe)
local HAS_CLIPBOARD = vim.fn.getreg("+") == _clip_probe
vim.fn.setreg("+", "")
if not HAS_CLIPBOARD then
  print("  note no clipboard provider available — skipping clipboard-content assertions")
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
local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

-- ── trash require_symlink (batched route): run_all_batched also enforces ──
-- the check, not just the single-path do_trash chain -- regression coverage
-- for the exact gap the second ultracode review round flagged: 2+ marked
-- symlinks with the default trash mode go through run_all_batched, which
-- used to skip the TOCTOU re-check entirely.
do
  local tmp = (TMP_ROOT .. "/units-trash-requiresymlink-batch"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local link_a = tmp .. "/a.txt"
  local link_b = tmp .. "/b.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_a = mutate.symlink(tmp .. "/old_a.txt", link_a, false)
  local ok_b = mutate.symlink(tmp .. "/old_b.txt", link_b, false)

  if not (ok_a and ok_b) then
    print(
      "  note trash require_symlink (batch): could not create test symlinks in this environment, skipping"
    )
  else
    -- >1 path with mode="trash" (default) routes run_all through
    -- run_all_batched/send_batch, not the per-path do_trash chain -- stub
    -- the platform layer so this never touches the real OS trash.
    package.loaded["filetree.features.fileops.trash.platform"] = {
      available = function()
        return true
      end,
      send = function(p, cb)
        os.remove(p)
        if cb then cb({ ok = true }) end
      end,
      send_batch = function(paths, cb)
        local results = {}
        for i, p in ipairs(paths) do
          os.remove(p)
          results[i] = { ok = true }
        end
        if cb then cb(results) end
      end,
    }

    local stub = setmetatable({
      name = "units-stub-requiresymlink-batch",
      is_available = function()
        return true
      end,
      get_current_node = function()
        return nil
      end,
      get_winid = function()
        return nil
      end,
      refresh = function()
        return true
      end,
    }, {
      __index = function()
        return function()
          return false
        end
      end,
    })

    local ft = require("filetree")
    ft.register_adapter(stub)
    ft.setup({
      adapter = "units-stub-requiresymlink-batch",
      -- confirm=false: run_all's own batched route, no chooser dialog in
      -- the way -- mode stays the default ("trash"), which is what
      -- actually reaches run_all_batched (permanent delete never batches).
      features = { trash = { enabled = true, confirm = false } },
    })
    local trash = ft.feature("trash")

    -- Same race as the single-path test above, but on ONE of the two
    -- batched paths: link_b gets replaced by a real file before the batch
    -- actually runs. link_a stays a genuine symlink throughout.
    local replaced_content = "real file, must survive untouched"
    vim.fn.delete(link_b)
    vim.fn.writefile({ replaced_content }, link_b)

    trash.delete_current({ paths = { link_a, link_b }, require_symlink = true })
    vim.wait(2000, function()
      return vim.fn.filereadable(link_a) == 0 or (vim.uv or vim.loop).fs_lstat(link_a) == nil
    end, 20)

    check(
      "trash require_symlink (batch): the real file that replaced one symlink survives untouched",
      vim.fn.filereadable(link_b) == 1
        and table.concat(vim.fn.readfile(link_b), "\n") == replaced_content
    )
    check(
      "trash require_symlink (batch): the genuine symlink in the same batch was still removed",
      (vim.uv or vim.loop).fs_lstat(link_a) == nil
    )

    package.loaded["filetree.features.fileops.trash.platform"] = nil
    package.loaded["filetree.features.fileops.trash"] = nil
  end
end

-- ── link_create repair: unsafe-root case fold is Unicode-aware, not just ───
-- ASCII -- regression coverage: Lua's string.lower() only folds ASCII
-- (("BJÖRN"):lower() == "bjÖrn", the Ö untouched), so a case mismatch on a
-- non-ASCII path segment (a Windows profile path with an accented letter,
-- say) would previously slip past the cache/data/state exclusion filter.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-unicodefold"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  -- Build the non-ASCII pair from explicit UTF-8 byte sequences (avoids
  -- encoding the literal accented character awkwardly in this test file).
  local upper_seg = "BJ" .. "\195\150" .. "RN" -- "BJÖRN" (Ö = U+00D6, UTF-8 C3 96)
  local lower_seg = "bj" .. "\195\182" .. "rn" -- "björn" (ö = U+00F6, UTF-8 C3 B6)
  local fake_cache_upper = tmp .. "/" .. upper_seg
  local fake_cache_lower = tmp .. "/" .. lower_seg
  vim.fn.mkdir(fake_cache_lower .. "/undo", "p")
  local unsafe_hit = fake_cache_lower .. "/undo/mangled_undofile"
  vim.fn.writefile({ "garbage" }, unsafe_hit)
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (unicode fold): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      sanitize = function(raw)
        return vim.fs.basename((raw:gsub("\\", "/")))
      end,
      cache_lookup = function(_)
        return {}
      end,
      -- gopath's own root, spelled with the UPPER-case accented letter --
      -- differs from the fake stdpath("cache") below only in that one
      -- non-ASCII character's case.
      guess_roots = function()
        return { fake_cache_upper }
      end,
      suffix_candidates = function(t, _)
        return { t }
      end,
    }
    local captured_items
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(_, _, on_done)
        on_done({ unsafe_hit })
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(items, _, on_choice)
      captured_items = items
      on_choice(nil, nil)
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local platform = require("filetree.util.platform")
    local orig_is_windows = platform.is_windows
    ---@diagnostic disable-next-line: duplicate-set-field
    platform.is_windows = function()
      return true
    end
    local orig_stdpath = vim.fn.stdpath
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.stdpath = function(what)
      if what == "cache" then return fake_cache_lower end -- lower-case accented letter
      return orig_stdpath(what)
    end

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-unicodefold",
      is_available = function()
        return true
      end,
      get_current_node = function()
        return cur_node
      end,
      get_winid = function()
        return nil
      end,
      refresh = function()
        return true
      end,
    }, {
      __index = function()
        return function()
          return false
        end
      end,
    })

    local ft = require("filetree")
    ft.register_adapter(stub)
    ft.setup({
      adapter = "units-stub-linkrepair-unicodefold",
      features = { link_create = { enabled = true, repair_nvim_config_root = false } },
    })
    local lc = ft.feature("link_create")

    lc.repair(link_path)
    vim.fn.stdpath = orig_stdpath
    platform.is_windows = orig_is_windows

    check(
      "link_create repair (unicode fold): a non-ASCII-cased unsafe hit is still filtered out",
      captured_items == nil or not vim.tbl_contains(captured_items, unsafe_hit),
      vim.inspect(captured_items)
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── rename_batch: confirm=true asks kit.confirm (async), not the old ────────
-- blocking `vim.fn.input("...[y/N]...")` freetext prompt.
do
  local tmp = (TMP_ROOT .. "/units-renamebatch-confirm"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local a_old, a_new = tmp .. "/a.txt", tmp .. "/a2.txt"
  vim.fn.writefile({ "a" }, a_old)

  local captured_question
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm"] = function(opts)
    captured_question = opts.question
    opts.on_choice(true) -- confirm the rename
  end
  package.loaded["filetree.features.fileops.rename_batch"] = nil -- reload with stub

  local nodes = { { path = a_old, type = "file" } }
  local stub = setmetatable({
    name = "units-stub-renamebatch-confirm",
    is_available = function()
      return true
    end,
    get_visible_nodes = function()
      return nodes
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-renamebatch-confirm",
    features = { rename_batch = { enabled = true, use_safety = false, confirm = true } },
  })

  ft.feature("rename_batch").open()
  local rb_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(rb_buf, 2, 3, false, { "a2.txt" })
  vim.cmd("write")
  -- The batch awaits its reference scan before renaming anything.
  vim.wait(5000, function()
    return vim.fn.filereadable(a_new) == 1
  end, 20)

  check(
    "rename_batch confirm: util.confirm asked instead of vim.fn.input",
    captured_question ~= nil,
    tostring(captured_question)
  )
  eq("rename_batch confirm: renamed on disk after Yes", vim.fn.filereadable(a_new), 1)

  package.loaded["filetree.util.confirm"] = nil
  package.loaded["filetree.features.fileops.rename_batch"] = nil
end

-- ── copy_move: paste confirm=true asks kit.confirm (async); Cancel pastes ───
-- nothing. Regression for the old blocking `vim.fn.input("...[y/N]...")`.
do
  local tmp = (TMP_ROOT .. "/units-copymove-confirm"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dst", "p")
  vim.fn.writefile({ "hi" }, tmp .. "/file1.txt")

  local captured_question
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm"] = function(opts)
    captured_question = opts.question
    opts.on_choice(false) -- Cancel
  end
  package.loaded["filetree.features.fileops.copy_move"] = nil -- reload with stub

  local cur_node = { path = tmp .. "/file1.txt", type = "file" }
  local stub = setmetatable({
    name = "units-stub-copymove-confirm",
    is_available = function()
      return true
    end,
    get_current_node = function()
      return cur_node
    end,
    get_winid = function()
      return nil
    end,
    get_bufnr = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-copymove-confirm",
    features = { copy_move = { enabled = true, confirm = true, use_safety = false } },
  })

  local cm = ft.feature("copy_move")
  cm.stage_copy()
  cur_node = { path = tmp .. "/dst", type = "directory" }
  cm.paste()

  check(
    "copy_move confirm: util.confirm asked instead of vim.fn.input",
    captured_question ~= nil,
    tostring(captured_question)
  )
  check(
    "copy_move confirm: Cancel means nothing was pasted",
    vim.fn.filereadable(tmp .. "/dst/file1.txt") == 0
  )

  package.loaded["filetree.util.confirm"] = nil
  package.loaded["filetree.features.fileops.copy_move"] = nil
end

-- ── create_from_template: overwrite asks kit.confirm, Cancel keeps original ─
-- Regression for the old blocking `vim.fn.input("...Overwrite? [y/N] ")`.
do
  local tmp = (TMP_ROOT .. "/units-cft-overwrite"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local tdir = tmp .. "/templates"
  vim.fn.mkdir(tdir, "p")
  vim.fn.writefile({ "content" }, tdir .. "/basic.lua")

  local dest_dir = tmp .. "/dest"
  vim.fn.mkdir(dest_dir, "p")
  vim.fn.writefile({ "existing" }, dest_dir .. "/new.lua")

  package.loaded["ui.kit"] = {
    -- `o.items` are create_from_template's own {text, tmpl} rows, not raw
    -- template descriptors: with both a custom and builtin template present
    -- (the repo's shipped builtin/ templates always are), items[1] is the
    -- cosmetic "[custom]" header row, not a pickable template — skip to the
    -- first row that actually carries one.
    select = function(o)
      for _, item in ipairs(o.items) do
        if item.tmpl then
          o.on_select(item, 1)
          return
        end
      end
    end,
    input = function(opts)
      opts.on_submit("new.lua")
    end,
  }

  local captured_question
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm"] = function(opts)
    captured_question = opts.question
    opts.on_choice(false) -- Cancel: do not overwrite
  end
  package.loaded["filetree.util.select"] = nil -- reload so it picks up the stubbed kit
  package.loaded["filetree.features.fileops.create_from_template"] = nil -- reload with stub

  local stub = setmetatable({
    name = "units-stub-cft",
    is_available = function()
      return true
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-cft",
    features = { create_from_template = { enabled = true, template_dir = tdir } },
  })

  local cft = ft.feature("create_from_template")
  cft.open(dest_dir) -- picker resolves synchronously via the stubbed kit.select above

  check(
    "create_from_template overwrite: util.confirm asked instead of vim.fn.input",
    captured_question ~= nil,
    tostring(captured_question)
  )
  check(
    "create_from_template overwrite: Cancel leaves existing content untouched",
    vim.fn.readfile(dest_dir .. "/new.lua")[1] == "existing"
  )

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm"] = nil
  package.loaded["filetree.util.select"] = nil
  package.loaded["filetree.features.fileops.create_from_template"] = nil
end

-- ── create_from_template: pickers.nvim dispatch (prefer, Pickers.Item) ──────
do
  local tmp = (TMP_ROOT .. "/units-cft-pickers"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local tdir = tmp .. "/templates"
  vim.fn.mkdir(tdir, "p")
  vim.fn.writefile({ "content" }, tdir .. "/basic.lua")

  local dest_dir = tmp .. "/dest"
  vim.fn.mkdir(dest_dir, "p")

  local stub = setmetatable({
    name = "units-stub-cft-pickers",
    is_available = function()
      return true
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  -- prefer = "auto" (default): dispatches through pickers.engines.load(),
  -- items carry {text, file, tmpl} and on_select unwraps .tmpl.
  do
    local captured_prefer, captured_items
    package.loaded["pickers.engines"] = {
      load = function(prefer)
        captured_prefer = prefer
        return {
          pick_item = function(o)
            captured_items = o.items
            o.on_select(o.items[1]) -- pick the first template
          end,
        }
      end,
    }
    package.loaded["ui.kit"] = {
      input = function(opts)
        opts.on_submit("new.lua")
      end,
    }
    package.loaded["filetree.features.fileops.create_from_template"] = nil

    local ft = require("filetree")
    ft.register_adapter(stub)
    ft.setup({
      adapter = "units-stub-cft-pickers",
      features = { create_from_template = { enabled = true, template_dir = tdir } },
    })

    local cft = ft.feature("create_from_template")
    cft.open(dest_dir)

    check(
      'pickers dispatch: prefer defaults to "auto"',
      captured_prefer == "auto",
      tostring(captured_prefer)
    )
    check(
      "pickers dispatch: item carries display text",
      captured_items ~= nil and captured_items[1].text == "basic.lua"
    )
    check(
      "pickers dispatch: item carries the template's file path",
      captured_items ~= nil and captured_items[1].file == tdir .. "/basic.lua"
    )
    check(
      "pickers dispatch: selecting created the file from the template",
      vim.fn.filereadable(dest_dir .. "/new.lua") == 1
        and vim.fn.readfile(dest_dir .. "/new.lua")[1] == "content"
    )
  end

  -- prefer = "builtin": pickers.engines.load() must never be called; falls
  -- through to the pre-existing kit.picker/ui_select flow unchanged.
  do
    vim.fn.delete(dest_dir .. "/new2.lua")
    local pickers_called = false
    package.loaded["pickers.engines"] = {
      load = function()
        pickers_called = true
        return nil
      end,
    }
    package.loaded["ui.kit"] = {
      -- Same reasoning as the overwrite test above: skip the "[custom]"
      -- header row and pick the first row that actually carries a template.
      select = function(o)
        for _, item in ipairs(o.items) do
          if item.tmpl then
            o.on_select(item, 1)
            return
          end
        end
      end,
      input = function(opts)
        opts.on_submit("new2.lua")
      end,
    }
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.create_from_template"] = nil

    local ft = require("filetree")
    ft.setup({
      adapter = "units-stub-cft-pickers",
      features = {
        create_from_template = { enabled = true, template_dir = tdir, prefer = "builtin" },
      },
    })
    local cft = ft.feature("create_from_template")
    cft.open(dest_dir)

    check(
      'pickers dispatch: prefer="builtin" never calls pickers.engines.load',
      pickers_called == false
    )
    check(
      'pickers dispatch: prefer="builtin" still creates the file (fallback path)',
      vim.fn.filereadable(dest_dir .. "/new2.lua") == 1
    )
  end

  -- Both sub-blocks above stub ui.kit with an incomplete table (only
  -- `.input`/`.select`, no `.confirm`). create_from_template's own module-level
  -- `require("filetree.util.confirm")` captures whatever `kit` is live THE
  -- MOMENT it is first (re)loaded, and caches it — so unless that cache is
  -- invalidated too, any later feature calling confirm.lua (e.g. trash) would
  -- permanently get our incomplete stub and crash on `kit.confirm(...)`.
  package.loaded["pickers.engines"] = nil
  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.select"] = nil
  package.loaded["filetree.util.confirm"] = nil
  package.loaded["filetree.features.fileops.create_from_template"] = nil
end

-- ── open_in_fm: target resolution + reuse_existing dispatch ─────────────────
-- Regression coverage for a feature that previously had ZERO logic tests: it
-- only checked that a process STARTED, never that it succeeded — this is what
-- made an intermittent real-world failure look like it had "no pattern."
-- The platform dispatch now lives in lib.nvim.cross.reveal_in_fm (shared with
-- open.nvim), so what is tested here is what this module still decides: which
-- path is handed over, and with which options.
do
  local platform = require("filetree.util.platform")
  local tmp_dir = (TMP_ROOT .. "/units-open-in-fm"):gsub("\\", "/")
  vim.fn.mkdir(tmp_dir, "p")
  local tmp_file = tmp_dir .. "/node.txt"
  vim.fn.writefile({ "x" }, tmp_file)

  local node_path = tmp_dir
  local stub_adapter = {
    get_current_node = function()
      return { path = node_path }
    end,
  }

  local orig_is_windows = platform.is_windows
  ---@diagnostic disable-next-line: duplicate-set-field
  platform.is_windows = function()
    return true
  end

  -- Stub the shared dispatcher: its own platform behavior is lib.nvim's to
  -- test, and stubbing keeps these checks host-independent.
  local orig_reveal_mod = package.loaded["lib.nvim.cross.reveal_in_fm"]
  ---@type { target: string, opts: table }|nil
  local captured
  package.loaded["lib.nvim.cross.reveal_in_fm"] = function(target, opts)
    captured = { target = target, opts = opts or {} }
    return true, nil
  end

  local function reload()
    package.loaded["filetree.features.system.open_in_fm"] = nil
    return require("filetree.features.system.open_in_fm")
  end

  local open_in_fm = reload()
  open_in_fm.setup({ enabled = true }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: directory node is handed over as-is", captured.target == tmp_dir)
  check("open_in_fm: reveal defaults to true", captured.opts.reveal == true)
  check("open_in_fm: no command override by default", captured.opts.command == nil)

  node_path = tmp_file
  open_in_fm = reload()
  open_in_fm.setup({ enabled = true }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check(
    "open_in_fm: file node keeps the FILE path (so it can be selected)",
    captured.target == tmp_file
  )

  open_in_fm = reload()
  open_in_fm.setup({ enabled = true, reveal = false, command = "thunar" }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: reveal=false is forwarded", captured.opts.reveal == false)
  check("open_in_fm: command override is forwarded", captured.opts.command == "thunar")

  -- A node whose path no longer exists falls back to its parent directory:
  -- there is nothing to select there.
  node_path = tmp_dir .. "/gone/deleted.txt"
  open_in_fm = reload()
  open_in_fm.setup({ enabled = true }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: nonexistent node falls back to a directory", captured.target ~= node_path)

  -- reuse_existing is no longer decided here: it is forwarded as an option, so
  -- the reuse and the raise happen in one step inside the shared dispatcher.
  -- The old in-module pre-step returned "reused" without ever bringing the
  -- window forward, which Windows silently refuses for a background process.
  node_path = tmp_dir

  open_in_fm = reload()
  open_in_fm.setup({ enabled = true, reuse_existing = true }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: reuse_existing=true is forwarded as reuse", captured.opts.reuse == true)
  check(
    "open_in_fm: reuse_existing=true still reaches the shared dispatcher",
    captured.target == tmp_dir
  )

  open_in_fm = reload()
  open_in_fm.setup({ enabled = true }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: reuse defaults to false", captured.opts.reuse == false)

  -- A launcher override names the program, so there is no Explorer window to
  -- reuse — reuse must not be forwarded alongside it.
  open_in_fm = reload()
  open_in_fm.setup({ enabled = true, reuse_existing = true, command = "thunar" }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: a command override suppresses reuse", captured.opts.reuse == false)

  -- Reuse is Explorer-specific COM automation; off-Windows it must not be sent.
  ---@diagnostic disable-next-line: duplicate-set-field
  platform.is_windows = function()
    return false
  end
  open_in_fm = reload()
  open_in_fm.setup({ enabled = true, reuse_existing = true }, stub_adapter)
  captured = nil
  open_in_fm.open()
  assert(captured, "the reveal dispatcher was not called")
  check("open_in_fm: reuse is not forwarded off Windows", captured.opts.reuse == false)

  platform.is_windows = orig_is_windows
  package.loaded["lib.nvim.cross.reveal_in_fm"] = orig_reveal_mod
  package.loaded["filetree.features.system.open_in_fm"] = nil
end

-- ── no_name_guard: tab-wide sweep on BufAdd/BufDelete/BufWipeout ────────────
-- Regression coverage for a real, previously-untested gap: a stray [No Name]
-- buffer sitting in a window that never itself refires BufWinEnter (so the
-- existing single-pair `handle()` never revisits it) used to persist
-- indefinitely even with real, usable buffers open elsewhere.
do
  vim.cmd("only")
  local real_path = (TMP_ROOT .. "/units-no-name-guard-real.txt"):gsub("\\", "/")
  vim.fn.writefile({ "x" }, real_path)
  vim.cmd("edit " .. vim.fn.fnameescape(real_path))

  vim.cmd("vsplit")
  local no_name_win = vim.api.nvim_get_current_win()
  vim.cmd("enew") -- fresh [No Name] buffer in THIS window only
  local no_name_buf = vim.api.nvim_win_get_buf(no_name_win)

  check(
    "no_name_guard setup: second window really is a stray No Name buffer",
    vim.api.nvim_buf_get_name(no_name_buf) == "" and vim.bo[no_name_buf].buftype == ""
  )

  local stub_adapter = setmetatable({
    name = "units-stub-no-name-guard",
    is_available = function()
      return true
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub_adapter)
  ft.setup({
    adapter = "units-stub-no-name-guard",
    features = { no_name_guard = { enabled = true } },
  })

  -- The sweep doesn't care which buffer/event triggered it, only that the
  -- buffer list changed -- fire BufAdd on something unrelated.
  vim.cmd("badd " .. vim.fn.fnameescape(vim.fn.tempname()))
  vim.wait(50)

  check(
    "no_name_guard sweep: the No Name window was redirected to a real buffer",
    vim.api.nvim_win_get_buf(no_name_win) ~= no_name_buf
  )
  check(
    "no_name_guard sweep: the stray buffer itself was wiped",
    not vim.api.nvim_buf_is_valid(no_name_buf)
  )

  pcall(vim.api.nvim_win_close, no_name_win, true)
  vim.cmd("only")
end

-- ── open_variants: sg/sv/st/gb/<S-CR> are all bound ──────────────────────────
do
  local cur_node = { path = (TMP_ROOT .. "/units-openvariants.txt"):gsub("\\", "/"), type = "file" }
  vim.fn.writefile({ "x" }, cur_node.path)
  local stub = setmetatable({
    name = "units-stub4",
    is_available = function()
      return true
    end,
    get_current_node = function()
      return cur_node
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub4",
    features = {
      open_variants = { enabled = true },
      no_name_guard = { enabled = false }, -- see note on earlier keymap tests
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "neo-tree"
  vim.wait(200, function()
    return false
  end)

  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end
  check("open_variants: 'sg' bound", km["sg"] ~= nil)
  check("open_variants: 'sv' bound", km["sv"] ~= nil)
  check("open_variants: 'st' bound", km["st"] ~= nil)
  check("open_variants: 'gb' bound", km["gb"] ~= nil)
  check("open_variants: '<S-CR>' bound", km["<S-CR>"] ~= nil)

  local ov = ft.feature("open_variants")
  ov.open_badd()
  check(
    "open_variants: open_badd() adds the file to the buffer list",
    vim.fn.bufnr(cur_node.path) ~= -1
  )
end

-- ── open_variants: <S-CR> on a directory collapses instead of badd ──────────
do
  local dir_node =
    { path = (TMP_ROOT .. "/units-openvariants-dir"):gsub("\\", "/"), type = "directory" }
  vim.fn.mkdir(dir_node.path, "p")
  local collapse_calls = {}
  local stub = setmetatable({
    name = "units-stub4b",
    is_available = function()
      return true
    end,
    get_current_node = function()
      return dir_node
    end,
    collapse_node = function(node)
      collapse_calls[#collapse_calls + 1] = node
      return true
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub4b",
    features = {
      open_variants = { enabled = true },
      no_name_guard = { enabled = false },
    },
  })

  local ov = ft.feature("open_variants")
  ov.open_badd_or_collapse()
  check(
    "open_variants: <S-CR> on a directory calls adapter.collapse_node()",
    #collapse_calls == 1 and collapse_calls[1].path == dir_node.path
  )
  check(
    "open_variants: <S-CR> on a directory does not add it to the buffer list",
    vim.fn.bufnr(dir_node.path) == -1
  )
end

-- ── markdown_links: current/recursive/marked all produce "[name](path)" ─────
do
  local tmp = (TMP_ROOT .. "/units-mdlinks"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/sub", "p")
  vim.fn.writefile({ "x" }, tmp .. "/a.lua")
  vim.fn.writefile({ "x" }, tmp .. "/sub/b.lua")
  vim.fn.chdir(tmp)

  local cur_node = { path = tmp .. "/a.lua", type = "file" }
  local stub = setmetatable({
    name = "units-stub5",
    is_available = function()
      return true
    end,
    get_current_node = function()
      return cur_node
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({ adapter = "units-stub5", features = { markdown_links = { enabled = true } } })

  local md = ft.feature("markdown_links")
  local ok_cur = pcall(md.link_current)
  check("markdown_links: link_current() does not error", ok_cur)
  if HAS_CLIPBOARD then
    check(
      "markdown_links: link_current() copies '[a.lua](a.lua)'",
      vim.fn.getreg("+") == "[a.lua](a.lua)",
      vim.fn.getreg("+")
    )
  end

  cur_node = { path = tmp, type = "directory" }
  local ok_rec = pcall(md.link_recursive)
  check("markdown_links: link_recursive() does not error", ok_rec)
  if HAS_CLIPBOARD then
    local recursive_reg = vim.fn.getreg("+")
    check(
      "markdown_links: link_recursive() includes the top-level file",
      recursive_reg:find("[a.lua](a.lua)", 1, true) ~= nil,
      recursive_reg
    )
    check(
      "markdown_links: link_recursive() includes the nested file",
      recursive_reg:find("b.lua", 1, true) ~= nil,
      recursive_reg
    )
  end

  -- ── MI: INSERT into the window we came from, cursor into the link ──
  vim.fn.mkdir(tmp .. "/docs", "p")
  vim.fn.writefile({ "intro" }, tmp .. "/docs/note.md")
  ft.setup({
    adapter = "units-stub5",
    features = {
      markdown_links = { enabled = true, cursor = { startinsert = false }, insert_path = "buffer" },
    },
  })
  md = ft.feature("markdown_links")

  vim.cmd("only")
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/docs/note.md"))
  local editor_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.cmd("enew") -- stands in for the tree window: we came FROM editor_win
  vim.bo.filetype = "neo-tree" -- a real tree window is a sidebar, never an insertion target
  local tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(editor_win)
  vim.api.nvim_win_set_cursor(editor_win, { 1, 5 })
  vim.api.nvim_set_current_win(tree_win)

  cur_node = { path = tmp .. "/sub/b.lua", type = "file" }
  check("markdown_links: insert_current() does not error", pcall(md.insert_current))
  local edited = vim.api.nvim_win_get_buf(editor_win)
  local text = table.concat(vim.api.nvim_buf_get_lines(edited, 0, -1, false), "\n")
  check(
    "markdown_links: MI writes a link relative to the TARGET buffer, inline at its cursor",
    text == "intr[b.lua](../sub/b.lua)o", -- a normal-mode cursor sits at most on the last character
    text
  )
  check(
    "markdown_links: MI leaves the cursor in the path of the filled link, in the editor window",
    vim.api.nvim_get_current_win() == editor_win
      and vim.api.nvim_win_get_cursor(editor_win)[2] == 24,
    vim.inspect(vim.api.nvim_win_get_cursor(editor_win))
  )

  -- A directory path with a trailing separator must not give an empty title.
  check(
    "markdown_links: a directory with a trailing slash still gets a title",
    (function()
      local links = ft.feature("markdown_links").build_insert_links({ tmp .. "/sub/" }, edited)
      return links[1]:match("^%[sub%]%(") ~= nil
    end)(),
    vim.inspect(ft.feature("markdown_links").build_insert_links({ tmp .. "/sub/" }, edited))
  )

  -- Typed in the editor (not from the tree): the CURRENT window gets the link, not
  -- whichever split was visited before.
  do
    vim.cmd("only")
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.cmd("enew")
    vim.api.nvim_set_current_win(editor_win)
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "intro" })
    vim.api.nvim_win_set_cursor(editor_win, { 1, 0 })
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_set_current_win(editor_win) -- previous window is now `other`
    cur_node = { path = tmp .. "/sub/b.lua", type = "file" }
    pcall(md.insert_current)
    local got = table.concat(vim.api.nvim_buf_get_lines(edited, 0, -1, false), "\n")
    check(
      "markdown_links: inserted into the current editing window, not the previously visited split",
      got:find("[b.lua](", 1, true) ~= nil,
      got
    )
  end

  if vim.fn.has("win32") == 1 then
    check(
      "markdown_links: a directory with a trailing backslash still gets a title (Windows)",
      ft.feature("markdown_links")
        .build_insert_links({ ((tmp .. "/sub/"):gsub("/", "\\")) }, edited)[1]
        :match("^%[sub%]%(") ~= nil
    )
  end

  check(
    "markdown_links: insert_path = absolute",
    (function()
      ft.setup({
        adapter = "units-stub5",
        features = {
          markdown_links = {
            enabled = true,
            insert_path = "absolute",
            cursor = { startinsert = false },
          },
        },
      })
      local links = ft.feature("markdown_links").build_insert_links({ tmp .. "/a.lua" }, edited)
      return links[1] == "[a.lua](" .. tmp .. "/a.lua)"
    end)()
  )
  check(
    "markdown_links: insert_path = env folds a known root, else falls back to the buffer path",
    (function()
      vim.env.FT_TEST_ROOT = tmp
      ft.setup({
        adapter = "units-stub5",
        features = {
          markdown_links = { enabled = true, insert_path = "env", env_roots = { "FT_TEST_ROOT" } },
        },
      })
      local m = ft.feature("markdown_links")
      local inside = m.build_insert_links({ tmp .. "/a.lua" }, edited)[1]
      local outside =
        m.build_insert_links({ vim.fn.stdpath("data") .. "/zz-none/x.lua" }, edited)[1]
      vim.env.FT_TEST_ROOT = nil
      return inside == "[a.lua]($FT_TEST_ROOT/a.lua)" and outside:find("%$FT_TEST_ROOT") == nil
    end)()
  )

  vim.cmd("only")
end

-- ── config.confirmations: boolean shorthand + per-action table ──────────────
-- explicit per-feature `confirm` always wins over the top-level switch.
do
  local config = require("filetree.config")

  config.setup({ adapter = "stub", confirmations = false })
  local cfg = config.get()
  check("confirmations=false: copy_move.confirm is false", cfg.features.copy_move.confirm == false)
  check("confirmations=false: trash.confirm is false", cfg.features.trash.confirm == false)
  check(
    "confirmations=false: rename_batch.confirm is false",
    cfg.features.rename_batch.confirm == false
  )

  config.setup({ adapter = "stub", confirmations = { paste = false, delete = true } })
  cfg = config.get()
  check(
    "confirmations table: paste -> copy_move.confirm false",
    cfg.features.copy_move.confirm == false
  )
  check("confirmations table: delete -> trash.confirm true", cfg.features.trash.confirm == true)
  check(
    "confirmations table: rename_batch untouched (nil, not in table)",
    cfg.features.rename_batch == nil or cfg.features.rename_batch.confirm == nil
  )

  config.setup({
    adapter = "stub",
    confirmations = true,
    features = { trash = { confirm = false } },
  })
  cfg = config.get()
  check(
    "explicit features.trash.confirm=false wins over confirmations=true",
    cfg.features.trash.confirm == false
  )
  check(
    "confirmations=true still applies to copy_move (not explicitly set)",
    cfg.features.copy_move.confirm == true
  )
end

-- ── config: unknown option / wrongly-typed value (ERR-50 / ERR-22) ─────────
-- Validated BEFORE the merge: an unrecognized top-level key or feature name
-- is dropped and reported via issues(), never silently merged into the
-- active config; a wrongly-typed adapter/features falls back to its default
-- instead of surviving into `_active`.
do
  local config = require("filetree.config")

  config.setup({ adaptor = "neotree" }) -- typo: "adaptor"
  local cfg = config.get()
  eq("unknown top-level key: adapter keeps its default", cfg.adapter, "auto")
  check("unknown top-level key: reported in issues()", #config.issues() > 0)
  local joined = table.concat(config.issues(), "\n")
  check(
    "unknown top-level key: message names the typo and a did-you-mean hint",
    joined:find("adaptor", 1, true) ~= nil and joined:find("adapter", 1, true) ~= nil,
    joined
  )

  config.setup({ features = { auto_reaveal = { enabled = false } } }) -- typo: "auto_reaveal"
  check("unknown feature name: reported in issues()", #config.issues() > 0)
  joined = table.concat(config.issues(), "\n")
  check(
    "unknown feature name: message names the typo and a did-you-mean hint",
    joined:find("auto_reaveal", 1, true) ~= nil and joined:find("auto_reveal", 1, true) ~= nil,
    joined
  )

  config.setup({ adapter = 0 })
  cfg = config.get()
  eq("wrongly-typed adapter falls back to its default", cfg.adapter, "auto")
  check("wrongly-typed adapter reported in issues()", #config.issues() > 0)

  config.setup({ features = "all" })
  cfg = config.get()
  check("wrongly-typed features falls back to a table", type(cfg.features) == "table")
  check("wrongly-typed features reported in issues()", #config.issues() > 0)

  -- A clean setup() call clears the previous call's issues.
  config.setup({ adapter = "stub" })
  eq("issues() cleared after a clean setup()", #config.issues(), 0)

  -- filetree.setup() itself never aborts over a wrongly-typed value: it
  -- completes (is_initialized() true) with the degraded default instead.
  local ft = require("filetree")
  local stub = setmetatable({
    name = "units-stub-err22",
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
  ft.register_adapter(stub)
  local ok_setup = pcall(ft.setup, { adapter = "units-stub-err22", features = "all" })
  check("filetree.setup() does not error on a wrongly-typed features value", ok_setup)
  check("filetree.setup() completes (does not abort) on a wrongly-typed value", ft.is_initialized())

  -- cfg.adapter must reflect the adapter that actually ended up active after
  -- the "unresolvable name -> fall back to auto" path (regression: it used
  -- to keep the unresolvable name forever, so health.lua's "Configuration
  -- loaded (adapter = ...)" line kept reporting a name nothing was running,
  -- masking that the fallback had happened at all). "auto" always resolves
  -- to "netrw" here (no other adapter plugin is on rtp in this suite, and
  -- netrw is always available -- built in) -- pin an inert stub under that
  -- exact name first, the same no-op-metatable double used throughout this
  -- file, so the real netrw adapter's real implementation never actually
  -- runs against the rest of this shared test process; only the fallback
  -- bookkeeping in filetree.setup() itself is under test here.
  local adapter_mod = require("filetree.adapter")
  adapter_mod.register(setmetatable({
    name = "netrw",
    is_available = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  }))
  local ok_setup2 = pcall(
    ft.setup,
    { adapter = "totally-bogus-adapter-xyz", features = { size_info = { enabled = false } } }
  )
  check("config.adapter fallback: setup() still completes", ok_setup2 and ft.is_initialized())
  cfg = config.get()
  check(
    "config.adapter fallback: does not keep the unresolvable name that was asked for",
    cfg.adapter ~= "totally-bogus-adapter-xyz"
  )
  eq(
    "config.adapter fallback: cfg.adapter matches the adapter that actually ended up active",
    cfg.adapter,
    ft.adapter().name
  )
end

-- ── config: nested unknown key / degraded value (ERR-50 / ERR-22) ──────────
-- sanitize() recurses one level into `menu` and validates every
-- `features.<name>` body against that feature's SCHEMA -- a typo there used to
-- vanish into the default with zero diagnostic (ERR-50). Separately, normalize_values()
-- degrades a handful of numeric/string fields whose only prior guard was
-- `x or default` (catches nil, nothing else) before they reach a consumer
-- that throws on the wrong type (ERR-22).
do
  local config = require("filetree.config")

  -- ERR-50: a typo inside a feature body is caught by full
  -- dotted path, and the real option keeps its default -- not silently
  -- dropped into the merged config as a dead field.
  config.setup({ features = { cwd_sync = { enabled = true, dedounce_ms = 300 } } })
  local cfg = config.get()
  eq(
    "nested feature typo: the real option (debounce_ms) keeps its default",
    cfg.features.cwd_sync.debounce_ms,
    150
  )
  check(
    "nested feature typo: the typo'd key does not leak into the active config",
    cfg.features.cwd_sync.dedounce_ms == nil
  )
  local joined = table.concat(config.issues(), "\n")
  check(
    "nested feature typo: message carries the FULL dotted path, not just the bare key",
    joined:find("features.cwd_sync.dedounce_ms", 1, true) ~= nil,
    joined
  )

  -- ERR-50: same one-level recursion for `menu`.
  config.setup({ menu = { fielops = true } })
  joined = table.concat(config.issues(), "\n")
  check(
    "menu typo: reported by full dotted path",
    joined:find("menu.fielops", 1, true) ~= nil,
    joined
  )

  -- ERR-22: a wrong-type numeric field degrades to its documented default
  -- instead of surviving into `_active` to crash a debounce timer / a numeric
  -- `for` limit / a bare length comparison downstream.
  config.setup({
    features = {
      layout_guard = { enabled = true, delay_ms = true }, -- boolean, not a number
      cwd_sync = { enabled = true, debounce_ms = {}, parent_levels = "abc" },
      current_hl = { enabled = true, debounce_ms = -5 }, -- negative
      safety = { enabled = true, max_backups = "5", backup_dir = {} },
    },
    refs = { scan = { max_files = true, timeout_ms = 0 } },
  })
  cfg = config.get()
  eq(
    "ERR-22: layout_guard.delay_ms (boolean) degrades to its default",
    cfg.features.layout_guard.delay_ms,
    50
  )
  eq(
    "ERR-22: cwd_sync.debounce_ms (table) degrades to its default",
    cfg.features.cwd_sync.debounce_ms,
    150
  )
  eq(
    "ERR-22: cwd_sync.parent_levels (string) degrades to its default",
    cfg.features.cwd_sync.parent_levels,
    0
  )
  eq(
    "ERR-22: current_hl.debounce_ms (negative) degrades to its default",
    cfg.features.current_hl.debounce_ms,
    100
  )
  eq(
    "ERR-22: safety.max_backups (numeric string) degrades to its default",
    cfg.features.safety.max_backups,
    5
  )
  check(
    "ERR-22: safety.backup_dir (table) degrades to nil (the documented default)",
    cfg.features.safety.backup_dir == nil
  )
  eq("ERR-22: refs.scan.max_files (boolean) degrades to its default", cfg.refs.scan.max_files, 5000)
  eq("ERR-22: refs.scan.timeout_ms (zero) degrades to its default", cfg.refs.scan.timeout_ms, 3000)
  check(
    "ERR-22: every degraded value is reported in issues()",
    #config.issues() >= 8,
    table.concat(config.issues(), "\n")
  )

  -- The consumers themselves must not throw once the config holds the
  -- degraded value -- the actual crash sites this fix closes.
  local debounce = require("lib.nvim.debounce")
  local ok_debounce = pcall(function()
    local d = debounce.new(function() end, cfg.features.cwd_sync.debounce_ms)
    d.call()
  end)
  check(
    "ERR-22: lib.nvim.debounce.call() no longer throws on the degraded debounce_ms",
    ok_debounce
  )
  local ok_defer = pcall(vim.defer_fn, function() end, cfg.features.layout_guard.delay_ms)
  check("ERR-22: vim.defer_fn() no longer throws on the degraded delay_ms", ok_defer)
  local ok_forloop = pcall(function()
    for _ = 1, cfg.features.cwd_sync.parent_levels do
    end
  end)
  check("ERR-22: the parent_levels for-loop no longer throws on the degraded value", ok_forloop)
  local ok_cmp = pcall(function()
    return 7 > cfg.features.safety.max_backups
  end)
  check("ERR-22: the max_backups comparison no longer throws on the degraded value", ok_cmp)

  config.setup({ adapter = "stub" }) -- reset for the suites that follow
end

-- ── trash: default (no confirmations config at all) DOES prompt ────────────
-- End-to-end check of the *actual* out-of-the-box default, not just what
-- config.get() reports: with nothing set, delete_current() must prompt before
-- deleting (now via the util.confirm info popup, not native vim.fn.confirm).
-- trash is deliberately the one confirmable action that defaults to
-- confirm=true (copy_move/rename_batch stay confirm=false) -- see the comment
-- on trash/init.lua's _cfg.confirm.
do
  local tmp = (TMP_ROOT .. "/units-trash-noconfirm"):gsub("\\", "/")
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "x" }, tmp .. "/victim2.txt")

  local cur_node = { path = tmp .. "/victim2.txt", type = "file" }
  local stub = setmetatable({
    name = "units-stub6",
    is_available = function()
      return true
    end,
    get_current_node = function()
      return cur_node
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  -- Force a fresh module load: trash's `_cfg` is a module-level table that
  -- earlier test blocks in this same process have already called setup() on
  -- with an explicit `confirm = false`, and setup() merges onto the existing
  -- _cfg rather than resetting to the module's literal default table -- so
  -- without this, this test would silently inherit that earlier confirm=false
  -- instead of exercising the actual shipped default.
  package.loaded["filetree.features.fileops.trash"] = nil

  local ft = require("filetree")
  ft.register_adapter(stub)
  -- No `confirm`/`confirmations` anywhere -- purely the shipped default.
  ft.setup({ adapter = "units-stub6", features = { trash = { enabled = true, dry_run = true } } })

  -- The shipped default confirms; a single delete now opens the nice info
  -- popup (util.confirm float) rather than the native vim.fn.confirm prompt.
  local confirm_called = false
  local orig_confirm = vim.fn.confirm
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.confirm = function(...)
    confirm_called = true
    return 1
  end
  local floats_before = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then floats_before = floats_before + 1 end
  end
  ft.feature("trash").delete_current()
  -- The popup only appears once the reference scan that decides which dialog
  -- to draw has finished.
  local function any_float()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then return true end
    end
    return false
  end
  vim.wait(5000, any_float, 20)
  vim.fn.confirm = orig_confirm

  local confirm_float = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then confirm_float = w end
  end
  check(
    "trash: default confirm opens a popup, not the native vim.fn.confirm",
    confirm_float ~= nil and not confirm_called
  )
  eq(
    "trash: file not yet deleted while the confirm popup is open",
    vim.fn.filereadable(tmp .. "/victim2.txt"),
    1
  )
  if confirm_float then pcall(vim.api.nvim_win_close, confirm_float, true) end
end

-- ── trash.undo: Windows restore reports real failure, not silent success ────
-- Regression for a bug where InvokeVerb('restore') is a *localized* verb
-- caption (e.g. German "Wiederherstellen") -- on any non-English Windows it
-- silently matched nothing, yet the script still exited 0, so restore_last()
-- reported success and dropped the history entry despite restoring nothing.
do
  package.loaded["filetree.features.fileops.trash.undo"] = nil
  local undo = require("filetree.features.fileops.trash.undo")

  -- restore_windows() starts PowerShell in the background through `undo._run` (it wraps
  -- lib.nvim.cross.run_argv.run_async_captured). An earlier version of this test mocked
  -- os.execute, which the code has never called: every case then spawned a real PowerShell
  -- against the real Recycle Bin and got exit code 1 by accident. Replace the seam the code really
  -- calls; the stand-in answers at once, so each restore below has its outcome on return.
  local orig_run = undo._run
  local captured_cmd

  local function with_exit_code(code, fn)
    undo._run = function(cmd, cb)
      captured_cmd = cmd[#cmd] -- the PowerShell script is the last argv element
      cb(code == 0, "", code)
    end
    local ok, err = fn()
    undo._run = orig_run
    return ok, err
  end

  local function restore_now(e)
    local got_ok, got_err
    undo.restore(e, function(o, er)
      got_ok, got_err = o, er
    end)
    return got_ok, got_err
  end

  local entry = {
    original_path = "C:/Users/x/project/victim.txt",
    name = "victim.txt",
    trashed_at = "2026-01-01 00:00:00",
    platform = "windows",
  }

  local ok1, err1 = with_exit_code(1, function()
    return restore_now(entry)
  end)
  check(
    "trash.undo: exit 1 (not found) is reported as failure, not success",
    ok1 == false and err1 ~= nil and err1:find("not found") ~= nil,
    tostring(err1)
  )

  local ok2, err2 = with_exit_code(2, function()
    return restore_now(entry)
  end)
  check(
    "trash.undo: exit 2 (move and verb fallback both failed) is reported as failure, not success",
    ok2 == false and err2 ~= nil and err2:find("could not move", 1, true) ~= nil,
    tostring(err2)
  )

  local ok3, err3 = with_exit_code(3, function()
    return restore_now(entry)
  end)
  check(
    "trash.undo: exit 3 (target already exists) is reported as failure, not success",
    ok3 == false and err3 ~= nil and err3:find("already exists", 1, true) ~= nil,
    tostring(err3)
  )

  local ok4 = with_exit_code(0, function()
    return restore_now(entry)
  end)
  check("trash.undo: exit 0 is reported as success", ok4 == true)

  check(
    "trash.undo: generated PowerShell command matches by DeletedFrom, not just Name",
    captured_cmd ~= nil and captured_cmd:find("DeletedFrom", 1, true) ~= nil
  )
  check(
    "trash.undo: generated PowerShell command restores via a locale-free Move-Item first",
    captured_cmd ~= nil and captured_cmd:find("Move-Item", 1, true) ~= nil,
    tostring(captured_cmd)
  )
  check(
    "trash.undo: generated PowerShell command still keeps the verb-caption fallback (incl. German)",
    captured_cmd ~= nil and captured_cmd:find("Wiederherstellen", 1, true) ~= nil
  )
  check(
    "trash.undo: generated PowerShell command targets the original path",
    captured_cmd ~= nil and captured_cmd:find("C:\\Users\\x\\project\\victim.txt", 1, true) ~= nil,
    tostring(captured_cmd)
  )
end

-- ── project_root: caches per-directory, populates intermediate dirs too ─────
do
  package.loaded["filetree.features.infra.project_root"] = nil
  local proot = require("filetree.features.infra.project_root")

  local tmp = (TMP_ROOT .. "/units-projectroot"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/proj/.git", "p")
  vim.fn.mkdir(tmp .. "/proj/src/deep/nested", "p")
  vim.fn.writefile({ "x" }, tmp .. "/proj/src/deep/nested/file.lua")

  proot.setup({ enabled = true }, { name = "stub" })
  proot.clear_cache()

  local root1 = proot.find(tmp .. "/proj/src/deep/nested/file.lua")
  eq(
    "project_root: finds .git root from a deeply nested file",
    root1:gsub("\\", "/"),
    tmp .. "/proj"
  )

  -- An intermediate directory passed on the same walk should now be cached
  -- too, without needing its own filesystem walk.
  local root2 = proot.find(tmp .. "/proj/src/deep")
  eq(
    "project_root: intermediate directory resolves to the same cached root",
    root2:gsub("\\", "/"),
    tmp .. "/proj"
  )

  -- Simulate a real cache hit: remove the .git dir on disk: if find() still
  -- returns the project root, it proved the cached value was used rather
  -- than a fresh (now-negative) filesystem walk.
  vim.fn.delete(tmp .. "/proj/.git", "d")
  local root3 = proot.find(tmp .. "/proj/src/deep/nested/file.lua")
  eq(
    "project_root: cache hit survives the marker being removed from disk",
    root3:gsub("\\", "/"),
    tmp .. "/proj"
  )

  proot.clear_cache()
  local root4 = proot.find(tmp .. "/proj/src/deep/nested/file.lua")
  check(
    "project_root: clear_cache() forces a fresh walk (marker now gone)",
    root4:gsub("\\", "/") ~= tmp .. "/proj"
  )

  -- Glob-shaped marker ("*.rockspec", the only one in the default list) --
  -- previously fed the directory path straight into vim.fn.glob as part of
  -- the pattern (XP-01); now routed through lib.nvim.fs.globbable first.
  -- Not the exact Windows 8.3-short-name repro (not portably constructible
  -- here), but this exercises the glob-marker branch end to end, which had
  -- no coverage at all before.
  local rock_dir = tmp .. "/rockproj"
  vim.fn.mkdir(rock_dir .. "/src", "p")
  vim.fn.writefile({ "package = 'x'" }, rock_dir .. "/x-1.0-1.rockspec")
  vim.fn.writefile({ "x" }, rock_dir .. "/src/init.lua")

  proot.clear_cache()
  local root5 = proot.find(rock_dir .. "/src/init.lua")
  eq(
    "project_root: glob-shaped marker (*.rockspec) still finds its directory as root",
    root5:gsub("\\", "/"),
    rock_dir
  )

  -- A sibling directory's walk stops at an already cached ancestor instead of
  -- re-walking the chain: with the marker gone from disk, only the cache still
  -- knows the root.
  local sib = tmp .. "/sibproj"
  vim.fn.mkdir(sib .. "/.git", "p")
  vim.fn.mkdir(sib .. "/a/x", "p")
  vim.fn.mkdir(sib .. "/b/y", "p")
  proot.clear_cache()
  proot.find(sib .. "/a/x")
  vim.fn.delete(sib .. "/.git", "d")
  eq(
    "project_root: a sibling walk stops at a cached ancestor instead of re-walking",
    proot.find(sib .. "/b/y"):gsub("\\", "/"),
    sib
  )
end

-- ── cheatsheet: `?` opens a float listing active tree-scoped keymaps ────────
-- Binds on a generic adapter (filetypes-driven, not hardcoded to neo-tree/
-- NvimTree), skips entirely on the neotree adapter (native `?` already
-- covers it), and degrades to a no-op when `filetypes` is missing/not a
-- table (the "got Function" bug from a catch-all __index stub adapter).
do
  local stub = setmetatable({
    name = "units-stub-cheatsheet",
    filetypes = { "units-cheatsheet-ft" },
    is_available = function()
      return true
    end,
    get_current_node = function()
      return nil
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-cheatsheet",
    features = {
      cheatsheet = { enabled = true, keymap = "?" },
      trash = { enabled = true },
      no_name_guard = { enabled = false }, -- see note on the earlier keymap tests
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "units-cheatsheet-ft"
  vim.wait(200, function()
    return false
  end)

  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end
  check("cheatsheet: '?' bound on the stub adapter's own filetype", km["?"] ~= nil)

  ft.feature("cheatsheet").show()
  local wins = vim.api.nvim_list_wins()
  local float_win, float_buf
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then float_win = w end
  end
  check("cheatsheet: show() opens a floating window", float_win ~= nil)
  if float_win then
    float_buf = vim.api.nvim_win_get_buf(float_win)
    local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    check("cheatsheet: lists the fileops category header", text:find("%sfileops") ~= nil, text)
    check(
      "cheatsheet: lists trash's 'd' keymap (feature is enabled)",
      text:find("d%s+Trash") ~= nil,
      text
    )
    check("cheatsheet: shows a close hint", text:find("close") ~= nil)
  end

  ft.feature("cheatsheet").show() -- second invocation toggles it closed
  check(
    "cheatsheet: second show() closes the float",
    float_win == nil or not vim.api.nvim_win_is_valid(float_win)
  )

  -- neotree: binds '?' like every other adapter (its native help is built from
  -- a hand-kept table that lags the features) and must not error even though the neotree adapter module isn't actually loadable here.
  local neotree_stub = setmetatable({
    name = "neotree",
    filetypes = { "neo-tree" },
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
  ft.register_adapter(neotree_stub)
  local setup_ok = pcall(ft.setup, {
    adapter = "neotree",
    features = {
      cheatsheet = { enabled = true, keymap = "?" },
      no_name_guard = { enabled = false }, -- see note on the earlier keymap tests
    },
  })
  check("cheatsheet: setup() with the neotree adapter does not error", setup_ok)

  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf2)
  vim.bo[buf2].filetype = "neo-tree"
  vim.wait(200, function()
    return false
  end)
  local has_q = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf2, "n")) do
    if m.lhs == "?" then has_q = true end
  end
  check("cheatsheet: binds '?' on the neotree adapter too (replaces its stale native help)", has_q)

  -- filetypes missing/wrong-shaped (catch-all __index stub) must not error.
  local no_filetypes_stub = setmetatable({
    name = "units-stub-cheatsheet-nofiletypes",
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
  ft.register_adapter(no_filetypes_stub)
  local setup_ok2 = pcall(ft.setup, {
    adapter = "units-stub-cheatsheet-nofiletypes",
    features = { cheatsheet = { enabled = true, keymap = "?" } },
  })
  check(
    "cheatsheet: setup() does not error when adapter.filetypes is missing/not a table",
    setup_ok2
  )
end

-- ── breadcrumbs: float mode via lib.nvim.ui.statusline, anchored at the top ──
-- Migrated off a hand-rolled float (position/buffer/lifecycle management) onto
-- the shared primitive; anchor="top" is what makes it a header rather than a
-- status bar, unlike cwd_mode's badge which sits at the bottom.
do
  vim.cmd("vsplit")
  local tree_win = vim.api.nvim_get_current_win()
  vim.cmd("wincmd p")

  local function floats()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then out[#out + 1] = w end
    end
    return out
  end

  local before = #floats()
  local breadcrumbs = require("filetree.features.ui.breadcrumbs")
  local adapter = {
    name = "units-stub-breadcrumbs",
    get_winid = function()
      return tree_win
    end,
    get_current_node = function()
      return nil
    end,
  }

  breadcrumbs.setup({ enabled = true, mode = "float" }, adapter)
  breadcrumbs.update(root .. "/lua/filetree/init.lua")

  local open = floats()
  check("breadcrumbs float: exactly one float opened", #open == before + 1)
  if #open == before + 1 then
    local win = open[#open]
    local pos = vim.api.nvim_win_get_position(tree_win)
    local cfg = vim.api.nvim_win_get_config(win)
    check("breadcrumbs float: anchored at the tree window's TOP row", cfg.row == pos[1])
    local buf = vim.api.nvim_win_get_buf(win)
    local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] or ""
    check("breadcrumbs float: shows the path", text:find("init%.lua") ~= nil, text)
  end

  breadcrumbs.teardown()
  check("breadcrumbs float: teardown closes it", #floats() == before)
end

-- The <RightMouse> handler only acts on a click that is on a text row of the
-- current window, and this runner has no pointer (getmousepos() reports
-- winid = 0), so every call below is made with a pointer standing on the
-- cursor's own row.
local function click_here(callback)
  local real = vim.fn.getmousepos
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.getmousepos = function()
    local win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local row = vim.fn.screenpos(win, line, 1).row
    return {
      winid = win,
      line = line,
      column = 1,
      screenrow = row,
      screencol = 1,
      winrow = row,
      wincol = 1,
    }
  end
  local ok, err = pcall(callback)
  vim.fn.getmousepos = real
  return ok, err
end

-- ── context_menu: right-click binding, opt-out default, via ui.contextmenu ──
do
  local stub = setmetatable({
    name = "units-stub-context-menu",
    filetypes = { "units-context-menu-ft" },
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

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({ adapter = "units-stub-context-menu" }) -- no explicit context_menu config at all

  check(
    "context_menu: active without explicit config (opt-out, on by default)",
    ft.feature("context_menu") ~= nil
  )

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "units-context-menu-ft"
  vim.wait(200, function()
    return false
  end)

  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end
  check("context_menu: default keymap '<RightMouse>' bound", km["<RightMouse>"] ~= nil)
  -- A quick second right click on the same cell (right click, <Esc>, right click
  -- again) arrives as <2-RightMouse>: bound too, or Neovim takes it itself.
  for _, lhs in ipairs({ "<2-RightMouse>", "<3-RightMouse>", "<4-RightMouse>" }) do
    check("context_menu: the default trigger binds " .. lhs, km[lhs] ~= nil)
  end
  do
    local cm = require("filetree.features.ui.context_menu")
    check(
      "context_menu: with_repeats keeps another key as configured",
      cm.with_repeats("<F7>") == "<F7>"
    )
    local widened = cm.with_repeats({ "<F7>", "<RightMouse>" })
    check(
      "context_menu: with_repeats widens <RightMouse> inside a list, other keys kept",
      type(widened) == "table"
        and widened[1] == "<F7>"
        and vim.tbl_contains(widened, "<2-RightMouse>")
    )
  end

  -- ui.contextmenu draws with its kit renderer (no third-party
  -- dependency), so a click must not just avoid erroring -- it must actually
  -- open something. This is the regression this block exists for: the
  -- feature used to require a third-party menu directly and only ever degrade to a
  -- notify, which meant right-click opened NOTHING at all.
  package.loaded["menu"] = nil
  local kit_menu = require("ui.kit.menu")
  kit_menu.close() -- in case an earlier test left one open
  local ok_no_menu = click_here(km["<RightMouse>"].callback)
  check("context_menu: click does not error", ok_no_menu)
  check("context_menu: opens the kit renderer", kit_menu.is_open())
  kit_menu.close()

  -- A loaded third-party `menu` module is never used: the kit still draws
  -- the SAME entries filetree.integrations.menu.items() builds (that
  -- module's own content is covered by TESTS/menu.lua; this only checks the
  -- wiring calls through correctly).
  local foreign_called = false
  package.loaded["menu"] = {
    open = function()
      foreign_called = true
    end,
  }
  local ok_menu = click_here(km["<RightMouse>"].callback)
  check("context_menu: click with a `menu` module loaded does not error", ok_menu)
  check("context_menu: a loaded `menu` module is not called", not foreign_called)
  check("context_menu: the kit opens instead", kit_menu.is_open())
  kit_menu.close()
  package.loaded["menu"] = nil

  -- ui.contextmenu itself missing (an old ui.nvim): degrades to a
  -- notify, same as the "nothing to open" case always did.
  package.preload["ui.contextmenu"] = function()
    error("simulated: ui.nvim too old to have contextmenu")
  end
  package.loaded["ui.contextmenu"] = nil
  local ok_no_lib = click_here(km["<RightMouse>"].callback)
  package.preload["ui.contextmenu"] = nil
  package.loaded["ui.contextmenu"] = nil
  require("ui.contextmenu") -- restore the real module for later tests
  check("context_menu: missing ui.contextmenu does not error either", ok_no_lib)

  -- keymap = false disables the binding without disabling the feature.
  local stub2 = setmetatable({
    name = "units-stub-context-menu-2",
    filetypes = { "units-context-menu-ft2" },
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
  ft.register_adapter(stub2)
  ft.setup({
    adapter = "units-stub-context-menu-2",
    features = { context_menu = { keymap = false } },
  })
  check(
    "context_menu: keymap=false still leaves the feature enabled",
    ft.feature("context_menu") ~= nil
  )

  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf2)
  vim.bo[buf2].filetype = "units-context-menu-ft2"
  vim.wait(200, function()
    return false
  end)
  local has_rm = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf2, "n")) do
    if m.lhs == "<RightMouse>" then has_rm = true end
  end
  check("context_menu: keymap=false does not bind '<RightMouse>'", not has_rm)
end

-- ── context_menu: node highlight + beside-tree positioning (kit renderer) ───
do
  local hl_calls, unhl_calls = {}, {}
  local tree_win = vim.api.nvim_get_current_win() -- stand-in for the tree window
  local cur_node = { path = "/tmp/units-context-menu-node.txt", type = "file" }

  local stub = setmetatable({
    name = "units-stub-context-menu-3",
    filetypes = { "units-context-menu-ft3" },
    is_available = function()
      return true
    end,
    get_current_node = function()
      return cur_node
    end,
    highlight_node = function(path, hl)
      hl_calls[#hl_calls + 1] = { path = path, hl = hl }
      return true
    end,
    unhighlight_node = function(path)
      unhl_calls[#unhl_calls + 1] = path
      return true
    end,
    get_winid = function()
      return tree_win
    end,
    get_position = function()
      return "left"
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  -- context_menu's own config merges onto its PREVIOUS state rather than
  -- resetting (so a user who never touches the option keeps whatever they
  -- set before) -- the prior block above ends with keymap = false, which
  -- would otherwise leak into this one. Force the default key back on.
  ft.setup({
    adapter = "units-stub-context-menu-3",
    features = { context_menu = { keymap = "<RightMouse>" } },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "units-context-menu-ft3"
  vim.wait(200, function()
    return false
  end)

  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end

  package.loaded["menu"] = nil -- force the kit fallback, which returns a surf
  local ok_click = click_here(km["<RightMouse>"].callback)
  check("context_menu extras: click does not error", ok_click)
  check(
    "context_menu extras: highlighted exactly the clicked node's path",
    #hl_calls == 1 and hl_calls[1].path == cur_node.path,
    vim.inspect(hl_calls)
  )
  check(
    "context_menu extras: used the FiletreeContextMenuNode highlight group",
    #hl_calls == 1 and hl_calls[1].hl == "FiletreeContextMenuNode"
  )

  local kit_menu = require("ui.kit.menu")
  check("context_menu extras: kit menu is open after the click", kit_menu.is_open())

  -- The highlight must still be up right here, before the menu is closed --
  -- this is the regression check: opening the menu moves focus to its own
  -- floating window, which fires BufLeave on the tree buffer as a side
  -- effect of the menu merely appearing. A fallback that reacted to
  -- BufLeave (an earlier version of this feature did) cleared the
  -- highlight on that same tick, before the user ever saw it -- silently
  -- indistinguishable from the highlight never having been applied.
  check(
    "context_menu extras: highlight is NOT cleared just from the menu taking focus",
    #unhl_calls == 0,
    vim.inspect(unhl_calls)
  )

  -- The next-tick re-application (guarding against a same-tick wipe by a
  -- reactive re-render elsewhere) genuinely happens, not just the immediate
  -- one -- wait for it rather than assuming it landed within one tick.
  vim.wait(200, function()
    return #hl_calls >= 2
  end, 5)
  check(
    "context_menu extras: highlight is re-applied on the next tick too",
    #hl_calls >= 2,
    vim.inspect(hl_calls)
  )
  check(
    "context_menu extras: every re-application targets the same node",
    hl_calls[2] == nil or hl_calls[2].path == cur_node.path
  )

  -- Tree docked "left": the menu must open beside it (relative to the tree
  -- window's own right edge), never on top of it.
  local floats = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then floats[#floats + 1] = w end
  end
  local menu_win = floats[#floats]
  if menu_win then
    local cfg = vim.api.nvim_win_get_config(menu_win)
    check("context_menu extras: menu docks relative to the tree window", cfg.relative == "win")
    check("context_menu extras: anchored on the tree window itself", cfg.win == tree_win)
    check(
      "context_menu extras: sits at the tree window's right edge, not overlapping it",
      cfg.col == vim.api.nvim_win_get_width(tree_win),
      tostring(cfg.col)
    )
  else
    check("context_menu extras: a menu float exists to check positioning on", false)
  end

  kit_menu.close()
  -- Each re-application first removes this click's previous mark (adapters
  -- keep one mark id per path, so a stacked one could never be removed), and
  -- closing removes the last: every highlight is balanced by one removal.
  local all_same = #unhl_calls > 0
  for _, path in ipairs(unhl_calls) do
    if path ~= cur_node.path then all_same = false end
  end
  check(
    "context_menu extras: unhighlight_node called (via on_close) when the menu closed",
    all_same and #unhl_calls == #hl_calls,
    ("highlights %d, removals %s"):format(#hl_calls, vim.inspect(unhl_calls))
  )

  -- ── Which clicks count: only a text row of the tree window ──────────────
  -- Everything else is "not on a node" and must do nothing: no menu, and the
  -- cursor stays where it was (clamping it onto a node would make the menu act
  -- on one nobody clicked).
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aaa", "bbb", "ccc" })
  vim.cmd("redraw")
  local win = vim.api.nvim_get_current_win()
  local last_row = vim.fn.screenpos(win, 3, 1).row
  check("context_menu clicks: the last line is drawn", last_row > 0, tostring(last_row))

  ---Right-click with the pointer described by `pos` (defaults: this window,
  ---line 3, on its row). Returns whether a menu opened, and the cursor line.
  local function click_with(pos)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    local real = vim.fn.getmousepos
    local p = vim.tbl_extend(
      "force",
      { winid = win, line = 3, column = 1, screenrow = last_row, screencol = 1 },
      pos
    )
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.getmousepos = function()
      return p
    end
    local ok, err = pcall(km["<RightMouse>"].callback)
    vim.fn.getmousepos = real
    local opened = kit_menu.is_open()
    kit_menu.close()
    return ok, err, opened, vim.api.nvim_win_get_cursor(win)[1]
  end

  local ok_c, err_c, opened, cursor = click_with({})
  check("context_menu clicks: a click on the last row runs", ok_c, tostring(err_c))
  check("context_menu clicks: ...opens the menu", opened)
  eq("context_menu clicks: ...on the clicked line", cursor, 3)

  local function no_menu(label, pos)
    local ok_n, err_n, opened_n, cursor_n = click_with(pos)
    check("context_menu clicks: " .. label .. " runs", ok_n, tostring(err_n))
    check("context_menu clicks: " .. label .. " opens no menu", not opened_n)
    eq("context_menu clicks: " .. label .. " leaves the cursor alone", cursor_n, 1)
  end
  no_menu("the row right below the last line", { screenrow = last_row + 1 })
  no_menu("far below the last line", { screenrow = last_row + 8 })
  no_menu("the statusline / separator / winbar (line 0)", { line = 0, column = 0 })
  no_menu("the tabline or command line (winid 0)", { winid = 0, line = 0, column = 0 })

  vim.cmd("vsplit")
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  no_menu("another window", { winid = other, line = 2 })
  vim.api.nvim_win_close(other, true)

  -- A wrapped last line spans several screen rows, all of them on the node.
  vim.wo[win].wrap = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "aaa",
    "bbb",
    string.rep("x", vim.api.nvim_win_get_width(win) * 2 + 5),
  })
  vim.cmd("redraw")
  last_row = vim.fn.screenpos(win, 3, 1).row
  local height = vim.api.nvim_win_text_height(win, { start_row = 2, end_row = 2 }).all
  check("context_menu clicks: the last line wraps onto several rows", height >= 3, tostring(height))
  for r = 0, height - 1 do
    local _, _, opened_r, cursor_r = click_with({ screenrow = last_row + r })
    check(
      "context_menu clicks: wrapped row " .. r .. " of the last line opens the menu",
      opened_r and cursor_r == 3
    )
  end
  no_menu("the row after a wrapped last line", { screenrow = last_row + height })

  -- Trees are 'nowrap' and get scrolled sideways: screenpos() of the last
  -- line's first column is off screen then, which must not disable this.
  vim.wo[win].wrap = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    string.rep("a", 200),
    string.rep("b", 200),
    string.rep("c", 200),
  })
  vim.cmd("redraw")
  vim.fn.winrestview({ lnum = 3, col = 150, leftcol = 120 })
  vim.cmd("redraw")
  check("context_menu clicks: the window is scrolled sideways", vim.fn.winsaveview().leftcol > 0)
  last_row = vim.fn.screenpos(win, 3, 151).row
  check("context_menu clicks: the last line is still on screen", last_row > 0, tostring(last_row))
  check(
    "context_menu clicks: ...while its first column is not (the case that broke the guard)",
    vim.fn.screenpos(win, 3, 1).row == 0
  )
  local _, _, opened_s = click_with({ screenrow = last_row })
  check("context_menu clicks: sideways scrolled, a click on the last row opens", opened_s)
  no_menu("a sideways scrolled tree, below its last line", { screenrow = last_row + 1 })
  vim.wo[win].wrap = true

  package.loaded["menu"] = nil
  vim.cmd("bwipeout! " .. buf)
end

-- ── util.window: new editor windows stay clear of the tree's side ───────────
-- Regression: a bare `:vsplit` from the (full-width) tree window follows
-- 'splitright', so with the default `splitright = false` the new window landed
-- LEFT of a left sidebar — visually moving the tree to the right edge.
do
  local window = require("filetree.util.window")

  eq("window.away_modifier(left)", window.away_modifier("left"), "botright")
  eq("window.away_modifier(right)", window.away_modifier("right"), "topleft")
  eq("window.away_modifier(nil)", window.away_modifier(nil), "")

  local function stub(pos, winid)
    return {
      name = "units-stub-window",
      get_position = function()
        return pos
      end,
      get_winid = function()
        return winid
      end,
    }
  end

  eq("window.tree_side: adapter position wins", window.tree_side(stub("right", nil)), "right")
  check("window.tree_side: float has no side", window.tree_side(stub("float", nil)) == nil)
  check("window.tree_side: no adapter at all", window.tree_side(nil) == nil)

  local saved_splitright = vim.o.splitright
  vim.o.splitright = false -- the setting that produced the bug

  vim.cmd("only")
  local tree_win = vim.api.nvim_get_current_win()
  local new_win = window.open_editor_window(stub("left", tree_win), { empty = true })
  check("window.open_editor_window: created a window", new_win ~= nil)
  eq(
    "window.open_editor_window: left tree stays at column 0",
    vim.api.nvim_win_get_position(tree_win)[2],
    0
  )
  check(
    "window.open_editor_window: new window sits right of a left tree",
    new_win ~= nil and vim.api.nvim_win_get_position(new_win)[2] > 0
  )

  vim.cmd("only")
  local tree_win_r = vim.api.nvim_get_current_win()
  local new_win_r = window.open_editor_window(stub("right", tree_win_r), { empty = true })
  check(
    "window.open_editor_window: right tree keeps a non-zero column",
    vim.api.nvim_win_get_position(tree_win_r)[2] > 0
  )
  eq(
    "window.open_editor_window: new window sits left of a right tree",
    new_win_r and vim.api.nvim_win_get_position(new_win_r)[2],
    0
  )

  vim.cmd("only")
  vim.o.splitright = saved_splitright
end

-- ── tree_integrity: the nui "Error setting nodes" guard ─────────────────────
--
-- nui consumes a node's `__children` on first init and only keeps `_child_ids`,
-- so handing live nodes back to `set_nodes` re-registers the nodes but not their
-- children: `by_id` loses them while `_child_ids` still lists them, and the next
-- `set_nodes` over that subtree indexes nil and throws — permanently, because it
-- throws before `_child_ids` is reset. Asserted here against a hand-built stand-in
-- for nui's node store, so the suite needs no nui.nvim; the end-to-end run against
-- the real nui (including the unpatched crash) is in TESTS/MANUAL.md.
do
  local ti = require("filetree.features.infra.tree_integrity")

  ---Build the shape nui keeps internally: root → docs → (a → a1, b).
  local function fake_tree()
    local by_id = {}
    local tree = { nodes = { by_id = by_id, root_ids = { "root" } } }
    local function node(id, child_ids)
      by_id[id] = { _id = id, _initialized = true, _tree = tree, _child_ids = child_ids }
    end
    node("root", { "docs" })
    node("docs", { "a", "b" })
    node("a", { "a1" })
    node("a1", nil)
    node("b", nil)
    return tree
  end

  do -- live nodes get their children handed back, so nothing is orphaned
    local tree = fake_tree()
    local by_id = tree.nodes.by_id
    local dropped = ti.sanitize(tree, { by_id["a"], by_id["b"] }, "docs")
    eq("tree_integrity: healthy tree drops nothing", dropped, 0)
    check("tree_integrity: children handed back as __children", by_id["a"].__children ~= nil)
    eq("tree_integrity: exactly the live child", by_id["a"].__children[1], by_id["a1"])
    -- empty table, not nil: has_children() must report false (so remove_node does
    -- not detach them again) while initialize_nodes appends into it
    check("tree_integrity: _child_ids emptied, not removed", #by_id["a"]._child_ids == 0)
    check("tree_integrity: childless node untouched", by_id["b"].__children == nil)
  end

  do -- the crash itself: ids left over from an earlier corruption are dropped
    local tree = fake_tree()
    local by_id = tree.nodes.by_id
    by_id["a1"] = nil -- what an unpatched set_nodes leaves behind
    table.insert(by_id["docs"]._child_ids, "ghost")
    local dropped = ti.sanitize(tree, {}, "docs")
    eq("tree_integrity: both stale ids dropped", dropped, 2)
    eq("tree_integrity: parent list compacted", table.concat(by_id["docs"]._child_ids, ","), "a,b")
    eq("tree_integrity: nested stale id dropped too", #by_id["a"]._child_ids, 0)
  end

  do -- fresh nodes (the normal create_nodes path) must not be touched at all
    local tree = fake_tree()
    local fresh = { __children = { { _id = "n1" } }, _child_ids = { "stale" } }
    ti.sanitize(tree, { fresh }, "docs")
    eq("tree_integrity: fresh node keeps __children", #fresh.__children, 1)
    eq("tree_integrity: fresh node keeps _child_ids", fresh._child_ids[1], "stale")
  end

  do -- the whole-tree branch (set_nodes without a parent_id)
    local tree = fake_tree()
    local by_id = tree.nodes.by_id
    ti.sanitize(tree, { by_id["root"] }, nil)
    eq("tree_integrity: root branch rehydrates the top", by_id["root"].__children[1], by_id["docs"])
    eq("tree_integrity: root branch recurses", by_id["a"].__children[1], by_id["a1"])
  end

  do -- a corrupt tree can hold a cycle; neither walk may loop forever
    local tree = fake_tree()
    local by_id = tree.nodes.by_id
    by_id["a"]._child_ids = { "docs" }
    local ok = pcall(ti.sanitize, tree, { by_id["docs"] }, "root")
    check("tree_integrity: cycle does not hang or throw", ok)
  end
end

-- ── trash: AppleScript quoting ────────────────────────
--
-- The macOS fallback embeds the path in an AppleScript string literal, where
-- a backslash escapes like it does in C. Escaping only the quote left a path
-- ending in a backslash reading as one literal backslash followed by a quote
-- that closes the string early, with `do shell script` one word away in what
-- follows. Both characters are legal in a macOS filename.
do
  local file =
    vim.api.nvim_get_runtime_file("lua/filetree/features/fileops/trash/platform.lua", false)[1]
  check("trash: platform.lua is on the runtimepath", file ~= nil)
  if file then
    local src = table.concat(vim.fn.readfile(file), "\n")
    local body = src:match("local function applescript_string%(s%).-\nend")
    check("trash: applescript_string is still where the test looks for it", body ~= nil)
    if body then
      local esc = assert(load(body .. "\nreturn applescript_string"))()
      local payload = '/tmp/a\\" & (do shell script "id") & "'
      check("trash: no quote is left unescaped", esc(payload):find('[^\\]"') == nil)
      check("trash: a lone backslash is doubled", esc([[a\\b]]) == [[a\\\\b]])
      check("trash: an ordinary path is unchanged", esc("plain/path.txt") == "plain/path.txt")
    end
  end
end

-- ── util.path: dot_relative / refs env refold ───────────────────────────────
-- Both are pure string transforms over absolute paths -- nothing is stat'ed --
-- so the fixture root only has to be absolute on the running OS, not to exist.
do
  local path = require("filetree.util.path")
  local R = (vim.fn.has("win32") == 1) and "C:/ft-units" or "/ft-units"

  check(
    "path.dot_relative: a descendant gets an explicit ./",
    path.dot_relative(R .. "/docs/ROADMAP/ROADMAP.md", R .. "/docs/ROADMAP") == "./ROADMAP.md"
  )
  check(
    "path.dot_relative: a deeper descendant keeps its subpath",
    path.dot_relative(R .. "/docs/ROADMAP/ROADMAP.md", R) == "./docs/ROADMAP/ROADMAP.md"
  )
  -- The case cwd-relative copying gets wrong: the link is written in
  -- docs/ROADMAP/, so the target one directory up is "../BINDINGS.md".
  check(
    "path.dot_relative: a sibling directory climbs with ..",
    path.dot_relative(R .. "/docs/BINDINGS.md", R .. "/docs/ROADMAP") == "../BINDINGS.md"
  )
  check(
    "path.dot_relative: the base itself is .",
    path.dot_relative(R .. "/docs", R .. "/docs") == "."
  )
  -- A dotfile starts with "." too, and must still be prefixed -- the guard has
  -- to test for a "./" or "../" segment, not merely for a leading dot.
  check(
    "path.dot_relative: a dotfile is still prefixed",
    path.dot_relative(R .. "/docs/.hidden.md", R .. "/docs") == "./.hidden.md"
  )

  -- The `$VAR` refold of a moved link target (refs `env` style) goes through
  -- lib.nvim's named-roots registry; these were `path.env_rooted`'s checks.
  local pathutil = require("filetree.refs.pathutil")
  local lib_roots = require("lib.nvim.fs.roots")
  ---@param new_path string
  ---@param env FiletreeRefEnvRoots
  ---@return string
  local function refold(new_path, env)
    return pathutil.retarget({
      style = "env",
      target = "$X/old.md",
      from_file = R .. "/from.md",
      root = R,
      new_path = new_path,
      env = env,
    })
  end
  -- Only the roots named here: no `$REPOS_DIR` / `$NVIM_CONFIG_DIR` of the
  -- machine running the suite.
  lib_roots.setup({ vars = {}, nvim_config = false })

  local saved = vim.env.FILETREE_UNITS_ROOT
  vim.env.FILETREE_UNITS_ROOT = R .. "/repos"
  local names = { names = { "FILETREE_UNITS_ROOT" } }
  check(
    "refs env refold: a path under the variable is rewritten",
    refold(R .. "/repos/filetree.nvim/lua/x.lua", names)
      == "$FILETREE_UNITS_ROOT/filetree.nvim/lua/x.lua"
  )
  check(
    "refs env refold: the root itself needs no trailing slash",
    refold(R .. "/repos", names) == "$FILETREE_UNITS_ROOT"
  )
  check(
    "refs env refold: a path outside comes back absolute",
    refold(R .. "/elsewhere/x.lua", names) == R .. "/elsewhere/x.lua"
  )
  check(
    "refs env refold: an unset variable is skipped",
    refold(R .. "/repos/x.lua", { names = { "FILETREE_UNITS_NOT_SET" } }) == R .. "/repos/x.lua"
  )
  -- Deepest match wins, so a repo dir nested inside a home dir reports the
  -- repo dir -- the more specific of the two -- whatever order they are listed.
  local saved_home = vim.env.FILETREE_UNITS_HOME
  vim.env.FILETREE_UNITS_HOME = R
  check(
    "refs env refold: the deepest matching root wins",
    refold(R .. "/repos/x.lua", { names = { "FILETREE_UNITS_HOME", "FILETREE_UNITS_ROOT" } })
      == "$FILETREE_UNITS_ROOT/x.lua"
  )
  vim.env.FILETREE_UNITS_HOME = saved_home
  vim.env.FILETREE_UNITS_ROOT = saved

  -- `nvim_config`: `$NVIM_CONFIG_DIR` from stdpath("config"), without an
  -- environment variable of that name.
  local cfg_dir = (vim.fn.stdpath("config") --[[@as string]]):gsub("\\", "/")
  check(
    "refs env refold: $NVIM_CONFIG_DIR (no env var) is rewritten",
    refold(cfg_dir .. "/lua/x.lua", { nvim_config = true }) == "$NVIM_CONFIG_DIR/lua/x.lua"
  )
  check(
    "refs env refold: ...not with nvim_config = false",
    refold(cfg_dir .. "/lua/x.lua", { nvim_config = false }) == cfg_dir .. "/lua/x.lua"
  )

  -- A non-ASCII Windows profile path compares case-insensitively (the
  -- registry folds with `vim.fn.tolower`, not the ASCII-only `string.lower`).
  lib_roots.setup({
    vars = {},
    nvim_config = false,
    windows = true,
    source = { FILETREE_UNITS_ROOT = "C:/Users/BJÖRN/repos" },
  })
  check(
    "refs env refold: a non-ASCII-cased root still folds (Ö/ö) on Windows",
    refold("C:/Users/björn/repos/filetree.nvim/lua/x.lua", names)
      == "$FILETREE_UNITS_ROOT/filetree.nvim/lua/x.lua"
  )
  lib_roots.setup(nil)
end

-- ── path_copy: every format copies in the canonical separator ──────────────
-- `fnamemodify`'s ":." and ":h" hand back NATIVE separators on Windows the
-- moment they touch a path, so `relative` used to put `sub\b.lua` on the
-- clipboard while this module's own documented examples -- and `uri`, which
-- always slashified -- show `sub/b.lua`. The clipboard is not an OS-shell
-- invocation, the one case util.path exempts, so it follows the same rule.
--
-- The node handed in is deliberately BACKSLASHED: that is what an adapter
-- reports on Windows, and a check fed a forward-slash path would pass without
-- the formats doing anything.
do
  local tmp = (TMP_ROOT .. "/units-pathcopy"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/sub", "p")
  vim.fn.writefile({ "x" }, tmp .. "/sub/b.lua")
  vim.fn.chdir(tmp)
  -- Take the cwd back from Neovim instead of trusting `tmp`: on macOS $TMPDIR
  -- lives under /var, which is a symlink to /private/var, and chdir resolves
  -- it. `:.` only rewrites a path that is under the cwd, so a node path still
  -- spelled the unresolved way is not under it and stays absolute -- making
  -- the `relative` format look broken when it is behaving exactly right.
  tmp = (vim.fn.getcwd()):gsub("\\", "/")

  -- Backslashed only where a backslash IS a separator. On Windows that is the
  -- point of this block: an adapter reports native separators there, and a
  -- forward-slash path would let every format pass without doing anything. On
  -- a Unix host a backslash is an ordinary filename character, so the same
  -- spelling makes the path *relative* -- `:.` then has nothing under the cwd
  -- to rewrite and hands it straight back, which is what made `relative` look
  -- broken on macOS while it was behaving correctly. (Linux never showed it:
  -- this whole block is behind HAS_CLIPBOARD and a headless Linux runner has
  -- no provider, so it was skipped there rather than passing.)
  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local node_path = tmp .. "/sub/b.lua"
  local native = is_win and (node_path:gsub("/", "\\")) or node_path
  local cur_node = { path = native, type = "file" }
  local stub = setmetatable({
    name = "units-stub-pathcopy",
    is_available = function()
      return true
    end,
    get_current_node = function()
      return cur_node
    end,
    get_winid = function()
      return nil
    end,
    refresh = function()
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-pathcopy",
    features = { path_copy = { enabled = true, notify = false } },
  })

  local pc = ft.feature("path_copy")
  check("path_copy: the feature resolves", type(pc) == "table")

  if HAS_CLIPBOARD and type(pc) == "table" then
    -- Each format that can carry a separator at all. `name`/`stem` have none,
    -- so they would pass no matter what and are left out.
    local separator_formats = {
      "absolute",
      "relative",
      "dirname",
      "uri",
      "line",
      "project_root",
      "project_relative",
      "buffer_relative",
      "env_rooted",
    }
    -- The register is reset to a sentinel before each format. Without that, a
    -- format that THROWS leaves the previous format's text in place -- which
    -- has no backslash either, so the separator check would pass for a format
    -- that never ran. That is how `buffer_relative` hid an E194 crash:
    -- `expand("#:p")` raises when there is no alternate file instead of
    -- returning "".
    local bad, broken, silent = {}, {}, {}
    for _, fmt in ipairs(separator_formats) do
      local fn = pc["copy_" .. fmt]
      if type(fn) == "function" then
        vim.fn.setreg("+", "<<sentinel>>")
        local ok_fmt, err = pcall(fn)
        local got = vim.fn.getreg("+")
        if not ok_fmt then
          broken[#broken + 1] = fmt .. ": " .. (tostring(err):gsub("\n.*", ""))
        elseif got == "<<sentinel>>" then
          silent[#silent + 1] = fmt
        elseif type(got) == "string" and got:find("\\", 1, true) then
          bad[#bad + 1] = fmt .. "=" .. got
        end
      else
        -- A format the list names but the module lacks is no pass (NEW-43).
        broken[#broken + 1] = fmt .. ": copy_" .. fmt .. " is missing"
      end
    end
    check("path_copy: every format runs without erroring", #broken == 0, table.concat(broken, "; "))
    check(
      "path_copy: every format actually writes the register",
      #silent == 0,
      table.concat(silent, "; ")
    )
    check("path_copy: no format copies a native separator", #bad == 0, table.concat(bad, "; "))

    -- `buffer_relative` with no alternate file. `expand("#:p")` THROWS E194
    -- in that case rather than returning "", which made the cwd fallback
    -- below it unreachable in exactly the situation it was written for --
    -- someone who opens Neovim on a directory and copies before editing.
    --
    -- Driven by making `expand` raise rather than by arranging a window
    -- without an alternate: earlier blocks in this suite leave one behind,
    -- and even a fresh tab inherits it, so the branch would simply not run
    -- and the check would pass without testing anything. The guard is what
    -- matters here, so the guard is what is exercised.
    local real_expand = vim.fn.expand
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.expand = function(arg, ...)
      if arg == "#:p" then error("Vim:E194: No alternate file name to substitute for '#'") end
      return real_expand(arg, ...)
    end
    vim.fn.setreg("+", "<<sentinel>>")
    local ok_ba, err_ba = pcall(pc.copy_buffer_relative)
    local got_ba = vim.fn.getreg("+")
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.expand = real_expand
    check(
      "path_copy: `]b` survives a window with no alternate file (E194)",
      ok_ba and got_ba ~= "<<sentinel>>",
      ok_ba and "register untouched" or (tostring(err_ba):gsub("\n.*", ""))
    )

    -- And the relative form really is relative -- proof the check above was in
    -- a position to fail, since ":." only rewrites a path under the cwd.
    pcall(pc.copy_relative)
    check(
      "path_copy: `relative` is cwd-relative, so that check could have failed",
      vim.fn.getreg("+") == "sub/b.lua",
      vim.fn.getreg("+")
    )

    -- `env_rooted`'s nvim_config_root (default true): a node under
    -- vim.fn.stdpath("config") folds to $NVIM_CONFIG_DIR even though no
    -- env_roots entry (REPOS_DIR by default) would ever match it -- that
    -- dir typically lives nowhere near a repos checkout.
    local cfg_dir = (vim.fn.stdpath("config") --[[@as string]]):gsub("\\", "/")
    local probe_path = cfg_dir .. "/lua/units_nvim_config_root_probe.lua"
    cur_node = { path = probe_path, type = "file" }
    vim.fn.setreg("+", "<<sentinel>>")
    pcall(pc.copy_env_rooted)
    check(
      "path_copy: env_rooted folds $NVIM_CONFIG_DIR for a node under stdpath('config')",
      vim.fn.getreg("+") == "$NVIM_CONFIG_DIR/lua/units_nvim_config_root_probe.lua",
      vim.fn.getreg("+")
    )

    -- nvim_config_root = false turns the fold back off -- falls back to the
    -- plain absolute path, same as before this option existed.
    ft.setup({
      adapter = "units-stub-pathcopy",
      features = { path_copy = { enabled = true, notify = false, nvim_config_root = false } },
    })
    local pc_off = ft.feature("path_copy")
    vim.fn.setreg("+", "<<sentinel>>")
    pcall(pc_off.copy_env_rooted)
    check(
      "path_copy: nvim_config_root=false disables the $NVIM_CONFIG_DIR fold",
      vim.fn.getreg("+") == probe_path,
      vim.fn.getreg("+")
    )
  end
end

-- ── neo-tree collapse_all: which tree, which chain, merged lines ─────────────
-- Against a shaped stand-in of neo-tree's state/tree/renderer, so the chain
-- logic is gated in CI (TESTS/collapse_all_backends.lua runs the real tree,
-- but only where neo-tree is installed). The paths are real directories, one
-- folder is a junction/symlink: the chain must run THROUGH it.
do
  local uv = vim.uv or vim.loop
  local short_dir = vim.fn.tempname()
  vim.fn.mkdir(short_dir .. "/r/a", "p")
  vim.fn.mkdir(short_dir .. "/r/x", "p")
  vim.fn.mkdir(short_dir .. "/target", "p")
  local base = (uv.fs_realpath(short_dir) or short_dir):gsub("\\", "/")
  local tree_root = base .. "/r"
  local linked = uv.fs_symlink(base .. "/target", tree_root .. "/a/link", { junction = true })

  ---A tree of `ids` (all expanded), root first; `names` overrides a display name.
  local function fake_tree(ids, names)
    local nodes = {}
    local tree = { cursor = nil }
    for i, id in ipairs(ids) do
      local parent = i > 1 and (id:match("^(.*)/[^/]+$")) or nil
      nodes[id] = {
        id = id,
        name = (names or {})[id] or id:match("[^/]+$"),
        type = "directory",
        expanded = true,
        get_id = function(self)
          return self.id
        end,
        get_parent_id = function()
          return parent
        end,
        is_expanded = function(self)
          return self.expanded
        end,
        has_children = function()
          return true
        end,
        collapse = function(self)
          self.expanded = false
          return true
        end,
      }
    end
    function tree:get_nodes()
      return { nodes[ids[1]] }
    end
    function tree:get_node(id)
      if id == nil then return self.cursor and nodes[self.cursor] or nil end
      return nodes[id]
    end
    tree.nodes, tree.ids = nodes, ids
    return tree
  end

  ---@param tree table
  ---@return string  the expanded ids below the root, relative to it, sorted
  local function open_rel(tree)
    local out = {}
    for _, id in ipairs(tree.ids) do
      if id ~= tree.ids[1] and tree.nodes[id].expanded then
        out[#out + 1] = id:sub(#tree_root + 2)
      end
    end
    table.sort(out)
    return table.concat(out, ",")
  end

  local calls = { redraw = 0, refresh = 0, focus = {} }
  local states = {}
  package.loaded["neo-tree.sources.manager"] = {
    _get_all_states = function()
      local list = {}
      for _, s in pairs(states) do
        list[#list + 1] = s
      end
      return list
    end,
    get_state = function(_, tabid)
      return states[tabid]
    end,
    refresh = function()
      calls.refresh = calls.refresh + 1
    end,
  }
  package.loaded["neo-tree.ui.renderer"] = {
    get_expanded_nodes = function(tree)
      local out = {}
      for _, id in ipairs(tree.ids) do
        if tree.nodes[id].expanded then out[#out + 1] = id end
      end
      return out
    end,
    redraw = function()
      calls.redraw = calls.redraw + 1
    end,
    focus_node = function(_, id)
      calls.focus[#calls.focus + 1] = id
    end,
  }
  package.loaded["filetree.adapter.neotree"] = nil
  local nt = require("filetree.adapter.neotree")

  local tab1 = vim.api.nvim_get_current_tabpage()
  local function state_for(tab, tree, winid)
    return { name = "filesystem", tabid = tab, id = tab, tree = tree, winid = winid }
  end

  -- 1. The chain through a linked folder stays open, everything else closes.
  if linked then
    local tree =
      fake_tree({ tree_root, tree_root .. "/a", tree_root .. "/a/link", tree_root .. "/x" })
    states = { [tab1] = state_for(tab1, tree, nil) }
    local ok = nt.collapse_all(tree_root .. "/a/link/f.lua")
    check(
      "collapse_all(keep): the chain through a linked folder stays open, x closes",
      ok and open_rel(tree) == "a,a/link",
      open_rel(tree)
    )
    local remembered = vim.tbl_keys(states[tab1].explicitly_opened_nodes or {})
    eq("...neo-tree remembers just that chain as opened", #remembered, 2)
    eq("...a closed tree is not redrawn", calls.redraw, 0)
  else
    print("  note no symlink/junction could be created -- skipping the linked-folder case")
  end

  -- 2. The kept path in another spelling of the same folder (8.3 short form on
  --    Windows; identical elsewhere) still keeps its chain.
  do
    local tree = fake_tree({ tree_root, tree_root .. "/a", tree_root .. "/x" })
    states = { [tab1] = state_for(tab1, tree, nil) }
    nt.collapse_all(short_dir:gsub("\\", "/") .. "/r/x/f.lua")
    eq(
      "collapse_all(keep) in another spelling of the tree_root keeps x's chain",
      open_rel(tree),
      "x"
    )
  end

  -- 3. With this tab's tree closed and another tab's tree live, THIS tab's
  --    tree is the one collapsed.
  do
    local here = fake_tree({ tree_root, tree_root .. "/a", tree_root .. "/x" })
    local there = fake_tree({ tree_root, tree_root .. "/a", tree_root .. "/x" })
    vim.cmd("tabnew")
    local tab2 = vim.api.nvim_get_current_tabpage()
    local win2 = vim.api.nvim_get_current_win()
    vim.cmd("tabprevious")
    states = { [tab1] = state_for(tab1, here, nil), [tab2] = state_for(tab2, there, win2) }
    nt.collapse_all(nil)
    eq("collapse_all on a tab without an open tree collapses THIS tab's tree", open_rel(here), "")
    eq("...and leaves the live tree on the other tab alone", open_rel(there), "a,x")
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab2))
  end

  -- 4. A collapsed group_empty_dirs line on a live tree: refreshed, as
  --    collapse_node does, so it does not stay merged.
  do
    local merged_id = tree_root .. "/x"
    local tree = fake_tree({ tree_root, tree_root .. "/a", merged_id }, { [merged_id] = "x/y/z" })
    tree.cursor = tree_root .. "/a"
    states = { [tab1] = state_for(tab1, tree, vim.api.nvim_get_current_win()) }
    calls.redraw, calls.refresh, calls.focus = 0, 0, {}
    nt.collapse_all(nil)
    eq("a collapsed merged line: one refresh (rescan rebuilds it unmerged)", calls.refresh, 1)
    eq("...instead of a redraw of the still-merged state", calls.redraw, 0)
    eq("...the cursor goes to the top-level entry it was under", calls.focus[1], tree_root .. "/a")

    tree = fake_tree({ tree_root, tree_root .. "/a" })
    states = { [tab1] = state_for(tab1, tree, vim.api.nvim_get_current_win()) }
    calls.redraw, calls.refresh = 0, 0
    nt.collapse_all(nil)
    eq("no merged line: no refresh", calls.refresh, 0)
    eq("...one redraw of the live tree", calls.redraw, 1)
  end

  package.loaded["neo-tree.sources.manager"] = nil
  package.loaded["neo-tree.ui.renderer"] = nil
  package.loaded["filetree.adapter.neotree"] = nil
  vim.fn.delete(short_dir, "rf")
end

-- ── Report ────────────────────────────────────────────────────────────────────
print(("\nfiletree.nvim units (3/3): %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
