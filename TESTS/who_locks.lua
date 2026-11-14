---@diagnostic disable: need-check-nil, missing-fields
-- who_locks.lua — headless tests for features/infra/who_locks.
--
-- No real neo-tree and no real Restart Manager: `neo-tree...fs_watch` is a stub
-- whose `show_watched` closes over a `watchers` upvalue (the exact seam the
-- module reads), and `lib.nvim.cross.fs.lock` is a double.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/who_locks.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root_dir = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root_dir)

for _, env in ipairs({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" and vim.fn.isdirectory(v .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(v)
    break
  end
end
for _, c in ipairs({
  vim.fn.fnamemodify(root_dir, ":h") .. "/lib.nvim",
  vim.fn.stdpath("data") .. "/lazy/lib.nvim",
}) do
  if vim.fn.isdirectory(c .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(c)
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
    print("  FAIL " .. name .. (detail and ("  — " .. detail) or ""))
  end
end

-- ── Doubles ───────────────────────────────────────────────────────────────────
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local file = tmp .. "/locked.txt"
vim.fn.writefile({ "x" }, file)

local watchers = {
  [tmp] = { references = 2, active = true, handle = {} },
  [tmp .. "/elsewhere"] = { references = 1, active = true, handle = {} },
}
package.loaded["neo-tree"] = {}
package.loaded["neo-tree.sources.filesystem.lib.fs_watch"] = {
  show_watched = function()
    return watchers
  end,
}
package.loaded["lib.nvim.cross.fs.lock"] = {
  probe = function()
    return false, "EBUSY"
  end,
  supported = function()
    return true
  end,
  who = function(_, cb)
    cb({ { name = "other.exe", pid = 42 } })
  end,
  report = function(_, cb)
    cb({ "path: x", "probe: EBUSY" })
  end,
}

local printed = {}
local real_print = print
_G.print = function(...)
  printed[#printed + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
end

local who = require("filetree.features.infra.who_locks")

-- ── --json output ─────────────────────────────────────────────────────────────
who.run(file, true)
_G.print = real_print
local ok, decoded = pcall(vim.json.decode, printed[#printed] or "")
check("json output decodes", ok, tostring(decoded))
if ok then
  check(
    "json: probe reports EBUSY",
    decoded.probe.renameable == false and decoded.probe.error == "EBUSY"
  )
  check("json: holder listed", decoded.holders.list[1].pid == 42)
  check(
    "json: watchers ok, 2 total",
    decoded.watchers.status == "ok" and decoded.watchers.total == 2
  )
  check("json: only the file's folder matches", #decoded.watchers.entries == 1)
  check("json: buffer not open", decoded.buffer.open == false)
end

-- ── unreachable watcher table ─────────────────────────────────────────────────
package.loaded["neo-tree.sources.filesystem.lib.fs_watch"] = { show_watched = function() end }
printed = {}
_G.print = function(...)
  printed[#printed + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
end
who.run(file, true)
_G.print = real_print
local ok2, d2 = pcall(vim.json.decode, printed[#printed] or "")
check("json: unreachable table reported", ok2 and d2.watchers.status == "unreachable")

-- ── neo-tree not loaded ───────────────────────────────────────────────────────
package.loaded["neo-tree"] = nil
printed = {}
_G.print = function(...)
  printed[#printed + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
end
who.run(file, true)
_G.print = real_print
local ok3, d3 = pcall(vim.json.decode, printed[#printed] or "")
check("json: not_loaded reported", ok3 and d3.watchers.status == "not_loaded")

-- ── the own tree's watchers ───────────────────────────────────────────────────
---Run who_locks on `file` and return what it printed last: the JSON object decoded, or the text.
---@param as_json boolean
local function ran(as_json)
  printed = {}
  _G.print = function(...)
    printed[#printed + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
  end
  local real_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function() end
  who.run(file, as_json)
  vim.notify = real_notify
  _G.print = real_print
  local last = printed[#printed] or ""
  if not as_json then return last end
  local decodes, value = pcall(vim.json.decode, last)
  return decodes and value or {}
end
---The state `filetree.fs_state()` answers, for the length of `fn`.
---@param state table
---@param fn fun()
local function with_state(state, fn)
  local real = package.loaded["filetree"]
  package.loaded["filetree"] = {
    fs_state = function()
      return vim.tbl_extend("keep", state, {
        active = true,
        watch = true,
        recursive = false,
        watchers = {},
        released = {},
        quarantined = {},
        changed = {},
        reading = {},
        roots = {},
        stats = { events = 0, reports = 0, quarantined = 0 },
      })
    end,
  }
  local okay, err = pcall(fn)
  package.loaded["filetree"] = real
  if not okay then error(err, 0) end
end
local slashed = (tmp:gsub("\\", "/"))
local parent = vim.fn.fnamemodify(slashed, ":h")

check("own tree: not the backend, no handle -> inactive", ran(true).own_tree.status == "inactive")
do
  local text = ran(false)
  check(
    "text: says that the own tree holds nothing",
    text:find("not the active backend", 1, true) ~= nil
  )
  check(
    "text: neo-tree's section stays while the own tree is not the backend",
    text:find("neo-tree fs_event watchers:", 1, true) ~= nil
  )
end

with_state({ watchers = { { dir = slashed, refs = 2 }, { dir = parent, refs = 1 } } }, function()
  local data = ran(true).own_tree
  check("own tree: status ok, both handles counted", data.status == "ok" and data.total == 2)
  check(
    "own tree: one handle per folder -> only the folder itself holds it",
    #data.entries == 1 and data.entries[1].same_folder == true
  )
  check("own tree: with its references", data.entries[1].references == 2)
  local text = ran(false)
  check(
    "text: the own tree's section names the folder",
    text:find("WATCHES THIS FOLDER: " .. slashed, 1, true) ~= nil
  )
  check(
    "text: no neo-tree section on the own tree without neo-tree",
    text:find("neo-tree fs_event", 1, true) == nil
  )
end)

with_state({ recursive = true, watchers = { { dir = parent, refs = 1 } } }, function()
  local data = ran(true).own_tree
  check(
    "own tree: a recursive handle above holds the folder",
    #data.entries == 1 and data.entries[1].same_folder == false
  )
  check(
    "text: ... and is named as a folder above",
    ran(false):find("WATCHES A FOLDER ABOVE: " .. parent, 1, true) ~= nil
  )
end)

with_state({
  recursive = true,
  watchers = { { dir = slashed .. "x", refs = 1 }, { dir = slashed .. "/sub", refs = 1 } },
}, function()
  check(
    "own tree: a sibling with the same prefix and a folder below hold nothing",
    #ran(true).own_tree.entries == 0
  )
end)

with_state({ watchers = { { dir = slashed:upper(), refs = 1 } } }, function()
  check(
    "own tree: the comparison ignores case, as the neo-tree one does",
    #ran(true).own_tree.entries == 1
  )
end)

with_state({ released = { { dir = slashed, refs = 1 } } }, function()
  local data = ran(true).own_tree
  check(
    "own tree: a handle released for a running operation is listed apart",
    #data.entries == 0 and #data.released == 1
  )
  check("text: ... and named", ran(false):find("released for a running operation", 1, true) ~= nil)
end)

with_state({ watch = false }, function()
  check("own tree: native.watch = false -> off", ran(true).own_tree.status == "off")
  check("text: ... says so", ran(false):find("native.watch = false", 1, true) ~= nil)
end)

with_state({ active = false, watchers = { { dir = slashed, refs = 1 } } }, function()
  check(
    "own tree: a handle left from before the backend changed is still reported",
    #ran(true).own_tree.entries == 1
  )
end)

package.loaded["neo-tree"] = {}
with_state({ watchers = { { dir = slashed, refs = 1 } } }, function()
  check(
    "text: with neo-tree loaded both sections are there",
    ran(false):find("neo-tree fs_event watchers:", 1, true) ~= nil
  )
end)
package.loaded["neo-tree"] = nil

vim.fn.delete(tmp, "rf")
real_print(("\n%d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cq!")
