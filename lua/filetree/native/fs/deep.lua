---@module 'filetree.native.fs.deep'
---@brief Every file below a folder, as a stream: for a search that reaches folders the tree never opened.
---@description
--- The tree reads a folder when it is opened; a search has to look into all of them. This module lists
--- the files below a root in batches, with the fastest tool the machine has, and can be stopped.
---
--- Key responsibilities:
--- - `files(root, on_batch, on_done, opts)`: paths (normalized) in batches on the main loop; returns `cancel`
--- - Three tiers behind one call: `fd`, `rg --files`, else a walk with `uv.fs_scandir`
--- - `tier()`: which one this machine uses, for `:checkhealth`
---
--- `.git` is never entered. `fd` and `rg` leave out what `.gitignore` names; the walk leaves out the
--- names of the ignore list, which is the nearest thing it has. A cancelled listing calls nothing more.

local list = require("filetree.native.fs.list")

local uv = vim.uv

local M = {}

--- How many paths the walk hands over at most (the tools have no such limit: they stream).
M.WALK_LIMIT = 200000

---@alias Filetree.Fs.Deep.Tier "fd"|"rg"|"lua"

---Which tool lists files on this machine.
---@return Filetree.Fs.Deep.Tier tier
---@return string|nil exe
function M.tier()
  for _, exe in ipairs({ "fd", "fdfind" }) do
    if vim.fn.executable(exe) == 1 then return "fd", exe end
  end
  if vim.fn.executable("rg") == 1 then return "rg", "rg" end
  return "lua", nil
end

---@param tier Filetree.Fs.Deep.Tier
---@param exe string
---@param root string
---@return string[]
local function command(tier, exe, root)
  if tier == "fd" then
    return {
      exe,
      "--type",
      "f",
      "--hidden",
      "--exclude",
      ".git",
      "--color",
      "never",
      "--absolute-path",
      ".",
      root,
    }
  end
  return { exe, "--files", "--hidden", "--glob", "!.git", "--color", "never", root }
end

---List through an external tool.
---@param cmd string[]
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@return fun() cancel
local function spawn(cmd, on_batch, on_done)
  local cancelled = false
  local tail = ""
  local ok, job = pcall(vim.system, cmd, {
    text = true,
    stdout = function(_, data)
      if cancelled or not data then return end
      local text = tail .. data
      local batch = {}
      local last = 1
      for line, stop in text:gmatch("([^\r\n]*)\r?\n()") do
        if line ~= "" then batch[#batch + 1] = list.norm(line) end
        last = stop
      end
      tail = text:sub(last)
      if #batch > 0 then
        vim.schedule(function()
          if not cancelled then on_batch(batch) end
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if cancelled then return end
      if tail ~= "" then on_batch({ list.norm(tail) }) end
      on_done(result.code == 0)
    end)
  end)
  if not ok then
    vim.schedule(function()
      if not cancelled then on_done(false) end
    end)
    return function()
      cancelled = true
    end
  end
  return function()
    if cancelled then return end
    cancelled = true
    pcall(job.kill, job, 15)
  end
end

---List by walking the folders. One folder is read at a time, each without blocking.
---@param root string
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@return fun() cancel
local function walk(root, on_batch, on_done)
  local cancelled = false
  local ignored = require("filetree.util.ignore").predicate()
  local queue = { root }
  local head = 1
  local count = 0

  local function step()
    if cancelled then return end
    local dir = queue[head]
    if not dir or count >= M.WALK_LIMIT then
      on_done(dir == nil)
      return
    end
    head = head + 1
    uv.fs_scandir(dir, function(_, handle)
      local batch = {}
      if handle then
        while true do
          local name, kind = uv.fs_scandir_next(handle)
          if not name then break end
          if name ~= ".git" and not ignored(name) then
            local path = list.join(dir, name)
            if kind == "directory" then
              queue[#queue + 1] = path
            else
              -- a link to a folder is not followed (it may point back up), a link to a file is a file
              local to_dir = kind == "link" and (uv.fs_stat(path) or {}).type == "directory"
              if not to_dir then batch[#batch + 1] = path end
            end
          end
        end
      end
      vim.schedule(function()
        if cancelled then return end
        count = count + #batch
        if #batch > 0 then on_batch(batch) end
        step()
      end)
    end)
  end
  step()
  return function()
    cancelled = true
  end
end

---List every file below `root`.
---@param root string  Normalized.
---@param on_batch fun(paths: string[])  Normalized absolute paths, in the order they are found.
---@param on_done fun(ok: boolean)  Called once, after the last batch; false when the tool failed or the walk hit its limit.
---@param opts? { tier?: Filetree.Fs.Deep.Tier }  Force a tier (specs); default: `tier()`.
---@return fun() cancel  After it nothing more is called.
function M.files(root, on_batch, on_done, opts)
  local tier, exe = M.tier()
  if opts and opts.tier then
    tier = opts.tier
    if tier ~= "lua" then
      local found, found_exe = M.tier()
      -- a forced tool that is not installed: the walk, which every machine has
      exe = found == tier and found_exe or (vim.fn.executable(tier) == 1 and tier or nil)
      if not exe then tier = "lua" end
    end
  end
  if tier == "lua" or not exe then return walk(root, on_batch, on_done) end
  return spawn(command(tier, exe, root), on_batch, on_done)
end

return M
