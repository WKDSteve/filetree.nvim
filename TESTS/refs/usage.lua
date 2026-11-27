---@diagnostic disable: need-check-nil, missing-fields, redundant-parameter, duplicate-set-field
-- usage.lua -- regression test for `filetree.refs.usage`, the batched
-- reference counter behind `:Filetree references`, `:Filetree refs unused` and
-- the `I` node info section.
--
-- A throwaway project is built in a scratch dir (referenced, twice-referenced,
-- unreferenced, self-referencing and look-alike files), then counted once with
-- ripgrep and once through the ripgrep-free walk fallback -- both backends
-- must agree.
--
-- Usage (from the filetree.nvim repo root):
--   nvim --clean --headless -u NONE -l TESTS/refs/usage.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(root)

-- Dependency resolution, same candidate order as TESTS/refs/run.lua.
local function add_dep(dir_name, env_names, probe)
  local candidates = {}
  for _, env in ipairs(env_names) do
    local v = vim.env[env]
    if v and v ~= "" then candidates[#candidates + 1] = v end
  end
  candidates[#candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/" .. dir_name
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/" .. dir_name
  for _, path in ipairs(candidates) do
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. probe) == 1 then
      vim.opt.rtp:prepend(norm)
      package.path =
        table.concat({ norm .. "/lua/?.lua", norm .. "/lua/?/init.lua", package.path }, ";")
      return
    end
  end
end
add_dep("lib.nvim", { "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }, "/lua/lib")
add_dep("ui.nvim", { "FILETREE_UI_NVIM", "UI_NVIM_PATH" }, "/lua/ui")

local scratch_root = (vim.fn.has("win32") == 1 and vim.env.TEMP or "/tmp") .. "/filetree-usage-test"
do
  local uv = vim.uv or vim.loop
  vim.fn.mkdir(scratch_root, "p")
  local real = uv.fs_realpath(scratch_root)
  if real then scratch_root = (real:gsub("\\", "/")) end
end

---Whether a `vim.system` argv starts ripgrep: the scan may start it by its
---resolved path (a Scoop shim resolves to the real binary), not as "rg".
---@param cmd string[]
---@return boolean
local function is_rg(cmd)
  return (vim.fs.basename(cmd[1]):lower():gsub("%.exe$", "")) == "rg"
end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end

local refs = require("filetree.refs")
refs.setup({
  providers = { markdown = true, lua = true, python = false, ts_js = false },
  -- A report must not depend on the rewrite-on-mutation switches.
  enabled = false,
  on_delete = "off",
})

-- ── Fixture ───────────────────────────────────────────────────────────────────
local work = scratch_root .. "/project"
vim.fn.delete(work, "rf")
vim.fn.mkdir(work .. "/assets", "p")
vim.fn.mkdir(work .. "/bulk", "p")
vim.fn.mkdir(work .. "/lua/mod", "p")
vim.fn.writefile({ "[tool.filetree]" }, work .. "/pyproject.toml")
for _, name in ipairs({
  "used.png",
  "twice.png",
  "orphan.png",
  "shot.png",
  "my shot.png",
  "self.png",
}) do
  vim.fn.writefile({ "x" }, work .. "/assets/" .. name)
end
vim.fn.writefile({
  "One: ![u](assets/used.png)",
  "Twice here: ![t](assets/twice.png) and again ![t](assets/twice.png)",
  "Spaced: ![s](assets/my%20shot.png)",
  -- Look-alike: `shot.png` is a substring of `myshot.png`, which is not it.
  "Look-alike: ![x](assets/myshot.png)",
  "Self: [me](doc.md)",
}, work .. "/doc.md")
vim.fn.writefile({ "![t](assets/twice.png)" }, work .. "/other.md")
vim.fn.writefile({ "I am [self](../assets/self.png)" }, work .. "/assets/note.md")
vim.fn.writefile({ "return {}" }, work .. "/lua/mod/util.lua")
vim.fn.writefile({ 'local u = require("mod.util")', "return u" }, work .. "/lua/mod/init.lua")

-- Enough long-named files that the combined needles exceed the argv limit and
-- take the stdin path of `scan.candidates`.
local bulk_ref
for i = 1, 400 do
  local name = string.format("bulk/screenshot_%04d_with_a_rather_long_descriptive_name.png", i)
  vim.fn.writefile({ "x" }, work .. "/" .. name)
  if i == 217 then bulk_ref = name end
end
vim.fn.writefile({ "![b](" .. bulk_ref .. ")" }, work .. "/bulk-user.md")

local function p(rel)
  return work .. "/" .. rel
end

---@return table<string, FiletreeRefUsage>, FiletreeRefUsageMeta
local function count(paths)
  local got, meta, done = nil, nil, false
  refs.usage.count(paths, { root = work }, function(by_path, m)
    got, meta, done = by_path, m, true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  return got, meta
end

local function basename_set(files)
  local set = {}
  for _, f in ipairs(files) do
    set[f:match("([^/]+)$")] = true
  end
  return set
end

local function run(label)
  print("\n== refs.usage (" .. label .. ") ==")
  local paths = {
    p("assets/used.png"),
    p("assets/twice.png"),
    p("assets/orphan.png"),
    p("assets/shot.png"),
    p("assets/my shot.png"),
    p("assets/self.png"),
    p("lua/mod/util.lua"),
  }
  local u, meta = count(paths)
  check(label .. ": result returned", u ~= nil)
  if not u then return end

  check(label .. ": once-referenced counts 1", u[p("assets/used.png")].count == 1)
  check(
    label .. ": twice-in-one-file plus once elsewhere counts 3 sites in 2 files",
    u[p("assets/twice.png")].count == 3 and #u[p("assets/twice.png")].files == 2
  )
  check(label .. ": unreferenced counts 0 with an entry", u[p("assets/orphan.png")].count == 0)
  check(
    label .. ": look-alike myshot.png does not count for shot.png",
    u[p("assets/shot.png")].count == 0
  )
  check(label .. ": url-encoded space is found", u[p("assets/my shot.png")].count == 1)
  local self_files = basename_set(u[p("assets/self.png")].files)
  check(
    label .. ": a link from a sibling note counts",
    u[p("assets/self.png")].count == 1 and self_files["note.md"]
  )
  check(label .. ": lua module referenced by require counts 1", u[p("lua/mod/util.lua")].count == 1)

  local doc = count({ p("doc.md") })
  check(label .. ": a file linking to itself is not counted", doc[p("doc.md")].count == 0)

  local refs_of_twice = u[p("assets/twice.png")].refs
  check(
    label .. ": refs are sorted by file then line",
    #refs_of_twice == 3
      and refs_of_twice[1].file <= refs_of_twice[2].file
      and (
        refs_of_twice[1].file ~= refs_of_twice[2].file
        or refs_of_twice[1].line <= refs_of_twice[2].line
      )
  )

  local bulk_paths = {}
  for i = 1, 400 do
    bulk_paths[i] =
      p(string.format("bulk/screenshot_%04d_with_a_rather_long_descriptive_name.png", i))
  end
  local b = count(bulk_paths)
  local referenced, total_sites = 0, 0
  for _, path in ipairs(bulk_paths) do
    if b[path].count > 0 then referenced = referenced + 1 end
    total_sites = total_sites + b[path].count
  end
  check(
    label .. ": 400-path sweep finds exactly the one referenced file",
    referenced == 1 and total_sites == 1 and b[p(bulk_ref)].count == 1
  )

  check(
    label .. ": meta lists the providers that ran",
    meta and vim.tbl_contains(meta.providers, "markdown") and meta.files_scanned > 0
  )

  local empty_done = false
  refs.usage.count({}, nil, function(by_path)
    empty_done = next(by_path) == nil
  end)
  check(label .. ": empty input answers immediately", empty_done)
end

run("ripgrep")

local real_executable = vim.fn.executable
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.executable = function(name)
  if name == "rg" then return 0 end
  return real_executable(name)
end
run("walk fallback")
vim.fn.executable = real_executable

-- ── refs.report ───────────────────────────────────────────────────────────────
local function run_report()
  print("\n== refs.report (:Filetree references) ==")

  -- The popup goes through `filetree.util.select`; record what it is handed
  -- instead of opening a float.
  local popup
  package.loaded["filetree.util.select"] = function(items, opts, on_choice)
    popup = { items = items, opts = opts, on_choice = on_choice }
  end
  local report = require("filetree.refs.report")

  local notes = {}
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = tostring(msg), level = level }
  end

  local function wait_for(pred)
    vim.wait(20000, pred, 10)
  end

  check(
    "report: an explicit path resolves to an absolute path",
    report.resolve_target(p("assets/used.png")) == p("assets/used.png")
  )

  -- popup view
  report.references(p("assets/twice.png"), { view = "popup" })
  wait_for(function()
    return popup ~= nil
  end)
  check("report: popup lists all 3 sites", popup and #popup.items == 3)
  check(
    "report: popup title carries the total and the file name",
    popup and popup.opts.prompt == "3 References: twice.png",
    popup and popup.opts.prompt
  )
  local line = popup and popup.opts.format_item(popup.items[1]) or ""
  check(
    "report: a popup row reads `relative/path:line  text`",
    line:match("^[%w%._/%-]+:%d+  ") ~= nil and line:find("twice.png", 1, true) ~= nil,
    line
  )
  check("report: popup is centred, not cursor-anchored", popup and popup.opts.relative == "editor")

  -- Enter jumps: the file opens at the line of the chosen site.
  local first = popup.items[1]
  popup.on_choice(first, 1)
  check(
    "report: <CR> opens the referencing file",
    vim.api.nvim_buf_get_name(0):gsub("\\", "/") == first.file
  )
  check("report: ...at the referencing line", vim.api.nvim_win_get_cursor(0)[1] == first.line)

  -- cancel does not jump
  local before = vim.api.nvim_buf_get_name(0)
  popup.on_choice(nil, nil)
  check("report: cancelling the popup stays put", vim.api.nvim_buf_get_name(0) == before)

  -- picker view (quickfix backend: no plugin needed)
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
    picker = "quickfix",
  })
  vim.fn.setqflist({}, "r")
  report.references(p("assets/twice.png"), { view = "picker" })
  wait_for(function()
    return #vim.fn.getqflist() > 0
  end)
  check("report: picker view fills the quickfix list with every site", #vim.fn.getqflist() == 3)
  check(
    "report: the list carries the total in its title",
    vim.fn.getqflist({ title = 1 }).title:find("3 References", 1, true) ~= nil
  )
  vim.cmd("cclose")

  -- configured default view
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
    report = { view = "picker" },
    picker = "quickfix",
  })
  vim.fn.setqflist({}, "r")
  report.references(p("assets/twice.png"))
  wait_for(function()
    return #vim.fn.getqflist() > 0
  end)
  check("report: refs.report.view = picker is honoured without a flag", #vim.fn.getqflist() == 3)
  vim.cmd("cclose")

  -- unreferenced file: a plain message, no list
  popup = nil
  notes = {}
  report.references(p("assets/orphan.png"), { view = "popup" })
  wait_for(function()
    return #notes > 0
  end)
  check("report: a file nobody references only notifies", popup == nil and #notes == 1)
  check(
    "report: ...with the zero count",
    notes[1] and notes[1].msg:find("0 references", 1, true) ~= nil,
    notes[1] and notes[1].msg
  )

  -- missing path
  notes = {}
  report.references(p("assets/nope.png"))
  check(
    "report: a missing file is reported",
    notes[1] and notes[1].msg:find("no such file", 1, true)
  )

  -- ── unused ──────────────────────────────────────────────────────────────────
  print("\n== refs.report (:Filetree refs unused) ==")
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
    picker = "quickfix",
  })

  -- The picker and the trash hand-off are recorded, not opened.
  local refs_picker = require("filetree.util.refs_picker")
  local real_pick = refs_picker.pick
  local picked
  ---@diagnostic disable-next-line: duplicate-set-field
  refs_picker.pick = function(entries, opts, on_confirm, on_cancel)
    picked = { entries = entries, opts = opts, on_confirm = on_confirm, on_cancel = on_cancel }
  end
  local trashed
  report.delete_paths = function(paths)
    trashed = paths
  end

  local function names(entries)
    local set = {}
    for _, e in ipairs(entries) do
      set[e.file:match("([^/\\]+)$")] = true
    end
    return set
  end

  notes = {}
  report.unused(work .. "/assets")
  wait_for(function()
    return picked ~= nil
  end)
  local n = picked and names(picked.entries) or {}
  check(
    "unused: exactly the two never-referenced images are offered",
    picked and #picked.entries == 2 and n["orphan.png"] and n["shot.png"]
  )
  check(
    "unused: referenced and twice-referenced images are not offered",
    not n["used.png"] and not n["twice.png"] and not n["my shot.png"] and not n["self.png"]
  )
  check("unused: the non-asset note.md is outside the default extension filter", not n["note.md"])
  check(
    "unused: the title states how many are unused",
    picked and picked.opts.title:find("^2 unused: ") ~= nil,
    picked and picked.opts.title
  )
  check(
    "unused: a row is labelled with its size, not a line number",
    picked and picked.entries[1].label:find("%(%d+ B%)") ~= nil,
    picked and picked.entries[1].label
  )
  local summary = notes[#notes] and notes[#notes].msg or ""
  check(
    "unused: the summary names the count and the scanned providers",
    summary:find("2 of 6", 1, true) ~= nil and summary:find("markdown", 1, true) ~= nil,
    summary
  )

  -- confirming hands exactly the selection to the trash
  picked.on_confirm({ picked.entries[1] })
  check(
    "unused: confirming trashes only the selected file",
    trashed and #trashed == 1 and trashed[1] == picked.entries[1].file
  )
  trashed = nil
  picked.on_cancel()
  check("unused: cancelling trashes nothing", trashed == nil)

  -- --all lifts the extension filter
  picked = nil
  report.unused(work .. "/assets", { all = true })
  wait_for(function()
    return picked ~= nil
  end)
  check(
    "unused: --all also offers the unreferenced note.md",
    picked and names(picked.entries)["note.md"] and #picked.entries == 3
  )

  -- the same report from `:Filetree references <dir>`
  picked = nil
  report.references(work .. "/assets")
  wait_for(function()
    return picked ~= nil
  end)
  check("unused: `references <dir>` runs the unused report", picked and #picked.entries == 2)

  -- a dead ripgrep must not turn every file into an "unused" one
  local real_system = vim.system
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(cmd, o, on_exit)
    if is_rg(cmd) and on_exit then
      on_exit({ code = 2, stdout = "", stderr = "boom" })
      return {}
    end
    return real_system(cmd, o, on_exit)
  end
  picked = nil
  report.unused(work .. "/assets")
  wait_for(function()
    return picked ~= nil
  end)
  vim.system = real_system
  check(
    "unused: a failing ripgrep falls back to the walk, results unchanged",
    picked and #picked.entries == 2 and names(picked.entries)["orphan.png"]
  )

  -- nothing to look at / wrong target
  vim.fn.mkdir(work .. "/empty", "p")
  notes = {}
  report.unused(work .. "/empty")
  check(
    "unused: an empty folder says so",
    notes[1] and notes[1].msg:find("No candidate files", 1, true) ~= nil
  )
  notes = {}
  report.unused(p("doc.md"))
  check(
    "unused: a file argument is refused and pointed at `references`",
    notes[1] and notes[1].msg:find("not a directory", 1, true) ~= nil
  )

  ---@diagnostic disable-next-line: duplicate-set-field
  refs_picker.pick = real_pick

  vim.notify = real_notify
  package.loaded["filetree.util.select"] = nil
end

run_report()

-- ── node_info: the References section of `I` ─────────────────────────────────
local function run_node_info()
  print("\n== node_info (References section) ==")
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
  })
  local node_info = require("filetree.features.ui.node_info")

  -- formatting (pure)
  check("node_info: no usage -> no section", #node_info.references_lines(nil) == 0)
  check(
    "node_info: zero references -> no section at all (not even a heading)",
    #node_info.references_lines({ count = 0, refs = {}, files = {} }) == 0
  )

  local u = (count({ p("assets/twice.png") }))[p("assets/twice.png")]
  local lines = node_info.references_lines(u, work)
  check("node_info: section starts with a blank separator line", lines[1] == "")
  check(
    "node_info: heading carries the total number of references",
    lines[2] == "  References (3)",
    lines[2]
  )
  check(
    "node_info: one row per file with its line numbers, two sites on one line shown once",
    #lines == 4 and lines[3]:find("doc.md:2$") ~= nil and lines[4]:find("other.md:1$") ~= nil,
    table.concat(lines, " | ")
  )

  local many = { count = 40, refs = {}, files = {} }
  for i = 1, 20 do
    for line = 1, 8 do
      many.refs[#many.refs + 1] = { file = work .. "/f" .. i .. ".md", line = line }
    end
  end
  local capped = node_info.references_lines(many, work)
  check(
    "node_info: long lists are cut with an `and N more` row",
    capped[#capped]:find("and 8 more file", 1, true) ~= nil and #capped == 2 + 12 + 1,
    capped[#capped]
  )
  check("node_info: per-file line numbers are cut too", capped[3]:find(",…$") ~= nil, capped[3])

  -- the popup itself
  local current
  local stub_adapter = {
    get_current_node = function()
      return current
    end,
  }
  node_info.setup({ keymap = false }, stub_adapter)

  local function viewer_text()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "filetree_node_info" and vim.api.nvim_buf_is_valid(b) then
        return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      end
    end
    return nil
  end
  local function show(path)
    node_info.close()
    current = { path = path, type = "file" }
    node_info.show_current()
  end

  show(p("assets/twice.png"))
  check("node_info: the popup opens at once", viewer_text() ~= nil)
  vim.wait(20000, function()
    local t = viewer_text()
    return t ~= nil and t:find("References (3)", 1, true) ~= nil
  end, 20)
  local text = viewer_text() or ""
  check(
    "node_info: the section is added once the scan answers",
    text:find("References (3)", 1, true) ~= nil and text:find("Path:", 1, true) ~= nil
  )

  -- second time: cached, the section is there synchronously
  show(p("assets/twice.png"))
  check(
    "node_info: a cached count is in the very first render",
    (viewer_text() or ""):find("References (3)", 1, true) ~= nil
  )

  -- unreferenced: nothing appended
  show(p("assets/orphan.png"))
  vim.wait(1500, function()
    return false
  end, 50)
  check(
    "node_info: an unreferenced file gets no References text at all",
    viewer_text() ~= nil and viewer_text():find("Reference", 1, true) == nil
  )

  -- opt-out and directories never scan
  local real_count = refs.usage.count
  local scans = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  refs.usage.count = function(...)
    scans = scans + 1
    return real_count(...)
  end
  node_info.setup({ keymap = false, references = false }, stub_adapter)
  show(p("assets/used.png"))
  check("node_info: references = false starts no scan", scans == 0)
  node_info.setup({ keymap = false }, stub_adapter)
  show(work .. "/assets")
  check("node_info: a directory starts no scan", scans == 0)
  show(p("assets/shot.png"))
  check("node_info: a plain file does start one", scans == 1)
  vim.wait(20000, function()
    return viewer_text() ~= nil
  end, 20)
  ---@diagnostic disable-next-line: duplicate-set-field
  refs.usage.count = real_count

  node_info.teardown()
end

run_node_info()

-- ── review fixes: incomplete sweeps, search root, cached root ─────────────────
local function run_review_fixes()
  print("\n== review fixes ==")
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
    picker = "quickfix",
  })
  local scan = require("filetree.refs.scan")
  local report = require("filetree.refs.report")
  local refs_picker = require("filetree.util.refs_picker")

  -- 1. the walk fallback reports a cut-short search
  local walk_real_executable = vim.fn.executable
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.executable = function(name)
    if name == "rg" then return 0 end
    return walk_real_executable(name)
  end
  local got, incomplete, done = nil, nil, false
  scan.candidates(
    work,
    { "twice.png" },
    { "md" },
    { scan = { max_files = 1, timeout_ms = 1000 } },
    function(files, inc)
      got, incomplete, done = files, inc, true
    end
  )
  vim.wait(5000, function()
    return done
  end, 10)
  check("fix: a walk capped by max_files says it is incomplete", done and incomplete == true)
  done, incomplete = false, nil
  scan.candidates(
    work,
    { "twice.png" },
    { "md" },
    { scan = { max_files = 5000, timeout_ms = 1000 } },
    function(files, inc)
      got, incomplete, done = files, inc, true
    end
  )
  vim.wait(5000, function()
    return done
  end, 10)
  check("fix: a complete walk does not", done and not incomplete and #got > 0)

  -- a walk whose progress indicator was cancelled (400 png files take the
  -- chunked path) reports a partial result as incomplete too
  local progress = require("filetree.util.progress")
  local real_create = progress.create
  ---@diagnostic disable-next-line: duplicate-set-field
  progress.create = function()
    return {
      cancelled = true,
      update = function() end,
      finish = function() end,
    }
  end
  done, incomplete = false, nil
  scan.candidates(
    work,
    { "screenshot" },
    { "png" },
    { scan = { max_files = 5000, timeout_ms = 1000 } },
    function(_, inc)
      incomplete, done = inc, true
    end
  )
  vim.wait(5000, function()
    return done
  end, 10)
  progress.create = real_create
  check("fix: a cancelled walk says it is incomplete", done and incomplete == true)

  -- a ripgrep run killed by `scan.timeout_ms` (vim.system reports 124) is not
  -- "no references" for an ordinary rename scan: the walk takes over, and a
  -- capped walk warns and flags the result incomplete
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.executable = function(name)
    if name == "rg" then return 1 end
    return walk_real_executable(name)
  end
  local timeout_real_system = vim.system
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(cmd, o, on_exit)
    if is_rg(cmd) and on_exit then
      on_exit({ code = 124, signal = 15, stdout = "", stderr = "" })
      return {}
    end
    return timeout_real_system(cmd, o, on_exit)
  end
  local timeout_warns = {}
  local timeout_real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    if level == vim.log.levels.WARN then timeout_warns[#timeout_warns + 1] = tostring(msg) end
  end
  done, incomplete, got = false, nil, nil
  scan.candidates(
    work,
    { "twice.png" },
    { "md" },
    { scan = { max_files = 5000, timeout_ms = 1 } },
    function(files, inc)
      got, incomplete, done = files, inc, true
    end
  )
  vim.wait(5000, function()
    return done
  end, 10)
  check(
    "fix: a timed-out ripgrep falls back to the walk instead of finding nothing",
    done and not incomplete and got and #got > 0 and #timeout_warns == 0,
    vim.inspect({ got = got, incomplete = incomplete, warns = timeout_warns })
  )
  local plan_refs, plan_incomplete
  done = false
  scan.run_plan({
    needles = { "twice.png" },
    extensions = { "md" },
    extract = function(file, line, text)
      if text:find("twice.png", 1, true) then return { { file = file, line = line } } end
    end,
  }, { root = work, cfg = { scan = { max_files = 1, timeout_ms = 1 } } }, function(r, inc)
    plan_refs, plan_incomplete, done = r, inc, true
  end)
  vim.wait(5000, function()
    return done
  end, 10)
  vim.system = timeout_real_system
  vim.notify = timeout_real_notify
  check(
    "fix: a timed-out ripgrep with a capped walk is flagged incomplete and warned about",
    done
      and plan_incomplete == true
      and plan_refs ~= nil
      and timeout_warns[1] ~= nil
      and timeout_warns[1]:find("timed out", 1, true) ~= nil
      and timeout_warns[1]:find("refs.scan.max_files", 1, true) ~= nil,
    vim.inspect({ incomplete = plan_incomplete, warns = timeout_warns })
  )

  -- every job of one prefetch shares a scan session: when all their ripgrep
  -- runs time out, the fallback lists the tree once and warns once
  local ftfs = require("filetree.util.fs")
  local real_collect = ftfs.collect_recursive
  local listings = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  ftfs.collect_recursive = function(...)
    listings = listings + 1
    return real_collect(...)
  end
  vim.system = function(cmd, o, on_exit)
    if is_rg(cmd) and on_exit then
      on_exit({ code = 124, signal = 15, stdout = "", stderr = "" })
      return {}
    end
    return timeout_real_system(cmd, o, on_exit)
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    if level == vim.log.levels.WARN then timeout_warns[#timeout_warns + 1] = tostring(msg) end
  end
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
    scan = { max_files = 1, timeout_ms = 1, respect_gitignore = false },
  })
  timeout_warns = {}
  local prefetched
  refs
    .prefetch(
      { p("assets/twice.png"), p("assets/used.png"), p("assets/shot.png") },
      { op = "move", mode = "ask", root = work }
    )
    .await(function(res)
      prefetched = res
    end)
  vim.wait(5000, function()
    return prefetched ~= nil
  end, 10)
  ftfs.collect_recursive = real_collect
  refs.setup({ providers = { markdown = true, lua = true, python = false, ts_js = false } })
  check(
    "fix: a prefetch whose ripgrep runs all time out lists the tree once and warns once",
    prefetched ~= nil and prefetched.incomplete == true and listings == 1 and #timeout_warns == 1,
    vim.inspect({ listings = listings, warns = timeout_warns })
  )

  -- rg exits 2 when it hit an error on the way (an unreadable file) but
  -- still printed its hits: those are kept, not thrown away for the walk
  local rg_hit = work .. "/only-rg-knows.md"
  vim.system = function(cmd, o, on_exit)
    if is_rg(cmd) and on_exit then
      on_exit({ code = 2, signal = 0, stdout = rg_hit .. "\n", stderr = "rg: locked.md: denied" })
      return {}
    end
    return timeout_real_system(cmd, o, on_exit)
  end
  done, got = false, nil
  scan.candidates(
    work,
    { "twice.png" },
    { "md" },
    { scan = { max_files = 5000, timeout_ms = 1000 } },
    function(files)
      got, done = files, true
    end
  )
  vim.wait(5000, function()
    return done
  end, 10)
  vim.system = timeout_real_system
  vim.notify = timeout_real_notify
  check(
    "fix: a ripgrep run with errors but hits keeps its hits",
    done and got and #got == 1 and got[1] == rg_hit,
    vim.inspect(got)
  )

  -- rg exits 2 without any hit when its only errors are files it could not open: a dangling
  -- symlink (Windows: "os error 3") is no reason to distrust the run and walk the whole tree,
  -- and a file that exists but could not be opened comes back as a candidate
  local function rg_with_stderr(stderr)
    vim.system = function(cmd, o, on_exit)
      if is_rg(cmd) and on_exit then
        on_exit({ code = 2, signal = 0, stdout = "", stderr = stderr })
        return {}
      end
      return timeout_real_system(cmd, o, on_exit)
    end
    local result, finished = nil, false
    scan.candidates(
      work,
      { "twice.png" },
      { "md" },
      { scan = { max_files = 5000, timeout_ms = 1000 } },
      function(files)
        result, finished = files, true
      end
    )
    vim.wait(5000, function()
      return finished
    end, 10)
    vim.system = timeout_real_system
    return result
  end
  local dangling = work .. "/gone-target.md"
  got = rg_with_stderr(
    "rg: "
      .. dangling
      .. ": The system cannot find the path specified. (os error 3)\nrg: "
      .. dangling
      .. ": No such file or directory (os error 2)\n"
  )
  check(
    "fix: a ripgrep run whose only errors are dangling links is a whole answer, not a walk",
    got ~= nil and #got == 0,
    vim.inspect(got)
  )
  local locked = work .. "/rg-locked.md"
  vim.fn.writefile({ "nothing here" }, locked)
  got = rg_with_stderr("rg: " .. locked .. ": Access is denied. (os error 5)")
  vim.fn.delete(locked)
  check(
    "fix: a file ripgrep could not open comes back as a candidate",
    got ~= nil and #got == 1 and got[1] == locked,
    vim.inspect(got)
  )
  got = rg_with_stderr("rg: " .. work .. ": Access is denied. (os error 5)")
  check(
    "a ripgrep run that could not read a directory still falls back to the walk",
    got ~= nil and #got > 0,
    vim.inspect(got)
  )
  vim.notify = timeout_real_notify
  vim.fn.executable = walk_real_executable

  -- a dangling symlink among the candidates (git lists one like a file) holds no references:
  -- it must not be reported as unreadable, which made every delete warn about it
  local link = work .. "/dangling-link.md"
  vim.fn.delete(link)
  local linked = vim.uv.fs_symlink(work .. "/no-such-target.md", link)
  if not linked then
    print("n/a  dangling symlink: no symlink privilege on this machine")
  else
    local real_candidates = scan.candidates
    ---@diagnostic disable-next-line: duplicate-set-field
    scan.candidates = function(_, _, _, _, cb)
      cb({ (link:gsub("\\", "/")) })
    end
    local plan_unreadable
    done = false
    scan.run_plan({
      needles = { "twice.png" },
      extensions = { "md" },
      extract = function()
        return nil
      end,
    }, { root = work, cfg = {} }, function(_, _, unreadable)
      plan_unreadable, done = unreadable, true
    end)
    scan.candidates = real_candidates
    vim.fn.delete(link)
    check(
      "fix: a dangling symlink candidate is not reported as unreadable",
      done and plan_unreadable ~= nil and #plan_unreadable == 0,
      vim.inspect(plan_unreadable)
    )
  end

  -- the walk honours scan.respect_gitignore inside a git work tree
  if walk_real_executable("git") == 1 then
    local gitproj = scratch_root .. "/gitproj"
    vim.fn.delete(gitproj, "rf")
    vim.fn.mkdir(gitproj .. "/out", "p")
    vim.fn.writefile({ "out/" }, gitproj .. "/.gitignore")
    vim.fn.writefile({ "![t](twice.png)" }, gitproj .. "/kept.md")
    vim.fn.writefile({ "![t](twice.png)" }, gitproj .. "/out/generated.md")
    vim.system({ "git", "init", "-q", gitproj }):wait()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "rg" then return 0 end
      return walk_real_executable(name)
    end
    local function walk(respect)
      local out, fin = nil, false
      scan.candidates(
        gitproj,
        { "twice.png" },
        { "md" },
        { scan = { max_files = 5000, timeout_ms = 5000, respect_gitignore = respect } },
        function(files)
          out, fin = files, true
        end
      )
      vim.wait(5000, function()
        return fin
      end, 10)
      return basename_set(out or {})
    end
    local honoured, all = walk(true), walk(false)

    -- fixture git calls: a failed step fails here, not as a walk regression
    local fixture_ok, fixture_err = true, nil
    local function fixture_git(args)
      if not fixture_ok then return end
      local res = vim
        .system(
          vim.list_extend({
            "git",
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=" .. scratch_root .. "/no-hooks",
            "-c",
            "protocol.file.allow=always",
          }, args),
          { text = true }
        )
        :wait()
      if res.code ~= 0 then
        fixture_ok, fixture_err = false, table.concat(args, " ") .. ": " .. (res.stderr or "")
      end
    end

    -- a nested repository: `git ls-files` lists it only as `modules/lib/`
    -- while untracked (an embedded clone) and only as its gitlink once added
    -- (a submodule); the walk descends into it either way (tracked and
    -- untracked files, with its own ignore rules)
    local sub = gitproj .. "/modules/lib"
    vim.fn.mkdir(sub, "p")
    vim.fn.writefile({ "![t](twice.png)" }, sub .. "/in-sub.md")
    vim.fn.writefile({ "skip.md" }, sub .. "/.gitignore")
    vim.fn.writefile({ "![t](twice.png)" }, sub .. "/skip.md")
    fixture_git({ "init", "-q", sub })
    fixture_git({ "-C", sub, "add", "in-sub.md", ".gitignore" })
    fixture_git({ "-C", sub, "commit", "-qm", "i" })
    vim.fn.writefile({ "![t](twice.png)" }, sub .. "/untracked-in-sub.md")
    local embedded = walk(true)
    fixture_git({ "-C", gitproj, "add", "modules/lib" })
    -- a second submodule whose repository git cannot open any more: the walk
    -- falls back to its plain files instead of dropping them
    local broken = gitproj .. "/modules/broken"
    vim.fn.mkdir(broken, "p")
    vim.fn.writefile({ "![t](twice.png)" }, broken .. "/in-broken.md")
    fixture_git({ "init", "-q", broken })
    fixture_git({ "-C", broken, "add", "in-broken.md" })
    fixture_git({ "-C", broken, "commit", "-qm", "i" })
    fixture_git({ "-C", gitproj, "add", "modules/broken" })
    if fixture_ok then
      vim.fn.delete(broken .. "/.git", "rf")
      vim.fn.writefile({ "gitdir: " .. scratch_root .. "/no-such-gitdir" }, broken .. "/.git")
    end
    local with_sub = walk(true)
    vim.fn.executable = walk_real_executable
    check(
      "fix: the walk leaves gitignored files out with respect_gitignore",
      honoured["kept.md"] and not honoured["generated.md"],
      vim.inspect(honoured)
    )
    check(
      "fix: the walk includes them with respect_gitignore = false",
      all["kept.md"] and all["generated.md"],
      vim.inspect(all)
    )
    check("fix: the submodule fixture is set up", fixture_ok, fixture_err)
    check(
      "fix: the walk finds references in an embedded repository not in the index",
      embedded["kept.md"]
        and embedded["in-sub.md"]
        and embedded["untracked-in-sub.md"]
        and not embedded["skip.md"],
      vim.inspect(embedded)
    )
    check(
      "fix: the walk keeps a submodule's files when git cannot list it",
      with_sub["in-broken.md"],
      vim.inspect(with_sub)
    )
    check(
      "fix: the walk finds references in submodule files, honouring the submodule's gitignore",
      with_sub["kept.md"]
        and with_sub["in-sub.md"]
        and with_sub["untracked-in-sub.md"]
        and not with_sub["skip.md"]
        and not with_sub["generated.md"],
      vim.inspect(with_sub)
    )

    -- tracked folders named like a PRUNE_DIRS entry (`vendor/`, `build/`),
    -- at the root and nested: the walk's git listing prunes them at any
    -- depth, and ripgrep's globs must prune the same folders, or the two
    -- candidate searches disagree
    -- The second project lives below an ancestor named `build/`: pruning
    -- applies inside the scan root only, never to the root's own path, while
    -- the suite's cwd is not the root.
    local function prune_fixture(pruneproj)
      vim.fn.delete(pruneproj, "rf")
      for _, d in ipairs({ "vendor", "pkg/vendor/deep", "pkg/build" }) do
        vim.fn.mkdir(pruneproj .. "/" .. d, "p")
      end
      for _, f in ipairs({ "top.md", "vendor.md", "vendor/root-vendor.md", "pkg/ok.md" }) do
        vim.fn.writefile({ "![t](twice.png)" }, pruneproj .. "/" .. f)
      end
      vim.fn.writefile({ "![t](twice.png)" }, pruneproj .. "/pkg/vendor/deep/nested-vendor.md")
      vim.fn.writefile({ "![t](twice.png)" }, pruneproj .. "/pkg/build/nested-build.md")
      fixture_ok, fixture_err = true, nil
      fixture_git({ "init", "-q", pruneproj })
      fixture_git({ "-C", pruneproj, "add", "." })
      return fixture_ok, fixture_err
    end
    local pruneproj = scratch_root .. "/pruneproj"
    local prune_ok, prune_err = prune_fixture(pruneproj)
    vim.fn.delete(scratch_root .. "/build", "rf")
    local nestedproj = scratch_root .. "/build/proj"
    local nested_ok, nested_err = prune_fixture(nestedproj)
    local function search(rg, search_root)
      search_root = search_root or pruneproj
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function(name)
        if name == "rg" and not rg then return 0 end
        return walk_real_executable(name)
      end
      local out, fin = nil, false
      scan.candidates(
        search_root,
        { "twice.png" },
        { "md" },
        { scan = { max_files = 5000, timeout_ms = 5000 } },
        function(files)
          out, fin = files, true
        end
      )
      vim.wait(5000, function()
        return fin
      end, 10)
      vim.fn.executable = walk_real_executable
      return basename_set(out or {})
    end
    local expected = { ["top.md"] = true, ["vendor.md"] = true, ["ok.md"] = true }
    check("fix: the pruned-folder fixture is set up", prune_ok, prune_err)
    local walked = search(false)
    check(
      "fix: the walk prunes tracked vendor/ and build/ folders at any depth",
      vim.deep_equal(walked, expected),
      vim.inspect(walked)
    )
    if walk_real_executable("rg") == 1 then
      local grepped = search(true)
      check(
        "fix: ripgrep prunes the same tracked folders as the walk",
        vim.deep_equal(grepped, walked),
        vim.inspect({ rg = grepped, walk = walked })
      )
    else
      print("  skip the ripgrep pruned-folder check (rg not found)")
    end
    check("fix: the project below a build/ ancestor is set up", nested_ok, nested_err)
    check(
      "fix: the suite's cwd is not the project below a build/ ancestor",
      not vim.startswith(vim.fn.getcwd():gsub("\\", "/"):lower(), nestedproj:lower()),
      vim.fn.getcwd()
    )
    local walked_nested = search(false, nestedproj)
    check(
      "fix: the walk keeps a project whose ancestor is named build/",
      vim.deep_equal(walked_nested, expected),
      vim.inspect(walked_nested)
    )
    if walk_real_executable("rg") == 1 then
      local grepped_nested = search(true, nestedproj)
      check(
        "fix: ripgrep keeps a project whose ancestor is named build/",
        vim.deep_equal(grepped_nested, expected),
        vim.inspect(grepped_nested)
      )
    else
      print("  skip the ripgrep pruned-folder check (rg not found)")
    end
  else
    print("  skip the walk gitignore checks (git not found)")
  end

  -- an incomplete candidate search must stop `refs unused` from offering anything
  local real_candidates = scan.candidates
  ---@diagnostic disable-next-line: duplicate-set-field
  scan.candidates = function(_, _, _, _, cb)
    cb({}, true)
  end
  local notes, picked = {}, nil
  local real_notify, real_pick = vim.notify, refs_picker.pick
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    notes[#notes + 1] = tostring(msg)
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  refs_picker.pick = function()
    picked = true
  end
  report.unused(work .. "/assets")
  vim.wait(5000, function()
    return #notes > 0
  end, 10)
  scan.candidates = real_candidates
  check(
    "fix: an incomplete search offers nothing for deletion",
    picked == nil and notes[#notes] and notes[#notes]:find("cut short", 1, true) ~= nil,
    notes[#notes]
  )

  -- 2. a folder outside the search root is refused, not reported as all-unused
  local outside = scratch_root .. "/outside"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "x" }, outside .. "/lonely.png")
  local old_cwd = vim.fn.getcwd()
  vim.fn.chdir(work)
  refs.setup({
    providers = { markdown = true, lua = true, python = false, ts_js = false },
    scan = { root = "cwd" },
  })
  notes, picked = {}, nil
  report.unused(outside)
  check(
    "fix: a folder outside the search root is refused",
    picked == nil and notes[1] and notes[1]:find("outside the search root", 1, true) ~= nil,
    notes[1]
  )
  vim.fn.chdir(old_cwd)
  refs.setup({ providers = { markdown = true, lua = true, python = false, ts_js = false } })
  vim.notify, refs_picker.pick = real_notify, real_pick

  -- 3. a cached render spells the rows exactly like the async one
  local node_info = require("filetree.features.ui.node_info")
  local current
  node_info.setup({ keymap = false }, {
    get_current_node = function()
      return current
    end,
  })
  local function viewer_text()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "filetree_node_info" and vim.api.nvim_buf_is_valid(b) then
        return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      end
    end
  end
  vim.fn.chdir(work .. "/assets")
  node_info.close()
  current = { path = p("assets/used.png"), type = "file" }
  node_info.show_current()
  vim.wait(20000, function()
    return (viewer_text() or ""):find("References (1)", 1, true) ~= nil
  end, 20)
  local first = viewer_text() or ""
  node_info.close()
  node_info.show_current()
  local second = viewer_text() or ""
  check(
    "fix: cached and async renders spell reference paths alike",
    first:find("References (1)", 1, true) ~= nil
      and first:match("References %(1%)\n(.-)$") == second:match("References %(1%)\n(.-)$"),
    first .. " ## " .. second
  )
  vim.fn.chdir(old_cwd)
  node_info.teardown()
end

run_review_fixes()

print(("\nrefs.usage: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
