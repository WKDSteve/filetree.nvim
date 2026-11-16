---@diagnostic disable: missing-fields
-- Test doubles here implement only what the unit under test calls -- a full
-- FiletreeAdapter or FiletreeRef would be noise, not coverage.
-- run.lua — regression test for the reference engine (lua/filetree/refs) and
-- the features that drive it.
--
-- For each language under fixtures/<lang>/ it copies the fixture tree to a
-- scratch dir, renames (or moves) the "hub" file through the real feature —
-- smart_rename / move, with a stubbed adapter and a stubbed kit.input, so no
-- tree plugin, no LSP server and no floating window are involved — and then
-- asserts that every referencing file was rewritten, and that a
-- similar-but-different name was NOT touched (negative control, guards against
-- loose matching).
--
-- The engine runs in `auto` mode here: the chooser (Update all / Select… /
-- Show diff / Leave as-is) is a UI concern covered in TESTS/units.lua, and what
-- this suite is about is what actually lands on disk.
--
-- Usage (from the filetree.nvim repo root):
--   nvim --clean --headless -u NONE -l TESTS/refs/run.lua
--
-- Exit 0 = all passed, 1 = a check failed.
--
-- To add another language: add a fixtures/<lang>/ tree with a project marker
-- file (see project_root's marker list — .luarc.json, pyproject.toml,
-- package.json, Cargo.toml, go.mod, ... all work) and a LANGS entry below
-- pointing at the hub file + the files that reference it. A language the
-- engine has no provider for yet needs one first (lua/filetree/refs/providers).

-- ── Locate the repo root relative to this file, put it on rtp ────────────────
-- `---@diagnostic disable-next-line: duplicate-set-field` appears throughout
-- this file. Every one of them sits on a test double: a stdlib function, a
-- `package.loaded` entry or a platform probe is replaced for the length of one
-- case and put back right after it. Replacing a field LuaLS already knows is
-- exactly what the rule is for, and exactly what a double has to do -- so the
-- suppression is per line rather than per file, and each one marks a swap that
-- is undone a few lines further down.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(root)

-- lib.nvim resolution: $LIB_NVIM_PATH -> sibling checkout -> lazy.nvim's
-- managed copy (see lib.nvim/templates/resolve_lib_nvim.lua for the
-- canonical copy of this function and the other caller patterns).
local function add_lib_nvim()
  local candidates = {}
  -- $FILETREE_LIB_NVIM is the name TESTS/MANUAL.md documents and the other four
  -- suites read; $LIB_NVIM_PATH is lib.nvim's own canonical one. Accept both, so
  -- exporting either runs every suite in TESTS/.
  if vim.env.FILETREE_LIB_NVIM then candidates[#candidates + 1] = vim.env.FILETREE_LIB_NVIM end
  if vim.env.LIB_NVIM_PATH then candidates[#candidates + 1] = vim.env.LIB_NVIM_PATH end
  candidates[#candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/lib.nvim"
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"

  for _, path in ipairs(candidates) do
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. "/lua/lib") == 1 then
      vim.opt.rtp:prepend(norm)
      package.path = table.concat({
        norm .. "/lua/?.lua",
        norm .. "/lua/?/init.lua",
        package.path,
      }, ";")
      return norm
    end
  end
  return nil
end

-- ui.nvim resolution, same candidate order as add_lib_nvim() above:
-- ui.kit (kit.input/kit.confirm, stubbed below) moved out of
-- lib.nvim.ui.kit in the 2026-09 migration, so this suite needs ui.nvim
-- findable too -- unlike lib.nvim above, require("ui.kit") below is not
-- pcall'd, so a missing ui.nvim would crash this suite outright rather
-- than degrade.
local function add_ui_nvim()
  local candidates = {}
  if vim.env.FILETREE_UI_NVIM then candidates[#candidates + 1] = vim.env.FILETREE_UI_NVIM end
  if vim.env.UI_NVIM_PATH then candidates[#candidates + 1] = vim.env.UI_NVIM_PATH end
  candidates[#candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/ui.nvim"
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/ui.nvim"

  for _, path in ipairs(candidates) do
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. "/lua/ui") == 1 then
      vim.opt.rtp:prepend(norm)
      package.path = table.concat({
        norm .. "/lua/?.lua",
        norm .. "/lua/?/init.lua",
        package.path,
      }, ";")
      return norm
    end
  end
  return nil
end

add_lib_nvim()
add_ui_nvim()

local fixtures_root = vim.fn.fnamemodify(this, ":p:h") .. "/fixtures"
--- Scratch tree for the fixtures, spelled canonically.
---
--- The canonicalization is not cosmetic: on macOS `/tmp` is a symlink to
--- `/private/tmp`, so a path built from the literal `/tmp` and a path that has
--- been through `:cd`, a buffer name or `fs_realpath` are two spellings of one
--- directory. Checks that compare a fixture path against one the editor
--- produced then fail while the code under test is correct. Resolving once,
--- here, keeps every path in this suite in the same spelling.
---
--- One directory per run (pid + hrtime): a run that `scripts/test.sh` gave up
--- on but that is still alive must not rewrite the fixtures of the next run.
local uv = vim.uv or vim.loop
local scratch_root = ("%s/filetree-refs-test-%d-%d"):format(
  vim.fn.has("win32") == 1 and vim.env.TEMP or "/tmp",
  vim.fn.getpid(),
  uv.hrtime()
)
do
  vim.fn.mkdir(scratch_root, "p")
  local real = uv.fs_realpath(scratch_root)
  if real then scratch_root = (real:gsub("\\", "/")) end
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

-- ── Waiting for the asynchronous scan ────────────────────────────────────────
-- Every block below starts an asynchronous reference scan and waits for its
-- "done" signal. The limit is deliberately generous: on a loaded machine the
-- scan (plaintext is the heaviest provider) can take several times as long as
-- usual, and a fixed few seconds used to end the wait silently, so the content
-- checks that followed failed while the code under test was fine.
--
--   FILETREE_REFS_TEST_WAIT_MS        the limit per wait (default 30000)
--   FILETREE_REFS_TEST_SCAN_DELAY_MS  test hook: hold back every scan result
--                                     this long (proves the waits are not
--                                     racing the scan; see slow_scan_spec)
--   FILETREE_REFS_TEST_ONLY           run only the LANGS entry of this name
--
-- A wait that runs out is a FAIL of its own, named TIMEOUT, and ends the run:
-- the checks after it would only report the half-finished rename as wrong
-- content, and the scan still running in the background would race the next
-- block.
--
-- The default stays well below the 60 s that testing.nvim (scripts/test.sh,
-- CI) gives this whole file (`timeouts.file_ms`) before it kills it: a limit
-- per wait as long as the file's own would let the runner's kill win, and
-- the TIMEOUT line naming the stuck wait would never be printed. The whole
-- file normally takes about 12 s. `.testing.lua` passes FILETREE_REFS_TEST_*
-- through to the child, so raising the limit works through the runner too
-- (together with `--file-timeout`).
local WAIT_MS = tonumber(vim.env.FILETREE_REFS_TEST_WAIT_MS) or 30000
local SCAN_DELAY_MS = tonumber(vim.env.FILETREE_REFS_TEST_SCAN_DELAY_MS) or 0
local ONLY = vim.env.FILETREE_REFS_TEST_ONLY
print(("refs: waiting up to %d ms per scan"):format(WAIT_MS))

local function finish()
  print(("\nrefs: %d passed, %d failed"):format(passed, failed))
  if failed > 0 then
    print("  scratch dir kept for inspection: " .. scratch_root)
    vim.cmd("cq")
  else
    vim.fn.delete(scratch_root, "rf")
    vim.cmd("qa!")
  end
end

---Wait until `cond()` holds; a timeout is reported as TIMEOUT and ends the run.
---@param what string  the condition, as written (names the wait in the report)
---@param cond fun(): boolean
local function await(what, cond)
  if vim.wait(WAIT_MS, cond, 10) then return end
  local line = debug.getinfo(2, "l").currentline
  check(
    ("TIMEOUT waiting for `%s` (run.lua:%d)"):format(what, line),
    false,
    ("no result after %d ms; raise FILETREE_REFS_TEST_WAIT_MS on a slow machine"):format(WAIT_MS)
      .. " (under scripts/test.sh also --file-timeout)"
  )
  finish()
end

-- ── Portable recursive directory copy (binary-safe, no shell dependency) ─────
local function copy_dir(src, dst)
  vim.fn.mkdir(dst, "p")
  for _, name in ipairs(vim.fn.readdir(src)) do
    local s = src .. "/" .. name
    local d = dst .. "/" .. name
    if vim.fn.isdirectory(s) == 1 then
      copy_dir(s, d)
    else
      vim.fn.writefile(vim.fn.readfile(s, "b"), d, "b")
    end
  end
end

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, "\n") or nil
end

local function count_sub(s, sub)
  local n, i = 0, 1
  while true do
    local f = s:find(sub, i, true)
    if not f then return n end
    n = n + 1
    i = f + #sub
  end
end

---Whether `old` was fully replaced by `new` in `content`. Plain substring
---absence isn't enough when `new` textually extends `old` (e.g. python's bare
---"import pkg.util.shared" -> "import pkg.util.shared_utils" has no delimiter
---between them) — every correctly-updated occurrence of `new` would then
---still contain `old` as its own prefix. In that case compare counts instead:
---equal counts means every `old` match is accounted for by a `new` match,
---i.e. nothing was left unreplaced.
---@param content string
---@param old string
---@param new string
---@return boolean
local function old_fully_replaced(content, old, new)
  if new:sub(1, #old) == old then return count_sub(content, old) == count_sub(content, new) end
  return content:find(old, 1, true) == nil
end

---Assert every spec's `old` string really is in its fixture, BEFORE the
---mutation runs.
---
---This exists because of one specific failure: a spec expected
---`require "proj.util.shared"` in the deepest lua fixture while the fixture
---used `require("proj.util.shared")`. The "updated" check then looked for a
---string that could never appear, and its "old reference gone" partner passed
---*vacuously* -- the unparenthesised old string was absent too. What that
---looks like from the outside is "the engine updated b.lua but skipped
---c.lua one level deeper", which is how it got filed as an apply-layer defect
---and stayed on the roadmap for three weeks after the fixture was fixed
---(41395fc).
---
---Checking up front turns spec/fixture drift into one honest failure that
---names the real cause, instead of a half-signal that looks like a scanner
---bug.
---@param label string
---@param work string   Scratch copy of the fixture tree.
---@param checks {file: string, old: string, new: string}[]
local function check_fixtures_match_spec(label, work, checks)
  local missing = {}
  for _, c in ipairs(checks) do
    local content = read(work .. "/" .. c.file)
    if content == nil then
      missing[#missing + 1] = string.format("%s is not in the fixture at all", c.file)
    elseif content:find(c.old, 1, true) == nil then
      missing[#missing + 1] = string.format("%s does not contain %q", c.file, c.old)
    end
  end
  check(
    label .. ": every fixture holds what its spec expects to be rewritten",
    #missing == 0,
    table.concat(missing, "; ")
  )
end

-- ── UI stubs ─────────────────────────────────────────────────────────────────
-- kit.input opens a real floating prompt in insert mode, which headless Neovim
-- cannot drive; kit.confirm likewise. Both are replaced by scripted answers.
local kit = require("ui.kit")
local next_input, next_choice = nil, nil
---@diagnostic disable-next-line: duplicate-set-field
kit.input = function(opts)
  if next_input ~= nil and opts.on_submit then opts.on_submit(next_input) end
  return nil
end
---@diagnostic disable-next-line: duplicate-set-field
kit.confirm = function(opts)
  if opts.on_answer then opts.on_answer(next_choice) end
  -- a surface, not nil: the shared dialog takes nil for "no float opened" and asks again natively
  return true
end

-- Auto mode: apply every found reference without asking, so the assertions
-- below are about what the providers found, not about the chooser.
local refs = require("filetree.refs")
-- Test hook (FILETREE_REFS_TEST_SCAN_DELAY_MS, see `await` above): every
-- candidate search answers that much later, as on a heavily loaded machine.
if SCAN_DELAY_MS > 0 then
  local scan = require("filetree.refs.scan")
  local real_candidates = scan.candidates
  ---@diagnostic disable-next-line: duplicate-set-field
  scan.candidates = function(root_dir, needles, exts, cfg, cb)
    return real_candidates(root_dir, needles, exts, cfg, function(...)
      local args = { n = select("#", ...), ... }
      vim.defer_fn(function()
        cb(unpack(args, 1, args.n))
      end, SCAN_DELAY_MS)
    end)
  end
end
-- The undo stack itself: several blocks below assert on tokens directly.
local apply = require("filetree.refs.apply")

-- The config every block below starts from. `run_plaintext_comment_check`
-- re-applies a variant of it and this restores the baseline afterwards.
local BASE_REFS_CFG = {
  on_rename = "auto",
  on_move = "auto",
  on_delete = "auto",
  providers = { markdown = true, lua = true, python = true, ts_js = true },
  wiki_links = false,
  -- The experimental plaintext provider is off by default; the "plaintext"
  -- LANGS entry and the comment-toggle check below need it on.
  experimental = { plaintext = { enabled = true, comments = true } },
  -- ripgrep's own kill timer (default 3 s) is the second fixed clock a loaded
  -- machine can outrun: a killed search reads as "no references" and the
  -- rename lands without its rewrites. Give it the same generous limit.
  scan = { timeout_ms = WAIT_MS },
}
refs.setup(vim.deepcopy(BASE_REFS_CFG))

-- ── Language specs ────────────────────────────────────────────────────────────
-- checks[i].old == checks[i].new marks a negative control: the file must
-- still contain `old` unchanged (proves the rename didn't over-match).

---@class LangSpec
---@field name     string
---@field hub      string  Path (relative to the fixture root) of the file to rename.
---@field new_name string  New basename for the hub file.
---@field checks   {file: string, old: string, new: string}[]

---@type LangSpec[]
local LANGS = {
  {
    name = "lua",
    hub = "lua/proj/util/shared.lua",
    new_name = "shared_utils.lua",
    checks = {
      {
        file = "lua/proj/a.lua",
        old = 'require("proj.util.shared")',
        new = 'require("proj.util.shared_utils")',
      },
      {
        file = "lua/proj/nested/b.lua",
        old = 'require("proj.util.shared")',
        new = 'require("proj.util.shared_utils")',
      },
      {
        file = "lua/proj/nested/deep/c.lua",
        old = 'require "proj.util.shared"',
        new = 'require "proj.util.shared_utils"',
      },
      {
        file = "lua/proj/other/unrelated.lua",
        old = 'require("proj.util.shared_other")',
        new = 'require("proj.util.shared_other")',
      },
    },
  },
  {
    name = "python",
    hub = "pkg/util/shared.py",
    new_name = "shared_utils.py",
    checks = {
      {
        file = "pkg/a.py",
        old = "from pkg.util.shared import greet",
        new = "from pkg.util.shared_utils import greet",
      },
      {
        file = "pkg/nested/b.py",
        old = "import pkg.util.shared",
        new = "import pkg.util.shared_utils",
      },
      {
        file = "pkg/other/unrelated.py",
        old = "from pkg.util.shared_other import greet",
        new = "from pkg.util.shared_other import greet",
      },
    },
  },
  {
    name = "ts",
    hub = "src/util/shared.ts",
    new_name = "shared_utils.ts",
    checks = {
      {
        file = "src/a.ts",
        old = 'from "./util/shared"',
        new = 'from "./util/shared_utils"',
      },
      {
        file = "src/nested/b.ts",
        old = 'from "../util/shared"',
        new = 'from "../util/shared_utils"',
      },
      {
        file = "src/nested/deep/c.tsx",
        old = 'from "../../util/shared"',
        new = 'from "../../util/shared_utils"',
      },
      {
        file = "src/other/d.js",
        old = 'import("../util/shared")',
        new = 'import("../util/shared_utils")',
      },
      {
        file = "src/other/unrelated.ts",
        old = 'from "../util/shared_other"',
        new = 'from "../util/shared_other"',
      },
    },
  },
  {
    -- Experimental plaintext provider: bare paths in running prose, no link
    -- syntax around them. Two spellings (relative + project-root) point at the
    -- same moved file from two directories; a same-prefix sibling
    -- (Tester_helper.md) and an unrelated doc are the negative controls.
    name = "plaintext",
    hub = "notes/Tester.md",
    new_name = "Renamed.md",
    checks = {
      {
        file = "docs/index.md",
        old = "../notes/Tester.md",
        new = "../notes/Renamed.md",
      },
      {
        file = "docs/index.md",
        old = "/notes/Tester.md",
        new = "/notes/Renamed.md",
      },
      {
        file = "docs/sub/deep.md",
        old = "../../notes/Tester.md",
        new = "../../notes/Renamed.md",
      },
      {
        -- a bare filename with no path prefix, resolved against its own
        -- directory (notes/) — the hub lives there, so this points at it
        file = "notes/README.md",
        old = "in Tester.md",
        new = "in Renamed.md",
      },
      {
        file = "docs/index.md",
        old = "../notes/Tester_helper.md",
        new = "../notes/Tester_helper.md",
      },
      {
        file = "docs/other.md",
        old = "../notes/Tester_helper.md",
        new = "../notes/Tester_helper.md",
      },
    },
  },
  {
    name = "markdown",
    hub = "docs/guide.md",
    new_name = "manual.md",
    checks = {
      -- every link form the provider claims to cover, all pointing at the
      -- same moved file from two different directories
      {
        file = "README.md",
        old = "[the guide](./docs/guide.md)",
        new = "[the guide](./docs/manual.md)",
      },
      {
        file = "README.md",
        old = '<a href="./docs/guide.md">',
        new = '<a href="./docs/manual.md">',
      },
      {
        file = "README.md",
        old = "[guide-ref]: ./docs/guide.md",
        new = "[guide-ref]: ./docs/manual.md",
      },
      { file = "docs/notes.md", old = "[guide](guide.md)", new = "[guide](manual.md)" },
      -- negative controls: an external URL that merely contains the same
      -- path, and a same-named file in a different directory
      {
        file = "README.md",
        old = "https://example.com/docs/guide.md",
        new = "https://example.com/docs/guide.md",
      },
      {
        file = "README.md",
        old = "[other](./docs/guides/guide.md)",
        new = "[other](./docs/guides/guide.md)",
      },
    },
  },
}

-- ── Run one language ──────────────────────────────────────────────────────────
local function run_lang(lang)
  print("\n== " .. lang.name .. " ==")

  local work = scratch_root .. "/" .. lang.name
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/" .. lang.name, work)

  check_fixtures_match_spec(lang.name, work, lang.checks)

  local hub_old = work .. "/" .. lang.hub
  local hub_dir = vim.fn.fnamemodify(hub_old, ":h")
  local hub_new = hub_dir .. "/" .. lang.new_name

  local smart_rename = require("filetree.features.fileops.smart_rename")
  -- The reference scan and the rename are asynchronous; adapter.refresh() is
  -- the last thing do_rename calls before its final notify, so it is the
  -- "fully done" signal (filereadable(hub_new) flips earlier).
  local done = false
  local stub_adapter = {
    get_current_node = function()
      return { path = hub_old, type = "file" }
    end,
    refresh = function()
      done = true
      return true
    end,
  }
  smart_rename.setup({ enabled = true, use_safety = false, dry_run = false }, stub_adapter)

  next_input = lang.new_name
  smart_rename.rename_current()
  await("done", function()
    return done
  end)

  check(lang.name .. ": hub file renamed on disk", vim.fn.filereadable(hub_new) == 1)
  check(lang.name .. ": old hub path gone", vim.fn.filereadable(hub_old) == 0)

  for _, c in ipairs(lang.checks) do
    local content = read(work .. "/" .. c.file)
    if c.old == c.new then
      check(
        ("%s: %s keeps %s (negative control)"):format(lang.name, c.file, c.old),
        content ~= nil and content:find(c.old, 1, true) ~= nil
      )
    else
      check(
        ("%s: %s updated"):format(lang.name, c.file),
        content ~= nil and content:find(c.new, 1, true) ~= nil,
        "missing " .. c.new
      )
      check(
        ("%s: %s old reference gone"):format(lang.name, c.file),
        content ~= nil and old_fully_replaced(content, c.old, c.new),
        "still contains " .. c.old
      )
    end
  end
end

-- ── Bonus: verify the open-buffer branch (not just on-disk files) ────────────
-- refs.apply patches loaded buffers via nvim_buf_set_lines instead of going
-- through disk I/O; exercise that path once, for Lua.
local function run_lua_buffer_check()
  print("\n== lua (open buffer) ==")

  local work = scratch_root .. "/lua_buffer"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/lua", work)

  local hub_old = work .. "/lua/proj/util/shared.lua"
  local ref_path = work .. "/lua/proj/nested/b.lua"

  vim.cmd("edit " .. vim.fn.fnameescape(ref_path))
  local bufnr = vim.fn.bufnr(ref_path)

  local done = false
  local smart_rename = require("filetree.features.fileops.smart_rename")
  smart_rename.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = hub_old, type = "file" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })

  next_input = "shared_utils.lua"
  smart_rename.rename_current()
  await("done", function()
    return done
  end)

  local buf_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  check(
    "lua buffer: open buffer patched in-memory",
    buf_content:find('require("proj.util.shared_utils")', 1, true) ~= nil,
    "buffer content: " .. buf_content
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── Regression: directory rename cascades to nested submodule requires ──────
-- Renaming a directory ("proj.util" -> "proj.utilities") must update
-- require("proj.util.shared") -> require("proj.utilities.shared") in every
-- referencing file, not just an exact require("proj.util") match (which
-- doesn't even occur here — nothing requires the directory itself).
local function run_lua_directory_cascade_check()
  print("\n== lua (directory rename, submodule cascade) ==")

  local work = scratch_root .. "/lua_dir_cascade"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/lua", work)

  local old_dir = work .. "/lua/proj/util"
  local new_dir = work .. "/lua/proj/utilities"

  local cascade_checks = {
    {
      file = "lua/proj/a.lua",
      old = 'require("proj.util.shared")',
      new = 'require("proj.utilities.shared")',
    },
    {
      file = "lua/proj/nested/b.lua",
      old = 'require("proj.util.shared")',
      new = 'require("proj.utilities.shared")',
    },
    {
      file = "lua/proj/nested/deep/c.lua",
      old = 'require "proj.util.shared"',
      new = 'require "proj.utilities.shared"',
    },
    -- "proj.util.shared_other" is itself a submodule of "proj.util" (the
    -- directory being renamed) even though its basename looks like the
    -- file-rename negative control above — renaming the whole directory
    -- must cascade to it too, unlike renaming just shared.lua.
    {
      file = "lua/proj/other/unrelated.lua",
      old = 'require("proj.util.shared_other")',
      new = 'require("proj.utilities.shared_other")',
    },
  }
  check_fixtures_match_spec("lua dir cascade", work, cascade_checks)

  local done = false
  local smart_rename = require("filetree.features.fileops.smart_rename")
  smart_rename.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = old_dir, type = "directory" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })

  next_input = "utilities"
  smart_rename.rename_current()
  await("done", function()
    return done
  end)

  check("lua dir cascade: directory renamed on disk", vim.fn.isdirectory(new_dir) == 1)
  check("lua dir cascade: old directory gone", vim.fn.isdirectory(old_dir) == 0)

  for _, c in ipairs(cascade_checks) do
    local content = read(work .. "/" .. c.file)
    check(
      ("lua dir cascade: %s updated"):format(c.file),
      content ~= nil and content:find(c.new, 1, true) ~= nil,
      "missing " .. c.new
    )
    check(
      ("lua dir cascade: %s old reference gone"):format(c.file),
      content ~= nil and old_fully_replaced(content, c.old, c.new),
      "still contains " .. c.old
    )
  end
end

-- ── The `move` feature (M): move into a directory, then undo the rewrite ────
local function run_move_feature_check()
  print("\n== move (M) + refs undo ==")

  local work = scratch_root .. "/move"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/markdown", work)

  -- README.md links to ./docs/guide.md; moving docs/notes.md up to the root
  -- must rewrite the link that points at it from README.md.
  local src = work .. "/docs/notes.md"
  local dst = work .. "/notes.md"
  vim.fn.writefile({ "Notes live at [notes](./docs/notes.md)." }, work .. "/index.md")

  local move = require("filetree.features.fileops.move")
  local done = false
  move.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = src, type = "file" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })

  -- ":Filetree move <dest>" path — no prompt involved, so nothing to stub.
  move.move(work)
  await("done", function()
    return done
  end)

  check("move: file moved into the destination directory", vim.fn.filereadable(dst) == 1)
  check("move: source is gone", vim.fn.filereadable(src) == 0)

  local index = read(work .. "/index.md")
  check(
    "move: reference rewritten to the new location",
    index ~= nil and index:find("[notes](./notes.md)", 1, true) ~= nil,
    index
  )

  -- …and the undo token puts the reference back, byte for byte.
  refs.undo()
  local reverted = read(work .. "/index.md")
  check(
    "move: refs undo restores the previous line",
    reverted ~= nil and reverted:find("[notes](./docs/notes.md)", 1, true) ~= nil,
    reverted
  )
end

-- ── plaintext provider: code-comment scanning + the `comments` toggle ──────
-- The prose case is covered by the LANGS entry above; this exercises the
-- source-file path: a bare path in a `--` comment IS rewritten while the same
-- path in a real string literal on a code line is NOT, and setting
-- `comments = false` turns the comment scanning off too.
local function run_plaintext_comment_check()
  local function rename_hub(work, plaintext_cfg)
    local cfg = vim.deepcopy(BASE_REFS_CFG)
    cfg.experimental = { plaintext = plaintext_cfg }
    refs.setup(cfg)

    local hub_old = work .. "/notes/Tester.md"
    local done = false
    local smart_rename = require("filetree.features.fileops.smart_rename")
    smart_rename.setup({ enabled = true, use_safety = false, dry_run = false }, {
      get_current_node = function()
        return { path = hub_old, type = "file" }
      end,
      refresh = function()
        done = true
        return true
      end,
    })
    next_input = "Renamed.md"
    smart_rename.rename_current()
    await("done", function()
      return done
    end)
  end

  print("\n== plaintext (comments = true) ==")
  local work = scratch_root .. "/plaintext_comments"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/plaintext", work)
  rename_hub(work, { enabled = true, comments = true })

  local app = read(work .. "/src/app.lua")
  check(
    "plaintext comments=true: comment line rewritten",
    app ~= nil and app:find("-- Doc reference: ../notes/Renamed.md", 1, true) ~= nil,
    app
  )
  check(
    "plaintext comments=true: code string literal left untouched",
    app ~= nil and app:find('local doc = "../notes/Tester.md"', 1, true) ~= nil,
    app
  )

  print("\n== plaintext (comments = false) ==")
  local work2 = scratch_root .. "/plaintext_nocomments"
  vim.fn.delete(work2, "rf")
  copy_dir(fixtures_root .. "/plaintext", work2)
  rename_hub(work2, { enabled = true, comments = false })

  local app2 = read(work2 .. "/src/app.lua")
  check(
    "plaintext comments=false: comment line NOT rewritten",
    app2 ~= nil and app2:find("-- Doc reference: ../notes/Tester.md", 1, true) ~= nil,
    app2
  )
  -- Prose in the same tree is still rewritten regardless of the toggle.
  local idx2 = read(work2 .. "/docs/index.md")
  check(
    "plaintext comments=false: prose still rewritten",
    idx2 ~= nil and idx2:find("../notes/Renamed.md", 1, true) ~= nil,
    idx2
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG))
end

-- ── refs.outgoing(): what a file links out to (not what links to it) ────────
-- Step 1 of the cascade-delete-assets feature — no classifier involved, so this
-- only checks that every path-like link is found and resolved, external
-- links and pure anchors are not, and a file with nothing to link out to
-- comes back empty.
local function run_outgoing_scan_check()
  print("\n== refs.outgoing ==")

  local work = scratch_root .. "/outgoing"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/markdown", work)

  local readme = work .. "/README.md"
  local found, done = nil, false
  refs.outgoing(readme, nil, function(links)
    found = links
    done = true
  end)
  await("done", function()
    return done
  end)

  ---One link matching both `target` (as written) and `kind` — several of
  ---README.md's links share a target string ("./docs/guide.md" appears as an
  ---inline link, an html href, and a reference-definition), so `kind` is
  ---needed to tell them apart rather than just counting hits on the target.
  local function by(links, target, kind)
    for _, l in ipairs(links) do
      if l.target == target and l.kind == kind then return l end
    end
    return nil
  end

  local function normalized(p)
    return (p or ""):gsub("\\", "/")
  end

  check("outgoing: scan returned synchronously", done)
  check(
    "outgoing: found the inline link to docs/guide.md",
    found and by(found, "./docs/guide.md", "inline") ~= nil
  )
  check(
    "outgoing: found the bare-relative link to docs/notes.md",
    found and by(found, "docs/notes.md", "inline") ~= nil
  )
  check(
    "outgoing: found the inline image link to img/diagram.png",
    found and by(found, "./img/diagram.png", "inline") ~= nil
  )
  check(
    "outgoing: found the same target again via the html href (a distinct ref, not a dedup)",
    found and by(found, "./docs/guide.md", "html") ~= nil
  )
  check(
    "outgoing: found the same target a third time via the reference-definition",
    found and by(found, "./docs/guide.md", "refdef") ~= nil
  )
  check(
    "outgoing: same-named file in a different folder resolves to its own path, not docs/guide.md",
    found
      and (function()
        local l = by(found, "./docs/guides/guide.md", "inline")
        return l ~= nil and normalized(l.resolved):find("docs/guides/guide.md", 1, true) ~= nil
      end)()
  )
  check("outgoing: the diagram link resolves to a file that exists", found and (function()
    local l = by(found, "./img/diagram.png", "inline")
    return l ~= nil and l.exists == true
  end)())
  check("outgoing: the external URL is not returned at all", found and (function()
    for _, l in ipairs(found) do
      if l.target:find("example.com", 1, true) then return false end
    end
    return true
  end)())

  -- guide.md itself links nowhere — must come back empty, not error.
  local guide_links, guide_done = nil, false
  refs.outgoing(work .. "/docs/guide.md", nil, function(links)
    guide_links = links
    guide_done = true
  end)
  await("guide_done", function()
    return guide_done
  end)
  check(
    "outgoing: a file with no links out returns an empty list",
    guide_done and #guide_links == 0
  )

  -- A non-markdown file must not be walked at all (extension gate).
  local nonexistent_ext_done, nonexistent_ext_links = false, nil
  refs.outgoing(work .. "/pyproject.toml", nil, function(links)
    nonexistent_ext_links = links
    nonexistent_ext_done = true
  end)
  await("nonexistent_ext_done", function()
    return nonexistent_ext_done
  end)
  check(
    "outgoing: a non-markdown file is skipped by the extension gate",
    nonexistent_ext_done and #nonexistent_ext_links == 0
  )
end

-- ── refs.outgoing_assets(): the cascade-delete-assets classifier ────────────
-- Step 2 of the cascade-delete-assets feature — a small, purpose-built tree
-- (not the shared markdown fixture) isolates the three criteria: under a
-- configured root, an allowed extension, and not still referenced by some
-- OTHER surviving file. Each case changes exactly one criterion so a
-- passing test can't be hiding a coincidence.
local function run_outgoing_assets_check()
  print("\n== refs.outgoing_assets ==")

  local work = scratch_root .. "/outgoing_assets"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/assets", "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "x" }, work .. "/assets/shot.png")
  vim.fn.writefile({ "x" }, work .. "/assets/shared.png")
  vim.fn.writefile({ "x" }, work .. "/toplevel.png")
  -- Lives INSIDE assets/ (so the root check alone would pass) but has a
  -- disallowed extension -- isolates the extension criterion from the root
  -- one, unlike toplevel.png below (right extension, wrong location).
  vim.fn.writefile({ "-- a lua file, not an asset" }, work .. "/assets/code.lua")
  vim.fn.writefile({
    "Shot: ![shot](assets/shot.png)",
    "Shared: ![shared](assets/shared.png)",
    "Code: [code](assets/code.lua)",
    "Top-level image outside assets/: ![top](toplevel.png)",
    "Missing: ![gone](assets/gone.png)",
    -- The same files linked a second time (one through a different spelling of the path):
    -- one candidate per file, not one per link.
    "Shot again: ![shot2](assets/shot.png)",
    "Shot via ./: ![shot3](./assets/shot.png)",
    "Shared again: ![shared2](assets/shared.png)",
  }, work .. "/doc.md")
  -- Also links assets/shared.png -- the one asset with a surviving
  -- second referrer once doc.md (the file "being deleted") is excluded.
  vim.fn.writefile({ "Also shared: ![shared](assets/shared.png)" }, work .. "/other.md")

  local doc = work .. "/doc.md"
  local found, done = nil, false
  -- `mode = "auto"` overrides the (now off-by-default) enabled gate for
  -- this call -- this suite tests the classifier itself, not the gate
  -- (that's `run_outgoing_assets_gate_check` below).
  refs.outgoing_assets(doc, { root = work, mode = "auto" }, function(candidates)
    found = candidates
    done = true
  end)
  await("done", function()
    return done
  end)

  local function by(candidates, target)
    for _, c in ipairs(candidates) do
      if c.target == target then return c end
    end
    return nil
  end

  check("outgoing_assets: classification returned", done)
  check(
    "outgoing_assets: exactly 4 candidates (the dangling link is excluded, a file linked twice is one)",
    found and #found == 4
  )
  do
    local seen_paths, distinct = {}, true
    for _, c in ipairs(found or {}) do
      local k = c.resolved:gsub("\\", "/"):lower()
      if seen_paths[k] then distinct = false end
      seen_paths[k] = true
    end
    check("outgoing_assets: no file appears twice", distinct)
    local deletable = refs.assets.split(found or {})
    check(
      "outgoing_assets: the deletable list names each file once (shot.png)",
      #deletable == 1
        and deletable[1].resolved:gsub("\\", "/"):find("assets/shot.png", 1, true) ~= nil
    )
  end

  local shot = found and by(found, "assets/shot.png")
  check(
    "outgoing_assets: shot.png is an asset (under assets/, .png allowed)",
    shot and shot.is_asset == true
  )
  check(
    "outgoing_assets: shot.png has no other referrer -- safe to delete",
    shot and shot.still_referenced == false
  )

  local shared = found and by(found, "assets/shared.png")
  check("outgoing_assets: shared.png is an asset too", shared and shared.is_asset == true)
  check(
    "outgoing_assets: shared.png IS still referenced by other.md -- must not be offered",
    shared and shared.still_referenced == true and #shared.referenced_by == 1
  )
  check(
    "outgoing_assets: the referrer is other.md, not doc.md itself",
    shared
      and shared.referenced_by[1]
      and shared.referenced_by[1]:gsub("\\", "/"):find("other.md", 1, true) ~= nil
  )

  local code = found and by(found, "assets/code.lua")
  check(
    "outgoing_assets: assets/code.lua is NOT an asset -- right location, wrong extension",
    code and code.is_asset == false
  )

  local top = found and by(found, "toplevel.png")
  check(
    "outgoing_assets: toplevel.png is NOT an asset -- right extension, but outside assets/",
    top and top.is_asset == false
  )

  check(
    "outgoing_assets: the dangling link (assets/gone.png) is not in the result at all",
    found and by(found, "assets/gone.png") == nil
  )
end

-- ── refs.outgoing_assets(): the config gate (step 4) ─────────────────────────
-- `outgoing_assets.enabled` defaults to false -- the classifier must not run
-- at all (not even the outgoing scan underneath it) until a config turns it
-- on, and must run once one does, with no per-call override needed.
local function run_outgoing_assets_gate_check()
  print("\n== refs.outgoing_assets (config gate) ==")

  local work = scratch_root .. "/outgoing_assets_gate"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/assets", "p")
  vim.fn.writefile({ "x" }, work .. "/assets/shot.png")
  vim.fn.writefile({ "![shot](assets/shot.png)" }, work .. "/doc.md")

  -- Default config (BASE_REFS_CFG has no outgoing_assets key -> DEFAULTS'
  -- `enabled = false` applies): the gate must return an empty list without
  -- being asked to via `mode`.
  refs.setup(vim.deepcopy(BASE_REFS_CFG))
  local off_result, off_done = nil, false
  refs.outgoing_assets(work .. "/doc.md", { root = work }, function(candidates)
    off_result = candidates
    off_done = true
  end)
  check(
    "outgoing_assets gate: off by default, resolves synchronously to empty",
    off_done and off_result and #off_result == 0
  )

  -- Turning it on via refs.setup (not a per-call override) must produce the
  -- same result the "auto" override produced in run_outgoing_assets_check.
  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_assets = { enabled = true, on_delete = "auto" }
  refs.setup(cfg)
  local on_result, on_done = nil, false
  refs.outgoing_assets(work .. "/doc.md", { root = work }, function(candidates)
    on_result = candidates
    on_done = true
  end)
  await("on_done", function()
    return on_done
  end)
  check(
    "outgoing_assets gate: enabled via config, no per-call override needed",
    on_done and on_result and #on_result == 1 and on_result[1].is_asset == true,
    on_result and vim.inspect(on_result) or "nil"
  )

  -- `:Filetree refs status` (refs.status()) must report the block.
  local status = table.concat(refs.status(), "\n")
  check(
    "outgoing_assets gate: refs.status() reports the block",
    status:find("outgoing_assets: enabled=true", 1, true) ~= nil,
    status
  )

  -- The experimental plaintext provider is gated by `experimental.plaintext`,
  -- not by the `providers` map: status must say "off" by default and "on"
  -- only when enabled (it used to report it on in both cases).
  local function plaintext_line()
    for _, l in ipairs(refs.status()) do
      if l:find("plaintext", 1, true) and l:find("(experimental)", 1, true) then return l end
    end
  end
  local default_cfg = vim.deepcopy(BASE_REFS_CFG)
  default_cfg.experimental = nil -- the suite's baseline switches it on
  refs.setup(default_cfg)
  local default_line = plaintext_line()
  check(
    "status: the experimental plaintext provider is off by default",
    default_line ~= nil and default_line:find("○", 1, true) ~= nil,
    tostring(default_line)
  )
  local on_cfg = vim.deepcopy(BASE_REFS_CFG)
  on_cfg.experimental = { plaintext = { enabled = true } }
  refs.setup(on_cfg)
  local on_line = plaintext_line()
  check(
    "status: ...and on once experimental.plaintext.enabled is set",
    on_line ~= nil and on_line:find("●", 1, true) ~= nil,
    tostring(on_line)
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── refs.outgoing_assets(): independent of the main on_delete switch ────────
-- `outgoing_assets` documents itself as independent of the main
-- `on_delete`/`enabled` switch above (a user may want cascade-delete-assets
-- without incoming REF! markers, or vice versa). The safety recheck inside
-- the classifier (`still_referenced`, which asks "does some OTHER file still
-- link to this asset?") used to route through `refs.scan` with no mode
-- override, so it silently inherited the MAIN `on_delete` gate instead of
-- `outgoing_assets`' own — with the main switch off, every asset came back
-- "not referenced elsewhere" regardless of truth. This isolates that one
-- combination: main `on_delete = "off"`, `outgoing_assets` on and `"auto"`.
local function run_outgoing_assets_independent_switch_check()
  print("\n== refs.outgoing_assets (independent of main on_delete) ==")

  local work = scratch_root .. "/outgoing_assets_independent"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/assets", "p")
  vim.fn.writefile({ "x" }, work .. "/assets/shared.png")
  vim.fn.writefile({ "Shared: ![shared](assets/shared.png)" }, work .. "/doc.md")
  -- The surviving second referrer -- if the safety recheck silently never
  -- runs, this file is invisible and shared.png looks like a safe orphan.
  vim.fn.writefile({ "Also shared: ![shared](assets/shared.png)" }, work .. "/other.md")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.on_delete = "off" -- the UNRELATED incoming-refs direction, switched off
  cfg.outgoing_assets = { enabled = true, on_delete = "auto" }
  refs.setup(cfg)

  local found, done = nil, false
  refs.outgoing_assets(work .. "/doc.md", { root = work }, function(candidates)
    found = candidates
    done = true
  end)
  await("done", function()
    return done
  end)

  local shared = found
  for _, c in ipairs(found or {}) do
    if c.target == "assets/shared.png" then shared = c end
  end
  check(
    "outgoing_assets independent switch: classification returned",
    done and found and #found == 1
  )
  check(
    "outgoing_assets independent switch: shared.png IS still referenced by other.md, "
      .. "even with the main on_delete switch off",
    shared and shared.is_asset == true and shared.still_referenced == true,
    shared and vim.inspect(shared) or "nil"
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: a moved file's OWN outgoing links get rewritten too ─────────
-- The mirror direction of everything above: `refs/outgoing.lua` finds what a
-- file links OUT to, and `refs/own_links.lua` (opt-in, `outgoing_links`)
-- rewrites those links after the file that CONTAINS them moved. Kept in its
-- own fixture tree (`fixtures/markdown_own_links/`) rather than reusing
-- `fixtures/markdown/`, so the directory-move/env-var cases below don't
-- perturb the LANGS table's markdown checks above.
--
-- This first check also exercises `handle_result`'s merge: Index.md's link TO
-- Research.md (an INCOMING ref) and Research.md's own link to Screenshot.png
-- (an OUTGOING/own-links edit) both land from ONE move, under the SAME
-- effective mode (both inherit `on_move = "auto"`) -- so they must apply
-- through one combined call and revert together via a single `refs.undo()`.
local function run_own_links_move_check()
  print("\n== own_links: moved file's own relative link is re-anchored ==")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  refs.setup(cfg)

  local work = scratch_root .. "/own_links_move"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/markdown_own_links", work)

  local research_before = read(work .. "/Research/Research.md")
  check(
    "own_links move: fixture holds the relative link before the move",
    research_before ~= nil and research_before:find("../assets/Screenshot.png", 1, true) ~= nil,
    research_before
  )

  local src = work .. "/Research/Research.md"
  local dst = work .. "/Research.md"

  local move = require("filetree.features.fileops.move")
  local done = false
  move.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = src, type = "file" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })
  move.move(work)
  await("done", function()
    return done
  end)

  check("own_links move: the file moved up one level", vim.fn.filereadable(dst) == 1)
  check("own_links move: the old path is gone", vim.fn.filereadable(src) == 0)

  local index = read(work .. "/Index.md")
  check(
    "own_links move: the INCOMING ref (Index.md -> Research.md) followed the move",
    index ~= nil and index:find("[research](./Research.md)", 1, true) ~= nil,
    index
  )

  local moved = read(dst)
  check(
    "own_links move: the file's OWN relative link was re-anchored (no longer climbs a level)",
    moved ~= nil and moved:find("[shot](assets/Screenshot.png)", 1, true) ~= nil,
    moved
  )
  check(
    "own_links move: the old, now-wrong '../assets/...' spelling is gone",
    moved ~= nil and moved:find("../assets/Screenshot.png", 1, true) == nil,
    moved
  )
  check(
    "own_links move: an absolute link, unrelated to this move, stayed untouched (negative control)",
    moved ~= nil and moved:find("/elsewhere/Fixed.md", 1, true) ~= nil,
    moved
  )

  -- One `refs.undo()` reverts BOTH the incoming ref and the own-links edit --
  -- proof they really did share one undo token (`handle_result`'s merged
  -- path), not two independent applies that happen to have run back to back.
  refs.undo()
  local index_reverted = read(work .. "/Index.md")
  local moved_reverted = read(dst)
  check(
    "own_links move: a single undo restores the incoming ref too",
    index_reverted ~= nil
      and index_reverted:find("[research](./Research/Research.md)", 1, true) ~= nil,
    index_reverted
  )
  check(
    "own_links move: ...AND the own-links edit, in the same undo",
    moved_reverted ~= nil and moved_reverted:find("../assets/Screenshot.png", 1, true) ~= nil,
    moved_reverted
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: a directory move cascades to every nested file ──────────────
-- `own_links.collect` expands a directory entry in `moves` into one
-- {old, new} pair per file via `util/fs.lua`'s `collect_recursive` -- this
-- isolates that expansion from the move-a-single-file case above by moving a
-- directory that changes its OWN nesting depth (Docs/A -> top-level A), so a
-- naive "only look at the moved node itself" implementation would miss both
-- the direct child and the doubly-nested descendant below.
local function run_own_links_dir_move_check()
  print("\n== own_links: directory move covers every nested file (collect_recursive) ==")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  refs.setup(cfg)

  local work = scratch_root .. "/own_links_dir_move"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/Docs/A/sub", "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "# Shared" }, work .. "/Shared.md")
  vim.fn.writefile({ "Ref: [shared](../../Shared.md)" }, work .. "/Docs/A/note.md")
  vim.fn.writefile({ "Ref: [shared](../../../Shared.md)" }, work .. "/Docs/A/sub/deep.md")

  local old_dir = work .. "/Docs/A"
  local new_dir = work .. "/A"

  local move = require("filetree.features.fileops.move")
  local done = false
  move.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = old_dir, type = "directory" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })
  move.move(work)
  await("done", function()
    return done
  end)

  check("own_links dir move: the directory relocated", vim.fn.isdirectory(new_dir) == 1)
  check("own_links dir move: the old directory is gone", vim.fn.isdirectory(old_dir) == 0)

  local note = read(new_dir .. "/note.md")
  check(
    "own_links dir move: the direct child's link lost one '..' level",
    note ~= nil and note:find("[shared](../Shared.md)", 1, true) ~= nil,
    note
  )

  local deep = read(new_dir .. "/sub/deep.md")
  check(
    "own_links dir move: the doubly-nested descendant was covered too, not just the top-level file",
    deep ~= nil and deep:find("[shared](../../Shared.md)", 1, true) ~= nil,
    deep
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: $VAR-rooted link targets ─────────────────────────────────────
-- `pathutil.resolve_candidates`'/`retarget`'s "env" style: a link written as
-- "$VAR/rest" resolves through a configured env root instead of the
-- filesystem/relative readings. Two halves: (1) `refs.outgoing()` -- used
-- independently of `own_links`, e.g. by the cascade-delete-assets classifier
-- -- resolves it correctly when the caller threads `opts.env` in, and (2)
-- once `own_links` is on and the $VAR-anchored TARGET itself moves along with
-- its referrer (both inside one renamed directory), the rewritten link is
-- re-folded back into "$VAR/..." form at the new location rather than falling
-- back to a plain filesystem path.
local function run_own_links_env_var_check()
  print("\n== own_links: $VAR-rooted link (pre-move resolve + post-move re-render) ==")

  local work = scratch_root .. "/own_links_env_var"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/Notes", "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "Asset: [asset]($TESTVAR/Notes/Asset.txt)" }, work .. "/Notes/Notes.md")
  vim.fn.writefile({ "x" }, work .. "/Notes/Asset.txt")

  local prev_testvar = vim.env.TESTVAR
  vim.env.TESTVAR = work

  -- 1. Pre-move: refs.outgoing() resolves the $VAR-rooted target on its own,
  --    independent of the own_links feature (mirrors how outgoing_assets
  --    would use it).
  local env = { names = { "TESTVAR" } }
  local found, done = nil, false
  refs.outgoing(work .. "/Notes/Notes.md", { root = work, env = env }, function(links)
    found = links
    done = true
  end)
  await("done", function()
    return done
  end)

  local function normalized(p)
    return (p or ""):gsub("\\", "/")
  end

  local link = found and found[1]
  check("own_links env var: pre-move scan found the link", link ~= nil)
  check(
    "own_links env var: it resolved through $TESTVAR to Notes/Asset.txt",
    link ~= nil and normalized(link.resolved):find("Notes/Asset.txt", 1, true) ~= nil,
    link and link.resolved
  )
  check("own_links env var: the target exists on disk", link ~= nil and link.exists == true)
  check('own_links env var: the detected style is "env"', link ~= nil and link.style == "env")

  -- 2. Rename the whole directory (Notes -> Renamed): the $VAR-rooted link's
  --    own target (Asset.txt) moves along with it, so the re-render must
  --    still read in $VAR form, at the new path -- not fall back to "fs".
  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true, env_vars = { "TESTVAR" } }
  refs.setup(cfg)

  local old_dir = work .. "/Notes"
  local new_dir = work .. "/Renamed"
  local smart_rename = require("filetree.features.fileops.smart_rename")
  local rn_done = false
  smart_rename.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = old_dir, type = "directory" }
    end,
    refresh = function()
      rn_done = true
      return true
    end,
  })
  next_input = "Renamed"
  smart_rename.rename_current()
  await("rn_done", function()
    return rn_done
  end)

  check("own_links env var: the directory was renamed on disk", vim.fn.isdirectory(new_dir) == 1)

  local notes_after = read(new_dir .. "/Notes.md")
  check(
    "own_links env var: re-rendered in $VAR form, at the new path",
    notes_after ~= nil and notes_after:find("$TESTVAR/Renamed/Asset.txt", 1, true) ~= nil,
    notes_after
  )
  check(
    "own_links env var: the old $VAR/Notes/... spelling is gone",
    notes_after ~= nil and notes_after:find("$TESTVAR/Notes/Asset.txt", 1, true) == nil,
    notes_after
  )

  vim.env.TESTVAR = prev_testvar
  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: the copy path, wired separately from the incoming-ref scan ──
-- A copy never carries an incoming-ref scan (the original stays put, nothing
-- points at it needs fixing) -- but the pasted COPY's own outgoing links can
-- still need rewriting for its new location, via the second, separately
-- wired `refs.handle_result` call in `copy_move/init.lua`'s `do_paste_impl`.
-- The critical negative control (design decision 7's own words): the
-- ORIGINAL file at its old location must never be touched by this.
local function run_own_links_copy_check()
  print("\n== own_links: pasted copy's own link rewritten, original left alone ==")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  refs.setup(cfg)

  local work = scratch_root .. "/own_links_copy"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/markdown_own_links", work)
  vim.fn.mkdir(work .. "/Copies/Sub", "p")

  local original = work .. "/Research/Research.md"
  local original_before = read(original)

  local copy_move = require("filetree.features.fileops.copy_move")
  local current, done = original, false
  copy_move.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = current, type = current == original and "file" or "directory" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })

  -- c on the file, then p two levels deeper -- so the pasted copy's relative
  -- link genuinely needs re-anchoring, not just a no-op rewrite.
  copy_move.stage_copy()
  current = work .. "/Copies/Sub"
  copy_move.paste()
  await("done", function()
    return done
  end)

  local pasted = work .. "/Copies/Sub/Research.md"
  check("own_links copy: the copy landed at the destination", vim.fn.filereadable(pasted) == 1)
  check("own_links copy: the original is still there too", vim.fn.filereadable(original) == 1)

  local pasted_content = read(pasted)
  check(
    "own_links copy: the pasted copy's relative link was re-anchored for its new depth",
    pasted_content ~= nil and pasted_content:find("../../assets/Screenshot.png", 1, true) ~= nil,
    pasted_content
  )
  check(
    "own_links copy: the pasted copy's absolute link stayed untouched",
    pasted_content ~= nil and pasted_content:find("/elsewhere/Fixed.md", 1, true) ~= nil,
    pasted_content
  )

  check(
    "own_links copy: the ORIGINAL is byte-identical to before the paste (critical negative control)",
    read(original) == original_before,
    read(original)
  )

  copy_move.teardown()
  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: a symlink is never scanned or rewritten through (security) ──
-- Regression for a confirmed HIGH-severity finding from the 2026-09-28
-- ultracode review: a symlink-to-file entry (inside a moved directory, or
-- moved on its own) used to be walked/scanned exactly like a regular file --
-- `outgoing.scan` reads THROUGH the symlink to its real target's content via
-- `vim.fn.readfile`, and `refs.apply`'s `vim.fn.writefile` would write back
-- through the same link, silently modifying whatever file the symlink
-- actually points at (which can sit entirely outside the project). Fixed:
-- `own_links.expand_files` drops any symlink entry before it ever reaches
-- `outgoing.scan`/`apply`, in both the directory-walk and single-file-move
-- branches.
local function run_own_links_symlink_safety_check()
  print("\n== own_links: a symlink is never scanned or rewritten through (security) ==")

  local work = scratch_root .. "/own_links_symlink"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/outside", "p")
  vim.fn.mkdir(work .. "/Docs", "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "External: [x](./Other.md)" }, work .. "/outside/Secret.md")
  vim.fn.writefile({ "x" }, work .. "/outside/Other.md")
  local secret_before = read(work .. "/outside/Secret.md")

  if not uv.fs_symlink(work .. "/outside/Secret.md", work .. "/Docs/Link.md") then
    print("  note no permission to create a real symlink here -- skipping own_links symlink case")
    return
  end

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  refs.setup(cfg)

  -- Move the whole directory containing the symlink much deeper: if the
  -- symlink were (wrongly) scanned/rewritten, its "own" new depth would
  -- force a materially different relative link inside Secret.md -- making
  -- any write-through immediately, unambiguously observable as a change to
  -- a file outside the moved tree entirely.
  vim.fn.mkdir(work .. "/A/B/C", "p")
  local old_dir = work .. "/Docs"
  local new_dir = work .. "/A/B/C/Docs"
  vim.fn.rename(old_dir, new_dir)

  local own_links = require("filetree.refs.own_links")
  local edits, done = nil, false
  own_links.collect({ [old_dir] = new_dir }, { op = "move", cfg = cfg }, function(e)
    edits = e
    done = true
  end)
  await("done", function()
    return done
  end)
  check("own_links symlink: collect finished", done)
  check(
    "own_links symlink: no edit was produced for the symlinked entry",
    #(edits or {}) == 0,
    vim.inspect(edits)
  )
  check(
    "own_links symlink: the REAL external file was never touched (critical negative control)",
    read(work .. "/outside/Secret.md") == secret_before,
    read(work .. "/outside/Secret.md")
  )

  -- A single moved/renamed symlink (no directory nesting involved) is
  -- skipped the same way -- the `else` branch of `expand_files`.
  if uv.fs_symlink(work .. "/outside/Secret.md", work .. "/LinkAlone.md") then
    vim.fn.rename(work .. "/LinkAlone.md", work .. "/LinkAlone2.md")
    local edits2, done2 = nil, false
    own_links.collect(
      { [work .. "/LinkAlone.md"] = work .. "/LinkAlone2.md" },
      { op = "rename", cfg = cfg },
      function(e)
        edits2 = e
        done2 = true
      end
    )
    await("done2", function()
      return done2
    end)
    check(
      "own_links symlink: a single moved symlink (no directory) is skipped too",
      done2 and #(edits2 or {}) == 0,
      vim.inspect(edits2)
    )
  end

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: each file's project root is resolved independently (bug) ───
-- Regression for a confirmed MEDIUM-severity finding from the 2026-09-28
-- ultracode review: `handle_result` used to compute ONE project root for an
-- entire move/copy batch (from an arbitrary `next(moves)` entry) and apply
-- it to every file own_links processed -- wrong for any file in the batch
-- that sits under a DIFFERENT (nested) project root than the one that
-- happened to get picked. Fixed: `own_links.collect` now resolves each
-- file's root independently (`outgoing.resolve_root(pr.new)` per file,
-- mirroring how the incoming-refs path's `make_ctx` already works).
--
-- B2.md (root "subproj") and a same-named "shared.md" decoy one root up
-- (root "work") are BOTH moved in the same batch, each to a DIFFERENTLY
-- named destination -- so a correct per-file root and a wrong, shared one
-- would resolve B2.md's root-relative link to two DIFFERENT, both very much
-- observable, rewritten strings. Only the "own root" one may appear.
local function run_own_links_multi_root_check()
  print("\n== own_links: per-file project root for a multi-root batch (bug) ==")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  refs.setup(cfg)

  local work = scratch_root .. "/own_links_multi_root"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/subproj/docs", "p")
  vim.fn.mkdir(work .. "/subproj/moved_correct", "p")
  vim.fn.mkdir(work .. "/moved_wrong", "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/subproj/pyproject.toml")
  vim.fn.writefile({ "Ref: [x](/shared.md)" }, work .. "/subproj/docs/B.md")
  vim.fn.writefile({ "correct target" }, work .. "/subproj/shared.md")
  vim.fn.writefile({ "correct target (moved)" }, work .. "/subproj/moved_correct/shared.md")
  vim.fn.writefile({ "wrong-root decoy" }, work .. "/shared.md")
  vim.fn.writefile({ "wrong-root decoy (moved)" }, work .. "/moved_wrong/shared.md")

  vim.fn.rename(work .. "/subproj/docs/B.md", work .. "/subproj/docs/B2.md")

  local moves = {
    [work .. "/subproj/docs/B.md"] = work .. "/subproj/docs/B2.md",
    [work .. "/subproj/shared.md"] = work .. "/subproj/moved_correct/shared.md",
    [work .. "/shared.md"] = work .. "/moved_wrong/shared.md",
  }

  local own_links = require("filetree.refs.own_links")
  local edits, done = nil, false
  own_links.collect(moves, { op = "move", cfg = cfg }, function(e)
    edits = e
    done = true
  end)
  await("done", function()
    return done
  end)
  check("own_links multi-root: collect finished", done)

  local b_edit = nil
  for _, e in ipairs(edits or {}) do
    if e.file == work .. "/subproj/docs/B2.md" then b_edit = e end
  end
  check(
    "own_links multi-root: B2.md's link followed ITS OWN root's moved target",
    b_edit ~= nil and b_edit.new_target == "/moved_correct/shared.md",
    b_edit and vim.inspect(b_edit) or "no edit found for B2.md"
  )
  check(
    "own_links multi-root: the wrong (batch-shared) root's target never appears",
    b_edit == nil or b_edit.new_target ~= "/moved_wrong/shared.md",
    b_edit and vim.inspect(b_edit) or "n/a"
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: a directory move prunes .git/node_modules/etc (perf) ────────
-- Regression for a confirmed HIGH-severity finding from the 2026-09-28
-- ultracode review: a directory move used to walk EVERY nested file
-- unfiltered (`collect_recursive` with no `ignore_fn`) -- a moved directory
-- that happened to contain a populated `node_modules`/`.git`/etc. would be
-- fully enumerated and line-scanned synchronously on the main thread. Fixed:
-- `expand_files` now prunes the same directory set `refs/scan.lua` already
-- prunes for the incoming-refs side of this feature (`scan.PRUNE_DIRS`,
-- exported for exactly this reuse).
local function run_own_links_prune_dirs_check()
  print("\n== own_links: directory-move walk prunes node_modules/etc (performance) ==")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  refs.setup(cfg)

  local work = scratch_root .. "/own_links_prune"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/Nested", "p")
  vim.fn.mkdir(work .. "/Docs/node_modules/pkg", "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "# Shared" }, work .. "/Shared.md")
  vim.fn.writefile({ "Ref: [shared](../Shared.md)" }, work .. "/Docs/note.md")
  -- Same kind of relative link INSIDE the pruned dir: if the walk ever
  -- descended into node_modules, this would show up in `edits` below too.
  vim.fn.writefile({ "Ref: [shared](../../Shared.md)" }, work .. "/Docs/node_modules/pkg/fake.md")

  local old_dir = work .. "/Docs"
  local new_dir = work .. "/Nested/Docs"
  vim.fn.rename(old_dir, new_dir)

  local own_links = require("filetree.refs.own_links")
  local edits, done = nil, false
  own_links.collect({ [old_dir] = new_dir }, { op = "move", cfg = cfg }, function(e)
    edits = e
    done = true
  end)
  await("done", function()
    return done
  end)
  check("own_links prune: collect finished", done)

  local touched_node_modules = false
  for _, e in ipairs(edits or {}) do
    if e.file:find("node_modules", 1, true) then touched_node_modules = true end
  end
  check(
    "own_links prune: nothing under node_modules/ was scanned or rewritten",
    not touched_node_modules,
    vim.inspect(edits)
  )

  local note_touched = false
  for _, e in ipairs(edits or {}) do
    if e.file == new_dir .. "/note.md" and e.new_target == "../../Shared.md" then
      note_touched = true
    end
  end
  check(
    "own_links prune: the real note outside node_modules was still correctly processed",
    note_touched,
    vim.inspect(edits)
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── own_links: M.collect's cb() is always asynchronous, even the early-out ─
-- Regression for a bug introduced (and caught before shipping) in the same
-- review round as the three checks above: `M.collect` returns early, with an
-- empty edit list, when no ENABLED provider implements `retarget_link` (e.g.
-- markdown disabled). That branch used to call `cb` INLINE, breaking the
-- "always asynchronous" contract every other exit path already follows.
-- `refs/init.lua`'s `handle_result` pcall-wraps the INITIATING call to
-- `own_links.collect` so a synchronous SETUP failure can fall back cleanly --
-- but if `cb` itself throws while still running inside that same call stack
-- (inline), the pcall reports the whole call as failed and its own fallback
-- fires `cb` a SECOND time. Scheduling this branch like every other one
-- closes that: `cb` is always invoked after `own_links.collect` itself has
-- already returned, never from inside it.
local function run_own_links_empty_retargetable_async_check()
  print("\n== own_links: cb() is always async, even with no retarget-capable provider ==")

  local cfg = vim.deepcopy(BASE_REFS_CFG)
  cfg.outgoing_links = { enabled = true }
  -- markdown is the only provider with retarget_link -- disabling it leaves
  -- `retargetable` empty, hitting the early-out branch under test.
  cfg.providers = vim.tbl_extend("force", vim.deepcopy(cfg.providers or {}), { markdown = false })
  refs.setup(cfg)

  local work = scratch_root .. "/own_links_empty_retargetable"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "# Note: [x](./other.md)" }, work .. "/note.md")

  local own_links = require("filetree.refs.own_links")
  local edits, done = nil, false
  own_links.collect(
    { [work .. "/note.md"] = work .. "/note2.md" },
    { op = "rename", cfg = cfg },
    function(e)
      edits = e
      done = true
    end
  )
  -- Right here, own_links.collect() has already RETURNED, but not one tick of
  -- the event loop has run yet -- an inline (buggy) cb() would already have
  -- flipped `done` to true by this point.
  check(
    "own_links empty-retargetable: cb() was NOT called synchronously (still pending)",
    done == false
  )

  await("done", function()
    return done
  end)
  check("own_links empty-retargetable: cb() did eventually run", done)
  check(
    "own_links empty-retargetable: no edits (no enabled provider can retarget)",
    edits ~= nil and #edits == 0,
    vim.inspect(edits)
  )

  refs.setup(vim.deepcopy(BASE_REFS_CFG)) -- restore the baseline for later suites
end

-- ── Deleting a file and undoing it puts its REF! markers back ──────────────
-- The delete flow is two mutations, not one: the file goes to the trash, and
-- the references that pointed at it are rewritten to the provider's broken
-- marker. Restoring the file (`U`) therefore has to revert exactly THAT
-- rewrite — which is what the undo token handed to the trash history entry is
-- for. The OS-level restore itself (Recycle Bin / gio) is not driven here; the
-- two halves this covers are the token plumbing and the id-scoped undo, i.e.
-- everything that can silently revert the wrong thing.
local function run_delete_undo_refs_check()
  print("\n== delete + undo: REF! markers restored ==")

  local work = scratch_root .. "/delete_undo"
  vim.fn.delete(work, "rf")
  copy_dir(fixtures_root .. "/markdown", work)

  local trash_undo = require("filetree.features.fileops.trash.undo")
  apply.reset()

  local victim = work .. "/docs/notes.md"
  local asset = work .. "/img/diagram.png"
  vim.fn.writefile({ "Notes live at [notes](./docs/notes.md)." }, work .. "/index.md")
  vim.fn.writefile({ "Guide: [guide](./docs/guide.md)." }, work .. "/other.md")

  -- 1. what the delete's own cleanup does: mark every incoming ref REF!
  local found, done = nil, false
  refs.for_delete({ victim }, { root = work }, function(r)
    found = r
    done = true
  end)
  await("done", function()
    return done
  end)
  check("delete undo: incoming refs found", found ~= nil and #found > 0)

  local applied, _, undo_id = apply.run(found or {}, { label = "delete: notes.md" })
  check("delete undo: rewrite applied", applied > 0)
  check("delete undo: the apply reports an undo token", type(undo_id) == "number")
  local marked = read(work .. "/index.md")
  check(
    "delete undo: reference marked REF!",
    marked ~= nil and marked:find("REF!", 1, true) ~= nil,
    marked
  )

  -- 2. the history entry the token is attached to. The cascade trashes
  --    orphaned assets AFTER the file, so a newer entry sits on top by the
  --    time attach_refs runs — the token must still land on the file's entry.
  trash_undo.record(victim)
  trash_undo.record(asset)
  trash_undo.attach_refs(victim, undo_id, applied)
  local hist = trash_undo.history()
  check("delete undo: the asset is the newest history entry", hist[1].original_path == asset)
  check(
    "delete undo: the token landed on the file's entry, not the asset's",
    hist[2].original_path == victim
      and hist[2].refs_undo_id == undo_id
      and hist[2].refs_count == applied,
    vim.inspect(hist[2])
  )
  check("delete undo: the asset entry carries no token", hist[1].refs_undo_id == nil)

  -- 3. an unrelated, NEWER rewrite on top of the stack. `U` on the older
  --    delete must not revert this one (which plain `refs.undo` would).
  local other_found, other_done = nil, false
  refs.for_delete({ work .. "/docs/guide.md" }, { root = work }, function(r)
    other_found = r
    other_done = true
  end)
  await("other_done", function()
    return other_done
  end)
  local other_applied = apply.run(other_found or {}, { label = "delete: guide.md" })
  check("delete undo: a newer, unrelated rewrite was applied", other_applied > 0)

  check("delete undo: the token is still live", apply.has_token(undo_id) == true)
  local restored, _, _, skipped = apply.undo_by_id(undo_id)

  local reverted = read(work .. "/index.md")
  check(
    "delete undo: the reference is back, byte for byte",
    reverted ~= nil and reverted:find("[notes](./docs/notes.md)", 1, true) ~= nil,
    reverted
  )

  -- README.md's first paragraph links to notes.md AND guide.md on ONE line, so
  -- the second delete rewrote a line the first had already rewritten. Putting
  -- the first delete's version back would carry the guide link back with it,
  -- silently undoing the second delete. The line is therefore left exactly as
  -- the newer rewrite left it -- both markers intact -- and counted as skipped
  -- rather than quietly dropped, since it does still read REF!.
  local readme = read(work .. "/README.md")
  check(
    "delete undo: a line a NEWER rewrite also touched keeps that newer rewrite",
    readme ~= nil and readme:find("[the guide](REF!)", 1, true) ~= nil,
    readme
  )
  check(
    "delete undo: ...so the older delete's marker on that shared line stays too",
    readme ~= nil and readme:find("[shared notes](REF!)", 1, true) ~= nil,
    readme
  )
  check(
    "delete undo: the skipped line is reported, not silently dropped",
    restored == 1 and skipped == 1,
    ("restored=%d skipped=%d applied=%d"):format(restored, skipped, applied)
  )
  check(
    "delete undo: the newer, unrelated rewrite stayed applied",
    (read(work .. "/other.md") or ""):find("REF!", 1, true) ~= nil,
    read(work .. "/other.md")
  )
  check("delete undo: the token is consumed", apply.has_token(undo_id) == false)
  check("delete undo: undoing a consumed token is a no-op", apply.undo_by_id(undo_id) == 0)

  apply.reset()
end

-- ── Delete + immediate undo, while the refs rewrite is still chunking ──────
-- `apply.run`'s chunked path (more than APPLY_CHUNK_SIZE=8 distinct
-- referencing files) does its first chunk synchronously, then yields via
-- `vim.schedule` before the rest -- and `attach_refs` only runs once every
-- chunk has landed. Nothing gates `U` while that's in flight: pressing it
-- during the yield used to remove the trash-history entry before
-- `attach_refs` ever got a chance to attach the rewrite's undo token to it,
-- silently orphaning the whole rewrite from `U`/`<leader>th` (still reachable
-- via the unrelated `:Filetree refs undo`, but with no indication that was
-- necessary). `mark_refs_pending`/the `_pending` tracking in trash/undo.lua
-- exists to catch exactly this. This drives the real race, not a description
-- of it: it calls `apply.run` the same way trash/init.lua's
-- `trash_then_cleanup` does (a callback, so >8 files takes the chunked
-- path), and restores mid-chunk before any `vim.wait`/`vim.schedule` tick has
-- had a chance to run.
local function run_delete_undo_refs_chunked_race_check()
  print("\n== delete + undo: race against a chunked (>8 file) refs rewrite ==")

  local work = scratch_root .. "/delete_undo_chunked_race"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")

  local victim = work .. "/shared.md"
  vim.fn.writefile({ "# Shared" }, victim)
  -- 10 distinct referencing files: > APPLY_CHUNK_SIZE (8), so apply.run must
  -- take the chunked path rather than resolving everything synchronously.
  local N = 10
  for i = 1, N do
    vim.fn.writefile(
      { ("Referrer %d: [shared](./shared.md)."):format(i) },
      string.format("%s/ref%02d.md", work, i)
    )
  end

  local trash_undo = require("filetree.features.fileops.trash.undo")
  apply.reset()

  -- The OS-level restore is faked through `run_argv.run_blocking`, but only
  -- the Windows restore calls that unconditionally -- the Unix one needs a
  -- real `gio`/XDG trash directory and bails with "Could not restore"
  -- otherwise. Record the entry as a Windows one so every host takes the
  -- branch the fake covers, instead of passing on Windows alone.
  local host_platform = require("filetree.util.platform")
  local function record_as_windows(path)
    local real_current = host_platform.current
    ---@diagnostic disable-next-line: duplicate-set-field
    host_platform.current = function()
      return "windows"
    end
    -- Restored even if `record` throws: a stuck override would make every
    -- later spec in this process record its trash entries as Windows ones.
    local ok, err = pcall(trash_undo.record, path)
    host_platform.current = real_current
    if not ok then error(err, 0) end
  end

  local found, scanned = nil, false
  refs.for_delete({ victim }, { root = work }, function(r)
    found = r
    scanned = true
  end)
  await("scanned", function()
    return scanned
  end)
  check(
    "chunked race: found refs in all " .. N .. " referencing files",
    found ~= nil and #found == N,
    found and #found or "nil"
  )

  -- Mirrors trash/init.lua's trash_then_cleanup exactly: record the trash
  -- history entry, mark its refs rewrite pending, THEN kick off the
  -- (necessarily chunked) apply -- in that order, since that ordering is
  -- itself the fix.
  record_as_windows(victim)
  local said = {}
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level, opts)
    said[#said + 1] = tostring(msg)
    return real_notify(msg, level, opts)
  end

  trash_undo.mark_refs_pending(victim)
  local finished_applied, finished_undo_id
  apply.run(found or {}, { label = "delete: shared.md" }, function(applied, _, undo_id)
    finished_applied, finished_undo_id = applied, undo_id
    trash_undo.attach_refs(victim, undo_id, applied)
  end)

  -- Still inside the race window: apply.run's first chunk ran synchronously
  -- (8 of the 10 files), but it yielded via vim.schedule before the last 2 --
  -- attach_refs above has NOT run yet, so the history entry's refs_undo_id is
  -- still nil. Nothing has ticked the event loop since apply.run returned.
  check("chunked race: the rewrite has not finished yet (still mid-chunk)", finished_undo_id == nil)
  local before_restore = trash_undo.history()
  check(
    "chunked race: the history entry exists, with no token attached yet",
    before_restore[1] ~= nil
      and before_restore[1].original_path == victim
      and before_restore[1].refs_undo_id == nil
  )

  -- `U`, fired right now -- this is the race.
  local run_argv = require("lib.nvim.cross.run_argv")
  local orig_run_blocking = run_argv.run_blocking
  ---@diagnostic disable-next-line: duplicate-set-field
  run_argv.run_blocking = function()
    return true, nil -- pretend the OS-level restore succeeded; no real file to move
  end
  -- the rewrite settles after the restore: the person is asked whether the references go back too (No here)
  local asked_question
  trash_undo.confirm = function(question, _, cb)
    asked_question = question
    cb(false)
  end
  local restore_ok = trash_undo.restore_last()
  run_argv.run_blocking = orig_run_blocking

  check("chunked race: U itself reports success", restore_ok == true)
  check(
    "chunked race: the history entry is gone (the race actually happened)",
    #trash_undo.history() == 0 or trash_undo.history()[1].original_path ~= victim
  )
  check(
    "chunked race: restore_refs warned instead of staying silent about a nil id",
    (function()
      for _, m in ipairs(said) do
        if m:find("still running", 1, true) then return true end
      end
      return false
    end)(),
    table.concat(said, " | ")
  )

  -- Let the rest of the chunked rewrite actually finish.
  await("finished_undo_id ~= nil", function()
    return finished_undo_id ~= nil
  end)
  check("chunked race: the rewrite did eventually finish", finished_applied == N)
  vim.notify = real_notify

  check(
    "chunked race: attach_refs asked whether the finished rewrite is reverted too",
    asked_question ~= nil
      and asked_question:find("finished updating after the restore", 1, true) ~= nil,
    tostring(asked_question)
  )
  trash_undo.confirm = nil

  -- The orphaned token is not lost -- still reachable the generic way.
  check(
    "chunked race: the orphaned token is still on the refs undo stack",
    finished_undo_id ~= nil and apply.has_token(finished_undo_id) == true
  )
  local restored_count = apply.undo_by_id(finished_undo_id)
  check("chunked race: :Filetree refs undo can still revert it manually", restored_count == N)

  -- attach_refs clears `_pending[victim]` unconditionally (the vim.wait above
  -- ran it), so a brand new, unrelated delete of the same path afterward must
  -- not inherit a stale pending mark and spuriously warn "still running" for
  -- a rewrite that never happened this time.
  vim.fn.writefile({ "# Shared again" }, victim)
  record_as_windows(victim)
  local said2 = {}
  vim.notify = function(msg, level, opts)
    said2[#said2 + 1] = tostring(msg)
    return real_notify(msg, level, opts)
  end
  run_argv.run_blocking = function()
    return true, nil
  end
  local ok2 = trash_undo.restore_last()
  run_argv.run_blocking = orig_run_blocking
  vim.notify = real_notify
  check("chunked race: a later, unrelated restore of the same path succeeds", ok2 == true)
  for _, m in ipairs(said2) do
    check(
      "chunked race: ...and the stale pending mark does not leak into it",
      not m:find("still running", 1, true),
      m
    )
  end

  apply.reset()
end

-- ── Cut/paste and move: reverting one op's rewrite, not "the last one" ─────
-- `U` is trash's, but the id-scoped undo underneath it is not delete-specific:
-- any feature that rewrites references can revert its own apply later. These
-- two drive the real features (cut+paste through the clipboard, `M` through
-- move.move), then push an UNRELATED newer apply on top and revert the older
-- one by id -- the case a plain "undo the top of the stack" gets wrong.
--
-- Files are deliberately kept one-link-per-line here; the delete block above
-- covers what happens when two applies share a line.

---@param work string
---@param label string  Prefix for the check names.
---@return integer  Undo id of the newer, unrelated apply.
local function mark_unrelated_delete(work, label)
  local victim = work .. "/decoy.md"
  vim.fn.writefile({ "# Decoy" }, victim)
  vim.fn.writefile({ "Decoy: [decoy](./decoy.md)." }, work .. "/decoy_ref.md")

  local found, done = nil, false
  refs.for_delete({ victim }, { root = work }, function(r)
    found = r
    done = true
  end)
  await("done", function()
    return done
  end)
  local _, _, id = apply.run(found or {}, { label = "delete: decoy.md" })
  check(
    label .. ": the newer, unrelated rewrite landed",
    (read(work .. "/decoy_ref.md") or ""):find("REF!", 1, true) ~= nil
  )
  return id
end

local function run_cut_paste_undo_check()
  print("\n== cut/paste (x/p) + id-scoped refs undo ==")

  local work = scratch_root .. "/cut_paste_undo"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/docs", "p")
  vim.fn.writefile({ "[tool.x]" }, work .. "/pyproject.toml") -- project marker
  vim.fn.writefile({ "# Notes" }, work .. "/docs/notes.md")
  vim.fn.writefile({ "See [notes](./docs/notes.md)." }, work .. "/index.md")

  local src = work .. "/docs/notes.md"
  local dst = work .. "/notes.md"

  local copy_move = require("filetree.features.fileops.copy_move")
  local current, done = src, false
  copy_move.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = current, type = current == work and "directory" or "file" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })

  -- x on the file, then p on the destination directory.
  copy_move.stage_cut()
  current = work
  copy_move.paste()
  await("done", function()
    return done
  end)

  check(
    "cut/paste: the file moved",
    vim.fn.filereadable(dst) == 1 and vim.fn.filereadable(src) == 0
  )
  local moved = read(work .. "/index.md")
  check(
    "cut/paste: the reference followed the move",
    moved ~= nil and moved:find("[notes](./notes.md)", 1, true) ~= nil,
    moved
  )

  local paste_id = apply.last_token_id()
  check("cut/paste: the paste's apply is on the undo stack", type(paste_id) == "number")

  local decoy_id = mark_unrelated_delete(work, "cut/paste")
  check("cut/paste: the paste's token survived a newer apply", apply.has_token(paste_id) == true)

  local restored = apply.undo_by_id(paste_id)
  check("cut/paste: undo_by_id reverted the paste's own rewrite", restored == 1)
  local reverted = read(work .. "/index.md")
  check(
    "cut/paste: the reference is back to the pre-paste text",
    reverted ~= nil and reverted:find("[notes](./docs/notes.md)", 1, true) ~= nil,
    reverted
  )
  check(
    "cut/paste: the newer, unrelated rewrite was left alone",
    (read(work .. "/decoy_ref.md") or ""):find("REF!", 1, true) ~= nil
      and apply.has_token(decoy_id) == true
  )

  copy_move.teardown()
  apply.reset()
end

local function run_move_undo_check()
  print("\n== move (M) + id-scoped refs undo ==")

  local work = scratch_root .. "/move_undo"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/docs", "p")
  vim.fn.writefile({ "[tool.x]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "# Notes" }, work .. "/docs/notes.md")
  vim.fn.writefile({ "See [notes](./docs/notes.md)." }, work .. "/index.md")

  local src = work .. "/docs/notes.md"
  local dst = work .. "/notes.md"

  local move = require("filetree.features.fileops.move")
  local done = false
  move.setup({ enabled = true, use_safety = false, dry_run = false }, {
    get_current_node = function()
      return { path = src, type = "file" }
    end,
    refresh = function()
      done = true
      return true
    end,
  })
  move.move(work)
  await("done", function()
    return done
  end)

  check("move: the file moved", vim.fn.filereadable(dst) == 1 and vim.fn.filereadable(src) == 0)
  local moved = read(work .. "/index.md")
  check(
    "move: the reference followed the move",
    moved ~= nil and moved:find("[notes](./notes.md)", 1, true) ~= nil,
    moved
  )

  local move_id = apply.last_token_id()
  local decoy_id = mark_unrelated_delete(work, "move")
  check("move: the move's token survived a newer apply", apply.has_token(move_id) == true)

  -- Revert the OLDER apply to prove the id actually selects: a plain
  -- `refs.undo` here would pop the decoy instead.
  local restored = apply.undo_by_id(move_id)
  check("move: undo_by_id reverted the move's own rewrite", restored == 1)
  check(
    "move: the reference is back to the pre-move text",
    (read(work .. "/index.md") or ""):find("[notes](./docs/notes.md)", 1, true) ~= nil,
    read(work .. "/index.md")
  )
  check(
    "move: the newer, unrelated rewrite was left alone",
    (read(work .. "/decoy_ref.md") or ""):find("REF!", 1, true) ~= nil
  )

  -- …and the decoy is still undoable the ordinary way afterwards.
  refs.undo()
  check(
    "move: `:Filetree refs undo` still reverts the remaining apply",
    (read(work .. "/decoy_ref.md") or ""):find("[decoy](./decoy.md)", 1, true) ~= nil
      and apply.has_token(decoy_id) == false,
    read(work .. "/decoy_ref.md")
  )

  apply.reset()
end

-- ── Undo is content-verified, exactly like the apply ───────────────────────
-- The apply half never writes over a line that drifted since the scan. The
-- undo half used to restore blind, which threw away whatever had been typed on
-- those lines in the meantime -- reachable now from `U`, which reverts an
-- apply the user may not remember, on files they have been editing since.
local function run_undo_content_verification_check()
  print("\n== refs undo: an edit made since the apply wins ==")

  local work = scratch_root .. "/undo_verify"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "[tool.x]" }, work .. "/pyproject.toml")
  vim.fn.writefile({ "# Notes" }, work .. "/notes.md")
  vim.fn.writefile({ "Kept: [notes](./notes.md)." }, work .. "/kept.md")
  vim.fn.writefile({ "Edited: [notes](./notes.md)." }, work .. "/edited.md")

  local found, done = nil, false
  refs.for_delete({ work .. "/notes.md" }, { root = work }, function(r)
    found = r
    done = true
  end)
  await("done", function()
    return done
  end)
  local applied, _, id = apply.run(found or {}, { label = "delete: notes.md" })
  check("undo verify: both references were marked", applied == 2, "applied=" .. applied)

  -- Someone rewrites that line by hand after the delete — the undo must not
  -- silently replace their line with the pre-delete one.
  local hand_edit = "Edited: [notes](./somewhere/else.md)."
  vim.fn.writefile({ hand_edit }, work .. "/edited.md")

  local restored, files, _, skipped = apply.undo_by_id(id)
  check("undo verify: the untouched line was restored", restored == 1 and files == 1)
  check("undo verify: the edited line is reported as skipped", skipped == 1, "skipped=" .. skipped)
  check(
    "undo verify: the hand edit survived",
    read(work .. "/edited.md") == hand_edit,
    read(work .. "/edited.md")
  )
  check(
    "undo verify: the untouched file went back to its original text",
    (read(work .. "/kept.md") or ""):find("[notes](./notes.md)", 1, true) ~= nil,
    read(work .. "/kept.md")
  )

  apply.reset()
end

-- ── A dry-run delete plans everything and changes nothing ─────────────────
-- `dry_run` logs the trash instead of performing it, and does the same for
-- each cascaded asset — but the incoming-reference rewrite used to fall
-- straight through and really write REF! into every referencing file. That is
-- the half of a delete that touches files the user did not select, so a
-- dry-run has even less business making it than the delete itself.
--
-- The whole point rests on the delete genuinely HAVING references to rewrite:
-- a victim nothing points at would take the plain yes/no branch and pass this
-- vacuously, so the scan is asserted first.
local function run_trash_dry_run_check()
  print("\n== trash dry-run: plans the delete, rewrites nothing ==")

  local work = scratch_root .. "/trash_dry_run"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "[tool.x]" }, work .. "/pyproject.toml") -- project marker
  vim.fn.writefile({ "# Notes" }, work .. "/notes.md")
  vim.fn.writefile({ "See [notes](./notes.md)." }, work .. "/index.md")

  apply.reset()
  local victim = work .. "/notes.md"

  -- Same scan the delete itself runs, so "nothing was rewritten" below means
  -- "the guard held", not "there was nothing to rewrite".
  local found, scanned = nil, false
  refs.for_delete({ victim }, { root = work }, function(r)
    found = r
    scanned = true
  end)
  await("scanned", function()
    return scanned
  end)
  check(
    "trash dry-run: the delete really does have a reference to rewrite",
    found ~= nil and #found == 1,
    found and #found or "nil"
  )

  local trash = require("filetree.features.fileops.trash")
  local refreshed = false
  trash.setup({
    enabled = true,
    dry_run = true,
    confirm = true,
    mode = "trash",
    use_safety = false,
  }, {
    get_current_node = function()
      return { path = victim, type = "file" }
    end,
    refresh = function()
      refreshed = true
      return true
    end,
  })

  -- What a dry-run SAYS is the whole feature -- it changes nothing, so the
  -- messages are its only output. Captured for the two assertions below.
  ---@type string[]
  local said = {}
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level, opts)
    said[#said + 1] = tostring(msg)
    return real_notify(msg, level, opts)
  end

  next_choice = true -- "yes" to the trash confirmation
  trash.delete_current()
  await("refreshed", function()
    return refreshed
  end)
  vim.notify = real_notify

  ---@param needle string
  ---@return boolean
  local function said_something_like(needle)
    for _, msg in ipairs(said) do
      if msg:lower():find(needle:lower(), 1, true) then return true end
    end
    return false
  end

  check("trash dry-run: the delete was reported as done", refreshed)
  check("trash dry-run: the file is still there", vim.fn.filereadable(victim) == 1)
  check(
    "trash dry-run: the reference was NOT rewritten",
    (read(work .. "/index.md") or ""):find("[notes](./notes.md)", 1, true) ~= nil,
    read(work .. "/index.md")
  )
  check(
    "trash dry-run: no REF! marker was written anywhere",
    (read(work .. "/index.md") or ""):find("REF!", 1, true) == nil,
    read(work .. "/index.md")
  )
  check(
    "trash dry-run: nothing landed on the refs undo stack either",
    apply.can_undo() == false,
    apply.last_label()
  )

  -- Nor any trash history: nothing was trashed, so `U`/`<leader>th` must not
  -- offer to restore it. (Any entry here would be this run's -- every other
  -- block in this suite records through the undo module directly, and the one
  -- that does runs after this.)
  local trash_undo = require("filetree.features.fileops.trash.undo")
  local said_nothing_trashed = true
  for _, e in ipairs(trash_undo.history()) do
    if e.original_path == victim then said_nothing_trashed = false end
  end
  check(
    "trash dry-run: no trash history entry was recorded",
    said_nothing_trashed,
    vim.inspect(trash_undo.history())
  )

  check(
    "trash dry-run: it said it WOULD mark the reference",
    said_something_like("[dry-run] would mark 1 reference"),
    table.concat(said, " | ")
  )
  -- Every step of a dry-run reports in the conditional, so the closing summary
  -- must too: "Moved 1/1 to trash" was the one line claiming it had happened.
  check(
    "trash dry-run: the closing summary does not claim the file was moved",
    said_something_like("[dry-run] would move 1/1 to trash")
      and not said_something_like("Moved 1/1 to trash"),
    table.concat(said, " | ")
  )

  trash.teardown()
  apply.reset()
end

-- ── A candidate the scan cannot read makes the delete count a lower bound ───
-- ripgrep names a file, but reading it fails (locked, no permission): its references are missing,
-- so the confirm must not present the count it has as the final one, and the user is told which
-- file could not be read. Reading is stubbed for one file, since a real lock is per platform.
local function run_trash_lower_bound_check()
  print("\n== trash: an unreadable candidate makes the count a lower bound ==")

  local work = scratch_root .. "/trash_lower_bound"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "[tool.x]" }, work .. "/pyproject.toml") -- project marker
  vim.fn.writefile({ "# Notes" }, work .. "/notes.md")
  vim.fn.writefile({ "See [notes](./notes.md)." }, work .. "/index.md")
  vim.fn.writefile({ "Also [notes](./notes.md)." }, work .. "/locked.md")
  apply.reset()
  local victim = work .. "/notes.md"

  local scan = require("filetree.refs.scan")
  local real_lines_of = scan.lines_of
  ---@diagnostic disable-next-line: duplicate-set-field
  scan.lines_of = function(file)
    if file:gsub("\\", "/"):match("/locked%.md$") then return nil end
    return real_lines_of(file)
  end

  local trash = require("filetree.features.fileops.trash")
  local refreshed = false
  trash.setup({
    enabled = true,
    dry_run = true,
    confirm = true,
    mode = "trash",
    use_safety = false,
  }, {
    get_current_node = function()
      return { path = victim, type = "file" }
    end,
    refresh = function()
      refreshed = true
      return true
    end,
  })

  ---@type string[]
  local said, asked = {}, {}
  local real_notify, real_confirm = vim.notify, kit.confirm
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    said[#said + 1] = tostring(msg)
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  kit.confirm = function(opts)
    asked[#asked + 1] = tostring(opts.question)
    return real_confirm(opts)
  end

  next_choice = true -- "yes" to the trash confirmation
  local ok_run, err = pcall(function()
    trash.delete_current()
    await("refreshed", function()
      return refreshed
    end)
  end)
  vim.notify, kit.confirm, scan.lines_of = real_notify, real_confirm, real_lines_of
  trash.teardown()
  apply.reset()
  if not ok_run then error(err) end

  local question = table.concat(asked, " | ")
  check(
    "trash lower bound: the confirm says at least 1 reference",
    question:find("at least 1 ref(s) will be marked REF!", 1, true) ~= nil,
    question
  )
  local warned = false
  for _, msg in ipairs(said) do
    if msg:find("could not be read", 1, true) and msg:find("locked.md", 1, true) then
      warned = true
    end
  end
  check("trash lower bound: the unreadable file is named", warned, table.concat(said, " | "))
end

-- ── One spelling per path, whichever scan backend found it ─────────────────
-- `ref.file` is what `apply` groups by, what the undo stack keys on, and what
-- the chooser shows. The two candidate backends used to disagree about it:
-- ripgrep is handed a forward-slash root and prints `<root>\rel\path.lua`, so
-- on Windows its hits came back with mixed separators, while the libuv walk
-- returned clean forward slashes. Same file, two names, decided by whether the
-- machine happens to have ripgrep.
--
-- Nothing was visibly broken by it, which is exactly why it wants a test: the
-- next thing to dedup or compare on that string would have broken quietly, and
-- only on one of the two setups.
local function run_scan_path_canonical_check()
  print("\n== scan: both backends spell a path the same way ==")

  local work = scratch_root .. "/scan_paths"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/lua/proj/nested/deep", "p")
  vim.fn.mkdir(work .. "/lua/proj/util", "p")
  vim.fn.writefile({ "{}" }, work .. "/.luarc.json")
  vim.fn.writefile({ "return {}" }, work .. "/lua/proj/util/shared.lua")
  vim.fn.writefile({ 'require("proj.util.shared")' }, work .. "/lua/proj/a.lua")
  vim.fn.writefile({ 'require("proj.util.shared")' }, work .. "/lua/proj/nested/deep/c.lua")

  ---@return string[] sorted ref.file values
  local function scan_files()
    local done, result = false, nil
    refs.scan({ work .. "/lua/proj/util/shared.lua" }, { root = work, op = "rename" }, function(r)
      result = r
      done = true
    end)
    await("done", function()
      return done
    end)
    local seen, out = {}, {}
    for _, ref in ipairs((result or {}).refs or {}) do
      if not seen[ref.file] then
        seen[ref.file] = true
        out[#out + 1] = ref.file
      end
    end
    table.sort(out)
    return out
  end

  local with_rg = scan_files()
  check(
    "scan paths: the ripgrep backend found both referencing files",
    #with_rg == 2,
    vim.inspect(with_rg)
  )

  -- candidates_rg gives up when the spawn itself fails, which is the same door
  -- a machine without ripgrep comes through.
  local real_system = vim.system
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function()
    error("forced: no ripgrep")
  end
  local with_walk = scan_files()
  vim.system = real_system

  check(
    "scan paths: the libuv fallback found the same two files",
    #with_walk == 2,
    vim.inspect(with_walk)
  )
  check(
    "scan paths: both backends return byte-identical paths",
    table.concat(with_rg, "|") == table.concat(with_walk, "|"),
    ("rg=%s walk=%s"):format(vim.inspect(with_rg), vim.inspect(with_walk))
  )

  local backslashed = {}
  for _, f in ipairs(with_rg) do
    if f:find("\\", 1, true) then backslashed[#backslashed + 1] = f end
  end
  check(
    "scan paths: no candidate keeps a native separator",
    #backslashed == 0,
    table.concat(backslashed, "; ")
  )

  -- And what the chooser puts in front of the user follows the same rule:
  -- util.path makes `/` the one separator anything user-facing shows, but
  -- fnamemodify(":.") hands back native ones.
  local done, result = false, nil
  refs.scan({ work .. "/lua/proj/util/shared.lua" }, { root = work, op = "rename" }, function(r)
    result = r
    done = true
  end)
  await("done", function()
    return done
  end)
  local shown = require("filetree.refs.ui").unique_files((result or {}).refs or {})
  local shown_bad = {}
  for _, f in ipairs(shown) do
    if f:find("\\", 1, true) then shown_bad[#shown_bad + 1] = f end
  end
  check(
    "scan paths: the file list shown to the user uses `/` too",
    #shown > 0 and #shown_bad == 0,
    table.concat(shown, ", ")
  )
end

-- Extends the canonical-path block: what the user READS must follow the same
-- rule as what the engine stores. Each provider builds a `display` row for the
-- picker ("path:line: text"), and the chooser's diff view builds an
-- "--- a/<path>" header; both hand-rolled `fnamemodify(":.")`, which returns
-- native separators, so every row read `lua\proj\a.lua` on Windows while
-- util.path makes `/` the one separator anything user-facing shows.
local function run_display_path_check()
  print("\n== refs: every path the user reads uses `/` ==")

  local work = scratch_root .. "/display_paths"
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/lua/proj/nested/deep", "p")
  vim.fn.mkdir(work .. "/lua/proj/util", "p")
  vim.fn.mkdir(work .. "/docs", "p")
  vim.fn.writefile({ "{}" }, work .. "/.luarc.json")
  vim.fn.writefile({ "return {}" }, work .. "/lua/proj/util/shared.lua")
  vim.fn.writefile({ 'require("proj.util.shared")' }, work .. "/lua/proj/nested/deep/c.lua")
  vim.fn.writefile({ "See [x](../lua/proj/util/shared.lua)." }, work .. "/docs/guide.md")

  -- The cwd has to be INSIDE the fixture, and this is not a detail: `:.` only
  -- rewrites a path it can strip the cwd from, and stripping is exactly when
  -- it hands back native separators. Run from anywhere else it returns the
  -- path untouched -- so an earlier version of this block, which skipped the
  -- `cd`, passed against the unfixed code. A check that cannot fail is the
  -- same trap `check_fixtures_match_spec` above exists to catch.
  local prev_cwd = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  local done, result = false, nil
  refs.scan({ work .. "/lua/proj/util/shared.lua" }, { root = work, op = "rename" }, function(r)
    result = r
    done = true
  end)
  await("done", function()
    return done
  end)

  local found = (result or {}).refs or {}
  check("display paths: the scan found refs to inspect", #found > 0, tostring(#found))

  -- The per-ref row every picker backend renders (telescope, fzf-lua and the
  -- quickfix list all build from `r.display`).
  local bad_rows = {}
  local providers_seen = {}
  for _, ref in ipairs(found) do
    providers_seen[ref.provider] = true
    if type(ref.display) ~= "string" or ref.display:find("\\", 1, true) then
      bad_rows[#bad_rows + 1] = tostring(ref.display)
    end
  end
  check(
    "display paths: no picker row carries a native separator",
    #bad_rows == 0,
    table.concat(bad_rows, "; ")
  )
  -- More than one provider, so this is not a single code path passing by luck.
  local n_providers = 0
  for _ in pairs(providers_seen) do
    n_providers = n_providers + 1
  end
  check("display paths: more than one provider contributed a row", n_providers >= 2, n_providers)

  -- And the chooser's "Show diff" header.
  local rows = require("filetree.refs.apply").preview(vim.tbl_map(function(r)
    local copy = vim.deepcopy(r)
    copy.new_target = "REPLACED"
    return copy
  end, found))
  local diff_bad = {}
  for _, row in ipairs(rows) do
    if row.file:find("\\", 1, true) then diff_bad[#diff_bad + 1] = row.file end
  end
  check(
    "display paths: the diff preview's file paths are canonical too",
    #diff_bad == 0,
    table.concat(diff_bad, "; ")
  )

  -- The rows are relative, not absolute: proof that `:.` really did strip the
  -- cwd here, i.e. that the assertions above were in a position to fail.
  local absolute = {}
  for _, ref in ipairs(found) do
    if ref.display:find("^%a:") or ref.display:find("^/") then
      absolute[#absolute + 1] = ref.display
    end
  end
  check(
    "display paths: the rows are cwd-relative, so the check could have failed",
    #found > 0 and #absolute == 0,
    table.concat(absolute, "; ")
  )

  vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
end

-- ── Run ───────────────────────────────────────────────────────────────────────
for _, lang in ipairs(LANGS) do
  if not ONLY or lang.name == ONLY then run_lang(lang) end
end
if ONLY then finish() end
run_lua_buffer_check()
run_lua_directory_cascade_check()
run_move_feature_check()
run_plaintext_comment_check()
run_outgoing_scan_check()
run_outgoing_assets_check()
run_outgoing_assets_gate_check()
run_outgoing_assets_independent_switch_check()
run_own_links_move_check()
run_own_links_dir_move_check()
run_own_links_env_var_check()
run_own_links_copy_check()
run_own_links_symlink_safety_check()
run_own_links_multi_root_check()
run_own_links_prune_dirs_check()
run_own_links_empty_retargetable_async_check()
run_delete_undo_refs_check()
run_delete_undo_refs_chunked_race_check()
run_cut_paste_undo_check()
run_move_undo_check()
run_undo_content_verification_check()
run_trash_dry_run_check()
run_trash_lower_bound_check()
run_scan_path_canonical_check()
run_display_path_check()

-- ── Report ────────────────────────────────────────────────────────────────────
finish()
