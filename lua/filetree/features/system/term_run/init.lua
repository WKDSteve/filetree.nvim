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

---@class Filetree.TermRun.RunnerOpts
---@field windows_path? boolean  The program is a Windows one started from WSL: it gets the path
---                              in Windows form (`wslpath -w`), a `/mnt/c/...` path it cannot find.

---@alias Filetree.TermRun.Runner fun(kind: Filetree.TermRun.Kind): string[], Filetree.TermRun.RunnerOpts?

---Built-in runners: extension → function(kind) returning the words in front of the path (and
---how the path is to be written).
---@type table<string, Filetree.TermRun.Runner>
M.DEFAULT_RUNNERS = {
  ps1 = function(kind)
    if kind == "powershell" then return {} end
    -- pwsh (looked up only when such a file is run) takes the path of its own system; Windows
    -- PowerShell started from WSL is a Windows program and needs the Windows form of it
    if platform.has_executable("pwsh") then return { "pwsh", "-NoProfile", "-File" } end
    return { platform.powershell_exe(), "-NoProfile", "-File" }, { windows_path = platform.is_wsl() }
  end,
  bat = function()
    -- WSL starts only .exe files of Windows, and cmd.exe cannot find a /mnt/c/... path.
    if platform.is_wsl() then return { "cmd.exe", "/c" }, { windows_path = true } end
    -- Native Windows: cmd.exe, PowerShell and Git-Bash all start a .bat as itself. No `cmd.exe /c`
    -- from Git-Bash: MSYS rewrites `/c` into `C:/` and cmd.exe opens a prompt instead, and the
    -- `//c` that MSYS hands on as `/c` does the same to every shell that does not rewrite it.
    return {}
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

---Built-in runners that need Windows (natively or from WSL); elsewhere such a file is only typed.
---@type table<string, true>
M.WINDOWS_ONLY = { bat = true, cmd = true }

---@internal
---@param path string
---@return string ext lower case, "" without one
local function ext_of(path)
  local name = vim.fs.basename(path)
  return (name:match("^.+%.([^.]+)$") or ""):lower()
end

---@internal
---Whether the file starts like a program: a `#!` line, or an ELF / Mach-O header. The executable
---bit alone says nothing on a Windows drive mounted in WSL (`/mnt/c`), where every file has it.
---@param path string
---@return boolean
local function starts_like_program(path)
  local fd = io.open(path, "rb")
  if not fd then return false end
  local head = fd:read(4) or ""
  fd:close()
  if head:sub(1, 2) == "#!" or head == "\127ELF" then return true end
  return head == "\207\250\237\254" -- Mach-O 64-bit (0xfeedfacf, little-endian)
    or head == "\206\250\237\254" -- Mach-O 32-bit
    or head == "\202\254\186\190" -- universal binary (0xcafebabe)
end

---@internal
---The runner of `path`: a user entry (words, or false) wins over the built-in one. A file without
---an extension runs as itself when it is executable and starts like a program (not on Windows,
---which has no executable bit).
---@param path string
---@return Filetree.TermRun.Runner|nil
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
  if ext ~= "" then
    if M.WINDOWS_ONLY[ext] and not (platform.is_windows() or platform.is_wsl()) then return nil end
    return M.DEFAULT_RUNNERS[ext]
  end
  if not platform.is_windows() and vim.fn.executable(path) == 1 and starts_like_program(path) then
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
  -- both entries this feature calls: another plugin's `terminal` module is not terminal.nvim
  if
    ok
    and type(mod) == "table"
    and type(mod.run) == "function"
    and type(mod.send) == "function"
  then
    return mod
  end
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
    local argv, ropts = runner(kind)
    if ropts and ropts.windows_path then
      local win = require("lib.nvim.cross.fs.wslpath").to_win(p)
      if not win then return nil, "wslpath -w could not convert the path" end
      p = win
    end
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
---`escape_ks` is true: the line is literal text, and a byte 0x80 inside a UTF-8 character of a
---path (`À`, Cyrillic `р`) would otherwise be read as the start of a special key.
---@param line string
local function to_cmdline(line)
  local escaped = line:gsub("([%%#!])", "\\%1")
  vim.api.nvim_feedkeys(":!" .. escaped, "n", true)
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
