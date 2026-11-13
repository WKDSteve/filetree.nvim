-- TESTS/refs/slow_scan_spec.lua -- TESTS/refs/run.lua must not race its own
-- asynchronous reference scan.
--
-- run.lua used to wait a fixed 2-5 s for each scan and then check the files
-- anyway. On a loaded machine the scan (the plaintext provider is the heaviest)
-- took longer, and the half-finished rename was reported as wrong content
-- ("docs/index.md updated -- missing ../notes/Renamed.md"), on and off for the
-- same tree. This spec runs the plaintext case of run.lua in a child process
-- with every scan result held back 6 s -- longer than the old limit -- and
-- asserts that it still passes, and that a wait which really does run out is
-- reported as a TIMEOUT of its own and not as a content check.
--
--   nvim --clean --headless -u NONE -l TESTS/refs/slow_scan_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local run_lua = vim.fn.fnamemodify(this, ":p:h") .. "/run.lua"

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

---The directory on this editor's runtimepath that holds `lua/<mod>`.
---@param mod string
---@return string?
local function rtp_dir(mod)
  for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
    if vim.fn.isdirectory(dir .. "/lua/" .. mod) == 1 then return dir end
  end
  return nil
end

---Run the plaintext case of run.lua with the given extra environment.
---@param env table<string, string>
---@return integer code, string out
local function run(env)
  -- An empty WAIT_MS reads as "unset" (run.lua's default), whatever the caller's
  -- environment says; a case that wants a limit names it.
  env = vim.tbl_extend(
    "force",
    { FILETREE_REFS_TEST_ONLY = "plaintext", FILETREE_REFS_TEST_WAIT_MS = "" },
    env
  )
  -- run.lua finds lib.nvim and ui.nvim through these variables, a sibling
  -- checkout or the lazy.nvim directory. testing.nvim puts them on THIS
  -- editor's runtimepath, and in a checkout without siblings (the snapshot of
  -- `scripts/test.sh ci commit`, under the temp dir) nothing else finds them:
  -- the child died on `require("ui.kit")` within a second, and every full run
  -- through `ci commit` reported this spec red ("run.lua exits 0 -- exit 1").
  for var, mod in pairs({ FILETREE_LIB_NVIM = "lib", FILETREE_UI_NVIM = "ui" }) do
    if (vim.env[var] or "") == "" and env[var] == nil then env[var] = rtp_dir(mod) end
  end
  local res = vim
    .system({ vim.v.progpath, "--clean", "--headless", "-u", "NONE", "-l", run_lua }, {
      env = env,
      text = true,
    })
    :wait(120000)
  return res.code, (res.stdout or "") .. (res.stderr or "")
end

---@param out string
---@return string[]
local function fail_lines(out)
  local lines = {}
  for line in out:gmatch("[^\r\n]+") do
    if line:find("^%s*FAIL ") then lines[#lines + 1] = line end
  end
  return lines
end

print("\n== a scan slower than the old fixed 5 s wait ==")
do
  local code, out = run({ FILETREE_REFS_TEST_SCAN_DELAY_MS = "6000" })
  check("run.lua exits 0", code == 0, ("exit %d\n%s"):format(code, out))
  check("no check failed", #fail_lines(out) == 0, table.concat(fail_lines(out), " | "))
  check(
    "the plaintext rewrites were checked at all",
    out:find("ok   plaintext: docs/index.md updated", 1, true) ~= nil,
    out
  )

  -- The runner (testing.nvim: scripts/test.sh, CI) kills the whole file after
  -- `timeouts.file_ms`. A default limit per wait that long would let the kill
  -- win, and the TIMEOUT line naming the stuck wait would never be printed;
  -- and a FILETREE_REFS_TEST_* variable the runner does not pass through
  -- would make "raise FILETREE_REFS_TEST_WAIT_MS" a remedy that does nothing.
  local cfg = dofile(vim.fn.fnamemodify(this, ":p:h:h:h") .. "/.testing.lua")
  local file_ms = (cfg.timeouts or {}).file_ms or 60000
  local limit = tonumber(out:match("refs: waiting up to (%d+) ms per scan"))
  check(
    "the default wait leaves the runner's file limit room for a normal run",
    limit ~= nil and limit * 2 <= file_ms,
    ("limit %s ms, file_ms %d"):format(tostring(limit), file_ms)
  )
  local function allowed(name)
    for _, pat in ipairs(cfg.env_allow or {}) do
      if pat == name or (pat:sub(-1) == "*" and name:sub(1, #pat - 1) == pat:sub(1, -2)) then
        return true
      end
    end
    return false
  end
  for _, name in ipairs({
    "FILETREE_REFS_TEST_WAIT_MS",
    "FILETREE_REFS_TEST_SCAN_DELAY_MS",
    "FILETREE_REFS_TEST_ONLY",
  }) do
    check(".testing.lua passes " .. name .. " through to the spec", allowed(name))
  end
end

print("\n== a wait that really runs out ==")
do
  local code, out = run({
    FILETREE_REFS_TEST_SCAN_DELAY_MS = "3000",
    FILETREE_REFS_TEST_WAIT_MS = "500",
  })
  local fails = fail_lines(out)
  check("run.lua exits non-zero", code ~= 0, ("exit %d"):format(code))
  check(
    "the only FAIL is the TIMEOUT",
    #fails == 1 and fails[1]:find("FAIL TIMEOUT waiting for", 1, true) ~= nil,
    table.concat(fails, " | ")
  )
  -- A failed run keeps its scratch dir for inspection; it is unique per run.
  local kept = out:match("scratch dir kept for inspection: ([^\r\n]+)")
  check(
    "the scratch dir is per run (pid + hrtime)",
    kept ~= nil and kept:find("filetree%-refs%-test%-%d+%-%d+$") ~= nil,
    tostring(kept)
  )
  if kept then vim.fn.delete(kept, "rf") end
end

print(("\nfiletree.nvim refs/slow_scan_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
