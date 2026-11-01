-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/refs_incomplete_spec.lua -- an incomplete reference scan is announced by the
-- flows that act on it (rename/move/copy via handle_result, delete via for_delete),
-- and a complete scan stays silent.
--
--   nvim --clean --headless -u NONE -l TESTS/refs_incomplete_spec.lua

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

local messages = {}
vim.notify = function(msg)
  messages[#messages + 1] = tostring(msg)
end
local function mentions_cut_short()
  for _, m in ipairs(messages) do
    if m:find("cut short", 1, true) then return true end
  end
  return false
end

local refs = require("filetree.refs")

local function handle(result)
  messages = {}
  refs.handle_result(result, {}, { op = "rename" }, function() end)
  return mentions_cut_short()
end
eq("handle_result: incomplete scan warns", handle({ refs = {}, incomplete = true }), true)
eq("handle_result: complete scan is silent", handle({ refs = {} }), false)

-- for_delete asks M.scan; stub it so no tree or rg is needed.
local real_scan = refs.scan
local function delete(result)
  messages = {}
  refs.scan = function(_, _, cb)
    cb(result)
  end
  refs.for_delete({ "x" }, {}, function() end)
  refs.scan = real_scan
  return mentions_cut_short()
end
eq("for_delete: incomplete scan warns", delete({ refs = {}, incomplete = true }), true)
eq("for_delete: complete scan is silent", delete({ refs = {} }), false)

print(("\nfiletree.nvim refs_incomplete_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then vim.cmd("cq") else vim.cmd("qa!") end
