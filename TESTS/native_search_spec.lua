-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields
-- TESTS/native_search_spec.lua -- search on the own tree: the hits are laid over the tree and reach
-- folders it never opened; the tree underneath is never touched, so clearing shows it exactly as it
-- was, however early the search is cleared; a replaced or cleared search never reaches the screen;
-- every tier lists the same files; the filter feature drives it.
--
--   nvim --clean --headless -u NONE -l TESTS/native_search_spec.lua

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

-- No `vim.o.columns` / `vim.o.lines` in this file: a headless run has no UI, its screen grid stays
-- 80x24 whatever the options say, and the next forced redraw writes past it.

-- Results go to stdout directly: print() in a headless run goes through the message area.
local function say(text)
  io.stdout:write(text, "\n")
end

local passed, failed = 0, 0
local function eq(name, got, want)
  if vim.deep_equal(got, want) then
    passed = passed + 1
    say("  ok   " .. name)
  else
    failed = failed + 1
    say(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
  end
end
local function ok(name, cond)
  eq(name, cond and true or false, true)
end

vim.g.have_nerd_font = false

local list = require("filetree.native.fs.list")
local deep = require("filetree.native.fs.deep")
local native = require("filetree.native")
local filetree = require("filetree")
require("filetree.config").setup({})
local adapter = require("filetree.adapter.native")

-- ── fixture ────────────────────────────────────────────────────────────────────
local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
local dir = ("%s/ft_search_%d"):format(base, vim.uv.hrtime() % 1e9)
local function mkfile(rel)
  local path = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "x" }, path)
end
for _, rel in ipairs({
  "src/alpha.lua",
  "src/beta.lua",
  "src/deep/nested/needle_one.lua",
  "src/deep/other.txt",
  "docs/Needle_Two.md",
  "docs/guide.md",
  "far/away/down/needle_three.lua",
  ".git/needle_in_git",
  "top.lua",
}) do
  mkfile(rel)
end

local function lines()
  return vim.api.nvim_buf_get_lines(adapter.get_bufnr(), 0, -1, false)
end
local function names()
  local out = {}
  for _, node in ipairs(adapter.get_visible_nodes("files")) do
    out[#out + 1] = node.path:sub(#dir + 2)
  end
  table.sort(out)
  return out
end
local function settle(ms)
  vim.wait(ms or 150, function()
    return false
  end)
end
---Wait until the search in force has listed every file.
local function finished(view)
  vim.wait(8000, function()
    local s = view:searching()
    return s == nil or s.done
  end, 20)
  local s = view:searching()
  return s == nil or s.done
end

-- ── every tier lists the same files ────────────────────────────────────────────
local function listing(tier)
  local found, done = {}, nil
  deep.files(dir, function(batch)
    vim.list_extend(found, batch)
  end, function(success)
    done = success
  end, { tier = tier })
  vim.wait(8000, function()
    return done ~= nil
  end, 20)
  local out = {}
  for _, path in ipairs(found) do
    out[#out + 1] = path:sub(#dir + 2)
  end
  table.sort(out)
  return out, done
end
local by_walk, walk_ok = listing("lua")
eq("the walk finds every file and stays out of .git", by_walk, {
  "docs/Needle_Two.md",
  "docs/guide.md",
  "far/away/down/needle_three.lua",
  "src/alpha.lua",
  "src/beta.lua",
  "src/deep/nested/needle_one.lua",
  "src/deep/other.txt",
  "top.lua",
})
eq("the walk reports success", walk_ok, true)
local tier = deep.tier()
say("  info this machine lists files with: " .. tier)
for _, tool in ipairs({ "fd", "rg" }) do
  if vim.fn.executable(tool) == 1 then
    eq(tool .. " lists the same files as the walk", (listing(tool)), by_walk)
  else
    say("  n/a  " .. tool .. " is not installed here")
  end
end

-- a cancelled listing calls nothing more
local calls = 0
local cancel = deep.files(dir, function()
  calls = calls + 1
end, function()
  calls = calls + 1
end, { tier = "lua" })
cancel()
settle(400)
eq("a cancelled listing calls neither on_batch nor on_done", calls, 0)

-- ── the hits are laid over the tree ────────────────────────────────────────────
adapter.toggle_at("left", { dir = dir })
adapter.expand_node({ path = dir .. "/src" })
adapter.scroll_to_line(adapter.get_node_line(dir .. "/src/beta.lua"))
local view = adapter.get_state()
local before = lines()
eq("no search to begin with", view:searching(), nil)

ok("search answers true", view:search("needle"))
eq("hits from what the tree had read show at once", #names(), 0) -- none of the needles was read yet
ok("the listing finishes", finished(view))
eq("hits come from folders the tree never opened, in both cases", names(), {
  "docs/Needle_Two.md",
  "far/away/down/needle_three.lua",
  "src/deep/nested/needle_one.lua",
})
eq("the hits stand in their folders, all of them open", vim.list_slice(lines(), 2), {
  "  ▾ docs/",
  "      Needle_Two.md",
  "  ▾ far/",
  "    ▾ away/",
  "      ▾ down/",
  "          needle_three.lua",
  "  ▾ src/",
  "    ▾ deep/",
  "      ▾ nested/",
  "          needle_one.lua",
})
ok(
  "the root line names the search and the count: " .. lines()[1],
  lines()[1]:find("/needle  3", 1, true) ~= nil
)
eq("the cursor is on the first hit", adapter.get_current_node().name, "Needle_Two.md")
eq(
  "a hit is a node like any other",
  adapter.get_node_line(dir .. "/src/deep/nested/needle_one.lua") ~= nil,
  true
)
eq("searching() says what runs", view:searching(), { query = "needle", hits = 3, done = true })

-- ── an upper-case letter makes the search exact; several words all have to occur ─
view:search("Needle")
finished(view)
eq("smart case: Needle finds only the capitalised one", names(), { "docs/Needle_Two.md" })
view:search("src lua")
finished(view)
eq("two words: both have to occur in the path", names(), {
  "src/alpha.lua",
  "src/beta.lua",
  "src/deep/nested/needle_one.lua",
})
view:search("no_such_thing")
finished(view)
eq("no hit: only the root line", #lines(), 1)

-- ── clearing shows the tree as it was ──────────────────────────────────────────
ok("clear_search answers true", view:clear_search())
eq("the tree is back, line for line", lines(), before)
eq("the cursor is back on its node", adapter.get_current_node().name, "beta.lua")
eq("the folder that was open still is", adapter.get_expanded_paths(), { dir .. "/src" })
eq("clear without a search answers false", view:clear_search(), false)
eq(
  "an empty query clears",
  { view:search("needle"), view:search("   "), view:searching() },
  { true, false }
)

-- ── cleared right after it started, twenty times ───────────────────────────────
local broken = {}
for i = 1, 20 do
  view:search("needle")
  view:clear_search()
  if not vim.deep_equal(lines(), before) then broken[#broken + 1] = i end
end
eq("cleared at once, 20 of 20: the tree is identical every time", broken, {})
settle(800)
eq("... and no late answer drew over it", lines(), before)
eq(
  "... the open folder and the cursor untouched",
  { adapter.get_expanded_paths(), adapter.get_current_node().name },
  { { dir .. "/src" }, "beta.lua" }
)

-- ── a search replaced while it runs: only the last one reaches the screen ──────
view:search("alpha")
view:search("beta")
view:search("guide")
finished(view)
settle(200)
eq("three searches in a row: the hits are the last one's", names(), { "docs/guide.md" })
view:clear_search()

-- ── the tree underneath keeps living ───────────────────────────────────────────
view:search("needle")
finished(view)
mkfile("src/added_meanwhile.lua")
settle(1200)
eq("a change on disk does not draw into the hits", names(), {
  "docs/Needle_Two.md",
  "far/away/down/needle_three.lua",
  "src/deep/nested/needle_one.lua",
})
view:clear_search()
vim.wait(4000, function()
  return adapter.get_node_line(dir .. "/src/added_meanwhile.lua") ~= nil
end, 25)
ok(
  "... and is in the tree once the search is cleared",
  adapter.get_node_line(dir .. "/src/added_meanwhile.lua") ~= nil
)

-- ── a file the tree had read and that is gone since is no hit ──────────────────
ok("alpha.lua is a row of the tree", adapter.get_node_line(dir .. "/src/alpha.lua") ~= nil)
vim.fn.delete(dir .. "/src/alpha.lua")
vim.wait(4000, function()
  return adapter.get_node_line(dir .. "/src/alpha.lua") == nil
end, 25)
view:search("alpha")
eq("a deleted file the tree had read is no hit, not even at once", names(), {})
finished(view)
eq("... nor once the listing is done", names(), {})
view:clear_search()

-- ── more hits than are shown ───────────────────────────────────────────────────
view._opts.search_max = 2
view:search("lua")
finished(view)
ok(
  "a capped search says how many more there are: " .. lines()[#lines()],
  lines()[#lines()]:find("more hits") ~= nil
)
eq("... and shows as many as the limit", #adapter.get_visible_nodes("files"), 2)
ok("... counts every hit: " .. view:searching().hits, view:searching().hits > 2)
eq("... but keeps only the ones it shows", #view._search.hits, 2)
view._opts.search_max = nil
view:clear_search()

-- ── another root ends the search ───────────────────────────────────────────────
view:search("needle")
adapter.set_root(dir .. "/src")
eq("set_root ends a search", view:searching(), nil)
eq("... and shows the new root", lines()[1], "▾ src/")
adapter.set_root(dir)

-- ── the filter feature drives it ───────────────────────────────────────────────
native.reset()
filetree.setup({
  adapter = "native",
  deps_popup = false,
  features = { session = { enabled = false }, auto_reveal = { enabled = false } },
})
adapter = filetree.adapter()
adapter.toggle_at("left", { dir = dir })
local filter = filetree.feature("filter")
local plain = lines()
filter.apply("needle")
view = adapter.get_state()
ok(
  "filter.apply starts a search on the own tree",
  view:searching() ~= nil and view:searching().query == "needle"
)
finished(view)
eq("... with hits from folders that were never opened", #names(), 3)
filter.clear()
eq("filter.clear shows the tree as it was", { view:searching(), lines() }, { nil, plain })

native.reset()
vim.fn.delete(dir, "rf")

say(("\nfiletree.nvim native_search_spec: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
