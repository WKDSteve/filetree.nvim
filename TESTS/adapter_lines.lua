---@diagnostic disable: missing-fields
-- Test doubles/config here fill in only what the unit under test reads — a
-- complete feature config would be noise, not coverage.
-- adapter_lines.lua — the adapter's line->node mapping, against REAL trees.
--
-- `get_node_at_line(bufnr, linenr)` is what lets git_status, lsp_diagnostics,
-- size_info and copy_move's clipboard marker draw an extmark on a node's own
-- line. Getting it merely non-nil is not the bar: an off-by-one resolves every
-- line too, just to its neighbour, and the result is another file's git status
-- next to your file. So every assertion here resolves the line an extmark
-- actually sits on and compares it against the node that mark is about.
--
-- Unlike the other suites this one needs real backends: the whole point is the
-- mapping between what a backend DREW and what it reports, which a stub
-- adapter cannot have. It runs neo-tree and nvim-tree, and skips whichever is
-- not installed.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/adapter_lines.lua
--
-- $FILETREE_ADAPTER_LINES limits it to one backend, e.g. "nvimtree".
-- Exit 0 = all passed (or skipped), 1 = a check failed.

-- Line-buffered, so a run that has to be killed still shows how far it got.
io.stdout:setvbuf("line")
-- A leftover swap file from an interrupted run turns bufload() into a prompt
-- that a headless session can never answer -- it just hangs.
vim.opt.swapfile = false
vim.opt.shortmess:append("A")

local this = debug.getinfo(1, "S").source:sub(2)
local root_dir = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root_dir)
package.path = table.concat({
  root_dir .. "/lua/?.lua",
  root_dir .. "/lua/?/init.lua",
  package.path,
}, ";")

---Prepend the first candidate directory that looks like the plugin we want.
---@param env string[]  Env vars to honour first.
---@param names string[]  Directory names to look for beside the repo / in lazy.
---@param probe string  Path under the candidate that must exist.
---@return string?
local function resolve(env, names, probe)
  -- Looked up in, in this order: the named variables, $<NAME>_DIR ($NEO_TREE_NVIM_DIR, ...),
  -- <repo>/.deps/<name>, a sibling ../<name> (what CI checks out: neo-tree, nui and plenary at
  -- pinned commits), ../.test-plugins/<name>, stdpath("data")/lazy/<name>, and the lazy.nvim
  -- directory of the real editor (under testing.nvim the child's own stdpath is a sandbox) -- the
  -- places TESTS/minimal_init_sheet_neotree.lua searches. A checkout found on its own (not named
  -- by a variable) of what CI pins is used only at the pinned commit (TESTS/neotree_pins.lua).
  local candidates = {} ---@type { [1]: string, [2]: string? }[] dir, name to check against its pin
  for _, e in ipairs(env) do
    local v = vim.env[e]
    if v and v ~= "" then candidates[#candidates + 1] = { v } end
  end
  local parent = vim.fn.fnamemodify(root_dir, ":h")
  for _, name in ipairs(names) do
    local dir_env = vim.env[(name:upper():gsub("[^%w]", "_")) .. "_DIR"]
    if dir_env and dir_env ~= "" then candidates[#candidates + 1] = { dir_env } end
    candidates[#candidates + 1] = { root_dir .. "/.deps/" .. name, name }
    candidates[#candidates + 1] = { parent .. "/" .. name, name }
    candidates[#candidates + 1] = { parent .. "/.test-plugins/" .. name, name }
    candidates[#candidates + 1] = { vim.fn.stdpath("data") .. "/lazy/" .. name, name }
    local appdata, home = vim.env.LOCALAPPDATA, vim.env.HOME
    if appdata and appdata ~= "" then
      candidates[#candidates + 1] = { appdata .. "/nvim-data/lazy/" .. name, name }
    end
    if home and home ~= "" then
      candidates[#candidates + 1] = { home .. "/.local/share/nvim/lazy/" .. name, name }
    end
  end
  local pins = dofile(root_dir .. "/TESTS/neotree_pins.lua")
  local seen = {} -- stdpath("data")/lazy and ~/.local/share/nvim/lazy are often one directory
  for _, c in ipairs(candidates) do
    local norm = vim.fs.normalize(c[1])
    local found = not seen[norm] and vim.fn.isdirectory(norm .. "/" .. probe) == 1
    seen[norm] = true
    local off = found and c[2] and pins.off_pin(c[2], norm)
    if off then print("  note " .. off) end
    if found and not off then
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

resolve({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }, { "lib.nvim" }, "lua/lib")
resolve({ "FILETREE_UI_NVIM", "UI_NVIM_PATH" }, { "ui.nvim" }, "lua/ui")
resolve({}, { "plenary.nvim" }, "lua/plenary")
resolve({}, { "nvim-web-devicons" }, "lua/nvim-web-devicons")
local has_nui = resolve({}, { "nui.nvim" }, "lua/nui")
local has_neotree = resolve({ "FILETREE_NEOTREE" }, { "neo-tree.nvim" }, "lua/neo-tree")
local has_nvimtree = resolve({ "FILETREE_NVIMTREE" }, { "nvim-tree.lua" }, "lua/nvim-tree")

local passed, failed, skipped = 0, 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end

local function slash(p)
  return (tostring(p):gsub("\\", "/"))
end

---@return integer count  neo-tree windows on the current tab
local function neotree_windows()
  local n = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then n = n + 1 end
  end
  return n
end

---Close every neo-tree window on the current tab and keep it closed.
---A single close right after a `show` is not enough: neo-tree's debounced
---navigate from that show can still be pending, and when it fires it opens
---the window again -- and may focus it. The next suite then runs `:edit` from
---inside the tree window, where neo-tree's buffer-hijack guard moves the file
---into a NEW split, so "the editor window" that suite captured is not the one
---that ends up current (the `multitab` flake, roughly one run in five). Close,
---wait past the debounce, and repeat until no tree window comes back.
---@return boolean closed
local function close_neotree_settled()
  for _ = 1, 10 do
    pcall(require("neo-tree.command").execute, { action = "close", source = "filesystem" })
    vim.wait(400, function()
      return false
    end, 20)
    if neotree_windows() == 0 then return true end
  end
  return false
end

---A real little project, with a real git repo: one committed-then-modified
---file and one untracked file, both at the ROOT so no expansion is needed for
---git_status to have something to decorate.
---@param tag string
---@return string work
local function make_project(tag)
  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-lines-"
      .. tag
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/src", "p")
  vim.fn.writefile({ "-- committed" }, work .. "/src/a.lua")
  vim.fn.writefile({ "-- committed" }, work .. "/src/b.lua")
  vim.fn.writefile({ "# Readme" }, work .. "/README.md")

  local function git(...)
    vim.fn.system({ "git", "-C", work, ... })
  end
  git("init", "-q")
  git("config", "user.email", "t@t")
  git("config", "user.name", "t")
  git("add", "-A")
  git("commit", "-qm", "init")
  vim.fn.writefile({ "# Readme", "modified now" }, work .. "/README.md")
  vim.fn.writefile({ "brand new" }, work .. "/untracked.txt")
  return work
end

-- ── One backend's pass ───────────────────────────────────────────────────────

---@class BackendSpec
---@field name string             Adapter name, e.g. "neotree".
---@field open fun(work: string)  Open that backend's tree on `work`.
---@field native_filter_prompts boolean  Whether its native filter opens a UI prompt.

---@param spec BackendSpec
local function run_backend(spec)
  print(("\n%s\n== %s ==\n%s"):format(("="):rep(66), spec.name, ("="):rep(66)))

  local work = make_project(spec.name)
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  require("filetree").setup({
    adapter = spec.name,
    features = {
      git_status = { enabled = true },
      lsp_diagnostics = { enabled = true },
      size_info = { enabled = true, show_files = true, show_dirs = false },
      copy_move = { enabled = true },
      filter = { enabled = true },
      -- auto_reveal is on by default (opt-out) and reacts to BufEnter with
      -- its own debounced reveal/re-root -- see `run_neotree_multitab_redraw_check`'s
      -- setup() call for why every neo-tree suite in this file disables it
      -- explicitly rather than letting a stray debounced call from real
      -- editor buffers opened below outlive this pass.
      auto_reveal = { enabled = false },
    },
  })

  local adapter = require("filetree.adapter." .. spec.name)
  spec.open(work)
  vim.wait(6000, function()
    local b = adapter.get_bufnr()
    return b ~= nil and vim.api.nvim_buf_line_count(b) > 2
  end, 50)
  vim.wait(800, function()
    return false
  end, 50)

  local bufnr = adapter.get_bufnr()
  check(
    "the tree buffer exists",
    bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
    tostring(bufnr)
  )
  if not bufnr then return end

  ---Re-read the rendered buffer and resolve every line through the adapter.
  ---Done fresh per feature: both backends re-render on their own schedule (an
  ---async git fetch, a watcher event), so a snapshot taken earlier can
  ---describe a layout that no longer exists.
  local function snapshot()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local by_line = {}
    for i = 0, #lines - 1 do
      by_line[i] = adapter.get_node_at_line(bufnr, i)
    end
    return lines, by_line
  end

  local function marks(ns_name)
    local ns = vim.api.nvim_get_namespaces()[ns_name]
    if not ns then return {} end
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  end

  local function mark_text(m)
    local d = m[4] or {}
    local txt = ""
    for _, chunk in ipairs(d.virt_text or {}) do
      txt = txt .. chunk[1]
    end
    return txt ~= "" and txt or (d.hl_group or "?")
  end

  local function report(label, ms, by_line)
    for _, m in ipairs(ms) do
      local n = by_line[m[2]]
      print(
        string.format(
          "    %s line %2d: %-8s -> %s",
          label,
          m[2],
          mark_text(m),
          n and (n.type:sub(1, 3) .. " " .. vim.fn.fnamemodify(n.path, ":t")) or "nil"
        )
      )
    end
  end

  -- ── The mapping itself ─────────────────────────────────────────────────────
  local lines, by_line = snapshot()
  local resolved = 0
  for i = 0, #lines - 1 do
    if by_line[i] then resolved = resolved + 1 end
  end

  print("  -- rendered buffer (line: text -> resolved node) --")
  for i = 0, #lines - 1 do
    local n = by_line[i]
    print(
      string.format(
        "  [%02d] %-40s -> %s",
        i,
        (lines[i + 1] or ""):gsub("%s+$", ""),
        n and (n.type .. " " .. vim.fn.fnamemodify(n.path, ":t")) or "nil"
      )
    )
  end
  check("it resolved nodes for the rendered lines", resolved >= 4, "resolved=" .. resolved)

  -- `is_expanded` is a tri-state: true / false for a directory (open / closed),
  -- nil for a file. A closed directory used to come back nil (`x and false or
  -- nil`), indistinguishable from a file.
  local function expanded_contract(label, node)
    if node.type == "directory" then
      return type(node.is_expanded) == "boolean",
        label .. ": directory " .. node.name .. " has is_expanded=" .. tostring(node.is_expanded)
    end
    return node.is_expanded == nil,
      label .. ": file " .. node.name .. " has is_expanded=" .. tostring(node.is_expanded)
  end
  local dirs_seen, expanded_bad = 0, {}
  for _, n in pairs(by_line) do
    local ok_e, msg = expanded_contract("line", n)
    if n.type == "directory" then dirs_seen = dirs_seen + 1 end
    if not ok_e then expanded_bad[#expanded_bad + 1] = msg end
  end
  for _, n in ipairs(adapter.get_visible_nodes()) do
    local ok_e, msg = expanded_contract("visible", n)
    if not ok_e then expanded_bad[#expanded_bad + 1] = msg end
  end
  check(
    "is_expanded is boolean for directories and nil for files",
    #expanded_bad == 0,
    table.concat(expanded_bad, "; ")
  )
  check("...with directories actually in the tree", dirs_seen > 0, "dirs=" .. dirs_seen)
  local closed_dir = false
  for _, n in pairs(by_line) do
    if n.type == "directory" and n.is_expanded == false then closed_dir = true end
  end
  check("...and a closed directory reads as false, not nil", closed_dir)

  -- The mapping must be RIGHT, not merely non-nil. Both backends render the
  -- root line as a path label rather than the node's `name`, so line 0 is
  -- compared by path instead.
  local misaligned = {}
  for i = 0, #lines - 1 do
    local n = by_line[i]
    if n and i > 0 then
      local text = lines[i + 1] or ""
      if not text:find(n.name, 1, true) then
        misaligned[#misaligned + 1] = string.format("[%d] %q vs node %q", i, text, n.name)
      end
    end
  end
  check(
    "every resolved node's name is the text drawn on that line",
    #misaligned == 0,
    table.concat(misaligned, "; ")
  )
  check(
    "line 0 resolves to the tree's own root directory",
    by_line[0] ~= nil and by_line[0].type == "directory" and slash(by_line[0].path) == slash(work),
    by_line[0] and slash(by_line[0].path) or "nil"
  )

  -- A line the backend drew that is NOT a node must resolve to nil. neo-tree's
  -- `(N hidden items)` notice is one: it carries a synthetic id that looks
  -- enough like a path to fool a caller into statting it once per render and,
  -- through the same conversion, into aiming a delete at it.
  local notice_line
  for i = 0, #lines - 1 do
    local text = lines[i + 1] or ""
    if text:find("hidden item", 1, true) or text:find("empty folder", 1, true) then
      notice_line = i
      break
    end
  end
  if notice_line then
    check(
      "a notice line resolves to nil, not to a pseudo-node",
      by_line[notice_line] == nil,
      "line "
        .. notice_line
        .. " -> "
        .. tostring(by_line[notice_line] and by_line[notice_line].path)
    )
  else
    print("  --   (this backend rendered no notice line; nothing to check)")
    skipped = skipped + 1
  end

  -- `get_node_line` is the inverse: it answers "which line is this path on",
  -- and reveal/scroll_to_line steer the cursor with it. The two must agree, or
  -- revealing a file parks the cursor on its neighbour.
  local gl_bad = {}
  for i = 0, #lines - 1 do
    local n = by_line[i]
    if n then
      local got = adapter.get_node_line(n.path)
      if got ~= i + 1 then
        gl_bad[#gl_bad + 1] =
          string.format("%s is on line %d, get_node_line says %s", n.name, i + 1, tostring(got))
      end
    end
  end
  check(
    "get_node_line is the exact inverse of get_node_at_line",
    #gl_bad == 0,
    table.concat(gl_bad, "; ")
  )

  check(
    "a bufnr that is not the tree buffer resolves to nil",
    adapter.get_node_at_line(vim.api.nvim_create_buf(false, true), 0) == nil
  )
  check("a line past the end resolves to nil", adapter.get_node_at_line(bufnr, #lines + 50) == nil)

  -- Every decorating feature calls this once per rendered line, so a per-call
  -- cost in the tens of microseconds is tens of milliseconds per render on a
  -- large tree. It was exactly that on neo-tree until the conversion stopped
  -- routing through a helper that stats the filesystem for an is-directory
  -- flag it discards. The exact shape of that regression is pinned without a
  -- clock below (a lookup touches no filesystem); the timing check bounds the
  -- cost against a stat of the very path the lookup resolves, measured here
  -- and now, not against machine-to-machine variance. A fixed bound in
  -- microseconds was red under load (14-20 us in WSL with every core busy),
  -- and a stat ranges from ~1 us (Linux) to ~50 us (Windows). On Linux a
  -- lookup (~0.4-0.8 us) is close to a stat, hence twice a stat as the bound.
  -- Batches of both alternate and the cheapest batch of each counts, so a
  -- load spike in one batch does not decide it.
  local reps, batches = 2000, 7
  local stat_path = by_line[1] and by_line[1].path or work
  local function per_call_us(fn)
    local t0 = vim.uv.hrtime()
    for _ = 1, reps do
      fn()
    end
    return (vim.uv.hrtime() - t0) / reps / 1000
  end
  local function lookup()
    adapter.get_node_at_line(bufnr, 1)
  end
  local function stat()
    vim.uv.fs_stat(stat_path)
  end
  lookup()
  stat()
  local us, stat_us = math.huge, math.huge
  for _ = 1, batches do
    us = math.min(us, per_call_us(lookup))
    stat_us = math.min(stat_us, per_call_us(stat))
  end
  print(
    string.format(
      "    cost: %.2f us/call (~%.1f ms per 1000 lines x 4 features), a stat %.2f us",
      us,
      us * 4,
      stat_us
    )
  )
  check(
    "one lookup costs less than two filesystem stats of the same path, measured here",
    us < 2 * stat_us,
    ("%.2f us/call, a stat %.2f us"):format(us, stat_us)
  )
  -- The same regression without a clock: a lookup touches no filesystem.
  local fs_calls = {}
  local spied = {
    { vim.uv, "fs_stat" },
    { vim.uv, "fs_lstat" },
    { vim.uv, "fs_realpath" },
    { vim.fn, "isdirectory" },
    { vim.fn, "getftype" },
    { vim.fn, "filereadable" },
  }
  for _, s in ipairs(spied) do
    local orig = s[1][s[2]]
    s[3] = orig
    s[1][s[2]] = function(...)
      fs_calls[#fs_calls + 1] = s[2]
      return orig(...)
    end
  end
  lookup()
  for _, s in ipairs(spied) do
    s[1][s[2]] = s[3]
  end
  check(
    "one lookup touches no filesystem (no stat, no isdirectory)",
    #fs_calls == 0,
    table.concat(fs_calls, ", ")
  )

  local features = require("filetree.features")

  -- ── git_status ─────────────────────────────────────────────────────────────
  print("\n  -- git_status --")
  local _, git_status = features.load("git_status")
  git_status.refresh()
  -- refresh() runs git in the background and renders from its callback, so the
  -- first marks can describe a layout the backend has already replaced. Wait
  -- for the status to have landed, let the tree settle, then render once more
  -- against the buffer we are about to read.
  vim.wait(4000, function()
    return #marks("filetree_git_status") > 0
  end, 50)
  vim.wait(500, function()
    return false
  end, 50)
  git_status._render()
  local gm = marks("filetree_git_status")
  local _, g_by_line = snapshot()
  report("git", gm, g_by_line)
  check("git_status placed signs", #gm > 0)

  local dirty = { ["README.md"] = true, ["untracked.txt"] = true, ["src"] = true, [""] = true }
  local g_bad, g_files = {}, {}
  for _, m in ipairs(gm) do
    local n = g_by_line[m[2]]
    local rel = n and slash(n.path):gsub("^" .. vim.pesc(work) .. "/?", "") or "<nil>"
    g_files[#g_files + 1] = rel
    if not dirty[rel] then g_bad[#g_bad + 1] = string.format("line %d -> %s", m[2], rel) end
  end
  check(
    "every git sign sits on a line whose node really is dirty",
    #g_bad == 0,
    table.concat(g_bad, "; ")
  )
  check(
    "the modified file got a sign",
    vim.tbl_contains(g_files, "README.md"),
    table.concat(g_files, ", ")
  )
  check(
    "the untracked file got one too",
    vim.tbl_contains(g_files, "untracked.txt"),
    table.concat(g_files, ", ")
  )

  -- ── size_info ──────────────────────────────────────────────────────────────
  print("\n  -- size_info --")
  local _, size_info = features.load("size_info")
  size_info._render()
  local sm = marks("filetree_size_info")
  local _, s_by_line = snapshot()
  report("size", sm, s_by_line)
  check("size_info placed sizes", #sm > 0)

  local s_bad = {}
  for _, m in ipairs(sm) do
    local n = s_by_line[m[2]]
    -- " 9 B" for an on-disk 9-byte file: the number in the virt_text has to be
    -- the size of the file the adapter says is on that line, not a neighbour's.
    local want = n and vim.fn.getfsize(n.path) or -1
    local got = tonumber(mark_text(m):match("(%d+)%s*B") or "")
    if not n or got ~= want then
      s_bad[#s_bad + 1] = string.format(
        "line %d: drew %s, node %s is %d B",
        m[2],
        mark_text(m),
        n and vim.fn.fnamemodify(n.path, ":t") or "<nil>",
        want
      )
    end
  end
  check(
    "every size is the size of the file on that very line",
    #s_bad == 0,
    table.concat(s_bad, "; ")
  )

  -- ── lsp_diagnostics ────────────────────────────────────────────────────────
  print("\n  -- lsp_diagnostics --")
  -- No language server here, so publish diagnostics directly -- the feature
  -- reads vim.diagnostic.get(nil), not any particular client.
  local diag_buf = vim.fn.bufadd(work .. "/src/b.lua")
  vim.fn.bufload(diag_buf)
  vim.diagnostic.set(vim.api.nvim_create_namespace("live_test_diag_" .. spec.name), diag_buf, {
    { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom" },
  })
  local _, lsp_diagnostics = features.load("lsp_diagnostics")
  -- The counts are recomputed from a DiagnosticChanged autocmd, not inside
  -- _render -- so rendering in the same tick as vim.diagnostic.set draws nothing.
  vim.wait(800, function()
    return false
  end, 50)
  lsp_diagnostics._render()
  local dm = marks("filetree_lsp_diagnostics")
  local _, d_by_line = snapshot()
  report("diag", dm, d_by_line)
  check("lsp_diagnostics placed markers", #dm > 0)

  local d_bad, saw_file = {}, false
  local target = slash(work .. "/src/b.lua")
  for _, m in ipairs(dm) do
    local n = d_by_line[m[2]]
    local p = n and slash(n.path) or ""
    -- src/b.lua itself, or a directory containing it (the feature aggregates).
    local ok = p == target or (n and n.type == "directory" and target:sub(1, #p + 1) == p .. "/")
    if p == target then saw_file = true end
    if not ok then
      d_bad[#d_bad + 1] = string.format("line %d -> %s", m[2], p ~= "" and p or "<nil>")
    end
  end
  check(
    "every diagnostic marker is on b.lua or a directory above it",
    #d_bad == 0,
    table.concat(d_bad, "; ")
  )

  -- Only meaningful when the file is on screen at all: the two backends
  -- differ in whether opening the tree leaves `src/` expanded, and a marker
  -- cannot land on a line that was never drawn. The aggregation onto the
  -- parent directories above is checked either way.
  local b_rendered = false
  for _, n in pairs(d_by_line) do
    if n and slash(n.path) == target then b_rendered = true end
  end
  if b_rendered then
    check("the file with the diagnostic got its own marker", saw_file)
  else
    print("  --   (src/ is collapsed here, so b.lua has no line; parents checked above)")
    skipped = skipped + 1
  end

  -- ── copy_move clipboard marker ─────────────────────────────────────────────
  print("\n  -- copy_move clipboard marker --")
  local _, copy_move = features.load("copy_move")
  local c_lines, c_by_line = snapshot()
  local cut_node, cut_line
  for i = 0, #c_lines - 1 do
    local n = c_by_line[i]
    if n and n.type == "file" then
      cut_node, cut_line = n, i
      break
    end
  end
  local winid = adapter.get_winid()
  if winid and cut_line then
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { cut_line + 1, 0 })
  end
  copy_move.stage_cut()
  local cm = marks("filetree_copy_move")
  local _, c2_by_line = snapshot()
  report("cut", cm, c2_by_line)
  check("copy_move drew the clipboard marker", #cm > 0)
  check(
    "the marker is on the node that was actually cut",
    #cm == 1 and c2_by_line[cm[1][2]] ~= nil and c2_by_line[cm[1][2]].path == cut_node.path,
    string.format(
      "cut %s, marker on %s",
      cut_node and vim.fn.fnamemodify(cut_node.path, ":t") or "?",
      #cm > 0 and c2_by_line[cm[1][2]] and vim.fn.fnamemodify(c2_by_line[cm[1][2]].path, ":t")
        or "?"
    )
  )
  copy_move.clear()

  -- ── filter ─────────────────────────────────────────────────────────────────
  print("\n  -- filter (native) --")
  local _, filter = features.load("filter")

  local function rendered()
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end

  -- The native path has to actually narrow the listing. Both branches used to
  -- call an API that no longer exists (neo-tree) or that takes no argument and
  -- prompts (nvim-tree), and reported success either way -- so `/` did nothing
  -- at all and the dim fallback was never reached. "Nothing was dimmed" alone
  -- would still pass for that; the listing itself has to change.
  check(
    "the unfiltered listing shows untracked.txt",
    rendered():find("untracked.txt", 1, true) ~= nil
  )

  filter.apply("a.lua")
  vim.wait(2000, function()
    return rendered():find("untracked.txt", 1, true) == nil
  end, 50)
  check(
    "the backend's own filter really narrowed the listing",
    rendered():find("untracked.txt", 1, true) == nil,
    rendered()
  )
  check(
    "the native filter handled it, so nothing was dimmed",
    #marks("filetree_filter") == 0,
    "dimmed " .. #marks("filetree_filter") .. " line(s)"
  )

  filter.clear()
  vim.wait(2000, function()
    return rendered():find("untracked.txt", 1, true) ~= nil
  end, 50)
  check(
    "clearing the filter restores the listing",
    rendered():find("untracked.txt", 1, true) ~= nil,
    rendered()
  )

  print("\n  -- filter (dim fallback) --")
  -- Force the fallback to exercise the branch that uses get_node_at_line at
  -- all. try_native_filter dispatches on _adapter.name, so renaming the
  -- adapter for one call is exactly the "backend with no native filter" case,
  -- which is what netrw/oil/mini.files are.
  local real_name = adapter.name
  adapter.name = "no-native-filter"
  filter.apply("a.lua")
  adapter.name = real_name

  local fm = marks("filetree_filter")
  local f_lines, f_by_line = snapshot()
  report("dim", fm, f_by_line)
  check("with the native filter unavailable, the dim fallback runs", #fm > 0)

  local dimmed = {}
  for _, m in ipairs(fm) do
    dimmed[m[2]] = true
  end
  local f_bad = {}
  for i = 0, #f_lines - 1 do
    local n = f_by_line[i]
    local matches = n ~= nil and n.name:lower():find("a.lua", 1, true) ~= nil
    if matches and dimmed[i] then
      f_bad[#f_bad + 1] = string.format("line %d (%s) matched but was dimmed", i, n.name)
    elseif n and not matches and not dimmed[i] then
      f_bad[#f_bad + 1] = string.format("line %d (%s) did not match but was not dimmed", i, n.name)
    end
  end
  check("exactly the non-matching node lines were dimmed", #f_bad == 0, table.concat(f_bad, "; "))
  filter.clear()

  pcall(adapter.close)
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── nvim-tree only: a live-filter prompt must never resolve to the root ────
-- `core.get_nodes_starting_line()` bumps its returned offset by ONE for EACH
-- of two independent, additive reasons: the root-folder label being shown,
-- and the live filter/search prompt being active. With `root_folder_label =
-- false` and an active live filter, that produces the exact same number
-- (`start == 2`) as "label shown, no filter" -- so a naive `start > 1` check
-- cannot tell the two states apart, and used to stamp the root directory node
-- onto line 1 even though line 1 is really nvim-tree's own "[FILTER]: …"
-- prompt, not a node. Every decorating feature that walks every rendered
-- line (git_status/lsp_diagnostics/size_info/copy_move) would then attach
-- the root's data to the filter-prompt line.
local function run_nvimtree_filter_line_check()
  print("\n== nvim-tree: the live-filter prompt line resolves to nil, not the root ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-nvimtree-filterline"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/src", "p")
  vim.fn.writefile({ "aaa" }, work .. "/src/a.lua")
  vim.fn.writefile({ "bbb" }, work .. "/src/b.lua")
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  -- root_folder_label = false is the reported precondition -- without it,
  -- get_nodes_starting_line's two reasons for bumping the offset don't
  -- collide, and the pre-fix code already handled this case correctly.
  require("nvim-tree").setup({
    hijack_netrw = false,
    update_focused_file = { enable = false },
    renderer = { group_empty = true, root_folder_label = false },
    view = { width = 40 },
  })

  local adapter = require("filetree.adapter.nvimtree")
  require("nvim-tree.api").tree.open({ path = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    return b ~= nil and vim.api.nvim_buf_line_count(b) > 1
  end, 50)
  local bufnr = adapter.get_bufnr()
  check("filter-line: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then return end

  check(
    "filter-line: line 0 already resolves to a real node before any filter",
    adapter.get_node_at_line(bufnr, 0) ~= nil
  )

  -- Drive nvim-tree's OWN live filter directly -- exactly the mechanism
  -- filter/init.lua's nvimtree_filter() uses, so this is the real trigger
  -- path, not a synthetic one.
  local core = require("nvim-tree.core")
  local explorer = core.get_explorer()
  explorer.live_filter.filter = "a"
  explorer.live_filter:apply_filter()
  if explorer.renderer and explorer.renderer.draw then explorer.renderer:draw() end
  vim.wait(500, function()
    return false
  end, 20)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  check(
    "filter-line: line 0 is really nvim-tree's own filter prompt now",
    (lines[1] or ""):find("FILTER", 1, true) ~= nil,
    lines[1]
  )
  local resolved = adapter.get_node_at_line(bufnr, 0)
  check(
    "filter-line: it resolves to nil -- not the root directory node",
    resolved == nil,
    resolved and vim.inspect(resolved) or "nil"
  )
  check(
    "filter-line: get_visible_nodes carries no phantom root entry either",
    (function()
      for _, n in ipairs(adapter.get_visible_nodes()) do
        if n.line_number == 1 and n.type == "directory" and n.path == work then return false end
      end
      return true
    end)()
  )

  -- And the legitimate case must still work: root label genuinely shown, no
  -- filter -- line 0 must still resolve to the root.
  explorer.live_filter.filter = nil
  explorer.live_filter:apply_filter()
  local ok_cfg, cfg = pcall(require, "nvim-tree.config")
  if ok_cfg then cfg.g.renderer.root_folder_label = nil end
  if explorer.renderer and explorer.renderer.draw then explorer.renderer:draw() end
  vim.wait(300, function()
    return false
  end, 20)
  local root_node = adapter.get_node_at_line(bufnr, 0)
  check(
    "filter-line: with the root label genuinely shown, line 0 is still the root",
    root_node ~= nil and root_node.type == "directory",
    root_node and vim.inspect(root_node) or "nil"
  )

  pcall(adapter.close)
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── neo-tree only: a clear-then-retype race must not corrupt the restore ───
-- `filter/init.lua`'s neotree_filter() re-derives the pre-search expansion
-- snapshot from `state.tree` whenever it looks unset -- but neo-tree's own
-- `reset_search` nils `state.open_folders_before_search` SYNCHRONOUSLY while
-- its re-render (`M.navigate`) is debounced ~100ms. A clear immediately
-- followed by a new query used to land inside that window and re-capture the
-- baseline from a stale/still-filtered tree instead of the true pre-search
-- state, so the eventual restore reopened only what the search had happened
-- to still show, silently dropping whatever else the user had expanded
-- before searching at all.
local function run_neotree_filter_race_check()
  print("\n== neo-tree: a clear-then-retype race must not corrupt the restore ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-filterrace"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work .. "/dirA", "p")
  vim.fn.mkdir(work .. "/dirB", "p")
  vim.fn.writefile({ "aaa" }, work .. "/dirA/xray.lua")
  vim.fn.writefile({ "bbb" }, work .. "/dirB/yankee.lua")
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  -- Start from one tab and no tree. Earlier phases of this file leave trees
  -- open on other tabs and other projects, and the filter feature (like
  -- `mgr.get_state()` below) resolves "the tree" through the CURRENT tab: with a
  -- stale tab state in play the fixture is rendered by one state while the
  -- feature drives another, and the baseline check reads a tree that is not the
  -- one on screen. It only showed up as a coin flip once startup timing shifted.
  pcall(vim.cmd, "tabonly")
  close_neotree_settled()

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal disabled -- see `run_neotree_multitab_redraw_check`'s
    -- setup() call for why every neo-tree suite in this file does this.
    features = { filter = { enabled = true }, auto_reveal = { enabled = false } },
  })

  local adapter = require("filetree.adapter.neotree")
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  -- A prior run_backend() pass left the tree open on a DIFFERENT, already
  -- multi-line project -- a bare line-count wait would pass on that stale
  -- buffer before the navigate to `work` ever re-renders. Wait for this
  -- fixture's own marker instead.
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("dirA", 1, true) ~= nil and text:find("dirB", 1, true) ~= nil
  end, 50)
  local bufnr = adapter.get_bufnr()
  check("filter-race: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then return end

  local mgr = require("neo-tree.sources.manager")
  local renderer = require("neo-tree.ui.renderer")
  local state = mgr.get_state("filesystem")

  -- Run the race with CI's timing on every machine. neo-tree looks its find
  -- command up on EVERY search (`vim.fn.executable` of fdfind, fd, ... over
  -- $PATH; the result lands on that search's options, not on the state). On a
  -- long $PATH (Windows, or WSL with the Windows $PATH appended) these
  -- lookups cost 100-160 ms per search, so the clear below came after neo-tree's
  -- 100 ms navigate debounce had run out, and the bug this pins stayed hidden
  -- on every machine but the hosted runners (run 43420079289: "after the
  -- clear only the root is expanded" on all three). Resolved once, as neo-tree
  -- would, the search starts within milliseconds, as it does there. Done here,
  -- before the settle waits below: neo-tree's debounce timer counts from the
  -- event loop's last tick, so every millisecond of work between that tick and
  -- the race shortens its window.
  if not state.find_command then
    for _, cmd in ipairs({ "fdfind", "fd", "find", "where" }) do
      local usable = vim.fn.executable(cmd) == 1
        and not (cmd == "find" and vim.fn.has("win32") == 1)
      if usable then
        state.find_command = cmd
        break
      end
    end
  end

  -- neo-tree node ids are native paths (backslashes on Windows), not the
  -- forward-slash form `work` is built from -- resolve them from what the
  -- adapter actually rendered instead of hand-building candidate strings.
  local function find_dir_path(name)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 0, #lines - 1 do
      local n = adapter.get_node_at_line(bufnr, i)
      if n and n.type == "directory" and n.name == name then return n.path end
    end
    return nil
  end

  local dirA_native, dirB_native = find_dir_path("dirA"), find_dir_path("dirB")
  check(
    "filter-race: both dirs were found in the rendered tree",
    dirA_native and dirB_native ~= nil
  )
  if not (dirA_native and dirB_native) then return end

  local function expanded_set()
    local set = {}
    for _, id in ipairs(renderer.get_expanded_nodes(state.tree)) do
      set[slash(id)] = true
    end
    return set
  end
  local dirA, dirB = slash(dirA_native), slash(dirB_native)

  -- Expand both dirs before any search -- this is the baseline the whole
  -- race is about preserving. neo-tree loads a directory's children with an
  -- asynchronous fs scan and rebuilds `state.tree` when it lands, which can
  -- swallow an `expand()` made in between; a fixed sleep after one attempt is
  -- therefore a coin flip on a loaded machine (it was stable until startup work
  -- elsewhere shifted the timing). Expand again until both are seen open,
  -- bounded, and only then read the baseline.
  vim.wait(4000, function()
    for _, p in ipairs({ dirA_native, dirB_native }) do
      local node = state.tree:get_node(p)
      if node then node:expand() end
    end
    renderer.redraw(state)
    local set = expanded_set()
    return (set[dirA] and set[dirB]) or false
  end, 200)
  vim.wait(300, function()
    return false
  end, 20)

  local before = expanded_set()
  check(
    "filter-race: both dirs are genuinely expanded before searching",
    before[dirA] and before[dirB],
    vim.inspect(before)
  )

  local filter = require("filetree.features.search.filter")

  -- Drive the actual race. `apply("xray")` captures the true, uncorrupted
  -- baseline (both dirs, since nothing has narrowed the tree yet). Real
  -- neo-tree narrows `state.tree` for a search asynchronously (a live fs
  -- scan, ~300-400ms even for two tiny dirs) -- waiting for that would make
  -- this check both slow and timing-flaky across machines. Collapsing dirB
  -- by hand right after the capture reproduces the exact precondition the
  -- bug depended on (the tree looking narrower than the true baseline at the
  -- moment of the next capture) deterministically, without the wait.
  filter.apply("xray")
  local node_b = state.tree:get_node(dirB_native)
  if node_b then node_b:collapse() end
  filter.apply("")
  filter.apply("yankee")
  filter.apply("")

  -- Let neo-tree's debounced navigate (and this fix's own 150ms deferred
  -- release) actually settle before reading the result.
  vim.wait(1000, function()
    return false
  end, 50)

  local after = expanded_set()
  check(
    "filter-race: dirA survives the race and is still expanded after the final clear",
    after[dirA] == true,
    vim.inspect(after)
  )
  check(
    "filter-race: dirB ALSO survives -- the corrupted-capture bug would have "
      .. "dropped it (only what the intermediate 'xray' filter still showed "
      .. "would have been re-captured)",
    after[dirB] == true,
    vim.inspect(after)
  )

  -- The fix must not leak the snapshot forever either: collapse dirB, start a
  -- genuinely new, independent filter session, and confirm a clear restores
  -- the CURRENT state (dirA open, dirB collapsed) rather than the stale one
  -- the race above captured.
  local nodeB = state.tree:get_node(dirB_native)
  if nodeB then nodeB:collapse() end
  renderer.redraw(state)
  vim.wait(300, function()
    return false
  end, 20)

  filter.apply("xray")
  vim.wait(300, function()
    return false
  end, 20)
  filter.apply("")
  vim.wait(1000, function()
    return false
  end, 50)

  local settled = expanded_set()
  check(
    "filter-race: the snapshot does not stick forever -- a later, unrelated "
      .. "session restores the CURRENT state (dirB stays collapsed), not the "
      .. "earlier race's",
    settled[dirA] == true and settled[dirB] ~= true,
    vim.inspect(settled)
  )

  filter.teardown()
  pcall(adapter.close)
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── neo-tree only: the filter drives the tree the adapter resolves ─────────
-- `neotree_filter` used to look its state up through the ambient
-- `mgr.get_state("filesystem")`, i.e. the CURRENT tab's state, while every
-- other part of the feature (the dim fallback, the input's position) and the
-- adapter itself resolve the tree that is actually live. With the tree on one
-- tab and `:Filetree filter` run from another, treeless one, the filter then
-- created an empty placeholder state for the current tab (which nothing ever
-- disposes), set the pattern on that, reported success -- and the visible tree
-- was never filtered, with no dim fallback either.
local function run_neotree_filter_other_tab_check()
  print("\n== neo-tree: the filter drives the live tree, not the current tab's state ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-filter-tab"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "a" }, work .. "/alpha.lua")
  vim.fn.writefile({ "b" }, work .. "/bravo.lua")
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  pcall(vim.cmd, "tabonly")
  close_neotree_settled()

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal disabled -- see `run_neotree_multitab_redraw_check`'s
    -- setup() call for why every neo-tree suite in this file does this.
    features = { filter = { enabled = true }, auto_reveal = { enabled = false } },
  })

  local mgr = require("neo-tree.sources.manager")
  local filter = require("filetree.features.search.filter")

  local tab_a = vim.api.nvim_get_current_tabpage()
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  ---@return string
  local function tree_text()
    local state = mgr.get_state("filesystem", tab_a)
    local win = state and state.winid
    if not (win and vim.api.nvim_win_is_valid(win)) then return "" end
    return table.concat(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
      "\n"
    )
  end
  vim.wait(4000, function()
    local text = tree_text()
    return text:find("alpha.lua", 1, true) ~= nil and text:find("bravo.lua", 1, true) ~= nil
  end, 50)
  check("filter-tab: tab A's tree shows both files", tree_text():find("bravo.lua", 1, true) ~= nil)

  -- A second tab without a tree is current; the filter is applied from there.
  vim.cmd("tabnew")
  local tab_b = vim.api.nvim_get_current_tabpage()
  filter.apply("alpha")
  vim.wait(3000, function()
    return tree_text():find("bravo.lua", 1, true) == nil
  end, 50)

  local state_a = mgr.get_state("filesystem", tab_a)
  check(
    "filter-tab: the pattern landed on tab A's live tree",
    state_a.search_pattern == "alpha",
    tostring(state_a.search_pattern)
  )
  check(
    "filter-tab: tab A's tree really narrowed (bravo.lua is gone)",
    tree_text():find("bravo.lua", 1, true) == nil and tree_text():find("alpha.lua", 1, true) ~= nil,
    tree_text()
  )
  local placeholder = false
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "filesystem" and s.tabid == tab_b then placeholder = true end
  end
  check("filter-tab: no placeholder state was created for the treeless tab", not placeholder)

  filter.clear()
  vim.wait(3000, function()
    return tree_text():find("bravo.lua", 1, true) ~= nil
  end, 50)
  check(
    "filter-tab: clearing from the treeless tab restores tab A's listing",
    state_a.search_pattern == nil and tree_text():find("bravo.lua", 1, true) ~= nil,
    tostring(state_a.search_pattern)
  )

  filter.teardown()
  pcall(vim.cmd, "tabonly")
  close_neotree_settled()
end

-- ── neo-tree only: filtering a closed tree must not open it ────────────────
-- With the tree closed, the adapter still resolves the current tab's tracked
-- state, and neo-tree opens a new tree window for any navigate on a state
-- whose window is gone. `neotree_filter` navigated it unconditionally (the
-- apply's own `manager.navigate`, the clear's `reset_search(state, true)`), so
-- `:Filetree filter foo`, `:Filetree filter clear`, `tree_reset` and the
-- teardown of a re-`setup()` popped the tree open on the current tab.
-- `manager.refresh`, which the apply used before, only marks such a state dirty.
local function run_neotree_filter_closed_tree_check()
  print("\n== neo-tree: filtering a closed tree does not open it ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-filter-closed"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "a" }, work .. "/alpha.lua")
  vim.fn.writefile({ "b" }, work .. "/bravo.lua")
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  pcall(vim.cmd, "tabonly")
  close_neotree_settled()

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal disabled -- see `run_neotree_multitab_redraw_check`'s
    -- setup() call for why every neo-tree suite in this file does this.
    features = { filter = { enabled = true }, auto_reveal = { enabled = false } },
  })

  local mgr = require("neo-tree.sources.manager")
  local filter = require("filetree.features.search.filter")
  local tab = vim.api.nvim_get_current_tabpage()

  ---@return integer count  neo-tree windows on the current tab
  local function tree_windows()
    local n = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then n = n + 1 end
    end
    return n
  end

  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local state = mgr.get_state("filesystem", tab)
    local win = state and state.winid
    if not (win and vim.api.nvim_win_is_valid(win)) then return false end
    local text =
      table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    return text:find("bravo.lua", 1, true) ~= nil
  end, 50)
  -- Let neo-tree's debounced navigate settle, or the close below races it and
  -- the pending render reopens the window by itself.
  vim.wait(1000, function()
    return false
  end, 50)
  require("filetree.adapter.neotree").close()
  vim.wait(1000, function()
    return tree_windows() == 0
  end, 50)
  check(
    "filter-closed: the tree is closed before filtering",
    tree_windows() == 0,
    tostring(tree_windows())
  )

  filter.apply("alpha")
  vim.wait(1000, function()
    return tree_windows() > 0
  end, 50)
  local state = mgr.get_state("filesystem", tab)
  check(
    "filter-closed: applying a query leaves the closed tree closed",
    tree_windows() == 0,
    tostring(tree_windows())
  )
  check(
    "filter-closed: the closed tree keeps the pattern for its next open",
    state.search_pattern == "alpha",
    tostring(state.search_pattern)
  )

  filter.clear()
  vim.wait(1000, function()
    return tree_windows() > 0
  end, 50)
  check(
    "filter-closed: clearing leaves the closed tree closed",
    tree_windows() == 0,
    tostring(tree_windows())
  )
  check(
    "filter-closed: the clear still drops the pattern",
    state.search_pattern == nil,
    tostring(state.search_pattern)
  )

  filter.teardown()
  close_neotree_settled()
end

-- ── neo-tree only: link_marker must survive neo-tree's own async re-render ──
-- A symlink's sign, drawn as an extmark on the very first `BufEnter`-driven
-- render, used to be silently wiped moments later: neo-tree's filesystem
-- source scans and draws asynchronously (`fs_scan.lua`), and its own
-- follow-up full-content redraw -- a replace, not an incremental edit --
-- does not carry over an extmark placed on the render before it. Fixed by
-- also subscribing to the neo-tree adapter's `on_render` bridge (see
-- `adapter/neotree.lua`), the same mechanism `marks`' checkmarks already
-- rely on for the identical reason. Only a REAL neo-tree open on a REAL
-- symlink can catch this -- a stub adapter calling `_render()` once,
-- synchronously, has no backend-initiated re-render to race against.
local function run_neotree_link_marker_check()
  print("\n== neo-tree: link_marker survives neo-tree's own async re-render ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-linkmarker"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "hi" }, work .. "/plain.txt")

  local link_ok = (vim.uv or vim.loop).fs_symlink(work .. "/plain.txt", work .. "/a_link.txt")
  if not link_ok then
    print("  note no permission to create a real symlink here -- skipping")
    return
  end

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal disabled -- see `run_neotree_multitab_redraw_check`'s
    -- setup() call for why every neo-tree suite in this file does this.
    features = { link_marker = { enabled = true }, auto_reveal = { enabled = false } },
  })

  local adapter = require("filetree.adapter.neotree")
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("a_link.txt", 1, true) ~= nil
  end, 50)

  local bufnr = adapter.get_bufnr()
  check("link_marker: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then return end

  -- Give the async scan's own follow-up redraw time to actually happen --
  -- reproducing it, not dodging it, is the whole point of this test.
  vim.wait(1000, function()
    return false
  end, 50)

  local function marker_line()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 0, #lines - 1 do
      local n = adapter.get_node_at_line(bufnr, i)
      if n and n.name == "a_link.txt" then return i end
    end
    return nil
  end

  local line = marker_line()
  check("link_marker: the symlinked file is in the rendered tree", line ~= nil)
  if line then
    -- Read the `link_marker` namespace specifically, not "any extmark on the
    -- line" -- `size_info` et al. may also have drawn something there.
    local ns = vim.api.nvim_get_namespaces()["filetree_link_marker"]
    local ms = ns
        and vim.api.nvim_buf_get_extmarks(bufnr, ns, { line, 0 }, { line, -1 }, { details = true })
      or {}
    local vt = ""
    for _, m in ipairs(ms) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        vt = vt .. chunk[1]
      end
    end
    check(
      "link_marker: the symlink sign is still there after neo-tree's own settling redraw",
      vt:find("⇢", 1, true) ~= nil,
      vt
    )
  end

  require("filetree.features.ui.link_marker").teardown()
  pcall(adapter.close)
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── neo-tree only: get_visible_nodes(filter, bufnr) must not silently
-- substitute the ambient tree when `bufnr` itself fails to resolve ─────────
-- Root cause: `bufnr and state_for_bufnr(bufnr) or get_state()` is the classic
-- Lua `and/or` pitfall -- when a REAL bufnr is given but `state_for_bufnr(bufnr)`
-- returns nil (a normal, reachable outcome: nothing shows that bufnr as a
-- live tree window), the expression falls through to the ambient `get_state()`
-- and returns a possibly UNRELATED tree's nodes instead of `{}`, inconsistent
-- with the sibling `get_node_at_line`, which correctly returns nil for the
-- identical resolution failure. Only a real neo-tree with a real, currently
-- open tree reproduces this: the bug requires an ambient tree to exist for
-- the fallback to wrongly substitute.
local function run_neotree_get_visible_nodes_bufnr_check()
  print("\n== neo-tree: get_visible_nodes(filter, bufnr) never falls back to the ambient tree ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-getvisiblebufnr"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "hi" }, work .. "/plain.txt")

  require("filetree").setup({
    adapter = "neotree",
    features = { auto_reveal = { enabled = false } },
  })

  local adapter = require("filetree.adapter.neotree")
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("plain.txt", 1, true) ~= nil
  end, 50)

  local tree_bufnr = adapter.get_bufnr()
  check("get-visible-bufnr: the tree buffer exists", tree_bufnr ~= nil, tostring(tree_bufnr))
  if not tree_bufnr then
    pcall(adapter.close)
    return
  end

  -- The ambient tree is genuinely non-empty -- otherwise a wrong fallback to
  -- it would be indistinguishable from a correct `{}`.
  local ambient = adapter.get_visible_nodes()
  check("get-visible-bufnr: the ambient tree has real nodes to wrongly fall back to", #ambient > 0)

  -- A real bufnr that no live tree window shows -- an ordinary scratch
  -- buffer, never displayed anywhere.
  local scratch = vim.api.nvim_create_buf(false, true)
  check(
    "get-visible-bufnr: the scratch bufnr is a real, valid, unrelated buffer",
    vim.api.nvim_buf_is_valid(scratch) and scratch ~= tree_bufnr
  )

  local result = adapter.get_visible_nodes(nil, scratch)
  check(
    "get-visible-bufnr: an unresolvable bufnr returns {} -- not the ambient tree's nodes",
    type(result) == "table" and #result == 0,
    "got " .. #result .. " node(s)"
  )

  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  close_neotree_settled()
end

-- ── neo-tree only: a background-tab redraw must still hit the tree's own,
-- real per-tab state -- not whichever tab happens to be current ────────────
-- Root cause: `adapter/neotree.lua`'s internal `get_state()` used to call
-- neo-tree's own `manager.get_state("filesystem")` with no `tabid`, which
-- neo-tree itself defaults to `vim.api.nvim_get_current_tabpage()` -- the
-- tab that is current WHEN THE CALL HAPPENS, not necessarily the tab the
-- tree sidebar lives on. Every adapter function funnels through that one
-- helper, so a redraw driven by neo-tree's own AFTER_RENDER event (exactly
-- how link_marker keeps its symlink sign in sync -- see that feature's
-- on_render subscription) or an async git-status/fs-watcher completion
-- firing while a DIFFERENT tab is current used to resolve the wrong tab's
-- (empty) state and silently no-op, leaving whatever the real redraw had
-- just wiped on the tree's OWN tab undrawn -- reappearing only once the tree
-- was focused again (which makes its tab current too). Only a real neo-tree
-- with a real second tabpage reproduces this; a stub adapter has no per-tab
-- state to get wrong.
local function run_neotree_multitab_redraw_check()
  print("\n== neo-tree: a background-tab redraw still finds the tree's own tab ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-multitab"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "hi" }, work .. "/plain.txt")

  local link_ok = (vim.uv or vim.loop).fs_symlink(work .. "/plain.txt", work .. "/a_link.txt")
  if not link_ok then
    print("  note no permission to create a real symlink here -- skipping")
    return
  end

  vim.cmd("tabonly")
  -- The checks below need a plain editor window to be current with no tree
  -- around yet -- an earlier suite's tree that reopened itself after its own
  -- close would otherwise be where `:edit` runs (see close_neotree_settled).
  -- Checked before repairing it, so a teardown that leaks its tree is a
  -- named failure here instead of a flaky one further down.
  check(
    "multitab: no tree window is left over from an earlier suite",
    neotree_windows() == 0,
    tostring(neotree_windows()) .. " tree window(s)"
  )
  close_neotree_settled()
  -- Restored below on every exit path: neo-tree's `bind_to_cwd` (default on)
  -- reacts to `DirChanged` through its own 200ms-debounced event queue (see
  -- `setup/init.lua`) -- a queued reaction can still be sitting there,
  -- unfired, well past this test's own teardown wait, and fire LATE during a
  -- LATER test, silently re-navigating whatever tab is tracked back to THIS
  -- test's `work` dir out from under it. Leaving the global cwd changed here
  -- is exactly what feeds that: restoring it removes the trigger for good,
  -- not just outrunning its timing.
  local orig_cwd = vim.fn.getcwd()
  vim.cmd("cd " .. vim.fn.fnameescape(work))

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal is on by default (opt-out, not opt-in -- see
    -- filetree/init.lua's DEFAULT_DISABLED) and reacts to BufEnter on the
    -- real editor buffer this test opens below with its own debounced
    -- reveal/re-root. `lib.nvim`'s debounce primitive stops a pending call
    -- via a libuv timer:stop(), which cannot un-queue a callback that had
    -- already fired at the libuv level and is merely waiting for
    -- `vim.schedule` to run it -- so a reveal armed here can still land, with
    -- this test's OWN `work` dir baked into its closure, during a LATER
    -- test's own `vim.wait`. Disabled here since this test has no interest in
    -- reveal behavior, closing that off at the source rather than racing it.
    features = { link_marker = { enabled = true }, auto_reveal = { enabled = false } },
  })

  local adapter = require("filetree.adapter.neotree")
  local tabid_a = vim.api.nvim_get_current_tabpage()

  -- A real editor window alongside the sidebar, like an ordinary session --
  -- the reported symptom is a tree sitting in the BACKGROUND, with an
  -- editor window (not the tree) as the tab's actual focus.
  vim.cmd("edit " .. vim.fn.fnameescape(work .. "/plain.txt"))
  local editor_win = vim.api.nvim_get_current_win()
  -- action = "show" (not "focus") leaves the current window alone.
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("a_link.txt", 1, true) ~= nil
  end, 50)
  check(
    "multitab: opening the tree left the editor window current",
    vim.api.nvim_get_current_win() == editor_win
  )

  local bufnr = adapter.get_bufnr()
  check("multitab: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then
    vim.cmd("tabonly")
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    return
  end

  -- Neo-tree's OWN state object for tab A, fetched directly -- exactly what
  -- an async git-status/watcher completion callback would still be holding,
  -- regardless of which tab happens to be current by the time it runs.
  local mgr = require("neo-tree.sources.manager")
  local events = require("neo-tree.events")
  local state_a = mgr.get_state("filesystem", tabid_a)

  -- Give the async scan's own follow-up redraw time to happen, same as the
  -- sibling link_marker check above -- the icon must genuinely be there
  -- before this check starts tampering with it. Then settle it
  -- deterministically by (re-)firing tab A's own REAL AFTER_RENDER state
  -- once, explicitly: neo-tree has an entirely separate redraw path of its
  -- own (`sources/manager.lua`'s `opened_buffers_changed`, wired to
  -- `enable_opened_markers`/`enable_modified_markers`'s default-on buffer-
  -- tracking) that calls `renderer.redraw(state)` DIRECTLY -- bypassing
  -- `show_nodes` and so never firing AFTER_RENDER at all -- every time a
  -- buffer opens or closes anywhere, which can silently shift/wipe an
  -- extmark placed by this tree's most recent AFTER_RENDER-driven redraw
  -- without this test's own doing. That is a real neo-tree behavior, wholly
  -- outside the on_render bridge this test pins, so re-firing once here
  -- proves the SAME thing the settling wait above already waits for, minus
  -- an occasional race against that unrelated redraw.
  vim.wait(1000, function()
    return false
  end, 50)
  events.fire_event(events.AFTER_RENDER, state_a)

  local ns = vim.api.nvim_get_namespaces()["filetree_link_marker"]
  check("multitab: link_marker's namespace exists", ns ~= nil)
  if not ns then
    vim.cmd("tabonly")
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    return
  end

  local function marker_line()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 0, #lines - 1 do
      local n = adapter.get_node_at_line(bufnr, i)
      if n and n.name == "a_link.txt" then return i end
    end
    return nil
  end

  local function marker_text_on(line)
    -- `line` is nil when `marker_line()` couldn't resolve the node at all
    -- (exactly the pre-fix failure mode) -- report "no icon" rather than
    -- crashing on a bad extmark range, so the rest of this file still runs.
    if line == nil then return "" end
    local ms = vim.api.nvim_buf_get_extmarks(
      bufnr,
      ns,
      { line, 0 },
      { line, -1 },
      { details = true }
    )
    local vt = ""
    for _, m in ipairs(ms) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        vt = vt .. chunk[1]
      end
    end
    return vt
  end

  local line = marker_line()
  check("multitab: the symlinked file is in the rendered tree", line ~= nil)
  if not line then
    vim.cmd("tabonly")
    vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
    return
  end
  check(
    "multitab: the icon is there before the test touches anything",
    marker_text_on(line):find("⇢", 1, true) ~= nil,
    marker_text_on(line)
  )

  -- Tab B: a fresh, unrelated tab becomes current -- tab A (the tree's real
  -- tab) is now the background one.
  vim.cmd("tabnew")
  local tabid_b = vim.api.nvim_get_current_tabpage()
  check("multitab: tab B is a genuinely different, current tab", tabid_b ~= tabid_a)

  -- The adapter, called from tab B's context, must still resolve tab A's
  -- real window/buffer/node -- this is the root cause itself, independent
  -- of link_marker: every one of get_bufnr/get_winid/get_node_at_line funnels
  -- through the same `get_state()` helper that git_status and size_info use
  -- too.
  check(
    "multitab: [FROM TAB B] adapter.get_winid() still resolves tab A's window",
    adapter.get_winid() == state_a.winid,
    string.format("got %s, want %s", tostring(adapter.get_winid()), tostring(state_a.winid))
  )
  check(
    "multitab: [FROM TAB B] adapter.get_bufnr() still resolves tab A's buffer",
    adapter.get_bufnr() == bufnr,
    tostring(adapter.get_bufnr())
  )
  local node_from_b = adapter.get_node_at_line(bufnr, line)
  check(
    "multitab: [FROM TAB B] get_node_at_line still resolves the right node",
    node_from_b ~= nil and node_from_b.name == "a_link.txt",
    node_from_b and node_from_b.name or "nil"
  )

  -- Now the full end-to-end symptom: simulate the redraw that is *about to*
  -- wipe the sign -- neo-tree's own full-content replace does not carry
  -- extmarks over, so clearing here stands in for that -- then fire the REAL
  -- neo-tree event that a real redraw fires when it finishes (`events.
  -- AFTER_RENDER`, from `ui/renderer.lua`'s `show_nodes`), from tab B's
  -- context, exactly like an async job's completion callback would. Checked
  -- immediately: `fire_event` dispatches its handlers synchronously (no
  -- `debounce_frequency` is configured for this event), so link_marker's
  -- on_render handler -- `M._render()` itself, undebounced on this path --
  -- has already run by the time `fire_event` returns. (Waiting here instead
  -- would be both unnecessary and flaky: neo-tree's own periodic upkeep --
  -- e.g. `resize_timer_interval` -- can replace the buffer's content again
  -- later, on its own schedule, which is a real but separate, pre-existing
  -- behavior this test has no business pinning.)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  check("multitab: the sign really is cleared now", marker_text_on(line) == "")
  events.fire_event(events.AFTER_RENDER, state_a)
  check(
    "multitab: [FROM TAB B] tab A's icon is redrawn even though tab B is current",
    marker_text_on(marker_line()):find("⇢", 1, true) ~= nil,
    marker_text_on(marker_line())
  )

  -- Back to tab A -- landing on the editor window, not the tree, exactly
  -- like a real tab switch (the tree was never focused to begin with).
  vim.api.nvim_set_current_tabpage(tabid_a)
  check(
    "multitab: [BACK ON TAB A, tree still unfocused] the current window is the editor, not the tree",
    vim.api.nvim_get_current_win() == editor_win
  )
  check(
    "multitab: [BACK ON TAB A, tree still unfocused] icon still present",
    marker_text_on(marker_line()):find("⇢", 1, true) ~= nil,
    marker_text_on(marker_line())
  )

  -- Finally, focusing the tree window itself -- this path already worked
  -- before the fix (focusing makes the tree's own tab current too), so it is
  -- a sanity check, not the regression this test pins.
  local winid = adapter.get_winid()
  if winid then vim.api.nvim_set_current_win(winid) end
  check(
    "multitab: [TREE WINDOW FOCUSED] icon present",
    marker_text_on(marker_line()):find("⇢", 1, true) ~= nil,
    marker_text_on(marker_line())
  )

  require("filetree.features.ui.link_marker").teardown()
  pcall(adapter.close)
  vim.cmd("tabonly")
  vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── neo-tree only: `get_state()`'s single-slot `_tree_tabid` cache tier
-- genuinely gets exercised, in isolation from the last-resort full-tabpage
-- probe ───────────────────────────────────────────────────────────────────
-- `get_state()` has three resolution tiers: the current tab, the
-- `_tree_tabid` cache, and (only reached when the first two both miss) a
-- full-tabpage probe. With only two tabs open, an ambient call from the
-- treeless tab would resolve correctly whether the SECOND tier (the cache)
-- or the THIRD (the probe, which would also find the only other tab) is what
-- actually answered -- the RESULT alone cannot tell them apart. With a
-- THIRD, uninvolved tab also open, it can: the full probe visits every OTHER
-- tab, so if it ran at all, it would call `manager.get_state` for that third
-- tab too. Spying on the real `manager.get_state` and asserting it was
-- called for the tree's own (cached) tab but NEVER for the third, unrelated
-- one proves the cache tier alone answered -- not merely that the answer
-- happened to be correct either way.
local function run_neotree_cache_tier_isolation_check()
  print("\n== neo-tree: get_state()'s _tree_tabid cache tier is genuinely exercised ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-cachetier"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "hi" }, work .. "/plain.txt")

  vim.cmd("tabonly")
  require("filetree").setup({
    adapter = "neotree",
    features = { auto_reveal = { enabled = false }, cwd_mode = { enabled = false } },
  })

  local adapter = require("filetree.adapter.neotree")
  local tabid_a = vim.api.nvim_get_current_tabpage()
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    return adapter.get_bufnr() ~= nil
  end, 50)
  check("cache-tier: the tree buffer exists", adapter.get_bufnr() ~= nil)

  -- Prime the cache: an ambient call while tab A (the tree's own tab) is
  -- current sets `_tree_tabid = tabid_a` (see `get_state()`'s tier-1 comment).
  adapter.get_root_path()

  vim.cmd("tabnew") -- tab B: current, treeless.
  local tabid_b = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew") -- tab C: current, treeless, and UNINVOLVED -- never the
  -- tree's own tab, never cached. Only the full-tabpage probe has any reason
  -- to ever touch it.
  local tabid_c = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabprevious") -- back to tab B: current, treeless, tab C now background.
  check(
    "cache-tier: tab B is current and genuinely tab/treeless",
    vim.api.nvim_get_current_tabpage() == tabid_b and tabid_b ~= tabid_a and tabid_b ~= tabid_c
  )

  local mgr = require("neo-tree.sources.manager")
  local queried_tabids = {}
  local original_get_state = mgr.get_state
  mgr.get_state = function(source_name, tabid, ...)
    if source_name == "filesystem" then
      queried_tabids[#queried_tabids + 1] = tabid or vim.api.nvim_get_current_tabpage()
    end
    return original_get_state(source_name, tabid, ...)
  end

  local ok_call, root = pcall(adapter.get_root_path)
  mgr.get_state = original_get_state -- restore immediately, pass or fail
  check("cache-tier: the ambient call itself succeeded", ok_call, tostring(root))

  local saw_c, saw_a = false, false
  for _, t in ipairs(queried_tabids) do
    if t == tabid_c then saw_c = true end
    if t == tabid_a then saw_a = true end
  end
  check(
    "cache-tier: the cached tab (A) was queried -- the cache tier ran",
    saw_a,
    vim.inspect(queried_tabids)
  )
  check(
    "cache-tier: the uninvolved third tab (C) was NEVER queried -- the full probe did not run",
    not saw_c,
    vim.inspect(queried_tabids)
  )

  -- Let any still-pending debounced `filesystem_navigate` from the initial
  -- `show` above finish against tab A while it's still a valid tabpage --
  -- otherwise `tabonly` below (closing every tab but the current one)
  -- destroys tab A out from under that in-flight debounce, which then logs
  -- a benign but noisy "Invalid tabpage id" error well after this test
  -- itself has finished.
  vim.wait(600, function()
    return false
  end, 50)
  pcall(adapter.close)
  vim.cmd("tabonly")
  vim.wait(300, function()
    return false
  end, 50)
end

-- ── neo-tree only: TWO independently, simultaneously live trees on two
-- different tabs must each resolve and decorate their OWN tree -- never
-- bleeding into each other, including on each tree's own FIRST render ──────
-- Regression introduced by the fix above (`run_neotree_multitab_redraw_check`):
-- its background-tab fallback (`_tree_tabid`, a single global slot caching
-- whichever tab a live window was last resolved on) was checked BEFORE the
-- tab that is actually current, so it unconditionally won over a SECOND,
-- genuinely current tree -- every ambient adapter call, and every
-- render-driven redraw that re-derived its bufnr ambiently instead of using
-- the one its own render pass was actually about, kept resolving back to
-- whichever tab got cached first. For link_marker/marks (both driven by the
-- adapter's `on_render` bridge) that meant a second tree's symlink icon
-- never drew AT ALL -- not even on that tree's own first real render, since
-- neo-tree fires AFTER_RENDER with the real per-render state, but the old
-- bridge discarded it and every subscriber re-derived an ambient bufnr
-- instead.
--
-- Fixed in `adapter/neotree.lua` by (1) `get_state()` preferring the tab
-- that is actually current over the background-tab cache, so an ambient
-- caller run from inside a tree's own window (a keymap, or a redraw fired
-- while that tab happens to be current) resolves ITS OWN tree; and (2)
-- threading the real per-render bufnr neo-tree's AFTER_RENDER handler
-- receives through `on_render` to link_marker/marks, so a render-driven
-- redraw resolves the SPECIFIC tree it was actually about via
-- `state_for_bufnr` -- correct regardless of which tab is nominally current
-- when that redraw happens, which (1) alone cannot guarantee (a background
-- tab's own async-scan-driven redraw does not make its tab current). Only a
-- real neo-tree with two real tabpages, each with its own live tree,
-- reproduces this; a stub adapter has no per-tab state to get wrong.
local function run_neotree_two_live_trees_check()
  print("\n== neo-tree: two simultaneously live per-tab trees never bleed into each other ==")

  local work_a = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-two-live-a"
  )
  local work_b = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-two-live-b"
  )
  for _, w in ipairs({ work_a, work_b }) do
    vim.fn.delete(w, "rf")
    vim.fn.mkdir(w, "p")
  end
  vim.fn.writefile({ "hi" }, work_a .. "/plain_a.txt")
  vim.fn.writefile({ "hi" }, work_b .. "/plain_b.txt")

  local uv = vim.uv or vim.loop
  local link_a_ok = uv.fs_symlink(work_a .. "/plain_a.txt", work_a .. "/link_a.txt")
  local link_b_ok = uv.fs_symlink(work_b .. "/plain_b.txt", work_b .. "/link_b.txt")
  if not (link_a_ok and link_b_ok) then
    print("  note no permission to create a real symlink here -- skipping")
    return
  end

  vim.cmd("tabonly")

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal disabled -- see `run_neotree_multitab_redraw_check`'s
    -- setup() call for why every neo-tree suite in this file does this.
    features = {
      link_marker = { enabled = true },
      marks = { enabled = true },
      auto_reveal = { enabled = false },
    },
  })

  local adapter = require("filetree.adapter.neotree")
  local marks = require("filetree.features.org.marks")
  local mgr = require("neo-tree.sources.manager")
  local events = require("neo-tree.events")
  local commands = require("neo-tree.command")

  local link_ns = vim.api.nvim_get_namespaces()["filetree_link_marker"]
  local marks_ns = vim.api.nvim_get_namespaces()["filetree_marks"]
  check("two-live: link_marker's namespace exists", link_ns ~= nil)
  check("two-live: marks' namespace exists", marks_ns ~= nil)
  if not (link_ns and marks_ns) then
    vim.cmd("tabonly")
    return
  end

  ---@param bufnr integer
  ---@param ns integer
  ---@param line integer?
  local function icon_text(bufnr, ns, line)
    if line == nil then return "" end
    local ms = vim.api.nvim_buf_get_extmarks(
      bufnr,
      ns,
      { line, 0 },
      { line, -1 },
      { details = true }
    )
    local vt = ""
    for _, m in ipairs(ms) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        vt = vt .. chunk[1]
      end
    end
    return vt
  end

  ---@param bufnr integer
  ---@param name string
  local function line_of(bufnr, name)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 0, #lines - 1 do
      local n = adapter.get_node_at_line(bufnr, i)
      if n and n.name == name then return i end
    end
    return nil
  end

  -- Tab A: open its own tree, rooted at work_a, and wait for the real
  -- symlink text to actually be on screen (the async scan's own settling
  -- redraw -- reproducing it, not dodging it, is the point, same as the
  -- sibling `run_neotree_link_marker_check`).
  local tabid_a = vim.api.nvim_get_current_tabpage()
  commands.execute({ action = "show", source = "filesystem", dir = work_a })
  vim.wait(4000, function()
    local state = mgr.get_state("filesystem", tabid_a)
    local win = state and state.winid
    if not (win and vim.api.nvim_win_is_valid(win)) then return false end
    local text =
      table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    return text:find("link_a.txt", 1, true) ~= nil
  end, 50)

  local state_a = mgr.get_state("filesystem", tabid_a)
  local bufnr_a = state_a.winid
      and vim.api.nvim_win_is_valid(state_a.winid)
      and vim.api.nvim_win_get_buf(state_a.winid)
    or nil
  check("two-live: tab A's tree buffer exists", bufnr_a ~= nil)
  if not bufnr_a then
    vim.cmd("tabonly")
    return
  end

  -- Tab B: a second, independently live tree rooted at work_b, opened and
  -- settled the SAME reliable way tab A was above -- genuinely current on
  -- tab B throughout its own setup, no racing against neo-tree's own window/
  -- buffer churn. (See below for how this test drives the actual
  -- cross-tab -- "rendered while a DIFFERENT tab is current" -- scenario
  -- deterministically, rather than by trying to catch a real async scan at
  -- exactly the right instant.)
  vim.cmd("tabnew")
  local tabid_b = vim.api.nvim_get_current_tabpage()
  check("two-live: tab B is a genuinely different, new tab", tabid_b ~= tabid_a)
  commands.execute({ action = "focus", source = "filesystem", dir = work_b })
  vim.wait(4000, function()
    local state = mgr.get_state("filesystem", tabid_b)
    local win = state and state.winid
    if not (win and vim.api.nvim_win_is_valid(win)) then return false end
    local text =
      table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    return text:find("link_b.txt", 1, true) ~= nil
  end, 50)

  local state_b = mgr.get_state("filesystem", tabid_b)
  local bufnr_b = state_b.winid
      and vim.api.nvim_win_is_valid(state_b.winid)
      and vim.api.nvim_win_get_buf(state_b.winid)
    or nil
  check("two-live: tab B's tree buffer exists", bufnr_b ~= nil)
  if not bufnr_b then
    vim.cmd("tabonly")
    return
  end

  local line_a = line_of(bufnr_a, "link_a.txt")
  local line_b = line_of(bufnr_b, "link_b.txt")
  check("two-live: link_a.txt resolves in tab A's tree", line_a ~= nil, tostring(line_a))
  check("two-live: link_b.txt resolves in tab B's tree", line_b ~= nil, tostring(line_b))
  check(
    "two-live: [TAB B SETTLED, TAB B CURRENT] tab B's own icon is there on its own first render",
    icon_text(bufnr_b, link_ns, line_b):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_b, link_ns, line_b)
  )
  check(
    "two-live: [TAB B SETTLED] tab A's icon is unaffected by tab B's own tree existing",
    icon_text(bufnr_a, link_ns, line_a):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_a, link_ns, line_a)
  )

  -- The critical, previously-broken check. Neo-tree's own async filesystem
  -- scan (or a background git-status/fs-watcher completion) can redraw a
  -- tree that lives on some OTHER, non-current tab at any time -- that is
  -- the whole premise `run_neotree_multitab_redraw_check` above already pins
  -- for a SINGLE tree. Reproduced here directly and deterministically for
  -- tab B specifically (rather than racing this test's own tab-switch
  -- against neo-tree's real async scan timing, which -- independently of
  -- this fix -- also collides with an entirely separate neo-tree redraw
  -- path, `sources/manager.lua`'s `opened_buffers_changed`; see
  -- `run_neotree_multitab_redraw_check`'s own "this test has no business
  -- pinning [neo-tree's] own periodic upkeep" comment for the same
  -- principle applied there): clear tab B's icon (standing in for whatever
  -- real redraw is about to wipe it, same technique as that sibling test),
  -- switch to tab A so tab B is now the ONLY-background tab, and fire tab
  -- B's REAL, node-carrying AFTER_RENDER state from tab A's context. Tab B's
  -- own icon must still be drawn correctly -- resolved via the bufnr
  -- neo-tree's own event handed the render-hook, never having ambiently
  -- guessed at "the current tab" -- and tab A's own icon must be completely
  -- unaffected.
  vim.api.nvim_buf_clear_namespace(bufnr_b, link_ns, 0, -1)
  check("two-live: tab B's icon is really cleared now", icon_text(bufnr_b, link_ns, line_b) == "")
  vim.api.nvim_set_current_tabpage(tabid_a)
  events.fire_event(events.AFTER_RENDER, state_b)
  check(
    "two-live: [FROM TAB A, TAB B's REAL RENDER] tab B's icon is drawn correctly",
    icon_text(bufnr_b, link_ns, line_b):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_b, link_ns, line_b)
  )
  check(
    "two-live: [FROM TAB A] tab A's icon is unaffected by resolving tab B's render",
    icon_text(bufnr_a, link_ns, line_a):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_a, link_ns, line_a)
  )

  -- Mark each node via the real API while its OWN tab is actually current --
  -- an ambient, keymap-shaped call that must resolve correctly on its own
  -- (task item 1: these are NOT render-callback-driven, and must keep
  -- working by simply being run on the correct tab already).
  local node_a = adapter.get_node_at_line(bufnr_a, line_a)
  if node_a then marks.toggle(node_a.path) end
  check(
    "two-live: [TAB A CURRENT] tab A's mark indicator is drawn",
    icon_text(bufnr_a, marks_ns, line_a) ~= ""
  )

  -- Bug (1) from the round-1 verify findings: ambient calls made FROM tab B
  -- while tab B's own tree is focused must resolve tab B's OWN window/buffer
  -- -- not tab A's, which is what the sticky single-slot cache used to
  -- return unconditionally.
  vim.api.nvim_set_current_tabpage(tabid_b)
  check(
    "two-live: [FROM TAB B, FOCUSED] adapter.get_winid() resolves tab B's own window",
    adapter.get_winid() == state_b.winid,
    string.format("got %s, want %s", tostring(adapter.get_winid()), tostring(state_b.winid))
  )
  check(
    "two-live: [FROM TAB B, FOCUSED] adapter.get_bufnr() resolves tab B's own buffer",
    adapter.get_bufnr() == bufnr_b,
    tostring(adapter.get_bufnr())
  )

  -- Mark link_b.txt the natural, keymap-shaped way -- while tab B is
  -- actually current -- and confirm it lands on tab B, not tab A.
  local node_b = adapter.get_node_at_line(bufnr_b, line_b)
  if node_b then marks.toggle(node_b.path) end
  check(
    "two-live: [TAB B CURRENT] tab B's mark indicator is drawn",
    icon_text(bufnr_b, marks_ns, line_b) ~= ""
  )
  check(
    "two-live: [TAB B CURRENT] tab A's mark did not gain a second mark from tab B's toggle",
    icon_text(bufnr_a, marks_ns, line_a) ~= ""
  )

  -- Back to tab A: ambient calls must resolve back to tab A's OWN
  -- window/buffer -- not stay stuck on tab B.
  vim.api.nvim_set_current_tabpage(tabid_a)
  check(
    "two-live: [BACK ON TAB A, FOCUSED] adapter.get_winid() resolves tab A's own window",
    adapter.get_winid() == state_a.winid,
    string.format("got %s, want %s", tostring(adapter.get_winid()), tostring(state_a.winid))
  )
  check(
    "two-live: [BACK ON TAB A, FOCUSED] adapter.get_bufnr() resolves tab A's own buffer",
    adapter.get_bufnr() == bufnr_a,
    tostring(adapter.get_bufnr())
  )
  check(
    "two-live: [BACK ON TAB A] tab A's icon and mark are both still exactly as they were",
    icon_text(bufnr_a, link_ns, line_a):find("⇢", 1, true) ~= nil
      and icon_text(bufnr_a, marks_ns, line_a) ~= ""
  )

  -- Finally, the full end-to-end symptom in both directions at once: clear
  -- both trees' decorations (standing in for neo-tree's own full-content
  -- replace on a real redraw, which does not carry extmarks over -- same
  -- technique as `run_neotree_multitab_redraw_check`), then fire each
  -- tree's REAL AFTER_RENDER event from the OTHER tab's context and confirm
  -- each tree redraws its OWN icon without touching the other's.
  vim.api.nvim_buf_clear_namespace(bufnr_a, link_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr_b, link_ns, 0, -1)
  check(
    "two-live: both trees' decorations are really cleared now",
    icon_text(bufnr_a, link_ns, line_a) == "" and icon_text(bufnr_b, link_ns, line_b) == ""
  )

  -- Tab B is current; the event fired is tab A's -- only tab A may redraw.
  events.fire_event(events.AFTER_RENDER, state_a)
  check(
    "two-live: [TAB B CURRENT, TAB A's EVENT FIRED] tab A's icon redraws",
    icon_text(bufnr_a, link_ns, line_a):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_a, link_ns, line_a)
  )
  check(
    "two-live: [TAB B CURRENT, TAB A's EVENT FIRED] tab B's icon stays cleared (no bleed)",
    icon_text(bufnr_b, link_ns, line_b) == "",
    icon_text(bufnr_b, link_ns, line_b)
  )

  -- Tab A is current; the event fired is tab B's -- only tab B may redraw.
  vim.api.nvim_set_current_tabpage(tabid_a)
  events.fire_event(events.AFTER_RENDER, state_b)
  check(
    "two-live: [TAB A CURRENT, TAB B's EVENT FIRED] tab B's icon redraws",
    icon_text(bufnr_b, link_ns, line_b):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_b, link_ns, line_b)
  )
  check(
    "two-live: [TAB A CURRENT, TAB B's EVENT FIRED] tab A's icon is untouched by tab B's redraw",
    icon_text(bufnr_a, link_ns, line_a):find("⇢", 1, true) ~= nil,
    icon_text(bufnr_a, link_ns, line_a)
  )

  require("filetree.features.org.marks").teardown()
  require("filetree.features.ui.link_marker").teardown()
  pcall(adapter.close)
  vim.cmd("tabonly")
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── neo-tree only: neo-tree's OWN `opened_buffers_changed`-driven redraw --
-- fired whenever ANY buffer opens or closes ANYWHERE in the session, wired
-- through `enable_opened_markers`/`enable_modified_markers` (both default
-- on) -- must still leave a BACKGROUND tab's link_marker icon and marks
-- checkmark drawn, not silently wiped ──────────────────────────────────────
-- Root cause: `sources/manager.lua`'s `opened_buffers_changed` (itself
-- reached from a REAL `BufAdd`/`BufDelete`/`BufWipeout` autocmd, debounced
-- 200ms, see `setup/init.lua`) calls `renderer.redraw(state)` DIRECTLY for
-- EVERY tracked per-tab state -- a real `state.tree:render()` buffer-content
-- replace, which does not carry extmarks over, same as any other redraw --
-- but that path never reaches `ui/renderer.lua`'s `show_nodes`, so it never
-- fires `AFTER_RENDER`. Before this fix, link_marker/marks' ONLY resync
-- signal for "a redraw just happened outside my own BufEnter/CursorMoved/
-- BufWritePost" was the adapter's `on_render` bridge subscribing to
-- `AFTER_RENDER` alone -- so this specific redraw path silently wiped a
-- background tab's icon/checkmark and left them gone until that tab's OWN
-- tree next got a real AFTER_RENDER (its own focus, its own rescan) --
-- reproduced for real: a tree open in tab A, then further tabs opened
-- elsewhere, and tab A's icon vanishes without tab A doing anything at all.
--
-- Reproduced here with the REAL trigger -- a real buffer opening and closing
-- in a genuinely different, current tab -- not a synthetic AFTER_RENDER fire,
-- unlike the two sibling suites above (which pin a DIFFERENT, already-fixed
-- bug: tab-scoped state RESOLUTION, not this redraw-path coverage gap; see
-- their own "wholly outside the on_render bridge this test pins" comment).
-- Fixed by `adapter/neotree.lua` also monkeypatching `neo-tree.ui.renderer`'s
-- `redraw` function itself (`install_redraw_hook`), reached by every caller
-- -- including this test's real trigger -- through a plain field lookup, not
-- a value captured once at neo-tree's own setup() time.
local function run_neotree_opened_buffers_redraw_check()
  print("\n== neo-tree: link_marker/marks survive a real opened_buffers_changed redraw ==")

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-openedbuffers"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  vim.fn.writefile({ "hi" }, work .. "/plain.txt")
  vim.fn.writefile({ "unrelated" }, work .. "/other.txt")

  local link_ok = (vim.uv or vim.loop).fs_symlink(work .. "/plain.txt", work .. "/a_link.txt")
  if not link_ok then
    print("  note no permission to create a real symlink here -- skipping")
    return
  end

  vim.cmd("tabonly")

  require("filetree").setup({
    adapter = "neotree",
    -- auto_reveal disabled -- see `run_neotree_multitab_redraw_check`'s
    -- setup() call for why every neo-tree suite in this file does this.
    features = {
      link_marker = { enabled = true },
      marks = { enabled = true },
      auto_reveal = { enabled = false },
    },
  })

  local adapter = require("filetree.adapter.neotree")
  local marks = require("filetree.features.org.marks")
  local mgr = require("neo-tree.sources.manager")
  local tabid_a = vim.api.nvim_get_current_tabpage()

  -- This suite never actually opens a SECOND tabpage for the sibling
  -- single-tree checks above -- `vim.cmd("tabonly")` on an already-single-tab
  -- session is a no-op, so `tabid_a` here is the exact same tab handle every
  -- earlier neo-tree check in this file just used. Neo-tree keeps its
  -- "filesystem" state keyed by that persistent tabid and updates it IN
  -- PLACE on every `show`/navigate -- fine for those tests' own synchronous
  -- assertions, but a PRIOR check's own buffer/tab churn (ambient adapter
  -- calls made from a background tab lazily create an empty placeholder
  -- state for THAT tabid too -- see `get_state()`'s own doc comment) can
  -- leave stray "filesystem" states, for tabids other than this one, sitting
  -- in neo-tree's `all_states`. `opened_buffers_changed` (the mechanism this
  -- test exercises) iterates ALL of them, not just this test's own -- a
  -- stray entry erroring mid-iteration (e.g. a disposed window it still
  -- references) would abort that whole pcall'd handler before it ever
  -- reaches this test's own state, silently skipping the very redraw this
  -- test means to trigger and reading as "survived" for the wrong reason.
  -- Disposing every "filesystem" state up front -- real neo-tree APIs, not a
  -- filetree internal -- drops all of that, so what this test measures is
  -- unambiguously its OWN redraw.
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "filesystem" then pcall(mgr.dispose, "filesystem", s.tabid) end
  end

  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("a_link.txt", 1, true) ~= nil
  end, 50)

  local bufnr = adapter.get_bufnr()
  check("opened-buffers: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then
    vim.cmd("tabonly")
    return
  end

  -- `bufnr` is captured once above; every helper below guards its validity
  -- rather than assuming it stays open for the rest of this test -- a stray
  -- redraw elsewhere in this same nvim process closing/replacing it out from
  -- under this test must fail a `check()` like any other unmet expectation,
  -- not crash the whole suite on an "Invalid buffer id" from the API call.
  local function line_of(name)
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 0, #lines - 1 do
      local n = adapter.get_node_at_line(bufnr, i)
      if n and n.name == name then return i end
    end
    return nil
  end

  local function text_on(ns, line)
    -- `line` is nil when `line_of()` couldn't resolve the node at all --
    -- report "nothing drawn" rather than crashing on a bad extmark range.
    if line == nil or not vim.api.nvim_buf_is_valid(bufnr) then return "" end
    local ms = vim.api.nvim_buf_get_extmarks(
      bufnr,
      ns,
      { line, 0 },
      { line, -1 },
      { details = true }
    )
    local vt = ""
    for _, m in ipairs(ms) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        vt = vt .. chunk[1]
      end
    end
    return vt
  end

  -- Give the async scan's own follow-up redraw time to actually happen first
  -- -- same as the sibling `run_neotree_link_marker_check` -- so the icon is
  -- genuinely there, drawn by the real thing, before this test starts. Polls
  -- `line_of` itself (the node-level, nui-tree-backed lookup this test's own
  -- checks rely on), not just the raw buffer text the earlier wait above
  -- already matched on: the two can briefly disagree while an in-flight
  -- render is still settling, and a fixed sleep landing inside that window
  -- reads as this test's OWN fixture never having rendered at all.
  vim.wait(3000, function()
    return line_of("a_link.txt") ~= nil
  end, 50)

  local link_ns = vim.api.nvim_get_namespaces()["filetree_link_marker"]
  local marks_ns = vim.api.nvim_get_namespaces()["filetree_marks"]
  check("opened-buffers: link_marker's namespace exists", link_ns ~= nil)
  check("opened-buffers: marks' namespace exists", marks_ns ~= nil)
  if not (link_ns and marks_ns) then
    vim.cmd("tabonly")
    return
  end

  local line = line_of("a_link.txt")
  check("opened-buffers: the symlinked file is in the rendered tree", line ~= nil)
  if not line then
    vim.cmd("tabonly")
    return
  end
  check(
    "opened-buffers: the icon is there before the test touches anything",
    text_on(link_ns, line):find("⇢", 1, true) ~= nil,
    text_on(link_ns, line)
  )

  -- Mark the SAME node too, via the real API -- covers `marks`, not just
  -- `link_marker`, against the exact same redraw.
  local node = adapter.get_node_at_line(bufnr, line)
  check("opened-buffers: the symlinked node resolves", node ~= nil)
  if node then marks.toggle(node.path) end
  check(
    "opened-buffers: the mark indicator is there before the test touches anything",
    text_on(marks_ns, line) ~= "",
    text_on(marks_ns, line)
  )

  -- Tab B: a fresh, unrelated tab becomes current -- tab A (the tree's real
  -- tab) is now the background one, exactly like the reported repro (a tree
  -- open in tab A, then further tabs opened elsewhere).
  vim.cmd("tabnew")
  local tabid_b = vim.api.nvim_get_current_tabpage()
  check("opened-buffers: tab B is a genuinely different, current tab", tabid_b ~= tabid_a)

  -- The REAL trigger: a real buffer opening, then closing, in tab B -- fires
  -- neo-tree's own real `BufAdd`/`BufDelete`/`BufWipeout` autocmds (see
  -- `setup/init.lua`'s `enable_opened_markers` wiring), NOT a synthetic
  -- `AFTER_RENDER` fire. Nothing here touches tab A or its tree directly --
  -- neo-tree's `opened_buffers_changed` is what reaches into tab A on its own.
  --
  -- The open and close are deliberately NOT back-to-back: `opened_buffers_changed`
  -- only actually redraws when its own 200ms-debounced callback finds the
  -- *opened-buffers set* genuinely different from what it cached last (see
  -- `sources/manager.lua`) -- computed at CALLBACK time, not at the moment
  -- the raw autocmd fired. Closing this buffer again before that callback has
  -- run would let the add and the remove cancel out from its point of view
  -- (same set before and after), skipping the redraw entirely and making this
  -- test's own trigger a no-op regardless of the fix. Waiting comfortably
  -- past the debounce after EACH half lets both the add and the remove land
  -- as two genuinely separate, real redraws.
  vim.cmd("edit " .. vim.fn.fnameescape(work .. "/other.txt"))
  vim.wait(500, function()
    return false
  end, 50)
  vim.cmd("bwipeout")
  vim.wait(500, function()
    return false
  end, 50)

  check(
    "opened-buffers: [FROM TAB B, REAL BufAdd/BufDelete] tab A's icon survives",
    text_on(link_ns, line):find("⇢", 1, true) ~= nil,
    text_on(link_ns, line)
  )
  check(
    "opened-buffers: [FROM TAB B, REAL BufAdd/BufDelete] tab A's mark survives",
    text_on(marks_ns, line) ~= "",
    text_on(marks_ns, line)
  )

  marks.teardown()
  require("filetree.features.ui.link_marker").teardown()
  pcall(adapter.close)
  vim.cmd("tabonly")
  vim.wait(500, function()
    return false
  end, 50)
end

-- ── Run ──────────────────────────────────────────────────────────────────────

local wanted = vim.env.FILETREE_ADAPTER_LINES
local function want(name)
  return wanted == nil or wanted == "" or wanted:find(name, 1, true) ~= nil
end

-- ── neo-tree: right-click menu acts on the CLICKED node ─────────────────────
--
-- `features/ui/context_menu` moves the tree cursor to the pointer and opens
-- the menu in the same breath. neo-tree remembers the cursor line from a
-- `CursorMoved` autocmd and restores it on every `WinEnter` of the tree
-- window; creating the menu's float re-enters the tree window synchronously,
-- i.e. BEFORE that autocmd could have seen the jump, so the cursor was put
-- back on the line it had before the click and the menu acted on the wrong
-- node -- in practice one further down than the one clicked.
--
-- Driven through the real buffer-local `<RightMouse>` mapping and the real
-- kit menu, with `getmousepos` standing in for the pointer (this runner has no
-- main loop to deliver a mouse event). The `CursorMoved` below is what that
-- main loop would have fired after the cursor's previous move.
local function run_neotree_context_menu_click_check()
  print("\n== neo-tree: the right-click menu acts on the clicked node, not a stale one ==")

  local ok_cm, contextmenu = pcall(require, "ui.contextmenu")
  if not ok_cm then
    print("  --   ui.nvim not resolvable; skipping")
    skipped = skipped + 1
    return
  end

  local work = slash(
    (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
      .. "/filetree-neotree-ctxmenu-click"
  )
  vim.fn.delete(work, "rf")
  vim.fn.mkdir(work, "p")
  for _, f in ipairs({ "a.txt", "b.txt", "c.txt", "d.txt" }) do
    vim.fn.writefile({ "x" }, work .. "/" .. f)
  end

  require("filetree").setup({
    adapter = "neotree",
    features = { auto_reveal = { enabled = false } },
  })

  local adapter = require("filetree.adapter.neotree")
  -- A tree left open by the previous check would otherwise still be showing
  -- ITS directory when this one looks for its files.
  pcall(adapter.close)
  vim.wait(300, function()
    return false
  end, 50)
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(6000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("a.txt", 1, true) ~= nil and text:find("d.txt", 1, true) ~= nil
  end, 50)
  vim.wait(500, function()
    return false
  end, 50)

  local bufnr, winid = adapter.get_bufnr(), adapter.get_winid()
  check("ctx-click: the tree exists", bufnr ~= nil and winid ~= nil)
  if not (bufnr and winid) then
    pcall(adapter.close)
    return
  end

  -- The buffer-local binding is made by the FileType dispatcher on a schedule.
  vim.api.nvim_set_current_win(winid)
  local function rhs()
    local m = vim.api.nvim_buf_call(bufnr, function()
      return vim.fn.maparg("<RightMouse>", "n", false, true)
    end)
    return m and m.callback
  end
  vim.wait(500, function()
    return rhs() ~= nil
  end, 20)
  local open_menu = rhs()
  check("ctx-click: the tree buffer has the <RightMouse> mapping", open_menu ~= nil)
  if not open_menu then
    pcall(adapter.close)
    return
  end

  local function line_of(name)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find(name, 1, true) then return i end
    end
  end
  local stale_line, target_line = line_of("a.txt"), line_of("d.txt")
  check(
    "ctx-click: the stale and the clicked line differ",
    stale_line and target_line and stale_line < target_line,
    tostring(stale_line) .. " / " .. tostring(target_line)
  )

  local saved_mousemodel, real_getmousepos = vim.o.mousemodel, vim.fn.getmousepos
  contextmenu.setup({ renderer = "kit" })

  local function float_count()
    local n = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then n = n + 1 end
    end
    return n
  end

  ---Right-click `target` while the cursor (as neo-tree last saw it) sits on
  ---`from`. `screenrow` defaults to where `target` is drawn, like the real
  ---`getmousepos()`; `getmousepos().line` is the clamped one past the buffer end.
  local function click(from, target, screenrow, extra)
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { from, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr, modeline = false })
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.getmousepos = function()
      return vim.tbl_extend("force", {
        winid = winid,
        line = target,
        column = 6,
        screenrow = screenrow or vim.fn.screenpos(winid, target, 1).row,
        screencol = 6,
      }, extra or {})
    end
    local floats_before = float_count()
    local ok, err = pcall(open_menu)
    local cursor = vim.api.nvim_win_get_cursor(winid)[1]
    local node = adapter.get_node_at_line(bufnr, cursor - 1)
    local opened = float_count() > floats_before
    -- Close the menu again (and put the mouse stub back) before the next round.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    vim.fn.getmousepos = real_getmousepos
    return ok, err, cursor, node, opened
  end

  local ok, err, cursor, node = click(stale_line, target_line)
  check("ctx-click: the mapping ran without error", ok, tostring(err))
  check(
    "ctx-click: the cursor is on the clicked line, not the stale one",
    cursor == target_line,
    ("cursor on line %s, clicked line %s"):format(tostring(cursor), tostring(target_line))
  )
  check(
    "ctx-click: ...and that line resolves to the clicked node",
    node ~= nil and node.name == "d.txt",
    node and node.name or "nil"
  )

  -- And the other way round, so a fix that merely pins the cursor to the
  -- bottom (or to "wherever the menu last was") cannot pass.
  local ok_up, err_up, _, node_up = click(target_line, line_of("b.txt"))
  check("ctx-click: a click upward works too", ok_up, tostring(err_up))
  check(
    "ctx-click: ...and lands on the clicked node",
    node_up ~= nil and node_up.name == "b.txt",
    node_up and node_up.name or "nil"
  )

  -- The empty area below the last node is not a node: no menu, cursor stays.
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local last_row = vim.fn.screenpos(winid, last_line, 1).row
  check("ctx-click: the last line is on screen", last_row > 0, tostring(last_row))
  local ok_l, err_l, cur_l, node_l, opened_l = click(stale_line, last_line)
  check("ctx-click: a click ON the last node opens the menu", ok_l and opened_l, tostring(err_l))
  check(
    "ctx-click: ...on that node",
    cur_l == last_line and node_l ~= nil,
    "cursor " .. tostring(cur_l)
  )
  local ok_b, err_b, cur_b, _, opened_b = click(stale_line, last_line, last_row + 2)
  check("ctx-click: a click below the last node runs without error", ok_b, tostring(err_b))
  check("ctx-click: ...opens no menu", not opened_b)
  check(
    "ctx-click: ...and leaves the cursor where it was",
    cur_b == stale_line,
    ("cursor on line %s, was on %s"):format(tostring(cur_b), tostring(stale_line))
  )

  -- Nothing else that is not a text row of the tree may open it either.
  local function expect_nothing(label, ...)
    local ok_n, err_n, cur_n, _, opened_n = click(stale_line, last_line, ...)
    check("ctx-click: " .. label .. " runs without error", ok_n, tostring(err_n))
    check("ctx-click: " .. label .. " opens no menu", not opened_n)
    check(
      "ctx-click: " .. label .. " leaves the cursor where it was",
      cur_n == stale_line,
      ("cursor on line %s, was on %s"):format(tostring(cur_n), tostring(stale_line))
    )
  end
  expect_nothing("the row right below the last node", last_row + 1)
  expect_nothing("the tree's statusline / separator (line 0)", last_row, { line = 0, column = 0 })

  vim.cmd("botright new")
  local editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(winid)
  expect_nothing("a click in another window", last_row, { winid = editor_win, line = 1 })
  pcall(vim.api.nvim_win_close, editor_win, true)

  vim.o.mousemodel = saved_mousemodel
  pcall(adapter.close)
  vim.wait(300, function()
    return false
  end, 50)
end

local ran = 0

if has_neotree and has_nui and want("neotree") then
  require("neo-tree").setup({
    close_if_last_window = false,
    filesystem = { use_libuv_file_watcher = false, follow_current_file = { enabled = false } },
    window = { position = "left", width = 40 },
  })
  run_backend({
    name = "neotree",
    open = function(work)
      -- The :Neotree command lives in neo-tree's plugin/ file, which an rtp
      -- prepended after startup never sources -- drive its command module.
      require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
    end,
  })
  run_neotree_filter_race_check()
  run_neotree_filter_other_tab_check()
  run_neotree_filter_closed_tree_check()
  run_neotree_link_marker_check()
  run_neotree_get_visible_nodes_bufnr_check()
  run_neotree_multitab_redraw_check()
  run_neotree_cache_tier_isolation_check()
  run_neotree_two_live_trees_check()
  run_neotree_opened_buffers_redraw_check()
  run_neotree_context_menu_click_check()
  ran = ran + 1
else
  print("n/a  neo-tree: not installed (or excluded) -- that pass did not run")
end

if has_nvimtree and want("nvimtree") then
  require("nvim-tree").setup({
    hijack_netrw = false,
    update_focused_file = { enable = false },
    renderer = { group_empty = true },
    view = { width = 40 },
  })
  run_backend({
    name = "nvimtree",
    open = function(work)
      require("nvim-tree.api").tree.open({ path = work })
    end,
  })
  run_nvimtree_filter_line_check()
  ran = ran + 1
else
  print("n/a  nvim-tree: not installed (or excluded) -- that pass did not run")
end

if ran == 0 then
  print("\nadapter_lines: no backend available -- nothing ran (not a failure).")
  print("  $FILETREE_NEOTREE / $FILETREE_NVIMTREE point at checkouts.")
end

print(("\nadapter_lines: %d passed, %d failed, %d n/a"):format(passed, failed, skipped))
vim.cmd(failed > 0 and "cq" or "qa!")
