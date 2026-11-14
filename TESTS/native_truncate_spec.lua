-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_truncate_spec.lua -- a name too long for the tree window: drawn cut with an ellipsis
-- while the buffer line keeps it whole, columns and badges given up before the name loses its minimum,
-- wide characters, a window scrolled sideways, and the float with the full name on the cursor line.
--
--   nvim --clean --headless -u NONE -l TESTS/native_truncate_spec.lua

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
local dir = ("%s/ft_trunc_%d"):format(base, vim.uv.hrtime() % 1e9)
local LONG = ("n"):rep(57) .. ".md" -- 60 characters
local WIDE = ("日本"):rep(15) .. ".md" -- 60 columns in 33 characters
for _, rel in ipairs({ LONG, WIDE, "short.md", "sub/x.md" }) do
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
end

local sw = vim.fn.strdisplaywidth

---What the tree draws on the line of `path`: the overlay that cuts the name (byte column and text)
---and the chunks right of the name. Ephemeral marks cannot be read back, so the call that places
---them is recorded.
local function drawn(path)
  local buf = adapter.get_bufnr()
  local line = adapter.get_node_line(path)
  local out = { right = {}, right_width = 0 }
  local real = vim.api.nvim_buf_set_extmark
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_buf_set_extmark = function(_, _, _, col, opts)
    if opts.virt_text and opts.virt_text_pos == "right_align" then
      for _, chunk in ipairs(opts.virt_text) do
        out.right[#out.right + 1] = vim.trim(chunk[1])
        out.right_width = out.right_width + sw(chunk[1])
      end
    elseif opts.virt_text and opts.virt_text_pos == "overlay" then
      out.cut_col, out.cut_text = col, opts.virt_text[1][1]
    end
    return 0
  end
  local okay, err = pcall(view_mod.decorate_line, buf, line - 1, adapter.get_winid())
  vim.api.nvim_buf_set_extmark = real
  if not okay then error(err, 0) end
  out.text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
  -- the columns the line takes on screen: what is left of the buffer text, the overlay, the items
  if out.cut_col then
    out.width = sw(out.text:sub(1, out.cut_col)) + sw(out.cut_text) + out.right_width
  end
  return out
end

local remove_badge = filetree.decorator({
  name = "spec_badge",
  slot = "badge",
  get = function(path)
    return (path:match("%.md$") and not path:match("short"))
        and { text = "M", hl = "DiagnosticWarn" }
      or nil
  end,
  subscribe = function()
    return function() end
  end,
})
local remove_column = filetree.decorator({
  name = "spec_column",
  slot = "column",
  get = function(path)
    return path:match("%.md$") and { text = "9k" } or nil
  end,
  subscribe = function()
    return function() end
  end,
})

adapter.toggle_at("left", { dir = dir })
local win = adapter.get_winid()
local buf = adapter.get_bufnr()
local view = native.current()
local long, wide, short = dir .. "/" .. LONG, dir .. "/" .. WIDE, dir .. "/short.md"

-- ── a name that fits ───────────────────────────────────────────────────────────
vim.api.nvim_win_set_width(win, 32)
eq("a name that fits is not cut", drawn(short).cut_col, nil)
eq(
  "... and has no full name to show",
  view_mod.cut_name(buf, adapter.get_node_line(short) - 1, win),
  nil
)

-- ── 20 columns, a name of 60 characters ────────────────────────────────────────
vim.api.nvim_win_set_width(win, 20)
local d = drawn(long)
ok("the buffer line keeps the whole name", d.text:find(LONG, 1, true) ~= nil)
ok("the name is drawn cut", d.cut_col ~= nil)
ok("the cut ends in an ellipsis", d.cut_text and d.cut_text:find("^…") ~= nil)
ok("the cut lies inside the name", d.cut_col and d.cut_col > d.text:find(LONG, 1, true))
eq("the line fills the window exactly", d.width, 20)
eq("the name keeps its 12 columns: badge and column still fit", d.right, { "M", "9k" })

vim.api.nvim_win_set_width(win, 16)
d = drawn(long)
eq("narrower: the column is given up before the name loses more", d.right, { "M" })
eq("... and the line fills the window", d.width, 16)

vim.api.nvim_win_set_width(win, 12)
d = drawn(long)
eq("very narrow: badge and column are given up", d.right, {})
ok("... and only then the name is cut below its 12 columns", d.cut_col ~= nil)
eq("... to the width of the window", d.width, 12)

vim.api.nvim_win_set_width(win, 3)
ok("a window narrower than the indent draws without an error", pcall(drawn, long))

-- ── wide characters ────────────────────────────────────────────────────────────
vim.api.nvim_win_set_width(win, 21)
d = drawn(wide)
ok("a name of double-width characters is cut", d.cut_col ~= nil)
eq("... and padded to the column the items start at", d.width, 21)
ok(
  "... on a character boundary",
  vim.fn.strchars(d.text:sub(1, d.cut_col)) > 0
    and d.text:sub(1, d.cut_col):find("[\128-\191]$") ~= nil
)

-- ── scrolled sideways ──────────────────────────────────────────────────────────
vim.api.nvim_win_set_width(win, 20)
if vim.fn.getwininfo(win)[1].leftcol ~= nil then
  vim.api.nvim_set_current_win(win)
  view:set_cursor(adapter.get_node_line(long))
  vim.cmd("normal! 10zl")
  if vim.fn.getwininfo(win)[1].leftcol > 0 then
    eq(
      "scrolled sideways: the rest of the name is readable, nothing drawn over it",
      drawn(long).cut_col,
      nil
    )
  else
    say("  n/a  the window did not scroll sideways")
  end
  vim.cmd("normal! ze0")
  vim.fn.winrestview({ leftcol = 0 })
end

-- ── the full name next to the cursor line ──────────────────────────────────────
local function float_text()
  local float = view._name_win
  if not float or not vim.api.nvim_win_is_valid(float) then return nil end
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)[1]
end
local function cursor_on(path)
  vim.api.nvim_win_set_cursor(win, { adapter.get_node_line(path), 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
end
vim.api.nvim_set_current_win(win)
local wins_before = #vim.api.nvim_list_wins()
cursor_on(long)
eq("the cursor on a cut name shows the full name", float_text(), LONG)
local float = view._name_win
eq("... in a float of the tree window", vim.api.nvim_win_get_config(float).relative, "win")
eq("... that cannot be entered", vim.api.nvim_win_get_config(float).focusable, false)
eq("... and the tree stays the current window", vim.api.nvim_get_current_win(), win)
cursor_on(wide)
eq("the next cut name replaces it", float_text(), WIDE)
ok("... the old float is closed", not vim.api.nvim_win_is_valid(float))
cursor_on(short)
eq("a name that fits shows none", float_text(), nil)
eq("... and no window is left over", #vim.api.nvim_list_wins(), wins_before)
cursor_on(long)
vim.cmd("wincmd p")
if vim.api.nvim_get_current_win() == win then vim.cmd("wincmd w") end
eq("leaving the tree takes the float away", float_text(), nil)
vim.api.nvim_set_current_win(win)
cursor_on(long)
ok("back in the tree it shows again", float_text() ~= nil)
vim.api.nvim_win_set_width(win, 90)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
if vim.api.nvim_win_get_width(win) >= 70 then
  eq("a window wide enough for the name shows none", float_text(), nil)
else
  say("  n/a  the window could not be made wide enough")
end
vim.api.nvim_win_set_width(win, 20)
cursor_on(long)
adapter.close()
eq("closing the tree takes the float away", float_text(), nil)

-- ── switched off ───────────────────────────────────────────────────────────────
native.reset()
native.setup({ name_float = false })
adapter.toggle_at("left", { dir = dir })
win, buf, view = adapter.get_winid(), adapter.get_bufnr(), native.current()
vim.api.nvim_win_set_width(win, 20)
vim.api.nvim_set_current_win(win)
cursor_on(long)
eq("name_float = false: no float", float_text(), nil)
ok("... the name is cut all the same", drawn(long).cut_col ~= nil)

remove_badge()
remove_column()
native.reset()
vim.notify = real_notify
require("lib.nvim.tree.registry").reset()
vim.fn.delete(dir, "rf")

eq("no warning along the way", warnings, {})
say(("\nfiletree.nvim native_truncate_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
