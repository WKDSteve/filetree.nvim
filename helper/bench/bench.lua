-- helper/bench/bench.lua -- E3h: the deep listing, recursive sizes and the git status of the own tree,
-- tier by tier and through the prototype helper, timed from the call until the last answer is on the
-- editor's main loop (what a search in the tree waits for).
--
--   nvim --clean --headless -u NONE -l helper/bench/bench.lua <helper-exe> <runs> <root> [<root> ...]
--
-- Prints one line per (root, work, tier): median, min and max over the runs, files found. Read-only:
-- lists folders, stats files, runs `git status`; writes nothing.

local this = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(this, ":p:h:h:h")
vim.opt.rtp:prepend(repo)
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  for _, candidate in ipairs({
    vim.env[dep:upper():gsub("%.", "_") .. "_DIR"] or "",
    vim.fn.fnamemodify(repo, ":h") .. "/" .. dep,
  }) do
    if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua") == 1 then
      vim.opt.rtp:prepend(candidate)
      break
    end
  end
end

local function say(text)
  io.stdout:write(text, "\n")
end

local exe, runs = _G.arg[1], tonumber(_G.arg[2])
local roots = {}
for i = 3, #_G.arg do
  roots[#roots + 1] = _G.arg[i]
end
assert(exe and runs and #roots > 0, "usage: bench.lua <helper-exe> <runs> <root>...")

require("filetree.config").setup({})
local list = require("filetree.native.fs.list")
local deep = require("filetree.native.fs.deep")
local uv = vim.uv
local TIMEOUT = 600000

-- ── the helper: the plugin's own module, with this program ─────────────────────
local helper = require("filetree.native.fs.helper")
helper.configure(exe)
do
  local t_spawn = uv.hrtime()
  local answered = false
  assert(
    helper.request("size", list.norm(vim.fn.getcwd()), function()
      answered = true
    end),
    "cannot start " .. exe
  )
  vim.wait(TIMEOUT, function()
    return answered
  end, 1)
  say(("helper %s, start and first answer %.1f ms"):format(exe, (uv.hrtime() - t_spawn) / 1e6))
end

---@param work fun(done: fun(files: integer)): any
---@return number ms, integer files, number first_ms
local function timed(work)
  local t0 = uv.hrtime()
  local finished, files, first = false, 0, nil
  work(function(n)
    files, finished = n, true
  end, function()
    first = first or uv.hrtime()
  end)
  assert(
    vim.wait(TIMEOUT, function()
      return finished
    end, 1),
    "timed out"
  )
  local t1 = uv.hrtime()
  return (t1 - t0) / 1e6, files, ((first or t1) - t0) / 1e6
end

-- ── the works ──────────────────────────────────────────────────────────────────
local function deep_tier(tier)
  return function(done, first)
    local n = 0
    deep.files(list.norm(_G.ROOT), function(batch)
      first()
      n = n + #batch
    end, function()
      done(n)
    end, { tier = tier })
  end
end

-- the size of a folder, everything counted, through the helper
local function helper_size(done, first)
  helper.request("size", list.norm(_G.ROOT), function(_, payload)
    first()
    done(payload.files or -1)
  end)
end

-- recursive size in Lua: the walk of tier 1 and one stat per file, as a size column would need it
local function lua_sizes(done, first)
  local n, bytes = 0, 0
  deep.files(list.norm(_G.ROOT), function(batch)
    first()
    for _, path in ipairs(batch) do
      local stat = uv.fs_stat(path)
      if stat then bytes = bytes + stat.size end
    end
    n = n + #batch
  end, function()
    done(n)
  end, { tier = "lua" })
end

local function git_status(done, first)
  require("lib.nvim.git").status_porcelain_async({ dir = _G.ROOT }, function(map)
    first()
    done(vim.tbl_count(map or {}))
  end)
end

local function helper_status(done, first)
  ---@diagnostic disable-next-line: param-type-mismatch
  helper.request("status", list.norm(_G.ROOT), function(kind, payload)
    first()
    done(kind == "status" and payload.entries or -1)
  end)
end

local rows = {
  { "deep", "fd", deep_tier("fd") },
  { "deep", "rg", deep_tier("rg") },
  { "deep", "lua", deep_tier("lua") },
  { "deep", "helper", deep_tier("helper") },
  { "sizes", "lua", lua_sizes },
  { "sizes", "helper", helper_size },
  { "status", "git", git_status },
  { "status", "helper", helper_status },
}

local function stats(values)
  table.sort(values)
  return values[math.ceil(#values / 2)], values[1], values[#values]
end

for _, root in ipairs(roots) do
  _G.ROOT = root
  say(("\n%s"):format(root))
  for _, row in ipairs(rows) do
    local work, tier = row[1], row[2]
    local times, firsts, files = {}, {}, 0
    timed(row[3]) -- warm-up, not counted (file system cache, first start of the tool)
    for _ = 1, runs do
      local ms, n, first = timed(row[3])
      times[#times + 1], firsts[#firsts + 1], files = ms, first, n
    end
    local med, lo, hi = stats(times)
    say(
      ("  %-6s %-6s median %8.1f ms  (min %8.1f, max %8.1f)  first batch %7.1f ms  n=%d"):format(
        work,
        tier,
        med,
        lo,
        hi,
        (stats(firsts)),
        files
      )
    )
  end
end

helper.stop()
vim.cmd("qa!")
