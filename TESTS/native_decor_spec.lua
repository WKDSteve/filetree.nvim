-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_decor_spec.lua -- decorators on the own tree: a registered decorator's badges are drawn
-- on the rows of its paths, a folder shows what lies below it (also one that was never opened), late
-- and removed decorators, keys that change, slots, what gives way in a narrow window, and a decorator
-- that raises.
--
--   nvim --clean --headless -u NONE -l TESTS/native_decor_spec.lua

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

-- No `vim.o.columns` / `vim.o.lines` in this file: a headless run has no UI, its screen grid stays
-- 80x24 whatever the options say, and the next forced redraw writes past it.

-- Results go to stdout directly: print() in a headless run goes through the message area.
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
local function ok(name, cond)
  eq(name, cond and true or false, true)
end

vim.g.have_nerd_font = false

local list = require("filetree.native.fs.list")
local native = require("filetree.native")
local view_mod = require("filetree.native.view")
local decor = require("filetree.native.decor")
local filetree = require("filetree")
require("filetree.config").setup({})
require("lib.nvim.tree.registry").reset()
local adapter = require("filetree.adapter.native")

local warnings = {}
local real_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level)
  if (level or vim.log.levels.INFO) >= vim.log.levels.WARN then
    warnings[#warnings + 1] = tostring(msg)
  end
end

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_decor_%d"):format(base, vim.uv.hrtime() % 1e9)
for _, rel in ipairs({
  "lua/mod/a.lua",
  "lua/mod/b.lua",
  "lua/init.lua",
  "docs/guide.md",
  "README.md",
}) do
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
end

---What the tree draws on the line of `path`: the chunks right of the name, the highlight laid over
---the name, and the highlight of the whole line. Ephemeral marks cannot be read back, so the call that
---places them is recorded.
local function drawn(path)
  local buf = adapter.get_bufnr()
  local line = adapter.get_node_line(path)
  local out = { right = {}, name_hl = nil, line_hl = nil }
  local real = vim.api.nvim_buf_set_extmark
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_buf_set_extmark = function(_, _, _, _, opts)
    if opts.virt_text then
      for _, chunk in ipairs(opts.virt_text) do
        out.right[#out.right + 1] = vim.trim(chunk[1]) .. (chunk[2] and (":" .. chunk[2]) or "")
      end
    elseif opts.line_hl_group then
      out.line_hl = opts.line_hl_group
    elseif opts.priority == 95 then
      out.name_hl = opts.hl_group
    end
    return 0
  end
  local okay, err = pcall(view_mod.decorate_line, buf, line - 1, adapter.get_winid())
  vim.api.nvim_buf_set_extmark = real
  if not okay then error(err, 0) end
  return out
end
local function settle()
  vim.wait(50, function()
    return false
  end)
end

-- ── a decorator registered before the tree opens ───────────────────────────────
local cache = {
  [dir .. "/lua/mod/a.lua"] = { text = "M", hl = "DiagnosticWarn", status = "modified" },
  [dir .. "/lua/mod/b.lua"] = { text = "A", hl = "DiagnosticOk", status = "added" },
}
local emit_git
local subscribed, unsubscribed = 0, 0
local remove_git = filetree.decorator({
  name = "spec_git",
  slot = "badge",
  roll_up = "worst",
  severity = { "conflict", "modified", "added" },
  get = function(path)
    return cache[path]
  end,
  all = function()
    return cache
  end,
  subscribe = function(emit)
    subscribed = subscribed + 1
    emit_git = emit
    return function()
      unsubscribed = unsubscribed + 1
    end
  end,
})
eq("registering asks nothing of the decorator", subscribed, 0)

adapter.toggle_at("left", { dir = dir })
eq("opening the tree subscribes", subscribed, 1)
eq("the decorator is followed", decor.names(), { "spec_git" })
eq(
  "a folder that was never opened shows the worst status below it",
  drawn(dir .. "/lua").right,
  { "M:DiagnosticWarn" }
)
eq("a folder with nothing below shows nothing", drawn(dir .. "/docs").right, {})
eq("a file without a badge shows nothing", drawn(dir .. "/README.md").right, {})
adapter.expand_node({ path = dir .. "/lua" })
adapter.expand_node({ path = dir .. "/lua/mod" })
eq("a file shows its own badge", drawn(dir .. "/lua/mod/b.lua").right, { "A:DiagnosticOk" })
eq("the folder in between rolls up too", drawn(dir .. "/lua/mod").right, { "M:DiagnosticWarn" })
eq("a sibling without a badge stays clean", drawn(dir .. "/lua/init.lua").right, {})

-- ── keys that change ───────────────────────────────────────────────────────────
local redraws = 0
local real_redraw = vim.api.nvim__redraw
---@diagnostic disable-next-line: duplicate-set-field
vim.api.nvim__redraw = function(opts)
  if opts.valid == false then redraws = redraws + 1 end
end
cache[dir .. "/lua/mod/a.lua"] = nil
emit_git({ dir .. "/lua/mod/a.lua" })
emit_git({ dir .. "/lua/mod/a.lua" })
eq("the folders follow at once", drawn(dir .. "/lua").right, { "A:DiagnosticOk" })
eq("the file lost its badge", drawn(dir .. "/lua/mod/a.lua").right, {})
settle()
eq("two changes in one tick ask for one redraw", redraws, 1)
vim.api.nvim__redraw = real_redraw

cache = { [dir .. "/docs/guide.md"] = { text = "C", hl = "DiagnosticError", status = "conflict" } }
emit_git() -- no keys: everything changed, the tree reads all() again
eq("after a full change the old folder is clean", drawn(dir .. "/lua").right, {})
eq("... and the new one shows it", drawn(dir .. "/docs").right, { "C:DiagnosticError" })

-- ── a decorator that arrives late, and one that goes ───────────────────────────
local counts = {
  [dir .. "/lua/mod/a.lua"] = { text = "3", status = "x" },
  [dir .. "/lua/mod/b.lua"] = { text = "1", status = "x" },
}
local remove_count = filetree.decorator({
  name = "spec_count",
  slot = "column",
  roll_up = "count",
  priority = 5,
  get = function(path)
    return counts[path]
  end,
  all = function()
    return counts
  end,
  subscribe = function()
    return function() end
  end,
})
eq(
  "a decorator registered while the tree is open is followed",
  decor.names(),
  { "spec_git", "spec_count" }
)
eq("roll_up = count shows how many paths below carry a badge", drawn(dir .. "/lua").right, { "2" })
eq(
  "badges of several decorators stand side by side, in registration order",
  drawn(dir .. "/docs").right,
  { "C:DiagnosticError" }
)
cache[dir .. "/lua/mod/a.lua"] = { text = "M", hl = "DiagnosticWarn", status = "modified" }
emit_git({ dir .. "/lua/mod/a.lua" })
eq("two decorators on one row", drawn(dir .. "/lua/mod/a.lua").right, { "M:DiagnosticWarn", "3" })

-- ── what gives way in a narrow window ──────────────────────────────────────────
local win = adapter.get_winid()
-- the line is 11 columns of indent and name; each item right of it costs 2 (a blank, one character)
vim.api.nvim_win_set_width(win, 14)
eq(
  "narrow: the column goes before the badge",
  drawn(dir .. "/lua/mod/a.lua").right,
  { "M:DiagnosticWarn" }
)
vim.api.nvim_win_set_width(win, 12)
eq("very narrow: only the name is left", drawn(dir .. "/lua/mod/a.lua").right, {})
vim.api.nvim_win_set_width(win, 32)

eq("unregistering answers true", remove_count(), true)
eq("... and the decorator is no longer followed", decor.names(), { "spec_git" })
eq("... nor drawn", drawn(dir .. "/lua/mod/a.lua").right, { "M:DiagnosticWarn" })

-- ── slots that are not right of the name ───────────────────────────────────────
local remove_name = filetree.decorator({
  name = "spec_name",
  slot = "name",
  get = function(path)
    return path:match("README") and { hl = "Underlined" } or nil
  end,
  subscribe = function()
    return function() end
  end,
})
local remove_line = filetree.decorator({
  name = "spec_line",
  slot = "line",
  get = function(path)
    return path:match("guide") and { hl = "CursorLine" } or nil
  end,
  subscribe = function()
    return function() end
  end,
})
adapter.expand_node({ path = dir .. "/docs" })
eq("slot name lays a highlight over the name", drawn(dir .. "/README.md").name_hl, "Underlined")
eq("... and draws nothing right of it", drawn(dir .. "/README.md").right, {})
eq("slot line highlights the whole line", drawn(dir .. "/docs/guide.md").line_hl, "CursorLine")
remove_name()
remove_line()

-- ── a decorator keyed by node id ───────────────────────────────────────────────
local remove_id = filetree.decorator({
  name = "spec_id",
  key = "id",
  get = function(id)
    return id == dir .. "/README.md" and { text = "id" } or nil
  end,
  subscribe = function()
    return function() end
  end,
})
eq("key = id is asked with the node's id", drawn(dir .. "/README.md").right, { "id" })
remove_id()

-- ── a decorator that raises ────────────────────────────────────────────────────
local asked = 0
filetree.decorator({
  name = "spec_broken",
  get = function()
    asked = asked + 1
    error("boom")
  end,
  subscribe = function()
    return function() end
  end,
})
eq(
  "the tree keeps drawing the others",
  drawn(dir .. "/lua/mod/a.lua").right,
  { "M:DiagnosticWarn" }
)
local first_asked = asked
drawn(dir .. "/lua/mod/b.lua")
eq("a decorator that raised is not asked again", asked, first_asked)
ok("... and is named once", #warnings == 1 and warnings[1]:find("spec_broken", 1, true) ~= nil)

-- ── the end of a decorator's life ──────────────────────────────────────────────
eq("unregistering unsubscribes", { remove_git(), unsubscribed }, { true, 1 })
eq("nothing is drawn for it any more", drawn(dir .. "/lua/mod/a.lua").right, {})
native.reset()
eq("reset stops following the registry", decor.names(), {})

vim.notify = real_notify
require("lib.nvim.tree.registry").reset()
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_decor_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
