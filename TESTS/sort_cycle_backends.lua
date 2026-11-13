---@diagnostic disable: missing-fields
-- sort_cycle_backends.lua — `adapter.set_sort` / `get_sort` and `features.nav.sort_cycle`
-- against a REAL neo-tree.
--
-- What a stub cannot answer: the order the real tree renders and where the cursor is
-- afterwards.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/sort_cycle_backends.lua
--
-- Gated on CI, which checks out neo-tree, nui and plenary at pinned commits; prints an n/a
-- line without neo-tree.
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

---Prepend the first candidate directory that looks like the plugin we want.
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
resolve({ "FILETREE_NVIMTREE" }, { "nvim-tree.lua" }, "lua/nvim-tree")

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

local function settle(ms)
  vim.wait(ms or 400, function()
    return false
  end, 25)
end

if not (has_neotree and has_nui) then
  print("n/a  neo-tree.nvim / nui.nvim not found (set FILETREE_NEOTREE)")
  vim.cmd("qa!")
  return
end

-- big.lua is the largest and the oldest, small.lua the smallest and the newest.
local work = vim.fs.normalize((vim.env.TEMP or "/tmp") .. "/filetree-sort-cycle")
vim.fn.delete(work, "rf")
vim.fn.mkdir(work, "p")
vim.fn.writefile({ string.rep("x", 3000) }, work .. "/big.lua")
vim.fn.writefile({ string.rep("x", 800) }, work .. "/mid.lua")
vim.fn.writefile({ "x" }, work .. "/small.lua")
local now = os.time()
vim.uv.fs_utime(work .. "/big.lua", now - 3000, now - 3000)
vim.uv.fs_utime(work .. "/mid.lua", now - 2000, now - 2000)
vim.uv.fs_utime(work .. "/small.lua", now - 1000, now - 1000)
vim.cmd("cd " .. vim.fn.fnameescape(work))

require("neo-tree").setup({
  close_if_last_window = false,
  filesystem = { use_libuv_file_watcher = false, follow_current_file = { enabled = false } },
  window = { position = "left", width = 40 },
})
require("filetree").setup({
  adapter = "neotree",
  features = {
    auto_reveal = { enabled = false },
    tree_toggle = { enabled = true },
    sort_cycle = { enabled = true },
  },
})
local adapter = require("filetree.adapter.neotree")
local feature = require("filetree.features.nav.sort_cycle")
require("filetree.features.nav.tree_toggle").toggle("left")
vim.wait(6000, function()
  return adapter.get_node_line(work .. "/big.lua") ~= nil
end, 50)
settle()

---The file names of the tree in rendered order.
---@return string
local function order()
  local bufnr = adapter.get_bufnr()
  local out = {}
  for line = 1, vim.api.nvim_buf_line_count(bufnr) do
    local node = adapter.get_node_at_line(bufnr, line - 1)
    if node and node.path and node.type == "file" then
      out[#out + 1] = vim.fn.fnamemodify(node.path, ":t:r")
    end
  end
  return table.concat(out, ",")
end

---Sort and wait until the render shows `want`.
---@param run fun()
---@param want string
---@return string got
local function sorted(run, want)
  run()
  vim.wait(6000, function()
    return order() == want
  end, 50)
  settle(150)
  return order()
end

check("default: name, ascending", order() == "big,mid,small", order())
local initial = adapter.get_sort()
check(
  "get_sort before any sort: name ascending",
  initial.kind == "name" and initial.descending == false
)

local got = sorted(function()
  adapter.set_sort("size", true)
end, "big,mid,small")
check("size, largest first", got == "big,mid,small", got)
got = sorted(function()
  adapter.set_sort("size", false)
end, "small,mid,big")
check("size, smallest first", got == "small,mid,big", got)
got = sorted(function()
  adapter.set_sort("mtime", true)
end, "small,mid,big")
check("modified, newest first", got == "small,mid,big", got)
got = sorted(function()
  adapter.set_sort("mtime", false)
end, "big,mid,small")
check("modified, oldest first", got == "big,mid,small", got)
got = sorted(function()
  adapter.set_sort("name", true)
end, "small,mid,big")
check("name, descending", got == "small,mid,big", got)
local s = adapter.get_sort()
check("get_sort reads it back", s.kind == "name" and s.descending == true)

local ok, reason = adapter.set_sort("nonsense")
check("unknown criterion is refused", ok == false and reason ~= nil)

-- the cursor stays on its entry when the order changes
adapter.set_sort("name", false)
settle(400)
adapter.scroll_to_line(adapter.get_node_line(work .. "/mid.lua"))
check("cursor starts on mid.lua", adapter.get_current_node().path:find("mid.lua", 1, true) ~= nil)
adapter.set_sort("size", false)
vim.wait(6000, function()
  return order() == "small,mid,big"
end, 50)
settle(300)
local cur = adapter.get_current_node()
check(
  "cursor identity: still on mid.lua after the re-sort",
  cur and cur.path:find("mid.lua", 1, true) ~= nil,
  cur and cur.path
)

-- the feature on top: cycle and reverse
adapter.set_sort("name", false)
settle(400)
got = sorted(function()
  feature.cycle()
end, "big,mid,small")
check("cycle: name -> size, largest first", got == "big,mid,small", got)
got = sorted(function()
  feature.reverse()
end, "small,mid,big")
check("reverse flips the direction", got == "small,mid,big", got)
feature.cycle()
settle(600)
check("cycle: size -> modified", adapter.get_sort().kind == "mtime")
feature.cycle()
settle(600)
check("cycle: modified -> name", adapter.get_sort().kind == "name")

vim.fn.delete(work, "rf")
print(("\nfiletree.nvim sort_cycle_backends: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
