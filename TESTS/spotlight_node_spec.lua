-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/spotlight_node_spec.lua -- the node under the cursor becomes a spotlight token;
-- spotlight.nvim missing only warns.
--
--   nvim --clean --headless -u NONE -l TESTS/spotlight_node_spec.lua

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

local warnings = {}
vim.notify = function(msg)
  warnings[#warnings + 1] = tostring(msg)
end

local current
local feature = require("filetree.features.search.spotlight_node")
feature.setup({ enabled = true }, {
  get_current_node = function()
    return current
  end,
})

-- spotlight.nvim absent: a warning, no error
package.loaded["spotlight"] = nil
package.preload["spotlight"] = nil
current = { path = "/proj/src/init.lua", type = "file" }
eq("absent spotlight: returns false", feature.spotlight(), false)
eq(
  "absent spotlight: warns",
  #warnings > 0 and warnings[#warnings]:find("not installed", 1, true) ~= nil,
  true
)

-- present: gets the basename
local added = {}
package.loaded["spotlight"] = {
  add = function(text)
    added[#added + 1] = text
  end,
}
eq("file: returns true", feature.spotlight(), true)
eq("file: basename passed on", added[1], "init.lua")
current = { path = "/proj/src", type = "directory" }
eq("directory: returns true", feature.spotlight(), true)
eq("directory: its name is passed on", added[2], "src")
current = nil
eq("no node: returns false", feature.spotlight(), false)
feature.teardown()
eq("after teardown: returns false", feature.spotlight(), false)

print(("\nfiletree.nvim spotlight_node_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
