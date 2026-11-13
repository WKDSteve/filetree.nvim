---@diagnostic disable: need-check-nil, missing-fields
-- quickpick_neotree.lua -- the numbered quick-pick mode against a REAL neo-tree.
--
-- `TESTS/quickpick.lua` drives the mode against a fake adapter that owns a
-- buffer; what it cannot show is neo-tree itself: that the node list the
-- adapter reads off the nui tree lines up with what neo-tree drew, that a
-- folder number really loads and shows its children (neo-tree scans a
-- never-opened directory asynchronously), that the open lands in an editor
-- window, and that neo-tree's own buffer-local keys come back byte for byte.
--
-- Needs neo-tree.nvim + nui.nvim (+ plenary, devicons) and prints an n/a line
-- without them, like `adapter_lines.lua`; gated on CI like it.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/quickpick_neotree.lua
--
-- $FILETREE_NEOTREE points at a neo-tree checkout. Exit 0 = passed or skipped.

io.stdout:setvbuf("line")
vim.opt.swapfile = false
vim.opt.shortmess:append("A")

local this = debug.getinfo(1, "S").source:sub(2)
local root_dir = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root_dir)
package.path = table.concat({
  root_dir .. "/lua/?.lua",
  root_dir .. "/lua/?/init.lua",
  package.path,
}, ";")

---@param env string[]
---@param names string[]
---@param probe string
---@return string?
local function resolve(env, names, probe)
  -- Looked up in, in this order: the named variables, $<NAME>_DIR ($NEO_TREE_NVIM_DIR, ...),
  -- <repo>/.deps/<name>, a sibling ../<name> (what CI checks out: neo-tree, nui and plenary at
  -- pinned commits), ../.test-plugins/<name>, stdpath("data")/lazy/<name>, and the lazy.nvim
  -- directory of the real editor (under testing.nvim the child's own stdpath is a sandbox) -- the
  -- places TESTS/minimal_init_sheet_neotree.lua searches. A checkout found on its own (not named
  -- by a variable) of what CI pins is used only at the pinned commit (TESTS/neotree_pins.lua).
  local candidates = {} ---@type { [1]: string, [2]: string? }[] dir, name to check against its pin
  for _, e in ipairs(env) do
    local v = vim.env[e]
    if v and v ~= "" then candidates[#candidates + 1] = { v } end
  end
  local parent = vim.fn.fnamemodify(root_dir, ":h")
  for _, name in ipairs(names) do
    local dir_env = vim.env[(name:upper():gsub("[^%w]", "_")) .. "_DIR"]
    if dir_env and dir_env ~= "" then candidates[#candidates + 1] = { dir_env } end
    candidates[#candidates + 1] = { root_dir .. "/.deps/" .. name, name }
    candidates[#candidates + 1] = { parent .. "/" .. name, name }
    candidates[#candidates + 1] = { parent .. "/.test-plugins/" .. name, name }
    candidates[#candidates + 1] = { vim.fn.stdpath("data") .. "/lazy/" .. name, name }
    local appdata, home = vim.env.LOCALAPPDATA, vim.env.HOME
    if appdata and appdata ~= "" then
      candidates[#candidates + 1] = { appdata .. "/nvim-data/lazy/" .. name, name }
    end
    if home and home ~= "" then
      candidates[#candidates + 1] = { home .. "/.local/share/nvim/lazy/" .. name, name }
    end
  end
  local pins = dofile(root_dir .. "/TESTS/neotree_pins.lua")
  local seen = {} -- stdpath("data")/lazy and ~/.local/share/nvim/lazy are often one directory
  for _, c in ipairs(candidates) do
    local norm = vim.fs.normalize(c[1])
    local found = not seen[norm] and vim.fn.isdirectory(norm .. "/" .. probe) == 1
    seen[norm] = true
    local off = found and c[2] and pins.off_pin(c[2], norm)
    if off then print("  note " .. off) end
    if found and not off then
      vim.opt.rtp:prepend(norm)
      package.path = table.concat({
        norm .. "/lua/?.lua",
        norm .. "/lua/?/init.lua",
        package.path,
      }, ";")
      return norm
    end
  end
  return nil
end

resolve({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }, { "lib.nvim" }, "lua/lib")
resolve({ "FILETREE_UI_NVIM", "UI_NVIM_PATH" }, { "ui.nvim" }, "lua/ui")
resolve({}, { "plenary.nvim" }, "lua/plenary")
resolve({}, { "nvim-web-devicons" }, "lua/nvim-web-devicons")
local has_nui = resolve({}, { "nui.nvim" }, "lua/nui")
local has_neotree = resolve({ "FILETREE_NEOTREE" }, { "neo-tree.nvim" }, "lua/neo-tree")

if not (has_nui and has_neotree) then
  print("n/a  quickpick_neotree: neo-tree/nui not installed")
  vim.cmd("qa!")
  return
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
local function eq(name, got, want)
  check(name, got == want, ("got %s want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local function slash(p)
  return (tostring(p):gsub("\\", "/"))
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

-- ── A real little project ─────────────────────────────────────────────────────
local work = slash(
  (vim.uv.fs_realpath(vim.env.TEMP or "/tmp") or vim.env.TEMP or "/tmp")
    .. "/filetree-quickpick-neotree"
)
vim.fn.delete(work, "rf")
vim.fn.mkdir(work .. "/src/deep", "p")
vim.fn.mkdir(work .. "/docs", "p")
vim.fn.writefile({ "-- a" }, work .. "/src/a.lua")
vim.fn.writefile({ "-- b" }, work .. "/src/b.lua")
vim.fn.writefile({ "-- x" }, work .. "/src/deep/x.lua")
vim.fn.writefile({ "# g" }, work .. "/docs/guide.md")
vim.fn.writefile({ "# readme" }, work .. "/README.md")
vim.fn.writefile({ "z" }, work .. "/z.txt")
vim.cmd("cd " .. vim.fn.fnameescape(work))

require("neo-tree").setup({
  close_if_last_window = false,
  filesystem = { use_libuv_file_watcher = false, follow_current_file = { enabled = false } },
  window = { position = "left", width = 40 },
})
require("filetree").setup({
  adapter = "neotree",
  features = {
    auto_reveal = { enabled = false },
    quickpick = { enabled = true, timeout_ms = 0 },
  },
})
local ft = require("filetree")
local qp = ft.feature("quickpick")
local adapter = require("filetree.adapter.neotree")

-- An editor window with a real file, so there is something to reveal and an
-- editor window for the opens to land in.
vim.cmd("edit " .. vim.fn.fnameescape(work .. "/README.md"))
local editor = vim.api.nvim_get_current_win()

---Labels drawn in the tree buffer, by 1-based line.
---@param buf integer
---@return table<integer, string>
local function ns_labels(buf)
  local ns = vim.api.nvim_get_namespaces()["filetree_quickpick"]
  local out = {}
  if not ns then return out end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local text = ""
    for _, chunk in ipairs(m[4].virt_text) do
      text = text .. chunk[1]
    end
    out[m[2] + 1] = text
  end
  return out
end

---The label drawn on the line that shows `name`.
---@param name string
---@return string?
local function number_of(name)
  local buf = qp.snapshot().buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local labels = ns_labels(buf)
  for i, text in ipairs(lines) do
    if text:find(name, 1, true) and labels[i] then return labels[i] end
  end
  return nil
end

print("-- boot: the tree is closed, the mode opens it on the file's folder")
check("the tree starts closed", not adapter.is_open())
eq("start accepts", qp.start(), true)
local booted = vim.wait(8000, function()
  return qp.is_active()
end, 50)
check("the mode starts once neo-tree has rendered", booted)
if not booted then
  print(("\nquickpick_neotree: %d passed, %d failed"):format(passed, failed))
  vim.cmd("cq")
  return
end

local snap = qp.snapshot()
local buf = snap.buf
eq("focus is on the tree window", vim.api.nvim_get_current_win(), snap.win)

print("-- labels sit on the line of the node they name")
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local labels = ns_labels(buf)
for i = 0, #lines - 1 do
  print(("  [%02d] %-30s %s"):format(i, (lines[i + 1] or ""):gsub("%s+$", ""), labels[i + 1] or ""))
end
local misaligned = {}
check("the tree's own root line carries no label", labels[1] == nil, tostring(labels[1]))
for _, n in ipairs(adapter.get_visible_nodes(nil, buf)) do
  if labels[n.line_number] then
    local text = lines[n.line_number] or ""
    if not text:find(n.name, 1, true) then misaligned[#misaligned + 1] = n.name end
  end
end
check(
  "every labelled line shows its node's own name",
  #misaligned == 0,
  table.concat(misaligned, ",")
)
check("something is numbered", snap.count >= 4, tostring(snap.count))
local first
for i = 1, #lines do
  if labels[i] then first = first or labels[i] end
end
eq("the first label is 00", first, "00")

-- Remember neo-tree's own mappings on the keys the mode takes over.
local watched = { "s", "t", "v", "c", "j", "k", "<CR>", "<Esc>", "a", "d", "q", "x" }
local function maps()
  local out = {}
  vim.api.nvim_buf_call(buf, function()
    for _, lhs in ipairs(watched) do
      local d = vim.fn.maparg(lhs, "n", false, true)
      if next(d) then
        out[lhs] = {
          buffer = d.buffer,
          rhs = d.rhs,
          desc = d.desc,
          nowait = d.nowait,
          noremap = d.noremap,
          silent = d.silent,
          has_cb = d.callback ~= nil,
        }
      else
        out[lhs] = false
      end
    end
  end)
  return out
end
qp.cancel()
local before = maps()
eq("(back in the editor)", vim.api.nvim_get_current_win(), editor)
local local_maps = 0
for _, m in pairs(before) do
  if m and m.buffer == 1 then local_maps = local_maps + 1 end
end
check("neo-tree has buffer-local maps on some of the watched keys", local_maps > 0)

print("-- folder number: neo-tree loads and shows the children")
qp.start()
check("the open tree is numbered at once", qp.is_active())
local entries_before = qp.snapshot().count
local src_no = number_of("src")
check("src has a number", src_no ~= nil, tostring(src_no))
press(src_no)
local grew = vim.wait(5000, function()
  return qp.is_active() and qp.snapshot().count > entries_before
end, 50)
check(
  "expanding src (never opened before) shows its children and renumbers",
  grew,
  ("count %s -> %s"):format(entries_before, qp.is_active() and qp.snapshot().count or "inactive")
)
check("the mode is still running after a folder", qp.is_active())

print("-- file number with a prefix: vsplit")
local function normal_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "" then n = n + 1 end
  end
  return n
end
local wins_before = normal_wins()
-- The node count can grow before neo-tree has drawn the new lines and the labels are on them (seen
-- on Linux under load): wait for the label of a.lua itself, never read it right away.
vim.wait(3000, function()
  return qp.is_active() and number_of("a.lua") ~= nil
end, 50)
local a_no = number_of("a.lua")
check("a.lua has a number", a_no ~= nil, tostring(a_no))
-- without a number there is nothing to press: the checks below fail instead of the script dying
if a_no then press("v" .. a_no) end
check("the mode ended", not qp.is_active())
eq("the file is open", slash(vim.fn.expand("%:p")), work .. "/src/a.lua")
check("in a new split next to the editor, not in the tree", normal_wins() > wins_before)
check("the current window is not the tree", vim.bo.filetype ~= "neo-tree")

print("-- neo-tree's own keys are back, exactly")
local after = maps()
local diff = {}
for _, lhs in ipairs(watched) do
  if not vim.deep_equal(before[lhs], after[lhs]) then
    diff[#diff + 1] = lhs .. ": " .. vim.inspect(before[lhs]) .. " -> " .. vim.inspect(after[lhs])
  end
end
check("every watched mapping is identical to what it was", #diff == 0, table.concat(diff, "; "))

print("-- cleanup")
local ns = vim.api.nvim_get_namespaces()["filetree_quickpick"]
eq("no extmarks left in the tree buffer", #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)
local floats = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(w).relative ~= "" then floats = floats + 1 end
end
eq("no badge float left", floats, 0)

pcall(adapter.close)
print(("\nquickpick_neotree: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed > 0 and "cq" or "qa!")
