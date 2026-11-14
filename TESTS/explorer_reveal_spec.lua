-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/explorer_reveal_spec.lua -- filetree.nvim signs in at `lib.nvim.explorer` to show a path, with
-- a backend that is not the own tree: the entry owns no buffer, reveals through the active adapter,
-- and is taken back when the backend cannot reveal.
--
--   nvim --clean --headless -u NONE -l TESTS/explorer_reveal_spec.lua

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

local function say(text)
  io.stdout:write(text, "\n")
end
local passed, failed = 0, 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    say("  ok   " .. name)
  else
    failed = failed + 1
    say(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local explorer = require("lib.nvim.explorer")
if type(explorer.reveal) ~= "function" then
  say("  n/a  this lib.nvim has no explorer.reveal yet")
  say("\nfiletree.nvim explorer_reveal_spec: 0 passed, 0 failed")
  vim.cmd("qa!")
end
explorer.reset()

local integration = require("filetree.integrations.explorer")
local adapters = require("filetree.adapter")

-- a backend that is not the own tree, with a tree buffer of its own filetype
local asked = {}
local answer = true
local backend = {
  name = "spec_backend",
  filetypes = { "spec_tree" },
  is_available = function()
    return true
  end,
  open_reveal = function(path)
    asked[#asked + 1] = path
    return answer
  end,
}
local real_get = adapters.get
---@diagnostic disable-next-line: duplicate-set-field
adapters.get = function()
  return backend
end

local function names()
  return vim.tbl_map(function(adapter)
    return adapter.name
  end, explorer.adapters())
end

eq("before setup nothing can reveal", explorer.can_reveal(), false)
eq("register answers true for a backend that can reveal", integration.register(backend), true)
eq("filetree is an explorer now", vim.tbl_contains(names(), "filetree"), true)
eq("... that can reveal", explorer.can_reveal(), true)
eq("reveal goes to the active adapter", { explorer.reveal("/proj/a.lua") }, { true, "filetree" })
eq("... with the path", asked, { "/proj/a.lua" })

local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "neo-tree"
eq(
  "the entry owns no buffer: a neo-tree buffer stays neo-tree's",
  explorer.current(buf),
  "neo-tree"
)
vim.bo[buf].filetype = "lua"
eq("... and an editor buffer nobody's", explorer.current(buf), nil)
eq("reload_all does not name it", vim.tbl_contains(explorer.reload_all(), "filetree"), false)

answer = false
eq("an adapter that could not show the path: false", { explorer.reveal("/proj/b.lua") }, { false })
backend.open_reveal = function()
  error("boom")
end
eq("an adapter that raises: false, no error", { explorer.reveal("/proj/c.lua") }, { false })

eq("registering again keeps one entry", integration.register(backend), true)
eq("... of that name", #vim.tbl_filter(function(name)
  return name == "filetree"
end, names()), 1)

backend.open_reveal = nil
eq("a backend that cannot reveal is not registered", integration.register(backend), false)
eq(
  "... and the entry of the setup before is taken back",
  vim.tbl_contains(names(), "filetree"),
  false
)
eq("... nothing can reveal", explorer.can_reveal(), false)

eq(
  "the own tree signs in by itself: nothing registered here",
  integration.register({ name = "native" }),
  false
)
eq("... no entry from this module", vim.tbl_contains(names(), "filetree"), false)

adapters.get = function()
  return nil
end
eq("without an active adapter reveal answers false", integration.reveal("/proj/a.lua"), false)

adapters.get = real_get
explorer.reset()
pcall(vim.api.nvim_buf_delete, buf, { force = true })

say(("\nfiletree.nvim explorer_reveal_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
