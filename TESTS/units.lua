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

  -- Without nvzone/menu on rtp: ui.contextmenu falls back to its own
  -- kit renderer (no third-party dependency), so a click must not just avoid
  -- erroring -- it must actually open something. This is the regression
  -- this block exists for: the feature used to require("menu") directly and
  -- only ever degrade to a notify when nvzone/menu wasn't installed, which
  -- meant right-click opened NOTHING at all on a setup that (deliberately)
  -- doesn't have nvzone/menu.
  package.loaded["menu"] = nil
  local kit_menu = require("ui.kit.menu")
  kit_menu.close() -- in case an earlier test left one open
  local ok_no_menu = click_here(km["<RightMouse>"].callback)
  check("context_menu: click without nvzone/menu installed does not error", ok_no_menu)
  check("context_menu: falls back to the kit renderer and actually opens it", kit_menu.is_open())
  kit_menu.close()

  -- With a stubbed nvzone/menu: ui.contextmenu must prefer it (its
  -- documented "auto" default) and call menu.open(items, {mouse=true}) with
  -- the SAME entries filetree.integrations.menu.items() builds (that
  -- module's own content is covered by TESTS/menu.lua; this only checks the
  -- wiring calls through correctly).
  local captured
  package.loaded["menu"] = {
    open = function(items, opts)
      captured = { items = items, opts = opts }
    end,
  }
  local ok_menu = click_here(km["<RightMouse>"].callback)
  check("context_menu: click with nvzone/menu present does not error", ok_menu)
  check("context_menu: calls menu.open()", captured ~= nil)
  if captured then
    check("context_menu: opens with mouse=true", captured.opts.mouse == true)
    check("context_menu: passes a non-empty item list", #captured.items > 0)
  end
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
print(("\nfiletree.nvim units: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
