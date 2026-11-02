---@module 'filetree.features.system.compress'
---@brief Compress the node under the cursor, or the marked nodes, to `.zip`.
---@description
--- Targets, same gather order as trash/copy_move: the marked nodes if any are
--- marked (see features.org.marks), else the node under the cursor. A folder is
--- archived with its contents. Marks are left alone, the sources are never
--- touched -- this only writes new files.
---
---   * one node        -> `<name>.zip` beside it
---   * several nodes   -> `multiple` decides: `"each"` one zip per node, `"together"`
---                        one zip for all of them (name asked, default the first
---                        node's folder name), `"ask"` (default) offers both
---
--- An existing zip is never overwritten: the new one becomes `<name>_2.zip`, ....
--- The archive is written by Info-ZIP `zip` or a bsdtar (Windows ships one), see
--- `archiver.lua`; with neither on the machine the key only warns.
---
--- Keymap (in tree buffer, default):
---   gz   Compress the current node / marked nodes to .zip
---
--- Commands: `:Filetree compress` (as `gz`), `:Filetree compress each`,
--- `:Filetree compress together` (skip the question for several nodes).

local archiver = require("filetree.features.system.compress.archiver")
local path = require("filetree.util.path")
local confirm_choice = require("filetree.util.confirm_choice")
local notify = require("filetree.util.notify").create("[filetree.compress]")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreeCompressConfig
local DEFAULTS = {
  enabled = true,
  keymap = "gz",
  multiple = "ask",
}

---@type FiletreeCompressConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.compress` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  multiple = { "string", enum = { "ask", "each", "together" } },
}

---@type FiletreeAdapter?
local _adapter = nil

local CHOICE_EACH = "One zip each"
local CHOICE_TOGETHER = "One zip for all"

---Absolute, `/`-separated, without a trailing slash.
---@param p string
---@return string
local function clean(p)
  local s = path.slashify(p)
  if #s > 1 and s:sub(-1) == "/" and not s:match("^%a:/$") then s = s:sub(1, -2) end
  return s
end

---The marked nodes if any are marked, else the node under the cursor. Paths that
---no longer exist (a stale mark) are dropped.
---@return string[]
function M.gather()
  local raw = {}
  local ok_m, marks = require("filetree.features").load("marks")
  if ok_m and marks and marks.count() > 0 then
    raw = marks.get_marked()
  elseif _adapter then
    local node = _adapter.get_current_node()
    if node and node.path then raw = { node.path } end
  end
  local out = {}
  for _, p in ipairs(raw) do
    local c = clean(p)
    if vim.uv.fs_stat(c) then out[#out + 1] = c end
  end
  return out
end

---Run one archive job. `done(err)` gets nil on success, else the reason.
---@param tool FiletreeCompressTool
---@param out string
---@param sources string[]
---@param done fun(err: string?)
local function write_zip(tool, out, sources, done)
  local cmd, cwd = archiver.build(tool, out, sources)
  if not cmd then return done(cwd) end
  local ok, err = pcall(
    require("filetree.util.live_procs").spawn,
    cmd,
    { cwd = cwd, text = true },
    function(res)
      vim.schedule(function()
        if res.code == 0 and vim.uv.fs_stat(out) then return done(nil) end
        os.remove(out) -- a half-written archive is worse than none
        local first = vim.split(vim.trim(res.stderr or ""), "\n")[1]
        done(first ~= "" and first or ("exit code " .. tostring(res.code)))
      end)
    end
  )
  if not ok then done(tostring(err)) end
end

---Write the zips `jobs` lists one after another, then report once and refresh.
---@param tool FiletreeCompressTool
---@param jobs {out: string, sources: string[]}[]
local function run(tool, jobs)
  local made, failed = {}, {}
  local i = 0
  local function step()
    i = i + 1
    local job = jobs[i]
    if not job then
      if #made > 0 then
        notify.info(string.format("Created %d zip(s): %s", #made, table.concat(made, ", ")))
        if _adapter and _adapter.refresh then pcall(_adapter.refresh) end
      end
      if #failed > 0 then notify.error("Could not compress: " .. table.concat(failed, "; ")) end
      return
    end
    write_zip(tool, job.out, job.sources, function(err)
      if err then
        failed[#failed + 1] = path.basename(job.out) .. " (" .. err .. ")"
      else
        made[#made + 1] = path.basename(job.out)
      end
      step()
    end)
  end
  step()
end

---One job per source: `<source>.zip` beside it.
---@param sources string[]
---@return {out: string, sources: string[]}[]
function M.jobs_each(sources)
  local jobs, taken = {}, {}
  for _, src in ipairs(sources) do
    local out = archiver.free_path(src .. ".zip")
    -- two sources whose zips would collide in one run (a.zip marked beside a)
    while taken[out] do
      out = archiver.free_path(out:gsub("%.zip$", "") .. "_2.zip")
    end
    taken[out] = true
    jobs[#jobs + 1] = { out = out, sources = { src } }
  end
  return jobs
end

---The zip path an answer to the name prompt means: relative to the first source's
---folder unless absolute, `.zip` appended when missing.
---@param answer string
---@param sources string[]
---@return string
function M.together_path(answer, sources)
  local name = vim.trim(answer)
  if not name:lower():match("%.zip$") then name = name .. ".zip" end
  name = path.slashify(name)
  if not (name:match("^%a:/") or name:sub(1, 1) == "/") then
    name = path.parent(sources[1]) .. "/" .. name
  end
  return clean(name)
end

---@param tool FiletreeCompressTool
---@param sources string[]
local function compress_together(tool, sources)
  local dir = path.parent(sources[1])
  local default = path.basename(#sources == 1 and sources[1] or dir) .. ".zip"
  require("lib.nvim.ui.dialog").input({
    prompt = string.format("Zip %d node(s) as: ", #sources),
    default = default,
  }, function(answer)
    if not answer or vim.trim(answer) == "" then return end
    local out = M.together_path(answer, sources)
    if archiver.inside_source(out, sources) then
      notify.warn("The zip cannot go inside a folder it compresses: " .. out)
      return
    end
    run(tool, { { out = archiver.free_path(out), sources = sources } })
  end)
end

---Compress the marked nodes (else the current one).
---@param mode? "ask"|"each"|"together"  For several nodes; default `multiple`.
function M.compress(mode)
  local sources = M.gather()
  if #sources == 0 then
    notify.warn("No node to compress")
    return
  end
  local tool = archiver.detect()
  if not tool then
    notify.warn("Neither zip nor a bsdtar found, cannot compress")
    return
  end

  if #sources == 1 and mode ~= "together" then return run(tool, M.jobs_each(sources)) end

  mode = mode or _cfg.multiple
  if mode == "each" then return run(tool, M.jobs_each(sources)) end
  if mode == "together" then return compress_together(tool, sources) end
  confirm_choice(
    string.format("Compress %d nodes", #sources),
    { CHOICE_EACH, CHOICE_TOGETHER, "Cancel" },
    function(choice)
      if choice == CHOICE_EACH then
        run(tool, M.jobs_each(sources))
      elseif choice == CHOICE_TOGETHER then
        compress_together(tool, sources)
      end
    end
  )
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeCompressConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("compress", _cfg, {
    {
      name = "compress",
      field = "keymap",
      rhs = function()
        M.compress()
      end,
      desc = "compress node / marked nodes to .zip",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
