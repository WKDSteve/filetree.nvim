---@module 'filetree.native.ai.plan'
---@brief The answer of the model as a plan of tree actions: read it, and check every field of it.
---@description
--- The answer of a model is untrusted input. Nothing in it is run, opened or loaded as code: this module
--- only reads JSON out of the text and checks each step against the catalog of the view (the actions the
--- tree has) and the paths the tree knows. What does not fit is refused with one line saying why.
---
--- Pure: no window, no buffer, no file access. What it needs to know about the tree comes in `env`.
---
--- Key responsibilities:
--- - `read(text)`: the steps of the answer (`[{ action, target, args }]`), or why there are none
--- - `check(steps, env)`: every step resolved to a catalog entry, a known path (or several, when a
---   name is ambiguous) and checked arguments; or the one line that refuses the whole plan
--- - `target(raw, env)`: one target, as the plan names it, to a path below the root

local M = {}

--- Steps a plan may have at most. The tree runs a short plan the person asked for, not an agent.
M.MAX_STEPS = 5
--- Characters an argument value may have at most.
M.MAX_ARG = 200
--- Characters a target may have at most.
M.MAX_TARGET = 1024
--- Candidates a fuzzy name may resolve to at most (the rest are not offered).
M.MAX_CANDIDATES = 20

---@class Filetree.Ai.Step
---@field action string  The catalog name.
---@field item Filetree.Ai.Item  The catalog entry.
---@field target? string  The resolved path (absolute, normalized); nil: the selection or the cursor.
---@field candidates? string[]  Several paths fit the name: one has to be picked.
---@field raw_target? string  The target as the plan wrote it.
---@field args? table<string, string>

---@class Filetree.Ai.Env
---@field root string  The root of the view (normalized).
---@field catalog table<string, Filetree.Ai.Item>  By name.
---@field known table<string, boolean>  Every path the tree knows (normalized, absolute) -> is a folder.
---@field order? string[]  The known paths in the order they are offered on several hits.
---@field check fun(item: Filetree.Ai.Item, path: string|nil): boolean, string|nil  Whether the action applies to the path (nil: the cursor).

---A path in one spelling: `/`-separated, drive letter upper case, no trailing slash.
---@param path string
---@return string
local function norm(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^(%a):", function(drive)
    return drive:upper() .. ":"
  end)
  if #path > 1 and path:sub(-1) == "/" and not path:match("^%a:/$") then path = path:sub(1, -2) end
  return path
end

---@param root string
---@param path string
---@return boolean
local function inside(root, path)
  if path == root then return true end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return path:sub(1, #prefix) == prefix
end

---`path` relative to `root` ("" for the root itself).
---@param root string
---@param path string
---@return string
local function rel_of(root, path)
  if path == root then return "" end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return path:sub(#prefix + 1)
end
M.rel_of = rel_of

---`rel` below `root`.
---@param root string
---@param rel string
---@return string
local function join(root, rel)
  return norm((root:sub(-1) == "/" and root or (root .. "/")) .. rel)
end

---A string fit to be shown in one line of a message: control characters out, cut to `max`.
---@param text any
---@param max? integer
---@return string
function M.shown(text, max)
  local s = tostring(text):gsub("%c", " ")
  max = max or 60
  if vim.fn.strchars(s) > max then s = vim.fn.strcharpart(s, 0, max - 1) .. "…" end
  return s
end

---The JSON value in an answer: a fenced block, else the text from the first `[` or `{` to the last
---`]` or `}`.
---@param text string
---@return string|nil
local function json_of(text)
  local fenced = text:match("```[%w]*%s*\n(.-)\n%s*```")
  if fenced then return fenced end
  local first = text:find("[%[{]")
  if not first then return nil end
  local last = nil
  for i = #text, first, -1 do
    local c = text:sub(i, i)
    if c == "]" or c == "}" then
      last = i
      break
    end
  end
  if not last then return nil end
  return text:sub(first, last)
end

---The steps of an answer.
---@param text any  The text of the answer.
---@return table[]|nil steps  Raw: not checked yet.
---@return string|nil reason  Why there are none; "none: <why>" when the model said nothing fits.
function M.read(text)
  if type(text) ~= "string" or text == "" then return nil, "the answer is empty" end
  local json = json_of(text)
  if not json then return nil, "the answer has no plan in it" end
  local ok, value = pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
  if not ok or type(value) ~= "table" then return nil, "the answer is no plan (not JSON)" end
  if vim.islist(value) then return value, nil end
  -- an object: the plan under a key, one step on its own, or the model's "nothing fits"
  if type(value.none) == "string" then return nil, "none: " .. M.shown(value.none, 120) end
  if type(value.plan) == "table" and vim.islist(value.plan) then return value.plan, nil end
  if value.action ~= nil then return { value }, nil end
  return nil, "the answer is no plan (no list of steps)"
end

---One target, as the plan wrote it, to the paths it can mean.
---@param raw any
---@param env Filetree.Ai.Env
---@return string|nil path  The one known path it names; nil with `candidates` or `reason`.
---@return string[]|nil candidates  Several known paths fit the name.
---@return string|nil reason
function M.target(raw, env)
  if type(raw) ~= "string" then return nil, nil, "the target is not a path" end
  if #raw > M.MAX_TARGET then return nil, nil, "the target is too long" end
  if raw:find("%c") then return nil, nil, "the target has control characters in it" end
  local path = norm(vim.trim(raw))
  if path == "" then return nil, nil, "the target is empty" end
  -- a step up leaves the tree whatever comes before it; a home folder is not below the root either
  for part in path:gmatch("[^/]+") do
    if part == ".." then return nil, nil, ("%q goes above the root"):format(M.shown(raw)) end
  end
  if path:sub(1, 1) == "~" then
    return nil, nil, ("%q is not below the root"):format(M.shown(raw))
  end
  local absolute = path:sub(1, 1) == "/" or path:match("^%a:/") ~= nil or path:match("^%a:$") ~= nil
  -- what a name is compared with when the path is not known as written
  local name = (absolute and (path:match("([^/]+)$") or path) or path:gsub("^%./", "")):lower()
  if absolute then
    if not inside(env.root, path) then
      return nil, nil, ("%q is not below the root of the tree"):format(M.shown(raw))
    end
  else
    path = path:gsub("^%./", "")
    path = path == "." and env.root or join(env.root, path)
  end
  if env.known[path] ~= nil then return path, nil, nil end
  -- an absolute path names one file: another one of the same name is not what was meant
  if absolute then return nil, nil, ("%q is not an entry the tree knows"):format(M.shown(raw)) end
  -- not a path the tree knows: a name ("init.lua", "the init") among the known ones
  local hits = {}
  for _, known in ipairs(env.order or vim.tbl_keys(env.known)) do
    if known ~= env.root then
      local rel = rel_of(env.root, known):lower()
      local base = rel:match("([^/]+)$") or rel
      local stem = base:match("^(.+)%.[^.]+$") or base
      if rel == name or base == name or stem == name or rel:sub(-(#name + 1)) == "/" .. name then
        hits[#hits + 1] = known
      end
    end
  end
  if #hits == 1 then return hits[1], nil, nil end
  if #hits > 1 then
    table.sort(hits, function(a, b)
      if #a ~= #b then return #a < #b end
      return a < b
    end)
    return nil, vim.list_slice(hits, 1, M.MAX_CANDIDATES), nil
  end
  return nil, nil, ("%q is not an entry the tree knows"):format(M.shown(raw))
end

---Check the arguments of a step against what the action declares.
---@param raw any
---@param item Filetree.Ai.Item
---@return table<string, string>|nil args
---@return string|nil reason
local function check_args(raw, item)
  if raw == nil then return nil, nil end
  if type(raw) ~= "table" or (vim.islist(raw) and #raw > 0) then
    return nil, "its arguments are not a set of names and values"
  end
  if next(raw) == nil then return nil, nil end
  local spec = item.args or {}
  local out = {}
  for key, value in pairs(raw) do
    if type(key) ~= "string" or type(spec[key]) ~= "table" then
      if next(spec) == nil then return nil, ("%s takes no arguments"):format(item.name) end
      return nil, ("%s has no argument %q"):format(item.name, M.shown(key, 30))
    end
    if type(value) == "number" or type(value) == "boolean" then value = tostring(value) end
    if type(value) ~= "string" then
      return nil, ("argument %s of %s is not a value"):format(key, item.name)
    end
    if #value > M.MAX_ARG or value:find("%c") then
      return nil, ("argument %s of %s is no plain value"):format(key, item.name)
    end
    local values = spec[key].values
    if type(values) == "table" and not vim.tbl_contains(values, value) then
      return nil,
        ("argument %s of %s is one of %s, not %q"):format(
          key,
          item.name,
          table.concat(values, "/"),
          M.shown(value, 30)
        )
    end
    out[key] = value
  end
  return out, nil
end

---@param raw any
---@return boolean
local function no_target(raw)
  return raw == nil or raw == "" or raw == "selection" or raw == "cursor"
end

---Check every step of a plan. One step that does not fit refuses the whole plan: half a plan is
---not what the person asked for.
---@param steps any  What `read` returned.
---@param env Filetree.Ai.Env
---@return Filetree.Ai.Step[]|nil steps
---@return string|nil reason  One line.
function M.check(steps, env)
  if type(steps) ~= "table" or not vim.islist(steps) then return nil, "the plan is not a list" end
  if #steps == 0 then return nil, "the plan has no step" end
  if #steps > M.MAX_STEPS then
    return nil, ("the plan has %d steps, at most %d run at a time"):format(#steps, M.MAX_STEPS)
  end
  local out = {}
  local mutating = 0
  for i, raw in ipairs(steps) do
    local where = ("step %d: "):format(i)
    if type(raw) ~= "table" then return nil, where .. "not an action" end
    local name = raw.action
    if type(name) ~= "string" then return nil, where .. "names no action" end
    local item = env.catalog[name]
    if not item then
      return nil, where .. ("no action %q in this tree"):format(M.shown(name, 40))
    end
    local args, why = check_args(raw.args, item)
    if why then return nil, where .. why end
    ---@type Filetree.Ai.Step
    local step = { action = name, item = item, args = args }
    if no_target(raw.target) then
      local ok, reason = env.check(item, nil)
      if not ok then return nil, where .. name .. ": " .. (reason or "does not apply here") end
    else
      step.raw_target = raw.target
      local path, candidates, reason = M.target(raw.target, env)
      if reason then return nil, where .. reason end
      if path then
        local ok, not_ok = env.check(item, path)
        if not ok then return nil, where .. name .. ": " .. (not_ok or "does not apply here") end
        step.target = path
      else
        -- only the paths the action applies to are worth asking about
        local fit, first_reason = {}, nil
        for _, candidate in ipairs(candidates or {}) do
          local ok, reason2 = env.check(item, candidate)
          if ok then
            fit[#fit + 1] = candidate
          else
            first_reason = first_reason or reason2
          end
        end
        if #fit == 0 then
          return nil, where .. name .. ": " .. (first_reason or "does not apply here")
        end
        if #fit == 1 then
          step.target = fit[1]
        else
          step.candidates = fit
        end
      end
    end
    if item.mutates then
      mutating = mutating + 1
      -- the root is the tree itself: changing it is not asked for in a sentence
      if step.target == env.root then
        return nil, where .. name .. " on the root of the tree is not done this way"
      end
    end
    out[#out + 1] = step
  end
  -- A step that changes files runs alone: a step before it could move the cursor or the marks, so
  -- the question would name other entries than the ones it acts on; a step after it would run while
  -- its dialog is open.
  if mutating > 0 and #out > 1 then
    return nil, "a step that changes files is asked for on its own, not in a plan of several"
  end
  return out, nil
end

return M
