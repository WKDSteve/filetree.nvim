-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
---@diagnostic disable: missing-fields
-- Test doubles here implement only what the unit under test calls -- a full
-- FiletreeAdapter or FiletreeRef would be noise, not coverage.
-- units.lua — headless unit tests for filetree.nvim's util layer + adapter helpers.
--
-- Complements TESTS/smoke.lua (which is an integration test over the registry and
-- setup). This file exercises the reusable primitives directly.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/units.lua
--
-- Exit 0 = all passed, 1 = a check failed.

-- ":p" resolves to absolute *before* walking up two levels, so `root` stays
-- correct even if a test later changes Neovim's cwd (":h:h" alone would give a
-- path relative to invocation-time cwd, e.g. "." when run as `-l TESTS/units.lua`,
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

-- ── util.path ─────────────────────────────────────────────────────────────────
do
  local path = require("filetree.util.path")
  -- "E:\a\b" is only absolute on Windows; on POSIX it has no leading "/" and
  -- to_absolute() would (correctly) resolve it against cwd instead, so this
  -- assertion only holds on Windows. On POSIX, assert the same backslash-to-
  -- forward-slash behavior with a path that is actually absolute there.
  if vim.fn.has("win32") == 1 then
    eq("path.to_unix backslashes", path.to_unix("E:\\a\\b"):gsub("^%a:", ""), "/a/b")
  else
    eq("path.to_unix backslashes", path.to_unix("/a\\b"), "/a/b")
  end
  check(
    "path.ensure_dir file → parent",
    path.ensure_dir(root .. "/lua/filetree/init.lua"):gsub("\\", "/"):match("/filetree$") ~= nil
  )
  check(
    "path.ensure_dir dir → self",
    path.ensure_dir(root .. "/lua"):gsub("\\", "/"):match("/lua$") ~= nil
  )
  eq("path.relative under base", path.relative(root .. "/lua/x.lua", root), "lua/x.lua")
  eq("path.basename", path.basename("/a/b/c.lua"), "c.lua")
  eq("path.parent", path.parent("/a/b/c.lua"):gsub("\\", "/"), "/a/b")
  check("path.escape_shell_arg is string", type(path.escape_shell_arg("a b")) == "string")

  -- Single canonical separator: prompts/notifications always show "/", and
  -- either "/" or "\" typed by the user sanitizes to "/". Regression coverage
  -- for the smart_create/smart_rename prompt fix.
  eq("path.slashify converts backslashes", path.slashify("E:\\a\\b"), "E:/a/b")
  eq("path.slashify is idempotent on forward slashes", path.slashify("E:/a/b"), "E:/a/b")
  check(
    "path.parent never contains a backslash",
    not path.parent(root .. "\\lua\\filetree\\init.lua"):find("\\", 1, true)
  )
  check(
    "path.relative (outside base) never contains a backslash",
    not path.relative("Z:\\some\\other\\file.lua", root):find("\\", 1, true)
  )
end

-- ── util.path.to_absolute (SEC-34) ── must never run the path through
-- vim.fn.expand (backtick span -> &shell command substitution).
--
-- Used to be pinned against a simulated "lib.nvim.cross.fs.expand_path is
-- unavailable" fallback branch in filetree.util.path. That branch was removed
-- (LUA-01): lib.nvim is a hard dependency (filetree/commands.lua bare-requires
-- it, and filetree/init.lua bare-requires commands.lua at module top level),
-- so require("filetree") cannot succeed without lib.nvim at all -- the
-- soft-fallback was dead code for the exact case it existed to handle, and
-- simulating that case by poisoning package.preload no longer models a state
-- the real plugin can be in; it just makes the module's own top-level
-- `require` throw, taking the whole test file down with it (as it did here
-- until this test was updated). The guarantee itself still holds and is
-- covered directly below, against the real code path: to_absolute() delegates
-- unconditionally to lib.nvim.cross.fs.expand_path, which is a pure string
-- expansion with no shellout of its own.
do
  local path = require("filetree.util.path")

  local probe = (TMP_ROOT .. "/units-sec34-probe.txt"):gsub("\\", "/")
  vim.fn.delete(probe)
  local abs = path.to_absolute("~`touch " .. probe .. "`/x")
  check(
    "path.to_absolute: a backtick span in the path is never executed",
    vim.fn.filereadable(probe) == 0,
    abs
  )
  vim.env.FILETREE_SEC34_TEST_VAR = TMP_ROOT
  local expanded = path.to_absolute("$FILETREE_SEC34_TEST_VAR/probe-child"):gsub("\\", "/")
  check(
    "path.to_absolute: $VAR is still expanded (env, not shell)",
    expanded:find(TMP_ROOT, 1, true) == 1 and expanded:match("/probe%-child$") ~= nil,
    expanded
  )
  vim.env.FILETREE_SEC34_TEST_VAR = nil
end

-- ── util.buffer ───────────────────────────────────────────────────────────────
do
  local buf = require("filetree.util.buffer")
  check("buffer.TREE_FT has neo-tree", buf.TREE_FT["neo-tree"] == true)
  check("buffer.find_editor_win callable", type(buf.find_editor_win) == "function")
  -- a scratch (nofile) buffer is not a valid file buffer
  local b = vim.api.nvim_create_buf(false, true)
  check("is_valid_file_buffer false for scratch", buf.is_valid_file_buffer(b) == false)
  -- an editor window holding a real file is found
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/README.md"))
  local ewin = buf.find_editor_win(nil)
  check("find_editor_win finds the README window", ewin ~= nil)

  -- ── buffer.relocate ── repoint open buffers after a file/dir move or rename.
  -- Regression for: cutting a node (x) and pasting it (p) into a new
  -- directory left the original buffer pointing at a path that no longer
  -- existed, so opening the file at its new location created a second,
  -- disconnected buffer instead of reusing the original one.
  local tmp = (TMP_ROOT .. "/units-relocate"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/src/sub", "p")
  vim.fn.mkdir(tmp .. "/dst", "p")

  -- exact-match single file
  vim.fn.writefile({ "a" }, tmp .. "/src/a.txt")
  vim.cmd("edit " .. tmp .. "/src/a.txt")
  local buf_a = vim.api.nvim_get_current_buf()
  vim.fn.rename(tmp .. "/src/a.txt", tmp .. "/dst/a.txt")
  local n1 = buf.relocate(tmp .. "/src/a.txt", tmp .. "/dst/a.txt")
  eq("relocate: exact match repoints 1 buffer", n1, 1)
  eq(
    "relocate: exact match new buffer name",
    vim.api.nvim_buf_get_name(buf_a):gsub("\\", "/"),
    tmp .. "/dst/a.txt"
  )

  -- directory move: a buffer nested under the moved dir is repointed too
  vim.fn.writefile({ "b" }, tmp .. "/src/sub/b.txt")
  vim.cmd("edit " .. tmp .. "/src/sub/b.txt")
  local buf_b = vim.api.nvim_get_current_buf()
  vim.fn.mkdir(tmp .. "/dst2", "p")
  vim.fn.rename(tmp .. "/src/sub", tmp .. "/dst2/sub")
  buf.relocate(tmp .. "/src/sub", tmp .. "/dst2/sub")
  eq(
    "relocate: directory move repoints nested buffer",
    vim.api.nvim_buf_get_name(buf_b):gsub("\\", "/"),
    tmp .. "/dst2/sub/b.txt"
  )

  -- a MODIFIED buffer must not lose its unsaved changes
  vim.fn.writefile({ "orig" }, tmp .. "/src/c.txt")
  vim.cmd("edit " .. tmp .. "/src/c.txt")
  local buf_c = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf_c, 0, -1, false, { "UNSAVED" })
  vim.fn.rename(tmp .. "/src/c.txt", tmp .. "/dst/c.txt")
  buf.relocate(tmp .. "/src/c.txt", tmp .. "/dst/c.txt")
  check(
    "relocate: modified buffer keeps its unsaved content",
    vim.api.nvim_buf_get_lines(buf_c, 0, -1, false)[1] == "UNSAVED"
  )
  eq(
    "relocate: modified buffer still gets the new name",
    vim.api.nvim_buf_get_name(buf_c):gsub("\\", "/"),
    tmp .. "/dst/c.txt"
  )

  -- path-separator mismatch (backslash old/new vs forward-slash buffer name) --
  -- regression for the class of bug this session found across all 5 adapters.
  vim.fn.writefile({ "d" }, tmp .. "/src/d.txt")
  vim.cmd("edit " .. tmp .. "/src/d.txt")
  vim.fn.rename(tmp .. "/src/d.txt", tmp .. "/dst/d.txt")
  local n4 =
    buf.relocate((tmp .. "/src/d.txt"):gsub("/", "\\"), (tmp .. "/dst/d.txt"):gsub("/", "\\"))
  eq("relocate: backslash old/new path still matches forward-slash buffer name", n4, 1)

  -- ── buffer.close_for_path ── closing a shown buffer must NOT spawn a fresh
  -- [No Name]; the window is switched to another real (named) buffer first.
  -- Regression for: deleting an open file left a blank buffer that reshuffled
  -- the window layout, even though other buffers were open.
  vim.fn.writefile({ "1" }, tmp .. "/f1.txt")
  vim.fn.writefile({ "2" }, tmp .. "/f2.txt")
  vim.cmd("only")
  vim.cmd("edit " .. tmp .. "/f1.txt") -- becomes the alternate
  vim.cmd("edit " .. tmp .. "/f2.txt") -- shown in the window, to be closed
  local win = vim.api.nvim_get_current_win()
  local doomed = vim.api.nvim_get_current_buf()

  local function noname_count()
    local c = 0
    for _, nb in ipairs(vim.api.nvim_list_bufs()) do
      if
        vim.api.nvim_buf_is_valid(nb)
        and vim.api.nvim_buf_is_loaded(nb)
        and vim.api.nvim_buf_get_name(nb) == ""
      then
        c = c + 1
      end
    end
    return c
  end
  local before_noname = noname_count()

  local cn = buf.close_for_path(tmp .. "/f2.txt")
  eq("close_for_path: closed the shown buffer", cn, 1)
  check(
    "close_for_path: doomed buffer is gone",
    not vim.api.nvim_buf_is_valid(doomed) or vim.api.nvim_buf_get_name(doomed) == ""
  )
  local now_shown = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):gsub("\\", "/")
  eq(
    "close_for_path: window switched to the alternate named buffer, not a blank",
    now_shown,
    tmp .. "/f1.txt"
  )
  eq("close_for_path: no new [No Name] buffer was created", noname_count(), before_noname)
end

-- ── util.confirm ── shared button dialog, replacing native vim.fn.confirm ─
do
  local confirm = require("filetree.util.confirm")
  local function keys(s)
    return vim.api.nvim_replace_termcodes(s, true, false, true)
  end

  local got
  confirm({
    title = " T ",
    body = { "  info line" },
    question = "Do it?",
    on_choice = function(yes)
      got = yes
    end,
  })
  -- The dialog floats and takes focus; the safe answer, "No" (button 2), is focused.
  local float_open = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then float_open = true end
  end
  check("confirm: opens a floating window", float_open)
  vim.api.nvim_feedkeys(keys("<CR>"), "x", false)
  check("confirm: <CR> on the default-focused No resolves to false", got == false)

  got = nil
  confirm({
    body = {},
    question = "Do it?",
    on_choice = function(yes)
      got = yes
    end,
  })
  vim.api.nvim_feedkeys(keys("h<CR>"), "x", false)
  check("confirm: h<CR> moves focus to Yes and resolves to true", got == true)
end

-- ── opened_sync ── buffer open/close triggers a light adapter redraw ────────
do
  local redrew = 0
  local stub = setmetatable({
    name = "units-stub-opensync",
    is_available = function()
      return true
    end,
    is_open = function()
      return true, 1
    end,
    redraw = function()
      redrew = redrew + 1
      return true
    end,
    -- Explicitly absent (not just missing): this stub models a backend that
    -- only implements the plain `redraw`, so opened_sync must fall back to
    -- it rather than silently resolving `redraw_soon` through `__index`
    -- below (which would return a callable stub and mask this test).
    redraw_soon = false,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  package.loaded["filetree.features.ui.opened_sync"] = nil
  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-opensync",
    features = { opened_sync = { enabled = true, debounce_ms = 0 } },
  })

  vim.api.nvim_exec_autocmds("BufAdd", {})
  vim.wait(80, function()
    return redrew > 0
  end, 10)
  check("opened_sync: a buffer event triggers adapter.redraw()", redrew > 0)
end

-- ── opened_sync ── does NOT use adapter.redraw_soon(), even when present ───
-- opened_sync's own `_debounce` already collapses a burst of Buf* events
-- into exactly one call to redraw_now() -- routing that single, already-
-- debounced call through `redraw_soon()`'s own separate debounce window has
-- nothing left to coalesce it with, and would only add latency (a real,
-- confirmed regression this test guards against). Mirror image of the check
-- above: this backend implements BOTH redraw and redraw_soon, and plain
-- `redraw()` must be the one actually called.
do
  local redrew, redrew_soon = 0, 0
  local stub = setmetatable({
    name = "units-stub-opensync-both",
    is_available = function()
      return true
    end,
    is_open = function()
      return true, 1
    end,
    redraw = function()
      redrew = redrew + 1
      return true
    end,
    redraw_soon = function()
      redrew_soon = redrew_soon + 1
      return true
    end,
  }, {
    __index = function()
      return function()
        return false
      end
    end,
  })

  package.loaded["filetree.features.ui.opened_sync"] = nil
  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({
    adapter = "units-stub-opensync-both",
    features = { opened_sync = { enabled = true, debounce_ms = 0 } },
  })

  vim.api.nvim_exec_autocmds("BufAdd", {})
  vim.wait(80, function()
    return redrew > 0
  end, 10)
  check(
    "opened_sync: a buffer event calls adapter.redraw() even when redraw_soon exists",
    redrew > 0
  )
  check("opened_sync: redraw_soon() is never called from this path", redrew_soon == 0)
end

-- ── util.line_count ───────────────────────────────────────────────────────────
do
  local lc = require("filetree.util.line_count")
  check("line_count.is_countable lua", lc.is_countable("lua") == true)
  check("line_count.is_binary_ext png", lc.is_binary_ext("png") == true)
  check("line_count.count README > 0", (lc.count(root .. "/README.md", "md") or 0) > 0)
  eq("line_count.format 1", lc.format(1), "1 line")
  eq("line_count.MAX_BYTES is the documented 5 MiB default", lc.MAX_BYTES, 5 * 1024 * 1024)
  eq(
    "line_count.count: a file above the caller's max_bytes is not counted",
    lc.count(root .. "/README.md", "md", 1),
    nil
  )
  check(
    "line_count.count: a file within the caller's max_bytes is",
    (lc.count(root .. "/README.md", "md", 10 * 1024 * 1024) or 0) > 0
  )
end

-- ── util.map / util.autocmd (wrappers) ────────────────────────────────────────
do
  local map = require("filetree.util.map")
  local au = require("filetree.util.autocmd")
  -- `vim.is_callable`, not `type(...) == "function"`: lib.nvim's keymap
  -- module is a callable table, and the stricter check reported the working
  -- delegation as a failure.
  check("util.map is callable", vim.is_callable(map))
  local g = au.group("filetree_units_test", true)
  check("au.group returns id", type(g) == "number")
  local fired = false
  au.acmd("User", {
    group = g,
    pattern = "FiletreeUnitsPing",
    callback = function()
      fired = true
    end,
  })
  vim.api.nvim_exec_autocmds("User", { pattern = "FiletreeUnitsPing" })
  check("au.acmd handler fires", fired)
  au.del_group(g)
end

-- ── util.select (adapter) ─────────────────────────────────────────────────────
do
  package.loaded["filetree.util.select"] = nil
  package.loaded["ui.kit"] = {
    select = function(o)
      o.on_select(o.items[2], 2)
    end,
  }
  local ui_select = require("filetree.util.select")
  local chosen
  ui_select({ "a", "b", "c" }, { prompt = "p" }, function(item, idx)
    chosen = { item, idx }
  end)
  check("select passes original item + index", chosen and chosen[1] == "b" and chosen[2] == 2)
  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.select"] = nil
end

-- ── neotree adapter helpers (pure) ────────────────────────────────────────────
do
  package.loaded["neo-tree"] = { config = {} }
  local nt = dofile(root .. "/lua/filetree/adapter/neotree.lua")
  local paths, names = nt.extract_paths({
    { path = "E:/a/b.lua", name = "b.lua" },
    { name = "no-path-node" },
    {
      get_id = function()
        return "E:/c/d.lua"
      end,
    },
  })
  check("extract_paths skips pathless nodes", #paths == 2)
  eq("extract_paths path 1", paths[1], "E:/a/b.lua")
  eq("extract_paths name 1", names[1], "b.lua")
  check("extract_paths resolves via get_id", paths[2] == "E:/c/d.lua")
end

-- ── neotree adapter: node_is_dir skips the stat for a resolved type ─────────
-- A dangling symlink's node.type stays "link": neo-tree already tried
-- uv.fs_stat on the target and it failed, which is exactly what makes it
-- dangling. "unknown" means its own uv.fs_lstat failed. Both used to fall
-- through to a vim.fn.isdirectory() stat that was always going to fail too --
-- one real filesystem call per rendered line for every dangling link in the
-- tree. Only a genuinely absent type (neo-tree told us nothing) should still
-- ask the filesystem.
do
  package.loaded["neo-tree"] = { config = {} }
  local fake_node
  package.loaded["neo-tree.sources.manager"] = {
    get_state = function()
      return {
        tree = {
          get_node = function()
            return fake_node
          end,
        },
      }
    end,
  }
  package.loaded["filetree.adapter.neotree"] = nil
  local nt = dofile(root .. "/lua/filetree/adapter/neotree.lua")

  local real_dir = (TMP_ROOT .. "/units-nodeisdir-real"):gsub("\\", "/")
  vim.fn.mkdir(real_dir, "p")
  local missing = real_dir .. "/does-not-exist"

  -- A dangling symlink on a real disk resolves via the fallback exactly as
  -- correctly as via the type check -- `isdirectory()` on a nonexistent
  -- target returns 0 either way. So the functional result alone cannot tell
  -- the fixed code from the pre-fix one; what changed is whether that stat
  -- runs at all. Spy on it instead of just reading the outcome.
  local isdirectory_calls = 0
  local orig_isdirectory = vim.fn.isdirectory
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.isdirectory = function(...)
    isdirectory_calls = isdirectory_calls + 1
    return orig_isdirectory(...)
  end

  ---@param node table
  ---@return string?, integer stat_calls
  local function resolved_type(node)
    fake_node = node
    isdirectory_calls = 0
    local ft = nt.get_current_node()
    return (ft and ft.type or nil), isdirectory_calls
  end

  do
    local ty, stats = resolved_type({ type = "link", path = missing, name = "dangling" })
    check("node_is_dir: a dangling-symlink node (type='link') resolves to file", ty == "file")
    check(
      "node_is_dir: type='link' does NOT call vim.fn.isdirectory()",
      stats == 0,
      tostring(stats)
    )
  end
  do
    local ty, stats = resolved_type({ type = "unknown", path = missing, name = "mystery" })
    check(
      "node_is_dir: an 'unknown' node (its own lstat already failed) resolves to file",
      ty == "file"
    )
    check(
      "node_is_dir: type='unknown' does NOT call vim.fn.isdirectory()",
      stats == 0,
      tostring(stats)
    )
  end
  do
    local ty, stats = resolved_type({ type = "directory", path = real_dir, name = "d" })
    check("node_is_dir: type='directory' still resolves to directory", ty == "directory")
    check(
      "node_is_dir: type='directory' does NOT call vim.fn.isdirectory()",
      stats == 0,
      tostring(stats)
    )
  end
  do
    local ty, stats = resolved_type({ type = "file", path = real_dir, name = "f" })
    check("node_is_dir: type='file' still resolves to file", ty == "file")
    check(
      "node_is_dir: type='file' does NOT call vim.fn.isdirectory()",
      stats == 0,
      tostring(stats)
    )
  end
  do
    local ty, stats = resolved_type({ path = real_dir, name = "no-type-dir" })
    check(
      "node_is_dir: an absent type still falls back to a real filesystem check (directory)",
      ty == "directory"
    )
    check(
      "node_is_dir: an absent type DOES call vim.fn.isdirectory() -- the one case it must",
      stats == 1,
      tostring(stats)
    )
  end
  do
    local ty, stats = resolved_type({ path = missing, name = "no-type-file" })
    check(
      "node_is_dir: an absent type on a non-directory path falls back correctly (file)",
      ty == "file"
    )
    check(
      "node_is_dir: an absent type DOES call vim.fn.isdirectory() (non-dir case too)",
      stats == 1,
      tostring(stats)
    )
  end

  vim.fn.isdirectory = orig_isdirectory
  package.loaded["neo-tree.sources.manager"] = nil
  package.loaded["filetree.adapter.neotree"] = nil
end

-- ── attach: the neo-tree `window.mappings` injection is gone ────────────────
--
-- `attach` used to write filetree's keys into neo-tree's own mapping tables
-- after neo-tree.setup(), which made it the last word: a key a user had
-- switched off for one source was silently overruled. filetree binds its keys
-- itself (see the tree_attach block below) and its `?` cheatsheet lists them,
-- so there is nothing to inject; the old entry point stays as a no-op.
do
  package.loaded["neo-tree"] = { config = {} }
  local attach = dofile(root .. "/lua/filetree/attach.lua")

  check(
    "attach: no injection entry points left",
    attach.inject == nil and attach.mappings_for == nil
  )
  local opts = { window = { mappings = { ["<space>"] = "none" } } }
  local before = vim.deepcopy(opts)
  check(
    "attach: neotree() hands opts back untouched",
    attach.neotree(opts) == opts and vim.deep_equal(opts, before)
  )
  check("attach: neotree(nil) still answers a table", type(attach.neotree(nil)) == "table")
  check(
    "attach: neo-tree's config was not written to",
    vim.tbl_isempty(package.loaded["neo-tree"].config)
  )
end

-- ── tree_attach: the dispatcher honours the same source restriction ─────────
--
-- The half that actually decides what a keypress does. `attach.inject` only
-- feeds neo-tree's `?` cheatsheet; the keys themselves come from here, out of
-- one `FileType neo-tree` autocmd that fires for all five sources alike. Both
-- read `filetree.sources`, so a key cannot be bound where it is not listed.
do
  package.loaded["filetree.sources"] = nil
  package.loaded["filetree.util.tree_attach"] = nil
  local ta = dofile(root .. "/lua/filetree/util/tree_attach.lua")
  local srcs = dofile(root .. "/lua/filetree/sources.lua")

  check("sources: an unrestricted feature reaches any source", srcs.allows("node_info", "buffers"))
  check("sources: trash reaches filesystem", srcs.allows("trash", "filesystem"))
  check(
    "sources: trash does not reach document_symbols",
    not srcs.allows("trash", "document_symbols")
  )
  check("sources: trash does not reach diagnostics", not srcs.allows("trash", "diagnostics"))

  -- An unknown source means two opposite things depending on who is asking,
  -- and conflating them is how this would break NvimTree (no sources at all)
  -- or leak into the shared window table.
  check("sources: unknown source binds (lenient)", srcs.allows("trash", nil))
  check("sources: unknown source is not shared (strict)", not srcs.allows("trash", nil, true))

  -- The dispatcher itself, through its real autocmd rather than a stand-in:
  -- register one restricted and one unrestricted callback, then make a buffer
  -- look like the tree of a given source and let `FileType` fire.
  local ran = {}
  ta.reset()
  ta.on_attach(function()
    ran.trash = true
  end, "trash")
  ta.on_attach(function()
    ran.plain = true
  end)
  ta.install(nil) -- no adapter -> the default { "neo-tree", "NvimTree" } pattern

  ---@param source string|nil
  ---@return table
  local function attach_as(source)
    ran = {}
    local buf = vim.api.nvim_create_buf(false, true)
    -- Set before the event, not after: the real ordering (renderer sets it one
    -- tick later, which is the tick the dispatcher waits for anyway) is
    -- measured and documented in `filetree.sources`; what is under test here
    -- is the decision, not neo-tree's timing.
    if source then vim.b[buf].neo_tree_source = source end
    vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = buf })
    vim.wait(500, function()
      return ran.plain == true
    end, 10)
    vim.api.nvim_buf_delete(buf, { force = true })
    return ran
  end

  local fs_run = attach_as("filesystem")
  check("tree_attach: filesystem runs trash", fs_run.trash == true)
  check("tree_attach: filesystem runs the unrestricted one", fs_run.plain == true)

  local sym_run = attach_as("document_symbols")
  check("tree_attach: document_symbols skips trash", sym_run.trash == nil)
  check("tree_attach: document_symbols still runs the unrestricted one", sym_run.plain == true)

  local none_run = attach_as(nil)
  check("tree_attach: an adapter without sources runs everything", none_run.trash == true)

  ta.teardown()
end

-- ── suite hermeticity ── setup() never opens the first-run deps float ──────
-- Guards the header's `vim.g.lib_nvim_deps_disable_first_run`. On a cache
-- that has already "seen" filetree the suite passes without it, so only this
-- forced worst case (no seen store, a declared tool missing) keeps a removed
-- opt-out from going unnoticed until the next fresh $TEMP -- where the float's
-- 'winfixbuf' window makes the cwd_sync case below die with E1513 on :edit.
-- Nothing is written to the real cache (save is stubbed). view.show is only
-- scheduled, so the stubs stay until the event loop has run that callback.
do
  local disk = require("lib.nvim.cache.disk")
  local dspec = require("lib.nvim.deps.spec")
  local install = require("lib.nvim.deps.install")
  local view = require("lib.nvim.deps.view")
  local orig = {
    load = disk.load,
    save = disk.save,
    find = dspec.find,
    spec_load = dspec.load,
    plan = install.plan,
    show = view.show,
  }
  local shown = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  disk.load = function()
    return nil
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  disk.save = function()
    return true
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  dspec.find = function()
    return "install.json"
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  dspec.load = function()
    return { tools = { { name = "units-missing-tool" } } }
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  install.plan = function()
    return { missing = { { name = "units-missing-tool" } } }
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  view.show = function()
    shown = shown + 1
  end
  local stub = setmetatable({ name = "units-depsfirstrun-stub" }, {
    __index = function()
      return function()
        return false
      end
    end,
  })
  local ft = require("filetree")
  ft.register_adapter(stub)
  ft.setup({ adapter = stub.name, features = {} })
  vim.wait(100, function()
    return shown > 0
  end, 10)
  disk.load, disk.save = orig.load, orig.save
  dspec.find, dspec.load = orig.find, orig.spec_load
  install.plan, view.show = orig.plan, orig.show
  eq("deps first run: setup() schedules no external-tools float in this suite", shown, 0)
  vim.cmd("silent! only")
end

-- ── cwd_sync: silently changes cwd + refreshes, never prompts ────────────────
do
  local tmp = (TMP_ROOT .. "/units-cwdsync"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/proj/.git", "p")
  vim.fn.mkdir(tmp .. "/proj/sub", "p")
  vim.fn.writefile({ "x" }, tmp .. "/proj/sub/file.lua")
  vim.fn.chdir(tmp) -- start OUTSIDE the project root

  local refreshed, revealed_path = false, nil
  local stub = setmetatable({
    name = "units-stub",
    is_available = function()
      return true
    end,
    get_winid = function()
      return nil
    end,
    open_reveal = function(p)
      revealed_path = p
      return true
    end,
    refresh = function()
      refreshed = true
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

  local ui_input_called = false
  local orig_input = vim.ui.input
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.input = function(...)
    ui_input_called = true
    return orig_input(...)
  end

  ft.setup({ adapter = "units-stub", features = { cwd_sync = { enabled = true, debounce_ms = 0 } } })
  vim.cmd("edit " .. tmp .. "/proj/sub/file.lua")
  vim.wait(200, function()
    return revealed_path ~= nil
  end, 10)
  vim.ui.input = orig_input

  check("cwd_sync never prompts (no vim.ui.input)", not ui_input_called)
  eq(
    "cwd_sync chdir's to the detected project root",
    vim.fn.getcwd():gsub("\\", "/"),
    tmp .. "/proj"
  )
  -- cwd_sync deliberately does NOT call adapter.refresh() itself (a full
  -- filesystem rescan) -- the reveal call below re-renders the tree, so a
  -- separate rescan would be redundant work. See cwd_sync/init.lua's do_reveal.
  check("cwd_sync does not call adapter.refresh() itself", not refreshed)
  check(
    "cwd_sync still reveals the file",
    revealed_path and revealed_path:gsub("\\", "/") == tmp .. "/proj/sub/file.lua"
  )

  -- Drain any still-pending debounced reveal, then drop this block's autocmds
  -- and module state. Without this the next cwd_sync block inherits a live
  -- BufEnter handler and a populated `S.last_path`: its own `edit` fires the
  -- stale handler, which sets `S.last_path` to that file, and the block's real
  -- catch-up `do_reveal` then short-circuits on the `S.last_path == path`
  -- guard and never chdirs. (Order-dependent, and it surfaced only on Linux CI.)
  vim.wait(30)
  require("filetree.features.nav.cwd_sync").teardown()
end

-- ── cwd_sync: startup catch-up syncs a buffer focused BEFORE setup() ran ─────
-- Regression for: a session-restore plugin (or anything that focuses a buffer
-- very early) can leave the cwd stale with no BufEnter/WinEnter left to fire
-- for cwd_sync to react to, since the relevant buffer was already current
-- by the time setup() registered its autocmds. In this headless test process,
-- vim_did_enter is already 1 by the time the script runs, so this exercises
-- the "VimEnter already happened" branch that filetree.nvim actually hits in
-- practice (it typically loads on a lazy event well after VimEnter).
do
  local tmp = (TMP_ROOT .. "/units-cwdsync-catchup"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/proj/.git", "p")
  vim.fn.writefile({ "x" }, tmp .. "/proj/file.lua")

  -- Focus the buffer and go to a stale cwd FIRST -- before setup() runs, so no
  -- BufEnter/WinEnter for this buffer will ever reach cwd_sync's autocmds.
  vim.cmd("edit " .. tmp .. "/proj/file.lua")
  vim.fn.chdir(tmp)

  local revealed_path
  local stub = setmetatable({
    name = "units-stub-catchup",
    is_available = function()
      return true
    end,
    get_winid = function()
      return nil
    end,
    open_reveal = function(p)
      revealed_path = p
      return true
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
    adapter = "units-stub-catchup",
    features = { cwd_sync = { enabled = true, debounce_ms = 0 } },
  })

  vim.wait(500, function()
    return revealed_path ~= nil
  end, 10)

  eq(
    "cwd_sync startup catch-up: chdir's to the project root with no BufEnter",
    vim.fn.getcwd():gsub("\\", "/"),
    tmp .. "/proj"
  )
  check(
    "cwd_sync startup catch-up: reveals the already-focused file",
    revealed_path and revealed_path:gsub("\\", "/") == tmp .. "/proj/file.lua"
  )

  vim.wait(30)
  require("filetree.features.nav.cwd_sync").teardown()
end

-- ── neotree adapter: reveal-prompt guard ─────────────────────────────────────
-- Regression for neo-tree's own "File not in cwd. Change cwd to ...?" confirm
-- prompt (lua/neo-tree/command/init.lua's handle_reveal): it fires whenever a
-- reveal is requested (explicitly, or implicitly via
-- filesystem.follow_current_file.enabled) without an explicit `dir` and
-- without `reveal_force_cwd` set. filetree.nvim can't control every call site
-- that might trigger a reveal (a user's own custom keymaps calling neo-tree's
-- command API directly are just as much at risk as filetree's own code), so
-- install_reveal_guard() wraps neo-tree.command.execute ONCE to inject
-- reveal_force_cwd=true on any at-risk call, protecting all callers uniformly.
do
  package.loaded["neo-tree"] = {
    config = {},
    ensure_config = function()
      return {}
    end,
  }
  local captured = {}
  package.loaded["neo-tree.command"] = {
    execute = function(args)
      captured[#captured + 1] = vim.deepcopy(args)
      return true
    end,
  }
  package.loaded["neo-tree.sources.manager"] = {
    get_state = function()
      return nil
    end,
  }
  package.loaded["neo-tree.setup.mapping-helper"] = {
    normalize_map_key = function(k)
      return k
    end,
  }

  local ft = require("filetree")
  ft.setup({ adapter = "neotree" })

  local cmd = require("neo-tree.command")
  cmd.execute({ action = "focus", reveal = true }) -- explicit reveal, no dir
  cmd.execute({ action = "show" }) -- reveal left nil (implicit-via-follow)
  cmd.execute({ action = "show", reveal = false }) -- explicit opt-out, must stay untouched
  cmd.execute({ action = "show", dir = "E:/some/dir" }) -- dir already given, already safe
  cmd.execute({ action = "show", reveal = true, reveal_force_cwd = false }) -- caller's explicit choice, must win

  eq(
    "reveal guard: injects reveal_force_cwd for explicit reveal=true",
    captured[1].reveal_force_cwd,
    true
  )
  eq(
    "reveal guard: injects reveal_force_cwd for implicit reveal (nil)",
    captured[2].reveal_force_cwd,
    true
  )
  eq("reveal guard: leaves an explicit reveal=false untouched", captured[3].reveal_force_cwd, nil)
  eq("reveal guard: does not inject when dir is already given", captured[4].reveal_force_cwd, nil)
  eq(
    "reveal guard: respects an explicit reveal_force_cwd=false",
    captured[5].reveal_force_cwd,
    false
  )

  local before = cmd.execute
  ft.setup({ adapter = "neotree" })
  check(
    "reveal guard: re-running setup() does not double-wrap execute",
    before == require("neo-tree.command").execute
  )

  package.loaded["neo-tree"] = nil
  package.loaded["neo-tree.command"] = nil
  package.loaded["neo-tree.sources.manager"] = nil
  package.loaded["neo-tree.setup.mapping-helper"] = nil
end

-- ── ignore_list: hide_by_name must be dict-shaped, not array-shaped ─────────
-- neo-tree's own filesystem.setup() converts hide_by_name from a user-facing
-- string[] into a {name=true,...} dict (utils.list_to_dict) — its render-time
-- filter (file-items.lua) only ever does f.hide_by_name[name], never iterates.
-- Appending array-style (ipairs + #+1) after that conversion silently hides
-- nothing at all, which is exactly the bug this guards against.
do
  package.loaded["neo-tree"] = { config = { filesystem = { filtered_items = {} } } }
  package.loaded["neo-tree.sources.manager"] = {
    _get_all_states = function()
      return {}
    end,
  }
  package.loaded["filetree.features.infra.ignore_list"] = nil
  local il = require("filetree.features.infra.ignore_list")
  local refreshed = false
  il.setup({ enabled = true }, {
    name = "neotree",
    refresh = function()
      refreshed = true
      return true
    end,
  })

  local fi = package.loaded["neo-tree"].config.filesystem.filtered_items
  check("ignore_list: hide_by_name is a table", type(fi.hide_by_name) == "table")
  check("ignore_list: '.git' hidden via dict lookup", fi.hide_by_name[".git"] == true)
  check("ignore_list: '.agents' hidden (from lib.nvim's list)", fi.hide_by_name[".agents"] == true)
  check("ignore_list: '.claude' hidden (from lib.nvim's list)", fi.hide_by_name[".claude"] == true)
  check("ignore_list: not array-shaped (no numeric key 1)", fi.hide_by_name[1] == nil)
  -- setup() fires the refresh through `vim.defer_fn(…, 100)`, and `vim.wait`
  -- polls every 200ms unless told otherwise -- so a 150ms timeout with the
  -- default interval evaluated the condition at t=0, then gave up before its
  -- next poll, leaving only 50ms of slack for a 100ms timer. On an idle
  -- machine that passed; under load (several headless runs at once) the timer
  -- slipped past the timeout and this failed intermittently, with nothing in
  -- the output to suggest the test was at fault rather than the feature.
  -- An explicit small interval and a timeout an order of magnitude over the
  -- timer make it wait for the event, not for the clock.
  vim.wait(2000, function()
    return refreshed
  end, 10)
  check("ignore_list: adapter.refresh() called", refreshed)

  package.loaded["neo-tree"] = nil
  package.loaded["neo-tree.sources.manager"] = nil
  package.loaded["filetree.features.infra.ignore_list"] = nil
end

-- ── ignore_list: must force visible=false, even over a pre-existing true ────
-- `filtered_items.visible = true` disables the hide_by_name filter entirely
-- (neo-tree shows everything until "H" toggles it off). If the user's own
-- neo-tree opts already set visible=true for any reason, hide_by_name would
-- be correctly populated but never actually applied until a manual H press —
-- defeating this feature's documented purpose of hiding clutter by default.
do
  package.loaded["neo-tree"] = {
    config = { filesystem = { filtered_items = { visible = true } } },
  }
  package.loaded["neo-tree.sources.manager"] = {
    _get_all_states = function()
      return {}
    end,
  }
  package.loaded["filetree.features.infra.ignore_list"] = nil
  local il = require("filetree.features.infra.ignore_list")
  il.setup({ enabled = true }, {
    name = "neotree",
    refresh = function()
      return true
    end,
  })

  local fi = package.loaded["neo-tree"].config.filesystem.filtered_items
  check("ignore_list: visible forced to false even if pre-set true", fi.visible == false)

  package.loaded["neo-tree"] = nil
  package.loaded["neo-tree.sources.manager"] = nil
  package.loaded["filetree.features.infra.ignore_list"] = nil
end

-- ── ignore_list: predicate() feeds path-output actions (copy_file_list, ────
-- markdown_links) the same basenames this feature hides in the tree, so
-- recursive copies stop surfacing .git/node_modules/etc (see filetree.util.ignore).
do
  package.loaded["filetree.features.infra.ignore_list"] = nil
  local il = require("filetree.features.infra.ignore_list")

  check("ignore_list: predicate() ignores nothing before setup()", il.predicate()(".git") == false)

  il.setup({ enabled = true }, { name = "stub" })
  local pred = il.predicate()
  check("ignore_list: predicate() ignores '.git'", pred(".git") == true)
  check("ignore_list: predicate() ignores 'node_modules'", pred("node_modules") == true)
  check("ignore_list: predicate() does not ignore ordinary names", pred("src") == false)

  il.teardown()
  check(
    "ignore_list: predicate() ignores nothing after teardown()",
    il.predicate()(".git") == false
  )
  package.loaded["filetree.features.infra.ignore_list"] = nil
end

-- ── copy_file_list: recursive collection skips ignored subtrees (.git) ──────
-- Regression test for the bug this predicate wiring fixes: `[f`/`]f`/`[F`/`]F`
-- used to walk fs.collect_files/collect_folders with no ignore_fn at all, so
-- .git internals ended up in the copied path list.
do
  local tmp = (TMP_ROOT .. "/units-copyfilelist"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/.git/objects", "p")
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.writefile({ "x" }, tmp .. "/.git/HEAD")
  vim.fn.writefile({ "x" }, tmp .. "/src/main.lua")

  package.loaded["filetree.features.infra.ignore_list"] = nil
  local il = require("filetree.features.infra.ignore_list")
  il.setup({ enabled = true }, { name = "stub" })

  local fs = require("filetree.util.fs")
  local ignore = require("filetree.util.ignore")
  local files = fs.collect_files(tmp, ignore.predicate())

  local has_git = false
  for _, f in ipairs(files) do
    if f:find("/.git/", 1, true) then has_git = true end
  end
  check("copy_file_list: recursive collect skips .git subtree", not has_git)
  check(
    "copy_file_list: recursive collect still finds src/main.lua",
    vim.tbl_contains(files, tmp .. "/src/main.lua")
  )

  il.teardown()
  package.loaded["filetree.features.infra.ignore_list"] = nil
end

-- ── find_files: via_builtin fallback skips ignored subtrees (.git) too ──────
-- Same category of bug as copy_file_list above: vim.fn.globpath expands
-- everything, so without filtering the ignore predicate the picker would
-- offer .git internals as "find files" candidates. telescope/fzf-lua/
-- mini.pick aren't on rtp in this headless harness, so M.find() falls
-- through to via_builtin exactly as it would for a real user without those
-- plugins installed.
do
  local tmp = (TMP_ROOT .. "/units-findfiles"):gsub("\\", "/")
  vim.fn.mkdir(tmp .. "/.git/objects", "p")
  vim.fn.mkdir(tmp .. "/src", "p")
  vim.fn.writefile({ "x" }, tmp .. "/.git/HEAD")
  vim.fn.writefile({ "x" }, tmp .. "/src/main.lua")

  package.loaded["filetree.features.infra.ignore_list"] = nil
  local il = require("filetree.features.infra.ignore_list")
  il.setup({ enabled = true }, { name = "stub" })

  local shown
  package.loaded["ui.kit"] = {
    select = function(o)
      shown = o.items
    end,
  }
  package.loaded["filetree.util.select"] = nil
  package.loaded["filetree.features.search.find_files"] = nil
  local find_files = require("filetree.features.search.find_files")
  find_files.find(tmp)

  check("find_files: builtin fallback shown", shown ~= nil)
  local has_git = false
  for _, rel in ipairs(shown or {}) do
    if rel:find(".git/", 1, true) or rel == ".git" then has_git = true end
  end
  check("find_files: builtin fallback skips .git subtree", not has_git)
  check(
    "find_files: builtin fallback still finds src/main.lua",
    vim.tbl_contains(shown or {}, "src/main.lua") or vim.tbl_contains(shown or {}, "src\\main.lua")
  )

  il.teardown()
  package.loaded["filetree.features.infra.ignore_list"] = nil
  package.loaded["ui.kit"] = nil
  package.loaded["filetree.util.select"] = nil
  package.loaded["filetree.features.search.find_files"] = nil
end

-- ── copy_move: default single-char "c"/"x" cleanly override the adapter's ───
-- native "c"/"x" (exact same key, last-registration-wins -- no ambiguity).
do
  local tmp = (TMP_ROOT .. "/units-copymove"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf") -- fresh dst/ each run, so a leftover file1.txt from a
  -- prior run doesn't look like a paste conflict here
  vim.fn.mkdir(tmp .. "/dst", "p")
  vim.fn.writefile({ "hi" }, tmp .. "/file1.txt")

  local cur_node = { path = tmp .. "/file1.txt", type = "file" }
  local stub = setmetatable({
    name = "units-stub",
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
    adapter = "units-stub",
    features = {
      copy_move = { enabled = true, confirm = false, use_safety = false },
      -- The scratch buffer below is deliberately unnamed at the moment it's
      -- made current (name/filetype come after) so it looks exactly like a
      -- stray [No Name] buffer to no_name_guard, which would otherwise wipe
      -- it out from under this test before the keymap assertions below run.
      no_name_guard = { enabled = false },
    },
  })

  -- unlisted+scratch (buftype=nofile), like a real neo-tree buffer -- an
  -- ordinary listed buffer with no name is indistinguishable from a stray
  -- [No Name] window, which the enabled-by-default no_name_guard feature
  -- would wipe out from under this test during the vim.wait below.
  local buf = vim.api.nvim_create_buf(false, true)
  -- Simulate the adapter's own native single-char mappings, set BEFORE
  -- filetree's FileType-driven keymaps get scheduled (mirrors real timing).
  vim.api.nvim_buf_set_keymap(buf, "n", "c", "", { callback = function() end, nowait = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "x", "", { callback = function() end, nowait = true })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "neo-tree"
  vim.wait(200, function()
    return false
  end)

  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end
  check(
    "copy_move: 'c' overridden by filetree's own stage-copy handler",
    km["c"] ~= nil and km["c"].callback ~= nil
  )
  check(
    "copy_move: 'x' overridden by filetree's own stage-cut handler",
    km["x"] ~= nil and km["x"].callback ~= nil
  )

  local cm = ft.feature("copy_move")
  cm.stage_copy()
  cur_node = { path = tmp .. "/dst", type = "directory" }
  local captured
  local orig_notify = vim.notify
  -- A test double over typed `vim.*` surface: replacing the field is the
  -- point of the case, not a second definition of it.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured = m
  end
  cm.paste()
  vim.notify = orig_notify
  check(
    "copy_move: paste actually copies the file (shell-free vim.uv.fs_copyfile)",
    vim.fn.filereadable(tmp .. "/dst/file1.txt") == 1
  )
  check(
    "copy_move: notifies 1/1 pasted, not 'Clipboard is empty'",
    captured and captured:find("1/1") ~= nil,
    tostring(captured)
  )
end

-- ── copy_move: copying a symlink recreates the link, not its target ─────────
-- Regression: `do_copy`/`copy_dir` used to decide "directory or not" with a
-- plain `vim.fn.isdirectory()`, which follows a symlink transparently -- a
-- symlinked directory got silently deep-copied into a real one (unbounded
-- through a symlink cycle, since a real directory tree cannot have one but
-- this walk did not know that), and a symlinked file got silently
-- dereferenced into an independent copy of its target's content.
do
  local tmp = (TMP_ROOT .. "/units-copymove-symlink"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/src_dir", "p")
  vim.fn.mkdir(tmp .. "/dst", "p")
  vim.fn.writefile({ "inner" }, tmp .. "/src_dir/inner.txt")
  vim.fn.writefile({ "plain" }, tmp .. "/plain.txt")

  local uv = vim.uv or vim.loop
  local dir_link_ok = uv.fs_symlink(tmp .. "/src_dir", tmp .. "/link_to_dir", { dir = true })
  local file_link_ok = uv.fs_symlink(tmp .. "/plain.txt", tmp .. "/link_to_file.txt")

  if not dir_link_ok or not file_link_ok then
    print("  note no permission to create a real symlink here — skipping copy_move symlink case")
  else
    local cur_node = { path = tmp .. "/link_to_dir", type = "directory" }
    local stub = setmetatable({
      name = "units-stub-symlink",
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
      adapter = "units-stub-symlink",
      features = {
        copy_move = { enabled = true, confirm = false, use_safety = false },
        no_name_guard = { enabled = false },
      },
    })

    local cm = ft.feature("copy_move")

    -- A symlinked directory: staged, pasted, must land as a symlink again --
    -- not a deep copy of src_dir's contents.
    cur_node = { path = tmp .. "/link_to_dir", type = "directory" }
    cm.stage_copy()
    cur_node = { path = tmp .. "/dst", type = "directory" }
    cm.paste()
    local lst_dir = uv.fs_lstat(tmp .. "/dst/link_to_dir")
    check(
      "copy_move: a symlinked directory pastes as a symlink, not a deep copy",
      lst_dir ~= nil and lst_dir.type == "link"
    )

    -- A symlinked file: staged, pasted, must land as a symlink too -- not a
    -- dereferenced copy of plain.txt's content.
    cur_node = { path = tmp .. "/link_to_file.txt", type = "file" }
    cm.stage_copy()
    cur_node = { path = tmp .. "/dst", type = "directory" }
    cm.paste()
    local lst_file = uv.fs_lstat(tmp .. "/dst/link_to_file.txt")
    check(
      "copy_move: a symlinked file pastes as a symlink, not a dereferenced copy",
      lst_file ~= nil and lst_file.type == "link"
    )

    -- Control: an ORDINARY directory (not a link) still deep-copies for real
    -- -- the fix must not turn every directory copy into a symlink.
    cur_node = { path = tmp .. "/src_dir", type = "directory" }
    cm.stage_copy()
    cur_node = { path = tmp .. "/dst", type = "directory" }
    cm.paste()
    check(
      "copy_move: an ordinary directory still deep-copies its contents",
      vim.fn.filereadable(tmp .. "/dst/src_dir/inner.txt") == 1
    )
  end
end

-- ── copy_move: a user-configured two-char sequence (e.g. "yy"/"xx") must ────
-- still survive an adapter-native nowait single-char "y"/"x", for anyone who
-- opts back into that style via config. neo-tree's own window.mappings apply
-- a global `nowait = true`, so a native single-char "y" mapping fires
-- immediately on the first keypress, never giving Neovim a chance to wait
-- for the second character of "yy" -- copy_move must re-bind the bare prefix
-- char to a plain (non-nowait) <Nop> to restore Neovim's normal
-- ambiguous-mapping wait behaviour.
do
  local tmp = (TMP_ROOT .. "/units-copymove2"):gsub("\\", "/")
  vim.fn.mkdir(tmp, "p")

  local cur_node = { path = tmp, type = "directory" }
  local stub = setmetatable({
    name = "units-stub2",
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
    adapter = "units-stub2",
    features = {
      copy_move = {
        enabled = true,
        confirm = false,
        use_safety = false,
        keymaps = { copy = "yy", cut = "xx", paste = "p", show = "P" },
      },
      -- See the identical note on the previous copy_move test block: this
      -- scratch buffer is unnamed when it becomes current, which otherwise
      -- makes no_name_guard mistake it for a stray [No Name] buffer and wipe it.
      no_name_guard = { enabled = false },
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_keymap(buf, "n", "y", "", { callback = function() end, nowait = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "x", "", { callback = function() end, nowait = true })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "neo-tree"
  vim.wait(200, function()
    return false
  end)

  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end
  check(
    "copy_move (custom yy/xx): 'y' re-bound without nowait (unblocks 'yy')",
    km["y"] ~= nil and (km["y"].nowait == 0 or not km["y"].nowait)
  )
  check(
    "copy_move (custom yy/xx): 'x' re-bound without nowait (unblocks 'xx')",
    km["x"] ~= nil and (km["x"].nowait == 0 or not km["x"].nowait)
  )
  check("copy_move (custom yy/xx): 'yy' still bound", km["yy"] ~= nil)
  check("copy_move (custom yy/xx): 'xx' still bound", km["xx"] ~= nil)
end

-- ── copy_move: cut+paste repoints the open buffer at the moved file ─────────
-- End-to-end regression for the user-reported bug: cutting a node (x) and
-- pasting (p) it into a new directory left the original buffer pointing at a
-- path that no longer existed on disk; opening the file at its new location
-- then created a second, disconnected buffer instead of reusing the original.
do
  local tmp = (TMP_ROOT .. "/units-copymove-relocate"):gsub("\\", "/")
  -- Wipe any leftover state from a previous run first: do_move() deliberately
  -- refuses to silently overwrite an existing destination, so a stale
  -- docs/filetree/filetree.md from a prior run would make this test fail for
  -- a reason that has nothing to do with the behavior under test.
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/docs", "p")
  vim.fn.writefile({ "# filetree" }, tmp .. "/docs/filetree.md")

  vim.cmd("edit " .. tmp .. "/docs/filetree.md")
  local orig_buf = vim.api.nvim_get_current_buf()

  vim.fn.mkdir(tmp .. "/docs/filetree", "p")
  local cur_node = { path = tmp .. "/docs/filetree.md", type = "file" }
  local target_node = { path = tmp .. "/docs/filetree", type = "directory" }
  local stub = setmetatable({
    name = "units-stub7",
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
    adapter = "units-stub7",
    features = { copy_move = { enabled = true, confirm = false, use_safety = false } },
  })

  local copy_move = ft.feature("copy_move")
  copy_move.stage_cut()
  stub.get_current_node = function()
    return target_node
  end -- cursor now on the new dir
  -- A cut awaits its reference scan before moving anything, so the paste
  -- completes a few event-loop ticks after the call returns.
  copy_move.paste()
  vim.wait(5000, function()
    return vim.fn.filereadable(tmp .. "/docs/filetree/filetree.md") == 1
  end, 20)

  eq(
    "copy_move relocate: original path no longer readable",
    vim.fn.filereadable(tmp .. "/docs/filetree.md"),
    0
  )
  eq(
    "copy_move relocate: file exists at the new path",
    vim.fn.filereadable(tmp .. "/docs/filetree/filetree.md"),
    1
  )
  eq(
    "copy_move relocate: original buffer repointed to the new path",
    vim.api.nvim_buf_get_name(orig_buf):gsub("\\", "/"),
    tmp .. "/docs/filetree/filetree.md"
  )

  local bufcount_before = #vim.api.nvim_list_bufs()
  vim.cmd("edit " .. tmp .. "/docs/filetree/filetree.md")
  check(
    "copy_move relocate: opening the new-location file reuses the original buffer (no duplicate)",
    vim.api.nvim_get_current_buf() == orig_buf and #vim.api.nvim_list_bufs() == bufcount_before
  )
end

-- ── copy_move: a move blocked by a sharing lock is NOT silent ───────────────
-- Regression for a user report: cutting (x) a file whose containing folder
-- was open elsewhere (Explorer, an indexer, an AV scan) and pasting (p) into
-- another directory appeared to do nothing at all -- do_move() discarded
-- mutate.move's error entirely, so a blocked move and a stale event loop
-- looked identical, and the final "Pasted 0/1 item(s)" summary never even
-- mentions a failure count.
do
  local tmp = (TMP_ROOT .. "/units-copymove-lockfail"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dest", "p")
  vim.fn.writefile({ "locked" }, tmp .. "/locked.txt")

  local cur_node = { path = tmp .. "/locked.txt", type = "file" }
  local dest_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-copymove-lockfail",
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
    adapter = "units-stub-copymove-lockfail",
    features = { copy_move = { enabled = true, confirm = false, use_safety = false } },
  })
  local copy_move = ft.feature("copy_move")

  -- Fake the actual libuv rename call, not filetree.util.mutate itself --
  -- exercising the real retry/backoff path `mutate.move` wraps it in, the
  -- same way the EXDEV hardlink-fallback test above fakes `mutate.hardlink`
  -- rather than a higher layer.
  local fsops = require("lib.nvim.cross.fs.mutate")
  local orig_rename = fsops.rename_file
  ---@diagnostic disable-next-line: duplicate-set-field
  fsops.rename_file = function(_, _)
    return false, "EPERM: operation not permitted, rename 'fake' -> 'fake'"
  end

  local captured = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured[#captured + 1] = tostring(m)
  end

  copy_move.stage_cut()
  stub.get_current_node = function()
    return dest_node
  end -- cursor now on the destination dir
  copy_move.paste()
  -- 5000ms, matching the "copy_move relocate" test above for the identical
  -- stage+paste async chain: refs.prefetch's own scan.timeout_ms defaults to
  -- 3000ms, so a shorter wait here could give up before a slow/cold-cache
  -- scan finishes.
  vim.wait(5000, function()
    return #captured >= 2 -- the stage-cut notice, plus at least the failure/summary
  end, 20)

  vim.notify = orig_notify
  fsops.rename_file = orig_rename
  package.loaded["filetree.features.fileops.copy_move"] = nil

  check(
    "copy_move lockfail: the source is untouched (the move genuinely never landed)",
    vim.fn.filereadable(tmp .. "/locked.txt") == 1
      and vim.fn.filereadable(tmp .. "/dest/locked.txt") == 0
  )
  local all = table.concat(captured, " | ")
  local lower = all:lower()
  check(
    "copy_move lockfail: a failure notification names the failed item",
    lower:find("failed", 1, true) ~= nil and lower:find("locked.txt", 1, true) ~= nil,
    all
  )
  check(
    "copy_move lockfail: the underlying lock reason is surfaced, not swallowed",
    lower:find("eperm", 1, true) ~= nil,
    all
  )
end

-- ── copy_move: a copy blocked by a sharing lock is NOT silent either ────────
-- do_copy() had the identical gap do_move() just got fixed for: a copy
-- (c+p) that fails partway through (plain file, or the recursive directory
-- walk) discarded fsops.copy_file's error just the same.
do
  local tmp = (TMP_ROOT .. "/units-copymove-copylockfail"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dest", "p")
  vim.fn.writefile({ "locked" }, tmp .. "/locked.txt")

  local cur_node = { path = tmp .. "/locked.txt", type = "file" }
  local dest_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-copymove-copylockfail",
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
    adapter = "units-stub-copymove-copylockfail",
    features = { copy_move = { enabled = true, confirm = false, use_safety = false } },
  })
  local copy_move = ft.feature("copy_move")

  local fsops = require("lib.nvim.cross.fs.mutate")
  local orig_copy_file = fsops.copy_file
  ---@diagnostic disable-next-line: duplicate-set-field
  fsops.copy_file = function(_, _)
    return false, "EBUSY: resource busy or locked: fake"
  end

  local captured = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured[#captured + 1] = tostring(m)
  end

  copy_move.stage_copy()
  stub.get_current_node = function()
    return dest_node
  end
  copy_move.paste()
  -- Same reasoning as the lockfail (move) test above: 5000ms, not 2000ms,
  -- to stay clear of refs.prefetch's own 3000ms scan.timeout_ms default.
  vim.wait(5000, function()
    return #captured >= 2
  end, 20)

  vim.notify = orig_notify
  fsops.copy_file = orig_copy_file
  package.loaded["filetree.features.fileops.copy_move"] = nil

  check(
    "copy_move copy-lockfail: no partial file was left at the destination",
    vim.fn.filereadable(tmp .. "/dest/locked.txt") == 0
  )
  local all = table.concat(captured, " | ")
  local lower = all:lower()
  check(
    "copy_move copy-lockfail: a failure notification names the failed item",
    lower:find("failed", 1, true) ~= nil and lower:find("locked.txt", 1, true) ~= nil,
    all
  )
  check(
    "copy_move copy-lockfail: the underlying lock reason is surfaced, not swallowed",
    lower:find("ebusy", 1, true) ~= nil,
    all
  )
end

-- ── copy_move: a sharing lock deep inside a directory copy propagates too ───
-- The two tests above only ever reach do_copy()'s flat, single-file
-- fsops.copy_file branch. copy_dir()'s own recursive error propagation (a
-- failure surfacing through a NESTED subdirectory's own copy_dir() call, not
-- just a direct fsops.copy_file call) was untested -- this fakes copy_file to
-- fail only for a file two levels deep, letting a sibling file at the top
-- level copy for real, so the failure can only reach do_paste_impl by
-- travelling back up through copy_dir's own recursive `return rc, err`.
do
  local tmp = (TMP_ROOT .. "/units-copymove-dircopylockfail"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dest", "p")
  vim.fn.mkdir(tmp .. "/src/sub", "p")
  vim.fn.writefile({ "ok" }, tmp .. "/src/regular.txt")
  vim.fn.writefile({ "locked" }, tmp .. "/src/sub/nested.txt")

  local cur_node = { path = tmp .. "/src", type = "directory" }
  local dest_node = { path = tmp .. "/dest", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-copymove-dircopylockfail",
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
    adapter = "units-stub-copymove-dircopylockfail",
    features = { copy_move = { enabled = true, confirm = false, use_safety = false } },
  })
  local copy_move = ft.feature("copy_move")

  -- Real copy_file for everything except the deeply-nested file, so the
  -- top-level entry (regular.txt) genuinely succeeds and the failure can
  -- only be observed if copy_dir's OWN recursive call correctly forwards it.
  local fsops = require("lib.nvim.cross.fs.mutate")
  local orig_copy_file = fsops.copy_file
  ---@diagnostic disable-next-line: duplicate-set-field
  fsops.copy_file = function(s, d)
    if tostring(d):find("nested.txt", 1, true) then
      return false, "EBUSY: resource busy or locked: fake"
    end
    return orig_copy_file(s, d)
  end

  local captured = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    captured[#captured + 1] = tostring(m)
  end

  copy_move.stage_copy()
  stub.get_current_node = function()
    return dest_node
  end
  copy_move.paste()
  vim.wait(5000, function()
    return #captured >= 2
  end, 20)

  vim.notify = orig_notify
  fsops.copy_file = orig_copy_file
  package.loaded["filetree.features.fileops.copy_move"] = nil

  check(
    "copy_move dir-copy-lockfail: the sibling file at the top level copied for real",
    vim.fn.filereadable(tmp .. "/dest/src/regular.txt") == 1,
    "readdir order may have skipped it -- see the comment above this block"
  )
  check(
    "copy_move dir-copy-lockfail: the nested locked file was not copied",
    vim.fn.filereadable(tmp .. "/dest/src/sub/nested.txt") == 0
  )
  local all = table.concat(captured, " | ")
  local lower = all:lower()
  check(
    "copy_move dir-copy-lockfail: the failure surfaces even though it happened two levels deep",
    lower:find("failed", 1, true) ~= nil and lower:find("ebusy", 1, true) ~= nil,
    all
  )
end

-- ── copy_move: reference engine -- cut updates refs, copy leaves them ───────
do
  local tmp = (TMP_ROOT .. "/units-copymove-refs"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/dst", "p")
  local cut_src = tmp .. "/cut.md"
  local cut_dst = tmp .. "/dst/cut.md"
  local copy_src = tmp .. "/copy.md"
  local copy_dst = tmp .. "/dst/copy.md"
  local linker = tmp .. "/linker.md"
  -- Project marker, so the reference scan's root is this fixture and not
  -- whatever directory the system temp dir happens to sit in.
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json")
  vim.fn.writefile({ "# Cut" }, cut_src)
  vim.fn.writefile({ "# Copy" }, copy_src)
  vim.fn.writefile({ "Refs: [cut](cut.md) and [copy](copy.md)." }, linker)

  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    on_choice(choices[1]) -- "Update all"
  end
  package.loaded["filetree.features.fileops.copy_move"] = nil -- reload with stubs

  local cur_node = { path = tmp .. "/dst", type = "directory" }
  local stub = setmetatable({
    name = "units-stub-copymove-mdrefs",
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
    adapter = "units-stub-copymove-mdrefs",
    refs = { on_move = "ask" },
    features = { copy_move = { enabled = true, confirm = false, use_safety = false } },
  })

  local cm = ft.feature("copy_move")

  -- Cut cut.md, paste into dst/ -> its reference must be updated. The paste
  -- awaits the reference scan, so it completes a few event-loop ticks later.
  cur_node = { path = cut_src, type = "file" }
  cm.stage_cut()
  cur_node = { path = tmp .. "/dst", type = "directory" }
  cm.paste()
  vim.wait(5000, function()
    return vim.fn.filereadable(cut_dst) == 1
  end, 20)
  eq("copy_move+refs: cut file moved", vim.fn.filereadable(cut_dst), 1)

  -- Copy copy.md, paste into dst/ -> the original stays put, no ref check needed.
  cur_node = { path = copy_src, type = "file" }
  cm.stage_copy()
  cur_node = { path = tmp .. "/dst", type = "directory" }
  cm.paste()
  vim.wait(5000, function()
    return vim.fn.filereadable(copy_dst) == 1
  end, 20)
  eq("copy_move+refs: copied file duplicated, original untouched", vim.fn.filereadable(copy_src), 1)
  eq("copy_move+refs: copy landed at destination too", vim.fn.filereadable(copy_dst), 1)

  local linker_lines = vim.fn.readfile(linker)
  check(
    "copy_move+refs: cut reference rewritten to the new (dst/) path",
    linker_lines[1]:find("dst/cut.md", 1, true) ~= nil,
    linker_lines[1]
  )
  check(
    "copy_move+refs: copy reference left exactly as-is (original still valid)",
    linker_lines[1]:find("](copy.md)", 1, true) ~= nil,
    linker_lines[1]
  )

  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.copy_move"] = nil
end

-- ── trash: delete_current binds d/U/<leader>th and trashes the right node ───
do
  local tmp = (TMP_ROOT .. "/units-trash"):gsub("\\", "/")
  vim.fn.mkdir(tmp, "p")
  vim.fn.writefile({ "x" }, tmp .. "/victim.txt")

  local cur_node = { path = tmp .. "/victim.txt", type = "file" }
  local stub = setmetatable({
    name = "units-stub3",
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
    adapter = "units-stub3",
    features = {
      trash = { enabled = true, confirm = false, dry_run = true },
      -- See the note on the copy_move keymap tests above: this scratch buffer
      -- is unnamed when made current, which no_name_guard would otherwise
      -- mistake for a stray [No Name] buffer and wipe before the keymap
      -- assertions below run.
      no_name_guard = { enabled = false },
    },
  })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "neo-tree"
  vim.wait(200, function()
    return false
  end)

  -- "<leader>" is substituted with the current mapleader (default "\") at
  -- map-registration time, so nvim_buf_get_keymap reports the already-expanded
  -- lhs, not the literal "<leader>..." string.
  local leader = vim.g.mapleader or "\\"
  local km = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    km[m.lhs] = m
  end
  check("trash: 'd' bound", km["d"] ~= nil)
  check("trash: 'U' bound", km["U"] ~= nil)
  check("trash: '<leader>th' bound", km[leader .. "th"] ~= nil)

  local trash = ft.feature("trash")
  -- delete_current() now emits more than one message for a batch (the per-item
  -- dry-run line + a single summary), so accumulate them all rather than only
  -- keeping the last one.
  local messages = {}
  local orig_notify = vim.notify
  -- A test double over typed `vim.*` surface: replacing the field is the
  -- point of the case, not a second definition of it.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(m)
    messages[#messages + 1] = m
  end
  trash.delete_current()
  vim.notify = orig_notify
  local joined = table.concat(messages, "\n")
  check(
    "trash: delete_current() (dry-run) targets the current node",
    joined:find("victim.txt", 1, true) ~= nil,
    joined
  )
end

-- ── trash: single delete closes the file's open buffer ──────────────────────
-- Deleting a file must force-close any buffer still open for it, so a stale
-- buffer doesn't linger pointing at a now-deleted path. Uses a stubbed trash
-- backend (removes the file from disk, no real Recycle Bin side effects).
do
  local tmp = (TMP_ROOT .. "/units-trash-bufclose"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local file = tmp .. "/doomed.txt"
  vim.fn.writefile({ "x" }, file)

  -- Stub the platform so no real trash happens; it just deletes on disk.
  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
  }
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with the stub

  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local doomed_buf = vim.api.nvim_get_current_buf()

  local cur_node = { path = file, type = "file" }
  local stub = setmetatable({
    name = "units-stub-bufclose",
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
  -- confirm = false → single item deletes straight away (no y/N to drive).
  ft.setup({
    adapter = "units-stub-bufclose",
    features = { trash = { enabled = true, confirm = false } },
  })

  -- Trashing is asynchronous (the reference scan runs first, then the platform
  -- backend, then the buffer cleanup), so wait for the end of the chain rather
  -- than asserting on the tick the call returns.
  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(file) == 0
      and (not vim.api.nvim_buf_is_valid(doomed_buf) or vim.api.nvim_buf_get_name(doomed_buf) == "")
  end, 20)

  eq("trash: single delete removes the file", vim.fn.filereadable(file), 0)
  check(
    "trash: single delete force-closes the file's buffer",
    not vim.api.nvim_buf_is_valid(doomed_buf) or vim.api.nvim_buf_get_name(doomed_buf) == ""
  )

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── trash: mode = "permanent" skips the OS trash and undo history ───────────
-- Opt-in permanent delete must never touch the trash backend at all (the
-- platform stub errors if called) and must not add a trash-history entry —
-- there is nothing to restore, so `U`/history must not pretend otherwise.
do
  local tmp = (TMP_ROOT .. "/units-trash-permanent"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local file = tmp .. "/doomed.txt"
  vim.fn.writefile({ "x" }, file)

  -- If permanent mode ever fell through to the OS trash, this stub's error
  -- would fail the test loudly instead of the assertion below staying silent.
  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function()
      error('mode = "permanent" must never call the trash backend')
    end,
  }
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with the stub

  local cur_node = { path = file, type = "file" }
  local stub = setmetatable({
    name = "units-stub-permanent",
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
    adapter = "units-stub-permanent",
    features = { trash = { enabled = true, confirm = false, mode = "permanent" } },
  })

  local history_before = #require("filetree.features.fileops.trash.undo").history()

  ft.feature("trash").delete_current()
  vim.wait(2000, function()
    return vim.fn.filereadable(file) == 0
  end, 10)

  eq("trash mode=permanent: file actually gone from disk", vim.fn.filereadable(file), 0)
  eq(
    "trash mode=permanent: no trash-history entry recorded",
    #require("filetree.features.fileops.trash.undo").history(),
    history_before
  )

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── trash: multi-mark batch chooser deletes all + clears marks ──────────────
-- With >1 item, delete_current() shows ONE chooser (hover_select) instead of
-- prompting per file. Stub the chooser to pick "Delete all at once" and stub
-- the marks feature to report two marked paths; verify both are trashed, both
-- buffers closed, and marks cleared once.
do
  local tmp = (TMP_ROOT .. "/units-trash-batch"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local a, b = tmp .. "/a.txt", tmp .. "/b.txt"
  vim.fn.writefile({ "a" }, a)
  vim.fn.writefile({ "b" }, b)

  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
    -- >1 marked path routes run_all through send_batch now (see
    -- run_all_batched in trash/init.lua), not a chain of `send` calls.
    send_batch = function(paths, cb)
      local results = {}
      for i, p in ipairs(paths) do
        os.remove(p)
        results[i] = { ok = true }
      end
      if cb then cb(results) end
    end,
  }
  -- Auto-drive the batch chooser: always pick option 1 ("Delete all at once").
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    on_choice(choices[1])
  end
  -- Stub marks: report a + b as marked, track that clear_all was called.
  local cleared = false
  package.loaded["filetree.features.org.marks"] = {
    setup = function() end,
    teardown = function() end,
    count = function()
      return 2
    end,
    get_marked = function()
      return { a, b }
    end,
    clear_all = function()
      cleared = true
    end,
  }
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with stubs

  vim.cmd("edit " .. vim.fn.fnameescape(a))
  local buf_a = vim.api.nvim_get_current_buf()
  vim.cmd("edit " .. vim.fn.fnameescape(b))
  local buf_b = vim.api.nvim_get_current_buf()

  local stub = setmetatable({
    name = "units-stub-batch",
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
    adapter = "units-stub-batch",
    features = { trash = { enabled = true, confirm = true } },
  })

  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(a) == 0 and vim.fn.filereadable(b) == 0 and cleared
  end, 20)

  eq("trash batch: file a removed", vim.fn.filereadable(a), 0)
  eq("trash batch: file b removed", vim.fn.filereadable(b), 0)
  check(
    "trash batch: buffer a closed",
    not vim.api.nvim_buf_is_valid(buf_a) or vim.api.nvim_buf_get_name(buf_a) == ""
  )
  check(
    "trash batch: buffer b closed",
    not vim.api.nvim_buf_is_valid(buf_b) or vim.api.nvim_buf_get_name(buf_b) == ""
  )
  check("trash batch: marks cleared after successful delete", cleared)

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.org.marks"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── refs.apply: patches a LIVE buffer, not just the file on disk ────────────
-- Regression: writefile() alone doesn't reload an open buffer (only a later
-- checktime/autoread does — hence "switch away and back" was needed). apply
-- must patch the open buffer directly and, when it had no unsaved changes,
-- persist + keep it unmodified. A ref without a column (`col = 0`) falls back
-- to replacing the first literal occurrence of its target.
do
  local refs_apply = require("filetree.refs.apply")
  local tmp = (TMP_ROOT .. "/units-refs-livebuf"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")

  -- Case 1: referencing file OPEN in an unmodified buffer.
  local open_file = tmp .. "/open.md"
  vim.fn.writefile({ "intro", "See [x](old.md) here.", "outro" }, open_file)
  vim.cmd("edit " .. vim.fn.fnameescape(open_file))
  local buf = vim.api.nvim_get_current_buf()

  refs_apply.run({
    {
      file = open_file,
      line = 2,
      col = 9,
      target = "old.md",
      display = "[x](old.md)",
      new_target = "new.md",
    },
  })

  local buf_line2 = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
  check(
    "refs.apply: open buffer patched live (no reload needed)",
    buf_line2 == "See [x](new.md) here.",
    buf_line2
  )
  check(
    "refs.apply: buffer left unmodified (change persisted to disk)",
    vim.bo[buf].modified == false
  )
  local disk = vim.fn.readfile(open_file)
  check(
    "refs.apply: disk also updated for the open+unmodified buffer",
    disk[2] == "See [x](new.md) here.",
    disk[2]
  )

  -- Case 2: referencing file NOT open anywhere -> disk edit as before.
  local closed_file = tmp .. "/closed.md"
  vim.fn.writefile({ "[y](old.md)" }, closed_file)
  refs_apply.run({
    {
      file = closed_file,
      line = 1,
      col = 0,
      target = "old.md",
      display = "[y](old.md)",
      new_target = "new.md",
    },
  })
  check(
    "refs.apply: closed file edited on disk (col = 0 fallback)",
    vim.fn.readfile(closed_file)[1] == "[y](new.md)"
  )

  -- Case 3: open buffer WITH unsaved changes -> patched live, left modified,
  -- disk NOT written (user's edits win on their own save).
  local dirty_file = tmp .. "/dirty.md"
  vim.fn.writefile({ "[z](old.md)" }, dirty_file)
  vim.cmd("edit " .. vim.fn.fnameescape(dirty_file))
  local dbuf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(dbuf, 1, 1, false, { "unsaved tail" }) -- make it modified
  refs_apply.run({
    {
      file = dirty_file,
      line = 1,
      col = 0,
      target = "old.md",
      display = "[z](old.md)",
      new_target = "new.md",
    },
  })
  check(
    "refs.apply: dirty buffer patched live",
    vim.api.nvim_buf_get_lines(dbuf, 0, 1, false)[1] == "[z](new.md)"
  )
  check("refs.apply: dirty buffer stays modified (not force-saved)", vim.bo[dbuf].modified == true)
  check(
    "refs.apply: disk left untouched while buffer is dirty",
    vim.fn.readfile(dirty_file)[1] == "[z](old.md)"
  )

  -- cleanup buffers
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  pcall(vim.api.nvim_buf_delete, dbuf, { force = true })
end

-- ── refs.apply: a wide change is applied in chunks, totals via on_done ──────
-- More than APPLY_CHUNK_SIZE (8) referencing files: apply must spread the
-- rewrites across event-loop ticks and deliver the totals through the
-- callback, and undo must reverse every one of them.
do
  local refs_apply = require("filetree.refs.apply")
  refs_apply.reset()
  local tmp = (TMP_ROOT .. "/units-refs-wide"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")

  local n = 20
  local refs = {}
  for i = 1, n do
    local f = string.format("%s/ref_%02d.md", tmp, i)
    vim.fn.writefile({ "top", "link [x](old.md) here", "bottom" }, f)
    refs[#refs + 1] = {
      file = f,
      line = 2,
      col = 10,
      target = "old.md",
      display = "[x](old.md)",
      new_target = "new.md",
    }
  end

  local done_applied, done_files
  local snap = refs_apply.run(refs, { label = "wide rename" }, function(applied, files_changed)
    done_applied, done_files = applied, files_changed
  end)
  check(
    "refs.apply(wide): sync return is a partial snapshot",
    snap > 0 and snap < n,
    tostring(snap)
  )
  local settled = vim.wait(4000, function()
    return done_applied ~= nil
  end)
  check(
    "refs.apply(wide): on_done fired with the real total",
    settled and done_applied == n,
    tostring(done_applied)
  )
  check("refs.apply(wide): every file counted", done_files == n, tostring(done_files))
  check(
    "refs.apply(wide): last file was actually rewritten",
    vim.fn.readfile(string.format("%s/ref_%02d.md", tmp, n))[2] == "link [x](new.md) here"
  )

  local undone_restored
  refs_apply.undo(function(restored)
    undone_restored = restored
  end)
  local undo_settled = vim.wait(4000, function()
    return undone_restored ~= nil
  end)
  check(
    "refs.apply(wide): undo restored every reference",
    undo_settled and undone_restored == n,
    tostring(undone_restored)
  )
  check(
    "refs.apply(wide): undo reverted the last file on disk",
    vim.fn.readfile(string.format("%s/ref_%02d.md", tmp, n))[2] == "link [x](old.md) here"
  )
  refs_apply.reset()
end

-- ── refs.scan: ripgrep-free fallback walk is chunked ────────────────────────
-- Force the rg-unavailable path (stub vim.fn.executable) with more than
-- WALK_CHUNK_SIZE (20) extension-matching files: the read loop must spread
-- across event-loop ticks and still find exactly the files that hold a
-- needle, skipping the ones that don't.
do
  local refs_scan = require("filetree.refs.scan")
  local tmp = (TMP_ROOT .. "/units-refs-scan-walk"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")

  local n = 25
  for i = 1, n do
    local f = string.format("%s/cand_%02d.md", tmp, i)
    if i % 3 == 0 then
      vim.fn.writefile({ "see NEEDLE_HIT here" }, f)
    else
      vim.fn.writefile({ "nothing relevant" }, f)
    end
  end

  local orig_executable = vim.fn.executable
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.executable = function(name)
    if name == "rg" then return 0 end
    return orig_executable(name)
  end

  local result
  refs_scan.candidates(tmp, { "NEEDLE_HIT" }, { "md" }, {}, function(files)
    result = files
  end)
  vim.fn.executable = orig_executable

  local settled = vim.wait(4000, function()
    return result ~= nil
  end)
  check("refs.scan(walk, wide): callback fired", settled)
  check(
    "refs.scan(walk, wide): found exactly the hitting files",
    result ~= nil and #result == math.floor(n / 3),
    tostring(result and #result)
  )

  vim.fn.delete(tmp, "rf")
end

-- ── trash: reference chooser + cleanup ──────────────────────────────────────
-- When something links to the file being trashed, delete_current() must show
-- the 3-way chooser (not the plain y/N popup) and, on "delete + remove
-- references", rewrite that line's link target to "REF!" in the referencing
-- file.
do
  local tmp = (TMP_ROOT .. "/units-trash-refs"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local victim = tmp .. "/victim.md"
  local linker = tmp .. "/linker.md"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "# Victim" }, victim)
  vim.fn.writefile({ "intro", "See [victim](victim.md) here.", "outro" }, linker)

  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
  }
  -- Auto-drive the chooser: always pick option 1 ("Delete + remove refs").
  local select_prompt = nil
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(question, choices, on_choice)
    select_prompt = question
    on_choice(choices[1])
  end
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with stubs

  local cur_node = { path = victim, type = "file" }
  local stub = setmetatable({
    name = "units-stub-mdrefs",
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
    adapter = "units-stub-mdrefs",
    features = { trash = { enabled = true, confirm = true } },
  })

  -- The reference scan runs before the dialog can be drawn, so the whole flow
  -- resolves a few event-loop ticks after the call returns.
  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(victim) == 0
  end, 20)

  check(
    "trash+refs: a reference triggers the chooser, not the plain y/N popup",
    select_prompt ~= nil and select_prompt:find("ref", 1, true) ~= nil,
    tostring(select_prompt)
  )
  eq("trash+refs: victim file removed", vim.fn.filereadable(victim), 0)
  local linker_lines = vim.fn.readfile(linker)
  check(
    "trash+refs: referencing line rewritten to REF!",
    linker_lines[2] == "See [victim](REF!) here.",
    linker_lines[2]
  )
  check(
    "trash+refs: unrelated lines untouched",
    linker_lines[1] == "intro" and linker_lines[3] == "outro"
  )

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── trash: "Inspect references" (idx 2) -> quickfix picker -> partial cleanup ─
-- End-to-end through the real chooser: pick "Inspect references first", the
-- quickfix fallback opens (no telescope/fzf-lua stubbed), prune one entry the
-- same way a user would (delete a line), confirm via the picker's own public
-- API, and verify only the surviving reference got cleaned up.
do
  local tmp = (TMP_ROOT .. "/units-trash-refs-inspect"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp, "p")
  local victim = tmp .. "/victim.md"
  local linker = tmp .. "/linker.md"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "# Victim" }, victim)
  vim.fn.writefile({
    "See [victim](victim.md) here.",
    "Again: [victim](victim.md) there.",
  }, linker)

  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
  }
  -- Auto-drive the chooser: always pick option 2 ("Inspect first").
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    on_choice(choices[2])
  end
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with stubs

  local cur_node = { path = victim, type = "file" }
  local stub = setmetatable({
    name = "units-stub-mdrefs-inspect",
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
    adapter = "units-stub-mdrefs-inspect",
    refs = { picker = "quickfix" },
    features = { trash = { enabled = true, confirm = true } },
  })

  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return #vim.fn.getqflist() > 0
  end, 20)

  -- The quickfix picker is now open awaiting user pruning; simulate keeping
  -- only line 1's reference (drop the line-2 duplicate) and confirming.
  local qf = vim.fn.getqflist()
  check("trash+inspect: quickfix populated with both references", #qf == 2)
  vim.fn.setqflist({}, "r", { items = { qf[1] } })
  require("filetree.util.refs_picker").qf_confirm()

  vim.wait(5000, function()
    return vim.fn.filereadable(victim) == 0
  end, 20)
  eq("trash+inspect: victim file removed", vim.fn.filereadable(victim), 0)
  local linker_lines = vim.fn.readfile(linker)
  check(
    "trash+inspect: kept reference (line 1) was cleaned up",
    linker_lines[1] == "See [victim](REF!) here.",
    linker_lines[1]
  )
  check(
    "trash+inspect: pruned reference (line 2) was left untouched",
    linker_lines[2] == "Again: [victim](victim.md) there.",
    linker_lines[2]
  )

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── trash: cascade-delete-assets — orphaned asset offered and deleted ───────
-- Step 3 of the cascade-delete-assets feature: a markdown file that links
-- to an image under assets/ which nothing else references has no INCOMING
-- refs of its own, so this must still trigger the chooser (asset-only, no
-- "Inspect first" branch) and, on confirm, cascade-delete the asset too.
do
  local tmp = (TMP_ROOT .. "/units-trash-asset-delete"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/assets", "p")
  local victim = tmp .. "/victim.md"
  local asset = tmp .. "/assets/shot.png"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "x" }, asset)
  vim.fn.writefile({ "# Victim", "![shot](assets/shot.png)" }, victim)

  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
  }
  local select_prompt, select_choices = nil, nil
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(question, choices, on_choice)
    select_prompt = question
    select_choices = choices
    on_choice(choices[1]) -- "Delete + remove assets"
  end
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with stubs

  local cur_node = { path = victim, type = "file" }
  local stub = setmetatable({
    name = "units-stub-asset-delete",
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
    adapter = "units-stub-asset-delete",
    refs = { outgoing_assets = { enabled = true, on_delete = "ask" } },
    features = { trash = { enabled = true, confirm = true } },
  })

  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(victim) == 0
  end, 20)

  check(
    "trash+assets: an orphaned asset triggers the chooser, no incoming refs needed",
    select_prompt ~= nil and select_prompt:find("asset", 1, true) ~= nil,
    tostring(select_prompt)
  )
  check(
    "trash+assets: no 'Inspect first' offered when there are no incoming refs",
    select_choices ~= nil
      and (function()
        for _, c in ipairs(select_choices) do
          if c == "Inspect first" then return false end
        end
        return true
      end)()
  )
  eq("trash+assets: victim file removed", vim.fn.filereadable(victim), 0)
  eq("trash+assets: the orphaned asset was cascade-deleted too", vim.fn.filereadable(asset), 0)

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── trash: cascade-delete-assets — asset still referenced elsewhere survives ─
-- Same shape, but a SECOND markdown file also links to the same asset: the
-- classifier's incoming-safety recheck must exclude it from the delete
-- offer, and with no incoming refs to the victim either, the plain y/N popup
-- is used (not the chooser) even though an asset link exists on the page.
do
  local tmp = (TMP_ROOT .. "/units-trash-asset-survives"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/assets", "p")
  local victim = tmp .. "/victim.md"
  local other = tmp .. "/other.md"
  local asset = tmp .. "/assets/shared.png"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "x" }, asset)
  vim.fn.writefile({ "# Victim", "![shared](assets/shared.png)" }, victim)
  vim.fn.writefile({ "Also shared: ![shared](assets/shared.png)" }, other)

  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
  }
  -- The plain y/N popup is expected here, not the chooser -- confirm_choice
  -- must never fire when the only asset found is one that survives.
  local choice_fired = false
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    choice_fired = true
    on_choice(choices[1])
  end
  local confirmed_question
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm"] = function(opts)
    confirmed_question = opts.question
    opts.on_choice(true)
  end
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with stubs

  local cur_node = { path = victim, type = "file" }
  local stub = setmetatable({
    name = "units-stub-asset-survives",
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
    adapter = "units-stub-asset-survives",
    refs = { outgoing_assets = { enabled = true, on_delete = "ask" } },
    features = { trash = { enabled = true, confirm = true } },
  })

  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(victim) == 0
  end, 20)

  check("trash+assets survives: the plain y/N popup was used", confirmed_question ~= nil)
  check("trash+assets survives: the chooser never fired", not choice_fired)
  eq("trash+assets survives: victim file removed", vim.fn.filereadable(victim), 0)
  eq(
    "trash+assets survives: the still-referenced asset was NOT deleted",
    vim.fn.filereadable(asset),
    1
  )

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.util.confirm"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── trash: cascade-delete-assets — off by default (step 4's config gate) ────
-- Same shape as "orphaned asset offered and deleted" above, but with NO
-- `refs.outgoing_assets` config at all: the feature must stay off (plain
-- y/N popup, asset untouched) until a config explicitly turns it on, even
-- though the asset itself would otherwise qualify (right root, right
-- extension, no other referrer).
do
  local tmp = (TMP_ROOT .. "/units-trash-asset-gate-off"):gsub("\\", "/")
  vim.fn.delete(tmp, "rf")
  vim.fn.mkdir(tmp .. "/assets", "p")
  local victim = tmp .. "/victim.md"
  local asset = tmp .. "/assets/shot.png"
  vim.fn.writefile({ "{}" }, tmp .. "/.luarc.json") -- project marker: scan root
  vim.fn.writefile({ "x" }, asset)
  vim.fn.writefile({ "# Victim", "![shot](assets/shot.png)" }, victim)

  package.loaded["filetree.features.fileops.trash.platform"] = {
    available = function()
      return true
    end,
    send = function(p, cb)
      os.remove(p)
      if cb then cb({ ok = true }) end
    end,
  }
  local choice_fired = false
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm_choice"] = function(_question, choices, on_choice)
    choice_fired = true
    on_choice(choices[1])
  end
  local confirmed_question
  ---@diagnostic disable-next-line: duplicate-set-field
  package.loaded["filetree.util.confirm"] = function(opts)
    confirmed_question = opts.question
    opts.on_choice(true)
  end
  package.loaded["filetree.features.fileops.trash"] = nil -- reload with stubs

  local cur_node = { path = victim, type = "file" }
  local stub = setmetatable({
    name = "units-stub-asset-gate-off",
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
    adapter = "units-stub-asset-gate-off",
    -- No `refs.outgoing_assets` key at all -> DEFAULTS' `enabled = false`.
    features = { trash = { enabled = true, confirm = true } },
  })

  ft.feature("trash").delete_current()
  vim.wait(5000, function()
    return vim.fn.filereadable(victim) == 0
  end, 20)

  check(
    "trash+assets gate off: the plain y/N popup was used, not the chooser",
    confirmed_question ~= nil
  )
  check("trash+assets gate off: the chooser never fired", not choice_fired)
  eq("trash+assets gate off: victim file removed", vim.fn.filereadable(victim), 0)
  eq(
    "trash+assets gate off: the otherwise-qualifying asset was left untouched",
    vim.fn.filereadable(asset),
    1
  )

  package.loaded["filetree.features.fileops.trash.platform"] = nil
  package.loaded["filetree.util.confirm_choice"] = nil
  package.loaded["filetree.util.confirm"] = nil
  package.loaded["filetree.features.fileops.trash"] = nil
end

-- ── Report ────────────────────────────────────────────────────────────────────
print(("\nfiletree.nvim units (1/3): %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
