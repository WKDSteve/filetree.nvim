-- TESTS/mdview_open_spec.lua -- features.mdview_open opens the markdown node under the cursor
-- in mdview.nvim's preview, and only that.
--
-- mdview's `open()` previews the current buffer, so the feature loads the file into a buffer and
-- calls `open()` with that buffer current. The adapter and the mdview module are doubles here;
-- whether the real mdview then shows the page needs a running mdview session (a handcheck).
--
--   nvim --clean --headless -u NONE -l TESTS/mdview_open_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

-- lib.nvim, which filetree's util modules need (same search as the refs specs).
for _, dir in ipairs({
  vim.env.LIB_NVIM_DIR,
  vim.env.FILETREE_LIB_NVIM,
  vim.env.LIB_NVIM_PATH,
  vim.fn.fnamemodify(root, ":h") .. "/lib.nvim",
  vim.fn.stdpath("data") .. "/lazy/lib.nvim",
}) do
  if dir and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(vim.fs.normalize(dir))
    break
  end
end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end

local scratch = (vim.fn.tempname() .. "-ft-mdview"):gsub("\\", "/")
vim.fn.mkdir(scratch, "p")
local note = scratch .. "/Note.MD"
vim.fn.writefile({ "# hello" }, note)
local txt = scratch .. "/a.txt"
vim.fn.writefile({ "x" }, txt)

local mod = require("filetree.features.system.mdview_open")

check("is_markdown: .md", mod.is_markdown("/x/a.md"))
check("is_markdown: upper case .MD", mod.is_markdown(note))
check("is_markdown: .markdown", mod.is_markdown("/x/a.markdown"))
check("is_markdown: .txt is not", not mod.is_markdown(txt))
check("is_markdown: no extension is not", not mod.is_markdown("/x/README"))
check("is_markdown: nil is not", not mod.is_markdown(nil))

-- The cursor node the fake adapter reports.
local node
mod.setup({ enabled = true, keymap_open = false }, {
  get_current_node = function()
    return node
  end,
})

-- The warnings go through filetree's notifier, which ends in vim.notify.
local warned = {}
local real_notify = vim.notify
vim.notify = function(msg)
  warned[#warned + 1] = tostring(msg)
end
local function warned_with(text)
  for _, m in ipairs(warned) do
    if m:find(text, 1, true) then return true end
  end
  return false
end

-- mdview double: records the buffer that is current during open().
local opened_name, opened_calls = nil, 0
package.loaded["mdview"] = {
  open = function()
    opened_calls = opened_calls + 1
    opened_name = vim.api.nvim_buf_get_name(0)
  end,
}

local start_buf = vim.api.nvim_get_current_buf()

node = { type = "file", path = note }
mod.open()
-- A buffer name is the physical path (bufadd resolves symlinked directories: /var is /private/var
-- on macOS), the node keeps its spelling, so only the resolved forms are comparable.
local function eq(p)
  return vim.fs.normalize((vim.uv or vim.loop).fs_realpath(p) or p)
end
check("md node: mdview.open ran once", opened_calls == 1, tostring(opened_calls))
check(
  "md node: with the node's file as the current buffer",
  opened_name ~= nil and eq(opened_name) == eq(note),
  tostring(opened_name)
)
check("md node: the editor window keeps its buffer", vim.api.nvim_get_current_buf() == start_buf)
local nbuf = vim.fn.bufnr(note)
check("md node: the file buffer is loaded", nbuf > 0 and vim.api.nvim_buf_is_loaded(nbuf))
check("md node: and unlisted (it was not open before)", vim.bo[nbuf].buflisted == false)

opened_calls = 0
node = { type = "file", path = txt }
mod.open()
check("non-markdown node: mdview is not called", opened_calls == 0)
check("non-markdown node: warns", warned_with("No markdown file"))

node = { type = "directory", path = scratch .. "/dir.md" }
mod.open()
check("folder named *.md: mdview is not called", opened_calls == 0)

node = nil
mod.open()
check("no node: mdview is not called", opened_calls == 0)

-- mdview.nvim missing: a warning, no error.
package.loaded["mdview"] = nil
-- A preload that fails stands in for a module that is not installed.
package.preload["mdview"] = function()
  error("module 'mdview' not found")
end
node = { type = "file", path = note }
warned = {}
local ok = pcall(mod.open)
package.preload["mdview"] = nil
check("mdview missing: no error", ok)
check("mdview missing: warns", warned_with("mdview.nvim is not installed"))

vim.notify = real_notify
vim.fn.delete(scratch, "rf")
print(("\nfiletree.nvim mdview_open_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
