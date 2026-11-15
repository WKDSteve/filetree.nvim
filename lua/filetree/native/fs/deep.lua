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
--- - `resolve(path)`: the program behind a scoop shim; `running()`: tools that have not ended
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
---
--- A tool is started by the program itself, not by a launcher in front of it (`resolve`): a scoop
--- shim costs 40 to 70 ms per start, and ending it leaves the program it started running, so a
--- cancelled listing (one per keystroke of a search) listed the whole root to the end. With the
--- program itself the two runs of `fd` go side by side; behind a launcher they still go one after
--- the other. `running()` counts the tools that have not ended.

local list = require("filetree.native.fs.list")

local uv = vim.uv

local M = {}

--- How many paths the walk hands over at most (the tools have no such limit: they stream).
M.WALK_LIMIT = 200000

---@alias Filetree.Fs.Deep.Tier "helper"|"fd"|"rg"|"lua"

---The program behind a launcher. Scoop puts `<name>.exe` next to `<name>.shim`, a text file that
---names the real program (`path = "..."`); started through the shim, the program is a grandchild.
---@param path string  The full path of the executable that was found.
---@return string exe  The program to start: the one the shim names, else `path`.
---@return boolean direct  false when a launcher stays in between (a shim with arguments of its own, or one whose target is gone).
function M.resolve(path)
  local shim = (path:gsub("%.[^.\\/]+$", "")) .. ".shim"
  local file = io.open(shim, "r")
  if not file then return path, true end
  local text = file:read("*a") or ""
  file:close()
  local target = text:match('path%s*=%s*"([^"\r\n]+)"') or text:match("path%s*=%s*([^\r\n]+)")
  -- a shim that brings arguments is not the program alone: it stays
  if target and not text:match("args%s*=") and uv.fs_stat(target) then return target, true end
  return path, false
end

---@type table<string, { exe: string, direct: boolean }>  by the name asked for; a tool does not move while Neovim runs
local resolved = {}

---What to start for a tool name, and whether that is the program itself.
---@param name string
---@return string exe
---@return boolean direct
local function program(name)
  local hit = resolved[name]
  if not hit then
    local path = vim.fn.exepath(name)
    if path == "" then
      hit = { exe = name, direct = true }
    else
      local exe, direct = M.resolve(path)
      hit = { exe = exe, direct = direct }
    end
    resolved[name] = hit
  end
  return hit.exe, hit.direct
end

--- Tools started by `files` that have not ended yet.
local live = 0

---How many tools started for a listing are still running (a cancelled one ends at once).
---@return integer
function M.running()
  return live
end

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
  cmd = vim.list_slice(cmd)
  cmd[1] = program(cmd[1])
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
    live = live - 1
    vim.schedule(function()
      if cancelled then return end
      if tail ~= "" then on_batch({ list.norm(tail) }) end
      on_done(result.code == 0)
    end)
  end)
  if ok then live = live + 1 end
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
  -- is dropped here, as the walk drops it.
  ---@param paths string[]
  local function links(paths)
    local batch = {}
    for _, path in ipairs(paths) do
      if (uv.fs_stat(path) or {}).type ~= "directory" then batch[#batch + 1] = path end
    end
    if #batch > 0 then on_batch(batch) end
  end
  local cancelled = false
  local _, direct = program(exe)
  if direct then
    -- the program itself: both runs side by side, the listing takes as long as the longer one
    local left, all_ok = 2, true
    ---@param ok boolean
    local function one_done(ok)
      all_ok = all_ok and ok
      left = left - 1
      if left == 0 and not cancelled then on_done(all_ok) end
    end
    local cancel_files = spawn(command(tier, exe, root), on_batch, one_done)
    local cancel_links = spawn(command(tier, exe, root, "l"), links, one_done)
    return function()
      cancelled = true
      cancel_files()
      cancel_links()
    end
  end
  -- A launcher in between: one run after the other, never both at once. With two children started
  -- side by side, ending the first left its `fd` behind for good on Windows (seen as one stuck
  -- `fd.exe` per cancelled search).
  local cancel_run
  cancel_run = spawn(command(tier, exe, root), on_batch, function(files_ok)
    if cancelled then return end
    cancel_run = spawn(command(tier, exe, root, "l"), links, function(links_ok)
      on_done(files_ok and links_ok)
    end)
  end)
  return function()
    cancelled = true
    cancel_run()
  end
end

return M
