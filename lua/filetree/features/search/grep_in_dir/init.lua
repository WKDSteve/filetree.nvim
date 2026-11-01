---@module 'filetree.features.search.grep_in_dir'
--- Grep/ripgrep in the directory of the current tree node.
---
--- Detects available backends in order:
---   1. pickers.nvim   live grep (picks its own engine)
---   2. telescope.nvim  live_grep / grep_string
---   3. fzf-lua         live_grep / grep
---   4. vim.fn.system   ripgrep → grep fallback → quickfix list
---
--- The search root is the directory of the node under the cursor (or cwd).
--- After selection the file is opened and the match line is jumped to.
---
--- Keymaps (in tree buffer, default):
---   gr  grep with prompt
---   tg  grep via pickers.nvim specifically
--- (keymap_cword, "grep word under cursor", has no default keymap — set one
--- explicitly via config if wanted.)
---
--- User commands:
---   :FiletreeGrepInDir [pattern]

local notify = require("filetree.util.notify").create("[filetree.grep_in_dir]")
local list = require("lib.nvim.ui.list")

local M = {}

-- Builtin searches still running, keyed by their `vim.SystemObj`. Neovim does not
-- stop a `vim.system` child at exit on POSIX: VimLeavePre kills them. No
-- timeout on purpose: a search of a big tree is slow, not stuck, and the user
-- sees the progress indicator.
---@type table<vim.SystemObj, true>
local live = {}
local leave_hook = false

---@internal
---Kill every builtin search that has not exited yet.
---@return integer killed
function M.kill_live()
  local n = 0
  for obj in pairs(live) do
    live[obj] = nil
    if pcall(obj.kill, obj, "sigkill") then n = n + 1 end
  end
  return n
end

---@internal
---How many builtin searches are running (for the specs).
---@return integer
function M.live_count()
  local n = 0
  for _ in pairs(live) do
    n = n + 1
  end
  return n
end

-- Optional: shows a "searching…" indicator around the builtin backend's
-- blocking rg/grep process, which can take a while under a large directory.
-- No-op (returns nil) when lib.nvim isn't installed.
local progress = require("filetree.util.progress")
local bind = require("filetree.util.bind")
---@internal
---@return table?
local function new_progress()
  return progress.create({ title = "[filetree.grep_in_dir]" })
end

---@type FiletreeGrepInDirConfig
local DEFAULTS = {
  enabled = false,
  keymap = "gr",
  keymap_cword = nil,
  keymap_pickers = "tg",
  keymap_telescope = nil,
  prefer = "auto", -- "auto"|"pickers"|"telescope"|"fzf-lua"|"builtin"
  hidden = false,
  extra_args = {},
}

---@type FiletreeGrepInDirConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.grep_in_dir` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  keymap_cword = "keymap",
  keymap_pickers = "keymap",
  keymap_telescope = "keymap",
  prefer = { "string", enum = { "auto", "pickers", "telescope", "fzf-lua", "builtin" } },
  hidden = "boolean",
  extra_args = { "table", of = "string" },
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Root ──────────────────────────────────────────────────────────────────────

---@internal
---Directory to grep in: the node under the cursor's directory, or the
---held/project/cwd root via `filetree.util.root`.
---@return string
local function get_dir()
  -- No node under the cursor (or no tree at all): fall back to the root
  -- cwd_mode holds, if any, before the plain cwd — a locked session must
  -- grep in the locked project, not in whichever one the focused buffer
  -- happens to belong to.
  if not _adapter then return require("filetree.util.root").find() end
  local node = _adapter.get_current_node()
  if not node then return require("filetree.util.root").find() end
  return node.type == "directory" and node.path or vim.fn.fnamemodify(node.path, ":h")
end

-- ── Backends ──────────────────────────────────────────────────────────────────

---@internal
---Grep via pickers.nvim. Returns false when it is not installed.
---@param dir string
---@param pattern string?
---@return boolean handled
local function via_pickers(dir, pattern)
  return require("filetree.util.pickers").grep(dir, pattern, _cfg.extra_args)
end

---@internal
---Grep via telescope.nvim. Returns false when telescope isn't installed.
---@param dir string
---@param pattern string?
---@return boolean handled
local function via_telescope(dir, pattern)
  local ok, tel = pcall(require, "telescope.builtin")
  if not ok then return false end
  local opts = {
    cwd = dir,
    search = pattern or nil,
    hidden = _cfg.hidden,
    additional_args = _cfg.extra_args,
  }
  if pattern and pattern ~= "" then
    tel.grep_string(vim.tbl_extend("force", opts, { word_match = false }))
  else
    tel.live_grep(opts)
  end
  return true
end

---@internal
---Grep via fzf-lua. Returns false when fzf-lua isn't installed.
---@param dir string
---@param pattern string?
---@return boolean handled
local function via_fzflua(dir, pattern)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then return false end
  local opts = {
    cwd = dir,
    hidden = _cfg.hidden,
  }
  if pattern and pattern ~= "" then
    opts.search = pattern
    fzf.grep(opts)
  else
    fzf.live_grep(opts)
  end
  return true
end

---@internal
---Quickfix population for run_builtin_search, split out so the search itself
---can hand its result over from a vim.system callback.
---@param dir string
---@param pattern string
---@param output string[]
---@param exit_code integer
---@param prog table|nil
---@return nil
local function builtin_search_done(dir, pattern, output, exit_code, prog)
  if prog then prog:finish(string.format("%d line(s) matched", #output)) end

  if exit_code ~= 0 and #output == 0 then
    notify.info("No matches for: " .. pattern)
    return
  end

  -- Populate quickfix
  local qf_items = {}
  for _, line in ipairs(output) do
    -- rg/grep --vimgrep format: file:line:col:text
    local file, lnum, col, text = line:match("^(.+):(%d+):(%d+):(.*)")
    if file then
      qf_items[#qf_items + 1] = {
        filename = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = text,
      }
    end
  end

  if #qf_items == 0 then
    notify.info("No matches for: " .. pattern)
    return
  end

  list.qf(qf_items, "grep: " .. pattern .. " [" .. dir .. "]", { action = "r" })
  notify.info(string.format("Found %d match(es) in %s", #qf_items, vim.fn.fnamemodify(dir, ":t")))
  return
end

---@internal
---Run the dependency-free rg/grep fallback and populate the quickfix list.
---@param dir string
---@param pattern string
---@return boolean
local function run_builtin_search(dir, pattern)
  -- Prefer rg, then grep
  local has_rg = vim.fn.executable("rg") == 1

  local prog = new_progress()
  if prog then prog:update({ text = "searching " .. dir .. "…" }) end

  -- vim.system with an argv list (not a shell string) on purpose: it execs the
  -- search tool directly with no shell in between, so there is nothing to
  -- quote/escape and no dependency on &shell being cmd.exe-compatible (e.g.
  -- Git Bash as &shell on Windows mishandles a hand-built quoted command
  -- string passed through vim.fn.system/systemlist). The grep branch used to
  -- build exactly such a string; it is an argv list now too.
  local args
  if has_rg then
    -- The real binary, not a Scoop shim: a shim between the editor and rg
    -- lets rg outlive the editor (see `filetree.util.platform.rg_binary`).
    args = { require("filetree.util.platform").rg_binary(), "--vimgrep", "--color=never" }
    if _cfg.hidden then args[#args + 1] = "--hidden" end
    for _, a in ipairs(_cfg.extra_args) do
      args[#args + 1] = a
    end
    args[#args + 1] = "--"
    args[#args + 1] = pattern
    args[#args + 1] = dir
  else
    args = { "grep", "-rn", "--", pattern, dir }
  end

  -- The search used to run through `vim.system():wait()` (rg) or
  -- `vim.fn.systemlist()` (grep) -- both froze the editor for the whole scan.
  -- On a large tree that is seconds, and the progress indicator started just
  -- above could never even paint. It is a callback now. The `true` returned
  -- below is a formality: this is always the last fallback in M.grep's chain
  -- and no caller consults it (see via_builtin's doc comment).
  local obj
  if not leave_hook then
    leave_hook = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("filetree.grep_in_dir", { clear = true }),
      desc = "filetree grep_in_dir: stop searches still running",
      callback = function()
        M.kill_live()
      end,
    })
  end
  obj = vim.system(args, { text = true }, function(result)
    if obj then live[obj] = nil end
    local output = vim.split(result.stdout or "", "\n", { trimempty = true })
    -- vim.system callbacks run off the main loop; quickfix, notify and :copen
    -- all need the main loop.
    vim.schedule(function()
      builtin_search_done(dir, pattern, output, result.code, prog)
    end)
  end)
  live[obj] = true

  return true
end

---@internal
---Grep via the builtin rg/grep backend. Prompts for a pattern first when none
---is given (async via kit.input); the caller's return value is never
---consulted (this is always the last fallback in M.grep's chain), so it's
---fine for the prompt path to return before the actual search runs.
---@return boolean
local function via_builtin(dir, pattern)
  if not pattern or pattern == "" then
    require("ui.kit").input({
      title = "Grep pattern: ",
      on_submit = function(input)
        if input == "" then return end
        run_builtin_search(dir, input)
      end,
    })
    return true
  end

  return run_builtin_search(dir, pattern)
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Run grep in `dir` for `pattern`.
---@param dir?     string
---@param pattern? string  If nil, a prompt is shown (telescope/fzf do their own input).
function M.grep(dir, pattern)
  dir = dir or get_dir()
  local prefer = _cfg.prefer or "auto"

  if prefer == "pickers" then
    via_pickers(dir, pattern)
    return
  end
  if prefer == "telescope" then
    via_telescope(dir, pattern)
    return
  end
  if prefer == "fzf-lua" then
    via_fzflua(dir, pattern)
    return
  end
  if prefer == "builtin" then
    via_builtin(dir, pattern)
    return
  end

  if
    not via_pickers(dir, pattern)
    and not via_telescope(dir, pattern)
    and not via_fzflua(dir, pattern)
  then
    via_builtin(dir, pattern)
  end
end

---Grep the word under the cursor in the current node's directory.
function M.grep_cword()
  M.grep(get_dir(), vim.fn.expand("<cword>"))
end

---Force pickers.nvim specifically, regardless of the configured `prefer` backend.
---@param dir?     string
---@param pattern? string
function M.grep_pickers(dir, pattern)
  dir = dir or get_dir()
  if not via_pickers(dir, pattern) then notify.warn("pickers.nvim not available") end
end

---Force telescope specifically, regardless of the configured `prefer` backend.
---@param dir?     string
---@param pattern? string
function M.grep_telescope(dir, pattern)
  dir = dir or get_dir()
  if not via_telescope(dir, pattern) then notify.warn("telescope.nvim not available") end
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeGrepInDirConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("grep_in_dir", _cfg, {
    { name = "grep", field = "keymap", rhs = M.grep, desc = "grep in node directory" },
    {
      name = "grep_cword",
      field = "keymap_cword",
      rhs = M.grep_cword,
      desc = "grep cword in node directory",
    },
    {
      name = "grep_pickers",
      field = "keymap_pickers",
      rhs = M.grep_pickers,
      desc = "grep via pickers.nvim specifically",
    },
    {
      name = "grep_telescope",
      field = "keymap_telescope",
      rhs = M.grep_telescope,
      desc = "grep via telescope specifically",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
