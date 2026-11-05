-- Test code: when something here comes back nil the file must crash and name it.
---@diagnostic disable: need-check-nil
-- close_on_open_spec.lua -- `features.close_on_open`: the tree closes after a file
-- was opened from it, `<M-CR>` (hold) keeps it open, and open_replace's own keys
-- cooperate. The tree is a scratch buffer with the neo-tree filetype in a split;
-- "open from the tree" is what really happens: leave the tree window, show a file.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/close_on_open_spec.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

local function prepend_dep(envs, sibling, lazy_name, marker)
  local candidates = {}
  for _, env in ipairs(envs) do
    local v = vim.env[env]
    if v and v ~= "" then candidates[#candidates + 1] = v end
  end
  candidates[#candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/" .. sibling
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/" .. lazy_name
  for _, c in ipairs(candidates) do
    if vim.fn.isdirectory(c .. marker) == 1 then
      vim.opt.rtp:prepend(c)
      return
    end
  end
end
prepend_dep(
  { "FILETREE_LIB_NVIM", "LIB_NVIM_PATH", "LIB_NVIM_DIR" },
  "lib.nvim",
  "lib.nvim",
  "/lua/lib"
)

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
  check(name, got == want, ("got %s want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local coo = require("filetree.features.nav.close_on_open")
local orepl = require("filetree.features.fileops.open_replace")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local file_a, file_b, file_c = tmp .. "/a.txt", tmp .. "/b.txt", tmp .. "/c.txt"
for _, f in ipairs({ file_a, file_b, file_c }) do
  vim.fn.writefile({ "x" }, f)
end

local editor_win, tree_win, tree_buf
local closes
local cur_node

local stub = {
  name = "stub",
  is_open = function()
    return tree_win ~= nil and vim.api.nvim_win_is_valid(tree_win)
  end,
  close = function()
    closes = closes + 1
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
      vim.api.nvim_win_close(tree_win, true)
    end
  end,
  get_winid = function()
    return tree_win
  end,
  get_current_node = function()
    return cur_node
  end,
}

--- Fresh layout: an editor window on file_a and the tree split to its right,
--- focus in the tree.
local function layout()
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  closes = 0
  vim.cmd("edit " .. vim.fn.fnameescape(file_a))
  editor_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  tree_win = vim.api.nvim_get_current_win()
  tree_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[tree_buf].filetype = "neo-tree"
  vim.api.nvim_win_set_buf(tree_win, tree_buf)
end

--- What a backend's open does: focus the editor window, show the file there.
local function open_from_tree(file)
  vim.api.nvim_set_current_win(editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.wait(100, function()
    return false
  end)
end

local function tree_alive()
  return vim.api.nvim_win_is_valid(tree_win)
end

-- ── on: <CR> closes, hold keeps ───────────────────────────────────────────────

coo.setup({ enabled = true }, stub)

layout()
open_from_tree(file_b)
eq("a file opened from the tree closes it", tree_alive(), false)
eq("...through the adapter's close, once", closes, 1)
eq("...and the focus stays in the editor window", vim.api.nvim_get_current_win(), editor_win)

layout()
coo.hold()
open_from_tree(file_b)
eq("hold: the next open keeps the tree open", tree_alive(), true)
open_from_tree(file_c)
vim.api.nvim_set_current_win(tree_win)
open_from_tree(file_a)
eq("...and only that one: the open after it closes the tree again", tree_alive(), false)

layout()
coo.hold()
vim.wait(600, function()
  return false
end)
open_from_tree(file_b)
eq("a hold that nothing consumed expires (folder toggled with the key)", tree_alive(), false)

layout()
vim.api.nvim_set_current_win(editor_win)
vim.wait(600, function()
  return false
end)
vim.cmd("edit " .. vim.fn.fnameescape(file_b))
eq("`:edit` long after leaving the tree does not close it", tree_alive(), true)

layout()
vim.api.nvim_set_current_win(editor_win)
vim.api.nvim_set_current_win(tree_win)
eq("moving between windows without opening a file does not close it", tree_alive(), true)

layout()
local pbuf = vim.fn.bufadd(file_b)
vim.fn.bufload(pbuf)
local float = vim.api.nvim_open_win(pbuf, false, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 20,
  height = 5,
})
vim.api.nvim_set_current_win(editor_win)
vim.wait(100, function()
  return false
end)
eq("a preview float is not an open", tree_alive(), true)
pcall(vim.api.nvim_win_close, float, true)

-- ── open_replace cooperation ──────────────────────────────────────────────────

orepl.setup({ enabled = true, close_tree = false, swap_close_tree = false }, stub)
layout()
cur_node = { path = file_b, type = "file" }
vim.api.nvim_set_current_win(tree_win)
orepl.open_swap()
vim.wait(100, function()
  return false
end)
eq("open_replace swap with swap_close_tree = false keeps the tree open", tree_alive(), true)

orepl.setup({ enabled = true, close_tree = true, swap_close_tree = true }, stub)
layout()
vim.api.nvim_set_current_win(tree_win)
orepl.open_swap()
vim.wait(100, function()
  return false
end)
eq("...and swap_close_tree = true closes it", tree_alive(), false)

-- ── off ───────────────────────────────────────────────────────────────────────

coo.setup({ enabled = false }, stub)
layout()
open_from_tree(file_b)
eq("disabled: opening a file leaves the tree as it was", tree_alive(), true)

coo.teardown()
vim.fn.delete(tmp, "rf")
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
