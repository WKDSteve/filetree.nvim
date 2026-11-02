-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read -- this file must crash and name it. The nil guards LuaLS
-- asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- feature_setup_fresh_spec.lua -- every feature's setup() starts from its defaults.
--
-- A feature module keeps its options in `_cfg`. `M.setup()` used to merge the new
-- options over the previous `_cfg`, so an option set by one call and left out of the next
-- kept its value until the editor restarted. Now each module has a literal `DEFAULTS`
-- and merges over a fresh copy of it.
--
-- This runs the same check for every feature in the registry that has both upvalues
-- (`_cfg`, `DEFAULTS`) behind its `setup`: call `setup` with one option changed, call it
-- again without, and compare `_cfg` with `DEFAULTS`. A module that keeps its options in
-- another shape is counted and listed, not skipped silently.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/feature_setup_fresh_spec.lua

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)

local function prepend_first(envs, sibling, lazy_name, marker)
  local candidates = {}
  for _, env in ipairs(envs) do
    local v = vim.env[env]
    if v and v ~= "" then candidates[#candidates + 1] = v end
  end
  candidates[#candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/" .. sibling
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/" .. lazy_name
  for _, candidate in ipairs(candidates) do
    if vim.fn.isdirectory(candidate .. marker) == 1 then
      vim.opt.rtp:prepend(candidate)
      return
    end
  end
end
prepend_first({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }, "lib.nvim", "lib.nvim", "/lua/lib")
prepend_first({ "FILETREE_UI_NVIM", "UI_NVIM_PATH" }, "ui.nvim", "ui.nvim", "/lua/ui")

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

local registry = require("filetree.features")

---An upvalue of `fn` by name.
---@param fn function
---@param name string
---@return any value, boolean found
local function upvalue(fn, name)
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if n == nil then return nil, false end
    if n == name then return v, true end
  end
  return nil, false
end

---A stand-in adapter: every method answers "nothing".
local stub = setmetatable({
  name = "fresh-stub",
  is_available = function()
    return true
  end,
}, {
  __index = function()
    return function()
      return false
    end
  end,
})

---The first option of `defaults` (sorted) whose value is a plain scalar, and a value that differs.
---@param defaults table
---@return string? key, any changed
local function pick(defaults)
  local keys = vim.tbl_keys(defaults)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local v = defaults[key]
    if key ~= "enabled" then
      if type(v) == "boolean" then return key, not v end
      if type(v) == "number" then return key, v + 1 end
      if type(v) == "string" then return key, v .. "-changed" end
    end
  end
  return nil, nil
end

local names = vim.tbl_keys(registry.FEATURES)
table.sort(names)

-- The modules that were merging onto their previous `_cfg`. A module that loses its `DEFAULTS`
-- (or goes back to merging onto `_cfg`) drops out of the loop below, so it is named here:
-- leaving the loop is a failure for these.
local MUST_BE_EXERCISED = {
  "auto_resize",
  "auto_reveal",
  "breadcrumbs",
  "cheatsheet",
  "compress",
  "context_menu",
  "copy_move",
  "create_from_template",
  "diff",
  "file_watcher",
  "filter",
  "find_files",
  "git_status",
  "grep_in_dir",
  "link_create",
  "link_marker",
  "live_search",
  "lua_require_copy",
  "spotlight_node",
  "sort_cycle",
  "markdown_links",
  "marks",
  "move",
  "open_replace",
  "open_variants",
  "open_with",
  "path_copy",
  "pdf_create",
  "pdf_open",
  "project_root",
  "rename_batch",
  "session",
  "size_info",
  "smart_create",
  "smart_rename",
  "trash",
  "tree_integrity",
  "watcher_quarantine",
  "window_size_cycler",
  "window_style",
}

local exercised, not_applicable = 0, {}
local exercised_names = {}
for _, name in ipairs(names) do
  local info = registry.FEATURES[name]
  local ok_mod, mod = pcall(require, info.mod)
  if not ok_mod or type(mod) ~= "table" or type(mod.setup) ~= "function" then
    not_applicable[#not_applicable + 1] = name .. " (no setup)"
  else
    local defaults, has_defaults = upvalue(mod.setup, "DEFAULTS")
    local _, has_cfg = upvalue(mod.setup, "_cfg")
    local key, changed
    if has_defaults and has_cfg and type(defaults) == "table" then
      key, changed = pick(defaults)
    end
    if not key then
      not_applicable[#not_applicable + 1] = name
        .. (
          has_defaults and has_cfg and " (no scalar option)"
          or " (options not kept as _cfg/DEFAULTS)"
        )
    else
      exercised = exercised + 1
      exercised_names[name] = true
      local function cfg()
        return (upvalue(mod.setup, "_cfg"))
      end

      pcall(mod.setup, { enabled = true, [key] = changed }, stub)
      check(
        name .. ": setup() applies " .. key,
        cfg() and cfg()[key] == changed,
        vim.inspect(cfg() and cfg()[key])
      )

      pcall(mod.setup, { enabled = true }, stub)
      check(
        name .. ": a later setup() without " .. key .. " is back at the default",
        cfg() and cfg()[key] == defaults[key],
        vim.inspect(cfg() and cfg()[key])
      )

      -- No other option moved either, `enabled` aside (a feature may switch itself off when its
      -- platform lacks something).
      local differs = {}
      for k, v in pairs(defaults) do
        if k ~= "enabled" and not vim.deep_equal(cfg() and cfg()[k], v) then
          differs[#differs + 1] = k
        end
      end
      table.sort(differs)
      check(
        name .. ": nothing else differs from DEFAULTS",
        #differs == 0,
        table.concat(differs, ", ")
      )

      -- Writing into the live options never reaches DEFAULTS.
      local before = vim.deepcopy(defaults)
      if cfg() then cfg()[key] = changed end
      check(name .. ": DEFAULTS is a separate table", vim.deep_equal(defaults, before))
      pcall(mod.setup, { enabled = true }, stub)
    end
  end
end

print(
  ("\n%d feature(s) exercised, %d not applicable: %s"):format(
    exercised,
    #not_applicable,
    table.concat(not_applicable, ", ")
  )
)
check("most of the registry is exercised", exercised >= 30, tostring(exercised))
for _, name in ipairs(MUST_BE_EXERCISED) do
  check(
    name .. ": keeps its options as _cfg over a DEFAULTS literal",
    exercised_names[name] == true
  )
end

print(("\nfiletree.nvim feature_setup_fresh: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
