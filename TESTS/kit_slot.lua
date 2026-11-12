---@diagnostic disable: missing-fields
-- Test doubles here implement only what the unit under test calls -- a full
-- FiletreeAdapter would be noise, not coverage.
-- kit_slot.lua -- headless tests for the ui/kit_slot feature.
--
-- The feature registers the tree at `lib.nvim.ui.kit.sidebar.register_foreign` so a kit sidebar and the tree agree
-- on one slot. A stub adapter (a split on a scratch buffer: `get_winid`, `close`, `open_cwd`, `get_position`) is
-- the whole seam the feature reads through, so the real kit does the exclusivity and only the tree is fake.
--
--   nvim --clean --headless -u NONE -l TESTS/kit_slot.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root_dir = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root_dir)

for _, env in ipairs({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" and vim.fn.isdirectory(v .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(v)
    break
  end
end
for _, c in ipairs({
  vim.fn.fnamemodify(root_dir, ":h") .. "/lib.nvim",
  vim.fn.stdpath("data") .. "/lazy/lib.nvim",
}) do
  if vim.fn.isdirectory(c .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(c)
    break
  end
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

local api = vim.api
local sidebar = require("lib.nvim.ui.kit.sidebar")
local feature = require("filetree.features.ui.kit_slot")

local function settle()
  vim.wait(80, function()
    return false
  end)
end

vim.cmd("enew")
local main = api.nvim_get_current_win()

-- ── The stub tree ────────────────────────────────────────────────────────────
local position = "left"
local tree = { buf = api.nvim_create_buf(false, true), closes = 0, opens = 0 }
local function tree_visible()
  return tree.win ~= nil and api.nvim_win_is_valid(tree.win)
end
local adapter = {
  name = "stub",
  get_winid = function()
    return tree_visible() and tree.win or nil
  end,
  get_position = function()
    return position
  end,
  close = function()
    tree.closes = tree.closes + 1
    if tree_visible() then api.nvim_win_close(tree.win, true) end
    return true
  end,
  open_cwd = function()
    tree.opens = tree.opens + 1
    vim.cmd("topleft vsplit")
    tree.win = api.nvim_get_current_win()
    api.nvim_win_set_buf(tree.win, tree.buf)
    api.nvim_set_current_win(main)
    return true
  end,
}

local function registered()
  return sidebar.get("filetree")
end

-- ── disabled: nothing registered ─────────────────────────────────────────────
adapter.open_cwd()
feature.setup({ enabled = false }, adapter)
settle()
check("disabled: the tree is not registered", registered() == nil)

-- ── enabled with the tree already open ───────────────────────────────────────
feature.setup({ enabled = true }, adapter)
settle()
check("enabled: an already open tree is registered", registered() ~= nil)
check("...as a left sidebar", registered() and registered().position == "left")
check("...and the kit sees it", registered() and registered():is_visible() == true)

-- ── a kit sidebar takes the slot, closing it brings the tree back ────────────
local kit_side = assert(sidebar.open({ name = "kit_slot_notes", position = "left", enter = false }))
check("a kit sidebar on the left holds the slot", kit_side:is_visible())
check("...the kit hid the tree through adapter.close", tree.closes == 1 and not tree_visible())
kit_side:close()
settle()
check(
  "closing it brings the tree back through adapter.open_cwd",
  tree_visible() and tree.opens == 2
)

-- ── the tree opened by hand displaces a kit sidebar in its slot ──────────────
adapter.close()
settle()
local k2 = assert(sidebar.open({ name = "kit_slot_two", position = "left", enter = false }))
check("a kit sidebar on the left (the tree is closed)", k2:is_visible() and not tree_visible())
adapter.open_cwd()
settle()
check("the tree opened by hand is seen", tree_visible())
check("...and it took the slot from the kit sidebar", not k2:is_visible())
adapter.close()
settle()
check("the tree closing by hand brings the kit sidebar back", k2:is_visible())
k2:close()
settle()

-- ── a tree that is not on a side takes no slot ───────────────────────────────
feature.teardown()
check("teardown unregisters the tree", registered() == nil)
position = "float"
adapter.open_cwd()
feature.setup({ enabled = true }, adapter)
settle()
check("a floating tree takes no slot", registered() == nil)
feature.teardown()
adapter.close()

-- ── a custom name ────────────────────────────────────────────────────────────
position = "right"
adapter.open_cwd()
feature.setup({ enabled = true, name = "my_tree" }, adapter)
settle()
local named = sidebar.get("my_tree")
check("the name option is the registered name", named ~= nil)
check("...on the side the adapter reports", named and named.position == "right")
feature.teardown()
check("teardown removes it again", sidebar.get("my_tree") == nil)

print(("\nkit_slot: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cq!")
