-- neotree_refresh_spec.lua -- `adapter/neotree.lua` `M.refresh()` folds a burst of requests into one trailing refresh.
--
-- One user action can ask for several refreshes (a batch rename, a move, the file watcher on top of a fileop); each is a
-- full re-scan (~12 ms, 1 967 of them in 52 sessions). The first call of a burst runs at once, the calls inside the
-- window become ONE refresh when it ends. Against a stub of `neo-tree.sources.manager` (no neo-tree needed).
--
-- Usage: nvim --clean --headless -u NONE -l TESTS/neotree_refresh_spec.lua   (exit 1 = a check failed)

local this = debug.getinfo(1, "S").source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(this, ":p:h:h"))

local calls = {}
package.loaded["neo-tree.sources.manager"] = {
  refresh = function(source)
    calls[#calls + 1] = source
  end,
}
local adapter = require("filetree.adapter.neotree")

local function check(cond, msg)
  if not cond then error("FAIL " .. msg, 0) end
end

check(adapter.refresh() == true, "the first call of a burst refreshes at once and answers true")
check(#calls == 1 and calls[1] == "filesystem", "the first call reached the manager immediately")
for _ = 1, 5 do
  check(
    adapter.refresh() == true,
    "a call inside the window answers true (the refresh is on its way)"
  )
end
check(#calls == 1, "the burst has not refreshed again yet: " .. #calls)
check(
  vim.wait(1000, function()
    return #calls == 2
  end, 5),
  "the burst ends in ONE trailing refresh, not five: " .. #calls
)
vim.wait(150, function()
  return #calls > 2
end, 5)
check(#calls == 2, "and no more after it: " .. #calls)

-- a call after the window is a new burst
vim.wait(100)
adapter.refresh()
check(#calls == 3, "a call after the window runs at once again: " .. #calls)
print("neotree_refresh_spec: ok")
