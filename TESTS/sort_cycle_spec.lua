-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/sort_cycle_spec.lua -- the cycle order and the reverse key of features.nav.sort_cycle
-- against a stub adapter, and the message of an adapter that cannot sort.
--
--   nvim --clean --headless -u NONE -l TESTS/sort_cycle_spec.lua

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

local feature = require("filetree.features.nav.sort_cycle")

-- A stub that remembers the last sort it was told to apply.
local sort = { kind = "name", descending = false }
local stub = {
  name = "stub",
  get_sort = function()
    return { kind = sort.kind, descending = sort.descending }
  end,
  set_sort = function(kind, descending)
    sort = { kind = kind, descending = descending == true }
    return true
  end,
}
feature.setup({ enabled = true }, stub)

local function state()
  return sort.kind .. (sort.descending and ":desc" or ":asc")
end
eq("cycle 1: size, largest first", feature.cycle() and state(), "size:desc")
eq("cycle 2: modified, newest first", feature.cycle() and state(), "mtime:desc")
eq("cycle 3: back to name, A to Z", feature.cycle() and state(), "name:asc")
eq("reverse flips name", feature.reverse() and state(), "name:desc")
eq("reverse flips it back", feature.reverse() and state(), "name:asc")
feature.cycle()
eq("reverse keeps the criterion (size)", feature.reverse() and state(), "size:asc")

-- a failing backend is reported, not thrown
stub.set_sort = function()
  return false, "the tree has not been shown yet"
end
messages = {}
eq("failed sort returns false", feature.cycle(), false)
eq("failed sort says why", messages[#messages]:find("not been shown", 1, true) ~= nil, true)

-- a backend without the methods says it is not applicable
feature.setup({ enabled = true }, { name = "oil" })
messages = {}
eq("unsupported adapter: false", feature.cycle(), false)
eq("unsupported adapter: names it", messages[#messages]:find("not applicable: the oil adapter", 1, true) ~= nil, true)

feature.teardown()
print(("\nfiletree.nvim sort_cycle_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then vim.cmd("cq") else vim.cmd("qa!") end
