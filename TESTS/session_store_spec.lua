---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- session_store_spec.lua -- headless test for how the session store reaches the disk
-- (`filetree.features.org.session`): written through a temp file and a rename, so a failed
-- write keeps the previous store readable and leaves no temp file behind.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/session_store_spec.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root_dir = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root_dir)

local lib_candidates = {}
for _, env in ipairs({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" then lib_candidates[#lib_candidates + 1] = v end
end
lib_candidates[#lib_candidates + 1] = vim.fn.fnamemodify(root_dir, ":h") .. "/lib.nvim"
lib_candidates[#lib_candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"
for _, candidate in ipairs(lib_candidates) do
  if vim.fn.isdirectory(candidate .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(candidate)
    break
  end
end

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("PASS  " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local function read_store(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local dec_ok, data = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  return dec_ok and data or nil
end

local data_dir = vim.fn.tempname()
vim.fn.mkdir(data_dir, "p")
local real_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
  if what == "data" then return data_dir end
  return real_stdpath(what)
end

local session = require("filetree.features.org.session")
local expanded = { "a" }
local adapter = {
  name = "stub",
  get_winid = function()
    return -1
  end,
  get_expanded_paths = function()
    return expanded
  end,
}
session.setup(
  { enabled = true, auto_save = false, auto_restore = false, max_sessions = 10 },
  adapter
)

local store = data_dir .. "/filetree/sessions.json"
local function leftovers()
  local names = {}
  for name in vim.fs.dir(data_dir .. "/filetree") do
    if name ~= "sessions.json" then names[#names + 1] = name end
  end
  return names
end

-- A normal save lands as a readable store, no temp file next to it --------------------------
session.save()
local first = read_store(store)
check("save: the store is written and decodes", type(first) == "table" and next(first) ~= nil)
check("save: no temp file is left next to it", #leftovers() == 0, vim.inspect(leftovers()))
local first_text = table.concat(vim.fn.readfile(store), "\n")

-- A write that fails keeps the previous store ------------------------------------------------
expanded = { "a", "b" } -- a plain overwrite would now change the file
local uv = vim.uv or vim.loop
local real_fs_write = uv.fs_write
uv.fs_write = function()
  return nil, "ENOSPC: no space left on device"
end
local ok_save, err_save = pcall(session.save)
uv.fs_write = real_fs_write
check("failed write: save() does not raise", ok_save, err_save)
check(
  "failed write: the previous store is untouched",
  table.concat(vim.fn.readfile(store), "\n") == first_text,
  table.concat(vim.fn.readfile(store), "\n")
)
check("failed write: the previous store still decodes", type(read_store(store)) == "table")
check("failed write: the temp file is removed again", #leftovers() == 0, vim.inspect(leftovers()))

-- The next save works again ------------------------------------------------------------------
session.save()
local after = read_store(store)
local key, entry = next(after)
check(
  "save after a failure: the new content lands",
  key ~= nil and #entry.expanded == 2,
  vim.inspect(entry)
)

-- A restore somebody else took over is called off --------------------------------------------
do
  expanded = { "a" }
  session.save()
  local restores = 0
  adapter.expand_paths = function()
    restores = restores + 1
    return true
  end
  local function settle()
    vim.wait(250, function()
      return false
    end)
  end
  session.restore()
  settle()
  check("restore: the open folders reach the adapter", restores == 1, tostring(restores))
  session.restore()
  session.skip_restore()
  settle()
  check(
    "skip_restore: a restore that was still waiting does not run",
    restores == 1,
    tostring(restores)
  )
  session.restore()
  settle()
  check("skip_restore: a restore asked for afterwards runs", restores == 2, tostring(restores))
  session.restore()
  session.restore()
  settle()
  check("two restores in a row: only the last one runs", restores == 3, tostring(restores))

  -- the restore on the first attach of the tree
  local attach = require("filetree.util.tree_attach")
  local real_on_attach = attach.on_attach
  local on_attach
  attach.on_attach = function(fn)
    on_attach = fn
  end
  session.setup(
    { enabled = true, auto_save = false, auto_restore = true, max_sessions = 10 },
    adapter
  )
  session.skip_restore()
  on_attach()
  settle()
  check(
    "skip_restore before the tree attaches: no restore on attach",
    restores == 3,
    tostring(restores)
  )
  session.setup(
    { enabled = true, auto_save = false, auto_restore = true, max_sessions = 10 },
    adapter
  )
  on_attach()
  on_attach()
  settle()
  check("without it the first attach restores, once", restores == 4, tostring(restores))
  attach.on_attach = real_on_attach
  adapter.expand_paths = nil
end

vim.fn.stdpath = real_stdpath
vim.fn.delete(data_dir, "rf")

if failures > 0 then
  print(failures .. " check(s) failed")
  vim.cmd("cquit 1")
end
print("all session store checks passed")
vim.cmd("qa!")
