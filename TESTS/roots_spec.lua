-- roots_spec.lua -- `filetree.roots`: root providers a plugin registers, and
-- that cwd_mode and util.target_dir ask them before their marker walk.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/roots_spec.lua
--
-- Exit 0 = all passed, 1 = a check failed.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

local function prepend_dep(envs, sibling, lazy_name, marker)
  local candidates = {}
  for _, env in ipairs(envs) do
    local v = vim.env[env]
    if v and v ~= "" then candidates[#candidates + 1] = v end
  end
  candidates[#candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/" .. sibling
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/" .. lazy_name
  for _, c in ipairs(candidates) do
    if vim.fn.isdirectory(c .. marker) == 1 then
      vim.opt.rtp:prepend(c)
      return
    end
  end
end
prepend_dep(
  { "FILETREE_LIB_NVIM", "LIB_NVIM_PATH", "LIB_NVIM_DIR" },
  "lib.nvim",
  "lib.nvim",
  "/lua/lib"
)

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  — " .. detail) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, ("got %s want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local normkey = require("lib.nvim.fs.normkey")
local roots = require("filetree.roots")

-- A repository with a case folder inside it, like WKDBook-Tricentis/Cases/.../1234.
local base = normkey(vim.fn.tempname())
local case = base .. "/Cases/Open/1234"
vim.fn.mkdir(base .. "/.git", "p")
vim.fn.mkdir(case .. "/Research", "p")
vim.fn.mkdir(base .. "/Notes", "p")
local function touch(rel)
  local h = assert(io.open(base .. "/" .. rel, "w"))
  h:write("x")
  h:close()
  return base .. "/" .. rel
end
local in_case = touch("Cases/Open/1234/Research/00_Research.md")
local outside = touch("Notes/a.md")

---The provider casedesk registers, reduced to a prefix test.
local function case_provider(p)
  if normkey(p):find(case, 1, true) == 1 then return case end
end

-- ── registry ────────────────────────────────────────────────────────────────

check("no provider registered", not roots.any())
eq("no provider, no root", roots.resolve(in_case), nil)

roots.register("case", case_provider)
check("a provider is registered", roots.any())
eq("the provider answers for its folders", normkey(roots.resolve(in_case)), case)
eq("and stays out of the others", roots.resolve(outside), nil)

roots.register("broken", function()
  error("broken")
end)
roots.register("missing", function()
  return base .. "/does/not/exist"
end)
eq("a raising provider is skipped", roots.resolve(outside), nil)
eq("a directory that does not exist is no answer", roots.resolve(outside), nil)
roots.unregister("broken")
roots.unregister("missing")
roots.unregister("never-registered")

-- A libuv callback is a fast-event context, where vim.fn raises (E5560).
do
  local got, err = nil, nil
  local timer = (vim.uv or vim.loop).new_timer()
  timer:start(0, 0, function()
    local ok, res = pcall(roots.resolve, in_case)
    if ok then
      got = res or false
    else
      err = res
    end
    timer:close()
  end)
  vim.wait(1000, function()
    return got ~= nil or err ~= nil
  end)
  eq("resolve works in a fast-event context (no vim.fn)", err, nil)
  eq("and answers there too", got and normkey(got), case)
end

-- ── util.target_dir (cwd_mode off) ──────────────────────────────────────────

local target = require("filetree.util.target_dir").new({ root_markers = { ".git" } })
eq("target_dir: a case file roots at the case folder", normkey(target(in_case)), case)
eq("target_dir: any other file keeps the repository root", normkey(target(outside)), base)

-- ── cwd_mode (follow and project) ───────────────────────────────────────────

local cwd_mode = require("filetree.features.nav.cwd_mode")
cwd_mode.setup({ enabled = true, indicator = { enabled = false } }, {
  name = "roots-stub",
  get_winid = function() end,
  get_current_node = function() end,
  get_root_path = function()
    return base
  end,
})
eq("cwd_mode.resolve: the case folder", cwd_mode.resolve(in_case), case)
eq("cwd_mode.resolve: the repository for other files", cwd_mode.resolve(outside), base)

vim.cmd("noautocmd cd " .. vim.fn.fnameescape(case))
cwd_mode.set_mode("project")
local d = cwd_mode.decide(in_case)
eq("project mode holds the case folder", d and normkey(d.root or d.cwd or ""), case)

roots.unregister("case")
eq("without the provider the repository is the root again", cwd_mode.resolve(in_case), base)
cwd_mode.teardown()

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
