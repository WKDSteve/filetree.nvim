-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive.lua -- the shared bench of the `native_drive_*_spec.lua` files: a small project on
-- disk, a full `setup({ adapter = "native" })`, the tree open on the left, and the three places a
-- feature asks the person something (`vim.ui.input`, `filetree.util.select`, `filetree.util.confirm`)
-- answered from a queue that records what was asked. The dialogs themselves have their own specs; here
-- the question is what a feature does on the own tree once its key was pressed.
--
-- Not a spec (no `_spec` in the name). A spec loads it first thing:
--
--   local T = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/native_drive.lua")({
--     name = "native_drive_paths_spec",
--     features = { ... },
--   })

---@class NativeDriveOpts
---@field name string                 Name of the spec, for the result line.
---@field features? table             Merged over the feature block of the bench.
---@field setup? table                Merged over the top level of the setup table.
---@field files? string[]             Files of the project (relative), instead of the default ones.
---@field before_setup? fun(T: table) Runs after the fixture exists and before `filetree.setup`.

---@param opts NativeDriveOpts
return function(opts)
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

  -- No `vim.o.columns` / `vim.o.lines` here or in a spec on this bench: a headless run has no UI, its
  -- screen grid stays 80x24 whatever the options say, and the next forced redraw writes past it.

  local T = { root = root, passed = 0, failed = 0 }

  -- Results go to stdout directly: print() in a headless run goes through the message area.
  function T.say(text)
    io.stdout:write(text, "\n")
  end
  function T.eq(name, got, want)
    if vim.deep_equal(got, want) then
      T.passed = T.passed + 1
      T.say("  ok   " .. name)
    else
      T.failed = T.failed + 1
      T.say(("  FAIL %s  -- got %s want %s"):format(name, vim.inspect(got), vim.inspect(want)))
    end
  end
  function T.ok(name, cond)
    T.eq(name, cond and true or false, true)
  end
  function T.na(text)
    T.say("  n/a  " .. text)
  end

  vim.g.have_nerd_font = false
  vim.g.mapleader = "\\"

  local list = require("filetree.native.fs.list")
  T.norm = list.norm

  -- ── every message of the run ─────────────────────────────────────────────────
  T.notes = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level)
    T.notes[#T.notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
  end
  ---The messages at warning level or above, since `from` (an index into `T.notes`, default 1).
  ---@param from? integer
  ---@return string[]
  function T.loud(from)
    local out = {}
    for i = from or 1, #T.notes do
      local note = T.notes[i]
      if note.level >= vim.log.levels.WARN then out[#out + 1] = note.msg end
    end
    return out
  end
  ---The index the next message will get: `T.loud(T.mark())` reads what a step said.
  ---@return integer
  function T.mark()
    return #T.notes + 1
  end
  ---Whether a message since `from` contains `needle` (plain text).
  ---@param needle string
  ---@param from? integer
  ---@return boolean
  function T.told(needle, from)
    for i = from or 1, #T.notes do
      if T.notes[i].msg:find(needle, 1, true) then return true end
    end
    return false
  end

  -- ── the three places a feature asks something ────────────────────────────────
  -- Each answer is used once, in order. A question nobody queued an answer for is dismissed (nil,
  -- "No") and counted in `T.unanswered`, so a spec sees a prompt it did not expect.
  T.asked = {} ---@type { kind: string, prompt: string, default: string?, items: any[]? }[]
  T.unanswered = 0
  local queue = { input = {}, select = {}, confirm = {}, choice = {} }
  ---@param kind "input"|"select"|"confirm"|"choice"
  ---@param value any  input: the text, or false to dismiss. select: an index, a function
  ---                  `(items, format) -> index`, or false. confirm: true / false. choice: the
  ---                  label of a button, or false.
  function T.answer(kind, value)
    table.insert(queue[kind], { value = value })
  end
  local function take(kind)
    local entry = table.remove(queue[kind], 1)
    if not entry then
      T.unanswered = T.unanswered + 1
      return nil
    end
    return entry
  end

  local real_input = vim.ui.input
  vim.ui.input = function(o, on_confirm)
    o = o or {}
    T.asked[#T.asked + 1] =
      { kind = "input", prompt = tostring(o.prompt or ""), default = o.default }
    local entry = take("input")
    local value = entry and entry.value
    on_confirm(type(value) == "string" and value or nil)
  end

  -- The one-line prompt of ui.kit (create, rename, move ...): the same queue as `vim.ui.input`. Only
  -- this function of the kit is replaced; viewers and menus are the real ones.
  local kit = require("ui.kit")
  local real_kit_input = kit.input
  kit.input = function(o)
    o = o or {}
    T.asked[#T.asked + 1] =
      { kind = "input", prompt = tostring(o.title or ""), default = o.default }
    local entry = take("input")
    local value = entry and entry.value
    if type(value) == "string" then
      if o.on_submit then o.on_submit(value) end
    elseif o.on_cancel then
      o.on_cancel()
    end
    return nil
  end

  -- A question with up to four buttons: the answer is the label of one, or false to dismiss.
  package.loaded["filetree.util.confirm_choice"] = function(question, choices, on_choice)
    T.asked[#T.asked + 1] = { kind = "choice", prompt = tostring(question), items = choices }
    local entry = take("choice")
    local value = entry and entry.value
    on_choice(type(value) == "string" and vim.tbl_contains(choices, value) and value or nil)
  end

  package.loaded["filetree.util.select"] = function(items, o, on_choice)
    o = o or {}
    T.asked[#T.asked + 1] = { kind = "select", prompt = tostring(o.prompt or ""), items = items }
    local entry = take("select")
    local value = entry and entry.value
    if type(value) == "function" then value = value(items, o.format_item or tostring) end
    if type(value) == "number" and items[value] ~= nil then
      on_choice(items[value], value)
    else
      on_choice(nil, nil)
    end
  end

  package.loaded["filetree.util.confirm"] = function(o)
    o = o or {}
    T.asked[#T.asked + 1] = { kind = "confirm", prompt = tostring(o.question or "") }
    local entry = take("confirm")
    if o.on_choice then o.on_choice(entry ~= nil and entry.value == true) end
  end

  ---The index of the first item whose shown text contains `needle`: an answer for a select.
  ---@param needle string
  ---@return fun(items: any[], format: fun(item: any): string): integer?
  function T.item(needle)
    return function(items, format)
      for i, item in ipairs(items) do
        if tostring(format(item)):find(needle, 1, true) then return i end
      end
      return nil
    end
  end

  -- ── fixture: a small project ─────────────────────────────────────────────────
  local base = list.norm(vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")))
  local dir = ("%s/ft_drive_%d"):format(base, vim.uv.hrtime() % 1e9)
  T.dir = dir
  function T.mkfile(rel, text)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(type(text) == "table" and text or { text or "local x = 1" }, path)
    return path
  end
  function T.exists(rel)
    return vim.uv.fs_stat(dir .. "/" .. rel) ~= nil
  end
  function T.read(rel)
    return vim.fn.readfile(dir .. "/" .. rel)
  end
  for _, rel in
    ipairs(opts.files or {
      "lua/mod/a.lua",
      "lua/mod/b.lua",
      "lua/init.lua",
      "docs/guide.md",
      "README.md",
    })
  do
    T.mkfile(rel)
  end
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/README.md"))
  T.editor_win = vim.api.nvim_get_current_win()

  if opts.before_setup then opts.before_setup(T) end

  -- ── setup ────────────────────────────────────────────────────────────────────
  local filetree = require("filetree")
  T.filetree = filetree
  local setup_table = vim.tbl_deep_extend("force", {
    adapter = "native",
    deps_popup = false,
    native = { width = 36 },
    features = vim.tbl_deep_extend("force", {
      tree_toggle = { enabled = true },
      session = { enabled = false }, -- writes into the user's data directory
      -- opening a file from the tree would close the tree under the spec
      close_on_open = { enabled = false },
    }, opts.features or {}),
  }, opts.setup or {})
  local set_up, setup_err = pcall(filetree.setup, setup_table)
  T.ok("setup with adapter = native: " .. tostring(setup_err), set_up)
  T.adapter = filetree.adapter()
  T.eq("the active adapter", T.adapter.name, "native")
  T.eq("setup says nothing at warning level", T.loud(), {})

  function T.feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end
  function T.settle(ms)
    vim.wait(ms or 80, function()
      return false
    end)
  end
  ---Wait until `cond` holds (at most `ms`, default 2000) and say whether it did.
  ---@param cond fun(): boolean?
  ---@param ms? integer
  ---@return boolean
  function T.wait(cond, ms)
    return (vim.wait(ms or 2000, function()
      return cond() and true or false
    end, 20))
  end
  function T.lines()
    return vim.api.nvim_buf_get_lines(T.adapter.get_bufnr(), 0, -1, false)
  end
  ---Focus the tree window.
  function T.tree()
    if not T.adapter.is_open() then T.adapter.open_cwd() end
    vim.api.nvim_set_current_win(T.adapter.get_winid())
  end
  ---Open the folders above `rel` and put the tree's cursor on it. Crashes when the tree does not
  ---show the path afterwards: every case after it would test the wrong node.
  ---@param rel string  Relative to the project, "" for nothing.
  function T.on(rel)
    T.tree()
    local path = dir .. "/" .. rel
    local parts = vim.split(rel, "/", { plain = true })
    local folder = dir
    for i = 1, #parts - 1 do
      folder = folder .. "/" .. parts[i]
      T.wait(function()
        return T.adapter.get_node_line(folder) ~= nil
      end)
      T.adapter.expand_node({ path = folder })
    end
    T.wait(function()
      return T.adapter.get_node_line(path) ~= nil
    end)
    local line = T.adapter.get_node_line(path)
    assert(line, "the tree does not show " .. rel)
    vim.api.nvim_win_set_cursor(T.adapter.get_winid(), { line, 0 })
    vim.cmd("doautocmd CursorMoved")
    return path
  end
  ---Whether the tree shows the path (relative to the project).
  function T.shown(rel)
    return T.adapter.get_node_line(dir .. "/" .. rel) ~= nil
  end
  ---The text last written to the unnamed register (what a copy feature leaves behind).
  function T.copied()
    return vim.fn.getreg('"')
  end
  ---Empty the unnamed register, so a copy that did nothing is not read as the copy before it.
  function T.forget_copy()
    vim.fn.setreg('"', "")
  end

  T.tree()
  T.settle()
  T.buf = T.adapter.get_bufnr()

  ---Report, clean up and leave. `cq` on a failure.
  function T.finish()
    vim.notify = real_notify
    vim.ui.input = real_input
    kit.input = real_kit_input
    pcall(function()
      require("filetree.native").reset()
    end)
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    vim.fn.delete(dir, "rf")
    T.say(("\nfiletree.nvim %s: %d passed, %d failed"):format(opts.name, T.passed, T.failed))
    if T.failed > 0 then
      vim.cmd("cq")
    else
      vim.cmd("qa!")
    end
  end

  return T
end
