---@module 'filetree.native.fs.deep'
---@brief Every file below a folder, as a stream: for a search that reaches folders the tree never opened.
---@description
--- The tree reads a folder when it is opened; a search has to look into all of them. This module lists
--- the files below a root in batches, with the fastest tool the machine has, and can be stopped.
---
--- Key responsibilities:
--- - `files(root, on_batch, on_done, opts)`: paths (normalized) in batches on the main loop; returns `cancel`
--- - Four tiers behind one call: the helper process (`filetree.native.fs.helper`), `fd`, `rg --files`,
---   else a walk with `uv.fs_scandir`
--- - `tier()`: which one this machine uses, for `:checkhealth`
---
--- `.git` is never entered. The helper, `fd` and `rg` leave out what `.gitignore` names; the walk leaves
--- out the names of the ignore list, which is the nearest thing it has. A cancelled listing calls
--- nothing more. A helper that ends during a listing hands it to the next tier, which leaves out what
--- the helper had handed over already.
---
--- Links: a link to a file (and a link whose target is gone) is listed like a file, a link to a folder
--- is neither listed nor followed. `fd` and the walk agree on that; `fd --type f` alone leaves links
--- out, so its links come from a second run. `rg --files` cannot list a link without following it:
--- on a machine that has `rg` and no `fd`, links are not found.

local list = require("filetree.native.fs.list")

local uv = vim.uv

local M = {}

--- How many paths the walk hands over at most (the tools have no such limit: they stream).
M.WALK_LIMIT = 200000

---@alias Filetree.Fs.Deep.Tier "helper"|"fd"|"rg"|"lua"

---Which external tool (or the walk) lists files, the helper left aside.
---@return Filetree.Fs.Deep.Tier tier
---@return string|nil exe
local function tool_tier()
  for _, exe in ipairs({ "fd", "fdfind" }) do
    if vim.fn.executable(exe) == 1 then return "fd", exe end
  end
  if vim.fn.executable("rg") == 1 then return "rg", "rg" end
  return "lua", nil
end

---Which tier lists files on this machine.
---@return Filetree.Fs.Deep.Tier tier
---@return string|nil exe
function M.tier()
  local helper = require("filetree.native.fs.helper")
  if helper.available() then return "helper", (helper.find()) end
  return tool_tier()
end

---@param tier Filetree.Fs.Deep.Tier
---@param exe string
---@param root string
---@param kind? "f"|"l"  For `fd`: files (default) or links.
---@return string[]
local function command(tier, exe, root, kind)
  if tier == "fd" then
    return {
      exe,
      "--type",
      kind or "f",
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

---List through the helper process. Nil when it cannot take the request.
---@param root string
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@param rest fun(on_batch: fun(paths: string[]), on_done: fun(ok: boolean)): fun()  The next tier, for a helper that ends on the way.
---@return (fun())|nil cancel
local function via_helper(root, on_batch, on_done, rest)
  local helper = require("filetree.native.fs.helper")
  local cancelled = false
  ---@type table<string, true>  what was handed over: the next tier must not hand it over again
  local given = {}
  ---@type (fun())|nil
  local cancel_rest = nil
  local gen = helper.request("walk", root, function(kind, payload)
    if cancelled then return false end
    if kind == "files" then
      for _, path in ipairs(payload) do
        given[path] = true
      end
      vim.schedule(function()
        if not cancelled then on_batch(payload) end
      end)
      return true
    elseif kind == "done" then
      vim.schedule(function()
        if not cancelled then on_done(type(payload) ~= "table" or payload.ok ~= false) end
      end)
    elseif kind == "lost" then
      -- after the batches already on their way: the rest from the next tier
      vim.schedule(function()
        if cancelled then return end
        cancel_rest = rest(function(paths)
          local fresh = {}
          for _, path in ipairs(paths) do
            if not given[path] then fresh[#fresh + 1] = path end
          end
          if #fresh > 0 then on_batch(fresh) end
        end, on_done)
      end)
    end
    return false
  end)
  if not gen then return nil end
  return function()
    if cancelled then return end
    cancelled = true
    helper.drop(gen, "cancel")
    if cancel_rest then cancel_rest() end
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
    if tier ~= "lua" and tier ~= "helper" then
      local found, found_exe = tool_tier()
      -- a forced tool that is not installed: the walk, which every machine has
      exe = found == tier and found_exe or (vim.fn.executable(tier) == 1 and tier or nil)
      if not exe then tier = "lua" end
    end
  end
  if tier == "helper" then
    local cancel = via_helper(root, on_batch, on_done, function(batch, done)
      return M.files(root, batch, done, { tier = (tool_tier()) })
    end)
    if cancel then return cancel end
    -- no helper after all (forced in a spec, or it could not start): the tools
    tier, exe = tool_tier()
  end
  if tier == "lua" or not exe then return walk(root, on_batch, on_done) end
  if tier ~= "fd" then return spawn(command(tier, exe, root), on_batch, on_done) end

  -- `fd --type f` leaves every link out; a second run lists the links, and what points at a folder
  -- is dropped here, as the walk drops it. One run after the other, never both at once: with two
  -- children started side by side, killing the first left its `fd` behind for good on Windows (a
  -- scoop shim in between; seen as one stuck `fd.exe` per cancelled search).
  local cancelled = false
  local cancel_run
  cancel_run = spawn(command(tier, exe, root), on_batch, function(files_ok)
    if cancelled then return end
    cancel_run = spawn(command(tier, exe, root, "l"), function(paths)
      local batch = {}
      for _, path in ipairs(paths) do
        if (uv.fs_stat(path) or {}).type ~= "directory" then batch[#batch + 1] = path end
      end
      if #batch > 0 then on_batch(batch) end
    end, function(links_ok)
      on_done(files_ok and links_ok)
    end)
  end)
  return function()
    cancelled = true
    cancel_run()
  end
end

return M
