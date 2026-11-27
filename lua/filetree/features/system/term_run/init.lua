---@module 'filetree.features.system.term_run'
---@brief Hand the node under the cursor to a terminal: run a script, or type its path.
---@description
--- Binds a key (default `<leader>.`) in the tree buffer. On activation:
---
---   * a **runnable file** (`.ps1`, `.sh`, `.bat`, `.py`, ... see `runners`) is run: its command
---     line goes to the terminal with Enter. In PowerShell a `.ps1` runs as itself (`& '...'` when
---     the path needs quotes), in another shell through `pwsh -File`;
---   * **anything else** (a folder, a text file) has its quoted path typed into the terminal
---     without Enter, so the line can be finished by hand.
---
--- Where it goes (`backend`):
---   "terminal"  terminal.nvim's run terminal (`require("terminal").run/send`); it quotes the
---               line for the shell that terminal runs.
---   "cmdline"   Neovim's command line: `:!<line>` is put there and NOT run, Enter confirms it.
---               Quoted for 'shell'.
---   "auto"      terminal.nvim when it is installed, else the command line (default).
---
--- `system.open_with` (`<leader>sm`) asks `runnable()` first: a script goes here instead of to
--- the OS default handler, which would open it in an editor or run it in a window that closes.
---
--- Config:
---   enabled   boolean
---   keymap    string?   Key in the tree buffer (default "<leader>.").
---   backend   "auto"|"terminal"|"cmdline"
---   runners   table<string, string[]|false>  Per extension (lower case, no dot): the words in
---             front of the path, `{}` to run the file as itself, `false` to never run it.
---   execute   boolean   false: type the command line of a script without Enter (default true).
---   focus     boolean   Move to the terminal (default true).

local notify = require("filetree.util.notify").create("[filetree.term_run]")
local platform = require("filetree.util.platform")
local path_util = require("filetree.util.path")
local bind = require("filetree.util.bind")

local M = {}

M.BACKENDS = { "auto", "terminal", "cmdline" }

---Option schema (see `filetree.config.schema`): exactly what `features.term_run` accepts. Keep it
---in step with the keys this module reads; `TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  backend = { "string", enum = M.BACKENDS },
  runners = "table",
  execute = "boolean",
  focus = "boolean",
}

---@type FiletreeTermRunConfig
local DEFAULTS = {
  enabled = true,
  keymap = "<leader>.",
  backend = "auto",
  runners = {},
  execute = true,
  focus = true,
}

---@type FiletreeTermRunConfig
local _cfg = vim.deepcopy(DEFAULTS)
---@type FiletreeAdapter?
local _adapter = nil

-- ── Runners ───────────────────────────────────────────────────────────────────

---@alias Filetree.TermRun.Kind "posix"|"fish"|"powershell"|"cmd"|"portable"

---@internal
---The PowerShell to start a `.ps1` from another shell: pwsh when it is there, else Windows
---PowerShell (looked up only when such a file is run).
---@return string
local function pwsh()
  if platform.has_executable("pwsh") then return "pwsh" end
  return platform.powershell_exe()
end

---Built-in runners: extension → function(kind) returning the words in front of the path.
---@type table<string, fun(kind: Filetree.TermRun.Kind): string[]>
M.DEFAULT_RUNNERS = {
  ps1 = function(kind)
    if kind == "powershell" then return {} end
    return { pwsh(), "-NoProfile", "-File" }
  end,
  bat = function(kind)
    if kind == "cmd" or kind == "powershell" then return {} end
    return { "cmd.exe", "/c" }
  end,
  sh = function()
    return { "bash" }
  end,
  bash = function()
    return { "bash" }
  end,
  zsh = function()
    return { "zsh" }
  end,
  fish = function()
    return { "fish" }
  end,
  py = function()
    return { platform.is_windows() and "python" or "python3" }
  end,
  js = function()
    return { "node" }
  end,
  mjs = function()
    return { "node" }
  end,
  cjs = function()
    return { "node" }
  end,
  rb = function()
    return { "ruby" }
  end,
  pl = function()
    return { "perl" }
  end,
}
M.DEFAULT_RUNNERS.cmd = M.DEFAULT_RUNNERS.bat

---@internal
---@param path string
---@return string ext lower case, "" without one
local function ext_of(path)
  local name = vim.fs.basename(path)
  return (name:match("^.+%.([^.]+)$") or ""):lower()
end

---@internal
---The runner of `path`: a user entry (words, or false) wins over the built-in one. A file without
---an extension that has the executable bit (not on Windows, where every file reads executable
---under some mounts) runs as itself.
---@param path string
---@return (fun(kind: Filetree.TermRun.Kind): string[])|nil
local function runner_for(path)
  if vim.fn.isdirectory(path) == 1 then return nil end
  local ext = ext_of(path)
  local user = (_cfg.runners or {})[ext]
  if user == false then return nil end
  if type(user) == "table" then
    return function()
      return vim.deepcopy(user)
    end
  end
  if ext ~= "" then return M.DEFAULT_RUNNERS[ext] end
  if not platform.is_windows() and vim.fn.executable(path) == 1 then
    return function()
      return {}
    end
  end
  return nil
end

---Whether `path` is a file this feature runs (rather than types the path of).
---@param path string
---@return boolean
function M.runnable(path)
  return type(path) == "string" and path ~= "" and runner_for(path) ~= nil
end

-- ── Backends ──────────────────────────────────────────────────────────────────

---@internal
---@return table|nil terminal.nvim's facade
local function terminal_mod()
  local ok, mod = pcall(require, "terminal")
  if ok and type(mod) == "table" and type(mod.run) == "function" then return mod end
  return nil
end

---The backend a call uses: `override`, else the configured one; "auto" resolved.
---@param override? string
---@return "terminal"|"cmdline"|nil backend
---@return string|nil err
function M.resolve_backend(override)
  local want = override or _cfg.backend or "auto"
  if not vim.list_contains(M.BACKENDS, want) then
    return nil, ("unknown backend %s (use auto, terminal or cmdline)"):format(tostring(want))
  end
  if want == "cmdline" then return "cmdline", nil end
  if terminal_mod() then return "terminal", nil end
  if want == "terminal" then return nil, "terminal.nvim is not installed" end
  return "cmdline", nil
end

---@internal
---The shell kind of the target: terminal.nvim's configured shell, else 'shell'.
---@param backend "terminal"|"cmdline"
---@return Filetree.TermRun.Kind
local function shell_kind(backend)
  local sq = require("lib.nvim.cross.shell_quote")
  local exe = vim.o.shell
  if backend == "terminal" then
    local ok, tcfg = pcall(require, "terminal.config")
    if ok and type(tcfg.shell_executable) == "function" then
      local got_ok, got = pcall(tcfg.shell_executable)
      if got_ok and type(got) == "string" and got ~= "" then exe = got end
    end
  end
  return sq.shell_kind(exe)
end

---@internal
---The path as the shell wants it: backslashes for cmd.exe and PowerShell on Windows, forward
---slashes elsewhere.
---@param path string
---@param kind Filetree.TermRun.Kind
---@return string
local function native_path(path, kind)
  -- No trailing separator: a folder from `:p` ends in one, and PowerShell refuses a quoted word
  -- with white space that ends in a backslash (`lib.nvim.cross.shell_quote`).
  local p = path_util.to_unix(path)
  if #p > 1 and not p:match("^%a:/$") then p = p:gsub("/+$", "") end
  if platform.is_windows() and (kind == "cmd" or kind == "powershell") then
    return (p:gsub("/", "\\"))
  end
  return p
end

---What a call sends, built for the shell family `kind`.
---@param path string
---@param kind Filetree.TermRun.Kind
---@return { argv: string[]?, line: string?, run: boolean }|nil plan
---@return string|nil err
function M.plan(path, kind)
  local sq = require("lib.nvim.cross.shell_quote")
  local p = native_path(path, kind)
  local runner = runner_for(path)
  if runner then
    local argv = runner(kind)
    argv[#argv + 1] = p
    local line, err = sq.argv_to_line(argv, kind)
    if not line then return nil, err end
    return { argv = argv, line = line, run = _cfg.execute ~= false }, nil
  end
  local word, err = sq.word(p, kind, false)
  if not word then return nil, err end
  return { line = word, run = false }, nil
end

---@internal
---`:!<line>` on the command line, not run. `%`, `#` and `!` are escaped (`:!` expands them).
---@param line string
local function to_cmdline(line)
  local escaped = line:gsub("([%%#!])", "\\%1")
  vim.api.nvim_feedkeys(":!" .. escaped, "n", false)
end

---Hand `path` to the terminal (or the command line).
---@param path string
---@param opts? { backend?: string }
---@return boolean ok
---@return string|nil err
function M.run_path(path, opts)
  if type(path) ~= "string" or path == "" then
    notify.warn("No node under cursor")
    return false, "no path"
  end
  local backend, berr = M.resolve_backend(opts and opts.backend)
  if not backend then
    notify.warn(berr or "no backend")
    return false, berr
  end
  local kind = shell_kind(backend)
  local plan, perr = M.plan(path, kind)
  if not plan then
    local msg = ("Cannot pass %s to the %s shell: %s"):format(path, kind, perr)
    notify.warn(msg)
    return false, msg
  end
  if backend == "cmdline" then
    to_cmdline(plan.line)
    return true, nil
  end
  local term = terminal_mod() --[[@as table]]
  local focus = _cfg.focus ~= false
  if plan.run and plan.argv then
    -- an argv: terminal.nvim quotes it for the shell its terminal really runs
    return term.run(plan.argv, { focus = focus })
  end
  return term.send(plan.line, { focus = focus, newline = false })
end

-- ── Public actions ────────────────────────────────────────────────────────────

---Run / type the node under the cursor.
---@param backend? string "terminal" | "cmdline" | "auto" (default: the configured one)
function M.run(backend)
  local node = _adapter and _adapter.get_current_node and _adapter.get_current_node()
  local path = node and node.path or nil
  if not path or path == "" then
    notify.warn("No node under cursor")
    return
  end
  M.run_path(path, { backend = backend })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeTermRunConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("term_run", _cfg, {
    {
      name = "run",
      field = "keymap",
      rhs = function()
        M.run()
      end,
      desc = "run script / type path in terminal",
    },
  })
end

function M.teardown()
  _adapter = nil
  _cfg = vim.deepcopy(DEFAULTS)
end

return M
