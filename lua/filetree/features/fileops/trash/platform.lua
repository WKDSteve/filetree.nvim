---@module 'filetree.features.fileops.trash.platform'
---@brief Platform-specific "send to trash" implementations.

local platform = require("filetree.util.platform")
local ps_escape = require("lib.nvim.cross.powershell").escape_single

local M = {}

---@alias TrashResult { ok: boolean, err: string? }

---@internal
---Run `argv` without blocking the UI thread and hand the outcome to `cb`.
---
---Every backend below used to go through `lib.nvim.cross.run_argv.run_blocking`
---(and, for the AppleScript fallback, `os.execute`), all of which block the
---editor until the external process exits. On Windows that process is
---PowerShell, whose startup alone costs several hundred milliseconds -- so
---every single `d` in the tree froze Neovim, multiplied by the number of
---marked nodes in a batch. vim.system() reports back via callback instead.
---@param argv string[]
---@param err_msg string  message for a non-zero exit
---@param cb fun(result: TrashResult)
local function run(argv, err_msg, cb)
  if not vim.system then
    -- Neovim < 0.10: no async process API. Keep the old blocking behaviour
    -- rather than failing outright.
    local ok = require("lib.nvim.cross.run_argv").run_blocking(argv)
    cb({ ok = ok, err = not ok and err_msg or nil })
    return
  end

  vim.system(argv, { text = true }, function(res)
    -- vim.system callbacks run off the main loop; every caller of `cb` goes on
    -- to touch buffers, notify and the tree adapter.
    vim.schedule(function()
      cb({ ok = res.code == 0, err = res.code ~= 0 and err_msg or nil })
    end)
  end)
end

---@internal
---Same existence check as `filetree.util.conflict.exists`, duplicated
---rather than required: platform.lua only reasons about OS trash
---mechanics and stays a leaf module with no sibling-util dependency; a
---bare `filereadable`/`isdirectory` pair would miss a broken symlink (which
---is neither, yet very much still an entry on disk).
---@param path string
---@return boolean
local function path_exists(path)
  if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then return true end
  return (vim.uv or vim.loop).fs_lstat(path) ~= nil
end

-- ── Windows ───────────────────────────────────────────────────────────────────

---@param path string  Absolute path. For the WSL caller below this is
---                    already the *converted* Windows-style path, so
---                    `isdirectory` on it would test the wrong filesystem --
---                    that caller passes `is_dir` explicitly instead.
---@param cb fun(result: TrashResult)
---@param is_dir boolean?  Defaults to `vim.fn.isdirectory(path) == 1`.
local function trash_windows(path, cb, is_dir)
  -- Paths need native backslash separators for the .NET APIs below, and
  -- PowerShell single-quoted strings escape an embedded quote by doubling it
  -- ('' not \'), and treat U+2018..U+201B as quotes too, so a path containing
  -- one breaks (or escapes) the script otherwise; see lib.nvim.cross.powershell.
  -- Handled the same way in trash/undo.lua's restore_windows.
  local win_path = ps_escape((path:gsub("/", "\\")))
  if is_dir == nil then is_dir = vim.fn.isdirectory(path) == 1 end

  -- Microsoft.VisualBasic.FileIO.FileSystem, NOT Shell.Application's
  -- ParseName(...).InvokeVerb('delete') (what this used to be): that verb
  -- replays the exact same shell action as a manual Explorer delete,
  -- INCLUDING the "Are you sure you want to move this item to the Recycle
  -- Bin?" confirmation dialog -- which this script can never answer
  -- (-NonInteractive, no window for the user to even find). One marked file
  -- landing on that verb silently stalls the whole batch: do_trash's
  -- callback for that path never fires, so run_all's chain never reaches the
  -- paths queued after it, until a human notices the invisible dialog and
  -- clicks it (by which point the rest of the batch has usually been
  -- re-done by hand). UIOption.OnlyErrorDialogs suppresses exactly that
  -- confirmation while still surfacing real errors (permission denied, path
  -- too long, file in use, ...) as a non-zero exit via the try/catch below.
  local method = is_dir and "DeleteDirectory" or "DeleteFile"
  local script = string.format(
    "Add-Type -AssemblyName Microsoft.VisualBasic; "
      .. "try { [Microsoft.VisualBasic.FileIO.FileSystem]::%s("
      .. "'%s', "
      .. "[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, "
      .. "[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) } "
      .. "catch { exit 1 }",
    method,
    win_path
  )
  run(
    { "powershell", "-NoProfile", "-NonInteractive", "-Command", script },
    "PowerShell trash failed",
    cb
  )
end

---@internal
---One PowerShell process for the WHOLE batch instead of one per path.
---
---powershell.exe's own startup plus loading the Microsoft.VisualBasic
---assembly costs several hundred ms to a couple of seconds each (worse
---under real-time antivirus scanning of every new process) -- multiplied by
---a multi-mark batch, that is where "trashing 26 files took 30 seconds"
---comes from. Every individual FileSystem.DeleteFile/DeleteDirectory call
---*inside* one already-running process is comparatively instant, so
---amortizing the startup cost across the batch is the actual win, not
---making each delete itself faster.
---@param targets { win_path: string, is_dir: boolean }[]  win_path already
---       backslash/quote-escaped, same as trash_windows above.
---@param cb fun(results: TrashResult[])  one result per target, same order.
local function run_windows_batch(targets, cb)
  local items = {}
  for _, t in ipairs(targets) do
    items[#items + 1] =
      string.format("@{Path='%s';IsDir=$%s}", t.win_path, t.is_dir and "true" or "false")
  end

  -- Each target's own try/catch means one failure (locked file, permission
  -- denied) does not abort the rest of the batch -- same "independent
  -- failures" contract run_all already relies on for the per-path chain.
  -- $results is force-cast to [array] so a 1-target batch still comes back
  -- as a JSON array from ConvertTo-Json below, instead of Windows
  -- PowerShell 5.1's usual "a 1-element pipeline collapses to a bare
  -- object" behaviour.
  local script = "Add-Type -AssemblyName Microsoft.VisualBasic; "
    .. "$targets = @("
    .. table.concat(items, ",")
    .. "); "
    .. "[array]$results = foreach ($t in $targets) { "
    .. "try { "
    .. "if ($t.IsDir) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($t.Path, "
    .. "[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, "
    .. "[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) } "
    .. "else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($t.Path, "
    .. "[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, "
    .. "[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) } "
    .. "@{Ok=$true} "
    .. "} catch { @{Ok=$false;Err=$_.Exception.Message} } "
    .. "}; "
    .. "ConvertTo-Json -InputObject $results -Compress"

  vim.system(
    { "powershell", "-NoProfile", "-NonInteractive", "-Command", script },
    { text = true },
    function(res)
      vim.schedule(function()
        cb(M._parse_batch_output(res, #targets))
      end)
    end
  )
end

---@internal
---Decode `run_windows_batch`'s JSON stdout into one `TrashResult` per
---target, tolerating a non-zero exit (the whole process failed to even
---start the script) and unparseable output (a PowerShell version quirk)
---by falling back to "every target failed" rather than erroring.
---@param res vim.SystemCompleted
---@param count integer
---@return TrashResult[]
function M._parse_batch_output(res, count)
  local function all_failed(err)
    local results = {}
    for i = 1, count do
      results[i] = { ok = false, err = err }
    end
    return results
  end

  if res.code ~= 0 then return all_failed("PowerShell batch trash failed") end

  local ok_decode, decoded = pcall(vim.json.decode, res.stdout or "")
  if not ok_decode or type(decoded) ~= "table" then
    return all_failed("Could not parse PowerShell batch trash output")
  end

  local results = {}
  for i = 1, count do
    local item = decoded[i]
    if type(item) == "table" and item.Ok == true then
      results[i] = { ok = true }
    else
      results[i] = { ok = false, err = (type(item) == "table" and item.Err) or "unknown error" }
    end
  end
  return results
end

---@internal
---Escape `s` for embedding in an AppleScript double-quoted string literal.
---
---Order matters: the backslash first, or the escapes added for `"` are
---themselves re-escaped and the result is wrong in the other direction.
---@param s string
---@return string
local function applescript_string(s)
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- ── macOS ─────────────────────────────────────────────────────────────────────

---@param path string
---@param cb fun(result: TrashResult)
local function trash_mac(path, cb)
  -- `trash` CLI (brew install trash) preferred; AppleScript fallback
  if vim.fn.executable("trash") == 1 then
    run({ "trash", path }, "trash CLI failed", cb)
    return
  end
  -- AppleScript fallback. This used to be an os.execute() shell string; as an
  -- argv list osascript gets the script as one argument and no shell is
  -- involved, so the path no longer has to survive shell quoting.
  --
  -- It does still have to survive *AppleScript* quoting, and the backslash has
  -- to be escaped before the quote, not after. AppleScript escapes with `\`
  -- like C does, so escaping only `"` leaves a path ending in a backslash
  -- reading as `\\"` -- a literal backslash followed by a quote that closes
  -- the string early. Everything after it is then AppleScript source, and
  -- `do shell script` is one word away. Both characters are legal in a macOS
  -- filename, so a crafted name in a cloned repo is enough.
  run({
    "osascript",
    "-e",
    string.format('tell app "Finder" to delete POSIX file "%s"', applescript_string(path)),
  }, "AppleScript trash failed", cb)
end

---@internal
---One process for the whole batch, same idea as `run_windows_batch` but far
---simpler: both the `trash` CLI and Finder's `delete` Apple Event already
---accept a LIST of items in a single call (`delete {file1, file2, ...}` is
---the idiomatic way to trash several Finder items at once, not a loop of
---separate `tell` invocations), so there is no generated script/JSON
---round-trip to build here -- just pass every path in one invocation.
---
---Neither backend reports which individual path failed when the batch's
---exit code is non-zero (a locked file among otherwise-fine ones, say), so
---this checks existence afterward instead -- mirrors the pre-flight
---`conflict.exists` the caller already ran, and is the one outcome that
---means the same thing regardless of which backend (or its locale/version)
---produced it.
---@param paths string[]
---@param cb fun(results: TrashResult[])  one result per input path, same order.
local function run_mac_batch(paths, cb)
  local function finish(err_msg)
    local results = {}
    for i, p in ipairs(paths) do
      results[i] = path_exists(p) and { ok = false, err = err_msg } or { ok = true }
    end
    cb(results)
  end

  if vim.fn.executable("trash") == 1 then
    local argv = { "trash" }
    for _, p in ipairs(paths) do
      argv[#argv + 1] = p
    end
    run(argv, "trash CLI failed", function(result)
      finish(result.err)
    end)
    return
  end

  local specs = {}
  for _, p in ipairs(paths) do
    specs[#specs + 1] = string.format('POSIX file "%s"', applescript_string(p))
  end
  run(
    {
      "osascript",
      "-e",
      string.format('tell app "Finder" to delete {%s}', table.concat(specs, ", ")),
    },
    "AppleScript trash failed",
    function(result)
      finish(result.err)
    end
  )
end

-- ── Linux ─────────────────────────────────────────────────────────────────────

---@param path string
---@param cb fun(result: TrashResult)
local function trash_linux(path, cb)
  -- Prefer gio (most widely available on modern desktops)
  if vim.fn.executable("gio") == 1 then
    run({ "gio", "trash", path }, "gio trash failed", cb)
    return
  end
  -- trash-cli fallback
  if vim.fn.executable("trash-put") == 1 then
    run({ "trash-put", path }, "trash-put failed", cb)
    return
  end
  -- Manual: move to XDG Trash
  local trash_dir = (vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")) .. "/Trash/files"
  if vim.fn.isdirectory(trash_dir) == 0 then vim.fn.mkdir(trash_dir, "p") end
  local base = vim.fn.fnamemodify(path, ":t")
  local dst = trash_dir .. "/" .. base
  run({ "mv", path, dst }, "mv to XDG Trash failed", cb)
end

---@internal
---One process for the whole batch: `gio trash`, `trash-put` and `mv` (into
---a directory destination) all already accept multiple source paths in a
---single invocation, same as `run_mac_batch`'s reasoning -- no
---generated-script trick needed here either. Per-path outcome is
---determined the same way too: check existence afterward rather than
---trying to attribute one shared exit code across several paths.
---@param paths string[]
---@param cb fun(results: TrashResult[])  one result per input path, same order.
local function run_linux_batch(paths, cb)
  local function finish(err_msg)
    local results = {}
    for i, p in ipairs(paths) do
      results[i] = path_exists(p) and { ok = false, err = err_msg } or { ok = true }
    end
    cb(results)
  end

  local argv, err_msg
  if vim.fn.executable("gio") == 1 then
    argv, err_msg = { "gio", "trash" }, "gio trash failed"
  elseif vim.fn.executable("trash-put") == 1 then
    argv, err_msg = { "trash-put" }, "trash-put failed"
  end

  if argv then
    for _, p in ipairs(paths) do
      argv[#argv + 1] = p
    end
    run(argv, err_msg, function(result)
      finish(result.err)
    end)
    return
  end

  -- Manual XDG fallback: `mv src1 src2 ... trash_dir` (a directory
  -- destination), same primitive as the single-path trash_linux above --
  -- including the same same-basename-from-different-dirs collision that
  -- already existed there (the second `mv` silently overwrites the first's
  -- trashed copy), unrelated to batching it.
  local trash_dir = (vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")) .. "/Trash/files"
  if vim.fn.isdirectory(trash_dir) == 0 then vim.fn.mkdir(trash_dir, "p") end
  local mv_argv = { "mv" }
  for _, p in ipairs(paths) do
    mv_argv[#mv_argv + 1] = p
  end
  mv_argv[#mv_argv + 1] = trash_dir
  run(mv_argv, "mv to XDG Trash failed", function(result)
    finish(result.err)
  end)
end

-- ── WSL ───────────────────────────────────────────────────────────────────────

---@param path string
---@param cb fun(result: TrashResult)
local function trash_wsl(path, cb)
  -- Determined from the ORIGINAL (Linux-side) path, before wslpath below
  -- rewrites it to a Windows-style string that `isdirectory` on this side
  -- can no longer resolve (`trash_windows` would otherwise always fall back
  -- to "file").
  local is_dir = vim.fn.isdirectory(path) == 1

  -- is_wsl() reads the kernel release, so a plain Linux userland on a WSL2 kernel (a container on the
  -- podman machine, a distro without interop) lands here without wslpath; vim.system would throw ENOENT.
  if vim.fn.executable("wslpath") ~= 1 then
    cb({ ok = false, err = "wslpath not found (WSL detected, but no WSL interop)" })
    return
  end

  -- Convert to Windows path and use PowerShell Recycle Bin. Two chained
  -- spawns; both used to block.
  if not vim.system then
    local win_path = vim.fn.system({ "wslpath", "-w", path }):gsub("\n", "")
    if win_path == "" then
      cb({ ok = false, err = "wslpath conversion failed for: " .. path })
      return
    end
    trash_windows(win_path, cb, is_dir)
    return
  end

  vim.system({ "wslpath", "-w", path }, { text = true }, function(res)
    local win_path = (res.stdout or ""):gsub("[\r\n]", "")
    vim.schedule(function()
      if res.code ~= 0 or win_path == "" then
        cb({ ok = false, err = "wslpath conversion failed for: " .. path })
        return
      end
      trash_windows(win_path, cb, is_dir)
    end)
  end)
end

-- ── Dispatch ──────────────────────────────────────────────────────────────────

---Send a file or directory to the system trash.
---
---Asynchronous: the result arrives through `cb`, never as a return value.
---@param path string  Absolute path.
---@param cb fun(result: TrashResult)
---@return nil
function M.send(path, cb)
  if platform.is_wsl() then return trash_wsl(path, cb) end
  if platform.is_windows() then return trash_windows(path, cb) end
  if platform.is_mac() then return trash_mac(path, cb) end
  return trash_linux(path, cb)
end

---Send several paths to trash in as few external processes as possible.
---
---Every backend that can genuinely batch does: native Windows (see
---`run_windows_batch` -- the per-process powershell.exe + COM/.NET startup
---cost was the actual bottleneck for a multi-mark delete, several hundred ms
---to a couple of seconds each), macOS (`run_mac_batch`) and Linux
---(`run_linux_batch`). WSL and pre-0.10 Neovim (no vim.system to parse
---`run_windows_batch`'s JSON stdout with) fall back to a plain sequential
---loop over `M.send`, identical to what callers used to chain by hand --
---neither was ever the reported slowdown, and WSL's own two-hop
---wslpath+PowerShell dance per path is not worth batching on top of.
---@param paths string[]
---@param cb fun(results: TrashResult[])  one result per input path, same order.
---@return nil
function M.send_batch(paths, cb)
  if #paths == 0 then return cb({}) end

  if vim.system and platform.is_windows() and not platform.is_wsl() then
    local targets = {}
    for i, p in ipairs(paths) do
      targets[i] =
        { win_path = ps_escape((p:gsub("/", "\\"))), is_dir = vim.fn.isdirectory(p) == 1 }
    end
    return run_windows_batch(targets, cb)
  end
  if platform.is_mac() then return run_mac_batch(paths, cb) end
  if platform.is_linux() and not platform.is_wsl() then return run_linux_batch(paths, cb) end

  local results = {}
  local i = 0
  local function step()
    i = i + 1
    if i > #paths then return cb(results) end
    M.send(paths[i], function(result)
      results[i] = result
      step()
    end)
  end
  step()
end

---Return true when a trash CLI is available on the current platform.
---@return boolean
function M.available()
  if platform.is_windows() or platform.is_wsl() or platform.is_mac() then return true end
  return vim.fn.executable("gio") == 1
    or vim.fn.executable("trash-put") == 1
    or vim.fn.executable("trash") == 1
end

---Return a short description of the platform's trash backend.
---@return string
function M.backend_name()
  if platform.is_wsl() then return "PowerShell Recycle Bin (via WSL)" end
  if platform.is_windows() then return "PowerShell Recycle Bin" end
  if platform.is_mac() then
    return vim.fn.executable("trash") == 1 and "trash CLI" or "AppleScript Finder"
  end
  if vim.fn.executable("gio") == 1 then return "gio" end
  if vim.fn.executable("trash-put") == 1 then return "trash-cli" end
  return "XDG Trash (mv)"
end

return M
