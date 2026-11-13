-- neotree_collapse_redraw_coalesce.lua — `adapter/neotree.lua`'s
-- `M.redraw_soon()` coalescing helper, against a REAL neo-tree.
--
-- ── What this pins ──────────────────────────────────────────────────────────
--
-- The "modified"/"opened" icon blink on folder collapse (see the render-event
-- bridge section of docs/FEATURES/BACKENDS.md) was investigated as being
-- driven, on filetree's own side, by several independent triggers each
-- firing their own narrow `renderer.redraw` pass close together:
-- `collapse_node`'s own immediate redraw, and `opened_sync`'s debounced
-- buffer-lifecycle-driven redraw. `M.redraw_soon()` gives a caller whose
-- trigger isn't already synchronously tied to one structural mutation AND
-- isn't already debounced against itself a small coalescing window so a
-- burst of such requests collapses into one re-render. `opened_sync` turned
-- out to already satisfy that second condition on its own (its own debounce
-- reduces a burst to one call already), so it calls `redraw()` directly
-- instead — no production call site uses `redraw_soon` today; see its doc
-- comment on `adapter/neotree.lua` for the reasoning and `TESTS/units.lua`
-- for the regression check on `opened_sync` itself.
--
-- This suite pins the coalescing primitive itself against a real neo-tree +
-- real `neo-tree.ui.renderer.redraw`:
--   1. `M.redraw_soon()` called several times in a tight burst results in
--      exactly ONE real `renderer.redraw` call once the coalescing window
--      has elapsed, not one per call.
--   2. `M.redraw()` (used by `collapse_node`/`expand_node` directly, via the
--      shared `do_narrow_redraw`) stays synchronous and immediate — no
--      debounce delay, no coalescing with a concurrent `redraw_soon` burst.
--   3. A real `collapse_node` call still redraws immediately (unaffected by
--      this change).
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/neotree_collapse_redraw_coalesce.lua
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

require("filetree.adapter.neotree")

local work = slash(
  (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
    .. "/filetree-neotree-collapse-coalesce"
)
vim.fn.delete(work, "rf")
vim.fn.mkdir(work .. "/A/B", "p")
vim.fn.writefile({ "leaf" }, work .. "/A/B/leaf.txt")

require("neo-tree").setup({
  close_if_last_window = false,
  filesystem = { use_libuv_file_watcher = false, follow_current_file = { enabled = false } },
  window = { position = "left", width = 40 },
})

require("filetree").setup({
  adapter = "neotree",
  features = {
    opened_sync = { enabled = true, debounce_ms = 20 },
    auto_reveal = { enabled = false },
    cwd_mode = { enabled = false },
  },
})

do
  local adapter = require("filetree.adapter.neotree")

  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
  vim.wait(4000, function()
    local b = adapter.get_bufnr()
    if not b then return false end
    local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    return text:find("leaf.txt", 1, true) ~= nil or text:find("^A$", 1, false) ~= nil
  end, 50)

  local bufnr = adapter.get_bufnr()
  check("collapse-coalesce: the tree buffer exists", bufnr ~= nil, tostring(bufnr))
  if not bufnr then goto done end

  -- `collapse_node`/`expand_node` resolve state through the ambient
  -- "current tab" path (`get_state()`), not `state_for_bufnr` -- so the tree
  -- window must actually be focused, same as neotree_redraw_hook.lua's Part A.
  local tree_win = adapter.get_winid()
  check("collapse-coalesce: the tree window resolves", tree_win ~= nil)
  if tree_win then vim.api.nvim_set_current_win(tree_win) end

  ---Real keymap press (not the adapter's own `expand_node`, which assumes a
  ---directory's children are already loaded): drives neo-tree's OWN bound
  ---`<CR>` handler, which does the real async fs-scan-then-expand -- same
  ---technique as `group_empty_dirs_collapse.lua`'s `press`.
  ---@param lhs string
  ---@return boolean
  local function press(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs and type(m.callback) == "function" then
        return (pcall(vim.api.nvim_win_call, tree_win, m.callback))
      end
    end
    return false
  end

  -- Wrap the REAL, already filetree-patched `renderer.redraw` with a counting
  -- shim -- a plain field reassignment, seen by every caller that reaches it
  -- through a fresh field lookup (which is how `do_narrow_redraw` and every
  -- OTHER narrow-redraw call site in this codebase reach it; see
  -- `docs/FEATURES/BACKENDS.md`'s render-event bridge section for why that
  -- matters and which one caller does not).
  local renderer = require("neo-tree.ui.renderer")
  local real_redraw = renderer.redraw
  local redraw_calls = 0
  renderer.redraw = function(...)
    redraw_calls = redraw_calls + 1
    return real_redraw(...)
  end

  -- ── Check 1: a burst of M.redraw_soon() calls coalesces into one ──────────
  redraw_calls = 0
  for _ = 1, 5 do
    adapter.redraw_soon()
  end
  check(
    "collapse-coalesce: a burst of redraw_soon() calls has not redrawn yet (still coalescing)",
    redraw_calls == 0,
    tostring(redraw_calls)
  )
  vim.wait(200, function()
    return redraw_calls > 0
  end, 10)
  check(
    "collapse-coalesce: ... settles into exactly one real renderer.redraw call",
    redraw_calls == 1,
    tostring(redraw_calls)
  )

  -- ── Check 2: M.redraw() itself stays synchronous, no coalescing delay ────
  redraw_calls = 0
  adapter.redraw()
  check(
    "collapse-coalesce: M.redraw() redraws immediately, no wait needed",
    redraw_calls == 1,
    tostring(redraw_calls)
  )

  -- ── Check 3: a real collapse_node redraws immediately too ────────────────
  -- First expand "A" for real (neo-tree's own bound `<CR>`, which does the
  -- actual async fs-scan-then-expand -- `adapter.expand_node` assumes
  -- children are already loaded and is not a substitute here) so it has an
  -- expanded child to collapse back from.
  local a_line0 = adapter.get_node_line(work .. "/A")
  check("collapse-coalesce: the 'A' directory is in the rendered tree", a_line0 ~= nil)
  if a_line0 then
    vim.api.nvim_win_set_cursor(tree_win, { a_line0, 0 })
    check("collapse-coalesce: pressed <CR> on 'A'", press("<CR>"))
    vim.wait(2000, function()
      return adapter.get_node_line(work .. "/A/B") ~= nil
    end, 30)
  end
  local b_line = adapter.get_node_line(work .. "/A/B")
  check("collapse-coalesce: 'A' is genuinely expanded ('B' is now visible)", b_line ~= nil)

  local a_line1 = adapter.get_node_line(work .. "/A")
  local a_node = a_line1 and adapter.get_node_at_line(bufnr, a_line1 - 1)
  check("collapse-coalesce: 'A' resolves to a real node", a_node ~= nil)
  if a_node then
    redraw_calls = 0
    local collapsed = adapter.collapse_node(a_node)
    check("collapse-coalesce: collapse_node succeeds", collapsed == true)
    check(
      "collapse-coalesce: collapse_node's own redraw fires immediately, no wait needed",
      redraw_calls >= 1,
      tostring(redraw_calls)
    )
  end

  renderer.redraw = real_redraw
  pcall(adapter.close)
end

::done::

print(("\nneotree_collapse_redraw_coalesce: %d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
