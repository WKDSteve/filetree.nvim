-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_watch_fallback_spec.lua -- the watch of the helper process covers everything below a
-- root; when the helper ends, a handle of libuv takes its place that sees the root alone. The folders
-- a tree has read below it are watched one by one again at once, not when they are next read.
--
-- The helper is a stand-in here (no program is started): it takes a watch and can be told to end.
-- The system is told to have no recursive handles, which is where the helper watches at all.
--
--   nvim --clean --headless -u NONE -l TESTS/native_watch_fallback_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

---@type table<integer, { dir: string, handler: fun(kind: string, payload: any): boolean? }>
local helper_watches = {}
local next_gen = 0
local helper_alive = true
local stand_in = setmetatable({
  available = function()
    return helper_alive
  end,
  request = function(method, arg, handler)
    -- a listing, a size: not taken, the Lua tiers answer
    if method ~= "watch" then return nil end
    next_gen = next_gen + 1
    helper_watches[next_gen] = { dir = arg, handler = handler }
    return next_gen
  end,
  drop = function(gen)
    helper_watches[gen] = nil
  end,
  state = function()
    return {}
  end,
}, {
  __index = function()
    return function() end
  end,
})

local T = dofile(here .. "/native_drive.lua")({
  name = "native_watch_fallback_spec",
  setup = { native = { watch = true } },
  files = { "a/one/x.lua", "a/two/y.lua", "b/z.lua", "README.md" },
  before_setup = function()
    package.loaded["filetree.native.fs.helper"] = stand_in
    require("filetree.native.fs.watch").native_recursive = false
  end,
})
local eq, ok, dir = T.eq, T.ok, T.dir
local adapter = T.adapter
local watch = require("filetree.native.fs.watch")
T.tree()

---@return table<string, boolean>  watched folder (relative to the project, "." for the root) -> by the helper
local function watched()
  local out = {}
  for _, entry in ipairs(watch.state().watchers) do
    local rel = entry.dir == dir and "." or entry.dir:sub(#dir + 2)
    out[rel] = entry.helper == true
  end
  return out
end

eq("(the helper watches here)", watch.state().by_helper, true)
adapter.expand_node({ path = dir .. "/a" })
adapter.expand_node({ path = dir .. "/a/one" })
T.settle(100)
ok("(the folders are read)", T.shown("a/one/x.lua"))
eq("with the helper: one watch, on the root, for everything below", watched(), { ["."] = true })

-- the helper ends: it is not there for the rest of the session, and its watches are told
helper_alive = false
local lost = 0
for gen, entry in pairs(helper_watches) do
  helper_watches[gen] = nil
  entry.handler("lost")
  lost = lost + 1
end
eq("(its one watch is told)", lost, 1)
T.settle(50)
eq(
  "the helper ended: the root and the folders that were read are watched one by one",
  watched(),
  { ["."] = false, ["a"] = false, ["a/one"] = false }
)

-- ... and a change in one of them reaches the tree without anybody reading it first
T.mkfile("a/one/new.lua")
ok(
  "a file made in a folder read before the helper ended shows",
  T.wait(function()
    return T.shown("a/one/new.lua")
  end, 4000)
)
-- a folder opened from now on is watched as on a system without the helper
adapter.expand_node({ path = dir .. "/b" })
T.settle(100)
eq("a folder read afterwards gets its handle when it is read", watched()["b"], false)

adapter.close()
T.settle(50)
eq("the tree closed: no handle is left", watched(), {})
eq("nothing at warning level in the whole run", T.loud(), {})
T.finish()
