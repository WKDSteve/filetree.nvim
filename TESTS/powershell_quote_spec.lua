-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/powershell_quote_spec.lua -- the PowerShell single-quote escaping behind
-- the Windows trash, trash-undo and folder-size commands. PowerShell treats
-- U+2018..U+201B as quotes, so doubling only the ASCII `'` let a file name
-- close the string. The pure escape runs everywhere; the round trips through a
-- real powershell.exe (trash, restore, size, no side effect from an injected
-- name) run on Windows only.
--
--   nvim --clean --headless -u NONE -l TESTS/powershell_quote_spec.lua

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

local uv = vim.uv or vim.loop
local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

local escape = require("lib.nvim.cross.powershell").escape_single
local QUOTES = { "\226\128\152", "\226\128\153", "\226\128\154", "\226\128\155" } -- U+2018..U+201B

-- ── pure escape ───────────────────────────────────────────────────────────────
eq("plain text is untouched", escape("plain name.md"), "plain name.md")
eq("ASCII quote is doubled", escape("it's"), "it''s")
for i, q in ipairs(QUOTES) do
  eq(string.format("U+%X is doubled", 0x2017 + i), escape("a" .. q .. "b"), "a" .. q .. q .. "b")
end
eq(
  "other multi-byte text is untouched",
  escape("\195\164\226\130\172 \226\128\156x\226\128\157"),
  "\195\164\226\130\172 \226\128\156x\226\128\157"
)
eq(
  "every quote in a mix is doubled",
  escape("'" .. QUOTES[2] .. "'"),
  "''" .. QUOTES[2] .. QUOTES[2] .. "''"
)

-- ── real PowerShell (Windows only) ────────────────────────────────────────────
if vim.fn.has("win32") ~= 1 or vim.fn.executable("powershell") ~= 1 then
  print("  skip real PowerShell round trips (needs Windows + powershell.exe)")
else
  local UTF8 = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); "
  local function ps(script)
    return vim
      .system(
        { "powershell", "-NoProfile", "-NonInteractive", "-Command", UTF8 .. script },
        { text = true }
      )
      :wait(15000) -- bounded: a PowerShell that never ends fails the case with its output
  end

  local names = {
    "it" .. QUOTES[2] .. "s",
    "a" .. QUOTES[1] .. "b",
    "c" .. QUOTES[3] .. "d",
    "e" .. QUOTES[4] .. "f",
    "g'h",
  }
  names[#names + 1] = "x'; Write-Output INJECTED; '"
  names[#names + 1] = "x" .. QUOTES[2] .. "; Write-Output INJECTED; " .. QUOTES[2]

  -- the escaped text, inside '...', evaluates to the original string and nothing else
  for _, n in ipairs(names) do
    local res = ps("Write-Output '" .. escape(n) .. "'")
    if res.code == 124 then
      -- killed after the bound: stop with what is known (the runner kills the whole file at 60 s)
      check(
        "PowerShell answers within 15 s for " .. vim.inspect(n),
        false,
        ("code=%s stdout=%s stderr=%s"):format(
          tostring(res.code),
          vim.inspect(res.stdout),
          vim.inspect(res.stderr)
        )
      )
      print(("\nfiletree.nvim powershell_quote_spec: %d passed, %d failed"):format(passed, failed))
      vim.cmd("cq")
    end
    local out = (res.stdout or ""):gsub("\r?\n$", "")
    eq("PowerShell reads back " .. vim.inspect(n), out, n)
  end

  -- trash, restore and size really work on such names
  local base = (uv.fs_realpath(vim.env.TEMP or vim.env.TMP or ".") or "."):gsub("\\", "/")
  local dir = base .. "/ftps_" .. ("%d"):format(uv.hrtime())
  vim.fn.mkdir(dir, "p")
  local trash = require("filetree.features.fileops.trash.platform")
  local undo = require("filetree.features.fileops.trash.undo")

  -- bounded waits (the Windows runner once hung here for the whole file limit): each step reports whether it finished
  local function wait_for(cond)
    return vim.wait(20000, cond, 50)
  end

  local files = {}
  for i, n in ipairs(names) do
    if not n:find(";", 1, true) or i >= 6 then files[#files + 1] = dir .. "/" .. n end
  end
  for _, f in ipairs(files) do
    local fd = io.open(f, "wb")
    if fd then
      fd:write("x")
      fd:close()
    end
  end
  local existing = vim.tbl_filter(function(f)
    return vim.fn.filereadable(f) == 1
  end, files)
  check("the awkward names could be created", #existing == #files, #existing .. "/" .. #files)

  -- folder size: the command must succeed (code 0) and report the bytes
  local size_done, size_bytes
  require("filetree.features.ui.size_info")._query_dir_size(dir, function(bytes)
    size_done, size_bytes = true, bytes
  end)
  check(
    "folder size answers within 20 s",
    wait_for(function()
      return size_done
    end)
  )
  eq("folder size of a directory holding such names", size_bytes, #existing)

  -- single trash + restore, per name
  for _, f in ipairs(existing) do
    local res
    trash.send(f, function(r)
      res = r
    end)
    check(
      "trash answers within 20 s: " .. vim.inspect(vim.fn.fnamemodify(f, ":t")),
      wait_for(function()
        return res ~= nil
      end)
    )
    check("trash " .. vim.inspect(vim.fn.fnamemodify(f, ":t")), res and res.ok, res and res.err)
    check("  the file is gone", vim.fn.filereadable(f) == 0)
    undo.record(f)
    local ok, err = undo.restore_blocking(undo.last(), 20000)
    check("  restored", ok and vim.fn.filereadable(f) == 1, err)
  end
  eq("no side effect from an injected name", vim.fn.filereadable(dir .. "/INJECTED"), 0)

  -- batch trash
  local results
  trash.send_batch(existing, function(r)
    results = r
  end)
  check(
    "batch trash answers within 20 s",
    wait_for(function()
      return results ~= nil
    end)
  )
  local all_ok = results ~= nil
  for _, r in ipairs(results or {}) do
    all_ok = all_ok and r.ok
  end
  check("batch trash of all names succeeds", all_ok)
  local left = 0
  for _, f in ipairs(existing) do
    left = left + vim.fn.filereadable(f)
  end
  eq("and removed them all", left, 0)
  -- put them back so the Recycle Bin is left as found
  for _, f in ipairs(existing) do
    undo.record(f)
    undo.restore_blocking(undo.last(), 20000)
  end
  vim.fn.delete(dir, "rf")
end

print(("\nfiletree.nvim powershell_quote_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
