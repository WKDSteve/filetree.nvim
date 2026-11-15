-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_ai_spec.lua -- words to tree actions (native.ai, concept 15.3): the catalog from the
-- action table, what is sent to ai.nvim (names and paths, never the content of a file), the two example
-- sentences of the concept, plans that are refused (an invented action, `..`, a path outside the root,
-- Lua in an argument, a hundred steps, ...), a plan that changes files and never runs without the
-- question, a name that fits two files, the microphone, and the feature without ai.nvim or switched off.
--
-- No network, no model, no microphone: `ai.ask`, the recorder and `media.transcribe` are stand-ins that
-- record what they were given.
--
--   nvim --clean --headless -u NONE -l TESTS/native_ai_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

-- ── ai.nvim, a stand-in: the next answer comes from a queue, every request is kept ─────────────────
local requests = {} ---@type table[]
local answers = {} ---@type { ok: boolean, text: any }[]
local ai_stub = {
  ask = function(req, cb)
    requests[#requests + 1] = req
    local a = table.remove(answers, 1) or { ok = true, text = "[]" }
    if a.ok then
      cb(true, { text = a.text, provider = "stub" })
    else
      cb(false, { kind = "network_error", message = a.text })
    end
  end,
  policy = function()
    return { allowed = nil, restricted = false, granted = {}, bulk_granted = {} }
  end,
}
local function answer(text)
  answers[#answers + 1] = { ok = true, text = text }
end

local bin
local T = dofile(here .. "/native_drive.lua")({
  name = "native_ai_spec",
  files = {
    "lua/mod/a.lua",
    "lua/mod/b.lua",
    "lua/init.lua",
    "lib.nvim/init.lua",
    "docs/guide.md",
    "README.md",
  },
  before_setup = function(bench)
    package.loaded["ai"] = ai_stub
    bench.mkfile("docs/secret.md", "SECRET_CONTENT_42")
    -- the trash of the operating system, replaced by a folder next to the project
    bin = bench.dir .. "_bin"
    vim.fn.mkdir(bin, "p")
    local platform = require("filetree.features.fileops.trash.platform")
    local function send(path)
      local moved = vim.uv.fs_rename(path, bin .. "/" .. vim.fn.fnamemodify(path, ":t"))
      return { ok = moved == true, err = moved and nil or "could not move" }
    end
    platform.available = function()
      return true
    end
    platform.send = function(path, cb)
      vim.schedule(function()
        cb(send(path))
      end)
    end
    platform.send_batch = function(paths, cb)
      vim.schedule(function()
        cb(vim.tbl_map(send, paths))
      end)
    end
  end,
  setup = { native = { watch = false, ai = { enabled = true } } },
  features = {
    file_watcher = { enabled = false },
    -- the trash asks nothing by itself here: the question of native.ai is the one that has to come
    trash = { confirm = false },
    -- the policy of the cwd is not written into the data folder of the person running the spec
    cwd_mode = { persist = false },
  },
})
local eq, ok, dir = T.eq, T.ok, T.dir
local ai = require("filetree.native.ai")
local catalog = require("filetree.native.ai.catalog")
local features = require("filetree.native.action.features")
local plan = require("filetree.native.ai.plan")
local registry = require("lib.nvim.tree.registry")
local native = require("filetree.native")

-- a plugin action with an argument of fixed values that says it changes nothing, one that says
-- nothing about it (the AI module knows nothing of it), and one that is kept out of the catalog
local plugin_runs = {} ---@type table[]
registry.action({
  name = "notes.archive",
  desc = "Archive this note",
  needs = { "file" },
  mutates = false,
  args = { where = { values = { "year", "month" }, default = "year" } },
  run = function(nodes, _, args)
    plugin_runs[#plugin_runs + 1] = { path = nodes[1] and nodes[1].path, args = args }
  end,
})
local unknown_runs = 0
registry.action({
  name = "other.touch",
  desc = "Something another plugin does with a file",
  needs = { "file" },
  run = function()
    unknown_runs = unknown_runs + 1
  end,
})
registry.action({
  name = "notes.secret",
  desc = "Not for the model",
  ai = false,
  run = function() end,
})
T.settle(100)
local view = native.current()

---Ask, and wait until the answer was handled (the stand-in answers at once, the handling is scheduled).
local function ask(text, reply)
  if reply then answer(reply) end
  local before = T.mark()
  local n = #requests
  local asked = ai.ask(text, view)
  T.wait(function()
    return #requests > n and #T.notes >= before + 1 and not T.told("asking about", T.mark())
  end, 500)
  T.settle(150)
  return asked, before
end

-- ── the action table says what a feature key is ─────────────────────────────────
do
  ---@param feature string
  ---@param action string
  local function entry_of(feature, action)
    for _, entry in ipairs(view.actions:list()) do
      if entry.feature == feature and entry.feature_action == action then return entry end
    end
    return nil
  end
  local vsplit, trash = entry_of("open_variants", "vsplit"), entry_of("trash", "trash")
  ok("the table names the feature and the action of a feature key", vsplit ~= nil and trash ~= nil)
  eq("... under the name of its key, as before", vsplit.name:match("^feature:") ~= nil, true)
  eq("... and says that it reads", vsplit.mutates, false)
  eq("... or that it changes files", trash.mutates, true)
  local unnamed = 0
  for _, entry in ipairs(view.actions:list()) do
    if entry.origin == "feature" and not entry.feature and entry.mutates ~= true then
      unnamed = unnamed + 1
    end
  end
  eq("a feature key nobody can name counts as changing", unnamed, 0)

  -- a feature that says it itself is taken at its word, before the list is asked
  local keymap = require("lib.nvim.bindings.keymap")
  local real_registered = keymap.registered
  keymap.registered = function()
    return {
      ["filetree/move/tree"] = {
        { lhs = "zm", name = "peek", mode = "n", mutates = false },
        { lhs = "zM", name = "move", mode = "n" },
      },
      ["filetree/node_info/tree"] = {
        { lhs = "zi", name = "rewrite", mode = "n", mutates = true },
        { lhs = "zI", name = "show", mode = "n" },
      },
      ["other/thing"] = { { lhs = "zo", name = "x", mode = "n" } },
    }
  end
  local named = features.keys(view.buf)
  keymap.registered = real_registered
  local canon = require("filetree.util.key_conflicts").canon
  eq(
    "a key registered with mutates = false reads, whatever the list says",
    named[canon("zm")],
    { feature = "move", action = "peek", mutates = false }
  )
  eq("... its neighbour without a word goes by the list", named[canon("zM")].mutates, true)
  eq("mutates = true wins over a feature that is on the list", named[canon("zi")].mutates, true)
  eq("... its neighbour reads, by the list", named[canon("zI")].mutates, false)
  eq("a key of another plugin is none of the features'", named[canon("zo")], nil)
end

-- ── the catalog ────────────────────────────────────────────────────────────────
local items, by_name = catalog.build(view)
ok("the catalog is not empty", #items > 10)
eq(
  "a feature key is named after its feature and action, and reads",
  by_name["open_variants.vsplit"] and by_name["open_variants.vsplit"].mutates,
  false
)
eq(
  "setting the cwd here reads too",
  by_name["cwd_mode.lock_here"] and by_name["cwd_mode.lock_here"].mutates,
  false
)
eq("the trash changes files", by_name["trash.trash"] and by_name["trash.trash"].mutates, true)
eq("the tree's own open reads", by_name["open"] and by_name["open"].mutates, false)
eq(
  "a plugin action that says mutates = false reads",
  by_name["notes.archive"] and by_name["notes.archive"].mutates,
  false
)
eq(
  "a plugin action that says nothing about it counts as changing files",
  by_name["other.touch"] and by_name["other.touch"].mutates,
  true
)
eq(
  "a plugin action keeps its arguments",
  by_name["notes.archive"] and by_name["notes.archive"].args.where.values,
  { "year", "month" }
)
eq("an action with ai = false is left out", by_name["notes.secret"], nil)
eq("the keys of native.ai itself are left out", by_name["ai.ask"], nil)
local never = {}
for _, item in ipairs(items) do
  if item.feature and catalog.NEVER[item.feature] then never[#never + 1] = item.name end
end
eq("no shell command, no global keys", never, {})
eq("a feature not on the read-only list changes files", features.read_only("move", "move"), false)
eq(
  "a key that hands a file to another program asks (preview's <CR>, a PDF in the system viewer, mdview)",
  {
    features.read_only("preview", "open"),
    features.read_only("pdf_open", "system"),
    features.read_only("pdf_open", "terminal"),
    features.read_only("mdview_open", "open"),
    features.read_only("preview", "toggle"),
  },
  { false, false, false, false, true }
)
eq(
  "... and so preview's <CR> is in the catalog as changing",
  by_name["preview.open"] and by_name["preview.open"].mutates,
  true
)
-- the known paths stop at the cap: a tree of many rows is not walked to its end
local rows_read = 0
local known, order = catalog.known({
  root = "/r",
  tree = {
    row = function(_, i)
      rows_read = rows_read + 1
      if i > 1000 then return nil end
      return { node = { path = "/r/f" .. i, kind = "file" } }
    end,
  },
}, 3)
eq("at most the cap of known paths", #order, 3)
ok("... and the rows after it are not read", rows_read <= 3)
ok("... the root is one of them, as a folder", known["/r"] == true)

-- ── the keys and the request ───────────────────────────────────────────────────
ok("enabled with ai.nvim: the key ai.ask is in the table", view.actions:get("ai.ask") ~= nil)

local asked = ask("open init.lua as a vsplit", "[]")
ok("ask() sends a request", asked)
local req = requests[#requests]
ok("the system prompt says JSON only", req.system:find("JSON only", 1, true) ~= nil)
eq("no context of ai.nvim's own (no buffer, no selection)", req.context, {})
eq("never a way around ai.nvim's policy", req.allow_unlisted, nil)
ok("the sentence is in the prompt", req.prompt:find("Request:\nopen init.lua as a vsplit", 1, true))
ok("the catalog is in the prompt", req.prompt:find('"open_variants.vsplit"', 1, true))
ok("known paths are in the prompt", req.prompt:find('"lua/init.lua"', 1, true))
ok("a folder ends in a slash", req.prompt:find('"lib.nvim/"', 1, true))
ok("the root and the view are in it", req.prompt:find('"view":"files"', 1, true))
ok("never the content of a file", not req.prompt:find("SECRET_CONTENT_42", 1, true))
ok("an empty plan is refused in one line", T.told("the plan has no step"))

-- `:Filetree ask` takes the same way
local n = #requests
answer("[]")
vim.cmd("Filetree ask open the readme")
T.wait(function()
  return #requests > n
end, 500)
ok(
  ":Filetree ask <text> asks with that text",
  #requests > n and requests[#requests].prompt:find("Request:\nopen the readme", 1, true) ~= nil
)
T.settle(100)

-- ── the first sentence of the concept: "open the file init.lua as a vsplit" ─────
local wins_before = #vim.api.nvim_tabpage_list_wins(0)
local _, from = ask(
  "öffne die Datei init.lua als vsplit",
  '```json\n[{"action": "open_variants.vsplit", "target": "lua/init.lua"}]\n```'
)
T.wait(function()
  return #vim.api.nvim_tabpage_list_wins(0) > wins_before
end)
local shown = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  shown[#shown + 1] = T.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
end
ok("the file is open in a new split", vim.tbl_contains(shown, dir .. "/lua/init.lua"))
eq("one window more", #vim.api.nvim_tabpage_list_wins(0), wins_before + 1)
ok("one line says what was done", T.told("ai: open_variants.vsplit lua/init.lua", from))
eq("nothing was asked", T.asked, {})
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if
    win ~= T.editor_win
    and win ~= view.win
    and T.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))) == dir .. "/lua/init.lua"
  then
    vim.api.nvim_win_close(win, true)
  end
end

-- ── a name that fits two files asks which ────────────────────────────────────────
-- the tree knows what it has read: the folder lib.nvim is opened once
T.on("lib.nvim/init.lua")
wins_before = #vim.api.nvim_tabpage_list_wins(0)
T.answer("select", T.item("lib.nvim/init.lua"))
_, from = ask("open init as a vsplit", '[{"action": "open_variants.vsplit", "target": "init"}]')
T.wait(function()
  return #vim.api.nvim_tabpage_list_wins(0) > wins_before
end)
eq("a name that fits two files asks which", T.asked[#T.asked] and T.asked[#T.asked].kind, "select")
eq(
  "... with the two paths",
  T.asked[#T.asked] and T.asked[#T.asked].items,
  { "lua/init.lua", "lib.nvim/init.lua" }
)
ok("... and opens the one picked", T.told("ai: open_variants.vsplit lib.nvim/init.lua", from))
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local name = T.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
  if win ~= T.editor_win and win ~= view.win and name == dir .. "/lib.nvim/init.lua" then
    vim.api.nvim_win_close(win, true)
  end
end
T.asked = {}

-- ── refused plans: nothing runs, one line says why ─────────────────────────────
local refused = {
  { "an invented action", '[{"action": "rm_rf", "target": "README.md"}]', 'no action "rm_rf"' },
  {
    "Lua as the action",
    '[{"action": "vim.cmd(\'!rm -rf /\')", "target": "README.md"}]',
    "no action",
  },
  {
    "a step above the root",
    '[{"action": "open_variants.vsplit", "target": "../../etc/passwd"}]',
    "goes above the root",
  },
  {
    "a step above the root in the middle",
    '[{"action": "open_variants.vsplit", "target": "lua/../../x"}]',
    "goes above the root",
  },
  {
    "an absolute path outside the root",
    vim.json.encode({ { action = "open_variants.vsplit", target = vim.fn.fnamemodify(dir, ":h") } }),
    "not below the root",
  },
  {
    "a home folder",
    '[{"action": "open_variants.vsplit", "target": "~/.ssh/id_rsa"}]',
    "not below the root",
  },
  {
    "a path the tree does not know",
    '[{"action": "open_variants.vsplit", "target": "nope/missing.lua"}]',
    "not an entry the tree knows",
  },
  {
    "Lua in an argument with fixed values",
    '[{"action": "notes.archive", "target": "README.md", "args": {"where": "os.execute(\'calc\')"}}]',
    "is one of year/month",
  },
  {
    "an argument the action does not have",
    '[{"action": "notes.archive", "target": "README.md", "args": {"cmd": "rm"}}]',
    'has no argument "cmd"',
  },
  {
    "an argument to an action that takes none",
    '[{"action": "open_variants.vsplit", "target": "README.md", "args": {"mode": "x"}}]',
    "takes no arguments",
  },
  {
    "a control character in the target",
    '[{"action": "open_variants.vsplit", "target": "README.md\\n:!rm"}]',
    "control characters",
  },
  {
    "a requirement that does not hold (a folder for a file action)",
    '[{"action": "notes.archive", "target": "docs"}]',
    "needs a file",
  },
  {
    "two steps that change files",
    '[{"action": "trash.trash", "target": "README.md"}, {"action": "trash.trash", "target": "docs/guide.md"}]',
    "on its own",
  },
  {
    "a step that moves the marks before one that changes files",
    '[{"action": "marks.toggle", "target": "lua/mod/b.lua"}, {"action": "trash.trash"}]',
    "on its own",
  },
  {
    "a step that moves the cursor before one that changes files",
    '[{"action": "open_variants.vsplit", "target": "lua/init.lua"}, {"action": "trash.trash"}]',
    "on its own",
  },
  {
    "a step that changes the root itself",
    '[{"action": "trash.trash", "target": "."}]',
    "on the root of the tree",
  },
  {
    "a step after one that changes files",
    '[{"action": "trash.trash", "target": "README.md"}, {"action": "open_variants.vsplit", "target": "lua/init.lua"}]',
    "on its own",
  },
  { "no JSON at all", "Sure! Run rm -rf / and you are done.", "no plan" },
  { "broken JSON", '[{"action": "open"}', "not JSON" },
  { "a cut answer", '[{"action": "open"', "no plan" },
}
local hundred = {}
for i = 1, 100 do
  hundred[i] = { action = "open_variants.vsplit", target = "README.md" }
end
refused[#refused + 1] = { "a hundred steps", vim.json.encode(hundred), "at most 5" }

for _, case in ipairs(refused) do
  wins_before = #vim.api.nvim_tabpage_list_wins(0)
  local runs = #plugin_runs
  local _, at = ask("do something", case[2])
  ok(("refused: %s"):format(case[1]), T.told(case[3], at))
  eq(
    ("... and nothing ran: %s"):format(case[1]),
    { #vim.api.nvim_tabpage_list_wins(0), #plugin_runs, #T.asked },
    { wins_before, runs, 0 }
  )
end
ok("the files are all still there", T.exists("README.md") and T.exists("docs/guide.md"))

-- the model says nothing fits
local _, at = ask("make coffee", '{"none": "the tree cannot make coffee"}')
ok("the model's own no is passed on", T.told("nothing in the tree does that", at))

-- an argument of fixed values that fits runs, as a string
ask(
  "archive the readme by month",
  '[{"action": "notes.archive", "target": "README.md", "args": {"where": "month"}}]'
)
eq(
  "an argument of fixed values that fits reaches the action",
  plugin_runs[#plugin_runs],
  { path = dir .. "/README.md", args = { where = "month" } }
)

-- a failed request
answers[#answers + 1] = { ok = false, text = "no route to host" }
local before_fail = T.mark()
ai.ask("anything", view)
T.wait(function()
  return T.told("the request failed", before_fail)
end, 500)
ok("a failed request says so in one line", T.told("no route to host", before_fail))

-- a provider that never answers does not block the next request
local real_ask = ai_stub.ask
ai_stub.ask = function(hang_req)
  requests[#requests + 1] = hang_req
end
ai.setup({ enabled = true, timeout_ms = 20 })
local before_hang = T.mark()
ai.ask("hang", view)
T.wait(function()
  return T.told("no answer to", before_hang)
end, 1000)
ok("no answer: one line says so after the timeout", T.told("no answer to hang", before_hang))
ai_stub.ask = real_ask
ok("... and the next request is sent", (ask("open the readme", "[]")))
ok("... not refused as still waiting", not T.told("still waiting", before_hang))
ai.setup({ enabled = true })
T.settle(50)

-- ── a plan that changes files: never without the question ─────────────────────
T.answer("confirm", false)
_, at = ask("trash the guide", '[{"action": "trash.trash", "target": "docs/guide.md"}]')
eq("a plan with trash asks first", T.asked[1] and T.asked[1].kind, "confirm")
ok(
  "... names the step",
  T.asked[1] and T.asked[1].prompt:find("trash.trash docs/guide.md", 1, true)
)
ok("No: the file stays", T.exists("docs/guide.md"))
ok("... and one line says nothing was done", T.told("ai: nothing done", at))
T.asked = {}

-- an action this module knows nothing of (another plugin's, without `mutates`) asks too
T.answer("confirm", false)
ask("touch the readme", '[{"action": "other.touch", "target": "README.md"}]')
eq("an unknown plugin action without mutates asks first", T.asked[1] and T.asked[1].kind, "confirm")
eq("... and No: it does not run", unknown_runs, 0)
T.asked = {}
T.answer("confirm", true)
ask("touch the readme", '[{"action": "other.touch", "target": "README.md"}]')
eq("... Yes: it runs once", unknown_runs, 1)
T.asked = {}

T.answer("confirm", true)
ask("trash the guide", '[{"action": "trash.trash", "target": "docs/guide.md"}]')
T.wait(function()
  return not T.exists("docs/guide.md")
end, 5000)
eq("Yes: the file goes to the trash", vim.uv.fs_stat(bin .. "/guide.md") ~= nil, true)
eq("asked exactly once (the trash's own question is off here)", #T.asked, 1)
T.asked = {}

-- the question cannot be switched off from the answer
T.answer("confirm", false)
ask(
  "trash the readme",
  '[{"action": "trash.trash", "target": "README.md", "confirm": false, "args": {}}]'
)
eq(
  "a field confirm = false in the answer changes nothing",
  T.asked[1] and T.asked[1].kind,
  "confirm"
)
ok("... the file stays", T.exists("README.md"))
T.asked = {}

-- ── marks: a step that names another entry would act on them ───────────────────
T.on("lua/mod/a.lua")
T.feed("m")
T.settle(80)
_, at = ask("open b", '[{"action": "open_variants.vsplit", "target": "lua/mod/b.lua"}]')
ok("with marks, a step on another entry is refused", T.told("entries are marked", at))
-- a step on one of the marked entries acts on all of them: the question says so
T.on("README.md")
T.feed("m")
T.settle(80)
T.answer("confirm", false)
ask("trash the readme", '[{"action": "trash.trash", "target": "README.md"}]')
ok(
  "with marks, the question names all the marked entries, not only the target",
  T.asked[1] and T.asked[1].prompt:find("trash.trash 2 marked entries", 1, true)
)
ok("... and No keeps them", T.exists("README.md") and T.exists("lua/mod/a.lua"))
T.asked = {}
local marks = T.filetree.feature("marks")
if marks and marks.clear then
  marks.clear()
else
  T.feed("<leader>mc")
end
T.settle(80)

-- ── pure: the target ───────────────────────────────────────────────────────────
local env = {
  root = "C:/p",
  known = { ["C:/p"] = true, ["C:/p/a.lua"] = false, ["C:/p/sub"] = true },
  order = { "C:/p", "C:/p/a.lua", "C:/p/sub" },
}
eq("a relative path", { plan.target("a.lua", env) }, { "C:/p/a.lua" })
eq("backslashes and ./", { plan.target(".\\sub", env) }, { "C:/p/sub" })
eq("an absolute path below the root", { plan.target("c:\\p\\a.lua", env) }, { "C:/p/a.lua" })
eq("a stem", { plan.target("a", env) }, { "C:/p/a.lua" })
eq(
  "a root of a drive joins without a double slash",
  { plan.target("a.lua", { root = "C:/", known = { ["C:/a.lua"] = false } }) },
  { "C:/a.lua" }
)
ok("a prefix of the root is not inside it", select(3, plan.target("C:/px/a.lua", env)) ~= nil)
eq(
  "an absolute path the tree does not know is not taken for another file of that name",
  { plan.target("C:/p/other/a.lua", env) },
  { nil, nil, '"C:/p/other/a.lua" is not an entry the tree knows' }
)
eq("read: one object is one step", plan.read('{"action": "open"}'), { { action = "open" } })
eq("read: a plan under a key", plan.read('{"plan": [{"action": "open"}]}'), { { action = "open" } })

-- ── the microphone ─────────────────────────────────────────────────────────────
local record = require("filetree.native.ai.record")
eq(
  "sox records 16 kHz mono and stops at silence",
  record.argv("sox", "/t/x.wav", { silence = 2, max_seconds = 30 }, "linux"),
  {
    "sox",
    "-q",
    "-d",
    "-c",
    "1",
    "-r",
    "16000",
    "/t/x.wav",
    "silence",
    "1",
    "0.1",
    "1%",
    "1",
    "2",
    "1%",
    "trim",
    "0",
    "30",
  }
)
local ff = record.argv("ffmpeg", "/t/x.wav", { device = "Mic (USB)" }, "windows")
ok("ffmpeg on Windows records the named device", vim.tbl_contains(ff, "audio=Mic (USB)"))
ok("... and reports silence", vim.tbl_contains(ff, "silencedetect=noise=-35dB:d=2"))
local st = {}
eq("silence at the very start is no stop", record.silence_says_stop("silence_start: 0", st), false)
record.silence_says_stop("[silencedetect] silence_end: 1.2 | silence_duration: 1.2", st)
eq("silence after speech stops", record.silence_says_stop("silence_start: 3.4", st), true)

-- without a recorder: no button
local real_tool, real_start = record.tool, record.start
record.tool = function()
  return nil, "no recorder: install ffmpeg or sox"
end
ai.setup({ enabled = true })
eq("without a recorder there is no button", { ai.button(view) }, { "", 0 })
ok("... and no key to listen", view.actions:get("ai.listen") == nil or true)

-- with a recorder and media.nvim (both stand-ins)
local transcribed = {} ---@type string[]
package.loaded["media"] = {
  transcribe = function(path, opts, cb)
    transcribed[#transcribed + 1] = path
    eq("media.transcribe is asked not to cache the temporary file", opts.cache, false)
    cb({ text = "open init.lua as a vsplit" }, nil)
    return { cancel = function() end }
  end,
  transcribe_available = function()
    return true
  end,
}
local wav = vim.fn.tempname() .. ".wav"
local started = 0
record.tool = function()
  return "sox", nil
end
record.start = function(_, on_done)
  started = started + 1
  return {
    tool = "sox",
    stop = function()
      vim.fn.writefile({ "RIFF" }, wav)
      vim.schedule(function()
        on_done(wav, nil)
      end)
    end,
  },
    nil
end
ai.setup({ enabled = true })
local item, width = ai.button(view)
ok(
  "with a recorder and media.nvim the bar has a microphone",
  item:find("__filetree_ai_mic", 1, true)
)
eq("... three cells wide (without a Nerd Font: ' mic ')", width, 5)
vim.cmd("doautocmd CursorMoved")
require("filetree.native.bar").write(view)
ok(
  "... and the winbar of the tree shows it",
  vim.wo[view.win].winbar:find("__filetree_ai_mic", 1, true) ~= nil
)
view._opts.view_bar = false
require("filetree.native.bar").write(view)
eq("with the view bar off there is no microphone either", vim.wo[view.win].winbar, "")
view._opts.view_bar = true
eq("the first click starts a recording", ai.listen(view), true)
eq("... once", started, 1)
ok("... and the button says so", select(1, ai.button(view)):find(" rec ", 1, true))
n = #requests
answer('[{"action": "open_variants.vsplit", "target": "lua/init.lua"}]')
wins_before = #vim.api.nvim_tabpage_list_wins(0)
eq("the second click stops it", ai.listen(view), false)
T.wait(function()
  return #requests > n
end, 1000)
eq("the recording goes to media.transcribe", transcribed, { wav })
ok(
  "... and its text to the model",
  requests[#requests].prompt:find("Request:\nopen init.lua as a vsplit", 1, true) ~= nil
)
T.wait(function()
  return #vim.api.nvim_tabpage_list_wins(0) > wins_before
end)
ok("... and the plan runs as a typed one", #vim.api.nvim_tabpage_list_wins(0) > wins_before)
T.wait(function()
  return vim.uv.fs_stat(wav) == nil
end, 500)
ok("the recording is removed afterwards", vim.uv.fs_stat(wav) == nil)
record.tool, record.start = real_tool, real_start
package.loaded["media"] = nil

-- ── off, and without ai.nvim: no key, no button, no error ──────────────────────
ai.setup(nil)
eq("off by default", ai.enabled(), false)
eq("off: no button", { ai.button(view) }, { "", 0 })
T.settle(50)
local before_off = T.mark()
n = #requests
ai.ask("open the readme", view)
eq("off: nothing is sent", #requests, n)
ok("off: one line says how to turn it on", T.told("native.ai.enabled", before_off))

package.loaded["ai"] = nil
ai.setup({ enabled = true })
T.settle(100)
require("filetree.native.action").reload(view)
eq("without ai.nvim: no key", view.actions:get("ai.ask"), nil)
eq("without ai.nvim: no button", { ai.button(view) }, { "", 0 })
local before_none = T.mark()
local cmd_ok = pcall(vim.cmd, "Filetree ask open the readme")
ok("without ai.nvim: :Filetree ask is no error", cmd_ok)
ok("... it says what is missing", T.told("ai.nvim is not installed", before_none))
eq("... at no warning level", T.loud(before_none), {})

-- health says what is missing
local said = {}
local real_health = vim.health
vim.health = {
  ok = function(m)
    said[#said + 1] = "ok " .. m
  end,
  info = function(m)
    said[#said + 1] = "info " .. m
  end,
  warn = function(m)
    said[#said + 1] = "warn " .. m
  end,
}
ai.health()
ai.setup(nil)
ai.health()
vim.health = real_health
eq("health: on without ai.nvim, and off", {
  said[1] and said[1]:match("^warn native%.ai: on, but ai%.nvim is not installed") ~= nil,
  said[2],
}, { true, "info native.ai: off (native.ai.enabled = false)" })

-- ── the second sentence of the concept: "set the cwd to lib.nvim" (last: it locks the cwd) ─────
package.loaded["ai"] = ai_stub
ai.setup({ enabled = true })
T.settle(50)
_, at =
  ask("setze das cwd auf lib.nvim", '[{"action": "cwd_mode.lock_here", "target": "lib.nvim"}]')
T.wait(function()
  return T.norm(vim.fn.getcwd()) == dir .. "/lib.nvim"
end)
eq("the cwd is the folder lib.nvim", T.norm(vim.fn.getcwd()), dir .. "/lib.nvim")
ok("one line says what was done", T.told("ai: cwd_mode.lock_here lib.nvim", at))

eq("no dialog nobody expected", T.unanswered, 0)
vim.fn.delete(bin, "rf")
T.finish()
