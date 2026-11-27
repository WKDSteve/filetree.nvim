-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
---@diagnostic disable: missing-fields
-- Test doubles here implement only what the unit under test calls -- a full
-- FiletreeAdapter or FiletreeRef would be noise, not coverage.
-- units_2.lua — headless unit tests for filetree.nvim's util layer + adapter helpers.
--
-- Complements TESTS/smoke.lua (which is an integration test over the registry and
-- setup). This file exercises the reusable primitives directly.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/units_2.lua
--
-- Exit 0 = all passed, 1 = a check failed.

-- ":p" resolves to absolute *before* walking up two levels, so `root` stays
-- correct even if a test later changes Neovim's cwd (":h:h" alone would give a
-- path relative to invocation-time cwd, e.g. "." when run as `-l TESTS/units_2.lua`,
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

-- ── smart_rename: reference engine -> update refs to the new path ───────────
-- Same chooser pattern as trash, but post-rename (no "cancel" -- the rename
-- already happened) and the "update all" path rewrites to the file's new name
-- rather than a "REF!" marker.
do
  local tmp = (TMP_ROOT .. "/units-smartrename-refs"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local old_path = tmp .. "/old.md"
  local new_path = tmp .. "/renamed.md"
  local linker = tmp .. "/linker.md"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "# Old" }, old_path)
  vim.fn.writefile({ "See [old](old.md) here." }, linker)

  -- Auto-drive the "Rename to:" prompt and the resulting chooser.
  package.loaded["ui.kit"] = {
    input = function(opts)
      opts.on_submit("renamed.md")
    end,
  }
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    on_choice(choices[1]) -- "Update all refs"
  end
  package.loaded["filetree.features.fileops.smart_rename"] = nil -- reload with stubs

  local cur_node = { path = old_path, type = "file" }
  local stub = setmetatable({
    name = "units-stub-smartrename",
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
    adapter = "units-stub-smartrename",
    refs = { on_rename = "ask", providers = { markdown = true } },
    features = { smart_rename = { enabled = true, use_safety = false } },
  })

  ft.feature("smart_rename").rename_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(new_path) == 1
      and vim.fn.readfile(linker)[1]:find("old.md", 1, true) == nil
  end, 20)

  eq("smart_rename+refs: file renamed on disk", vim.fn.filereadable(new_path), 1)
  local linker_lines = vim.fn.readfile(linker)
  check(
    "smart_rename+refs: reference rewritten to the new name, link style preserved",
    linker_lines[1] == "See [old](renamed.md) here.",
    linker_lines[1]
  )

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.smart_rename"] = nil
end

-- ── rename_batch: references aggregated across the batch ────────────────
-- Two renamed files, each referenced from markdown; verify refs from BOTH
-- land in one aggregated chooser and each gets its own correct new target.
do
  local tmp = (TMP_ROOT .. "/units-renamebatch-refs"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local a_old, a_new = tmp .. "/a.md", tmp .. "/a2.md"
  local b_old, b_new = tmp .. "/b.md", tmp .. "/b2.md"
  local linker = tmp .. "/linker.md"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "# A" }, a_old)
  vim.fn.writefile({ "# B" }, b_old)
  vim.fn.writefile({ "See [a](a.md) and [b](b.md) here." }, linker)

  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    on_choice(choices[1]) -- "Update all refs"
  end
  package.loaded["filetree.features.fileops.rename_batch"] = nil -- reload with stubs

  local nodes = {
    { path = a_old, type = "file" },
    { path = b_old, type = "file" },
  }
  local stub = setmetatable({
    name = "units-stub-renamebatch",
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
    adapter = "units-stub-renamebatch",
    refs = { on_rename = "ask", providers = { markdown = true } },
    features = { rename_batch = { enabled = true, use_safety = false } },
  })

  local lib_autocmd = require("lib.nvim.bindings.autocmd")
  local function rb_records(b)
    return #lib_autocmd.registered({ group = "filetree_rename_batch_" .. b })
  end

  ft.feature("rename_batch").open()
  local rb_buf = vim.api.nvim_get_current_buf()
  check("rename_batch: an open session records its autocmds", rb_records(rb_buf) > 0)
  -- Lines: header, blank, then one name per node (see M.open()'s 2-line offset).
  vim.api.nvim_buf_set_lines(rb_buf, 2, 4, false, { "a2.md", "b2.md" })
  vim.cmd("write")
  vim.wait(5000, function()
    return vim.fn.filereadable(b_new) == 1
  end, 20)
  -- The scratch buffer is deleted once the renames went through; its BufDelete
  -- hook takes back the autocmds' records and the group. Deleting the group
  -- alone left two records per batch rename in lib.nvim's registry for good (the
  -- group is named after the buffer, which is never asked for twice).
  vim.wait(2000, function()
    return not vim.api.nvim_buf_is_valid(rb_buf)
  end, 20)
  eq("rename_batch: a finished session leaves no autocmd records", rb_records(rb_buf), 0)
  check(
    "rename_batch: ...and no augroup",
    not pcall(vim.api.nvim_get_autocmds, { group = "filetree_rename_batch_" .. rb_buf })
  )

  -- Cancelling (:bd) is the other way out, through the same hook.
  ft.feature("rename_batch").open()
  local cancel_buf = vim.api.nvim_get_current_buf()
  check("rename_batch: a second session records its autocmds", rb_records(cancel_buf) > 0)
  vim.cmd("bdelete!")
  eq("rename_batch: cancelling leaves no autocmd records", rb_records(cancel_buf), 0)

  eq("rename_batch+refs: a.md renamed", vim.fn.filereadable(a_new), 1)
  eq("rename_batch+refs: b.md renamed", vim.fn.filereadable(b_new), 1)
  local linker_lines = vim.fn.readfile(linker)
  check(
    "rename_batch+refs: both references updated to their own new paths",
    linker_lines[1]:find("a2.md", 1, true) ~= nil and linker_lines[1]:find("b2.md", 1, true) ~= nil,
    linker_lines[1]
  )

  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.rename_batch"] = nil
end

-- ── smart_rename: renaming onto an existing path asks confirm_choice ───────
-- Regression for the kit.confirm migration (Overwrite/Cancel used to be a
-- vim.ui.select list): the chooser must offer exactly Overwrite/Cancel, and
-- picking Cancel must leave both files untouched.
do
  local tmp = (TMP_ROOT .. "/units-smartrename-overwrite"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local old_path = tmp .. "/old.txt"
  local existing_path = tmp .. "/existing.txt"
  vim.fn.writefile({ "old" }, old_path)
  vim.fn.writefile({ "existing" }, existing_path)

  package.loaded["ui.kit"] = {
    input = function(opts)
      opts.on_submit("existing.txt")
    end,
  }

  local captured_question, captured_choices
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(question, choices, on_choice)
    captured_question, captured_choices = question, choices
    on_choice("Cancel")
  end
  package.loaded["filetree.features.fileops.smart_rename"] = nil -- reload with stub

  local cur_node = { path = old_path, type = "file" }
  local stub = setmetatable({
    name = "units-stub-smartrename-overwrite",
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
    adapter = "units-stub-smartrename-overwrite",
    features = { smart_rename = { enabled = true, use_safety = false } },
  })

  ft.feature("smart_rename").rename_current()

  check(
    "smart_rename overwrite: confirm_choice asked with Overwrite/Cancel",
    captured_choices ~= nil
      and captured_choices[1] == "Overwrite"
      and captured_choices[2] == "Cancel",
    vim.inspect(captured_choices)
  )
  check(
    "smart_rename overwrite: question mentions the existing name",
    captured_question ~= nil and captured_question:find("existing.txt", 1, true) ~= nil,
    tostring(captured_question)
  )
  check(
    "smart_rename overwrite: Cancel leaves the old file in place",
    vim.fn.filereadable(old_path) == 1,
    "old file should still exist"
  )

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.smart_rename"] = nil
end

-- ── case_clash: alias detection on a case-insensitive filesystem ────────────
do
  local cc = require("filetree.util.case_clash")
  local tmp = (TMP_ROOT .. "/units-caseclash"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/Telemetry", "p")
  vim.fn.mkdir(tmp .. "/Other", "p")
  vim.fn.writefile({ "x" }, tmp .. "/Telemetry/a.txt")

  check("case_clash: a path aliases itself", cc.same_file(tmp .. "/Telemetry", tmp .. "/Telemetry"))
  check(
    "case_clash: two distinct directories are not aliases",
    not cc.is_alias(tmp .. "/Telemetry", tmp .. "/Other")
  )
  check(
    "case_clash: a not-yet-existing distinct name is not an alias",
    not cc.is_alias(tmp .. "/Telemetry", tmp .. "/TELEMTRY")
  )
  if cc.case_insensitive_fs() then
    check(
      "case_clash: case-only variant IS an alias (case-insensitive fs)",
      cc.is_alias(tmp .. "/Telemetry", tmp .. "/TELEMETRY")
    )
  else
    check(
      "case_clash: case-only variant is NOT an alias (case-sensitive fs)",
      not cc.is_alias(tmp .. "/Telemetry", tmp .. "/TELEMETRY")
    )
  end
end

-- ── smart_rename: a case-only rename is not a collision ─────────────────────
-- Regression: on Windows/macOS `isdirectory("docs/TELEMETRY")` is truthy while
-- `docs/Telemetry` exists (the OS folds the casing), so smart_rename used to
-- pop a bogus "'TELEMETRY' exists." prompt. It must rename in place instead.
if require("filetree.util.case_clash").case_insensitive_fs() then
  local tmp = (TMP_ROOT .. "/units-smartrename-caseonly"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/Telemetry", "p")
  vim.fn.writefile({ "payload" }, tmp .. "/Telemetry/a.txt")

  package.loaded["ui.kit"] = {
    input = function(opts)
      opts.on_submit("TELEMETRY")
    end,
  }
  local asked = false
  package.loaded["filetree.util.confirm_choice"] = function(_q, _choices, on_choice)
    asked = true
    on_choice("Cancel")
  end
  package.loaded["filetree.features.fileops.smart_rename"] = nil

  local cur_node = { path = tmp .. "/Telemetry", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-smartrename-caseonly",
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
    adapter = "units-stub-smartrename-caseonly",
    features = { smart_rename = { enabled = true, use_safety = false } },
  })

  ft.feature("smart_rename").rename_current()
  vim.wait(300, function()
    return false
  end)

  check("smart_rename case-only: no bogus 'exists' prompt", not asked)
  check(
    "smart_rename case-only: directory re-cased on disk",
    vim.fn.isdirectory(tmp .. "/TELEMETRY") == 1
  )
  check(
    "smart_rename case-only: content preserved through the rename",
    vim.fn.readfile(tmp .. "/TELEMETRY/a.txt")[1] == "payload"
  )
  check("smart_rename case-only: exactly one entry — not a copy", #vim.fn.readdir(tmp) == 1)

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.smart_rename"] = nil
end

-- ── copy_move: a copy that collides only by case with its own source ────────
-- The OS can't hold both spellings, and the old "Overwrite" path would
-- delete(dst,"rf") — i.e. wipe the source. It must ask via case_clash and,
-- on "Append a number", produce a numbered copy while leaving the source be.
if require("filetree.util.case_clash").case_insensitive_fs() then
  local tmp = (TMP_ROOT .. "/units-cm-caseclash"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/Telemetry", "p")
  vim.fn.writefile({ "hi" }, tmp .. "/Telemetry/a.txt")
  -- Same directory, different casing — the paste target's node path.
  local recased = tmp:gsub("units%-cm%-caseclash", "UNITS-CM-CASECLASH")

  local saw_choices
  package.loaded["filetree.util.confirm_choice"] = function(_q, choices, on_choice)
    saw_choices = choices
    on_choice("Append a number")
  end
  package.loaded["filetree.features.fileops.copy_move"] = nil

  local cur_node = { path = tmp .. "/Telemetry", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-cm-caseclash",
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
    adapter = "units-stub-cm-caseclash",
    features = {
      copy_move = { enabled = true, confirm = false, use_safety = false },
      no_name_guard = { enabled = false },
    },
  })

  local cm = ft.feature("copy_move")
  cm.stage_copy()
  cur_node = { path = recased, type = "directory" }
  local orig_notify = vim.notify
  -- A test double over typed `vim.*` surface: replacing the field is the
  -- point of the case, not a second definition of it.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function() end
  cm.paste()
  vim.wait(400, function()
    return false
  end)
  vim.notify = orig_notify

  check(
    "copy_move caseclash: prompt offered the case-limitation choices",
    saw_choices ~= nil and saw_choices[1] == "Append a number",
    vim.inspect(saw_choices)
  )
  check(
    "copy_move caseclash: source directory left intact",
    vim.fn.readfile(tmp .. "/Telemetry/a.txt")[1] == "hi"
  )
  check(
    "copy_move caseclash: numbered copy written with content",
    vim.fn.filereadable(tmp .. "/Telemetry (2)/a.txt") == 1
  )
  check("copy_move caseclash: no third entry, no merge/overwrite", #vim.fn.readdir(tmp) == 2)

  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.copy_move"] = nil
end

-- ── smart_create: non-empty clipboard asks confirm_choice (Empty/Paste) ─────
-- Regression for the kit.confirm migration (used to be a vim.ui.select list).
-- Skipped without a working clipboard provider (see HAS_CLIPBOARD above): the
-- whole scenario hinges on `getreg("+")` actually returning what was set.
if HAS_CLIPBOARD then
  local tmp = (TMP_ROOT .. "/units-smartcreate-paste"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  vim.fn.chdir(tmp)
  vim.fn.setreg("+", "clip content")

  package.loaded["ui.kit"] = {
    input = function(opts)
      opts.on_submit("new.txt")
    end,
  }

  local captured_question, captured_choices
  package.loaded["filetree.util.confirm_choice"] = function(question, choices, on_choice)
    captured_question, captured_choices = question, choices
    on_choice("Paste clipboard")
  end
  package.loaded["filetree.features.fileops.smart_create"] = nil -- reload with stub

  local cur_node = { path = tmp, type = "directory" }
  local stub = setmetatable({
    name = "units-stub-smartcreate",
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
    adapter = "units-stub-smartcreate",
    features = { smart_create = { enabled = true, ask_clipboard = true } },
  })

  ft.feature("smart_create").create()

  check(
    "smart_create paste: confirm_choice asked with Empty/Paste clipboard",
    captured_choices ~= nil
      and captured_choices[1] == "Empty"
      and captured_choices[2] == "Paste clipboard",
    vim.inspect(captured_choices)
  )
  check(
    "smart_create paste: question mentions the new file name",
    captured_question ~= nil and captured_question:find("new.txt", 1, true) ~= nil,
    tostring(captured_question)
  )
  check(
    "smart_create paste: file created with clipboard content",
    vim.fn.filereadable(tmp .. "/new.txt") == 1
      and table.concat(vim.fn.readfile(tmp .. "/new.txt"), "\n"):find("clip content", 1, true)
        ~= nil
  )

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.smart_create"] = nil
end

-- ── link_create: file target asks Symlink/Hardlink, creates a real hardlink ──
-- The link is created in the CURRENT NODE's directory, which must be
-- different from the target's own directory or "same path" would collide
-- with the existence guard before creation is ever attempted.
do
  local tmp = (TMP_ROOT .. "/units-linkcreate-file"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.mkdir(tmp .. "/dest", "p")
  local target = tmp .. "/src/target.txt"
  vim.fn.writefile({ "hello link" }, target)

  package.loaded["ui.kit"] = {
    input = function(opts)
      opts.on_submit(target)
    end,
  }
  local captured_question, captured_choices
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(question, choices, on_choice)
    captured_question, captured_choices = question, choices
    on_choice("Hardlink")
  end
  package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stub

  local cur_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-linkcreate-file",
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
    adapter = "units-stub-linkcreate-file",
    features = { link_create = { enabled = true } },
  })

  ft.feature("link_create").create()

  check(
    "link_create file target: confirm_choice asked with Symlink/Hardlink",
    captured_choices ~= nil
      and captured_choices[1] == "Symlink"
      and captured_choices[2] == "Hardlink",
    vim.inspect(captured_choices)
  )
  check(
    "link_create file target: question mentions the link's name",
    captured_question ~= nil and captured_question:find("target.txt", 1, true) ~= nil,
    tostring(captured_question)
  )
  check(
    "link_create file target: hardlink created in dest/, with matching content",
    vim.fn.filereadable(tmp .. "/dest/target.txt") == 1
      and table.concat(vim.fn.readfile(tmp .. "/dest/target.txt"), "\n") == "hello link"
  )

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.link_create"] = nil
end

-- ── link_create: directory target skips the chooser (symlink only) ──────────
-- Windows symlink creation needs Developer Mode or an elevated process;
-- assert the no-chooser behavior unconditionally, but only assert the link
-- itself exists when creation actually succeeded (see mutate_spec.lua for the
-- same accommodation).
do
  local tmp = (TMP_ROOT .. "/units-linkcreate-dir"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/src/target_dir", "p")
  vim.fn.mkdir(tmp .. "/dest", "p")
  local target = tmp .. "/src/target_dir"

  package.loaded["ui.kit"] = {
    input = function(opts)
      opts.on_submit(target)
    end,
  }
  local confirm_choice_called = false
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_, _, on_choice)
    confirm_choice_called = true
    on_choice("Symlink")
  end
  package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stub

  local cur_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-linkcreate-dir",
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
    adapter = "units-stub-linkcreate-dir",
    features = { link_create = { enabled = true } },
  })

  ft.feature("link_create").create()

  check(
    "link_create dir target: no Symlink/Hardlink chooser (directories can't be hardlinked)",
    not confirm_choice_called
  )
  local link_stat = (vim.uv or vim.loop).fs_lstat(tmp .. "/dest/target_dir")
  if not link_stat then
    print(
      "  note link_create: directory symlink not created in this environment (needs elevation on Windows)"
    )
  else
    check("link_create dir target: symlink created", link_stat.type == "link")
  end

  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.link_create"] = nil
end

-- ── link_create mark/paste: explicit path, staged across two pastes ─────────
-- The fast-path pair, as opposed to `create()`'s prompt: mark once, paste into
-- several nodes without re-marking or being asked Symlink/Hardlink each time.
-- Link kind is picked by platform + source type instead (see M.paste), which
-- is exactly the choice that avoids the Windows-symlink-needs-elevation
-- problem the two tests above have to work around: a file on Windows gets an
-- (unprivileged) hardlink, elsewhere an (unprivileged) symlink -- so, unlike
-- those two, this one asserts the created link's kind unconditionally.
do
  local tmp = (TMP_ROOT .. "/units-linkmark-explicit"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.mkdir(tmp .. "/dest1", "p")
  vim.fn.mkdir(tmp .. "/dest2", "p")
  local target = tmp .. "/src/target.txt"
  vim.fn.writefile({ "hello mark" }, target)

  local cur_node = { path = tmp .. "/dest1", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-linkmark-explicit",
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
    adapter = "units-stub-linkmark-explicit",
    features = { link_create = { enabled = true } },
  })
  local lc = ft.feature("link_create")

  local captured
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured = m
  end
  lc.mark(target)
  check(
    "link_create mark: explicit path notifies with the marked file's name",
    captured ~= nil and captured:find("target.txt", 1, true) ~= nil,
    tostring(captured)
  )

  lc.paste()
  vim.notify = orig_notify

  check(
    "link_create mark/paste: link created in dest1/, with matching content",
    vim.fn.filereadable(tmp .. "/dest1/target.txt") == 1
      and table.concat(vim.fn.readfile(tmp .. "/dest1/target.txt"), "\n") == "hello mark"
  )

  local platform = require("filetree.util.platform")
  local link_stat = (vim.uv or vim.loop).fs_lstat(tmp .. "/dest1/target.txt")
  check(
    "link_create mark/paste: file link kind matches the platform (hardlink on Windows, symlink elsewhere)",
    link_stat ~= nil and link_stat.type == (platform.is_windows() and "file" or "link"),
    vim.inspect(link_stat)
  )

  -- Move to a second destination and paste again -- the marked source must
  -- still be there, i.e. paste() does not consume/clear it (a link, unlike a
  -- cut, never removes the source, so re-pasting the same mark elsewhere is
  -- the whole point of a "mark once" step).
  cur_node = { path = tmp .. "/dest2", type = "directory" }
  lc.paste()

  check(
    "link_create mark/paste: mark survives a paste -- second paste into dest2/ also lands",
    vim.fn.filereadable(tmp .. "/dest2/target.txt") == 1
      and table.concat(vim.fn.readfile(tmp .. "/dest2/target.txt"), "\n") == "hello mark"
  )

  package.loaded["filetree.features.fileops.link_create"] = nil
end

-- ── link_create mark: no path -- tree node under cursor, else focused buffer ─
do
  local tmp = (TMP_ROOT .. "/units-linkmark-implicit"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dest", "p")
  local node_file = tmp .. "/node.txt"
  local buffer_file = tmp .. "/buffer.txt"
  vim.fn.writefile({ "from node" }, node_file)
  vim.fn.writefile({ "from buffer" }, buffer_file)

  local cur_node = { path = node_file, type = "file" }
  local stub = setmetatable({
    name = "units-stub-linkmark-implicit",
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
    adapter = "units-stub-linkmark-implicit",
    features = { link_create = { enabled = true } },
  })
  local lc = ft.feature("link_create")

  -- Focused buffer = a fake tree buffer (filetype "neo-tree", matching
  -- buffer.is_tree_buffer()'s fallback list) -- mark() with no path must
  -- prefer the node under the cursor over anything buffer-related.
  local tree_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(tree_buf)
  vim.bo[tree_buf].filetype = "neo-tree"

  lc.mark()
  cur_node = { path = tmp .. "/dest", type = "directory" }
  lc.paste()
  check(
    "link_create mark: no path, tree buffer focused -- marks the node under the cursor",
    vim.fn.filereadable(tmp .. "/dest/node.txt") == 1
      and table.concat(vim.fn.readfile(tmp .. "/dest/node.txt"), "\n") == "from node"
  )

  -- Now focus a real, ordinary file buffer instead -- mark() with no path
  -- must fall back to it once the tree is no longer the focused buffer.
  vim.cmd("edit " .. vim.fn.fnameescape(buffer_file))
  lc.mark()
  lc.paste()
  check(
    "link_create mark: no path, editor buffer focused -- marks the focused buffer's file",
    vim.fn.filereadable(tmp .. "/dest/buffer.txt") == 1
      and table.concat(vim.fn.readfile(tmp .. "/dest/buffer.txt"), "\n") == "from buffer"
  )

  package.loaded["filetree.features.fileops.link_create"] = nil
end

-- ── link_create paste: no marked source, and already-exists guard ───────────
do
  local tmp = (TMP_ROOT .. "/units-linkmark-guards"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dest", "p")
  local target = tmp .. "/target.txt"
  vim.fn.writefile({ "guarded" }, target)

  local cur_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-linkmark-guards",
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
    adapter = "units-stub-linkmark-guards",
    features = { link_create = { enabled = true } },
  })
  local lc = ft.feature("link_create")

  local captured
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured = m
  end

  lc.paste() -- nothing marked yet
  check(
    "link_create paste: no source marked -- warns instead of erroring",
    captured ~= nil and captured:lower():find("no link source marked", 1, true) ~= nil,
    tostring(captured)
  )

  lc.mark(target)
  vim.fn.writefile({ "already here" }, tmp .. "/dest/target.txt") -- pre-existing collision
  captured = nil
  lc.paste()
  vim.notify = orig_notify

  check(
    "link_create paste: existing name at the destination is not overwritten",
    captured ~= nil and captured:lower():find("already exists", 1, true) ~= nil,
    tostring(captured)
  )
  check(
    "link_create paste: the pre-existing file's content is untouched",
    table.concat(vim.fn.readfile(tmp .. "/dest/target.txt"), "\n") == "already here"
  )

  package.loaded["filetree.features.fileops.link_create"] = nil
end

-- ── link_create paste: EXDEV on hardlink falls back to a real symlink ───────
-- Regression coverage for a real report: paste() picking "Hardlink" for a
-- file on Windows, then failing outright the moment source and destination
-- turn out to be on different drives -- a hard link can never cross
-- filesystems/drives on any OS, unlike a move (see filetree.util.mutate,
-- which already falls back for exactly this reason). do_create is now
-- supposed to retry as a symlink when hardlink fails with EXDEV.
--
-- Two real temp dirs under TMP_ROOT can't reproduce EXDEV (same drive), so
-- mutate.hardlink is faked to return it; mutate.symlink is left real, so the
-- fallback this exercises actually writes a link to disk. `platform.is_windows`
-- is also forced true so `paste()` picks "Hardlink" regardless of the machine
-- actually running this suite.
do
  local tmp = (TMP_ROOT .. "/units-linkmark-exdev"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dest", "p")
  local target = tmp .. "/target.txt"
  vim.fn.writefile({ "cross device" }, target)

  local cur_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-linkmark-exdev",
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
    adapter = "units-stub-linkmark-exdev",
    features = { link_create = { enabled = true } },
  })
  local lc = ft.feature("link_create")

  local platform = require("filetree.util.platform")
  local mutate = require("lib.nvim.cross.fs.mutate")
  local orig_is_windows = platform.is_windows
  local orig_hardlink = mutate.hardlink
  ---@diagnostic disable-next-line: duplicate-set-field
  platform.is_windows = function()
    return true
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  mutate.hardlink = function(_, _)
    return false, "EXDEV: cross-device link not permitted: fake"
  end

  lc.mark(target)
  local captured
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured = m
  end
  lc.paste()
  vim.notify = orig_notify
  platform.is_windows = orig_is_windows
  mutate.hardlink = orig_hardlink

  local msg = (captured or ""):lower()
  if msg:find("used a symlink instead", 1, true) then
    check("link_create paste: EXDEV on hardlink falls back to a real symlink", true)
    local link_stat = (vim.uv or vim.loop).fs_lstat(tmp .. "/dest/target.txt")
    check(
      "link_create paste: the fallback link actually exists as a symlink",
      link_stat ~= nil and link_stat.type == "link",
      vim.inspect(link_stat)
    )
  elseif msg:find("failed to create symlink", 1, true) then
    -- The fallback was attempted (proving the fix works) but this environment
    -- can't create a symlink at all -- same accommodation as the dir-target
    -- test above (needs Developer Mode/elevation on Windows).
    print(
      "  note link_create: EXDEV fallback attempted a symlink, but this environment can't create one -- "
        .. tostring(captured)
    )
  else
    -- Neither branch matched: the fallback was never attempted at all (e.g.
    -- this fix regressed and paste() is still reporting the raw EXDEV error).
    check(
      "link_create paste: EXDEV on hardlink triggers the symlink fallback",
      false,
      tostring(captured)
    )
  end

  package.loaded["filetree.features.fileops.link_create"] = nil
end

-- ── filetree.util.symlink: fresh lstat/stat pair, no adapter node needed ─────
do
  local tmp = (TMP_ROOT .. "/units-symlink-util"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local real_file = tmp .. "/real.txt"
  vim.fn.writefile({ "real" }, real_file)

  local symlink_util = require("filetree.util.symlink")
  local mutate = require("lib.nvim.cross.fs.mutate")

  check("symlink util: a plain file is not a link", not symlink_util.is_link(real_file))
  check("symlink util: a plain file is not broken", not symlink_util.is_broken(real_file))
  check("symlink util: no target for a plain file", symlink_util.read_target(real_file) == nil)

  local ok_valid = mutate.symlink(real_file, tmp .. "/valid_link.txt", false)
  local ok_broken = mutate.symlink(tmp .. "/does_not_exist.txt", tmp .. "/broken_link.txt", false)

  if not ok_valid or not ok_broken then
    print("  note symlink util: could not create a test symlink in this environment, skipping")
  else
    check("symlink util: a valid symlink is a link", symlink_util.is_link(tmp .. "/valid_link.txt"))
    check(
      "symlink util: a valid symlink is not broken",
      not symlink_util.is_broken(tmp .. "/valid_link.txt")
    )
    check(
      "symlink util: a broken symlink is a link",
      symlink_util.is_link(tmp .. "/broken_link.txt")
    )
    check(
      "symlink util: a broken symlink reports broken",
      symlink_util.is_broken(tmp .. "/broken_link.txt")
    )
    check(
      "symlink util: read_target returns something for a broken link",
      symlink_util.read_target(tmp .. "/broken_link.txt") ~= nil
    )
  end
end

-- ── broken_link_notify: warns when a just-opened buffer is a dangling ──────
-- symlink's target ────────────────────────────────────────────────────────
-- Opening a broken symlink otherwise looks exactly like opening any other
-- nonexistent path -- a silent, empty [New] buffer. A single BufNewFile
-- autocmd (backend-agnostic: not tied to the tree's own <CR>) must warn.
do
  local tmp = (TMP_ROOT .. "/units-brokenlinknotify"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local real_file = tmp .. "/real.txt"
  vim.fn.writefile({ "real" }, real_file)
  local valid_link = tmp .. "/valid_link.txt"
  local broken_link = tmp .. "/broken_link.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_valid = mutate.symlink(real_file, valid_link, false)
  local ok_broken = mutate.symlink(tmp .. "/gone.txt", broken_link, false)

  if not ok_valid or not ok_broken then
    print(
      "  note broken_link_notify: could not create a test symlink in this environment, skipping"
    )
  else
    local stub = setmetatable({
      name = "units-stub-brokenlinknotify",
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
      adapter = "units-stub-brokenlinknotify",
      features = { broken_link_notify = { enabled = true } },
    })

    local captured = {}
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(m)
      captured[#captured + 1] = m
    end
    vim.cmd("edit " .. vim.fn.fnameescape(broken_link))
    vim.cmd("edit " .. vim.fn.fnameescape(valid_link))
    vim.cmd("edit " .. vim.fn.fnameescape(real_file))
    vim.notify = orig_notify

    local joined = table.concat(captured, "\n")
    check(
      "broken_link_notify: warns when opening a broken symlink's target",
      joined:lower():find("broken symlink", 1, true) ~= nil
        and joined:find(broken_link, 1, true) ~= nil,
      joined
    )
    check(
      "broken_link_notify: no warning for a valid symlink's target",
      not joined:find(valid_link, 1, true),
      joined
    )
    check(
      "broken_link_notify: no warning for an ordinary existing file",
      not joined:find(real_file, 1, true),
      joined
    )

    require("filetree").feature("broken_link_notify").teardown()
  end
end

-- ── link_create check/checkall: symlink vs plain file, ok vs broken ──────────
do
  local tmp = (TMP_ROOT .. "/units-linkcheck"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local real_file = tmp .. "/real.txt"
  vim.fn.writefile({ "real" }, real_file)
  local valid_link = tmp .. "/valid_link.txt"
  local broken_link = tmp .. "/broken_link.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_valid = mutate.symlink(real_file, valid_link, false)
  local ok_broken = mutate.symlink(tmp .. "/gone.txt", broken_link, false)

  if not ok_valid or not ok_broken then
    print("  note link_create check: could not create a test symlink in this environment, skipping")
  else
    local cur_node = { path = broken_link, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkcheck",
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
      adapter = "units-stub-linkcheck",
      features = { link_create = { enabled = true }, marks = { enabled = true } },
    })
    local lc = ft.feature("link_create")
    local marks = ft.feature("marks")

    -- Implicit resolution (no explicit path) prefers the tree's cursor node
    -- ONLY while a tree buffer is focused (see the link_create mark implicit-
    -- resolution test above) -- fake one here so this doesn't fall through to
    -- whatever ordinary buffer an earlier test in this same process left focused.
    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(tree_buf)
    vim.bo[tree_buf].filetype = "neo-tree"

    local captured
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(m)
      captured = m
    end
    lc.check() -- cursor is on the broken link
    check(
      "link_create check: reports a broken symlink",
      captured ~= nil and captured:lower():find("broken", 1, true) ~= nil,
      tostring(captured)
    )

    captured = nil
    lc.check(valid_link)
    check(
      "link_create check: reports an ok symlink for an explicit path",
      captured ~= nil and captured:lower():find("ok", 1, true) ~= nil,
      tostring(captured)
    )

    captured = nil
    lc.check(real_file)
    check(
      "link_create check: a plain file is reported as not a symlink",
      captured ~= nil and captured:lower():find("not a symlink", 1, true) ~= nil,
      tostring(captured)
    )
    vim.notify = orig_notify

    marks.toggle(valid_link)
    marks.toggle(broken_link)
    marks.toggle(real_file)

    local captured_lines
    local orig_kit = package.loaded["ui.kit"]
    package.loaded["ui.kit"] = {
      viewer = function(opts)
        captured_lines = opts.lines
      end,
    }
    lc.check_all()
    package.loaded["ui.kit"] = orig_kit

    local joined = captured_lines and table.concat(captured_lines, "\n") or ""
    check(
      "link_create checkall: summary counts 1 ok, 1 broken, 1 skipped",
      joined:find("1 ok, 1 broken", 1, true) ~= nil
        and joined:find("1 not a symlink", 1, true) ~= nil,
      joined
    )

    marks.clear_all()
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create delete: only removes symlinks, never a non-symlink mark ─────
do
  local tmp = (TMP_ROOT .. "/units-linkdelete"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local real_file = tmp .. "/real.txt"
  vim.fn.writefile({ "keep me" }, real_file)
  local broken_link = tmp .. "/broken_link.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/gone.txt", broken_link, false)

  if not ok_broken then
    print(
      "  note link_create delete: could not create a test symlink in this environment, skipping"
    )
  else
    local cur_node = { path = real_file, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkdelete",
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
      adapter = "units-stub-linkdelete",
      features = {
        link_create = { enabled = true },
        marks = { enabled = true },
        -- permanent + confirm=false: a real, synchronous, no-subprocess delete
        -- (see trash's do_trash), so the assertions below can run right after
        -- lc.delete() returns instead of waiting on an async trash process.
        trash = { enabled = true, mode = "permanent", confirm = false },
      },
    })
    local lc = ft.feature("link_create")
    local marks = ft.feature("marks")

    -- Mark BOTH the broken symlink and the plain file -- delete() must remove
    -- only the former, skip (never touch) the latter.
    marks.toggle(broken_link)
    marks.toggle(real_file)

    local captured
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(m)
      captured = (captured and (captured .. "\n") or "") .. m
    end
    lc.delete()
    vim.notify = orig_notify

    check(
      "link_create delete: the marked symlink is gone",
      (vim.uv or vim.loop).fs_lstat(broken_link) == nil
    )
    check(
      "link_create delete: the marked plain file is untouched",
      vim.fn.filereadable(real_file) == 1
        and table.concat(vim.fn.readfile(real_file), "\n") == "keep me"
    )
    check(
      "link_create delete: notifies that the non-symlink mark was skipped",
      captured ~= nil and captured:lower():find("non%-symlink node%(s%) skipped", 1, false) ~= nil
        or captured:lower():find("non-symlink node(s) skipped", 1, true) ~= nil,
      tostring(captured)
    )

    marks.clear_all()
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: gopath.nvim absent -- falls back to delete/keep ──────
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-nogopath"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local broken_link = tmp .. "/broken_link.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/gone.txt", broken_link, false)

  if not ok_broken then
    print(
      "  note link_create repair: could not create a test symlink in this environment, skipping"
    )
  else
    -- Force the gopath.nvim require to fail regardless of whether it happens
    -- to be installed on this machine's runtimepath, so this test always
    -- exercises the "not installed" branch.
    package.preload["gopath.resolvers.common.tailsearch"] = function()
      error("gopath.nvim not on rtp (test double)")
    end

    local captured_choices
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.confirm_choice"] = function(_, choices, on_choice)
      captured_choices = choices
      on_choice("Delete symlink instead")
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stub

    local cur_node = { path = broken_link, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-nogopath",
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
      adapter = "units-stub-linkrepair-nogopath",
      features = {
        link_create = { enabled = true },
        trash = { enabled = true, mode = "permanent", confirm = false },
      },
    })
    local lc = ft.feature("link_create")

    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(tree_buf)
    vim.bo[tree_buf].filetype = "neo-tree"

    lc.repair()

    check(
      "link_create repair (no gopath): offers Delete/Keep, not a candidate list",
      captured_choices ~= nil
        and captured_choices[1] == "Delete symlink instead"
        and captured_choices[2] == "Keep broken (do nothing)",
      vim.inspect(captured_choices)
    )
    check(
      "link_create repair (no gopath): 'Delete symlink instead' actually removes it",
      (vim.uv or vim.loop).fs_lstat(broken_link) == nil
    )

    package.preload["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["filetree.util.confirm_choice"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: gopath.nvim finds a candidate -- relinks in place ────
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-candidate"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/newloc", "p")
  local new_target = tmp .. "/newloc/target.txt"
  vim.fn.writefile({ "moved" }, new_target)
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (candidate): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      sanitize = function(raw)
        return vim.fs.basename((raw:gsub("\\", "/")))
      end,
      cache_lookup = function(_)
        return { new_target }
      end,
      guess_roots = function()
        return { tmp }
      end,
    }
    local captured_items
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(items, _, on_choice)
      captured_items = items
      on_choice(new_target, 1)
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-candidate",
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
      adapter = "units-stub-linkrepair-candidate",
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")

    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(tree_buf)
    vim.bo[tree_buf].filetype = "neo-tree"

    lc.repair()

    check(
      "link_create repair (candidate): the picker was offered the found candidate plus escape hatches",
      captured_items ~= nil
        and vim.tbl_contains(captured_items, new_target)
        and vim.tbl_contains(captured_items, "Delete symlink instead")
        and vim.tbl_contains(captured_items, "Keep broken (do nothing)"),
      vim.inspect(captured_items)
    )
    check(
      "link_create repair (candidate): the symlink now resolves",
      (vim.uv or vim.loop).fs_stat(link_path) ~= nil
    )
    check(
      "link_create repair (candidate): reading through the relinked symlink gives the new target's content",
      vim.fn.filereadable(link_path) == 1
        and table.concat(vim.fn.readfile(link_path), "\n") == "moved"
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: unsafe roots/hits filtered on the LIVE search path ──
-- too, case-insensitively (Windows) ──────────────────────────────────────────
-- The other test below covers the cache_lookup() half of find_repair_candidates
-- (an early return before find_async is ever reached); this one drives the
-- find_async() half specifically -- both the ROOT LIST handed to it (must
-- exclude stdpath cache/data/state before the walk even starts) and its HITS
-- (must be filtered again, since gopath's own persisted cache could already
-- hold one). Also exercises the exact real-world mismatch that slipped past an
-- earlier, case-sensitive version of this filter: Windows compares paths
-- case-insensitively, and an env/stdpath-derived casing commonly disagrees
-- with a filesystem-walk-derived one for the same directory.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-liveunsafe"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  local fake_cache = tmp .. "/FakeCache"
  vim.fn.mkdir(fake_cache .. "/undo", "p")
  vim.fn.mkdir(tmp .. "/newloc", "p")
  local safe_hit = tmp .. "/newloc/target.txt"
  vim.fn.writefile({ "moved" }, safe_hit)
  local unsafe_hit = fake_cache .. "/undo/mangled_undofile"
  vim.fn.writefile({ "garbage" }, unsafe_hit)
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (live unsafe): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      sanitize = function(raw)
        return vim.fs.basename((raw:gsub("\\", "/")))
      end,
      cache_lookup = function(_)
        return {} -- empty -- forces the fallthrough to find_async
      end,
      -- Mirrors gopath's real default roots including a stdpath dir --
      -- deliberately a DIFFERENT case than the fake stdpath("cache") below,
      -- since that mismatch is exactly the real-world bug being guarded against.
      guess_roots = function(_)
        return { tmp, fake_cache:upper() }
      end,
      -- The stubbed find_async below ignores which suffix it's called with
      -- and always returns the same fixed hits, so a single passthrough
      -- suffix is enough here.
      suffix_candidates = function(t, _)
        return { t }
      end,
    }
    local captured_roots
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(_, opts, on_done)
        captured_roots = opts.roots
        on_done({ safe_hit, unsafe_hit })
      end,
    }
    local captured_items
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(items, _, on_choice)
      captured_items = items
      on_choice(nil, nil) -- only care what was offered, not what gets picked
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
      if what == "cache" then return fake_cache:lower() end -- yet another casing
      return orig_stdpath(what)
    end

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-liveunsafe",
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
      adapter = "units-stub-linkrepair-liveunsafe",
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")

    lc.repair(link_path)
    vim.fn.stdpath = orig_stdpath
    platform.is_windows = orig_is_windows

    check(
      "link_create repair (live unsafe): the differently-cased unsafe root is stripped before find_async runs",
      captured_roots ~= nil and not vim.tbl_contains(captured_roots, fake_cache:upper()),
      vim.inspect(captured_roots)
    )
    check(
      "link_create repair (live unsafe): the safe root still reaches find_async",
      captured_roots ~= nil and vim.tbl_contains(captured_roots, tmp),
      vim.inspect(captured_roots)
    )
    check(
      "link_create repair (live unsafe): the picker gets only the safe hit, never the unsafe one",
      captured_items ~= nil
        and vim.tbl_contains(captured_items, safe_hit)
        and not vim.tbl_contains(captured_items, unsafe_hit),
      vim.inspect(captured_items)
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: a stale multi-segment tail is searched by basename ──
-- Regression coverage for the real bug find_repair_candidates' basename
-- extraction guards against: gopath's tailsearch.sanitize() only normalizes
-- slashes/quotes/drive letters, it does NOT collapse a multi-segment relative
-- tail down to a single path segment -- so a moved file whose recorded
-- parent directory no longer matches its real location (the "gone/" ->
-- "ROADMAP/IDEAS/" regression from the commit message) must be searched by
-- basename alone, or find_async's exact-suffix match would never find it.
-- Unlike every other repair test in this file, `sanitize` and
-- `suffix_candidates` here are NOT stubbed down to an identity passthrough --
-- sanitize keeps the tail multi-segment and suffix_candidates does a real
-- basename extraction, so this actually exercises find_repair_candidates'
-- own basename-extraction line instead of a stub that already did the work.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-staletail"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/newloc", "p")
  local new_target = tmp .. "/newloc/target.txt"
  vim.fn.writefile({ "moved" }, new_target)
  local link_path = tmp .. "/target.txt"
  local stale_target = tmp .. "/gone/target.txt" -- never created: the moved-away parent

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(stale_target, link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (stale tail): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      -- Real gopath.sanitize() only normalizes slashes/quotes/drive letters --
      -- it does NOT collapse a multi-segment relative tail to a basename.
      sanitize = function(raw)
        return (raw:gsub("\\", "/"))
      end,
      cache_lookup = function(_)
        return {} -- empty -- forces the fallthrough to find_async
      end,
      guess_roots = function()
        return { tmp }
      end,
      -- A real basename extraction, not an identity passthrough like every
      -- other test in this file uses -- this is what
      -- find_repair_candidates' own basename-search line depends on.
      suffix_candidates = function(t, _)
        return { vim.fs.basename(t) }
      end,
    }
    -- Only a real basename match ("target.txt") resolves a hit -- unlike a
    -- stub that returns the same hit unconditionally, this also ties the
    -- "the symlink now resolves" check below to the basename extraction
    -- actually having happened, not just to find_async having been called.
    local captured_search_term
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(term, _, on_done)
        captured_search_term = term
        on_done(term == vim.fs.basename(new_target) and { new_target } or {})
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(items, _, on_choice)
      on_choice(items[1], 1)
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-staletail",
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
      adapter = "units-stub-linkrepair-staletail",
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")

    local tree_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(tree_buf)
    vim.bo[tree_buf].filetype = "neo-tree"

    lc.repair()

    check(
      "link_create repair (stale tail): find_async is searched by basename, not the stale full tail",
      captured_search_term == "target.txt",
      vim.inspect(captured_search_term)
    )
    check(
      "link_create repair (stale tail): the symlink now resolves to the moved file",
      (vim.uv or vim.loop).fs_stat(link_path) ~= nil
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: a stray undofile-shaped hit is filtered out ─────────
-- Regression coverage for a real report: gopath.nvim's default search roots
-- include stdpath("cache")/stdpath("data"), where Neovim's own undo directory
-- lives; an unrelated file's undofile (named by mangling ITS real path with
-- "%" in place of separators) can spuriously tail-match a broken link's
-- basename and get offered as a "candidate" -- picking it relinks the symlink
-- to binary undofile garbage. `find_repair_candidates` must drop any hit
-- under one of those stdpaths before it ever reaches the picker.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-unsafe"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local fake_cache = tmp .. "/fake_cache"
  vim.fn.mkdir(fake_cache .. "/undo", "p")
  local unsafe_hit = fake_cache .. "/undo/mangled_undofile"
  vim.fn.writefile({ "not a real target" }, unsafe_hit)
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (unsafe root): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      sanitize = function(raw)
        return vim.fs.basename((raw:gsub("\\", "/")))
      end,
      cache_lookup = function(_)
        return { unsafe_hit } -- the ONLY hit -- must be filtered to zero, not offered
      end,
      guess_roots = function()
        return { tmp }
      end,
    }
    local select_called = false
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(_, _, on_choice)
      select_called = true
      on_choice(nil, nil)
    end
    local captured_choices
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.confirm_choice"] = function(_, choices, on_choice)
      captured_choices = choices
      on_choice("Keep broken (do nothing)")
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local orig_stdpath = vim.fn.stdpath
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.stdpath = function(what)
      if what == "cache" then return fake_cache end
      return orig_stdpath(what)
    end

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-unsafe",
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
      adapter = "units-stub-linkrepair-unsafe",
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")

    lc.repair(link_path)
    vim.fn.stdpath = orig_stdpath

    check(
      "link_create repair (unsafe root): the stdpath('cache') hit is never offered in the picker",
      not select_called
    )
    check(
      "link_create repair (unsafe root): falls through to the no-candidate delete/keep choice instead",
      captured_choices ~= nil
        and captured_choices[1] == "Delete symlink instead"
        and captured_choices[2] == "Keep broken (do nothing)",
      vim.inspect(captured_choices)
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.util.confirm_choice"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: repair_roots is a SECOND pass, after fast roots ─────
-- come up empty ───────────────────────────────────────────────────────────
-- The other half of the same real report: a broken link's real target can
-- live entirely outside the current project (a different repo altogether),
-- which gopath's own buffer-dir/cwd/git-root guessing has no way to reach.
-- `features.link_create.repair_roots` is the configured escape hatch -- but
-- (per a real measurement against a real, large Neovim config) it is only
-- searched as a SECOND pass, once the fast default roots already came up
-- empty, to avoid paying a potentially large directory walk's cost on every
-- repair. Assert both: stage 1 (gopath's own `guess_roots()`, no `extra` arg
-- anymore) never includes it, and stage 2 does.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-extraroot"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local link_path = tmp .. "/target.txt"
  local extra_root = tmp .. "/sibling_repo"
  vim.fn.mkdir(extra_root, "p")

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (repair_roots): could not create a test symlink in this environment, skipping"
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
      guess_roots = function()
        return { tmp } -- stage 1's fast roots only -- no `extra` param anymore
      end,
      suffix_candidates = function(t, _)
        return { t }
      end,
    }
    local find_calls = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(_, opts, on_done)
        find_calls[#find_calls + 1] = opts.roots
        on_done({}) -- both passes stub-empty -- only the ROOTS searched matter here
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.progress"] =
      { create = function(_) end, set_style = function(_) end }
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-extraroot",
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
      adapter = "units-stub-linkrepair-extraroot",
      features = { link_create = { enabled = true, repair_roots = { extra_root } } },
    })
    local lc = ft.feature("link_create")

    lc.repair(link_path)

    check(
      "link_create repair (repair_roots): stage 1 (fast roots) does NOT include the configured extra root",
      find_calls[1] ~= nil and not vim.tbl_contains(find_calls[1], extra_root),
      vim.inspect(find_calls)
    )
    check(
      "link_create repair (repair_roots): stage 2 (after stage 1 found nothing) DOES search the extra root",
      find_calls[2] ~= nil and vim.tbl_contains(find_calls[2], extra_root),
      vim.inspect(find_calls)
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.progress"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: repair_nvim_config_root defaults to searching ──────
-- stdpath("config") in stage 2, and can be explicitly turned back off ──────
-- A real measurement against a real, large Neovim config (5.8k files/737MB,
-- worst case: nothing found, full walk) came back in ~0.1s, so unlike an
-- earlier (mistaken) measurement, this is safe to ship on by default. It
-- still only runs as stage 2, after the fast default roots (stage 1) come
-- up empty -- this checks the shipped default reaches it out of the box,
-- and that setting it back to `false` opts back out.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-cfgroot"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (config root default): could not create a test symlink in this environment, skipping"
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
      guess_roots = function()
        return { tmp }
      end,
      suffix_candidates = function(t, _)
        return { t }
      end,
    }
    local find_calls = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(_, opts, on_done)
        find_calls[#find_calls + 1] = opts.roots
        on_done({})
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.progress"] =
      { create = function(_) end, set_style = function(_) end }
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-cfgroot",
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
      adapter = "units-stub-linkrepair-cfgroot",
      -- No override -- exercises the shipped default (on) first.
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")
    local expect = require("filetree.util.path").slashify(vim.fn.stdpath("config"))

    lc.repair(link_path)
    check(
      "link_create repair (config root default): stage 2 searches stdpath('config') out of the box",
      find_calls[2] ~= nil and vim.tbl_contains(find_calls[2], expect),
      vim.inspect(find_calls) .. " / expected " .. expect
    )

    find_calls = {}
    package.loaded["filetree.features.fileops.link_create"] = nil
    ft.setup({
      adapter = "units-stub-linkrepair-cfgroot",
      -- Note: `repair_roots` can't be cleared back to "nothing" here via a
      -- config override -- `vim.tbl_deep_extend("force", ...)` merges a
      -- table value by INDEX, so a shorter (or empty) override table simply
      -- fails to overwrite the default's existing indices, it doesn't clear
      -- them. So this only isolates `repair_nvim_config_root`'s own effect
      -- (stdpath("config") specifically), not "no stage 2 at all" -- stage 2
      -- can still run for $REPOS_DIR (set for real on the machine running
      -- this suite), just without stdpath("config") in it.
      features = { link_create = { enabled = true, repair_nvim_config_root = false } },
    })
    lc = ft.feature("link_create")

    lc.repair(link_path)
    check(
      "link_create repair (config root disabled): stage 2 no longer includes stdpath('config')",
      find_calls[2] == nil or not vim.tbl_contains(find_calls[2], expect),
      vim.inspect(find_calls) .. " / must not contain " .. expect
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.progress"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: a slow second pass gets a one-time, actionable ─────
-- hint ──────────────────────────────────────────────────────────────────────
-- The default search is fast in practice (see above), but "usually fast"
-- isn't "always fast" (a network drive, an exceptionally large repos root),
-- so a genuinely slow run must not stay silently slow forever --
-- `repair_search_slow_hint_ms` notifies with actionable config guidance.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-slowhint"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (slow hint): could not create a test symlink in this environment, skipping"
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
      guess_roots = function()
        return { tmp }
      end,
      suffix_candidates = function(t, _)
        return { t }
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(_, _, on_done)
        -- Simulate a slow stage 2 without an actual multi-second sleep in
        -- the test suite: the code under test measures elapsed wall time
        -- around this call, so a real (short) busy-wait is enough to push
        -- it over a tiny configured threshold below, deterministically.
        local target = (vim.uv or vim.loop).hrtime() + 5 * 1e6 -- ~5ms
        while (vim.uv or vim.loop).hrtime() < target do
        end
        on_done({})
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.progress"] =
      { create = function(_) end, set_style = function(_) end }
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-slowhint",
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
      adapter = "units-stub-linkrepair-slowhint",
      -- Threshold set below the simulated ~5ms delay, so the hint reliably
      -- fires in this test without actually being slow for real.
      features = { link_create = { enabled = true, repair_search_slow_hint_ms = 1 } },
    })
    local lc = ft.feature("link_create")

    -- Accumulate every notify call -- the slow-hint warning fires before
    -- the final "no candidate" info notify, and a single-message capture
    -- would just be overwritten by that later, unrelated call.
    local captured = ""
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(m)
      captured = captured .. tostring(m) .. "\n"
    end
    lc.repair(link_path)
    vim.notify = orig_notify

    check(
      "link_create repair (slow hint): fires with actionable config guidance once the threshold is exceeded",
      captured:find("repair_roots", 1, true) ~= nil
        and captured:find("repair_nvim_config_root", 1, true) ~= nil,
      tostring(captured)
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.progress"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: find_async is NEVER called with an empty roots ─────
-- list -- regression coverage for a real bug: gopath.nvim's own find_async
-- silently substitutes ITS OWN default_roots() (cwd + stdpath config/data/
-- cache) for an empty/nil `opts.roots`, exactly reintroducing the search
-- space stage 1's filtering exists to exclude. A stage-1 fast_roots list
-- that filters down to nothing (e.g. cwd/bufdir/git-root all collapse to
-- stdpath("config"), which the config-exclusion filter then removes) must
-- skip find_async for that stage entirely rather than calling it with {}.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-emptyroots"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (empty roots): could not create a test symlink in this environment, skipping"
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
      -- Only entry is stdpath("config") itself -- stage 1's own filtering
      -- must remove it, leaving fast_roots empty.
      guess_roots = function()
        return { vim.fn.stdpath("config") }
      end,
      suffix_candidates = function(t, _)
        return { t }
      end,
    }
    local saw_empty_roots = false
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.truncated.finder"] = {
      find_async = function(_, opts, on_done)
        if not opts.roots or #opts.roots == 0 then saw_empty_roots = true end
        on_done({})
      end,
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.progress"] =
      { create = function(_) end, set_style = function(_) end }
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-emptyroots",
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
      adapter = "units-stub-linkrepair-emptyroots",
      -- repair_nvim_config_root=false so stage 2 has nothing configured
      -- either (repair_roots' own $REPOS_DIR default can't be cleared via
      -- override -- see @types/config.lua's doc comment -- so this test
      -- only asserts the specific "never call find_async with {}" guarantee,
      -- not "no find_async call happens at all").
      features = { link_create = { enabled = true, repair_nvim_config_root = false } },
    })
    local lc = ft.feature("link_create")

    lc.repair(link_path)

    check(
      "link_create repair (empty roots): find_async is never called with an empty/nil roots list",
      not saw_empty_roots
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["gopath.truncated.finder"] = nil
    package.loaded["filetree.util.progress"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: relink() re-checks link_path is STILL a symlink ────
-- immediately before deleting it -- regression coverage for a TOCTOU: repair
-- runs an async search plus an interactive picker between the initial
-- is_link/is_broken check and the eventual delete-then-recreate in relink().
-- If something else replaces link_path with a real file during that window,
-- relink() must refuse instead of silently fs_unlink-ing that real file.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-toctou"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/newloc", "p")
  local new_target = tmp .. "/newloc/target.txt"
  vim.fn.writefile({ "moved" }, new_target)
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (TOCTOU): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      sanitize = function(raw)
        return vim.fs.basename((raw:gsub("\\", "/")))
      end,
      cache_lookup = function(_)
        return { new_target } -- single candidate -> no picker needed to reach relink()
      end,
      guess_roots = function()
        return { tmp }
      end,
    }
    -- Simulate the race: by the time the (stubbed) picker "answers", replace
    -- link_path with a REAL file -- something else touched it while repair
    -- was working. Even with a single candidate, offer_repair still routes
    -- through ui_select (M.select is only skipped for the zero-candidate
    -- case), so stubbing it here is the right seam.
    local replaced_content = "real file, must survive untouched"
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(_, _, on_choice)
      vim.fn.delete(link_path)
      vim.fn.writefile({ replaced_content }, link_path)
      on_choice(new_target, 1)
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-toctou",
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
      adapter = "units-stub-linkrepair-toctou",
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")

    local captured
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(m)
      captured = m
    end
    lc.repair(link_path)
    vim.notify = orig_notify

    check(
      "link_create repair (TOCTOU): relink refuses once link_path is no longer a symlink",
      captured ~= nil and captured:lower():find("no longer a symlink", 1, true) ~= nil,
      tostring(captured)
    )
    check(
      "link_create repair (TOCTOU): the real file that replaced it survives untouched",
      vim.fn.filereadable(link_path) == 1
        and table.concat(vim.fn.readfile(link_path), "\n") == replaced_content
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── link_create repair: relink() re-checks new_target STILL EXISTS ──────────
-- immediately before deleting the old link -- regression coverage for the
-- other half of the same TOCTOU window the test above covers: the async
-- search plus interactive picker between find_repair_candidates() and
-- relink() is just as long a window for the CHOSEN CANDIDATE to vanish
-- (deleted, moved, a git checkout) as it is for link_path to be replaced.
-- `mutate.symlink` never checks its target -- a dangling symlink is legal on
-- every platform -- so without this check relink() would delete the OLD
-- (still-working, from the user's point of view) symlink and silently
-- replace it with a NEW one that is just as broken, while still reporting
-- "Symlink created" as if it had succeeded.
do
  local tmp = (TMP_ROOT .. "/units-linkrepair-toctou-target"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/newloc", "p")
  local new_target = tmp .. "/newloc/target.txt"
  vim.fn.writefile({ "moved" }, new_target)
  local link_path = tmp .. "/target.txt"
  local old_raw_target = tmp .. "/old_target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(old_raw_target, link_path, false)

  if not ok_broken then
    print(
      "  note link_create repair (TOCTOU target): could not create a test symlink in this environment, skipping"
    )
  else
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["gopath.resolvers.common.tailsearch"] = {
      sanitize = function(raw)
        return vim.fs.basename((raw:gsub("\\", "/")))
      end,
      cache_lookup = function(_)
        return { new_target } -- single candidate -> no picker needed to reach relink()
      end,
      guess_roots = function()
        return { tmp }
      end,
    }
    -- Simulate the race on the OTHER side: by the time the (stubbed) picker
    -- "answers", delete new_target itself -- the candidate that was found is
    -- gone by the time the user's choice reaches relink().
    ---@diagnostic disable-next-line: duplicate-set-field
    package.loaded["filetree.util.select"] = function(_, _, on_choice)
      vim.fn.delete(new_target)
      on_choice(new_target, 1)
    end
    package.loaded["filetree.features.fileops.link_create"] = nil -- reload with stubs

    local symlink_util = require("filetree.util.symlink")
    local original_raw_target = symlink_util.read_target(link_path)

    local cur_node = { path = link_path, type = "file" }
    local stub = setmetatable({
      name = "units-stub-linkrepair-toctou-target",
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
      adapter = "units-stub-linkrepair-toctou-target",
      features = { link_create = { enabled = true } },
    })
    local lc = ft.feature("link_create")

    local captured
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(m)
      captured = m
    end
    lc.repair(link_path)
    vim.notify = orig_notify

    check(
      "link_create repair (TOCTOU target): relink refuses once new_target no longer exists",
      captured ~= nil and captured:lower():find("no longer exist", 1, true) ~= nil,
      tostring(captured)
    )
    check(
      "link_create repair (TOCTOU target): the old symlink is left exactly as it was, not replaced",
      symlink_util.is_link(link_path) and symlink_util.read_target(link_path) == original_raw_target
    )

    package.loaded["gopath.resolvers.common.tailsearch"] = nil
    package.loaded["filetree.util.select"] = nil
    package.loaded["filetree.features.fileops.link_create"] = nil
  end
end

-- ── trash require_symlink: skips a delete when the path is no longer a ────
-- symlink by the time do_trash actually runs -- regression coverage for the
-- same class of TOCTOU as the repair test above, for :Filetree symlink
-- delete's own "never a real file" guarantee (link_create.M.delete() passes
-- require_symlink=true to trash.delete_current(); tested here directly
-- against trash's own M.delete(path, on_done, require_symlink), which is
-- what M.delete_current() actually calls through per-path).
do
  local tmp = (TMP_ROOT .. "/units-trash-requiresymlink"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local link_path = tmp .. "/target.txt"

  local mutate = require("lib.nvim.cross.fs.mutate")
  local ok_broken = mutate.symlink(tmp .. "/old_target.txt", link_path, false)

  if not ok_broken then
    print(
      "  note trash require_symlink: could not create a test symlink in this environment, skipping"
    )
  else
    local stub = setmetatable({
      name = "units-stub-requiresymlink",
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
      adapter = "units-stub-requiresymlink",
      -- permanent + confirm=false: a real, synchronous delete with no
      -- dialog in the way, so do_trash runs (and the require_symlink check
      -- fires) right inside this same call.
      features = { trash = { enabled = true, mode = "permanent", confirm = false } },
    })
    local trash = ft.feature("trash")

    -- Simulate the race: something else replaced the symlink with a real
    -- file between "gathered/validated it" and "trash actually runs".
    local replaced_content = "real file, must survive untouched"
    vim.fn.delete(link_path)
    vim.fn.writefile({ replaced_content }, link_path)

    local done_ok
    trash.delete(link_path, function(ok)
      done_ok = ok
    end, true)

    check("trash require_symlink: reports the delete as NOT done", done_ok == false)
    check(
      "trash require_symlink: the real file that replaced the symlink survives untouched",
      vim.fn.filereadable(link_path) == 1
        and table.concat(vim.fn.readfile(link_path), "\n") == replaced_content
    )

    package.loaded["filetree.features.fileops.trash"] = nil
  end
end

-- ── Report ────────────────────────────────────────────────────────────────────
print(("\nfiletree.nvim units (2/3): %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
