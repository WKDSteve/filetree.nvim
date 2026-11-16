-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
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

-- A candidate the search named but could not read (locked, no permission): rename/move and delete
-- say which file, and delete hands on that its count is a lower bound.
local function names_unreadable()
  for _, m in ipairs(messages) do
    if m:find("could not be read", 1, true) and m:find("locked.md", 1, true) then return true end
  end
  return false
end
local unreadable = { refs = {}, unreadable = { "/p/locked.md", "/p/locked.md" } }
messages = {}
refs.handle_result(unreadable, {}, { op = "rename" }, function() end)
eq("handle_result: an unreadable file is named", names_unreadable(), true)
eq("handle_result: the file is named once", #messages, 1)
messages = {}
refs.handle_result({ refs = {} }, {}, { op = "rename" }, function() end)
eq("handle_result: nothing unreadable, nothing said", names_unreadable(), false)

local lower
refs.scan = function(_, _, cb)
  cb(unreadable)
end
messages = {}
refs.for_delete({ "x" }, {}, function(_, lower_bound)
  lower = lower_bound
end)
eq("for_delete: an unreadable file is named", names_unreadable(), true)
eq("for_delete: the refs are a lower bound", lower, true)
refs.scan = function(_, _, cb)
  cb({ refs = {} })
end
refs.for_delete({ "x" }, {}, function(_, lower_bound)
  lower = lower_bound
end)
eq("for_delete: a complete scan is final", lower, false)
refs.scan = real_scan

-- run_plan: a candidate that cannot be read is reported, not dropped in silence.
local scan = require("filetree.refs.scan")
local real_candidates, real_lines_of = scan.candidates, scan.lines_of
scan.candidates = function(_, _, _, _, cb)
  cb({ "/p/a.md", "/p/locked.md" })
end
scan.lines_of = function(file)
  if file == "/p/locked.md" then return nil end
  return { "[x](./target.md)" }
end
local got_refs, got_unreadable
scan.run_plan({
  needles = {},
  extensions = { "md" },
  extract = function(file, line)
    return { { file = file, line = line } }
  end,
}, { root = "/p", cfg = {} }, function(r, _, u)
  got_refs, got_unreadable = r, u
end)
scan.candidates, scan.lines_of = real_candidates, real_lines_of
eq("run_plan: the readable file's ref is found", got_refs and #got_refs, 1)
eq(
  "run_plan: the unreadable file is reported",
  got_unreadable and got_unreadable[1],
  "/p/locked.md"
)

print(("\nfiletree.nvim refs_incomplete_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
