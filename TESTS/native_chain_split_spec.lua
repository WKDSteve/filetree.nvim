-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_chain_split_spec.lua -- a merged line `chain/only/` whose first folder gets a second
-- entry through an announced file operation (no watcher): the line splits, the folder has a line of
-- its own again, and reveal finds the new file. In the files view and in the files section of a view
-- of sections.
--
--   nvim --clean --headless -u NONE -l TESTS/native_chain_split_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_chain_split_spec",
  setup = {
    native = { watch = false, views = { { "files" }, { name = "work", "buffers", "files" } } },
  },
  features = { file_watcher = { enabled = false } },
  files = { "chain/only/leaf.lua", "README.md" },
})
local dir, adapter = T.dir, T.adapter
local view = adapter.get_state()
for _, name in ipairs({ "files", "work" }) do
  view:show(name)
  T.settle(150)
  T.tree()
  local sub = name == "files" and "x" or "y"
  T.eq(name .. ": reveal through the merged line", view:reveal(dir .. "/chain/only/leaf.lua"), true)
  T.mkfile("chain/" .. sub .. ".lua")
  require("filetree.util.changed").emit("create", nil, dir .. "/chain/" .. sub .. ".lua")
  T.settle(400)
  T.eq(
    name .. ": reveal of the new file in the folder that was merged",
    view:reveal(dir .. "/chain/" .. sub .. ".lua"),
    true
  )
  T.eq(
    name .. ": the cursor is on it",
    (adapter.get_current_node() or {}).path,
    dir .. "/chain/" .. sub .. ".lua"
  )
  T.eq(name .. ": the folder has its own line", adapter.get_node_line(dir .. "/chain") ~= nil, true)
end
T.finish()
