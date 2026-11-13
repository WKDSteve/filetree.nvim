-- group_empty_dirs_collapse.lua — regression test for `<S-CR>` collapsing a
-- neo-tree `group_empty_dirs` merged node, against a REAL neo-tree.
--
-- Bug report: a chain of directories holding nothing but another single
-- directory (`personal/All/Finish`, no files until the last one) renders as
-- one merged line. neo-tree rebuilds that line from scratch on every
-- lazy-loaded level (see `adapter/neotree.lua:collapse_node`'s doc comment
-- for the full mechanism), so it never reports itself as expanded and `<CR>`
-- can only ever drill deeper — there was no way back to `personal` short of
-- restarting the tree. `open_variants.open_badd_or_collapse()` (`<S-CR>`) is
-- the fix; this suite drives the actual neo-tree keymaps (not the adapter
-- function directly) to prove the fix holds through the real merge/replace
-- machinery, not just against a hand-built node shape.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/group_empty_dirs_collapse.lua
--
-- Not applicable (exit 0, an n/a line) when neo-tree/nui/lib.nvim aren't found — same
-- resolution rules as adapter_lines.lua.

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
  -- places TESTS/minimal_init_sheet_neotree.lua searches.
  local candidates = {}
  for _, e in ipairs(env) do
    local v = vim.env[e]
    if v and v ~= "" then candidates[#candidates + 1] = v end
  end
  local parent = vim.fn.fnamemodify(root_dir, ":h")
  for _, name in ipairs(names) do
    local dir_env = vim.env[(name:upper():gsub("[^%w]", "_")) .. "_DIR"]
    if dir_env and dir_env ~= "" then candidates[#candidates + 1] = dir_env end
    candidates[#candidates + 1] = root_dir .. "/.deps/" .. name
    candidates[#candidates + 1] = parent .. "/" .. name
    candidates[#candidates + 1] = parent .. "/.test-plugins/" .. name
    candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/" .. name
    local appdata, home = vim.env.LOCALAPPDATA, vim.env.HOME
    if appdata and appdata ~= "" then
      candidates[#candidates + 1] = appdata .. "/nvim-data/lazy/" .. name
    end
    if home and home ~= "" then
      candidates[#candidates + 1] = home .. "/.local/share/nvim/lazy/" .. name
    end
  end
  for _, c in ipairs(candidates) do
    local norm = vim.fs.normalize(c)
    if vim.fn.isdirectory(norm .. "/" .. probe) == 1 then
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

local has_lib = resolve({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }, { "lib.nvim" }, "lua/lib")
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

if not (has_neotree and has_nui and has_lib) then
  print("n/a  group_empty_dirs_collapse: neo-tree/nui/lib.nvim not installed")
  vim.cmd("qa!")
  return
end

local function slash(p)
  return (tostring(p):gsub("\\", "/"))
end

-- ── Fixture: personal/All/Finish/leaf.txt -- a chain of single-child dirs,
-- exactly the shape group_empty_dirs merges into one display line.
local work = slash((vim.env.TEMP or "/tmp") .. "/filetree-groupempty")
vim.fn.delete(work, "rf")
vim.fn.mkdir(work .. "/personal/All/Finish", "p")
vim.fn.writefile({ "leaf" }, work .. "/personal/All/Finish/leaf.txt")
vim.fn.writefile({ "sibling" }, work .. "/other.txt") -- a second top-level entry, so root isn't a single-child chain itself
-- An ORDINARY top-level directory, never expanded -- not a group_empty_dirs
-- chain (two children, not one), so it must never be confused with a merged
-- node. See the <S-CR>-on-an-unopened-directory check near the end of this file.
vim.fn.mkdir(work .. "/src", "p")
vim.fn.writefile({ "a" }, work .. "/src/a.lua")
vim.fn.writefile({ "b" }, work .. "/src/b.lua")

vim.cmd("cd " .. vim.fn.fnameescape(work))

require("neo-tree").setup({
  close_if_last_window = false,
  filesystem = {
    use_libuv_file_watcher = false,
    follow_current_file = { enabled = false },
    group_empty_dirs = true,
    scan_mode = "shallow", -- the plugin default; explicit since the merge only shows up level-by-level in this mode
  },
  window = { position = "left", width = 40 },
})

require("filetree").setup({ adapter = "neotree" })
local adapter = require("filetree.adapter.neotree")

-- Counts calls to neo-tree's own filesystem-rescan refresh, without changing
-- its behavior, so the <S-CR>-on-an-ordinary-directory check below can prove
-- a no-op stays a no-op instead of silently forcing a full disk rescan.
local manager = require("neo-tree.sources.manager")
local refresh_calls = 0
local orig_manager_refresh = manager.refresh
manager.refresh = function(...)
  refresh_calls = refresh_calls + 1
  return orig_manager_refresh(...)
end

require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = work })
vim.wait(6000, function()
  local b = adapter.get_bufnr()
  return b ~= nil and vim.api.nvim_buf_line_count(b) > 1
end, 50)
vim.wait(300, function()
  return false
end, 50)

local bufnr = adapter.get_bufnr()
local winid = adapter.get_winid()
check("the tree buffer exists", bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr))
check("the tree window exists", winid ~= nil and vim.api.nvim_win_is_valid(winid))
if not (bufnr and winid) then
  print(("\ngroup_empty_dirs_collapse: %d passed, %d failed"):format(passed, failed))
  vim.cmd(failed > 0 and "cq" or "qa!")
  return
end

---Line number (0-based) of the first buffer line containing `needle`.
---@param needle string
---@return integer?
local function find_line(needle)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i - 1 end
  end
  return nil
end

---Run the buffer-local normal-mode keymap for `lhs`, in the tree window.
---@param lhs string
---@return boolean
local function press(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs and type(m.callback) == "function" then
      local ok = pcall(vim.api.nvim_win_call, winid, m.callback)
      return ok
    end
  end
  return false
end

---Poll (up to 8s -- the real `<CR>`/group_empty_dirs path goes through an
---async fs scan + debounce that can take noticeably longer than a fixed
---short sleep) until `predicate()` is true, or give up.
---@param predicate fun(): boolean
---@return boolean
local function wait_for(predicate)
  return vim.wait(8000, predicate, 50)
end

local sep = require("neo-tree.utils").path_separator

-- 1st <CR> on "personal": merges in place to "personal\All" (still
-- collapsed). The real merge/replace goes through an async fs scan, so this
-- polls (wait_for) instead of a fixed sleep -- confirmed by hand to
-- sometimes land well past a 2-3s flat wait.
local personal_line = find_line("personal")
check("'personal' is rendered before any expand", personal_line ~= nil)
if personal_line then
  vim.api.nvim_win_set_cursor(winid, { personal_line + 1, 0 })
  check("pressed <CR> on 'personal'", press("<CR>"))
end

local merged1_ok = wait_for(function()
  return find_line("personal" .. sep .. "All") ~= nil
end)
check(
  "after 1st <CR>, the line reads 'personal" .. sep .. "All'",
  merged1_ok,
  table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), " | ")
)
local merged1 = find_line("personal" .. sep .. "All")

-- 2nd <CR> on that merged line: merges further to "personal\All\Finish".
if merged1 then
  vim.api.nvim_win_set_cursor(winid, { merged1 + 1, 0 })
  check("pressed <CR> on 'personal\\All'", press("<CR>"))
end

local merged2_ok = wait_for(function()
  return find_line("personal" .. sep .. "All" .. sep .. "Finish") ~= nil
end)
check(
  "after 2nd <CR>, the line reads 'personal" .. sep .. "All" .. sep .. "Finish'",
  merged2_ok,
  table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), " | ")
)
local merged2 = find_line("personal" .. sep .. "All" .. sep .. "Finish")

-- This is the bug: a 3rd <CR> on the SAME line only drills deeper (reveals
-- leaf.txt), it never collapses back to "personal". Confirm that's still
-- true before proving <S-CR> is the way out -- if neo-tree ever starts
-- toggling this cleanly on its own, this whole suite (and the collapse_node
-- fallback it exercises) should be revisited.
if merged2 then
  vim.api.nvim_win_set_cursor(winid, { merged2 + 1, 0 })
  press("<CR>")
end
check(
  "confirms the bug: <CR> on the merged line drilled deeper (revealed leaf.txt) instead of collapsing",
  wait_for(function()
    return find_line("leaf.txt") ~= nil
  end)
)

-- ── The fix: <S-CR> on the (still-drilled-open) merged line collapses it ────
local before_lines = vim.api.nvim_buf_line_count(bufnr)
local drilled_line = find_line("personal" .. sep .. "All" .. sep .. "Finish")
check("the merged line is still there before <S-CR>", drilled_line ~= nil)
if drilled_line then
  vim.api.nvim_win_set_cursor(winid, { drilled_line + 1, 0 })
  check("pressed <S-CR> on the merged, drilled-open line", press("<S-CR>"))
end
wait_for(function()
  return find_line("leaf.txt") == nil
end)

check(
  "<S-CR> made leaf.txt disappear from the tree",
  find_line("leaf.txt") == nil,
  table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), " | ")
)
check(
  "<S-CR> got the buffer back down towards its pre-drill line count",
  vim.api.nvim_buf_line_count(bufnr) < before_lines,
  ("before=%d after=%d"):format(before_lines, vim.api.nvim_buf_line_count(bufnr))
)
check("'personal' is visible again (collapsed) after <S-CR>", find_line("personal") ~= nil)
check(
  "...and it's genuinely un-merged, not just still reading 'personal"
    .. sep
    .. "All"
    .. sep
    .. "Finish'"
    .. " (a bare 'personal' substring match alone can't tell those apart)",
  find_line("personal" .. sep .. "All") == nil,
  table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), " | ")
)
check("the sibling 'other.txt' entry survived the refresh fallback", find_line("other.txt") ~= nil)

-- ── <S-CR> on an ORDINARY, never-expanded directory must be a true no-op ────
-- Regression check for a perf bug in the very fallback above: `src/` was
-- never opened, so it has the exact same loaded=false/is_expanded=false/
-- has_children=false shape neo-tree reports for a group_empty_dirs node
-- mid-merge (confirmed by hand) -- collapse_node must tell them apart via the
-- node's own name (a merged node's name IS the separator-joined chain, e.g.
-- "personal/All/Finish"; an ordinary directory's name is just its own
-- basename) rather than forcing a full filesystem rescan on every unopened
-- top-level directory.
-- Let any refresh still in flight from the merged-node collapse above fully
-- settle first -- otherwise its own (real, expected) tail end can land inside
-- this check's before/after window and read as a spurious extra call.
vim.wait(1000, function()
  return false
end, 50)

local src_line = find_line("src")
check("'src' (an ordinary, never-expanded directory) is rendered", src_line ~= nil)
if src_line then
  local refresh_calls_before = refresh_calls
  vim.api.nvim_win_set_cursor(winid, { src_line + 1, 0 })
  check("pressed <S-CR> on 'src'", press("<S-CR>"))
  vim.wait(500, function()
    return false
  end, 50)
  check(
    "<S-CR> on an unopened ordinary directory did NOT force a filesystem rescan",
    refresh_calls == refresh_calls_before,
    ("refresh_calls before=%d after=%d"):format(refresh_calls_before, refresh_calls)
  )
  check("'src' is still there, untouched", find_line("src") ~= nil)
end

manager.refresh = orig_manager_refresh
pcall(adapter.close)
print(("\ngroup_empty_dirs_collapse: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cq" or "qa!")
