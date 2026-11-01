-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/hooks_emit_spec.lua -- the hooks_api bus is actually fed: trash,
-- move and copy_move emit before_/after_ events through util.hooks.
--
--   nvim --clean --headless -u NONE -l TESTS/hooks_emit_spec.lua

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
  if vim.deep_equal(got, want) then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s: got %s, want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end

local bus = require("filetree.features.infra.hooks_api")
local hooks = require("filetree.util.hooks")
local ft = require("filetree")

-- Without a bus the helper is a silent no-op.
eq("no bus: emit is a no-op", hooks.emit("before_delete", { path = "x" }), 0)

-- With the bus active, events reach subscribers; a failing subscriber does not break the emitter.
local real_feature = ft.feature
ft.feature = function(name)
  if name == "hooks_api" then return bus end
  return real_feature(name)
end
bus.clear()
local seen = {}
for _, ev in ipairs({
  "before_delete",
  "after_delete",
  "before_move",
  "after_move",
  "before_copy",
  "after_copy",
}) do
  bus.on(ev, function(d)
    seen[#seen + 1] = { ev, d }
  end)
end
eq("bus on: emit reaches the handler", hooks.emit("before_delete", { path = "p" }), 1)
eq("payload arrives", seen[1], { "before_delete", { path = "p" } })
bus.on("before_move", function()
  error("subscriber blew up")
end)
eq(
  "a raising subscriber does not raise out",
  pcall(hooks.emit, "before_move", { src = "a", dst = "b" }),
  true
)
seen = {}

-- trash (permanent mode: no OS trash involved) emits before_/after_delete.
local trash = require("filetree.features.fileops.trash")
trash.setup({ enabled = true, mode = "permanent", confirm = false }, { refresh = function() end })
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local f = dir .. "/gone.txt"
vim.fn.writefile({ "x" }, f)
local done_ok
trash.delete(f, function(ok)
  done_ok = ok
end)
vim.wait(2000, function()
  return done_ok ~= nil
end)
eq("delete succeeded", done_ok, true)
eq("delete emitted before then after", {
  seen[1] and seen[1][1],
  seen[1] and seen[1][2].path == f,
  seen[2] and seen[2][1],
  seen[2] and seen[2][2].ok,
}, { "before_delete", true, "after_delete", true })

-- move and copy_move carry emit sites (their I/O needs a live tree adapter).
local function src_of(rel)
  return table.concat(vim.fn.readfile(root .. "/lua/filetree/features/fileops/" .. rel), "\n")
end
local mv, cm = src_of("move/init.lua"), src_of("copy_move/init.lua")
eq(
  "move emits before/after_move",
  mv:find('hooks.emit("before_move"', 1, true) ~= nil
    and mv:find('hooks.emit("after_move"', 1, true) ~= nil,
  true
)
eq(
  "copy_move emits copy and move events",
  cm:find('hooks.emit("after_copy"', 1, true) ~= nil
    and cm:find('hooks.emit("after_move"', 1, true) ~= nil,
  true
)

ft.feature = real_feature
bus.clear()
vim.fn.delete(dir, "rf")

print(("\nfiletree.nvim hooks_emit_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
