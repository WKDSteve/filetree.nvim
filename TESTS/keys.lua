---@diagnostic disable: need-check-nil
-- keys.lua — headless unit test for key conflicts: the shipped defaults are
-- conflict-free, a forced clash is found, recommended alternatives are really
-- free, and moving one of the two claims works (`filetree.util.key_conflicts`).
--
-- Usage (from the repo root):
--   nvim -n --clean --headless -u NONE -l TESTS/keys.lua
--
-- Exit code 0 = all checks passed; 1 = a check failed.

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
      return true
    end
  end
  return false
end
local has_lib =
  prepend_dep({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }, "lib.nvim", "lib.nvim", "/lua/lib")
local has_ui = prepend_dep({ "FILETREE_UI_NVIM", "UI_NVIM_PATH" }, "ui.nvim", "ui.nvim", "/lua/ui")
if not (has_lib and has_ui) then
  print("SKIP keys.lua: lib.nvim / ui.nvim not found")
  vim.cmd("qa!")
end

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

-- ── A stub tree adapter, every keymap-carrying feature switched on ─────────────

local stub = setmetatable({
  name = "neotree",
  filetypes = { "neo-tree" },
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

local ft = require("filetree")
ft.register_adapter(stub)
local bind = require("filetree.util.bind")
local kc = require("filetree.util.key_conflicts")

-- Every feature that binds keys. Opt-in ones included: a clash only one of a
-- pair's users would meet is still a clash.
local KEY_FEATURES = {
  "diff",
  "buffer_save",
  "copy_move",
  "create_from_template",
  "link_create",
  "move",
  "open_replace",
  "open_variants",
  "rename_batch",
  "smart_create",
  "smart_rename",
  "trash",
  "buffer_cycle",
  "cwd_mode",
  "reveal_alt",
  "source_switcher",
  "tree_toggle",
  "quickpick",
  "tree_traverse",
  "marks",
  "copy_file_list",
  "lua_require_copy",
  "spotlight_node",
  "sort_cycle",
  "markdown_links",
  "path_copy",
  "filter",
  "find_files",
  "grep_in_dir",
  "live_search",
  "open_in_fm",
  "open_with",
  "file_clipboard",
  "pdf_create",
  "compress",
  "pdf_open",
  "shell_run",
  "cheatsheet",
  "context_menu",
  "node_info",
  "preview",
  "tree_reset",
  "window_size_cycler",
  "collapse_all",
}

---@param overrides? table<string, table>  # Per-feature config on top of "enabled".
local function setup_all(overrides)
  local features = {}
  for _, name in ipairs(KEY_FEATURES) do
    features[name] = vim.tbl_deep_extend("force", { enabled = true }, (overrides or {})[name] or {})
  end
  features.no_name_guard = { enabled = false }
  features.file_watcher = { enabled = false }
  local ok, err = pcall(ft.setup, { adapter = "neotree", features = features })
  return ok, err
end

---A fresh tree buffer, attached the way a real one is (FileType), and current.
---@return integer
local function new_tree()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "neo-tree"
  vim.wait(300, function()
    return false
  end)
  return buf
end

local function live_desc(buf, lhs)
  local want = kc.canon(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if kc.canon_live(m) == want then return m.desc end
  end
  return nil
end

-- ── 1. The defaults: nothing claims a key twice ───────────────────────────────

local ok = setup_all()
check("setup() with every keymap feature on runs", ok)
local tree = new_tree()
local conflicts = kc.find(tree)
local names = {}
for _, c in ipairs(conflicts) do
  names[#names + 1] = c.lhs
end
check(
  "the shipped defaults claim no key twice",
  #conflicts == 0,
  "clashes on: " .. table.concat(names, ", ")
)

-- collapse_all's `W` on a tree buffer that already maps `W` itself (a neo-tree
-- `window.mappings` entry, set before filetree attaches): left alone, said once.
do
  check(
    "collapse_all binds W on a plain tree buffer",
    (live_desc(tree, "W") or ""):find("^filetree") ~= nil,
    live_desc(tree, "W")
  )

  local saved_notify, told = vim.notify, {}
  vim.notify = function(msg)
    told[#told + 1] = tostring(msg)
  end
  local own = vim.api.nvim_create_buf(false, true)
  vim.keymap.set("n", "W", function() end, { buffer = own, desc = "open_with_window_picker" })
  vim.api.nvim_set_current_buf(own)
  vim.bo[own].filetype = "neo-tree"
  vim.wait(300, function()
    return false
  end)
  vim.notify = saved_notify
  check(
    "a W the tree buffer already maps stays the user's",
    live_desc(own, "W") == "open_with_window_picker",
    live_desc(own, "W")
  )
  check(
    "...and collapse_all says why it is not on W",
    table.concat(told, "\n"):find("W is already mapped in the tree", 1, true) ~= nil,
    table.concat(told, " | ")
  )
end

-- Every action reads its key from a config field the schema declares, or a
-- moved key could not be told to the user as a `setup()` fragment.
do
  local missing, seen_actions = {}, 0
  for surface, entries in pairs(require("lib.nvim.bindings.keymap").registered()) do
    local feature = surface:match("^filetree/([^/]+)")
    if feature then
      for _, e in ipairs(entries) do
        local field = bind.field_of(feature, e.name)
        if field and field:sub(1, 1) ~= "_" then
          seen_actions = seen_actions + 1
          if not kc.config_path(feature, field) then
            missing[#missing + 1] = feature .. "." .. field
          end
        end
      end
    end
  end
  check("actions were seen", seen_actions > 30, tostring(seen_actions))
  table.sort(missing)
  check(
    "every action's key field is declared in its feature's SCHEMA",
    #missing == 0,
    table.concat(missing, ", ")
  )
end

check(
  "config_path resolves a nested field",
  kc.config_path("copy_move", "clear") == "keymaps.clear",
  tostring(kc.config_path("copy_move", "clear"))
)
check(
  "config_path resolves a flat field",
  kc.config_path("pdf_open", "keymap_open") == "keymap_open"
)

-- ── 1b. file_clipboard: the key and the command really reach the feature ─────
-- Section 1 proves no key is claimed twice; it does not prove `gy` is bound to
-- the feature, nor that `:Filetree clipfiles` calls it. The backend is stubbed,
-- so nothing touches the real clipboard.
do
  local fcb = require("filetree.features.system.file_clipboard.backend")
  local real_copy = fcb.copy
  local sent
  fcb.copy = function(paths, on_done)
    sent = vim.deepcopy(paths)
    on_done(true, nil, #paths)
  end
  local node_path = vim.fn.fnamemodify(this, ":p")
  stub.get_current_node = function()
    return { path = node_path }
  end
  local real_notify = vim.notify
  vim.notify = function() end

  local cb
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(tree, "n")) do
    if kc.canon_live(m) == kc.canon("gy") then cb = m.callback end
  end
  check("file_clipboard: `gy` is bound on a tree buffer", cb ~= nil)
  if cb then
    sent = nil
    cb()
    check("file_clipboard: `gy` copies the node under the cursor", sent and sent[1] == node_path)
  end

  sent = nil
  vim.cmd("Filetree clipfiles")
  check("file_clipboard: `:Filetree clipfiles` copies the node", sent and sent[1] == node_path)

  local cat_lhs
  for _, entries in pairs(require("filetree.bindings.keymaps")) do
    for _, e in ipairs(entries) do
      if e.feature == "file_clipboard" then cat_lhs = e.lhs end
    end
  end
  check("file_clipboard: the binding catalog lists `gy`", cat_lhs == "gy", tostring(cat_lhs))

  vim.notify = real_notify
  fcb.copy = real_copy
  stub.get_current_node = nil
end

-- ── 2. A forced clash is found ────────────────────────────────────────────────

-- The old defaults: both on <C-c>.
setup_all({ copy_move = { keymaps = { clear = "<C-c>" } }, filter = { keymap_clear = "<C-c>" } })
tree = new_tree()
conflicts = kc.find(tree)
check(
  "a forced clash is found",
  #conflicts == 1 and conflicts[1].lhs == "<C-c>",
  vim.inspect(#conflicts)
)
local clash = conflicts[1]
local features_in = {}
for _, c in ipairs(clash.claims) do
  features_in[c.feature] = c
end
check("both claimants are named", features_in.copy_move and features_in.filter)
check("the live owner is identified (Ctrl keys report a tagged lhsraw)", clash.active ~= nil)
check(
  "the owner is the claim the buffer's map belongs to",
  clash.active and live_desc(tree, "<C-c>") == clash.active.desc,
  live_desc(tree, "<C-c>")
)

-- ── 3. Alternatives are really free ───────────────────────────────────────────

local moved = features_in.copy_move
local options = kc.suggest(tree, moved, 12)
check("suggest() answers", #options > 0)
local used = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(tree, "n")) do
  used[kc.canon_live(m)] = true
end
local clash_free = true
for _, k in ipairs(options) do
  if used[kc.canon(k)] then clash_free = false end
end
check("no suggestion is a key already mapped on the buffer", clash_free, table.concat(options, " "))
check(
  "the original key is never suggested back",
  not vim.tbl_contains(options, "<C-c>"),
  table.concat(options, " ")
)
-- Prefix ambiguity: a bare `g` map would swallow (or be swallowed by) every g-key.
vim.keymap.set("n", "g", function() end, { buffer = tree })
local after = kc.suggest(tree, moved, 40)
local g_left = false
for _, k in ipairs(after) do
  if k:sub(1, 1) == "g" then g_left = true end
end
check(
  "a mapped prefix rules out every key that starts with it",
  not g_left,
  table.concat(after, " ")
)
vim.keymap.del("n", "g", { buffer = tree })

local lock = {
  feature = "cwd_mode",
  action = "lock_here",
  desc = "filetree: lock cwd here",
  lhs = "gp",
  mode = "n",
}
local for_lock = kc.suggest(tree, lock, 6)
check(
  "a g-key stays in the g family first (gp -> gL / gl)",
  vim.tbl_contains(for_lock, "gL") or vim.tbl_contains(for_lock, "gl"),
  table.concat(for_lock, " ")
)
local for_ctrl = kc.suggest(
  tree,
  { feature = "x", action = "y", desc = "filetree: do", lhs = "<C-q>", mode = "n" },
  3
)
check(
  "a ctrl key stays a ctrl key first",
  for_ctrl[1] and for_ctrl[1]:match("^<C%-") ~= nil,
  table.concat(for_ctrl, " ")
)

-- ── 4. Moving a claim ─────────────────────────────────────────────────────────

local other
for _, c in ipairs(clash.claims) do
  if c ~= moved then other = c end
end
local pre_owner = clash.active
local target = "gX"
local applied, err = kc.apply(clash, moved, target)
check("apply() reports success", applied == true, tostring(err))
check(
  "the moved action is bound at its new key",
  live_desc(tree, target) == moved.desc,
  tostring(live_desc(tree, target))
)
check(
  "the other action keeps the old key",
  live_desc(tree, "<C-c>") == other.desc,
  tostring(live_desc(tree, "<C-c>"))
)
check("the clash is gone", #kc.find(tree) == 0)
check("the previous owner is either side, never lost", pre_owner ~= nil)

-- A tree buffer opened afterwards binds the override, not the old key.
local later = new_tree()
check(
  "a later tree binds the moved action at the new key",
  live_desc(later, target) == moved.desc,
  tostring(live_desc(later, target))
)
check(
  "a later tree leaves the old key to the other action",
  live_desc(later, "<C-c>") == other.desc
)

-- The `setup()` fragment that makes it permanent.
check(
  "snippet: a nested field",
  kc.snippet(moved, target)
    == 'require("filetree").setup({ features = { copy_move = { keymaps = { clear = "gX" } } } })',
  kc.snippet(moved, target)
)
check(
  "snippet: a flat field",
  kc.snippet({ feature = "pdf_open", action = "open", desc = "d", lhs = "gp", mode = "n" }, "go")
    == 'require("filetree").setup({ features = { pdf_open = { keymap_open = "go" } } })'
)

-- Refusals.
local same_ok = kc.apply(clash, moved, clash.lhs)
check("apply() refuses the key it already has", same_ok == false)
local empty_ok = kc.apply(clash, moved, "")
check("apply() refuses an empty key", empty_ok == false)
local unknown_ok = kc.apply(
  clash,
  { feature = "nope", action = "nope", desc = "x", lhs = "<C-c>", mode = "n" },
  "gY"
)
check("apply() refuses an unknown action", unknown_ok == false)

-- ── 5. The cheatsheet shows it, and <CR> there starts the flow ─────────────────

setup_all({ copy_move = { keymaps = { clear = "<C-c>" } }, filter = { keymap_clear = "<C-c>" } })
tree = new_tree()
local cheatsheet = require("filetree.features.ui.cheatsheet")
cheatsheet.show()
local sheet = vim.api.nvim_get_current_buf()
local function body()
  return table.concat(vim.api.nvim_buf_get_lines(sheet, 0, -1, false), "\n")
end
check("a conflicts page exists", body():find("4 conflicts", 1, true) ~= nil, body())
check("page 1 flags the claimed key", body():find("also wanted by", 1, true) ~= nil, body())
vim.api.nvim_feedkeys("4", "x", false)
check(
  "page 4 names the key and both features",
  body():find("<C-c>", 1, true)
    and body():find("copy_move", 1, true)
    and body():find("filter", 1, true),
  body()
)
check("page 4 marks the live action", body():find("%* [%w_]+: ") ~= nil, body():gsub("\n", " | "))
check("page 4 recommends alternatives", body():find("move to: %S+") ~= nil, body())
check("page 4's footer offers <CR>", body():find("<CR> move a key", 1, true) ~= nil, body())

-- <CR> closes the sheet and starts `resolve`, which asks through `select`. The
-- chooser is stubbed to take the first option at every step.
local asked = {}
package.loaded["filetree.util.select"] = function(items, opts, on_choice)
  asked[#asked + 1] = opts.prompt
  on_choice(items[1], 1)
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
vim.wait(300, function()
  return #kc.find(tree) == 0
end)
check("<CR> on page 4 resolves the clash", #kc.find(tree) == 0, "asked: " .. vim.inspect(asked))
check("the flow asked which action to move, then where to", #asked == 2, vim.inspect(asked))
check("the sheet closed", vim.api.nvim_get_current_buf() == tree)
package.loaded["filetree.util.select"] = nil

-- Nothing to resolve: said so, asked nothing.
local quiet = {}
package.loaded["filetree.util.select"] = function(items, opts, on_choice)
  quiet[#quiet + 1] = opts.prompt
  on_choice(nil)
end
kc.resolve(tree)
check("resolve() with nothing claimed twice asks nothing", #quiet == 0, vim.inspect(quiet))
package.loaded["filetree.util.select"] = nil

-- ── 6. Guards: a taken key, a per-buffer feature, a buffer that is not the tree ──

setup_all({ copy_move = { keymaps = { clear = "<C-c>" } }, filter = { keymap_clear = "<C-c>" } })
tree = new_tree()
local guarded = kc.find(tree)
check("(guards) the forced clash is back", #guarded == 1, tostring(#guarded))
local gc = guarded[1]
check("find() records the tree buffer the owner was found on", gc.buf == tree, tostring(gc.buf))

local mover
for _, c in ipairs(gc.claims) do
  if c.feature == "copy_move" then mover = c end
end

-- A key that is already mapped is refused, and nothing is left half-done.
vim.keymap.set("n", "gW", function() end, { buffer = tree, desc = "someone's key" })
local taken_ok, taken_err = kc.apply(gc, mover, "gW")
check(
  "apply() refuses a key already in use",
  taken_ok == false and (taken_err or ""):find("in use") ~= nil,
  tostring(taken_err)
)
check("a refused move leaves the clash in place", #kc.find(tree) == 1)
tree = new_tree()
check(
  "a refused move: later trees still bind the old key",
  live_desc(tree, "<C-c>") ~= nil and live_desc(tree, "gW") == nil,
  tostring(live_desc(tree, "gW"))
)
check("is_free() says no for a mapped key", kc.is_free(tree, "n", "<C-c>") == false)
check("is_free() says yes for an unmapped one", kc.is_free(tree, "n", "gY") == true)

-- `preview` is declared per buffer: it cannot be moved or rebound while running.
check("can_rebind: an ordinary feature", bind.can_rebind("copy_move") == true)
check("can_rebind: a per-buffer feature is not", bind.can_rebind("preview") == false)
check("override() refuses a per-buffer feature", bind.override("preview", "open", "gZ") == false)
check("rebind() refuses a per-buffer feature", bind.rebind("preview", tree) == false)
local pv_claim =
  { feature = "preview", action = "open", desc = "filetree: x", lhs = "<C-c>", mode = "n" }
local pv_ok, pv_err =
  kc.apply({ mode = "n", lhs = "<C-c>", claims = { pv_claim, mover }, buf = tree }, pv_claim, "gV")
check(
  "apply() refuses a claimant bound per buffer, and says why",
  pv_ok == false and (pv_err or ""):find("per buffer") ~= nil,
  tostring(pv_err)
)
check("...before touching anything", live_desc(tree, "gV") == nil)
check("label() flags it up front", kc.label(pv_claim, nil):find("set in setup()", 1, true) ~= nil)
check("label() leaves an ordinary one alone", kc.label(mover, nil):find("setup()", 1, true) == nil)

-- Resolving from a window that is not the tree: the free keys are asked of the
-- tree buffer the owner was found on, not of the buffer that happens to be current.
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
package.loaded["filetree.util.select"] = function(items, _, on_choice)
  on_choice(items[1], 1)
end
kc.resolve()
vim.wait(200)
vim.api.nvim_set_current_buf(tree)
check("resolve() works from a buffer that is not the tree", #kc.find(tree) == 0)
package.loaded["filetree.util.select"] = nil

-- "other key...": a hand-typed key goes through the same guard.
setup_all({ copy_move = { keymaps = { clear = "<C-c>" } }, filter = { keymap_clear = "<C-c>" } })
tree = new_tree()
vim.keymap.set("n", "gW", function() end, { buffer = tree, desc = "someone's key" })
local kit = require("ui.kit")
local real_input = kit.input
local typed
kit.input = function(o)
  o.on_submit(typed)
end
local last_choice = function(items, _, on_choice)
  on_choice(items[#items], #items)
end
package.loaded["filetree.util.select"] = function(items, opts, on_choice)
  if opts.prompt:find("to:", 1, true) then
    last_choice(items, opts, on_choice) -- "other key..."
  else
    on_choice(items[1], 1)
  end
end
typed = "gW" -- taken
kc.resolve(tree)
vim.wait(200)
check("a typed key that is taken is refused", #kc.find(tree) == 1)
typed = "gU" -- free
kc.resolve(tree)
vim.wait(200)
check("a typed key that is free moves the action", #kc.find(tree) == 0)
kit.input = real_input
package.loaded["filetree.util.select"] = nil

print(string.format("\nkeys.lua: %d passed, %d failed", passed, failed))
vim.cmd(failed == 0 and "qa!" or "cq!")
