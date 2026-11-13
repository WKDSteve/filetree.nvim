-- neotree_redraw_hook.lua — the `renderer.redraw` monkeypatch, against a REAL
-- neo-tree, exercised through real neo-tree commands (not synthetic event
-- firing) and in a load order that reproduces the actual race this hook is
-- meant to close.
--
-- Runs in its OWN process (a fresh `nvim -l`), on purpose: this suite
-- deliberately controls exactly which neo-tree modules get `require`d first,
-- something no other suite may safely do once it's shared a process with
-- other neo-tree-backed checks (nothing else in this repo may reload core
-- neo-tree modules out from under an already-running session).
--
-- ── What this pins ──────────────────────────────────────────────────────────
--
-- neo-tree's own `sources/filesystem/commands.lua` does, at ITS OWN
-- module-load time:
--
--   local redraw = renderer.redraw
--
-- -- a plain Lua upvalue, captured ONCE, not a field lookup. `M.copy_to_clipboard`
-- and `M.cut_to_clipboard` (bound by default to `y`/`x`) call THAT captured
-- local, via `utils.wrap(redraw, state)`, to redraw after marking a node --
-- never a fresh `renderer.redraw` field read. So `filetree.adapter.neotree`'s
-- `renderer.redraw` monkeypatch only helps here if it is already installed
-- BEFORE `sources/filesystem/commands.lua` is first required -- and that
-- module is required EAGERLY, for every configured source, from inside
-- neo-tree's OWN `setup()` (`setup/init.lua`: `source_default_config.commands
-- = ... or require(mod_root .. ".commands")`). For a lazily-loaded
-- neo-tree.nvim, that `setup()` call itself only runs on the user's FIRST
-- `:Neotree` invocation -- so this suite reproduces exactly that order:
-- `filetree.nvim` loads (and installs its hook) FIRST, and neo-tree's own
-- `setup()` -- which is what actually captures the local -- runs SECOND, the
-- same relative order a lazily-loaded neo-tree.nvim gives in practice.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/neotree_redraw_hook.lua
-- Exit 0 = all passed (or skipped), 1 = a check failed.

io.stdout:setvbuf("line")
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

---@param env string[]
---@param names string[]
---@param probe string
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

local function slash(p)
  return (tostring(p):gsub("\\", "/"))
end

if not (has_neotree and has_nui) then
  print("n/a  neo-tree/nui not installed (or excluded) -- nothing to run")
  print("  $FILETREE_NEOTREE points at a checkout.")
  os.exit(0)
end

-- ── Part A: the redraw hook wins the real race, against neo-tree's own
-- copy_to_clipboard (bound to `y` by default) ───────────────────────────────
--
-- Order matters and is deliberate: `filetree.adapter.neotree` (which installs
-- the `package.preload["neo-tree.ui.renderer"]` hoist -- see that file's
-- `hoist_redraw_hook` doc comment) is required FIRST, before ANYTHING neo-tree
-- has ever touched `neo-tree.ui.renderer`. Only then does neo-tree's own
-- `setup()` run -- the same relative order a lazily-loaded neo-tree.nvim
-- gives on the user's first `:Neotree`.
require("filetree.adapter.neotree")

local work = slash((vim.env.TEMP or "/tmp") .. "/filetree-neotree-redrawhook")
vim.fn.delete(work, "rf")
vim.fn.mkdir(work, "p")
vim.fn.writefile({ "hi" }, work .. "/plain.txt")
vim.fn.writefile({ "copy me" }, work .. "/to_copy.txt")

local link_ok = (vim.uv or vim.loop).fs_symlink(work .. "/plain.txt", work .. "/a_link.txt")
if not link_ok then
  print("no permission to create a real symlink here -- skipping Part A/B")
  goto done
end

require("neo-tree").setup({
  close_if_last_window = false,
  filesystem = { use_libuv_file_watcher = false, follow_current_file = { enabled = false } },
  window = { position = "left", width = 40 },
})

require("filetree").setup({
  adapter = "neotree",
  features = {
    link_marker = { enabled = true },
    marks = { enabled = true },
    auto_reveal = { enabled = false },
    -- cwd_mode reacts to TabEnter/WinEnter (refresh_indicator -> ambient
    -- adapter.get_winid()) -- exactly the kind of ambient call Part B below
    -- means to isolate. Disabled here so a plain `tabnew` in Part B does not
    -- itself trigger a tier-1 ambient `get_state()` call (a legitimate,
    -- expected one, just not what Part B is trying to isolate) that would
    -- otherwise register a real "current tab" state for that tab before this
    -- suite's own probe ever runs, contaminating what Part B measures.
    cwd_mode = { enabled = false },
  },
})

do
  local adapter = require("filetree.adapter.neotree")
  local marks = require("filetree.features.org.marks")

  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("to_copy.txt", 1, true) ~= nil
  end, 50)

  local bufnr = adapter.get_bufnr()
  check("redraw-hook: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then goto done end

  local function line_of(name)
    if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 0, #lines - 1 do
      local n = adapter.get_node_at_line(bufnr, i)
      if n and n.name == name then return i end
    end
    return nil
  end

  vim.wait(3000, function()
    return line_of("a_link.txt") ~= nil and line_of("to_copy.txt") ~= nil
  end, 50)

  local link_line = line_of("a_link.txt")
  local copy_line = line_of("to_copy.txt")
  check("redraw-hook: the symlink is in the rendered tree", link_line ~= nil)
  check("redraw-hook: the file to copy is in the rendered tree", copy_line ~= nil)
  if not (link_line and copy_line) then goto done end

  -- Mark the symlink -- marks' own redraw is on_render-driven too, so it
  -- exercises the SAME bridge `copy_to_clipboard` is about to. Marked by the
  -- NODE's own `path` (not a hand-built string): neo-tree's `node.path` is
  -- native-separator (backslash on Windows), and `_marks` is keyed by exact
  -- string match, so a hand-built forward-slash path would silently never
  -- match and never draw.
  local link_node = adapter.get_node_at_line(bufnr, link_line)
  check("redraw-hook: the symlink node resolves", link_node ~= nil)
  if link_node then marks.toggle(link_node.path) end

  local link_ns = vim.api.nvim_get_namespaces()["filetree_link_marker"]
  local marks_ns = vim.api.nvim_get_namespaces()["filetree_marks"]
  check("redraw-hook: link_marker's namespace exists", link_ns ~= nil)
  check("redraw-hook: marks' namespace exists", marks_ns ~= nil)
  if not (link_ns and marks_ns) then goto done end

  local function text_on(ns, line)
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

  check(
    "redraw-hook: the icon is there before copy_to_clipboard",
    text_on(link_ns, link_line):find("⇢", 1, true) ~= nil,
    text_on(link_ns, link_line)
  )
  check(
    "redraw-hook: the mark is there before copy_to_clipboard",
    text_on(marks_ns, link_line) ~= "",
    text_on(marks_ns, link_line)
  )

  -- The real thing: neo-tree's own `y` command, on the OTHER file (so the
  -- symlink's own decorations aren't touched by the copy itself -- only by
  -- whatever redraw it triggers). This calls
  -- `sources.filesystem.commands.M.copy_to_clipboard`, whose ONLY redraw
  -- trigger is the captured-local `redraw` this whole suite is about.
  --
  -- Move the cursor and let its own debounced CursorMoved redraw (a totally
  -- separate mechanism from the on_render/redraw-hook bridge under test --
  -- see link_marker/marks' own `setup()`) fully settle FIRST, THEN call the
  -- clipboard command with no further cursor movement, and assert
  -- IMMEDIATELY afterward with no `vim.wait` at all: the whole
  -- copy_to_clipboard call chain (mark clipboard -> fire
  -- NEO_TREE_CLIPBOARD_CHANGED -> the `redraw` callback) runs synchronously.
  -- Waiting here would risk that unrelated CursorMoved-debounced redraw (or
  -- any other background trigger routed through a live field lookup, which
  -- this fix's field-patch already covers on its own) firing anyway and
  -- masking exactly the gap this suite means to catch: a real bug here would
  -- otherwise still read as "survives" simply because nothing else happened
  -- to repaint it in time.
  -- Genuinely FOCUS the tree window before moving the cursor in it (not just
  -- `nvim_win_set_cursor` from outside via `nvim_win_call`): neo-tree's own
  -- `render_tree` restores the cursor to its OWN last-tracked position on
  -- every redraw (see the "Render-event bridge" comment's "`state.tree:render()`
  -- plus cursor restore"), which it only updates from a real CursorMoved on
  -- the ACTUALLY CURRENT window -- setting the cursor without focusing first
  -- left it tracking the OLD position, and the very next (unrelated,
  -- debounce-driven) redraw during the settle wait below then snapped the
  -- cursor right back to it, silently resolving the wrong node.
  local win = adapter.get_winid()
  check("redraw-hook: tree window resolves", win ~= nil)
  if not win then goto done end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { copy_line + 1, 0 })
  vim.wait(300, function()
    return false
  end, 50)

  local fs_commands = require("neo-tree.sources.filesystem.commands")
  local state = require("neo-tree.sources.manager").get_state("filesystem")
  fs_commands.copy_to_clipboard(state)

  check(
    "redraw-hook: [REAL copy_to_clipboard] the symlink icon survives",
    text_on(link_ns, link_line):find("⇢", 1, true) ~= nil,
    text_on(link_ns, link_line)
  )
  check(
    "redraw-hook: [REAL copy_to_clipboard] the mark survives",
    text_on(marks_ns, link_line) ~= "",
    text_on(marks_ns, link_line)
  )

  -- cut_to_clipboard (bound to `x`) shares the identical captured-local
  -- shape -- pin it too, cheaply, on the same fixture, same no-wait
  -- reasoning as above.
  fs_commands.cut_to_clipboard(state)
  check(
    "redraw-hook: [REAL cut_to_clipboard] the symlink icon survives",
    text_on(link_ns, link_line):find("⇢", 1, true) ~= nil,
    text_on(link_ns, link_line)
  )

  marks.teardown()
  require("filetree.features.ui.link_marker").teardown()
  pcall(adapter.close)
end

-- ── Part B: the last-resort tab probe never leaks a permanent ghost state ──
--
-- `get_state()`'s full-tabpage probe (reached from an AMBIENT call, e.g.
-- `get_root_path()`, made while neither the current tab nor the cached
-- `_tree_tabid` has a live tree) used to call
-- `manager.get_state("filesystem", tabid)` on every OTHER tab just to check
-- liveness -- which neo-tree's own `manager.get_state` answers by lazily
-- creating and PERMANENTLY registering an empty state for any tabid that
-- never had one. Confirm a tab with no tracked "filesystem" state, probed
-- this way, does NOT end up in neo-tree's own `all_states` afterwards.
do
  local adapter = require("filetree.adapter.neotree")
  local mgr = require("neo-tree.sources.manager")

  vim.cmd("tabnew")
  local tab_x = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local tab_y = vim.api.nvim_get_current_tabpage()
  -- Making tab_x/tab_y current at all, above, is enough for OTHER
  -- filetree features still wired from Part A (sidebar_guard and friends --
  -- ordinary, expected traffic, not what this part means to isolate) to have
  -- made their own legitimate tier-1 `get_state()` calls for them already.
  -- Strip that back to "never had a tracked state", via neo-tree's own real
  -- `dispose` API, so what follows measures the LAST-RESORT PROBE's own
  -- behavior specifically.
  pcall(mgr.dispose, "filesystem", tab_x)
  pcall(mgr.dispose, "filesystem", tab_y)

  vim.cmd("tabnew") -- a fourth, current tab -- neither tab_x nor tab_y, and
  -- not tab 1 (the original tree's tab, cached as `_tree_tabid`, but its
  -- window was closed at the end of Part A, so that cache tier also misses).
  -- This ambient call therefore falls all the way to the last-resort probe,
  -- which visits tab_x and tab_y among others.
  adapter.get_root_path()

  local leaked = {}
  for _, s in ipairs(mgr._get_all_states()) do
    if s.name == "filesystem" and (s.tabid == tab_x or s.tabid == tab_y) then
      leaked[#leaked + 1] = s.tabid
    end
  end
  check(
    "ghost-state: the last-resort probe does not leak a state for a tab it merely checked",
    #leaked == 0,
    vim.inspect(leaked)
  )

  vim.cmd("tabonly")
end

-- ── Part C: the redraw-hook notification survives a hot reload -- no
-- stacked wrapper, no orphaned generation left as the only one firing ──────
--
-- `install_redraw_hook` used to keep its "already wrapped" bookkeeping in a
-- module-level local, which a plugin hot reload (`package.loaded[...] = nil`
-- + re-require, a normal dev workflow) resets to empty along with every
-- other local in the fresh module generation -- so the fresh generation
-- would wrap `renderer.redraw` AGAIN, stacking a second layer whose OWN
-- `notify_render_listeners` upvalue stayed frozen on the FIRST generation's
-- `_render_listeners` table. The second generation's own `on_render`
-- subscribers -- registered into ITS OWN, different `_render_listeners`
-- table -- then never fired at all. Fixed by storing the live notify
-- callback on `renderer` itself (neo-tree's own persistent module table,
-- untouched by reloading this one) instead of in a local here -- see
-- `install_redraw_hook`'s doc comment.
do
  local reload_work = slash((vim.env.TEMP or "/tmp") .. "/filetree-neotree-redrawhook-reload")
  vim.fn.delete(reload_work, "rf")
  vim.fn.mkdir(reload_work, "p")
  vim.fn.writefile({ "hi" }, reload_work .. "/plain.txt")

  -- Generation 1 is the module already `require`d by Parts A/B above.
  local gen1 = require("filetree.adapter.neotree")
  local gen1_hits = 0
  -- Deliberately never unsubscribed below: the point is to prove this
  -- listener goes silent because the live wrapper stops routing to it (the
  -- fix), not because this suite manually removed it.
  gen1.on_render(function()
    gen1_hits = gen1_hits + 1
  end)

  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = reload_work })
  vim.wait(2000, function()
    return gen1.get_bufnr() ~= nil
  end, 50)
  local bufnr = gen1.get_bufnr()
  check("reload: the tree buffer exists", bufnr ~= nil, tostring(bufnr))

  if bufnr then
    local renderer = require("neo-tree.ui.renderer")
    local state = require("neo-tree.sources.manager").get_state("filesystem")

    renderer.redraw(state)
    vim.wait(300, function()
      return gen1_hits > 0
    end, 20)
    check(
      "reload: generation 1's on_render fires on a real redraw, pre-reload",
      gen1_hits == 1,
      tostring(gen1_hits)
    )

    -- The actual hot reload: drop and re-require JUST this one module, same
    -- as a plugin manager's `:Lazy reload`/a dev's manual `package.loaded[...]
    -- = nil` workflow. `neo-tree.ui.renderer` itself is untouched -- it is
    -- not what got reloaded.
    package.loaded["filetree.adapter.neotree"] = nil
    local gen2 = require("filetree.adapter.neotree")
    check("reload: re-require produced a genuinely different module table", gen2 ~= gen1)

    local gen2_hits = 0
    gen2.on_render(function()
      gen2_hits = gen2_hits + 1
    end)

    gen1_hits = 0 -- checkpoint: any further increment below would mean the orphaned generation is STILL live
    renderer.redraw(state)
    vim.wait(300, function()
      return gen2_hits > 0
    end, 20)

    check(
      "reload: generation 2's on_render fires after the reload (no orphaned wrapper)",
      gen2_hits == 1,
      tostring(gen2_hits)
    )
    check(
      "reload: exactly one notification per real redraw -- no stacked wrapper double-firing, "
        .. "and the orphaned generation 1 listener stays silent",
      gen2_hits == 1 and gen1_hits == 0,
      "gen2_hits=" .. gen2_hits .. " gen1_hits=" .. gen1_hits
    )

    pcall(gen2.close)
  end

  vim.cmd("tabonly")
end

::done::

print(("\nneotree_redraw_hook: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
