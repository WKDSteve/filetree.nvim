-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/trash_linux_container_spec.lua -- the Linux trash backend against the real tools of a Linux container
-- (testing.container: `gio trash`, then `trash-put` once gio is gone). The checks run in
-- TESTS/container/trash_linux.lua inside the container; this file starts them and judges the outcome.
-- Prints `n/a` and ends green where no container engine or image exists.
--
--   nvim --clean --headless -u NONE -l TESTS/trash_linux_container_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
for _, dep in ipairs({ "testing.nvim" }) do
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

local ok_mod, container = pcall(require, "testing.container")
if not ok_mod then
  print("n/a  testing.nvim is not on the runtimepath (testing.container)")
  return
end
local available, reason = container.available()
if not available then
  print("n/a  " .. reason)
  return
end

-- The mounts need the engine's view of the host path (podman on Windows takes `E:\repos` as is).
local repos = vim.fn.fnamemodify(root, ":h")
local passed, failed = 0, 0
local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL  " .. msg)
  end
end

local function in_container(script, extra_env)
  return container.run({
    "nvim",
    "--headless",
    "--clean",
    "-u",
    "NONE",
    "-l",
    "/repos/filetree.nvim/TESTS/container/" .. script,
    "/repos",
  }, { mounts = { [repos] = "/repos" }, env = extra_env })
end

local res = in_container("trash_linux.lua")
check(res.code == 0, "gio backend: exit " .. res.code .. "\n" .. res.stdout .. res.stderr)
check(
  (res.stdout .. res.stderr):find("TRASH_OK gio", 1, true) ~= nil,
  "gio is the backend while present: " .. res.stdout .. res.stderr
)

-- Without gio the same script must go through trash-put: PATH is cut down to a directory that has no gio.
local no_gio = container.run({
  "sh",
  "-c",
  "mkdir -p /home/tester/bin && ln -s /usr/bin/trash-put /home/tester/bin/trash-put && ln -s /usr/bin/nvim /home/tester/bin/nvim"
    .. " && ln -s /usr/bin/python3 /home/tester/bin/python3 && PATH=/home/tester/bin:/usr/local/bin"
    .. " nvim --headless --clean -u NONE -l /repos/filetree.nvim/TESTS/container/trash_linux.lua /repos",
}, { mounts = { [repos] = "/repos" } })
check(
  no_gio.code == 0,
  "trash-put backend: exit " .. no_gio.code .. "\n" .. no_gio.stdout .. no_gio.stderr
)
check(
  (no_gio.stdout .. no_gio.stderr):find("TRASH_OK trash-cli", 1, true) ~= nil,
  "trash-cli is the backend without gio: " .. no_gio.stdout .. no_gio.stderr
)

local wsl = in_container("trash_wsl_no_wslpath.lua")
check(wsl.code == 0, "wsl without wslpath: exit " .. wsl.code .. "\n" .. wsl.stdout .. wsl.stderr)
check(
  (wsl.stdout .. wsl.stderr):find("WSL_NO_WSLPATH_OK", 1, true) ~= nil,
  "a missing wslpath is a reported failure: " .. wsl.stdout .. wsl.stderr
)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
