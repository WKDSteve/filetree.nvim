---@module 'filetree.native.ai'
---@brief Words to tree actions: `:Filetree ask <text>` and a microphone in the view bar, through ai.nvim.
---@description
--- Off by default (`native.ai.enabled = false`). ai.nvim is a soft dependency: without it there is no
--- key, no button and no error, and `:checkhealth filetree` says what is missing.
---
---   sentence ──► ai.ask(catalog + context + sentence) ──► answer (JSON text)
---       ▲                                                     │
---   speech: recorder (ffmpeg/sox) ─► media.transcribe         ▼
---                                         plan.read + plan.check (catalog, known paths, args)
---                                              │ refused: one line why
---                                              ▼
---                         read only: run, one line says what     changes files: the plan is shown and
---                                                                asked about first, always
---
--- The answer of the model is untrusted input: no field of it is run, opened or loaded before it was
--- checked against the catalog of the view and the paths the tree knows (`filetree.native.ai.plan`).
--- A step that changes files runs only after the person said yes to the plan here, whatever the
--- `confirm` options of the features say; the feature's own question follows as by hand. Only names and
--- paths go to the provider, never the content of a file, and ai.nvim's provider policy (`ai.policy()`)
--- decides which provider may answer: this module never asks for an exception to it.
---
--- Key responsibilities:
--- - `setup(opts)`: the `native.ai` options; the keys `ai.ask` / `ai.listen` when enabled and ai.nvim is there
--- - `ask(text, view?)`: one request, start to end
--- - `listen(view?)`: start or stop a spoken request
--- - `button(view)`: the microphone of the view bar
--- - `health()`: the lines of `:checkhealth filetree`

local catalog = require("filetree.native.ai.catalog")
local plan = require("filetree.native.ai.plan")
local list = require("filetree.native.fs.list")
local notify = require("filetree.util.notify").create("[filetree.ai]")

local api = vim.api

local M = {}

---@class Filetree.Ai.Opts
---@field enabled? boolean  Turn the feature on (default false).
---@field provider? string  The ai.nvim provider to ask (default: ai.nvim's own choice). It has to be allowed by ai.nvim's policy.
---@field model? string  The model of that provider (default: ai.nvim's).
---@field timeout_ms? integer  How long to wait for the answer (default 60000).
---@field max_paths? integer  Paths of the tree the model is told at most (default 400).
---@field keys? { ask?: string|false, listen?: string|false }  Keys in the tree (default `<leader>at`, `<leader>aT`).
---@field button? boolean  The microphone in the view bar (default true; needs a recorder and media.nvim).
---@field record? Filetree.Ai.RecordOpts

---@type Filetree.Ai.Opts
local DEFAULTS = {
  enabled = false,
  timeout_ms = 60000,
  max_paths = catalog.MAX_PATHS,
  keys = { ask = "<leader>at", listen = "<leader>aT" },
  button = true,
  record = { tool = "auto", silence = 2, max_seconds = 30 },
}

---@type Filetree.Ai.Opts
local options = vim.deepcopy(DEFAULTS)

---@type (fun(): boolean)[]
local unregister = {}

---@type { text: string }|nil  The request waiting for its answer.
local pending = nil
---@type Filetree.Ai.Recording|nil
local recording = nil
---@type Filetree.View|nil  The view the recording is for.
local recording_view = nil
---@type { cancel: fun() }|nil
local transcribing = nil

---@return Filetree.Ai.Opts
function M.options()
  return options
end

---@return boolean
function M.enabled()
  return options.enabled == true
end

---ai.nvim, when it is installed.
---@return table|nil
local function ai_nvim()
  local ok, ai = pcall(require, "ai")
  if ok and type(ai) == "table" and type(ai.ask) == "function" then return ai end
  return nil
end

---@return boolean
function M.has_ai()
  return ai_nvim() ~= nil
end

---What a spoken request needs that is missing: a recorder, media.nvim, a whisper engine.
---@return string[] missing  Empty: everything is there.
function M.voice_missing()
  local missing = {}
  local tool, why = require("filetree.native.ai.record").tool(options.record)
  if not tool then missing[#missing + 1] = why or "no recorder" end
  local ok, media = pcall(require, "media")
  if not ok or type(media) ~= "table" or type(media.transcribe) ~= "function" then
    missing[#missing + 1] = "media.nvim (speech to text) is not installed"
  elseif type(media.transcribe_available) == "function" then
    local ok2, ready = pcall(media.transcribe_available)
    if not ok2 or not ready then
      missing[#missing + 1] = "media.nvim has no whisper engine ready (:checkhealth media)"
    end
  end
  return missing
end

---@type boolean|nil  Cached answer of `voice_missing` for the bar, which is written often.
local voice_ready = nil

---@return boolean
local function voice()
  if voice_ready == nil then voice_ready = #M.voice_missing() == 0 end
  return voice_ready
end

---The tree view to act in: the one given, else the one of this tab.
---@param view? Filetree.View
---@return Filetree.View|nil
local function view_of(view)
  if view and view.actions then return view end
  local current = require("filetree.native").current()
  if current and current.actions then return current end
  return nil
end

---@param path string
---@param root string
---@return string
local function rel(path, root)
  if list.inside(root, path) then
    local r = plan.rel_of(root, path)
    return r == "" and "." or r
  end
  return path
end

-- ── checking a plan ────────────────────────────────────────────────────────────

---What `plan.check` checks a plan with: the catalog and the known paths of the view as they are now.
---@param view Filetree.View
---@return Filetree.Ai.Env env
---@return Filetree.Ai.Item[] items
function M.env(view)
  local tbl = require("filetree.native.action.table")
  local action = require("filetree.native.action")
  local items, by_name = catalog.build(view)
  local known, order = catalog.known(view, options.max_paths)
  ---@type Filetree.Ai.Env
  local env = {
    root = view.root,
    catalog = by_name,
    known = known,
    order = order,
    check = function(item, path)
      local entry = view.actions and view.actions:get(item.action)
      if not entry then return false, "is not in the tree any more" end
      local ctx = action.ctx(view)
      if path == nil then
        local row = view:current()
        return tbl.check(entry, row and row.node or nil, ctx)
      end
      local id = view:id_of(path)
      local node = view.tree:node(id)
      if not node then
        -- a path the cache read but no row shows: it is a file or folder all the same
        node = {
          id = path,
          path = path,
          kind = known[path] and "dir" or "file",
          label = list.basename(path),
        }
      end
      ctx.source = view:source_of(id)
      return tbl.check(entry, node, ctx)
    end,
  }
  return env, items
end

-- ── running a plan ─────────────────────────────────────────────────────────────

---Put the focus into the tree window, opening it when it is closed.
---@param view Filetree.View
---@return boolean
local function focus(view)
  if not view:is_open() then pcall(view.open, view, nil, true) end
  if not (view.win and api.nvim_win_is_valid(view.win)) then return false end
  api.nvim_set_current_win(view.win)
  return true
end

---One line for a step: the action and what it acts on.
---@param step Filetree.Ai.Step
---@param view Filetree.View
---@param affected? string[]
---@return string
local function describe(step, view, affected)
  local args = {}
  for k, v in pairs(step.args or {}) do
    args[#args + 1] = k .. "=" .. v
  end
  table.sort(args)
  local on
  if step.target then
    on = rel(step.target, view.root)
  elseif affected and #affected > 0 then
    on = #affected == 1 and rel(affected[1], view.root) or (#affected .. " marked entries")
  else
    on = "the entry under the cursor"
  end
  local text = ("%s %s"):format(step.action, on)
  if #args > 0 then text = text .. " (" .. table.concat(args, ", ") .. ")" end
  return text
end

---Run the steps, one after the other, each on its target. Stops at the first that cannot run.
---@param view Filetree.View
---@param steps Filetree.Ai.Step[]
function M.run(view, steps)
  local action = require("filetree.native.action")
  local said = {}
  for _, step in ipairs(steps) do
    if not focus(view) then
      notify.info("ai: the tree window could not be opened")
      return
    end
    if step.target and not view:reveal(step.target) then
      notify.info(("ai: %s is not shown in this view"):format(rel(step.target, view.root)))
      return
    end
    -- the action says itself in one line why it does not apply
    if not action.run(view, step.item.action, step.args) then return end
    said[#said + 1] = describe(step, view)
  end
  notify.info("ai: " .. table.concat(said, "; "))
end

---Run a checked plan: at once when it only reads, after the question when a step changes files.
---@param view Filetree.View
---@param steps Filetree.Ai.Step[]
function M.execute(view, steps)
  local marked = catalog.marked()
  local marked_set = {}
  for _, path in ipairs(marked or {}) do
    marked_set[path] = true
  end
  -- with entries marked, an action acts on them: a step that names another one would hit the marks
  for i, step in ipairs(steps) do
    if marked and step.target and not marked_set[step.target] then
      notify.info(
        ("ai: refused, step %d: %d entries are marked and %s would act on them, not on %s; clear the marks first"):format(
          i,
          #marked,
          step.action,
          rel(step.target, view.root)
        )
      )
      return
    end
  end
  local changes = nil
  for _, step in ipairs(steps) do
    if step.item.mutates then changes = step end
  end
  if not changes then
    M.run(view, steps)
    return
  end
  local affected = {}
  if changes.target then
    affected = { changes.target }
  elseif marked then
    affected = marked
  else
    local row = view:current()
    if row and row.node and row.node.path then affected = { list.norm(row.node.path) } end
  end
  local body = {}
  for i, step in ipairs(steps) do
    body[#body + 1] = ("  %d. %s"):format(
      i,
      describe(step, view, step == changes and affected or nil)
    )
  end
  for _, path in ipairs(changes.target and {} or affected) do
    body[#body + 1] = "     " .. rel(path, view.root)
  end
  -- never skipped: not by a feature's `confirm = false`, not by anything in the answer
  require("filetree.util.confirm")({
    title = " filetree ai ",
    body = body,
    question = ("Run this plan? %s changes files."):format(describe(changes, view, affected)),
    on_choice = function(yes)
      if yes then
        M.run(view, steps)
      else
        notify.info("ai: nothing done")
      end
    end,
  })
end

---Pick one path for every step whose name fit several, then go on.
---@param view Filetree.View
---@param steps Filetree.Ai.Step[]
---@param done fun(steps: Filetree.Ai.Step[])
local function pick_targets(view, steps, done)
  local i = 0
  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then return done(steps) end
    if not step.candidates then return next_step() end
    local items = {}
    for _, path in ipairs(step.candidates) do
      items[#items + 1] = rel(path, view.root)
    end
    require("filetree.util.select")(items, {
      prompt = ("Which %s? (%s)"):format(plan.shown(step.raw_target, 40), step.action),
    }, function(_, idx)
      if not idx then
        notify.info("ai: nothing done")
        return
      end
      step.target, step.candidates = step.candidates[idx], nil
      next_step()
    end)
  end
  next_step()
end

---What to do with the answer of the model.
---@param view Filetree.View
---@param ok boolean
---@param res any  `Ai.Response` or the error.
function M.answer(view, ok, res)
  if not ok then
    local msg = type(res) == "table" and (res.message or res.kind) or res
    notify.warn("ai: the request failed: " .. plan.shown(msg, 200))
    return
  end
  if not (view and view.actions) then return end
  local raw, why = plan.read(type(res) == "table" and res.text or nil)
  if not raw then
    if why and why:sub(1, 6) == "none: " then
      notify.info("ai: nothing in the tree does that: " .. why:sub(7))
    else
      notify.info("ai: refused, " .. why)
    end
    return
  end
  local env = M.env(view)
  local steps, reason = plan.check(raw, env)
  if not steps then
    notify.info("ai: refused, " .. reason)
    return
  end
  pick_targets(view, steps, function(picked)
    M.execute(view, picked)
  end)
end

-- ── asking ─────────────────────────────────────────────────────────────────────

---Why the policy of ai.nvim does not let the configured provider answer, or nil.
---@param ai table
---@return string|nil
local function policy_refuses(ai)
  if type(ai.policy) ~= "function" or not options.provider or options.provider == "auto" then
    return nil
  end
  local ok, policy = pcall(ai.policy)
  if not ok or type(policy) ~= "table" or type(policy.allowed) ~= "table" then return nil end
  if
    vim.tbl_contains(policy.allowed, options.provider)
    or vim.tbl_contains(policy.granted or {}, options.provider)
  then
    return nil
  end
  return ("provider %q is not allowed on this machine (ai.nvim policy: %s)"):format(
    options.provider,
    table.concat(policy.allowed, ", ")
  )
end

---Turn a sentence into tree actions.
---@param text string
---@param view? Filetree.View
---@return boolean asked
function M.ask(text, view)
  if not M.enabled() then
    notify.info("ai: off; turn it on with native.ai.enabled = true")
    return false
  end
  local ai = ai_nvim()
  if not ai then
    notify.info("ai: ai.nvim is not installed")
    return false
  end
  text = vim.trim(tostring(text or ""))
  if text == "" then
    notify.info("ai: ask what? :Filetree ask open init.lua as a vsplit")
    return false
  end
  view = view_of(view)
  if not view then
    notify.info('ai: the own tree (adapter = "native") is not open in this tab')
    return false
  end
  if pending then
    notify.info("ai: still waiting for the answer to " .. plan.shown(pending.text, 40))
    return false
  end
  local refused = policy_refuses(ai)
  if refused then
    notify.info("ai: " .. refused)
    return false
  end
  local env, items = M.env(view)
  local context = catalog.context(view, env.known, env.order)
  local request = {
    prompt = catalog.prompt(items, context, text),
    system = catalog.SYSTEM,
    -- nothing of ai.nvim's own context (buffer, selection, diagnostics): names and paths only
    context = {},
    provider = options.provider,
    model = options.model,
    timeout_ms = options.timeout_ms,
    temperature = 0,
  }
  local token = { text = text }
  pending = token
  notify.info("ai: asking about " .. plan.shown(text, 60))
  local ok, err = pcall(ai.ask, request, function(done, res)
    vim.schedule(function()
      if pending ~= token then return end
      pending = nil
      M.answer(view, done, res)
    end)
  end)
  if not ok then
    pending = nil
    notify.warn("ai: the request failed: " .. plan.shown(err, 200))
    return false
  end
  return true
end

---Ask for a sentence, then `ask` it.
---@param view? Filetree.View
function M.prompt(view)
  vim.ui.input({ prompt = "Ask the tree: " }, function(text)
    if text and vim.trim(text) ~= "" then M.ask(text, view) end
  end)
end

-- ── speaking ───────────────────────────────────────────────────────────────────

---@param view Filetree.View|nil
local function redraw_bar(view)
  if view and view.buf then require("filetree.native.bar").update(view) end
end

---@return boolean
function M.recording()
  return recording ~= nil
end

---Start a spoken request, or end the one that is being recorded.
---@param view? Filetree.View
---@return boolean started  false when it stopped one, or could not start.
function M.listen(view)
  if recording then
    recording.stop()
    return false
  end
  if not (M.enabled() and M.has_ai()) then
    notify.info("ai: off, or ai.nvim is not installed")
    return false
  end
  view = view_of(view)
  if not view then
    notify.info('ai: the own tree (adapter = "native") is not open in this tab')
    return false
  end
  local missing = M.voice_missing()
  if #missing > 0 then
    notify.info(
      "ai: cannot listen: " .. table.concat(missing, "; ") .. "; :Filetree ask <text> works"
    )
    return false
  end
  if transcribing then
    notify.info("ai: still turning the last recording into text")
    return false
  end
  local rec, err = require("filetree.native.ai.record").start(options.record, function(path, why)
    recording, recording_view = nil, nil
    redraw_bar(view)
    if not path then
      notify.info("ai: " .. tostring(why))
      return
    end
    M.transcribe(path, view)
  end)
  if not rec then
    notify.info("ai: " .. tostring(err))
    return false
  end
  recording, recording_view = rec, view
  notify.info(("ai: listening (%s); stops after a pause, or click again"):format(rec.tool))
  redraw_bar(view)
  return true
end

---A recording to text, and the text to `ask`. The recording is removed afterwards.
---@param path string
---@param view Filetree.View
function M.transcribe(path, view)
  local media = require("media")
  local ok, handle = pcall(media.transcribe, path, { cache = false }, function(transcript, err)
    vim.schedule(function()
      transcribing = nil
      pcall(vim.fn.delete, path)
      local text = type(transcript) == "table" and transcript.text or nil
      if type(text) ~= "string" or vim.trim(text) == "" then
        notify.info("ai: nothing understood" .. (err and (": " .. plan.shown(err, 120)) or ""))
        return
      end
      M.ask(text, view)
    end)
  end)
  if not ok then
    pcall(vim.fn.delete, path)
    notify.warn("ai: speech to text failed: " .. plan.shown(handle, 200))
    return
  end
  transcribing = type(handle) == "table" and handle or { cancel = function() end }
end

-- ── the view bar ───────────────────────────────────────────────────────────────

M.HL = { FiletreeBarMic = "WinBar", FiletreeBarMicOn = "DiagnosticError" }

---The microphone of the view bar: a click region and its width. Empty when there is nothing to click.
---@param view Filetree.View
---@return string item
---@return integer width
function M.button(view)
  if not (M.enabled() and options.button ~= false and M.has_ai() and voice()) then return "", 0 end
  local on = recording ~= nil and recording_view == view
  local nerd = vim.g.have_nerd_font == true
  local text = on and (nerd and " 󰍬 ● " or " rec ") or (nerd and " 󰍬 " or " mic ")
  return ("%%@v:lua.__filetree_ai_mic@%%#%s#%s%%X"):format(
    on and "FiletreeBarMicOn" or "FiletreeBarMic",
    text
  ),
    vim.fn.strdisplaywidth(text)
end

-- a click item of 'winbar' can name a global function only
_G.__filetree_ai_mic = function(_, _, button)
  if button ~= "l" then return end
  local win = vim.fn.getmousepos().winid
  if not win or win == 0 or not api.nvim_win_is_valid(win) then return end
  local view = require("filetree.native.view").of_buf(api.nvim_win_get_buf(win))
  if view then M.listen(view) end
end

-- ── setup ──────────────────────────────────────────────────────────────────────

---Take the keys out again (setup again, a change of backend, tests).
function M.reset()
  for _, off in ipairs(unregister) do
    pcall(off)
  end
  unregister = {}
  if recording then pcall(recording.stop) end
  if transcribing then pcall(transcribing.cancel) end
  recording, recording_view, transcribing, pending, voice_ready = nil, nil, nil, nil, nil
end

---@param opts? Filetree.Ai.Opts
function M.setup(opts)
  M.reset()
  options =
    vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), type(opts) == "table" and opts or {})
  if not M.enabled() or not M.has_ai() then return end
  for group, link in pairs(M.HL) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok then return end
  local keys = options.keys or {}
  unregister[#unregister + 1] = registry.action({
    name = "ai.ask",
    key = keys.ask or nil,
    desc = "Ask the tree in words: the request becomes actions of this tree (ai.nvim)",
    ai = false,
    run = function(_, ctx)
      M.prompt(ctx.tree)
    end,
  })
  if #M.voice_missing() == 0 then
    unregister[#unregister + 1] = registry.action({
      name = "ai.listen",
      key = keys.listen or nil,
      desc = "Speak to the tree: record until a pause (again: stop), then as ai.ask",
      ai = false,
      run = function(_, ctx)
        M.listen(ctx.tree)
      end,
    })
  end
end

-- ── health ─────────────────────────────────────────────────────────────────────

---The lines of `:checkhealth filetree` for this feature.
function M.health()
  if not M.enabled() then
    vim.health.info("native.ai: off (native.ai.enabled = false)")
    return
  end
  local ai = ai_nvim()
  if not ai then
    vim.health.warn("native.ai: on, but ai.nvim is not installed: no key, no button", {
      'Install "WKDSteve/ai.nvim"',
    })
    return
  end
  vim.health.ok("native.ai: on, ai.nvim found (:Filetree ask <text>)")
  local refused = policy_refuses(ai)
  if refused then
    vim.health.warn("native.ai: " .. refused)
  elseif type(ai.policy) == "function" then
    local okp, policy = pcall(ai.policy)
    if okp and type(policy) == "table" and type(policy.allowed) == "table" then
      vim.health.info("native.ai: ai.nvim policy allows " .. table.concat(policy.allowed, ", "))
    end
  end
  voice_ready = nil
  local missing = M.voice_missing()
  if #missing == 0 then
    local tool = require("filetree.native.ai.record").tool(options.record)
    vim.health.ok(("native.ai: speaking works (%s, media.nvim)"):format(tool))
  else
    vim.health.info("native.ai: no microphone: " .. table.concat(missing, "; "))
  end
end

return M
