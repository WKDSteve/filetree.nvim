-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/rename_stem_spec.lua -- where the rename prompt parks the cursor:
-- right before the extension of a file, at the end otherwise.
--
--   nvim --clean --headless -u NONE -l TESTS/rename_stem_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  for _, candidate in ipairs({
    vim.env[dep:upper():gsub("%.", "_") .. "_DIR"] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep,
    root .. "/.deps/" .. dep,
    vim.fn.stdpath("data") .. "/lazy/" .. dep,
  }) do
    if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua") == 1 then
      vim.opt.rtp:prepend(candidate)
      break
    end
  end
end

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s want %s"):format(name, tostring(got), tostring(want)))
  end
end

local stem_end = require("filetree.features.fileops.smart_rename").stem_end
eq("plain extension", stem_end("init.lua"), 4)
eq("last dot wins", stem_end("a.test.lua"), 6)
eq("no extension", stem_end("Makefile"), nil)
eq("dotfile", stem_end(".gitignore"), nil)
eq("trailing dot", stem_end("name."), nil)
eq("directory", stem_end("v1.2", true), nil)

-- ── the prompt itself: stubbed adapter, real kit.input window ──────────────────
local sr = require("filetree.features.fileops.smart_rename")
local current
sr.setup({ enabled = true }, {
  get_current_node = function()
    return current
  end,
  refresh = function()
    return true
  end,
})
local function prompt_cursor_col(name, node_type)
  current = { name = name, path = root .. "/" .. name, type = node_type }
  sr.rename_current()
  vim.wait(200, function()
    return false
  end)
  local win = vim.api.nvim_get_current_win()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(win)[2]
  vim.cmd("stopinsert")
  pcall(vim.api.nvim_win_close, win, true)
  return col, line
end
local col, line = prompt_cursor_col("init.lua", "file")
eq("prompt holds the old name", line, "init.lua")
eq("file: cursor before the extension", col, 4)
eq("multi-dot file: cursor before the last extension", (prompt_cursor_col("a.test.lua", "file")), 6)
eq("no extension: cursor at the end", (prompt_cursor_col("Makefile", "file")), 8)
eq("directory with a dot: cursor at the end", (prompt_cursor_col("v1.2", "directory")), 4)
sr.teardown()

sr.setup({ enabled = true, cursor = "end" }, {
  get_current_node = function()
    return current
  end,
  refresh = function()
    return true
  end,
})
eq("cursor = end: file keeps the cursor at the end", (prompt_cursor_col("init.lua", "file")), 8)
sr.teardown()

print(("\nfiletree.nvim rename_stem_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
