-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/term_run_spec.lua -- `term_run` (<leader>.) hands the node under the cursor to a terminal:
-- a script is run (its argv to terminal.nvim, which quotes it for its shell), anything else has its
-- quoted path typed without Enter. Without terminal.nvim (or with backend = "cmdline") the line is
-- put on the command line as `:!...`, never run. `open_with.open_system` (<leader>sm) sends a
-- script here instead of to the OS. terminal.nvim and the OS opener are stand-ins.
--
--   nvim --clean --headless -u NONE -l TESTS/term_run_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
for _, dep in ipairs({ "lib.nvim", "ui.nvim" }) do
  for _, candidate in ipairs({
    vim.env[dep:upper():gsub("%.", "_") .. "_DIR"] or "",
    vim.fn.fnamemodify(root, ":h") .. "/" .. dep,
    root .. "/.deps/" .. dep,
    vim.fn.stdpath("data") .. "/lazy/" .. dep,
  }) do
    if candidate ~= "" and vim.fn.isdirectory(candidate .. "/lua") == 1 then
      vim.opt.rtp:prepend(candidate)
      break
    end
  end
end

local passed, failed = 0, 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end
local function ok(name, cond)
  eq(name, cond and true or false, true)
end

local platform = require("filetree.util.platform")
local path_util = require("filetree.util.path")

-- ── fixtures ──────────────────────────────────────────────────────────────────
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/sub dir", "p")
local function touch(rel)
  local p = dir .. "/" .. rel
  vim.fn.writefile({ "x" }, p)
  return path_util.to_unix(p)
end
local ps1 = touch("build.ps1")
local ps1_space = touch("sub dir/run me.ps1")
local sh = touch("deploy.sh")
local txt = touch("notes.txt")
local folder = path_util.to_unix(dir .. "/sub dir")

-- ── stand-ins ─────────────────────────────────────────────────────────────────
local warned = {} ---@type string[]
vim.notify = function(msg)
  warned[#warned + 1] = msg
end

local term_calls = {} ---@type table[]
local term_shell = "pwsh"
local function install_terminal()
  package.loaded["terminal"] = {
    run = function(cmd, o)
      term_calls[#term_calls + 1] = { what = "run", cmd = cmd, opts = o }
      return true
    end,
    send = function(text, o)
      term_calls[#term_calls + 1] = { what = "send", text = text, opts = o }
      return true
    end,
  }
  package.loaded["terminal.config"] = {
    shell_executable = function()
      return term_shell
    end,
  }
end
local function remove_terminal()
  package.loaded["terminal"] = nil
  package.loaded["terminal.config"] = nil
  package.preload["terminal"] = function()
    error("terminal.nvim is not installed (stand-in)")
  end
end

local fed ---@type string?
local real_feedkeys = vim.api.nvim_feedkeys
vim.api.nvim_feedkeys = function(keys, _, _)
  fed = keys
end

local opened ---@type string?
package.loaded["lib.nvim.cross.open_default"] = function(p)
  opened = p
  return true
end

local cursor = ps1
local adapter = {
  get_current_node = function()
    return { path = cursor }
  end,
}

local term_run = require("filetree.features.system.term_run")
term_run.setup({ enabled = true, backend = "auto" }, adapter)

-- ── runnable ──────────────────────────────────────────────────────────────────
ok("a .ps1 is runnable", term_run.runnable(ps1))
ok("a .sh is runnable", term_run.runnable(sh))
ok("a .txt is not", not term_run.runnable(txt))
ok("a folder is not", not term_run.runnable(folder))

-- ── plan: the line per shell family ───────────────────────────────────────────
local win = platform.is_windows()
local native_ps1 = win and path_util.to_win(ps1) or ps1
local plan = term_run.plan(ps1, "powershell")
eq("in PowerShell a .ps1 runs as itself", plan.argv, { native_ps1 })
eq("... and is run", plan.run, true)
local spaced = term_run.plan(ps1_space, "powershell")
ok("a path with a space gets the call operator: & '...'", spaced.line:sub(1, 3) == "& '")
local posix_plan = term_run.plan(ps1, "posix")
eq("in bash a .ps1 goes through PowerShell -File", posix_plan.argv[2], "-NoProfile")
eq("... with -File in front of the path", posix_plan.argv[3], "-File")
eq("... the path last, forward slashes", posix_plan.argv[4], ps1)
eq("a .sh runs through bash", term_run.plan(sh, "posix").argv, { "bash", sh })
local bat = touch("make.bat")

-- The host is a stand-in from here on: Windows, WSL or Linux, whatever this machine is.
local real_platform = {
  is_windows = platform.is_windows,
  is_wsl = platform.is_wsl,
  has_executable = platform.has_executable,
}
local function host(name, o)
  platform.is_windows = function()
    return name == "windows"
  end
  platform.is_wsl = function()
    return name == "wsl"
  end
  platform.has_executable = function(exe)
    return (o and o.pwsh or false) and exe == "pwsh"
  end
end
local function real_host()
  for k, f in pairs(real_platform) do
    platform[k] = f
  end
end
local converted = {} ---@type string[]
package.loaded["lib.nvim.cross.fs.wslpath"] = {
  to_win = function(p)
    converted[#converted + 1] = p
    return "C:\\from-wsl\\" .. vim.fs.basename(p)
  end,
}

host("windows")
eq(
  "Windows, bash (Git-Bash): a .bat runs as itself -- no `cmd.exe /c`, which MSYS turns into C:/",
  term_run.plan(bat, "posix").argv,
  { bat }
)
eq("... in cmd.exe as well", #term_run.plan(bat, "cmd").argv, 1)
host("wsl")
converted = {}
eq(
  "WSL: a .bat goes through cmd.exe /c with the Windows form of its path",
  term_run.plan(bat, "posix").argv,
  { "cmd.exe", "/c", "C:\\from-wsl\\make.bat" }
)
eq("... converted by wslpath", converted, { bat })
eq(
  "WSL without pwsh: a .ps1 goes to powershell.exe with the Windows form of its path",
  term_run.plan(ps1, "posix").argv,
  { "powershell.exe", "-NoProfile", "-File", "C:\\from-wsl\\build.ps1" }
)
host("wsl", { pwsh = true })
eq(
  "WSL with pwsh: a .ps1 keeps its own path (pwsh of the distribution)",
  term_run.plan(ps1, "posix").argv,
  { "pwsh", "-NoProfile", "-File", ps1 }
)
host("linux")
ok("Linux: a .bat is not run (no cmd.exe there)", not term_run.runnable(bat))
eq("... its path is typed", term_run.plan(bat, "posix").run, false)

-- A file without an extension: executable AND starting like a program. In WSL every file on
-- /mnt/c has the executable bit, so the bit alone would run a LICENSE.
local real_executable = vim.fn.executable
vim.fn.executable = function()
  return 1
end
local license = touch("LICENSE")
local tool = dir .. "/tool"
vim.fn.writefile({ "#!/bin/sh", "echo hi" }, tool)
local elf = dir .. "/elfbin"
local fd = assert(io.open(elf, "wb"))
fd:write("\127ELF\2\1\1")
fd:close()
ok("an executable file without a #! or binary header is not run", not term_run.runnable(license))
ok("... one with #! is", term_run.runnable(tool))
ok("... and an ELF binary is", term_run.runnable(elf))
vim.fn.executable = real_executable
real_host()

local txt_plan = term_run.plan(txt, "posix")
eq("a .txt is only typed, not run", txt_plan.run, false)
local sq = require("lib.nvim.cross.shell_quote")
eq("... as its path, quoted for the shell", txt_plan.line, (sq.word(txt, "posix", false)))
local folder_plan = term_run.plan(folder .. "/", "powershell")
ok("a folder with a space loses its trailing separator (PowerShell refuses one)", folder_plan)
ok("... and is quoted", folder_plan and folder_plan.line:find("'", 1, true) == 1)

-- ── backend: terminal.nvim ────────────────────────────────────────────────────
install_terminal()
eq("auto picks terminal.nvim when it is there", term_run.resolve_backend(), "terminal")
term_calls = {}
cursor = ps1
term_run.run()
eq("<leader>. on a .ps1 runs it in terminal.nvim", term_calls[1] and term_calls[1].what, "run")
eq("... as an argv terminal.nvim quotes", term_calls[1] and term_calls[1].cmd, { native_ps1 })
eq("... with the focus on the terminal", term_calls[1] and term_calls[1].opts.focus, true)

term_calls = {}
cursor = txt
term_run.run()
eq("on a .txt the path is typed", term_calls[1] and term_calls[1].what, "send")
eq("... without Enter", term_calls[1] and term_calls[1].opts.newline, false)

term_calls = {}
cursor = folder
term_run.run()
eq("on a folder its path is typed as well", term_calls[1] and term_calls[1].what, "send")

-- execute = false: the script's line is typed, not run
term_run.setup({ enabled = true, execute = false }, adapter)
term_calls = {}
cursor = ps1
term_run.run()
eq("execute = false types the line instead", term_calls[1] and term_calls[1].what, "send")
eq("... without Enter", term_calls[1] and term_calls[1].opts.newline, false)

-- runners: a user entry wins, false switches one off
term_run.setup({ enabled = true, runners = { txt = { "cat" }, sh = false } }, adapter)
ok("runners = { txt = {...} } makes a .txt runnable", term_run.runnable(txt))
eq("... with those words in front", term_run.plan(txt, "posix").argv, { "cat", txt })
ok("runners = { sh = false } makes a .sh only typed", not term_run.runnable(sh))
term_run.setup({ enabled = true }, adapter)

-- ── backend: the command line ─────────────────────────────────────────────────
fed = nil
term_calls = {}
cursor = sh
vim.o.shell = "bash"
term_run.run("cmdline")
eq("an explicit cmdline backend leaves terminal.nvim alone", #term_calls, 0)
eq(
  "... and puts :!<line> on the command line (no Enter)",
  fed,
  ":!" .. sq.argv_to_line({ "bash", sh }, "posix")
)

local pct = touch("100%.sh")
fed = nil
term_run.run_path(pct, { backend = "cmdline" })
ok("% is escaped for :!", fed and fed:find("100\\%.sh", 1, true) ~= nil)

-- The real command line: a path with a byte 0x80 inside a UTF-8 character ("À" is C3 80) must
-- arrive as typed, not as the start of a special key.
local accent = touch("Àrun.sh")
local seen ---@type string?
vim.api.nvim_create_autocmd("CmdlineLeave", {
  once = true,
  callback = function()
    seen = vim.fn.getcmdline()
  end,
})
vim.api.nvim_feedkeys = real_feedkeys
term_run.run_path(accent, { backend = "cmdline" })
-- <C-c> abandons the line. Not <Esc>: typed from typeahead it RUNS the line (:h c_<Esc>).
real_feedkeys("\3", "nx", false)
vim.api.nvim_feedkeys = function() end
eq(
  "a path with À reaches the command line unchanged",
  seen,
  "!" .. sq.argv_to_line({ "bash", accent }, "posix")
)

-- Another plugin's `terminal` module (no `send`) is not terminal.nvim.
package.loaded["terminal"] = {
  run = function() end,
}
eq(
  "a `terminal` module without send is not taken for terminal.nvim",
  term_run.resolve_backend(),
  "cmdline"
)

remove_terminal()
eq(
  "auto falls back to the command line without terminal.nvim",
  term_run.resolve_backend(),
  "cmdline"
)
warned = {}
local done = term_run.run_path(ps1, { backend = "terminal" })
eq("an explicit terminal backend without terminal.nvim fails", done, false)
ok("... and says why", warned[1] and warned[1]:find("not installed", 1, true))
eq("an unknown backend is refused", (term_run.resolve_backend("tmux")), nil)

-- ── <leader>sm: open_with sends a script to the terminal ──────────────────────
install_terminal()
package.loaded["filetree.features.system.term_run"] = term_run
-- filetree's registry of active features: term_run is on until the test switches it off
local term_run_active = true
package.loaded["filetree"] = {
  feature = function(name)
    return (name == "term_run" and term_run_active) and term_run or nil
  end,
}
if not pcall(require, "ui.kit") then package.loaded["ui.kit"] = {} end
local open_with = require("filetree.features.system.open_with")
open_with.setup({ enabled = true }, adapter)
term_calls, opened = {}, nil
cursor = ps1
open_with.open_system()
eq("<leader>sm on a .ps1 runs it in the terminal", term_calls[1] and term_calls[1].what, "run")
eq("... and not through the OS", opened, nil)
term_calls, opened = {}, nil
cursor = txt
open_with.open_system()
eq("<leader>sm on a .txt opens it through the OS", opened, txt)
eq("... and leaves the terminal alone", #term_calls, 0)
open_with.setup({ enabled = true, scripts_in_terminal = false }, adapter)
term_calls, opened = {}, nil
cursor = ps1
open_with.open_system()
eq("scripts_in_terminal = false hands a .ps1 to the OS", opened, ps1)
open_with.setup({ enabled = true }, adapter)
term_run_active = false
term_calls, opened = {}, nil
open_with.open_system()
eq("with term_run switched off, <leader>sm hands a .ps1 to the OS", opened, ps1)
eq("... and leaves the terminal alone", #term_calls, 0)

vim.api.nvim_feedkeys = real_feedkeys
vim.fn.delete(dir, "rf")
print(("\nfiletree.nvim term_run: %d passed, %d failed"):format(passed, failed))
vim.cmd(failed == 0 and "qa!" or "cq")
