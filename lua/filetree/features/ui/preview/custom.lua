---@module 'filetree.features.ui.preview.custom'
---@brief Who else has a preview for the node under the cursor: its source, or a registered previewer.
---@description
--- The preview shows the file of a node. Two kinds of node have something better to show:
---
--- - a node of a source that knows more than its path: a failed test case shows its output, not the
---   spec file it lives in. The source says so with `preview(node, ctx)` (`Filetree.Source`).
--- - a file another plugin can draw: a frame of a video, the waveform of a recording. That plugin
---   registers a previewer (`Filetree.Previewer`): `match(node)` and `preview(node, ctx, done)`.
---
--- This module asks both, in that order, and hands back one answer (`Filetree.Preview.Result`):
--- lines to show, an image to hand to the image viewer, or one line that says why there is nothing.
--- It opens no window: showing the answer is `filetree.features.ui.preview`'s job.
---
--- Key responsibilities:
--- - `node(adapter)`: the node under the cursor as its source handed it over, and that source
--- - `resolve(node, source, ctx, cb)`: ask the source, then the previewers; `cb` at most once
--- - Only the newest question is answered: an answer for a node the cursor has left is dropped, and
---   the previewer that was still working is told (`cancel`)
--- - A previewer or a source that raises is named once and not asked again

local notify = require("filetree.util.notify").create("[filetree.preview]")

local M = {}

---@type table<string, true>  "previewer:<name>" / "source:<name>" that raised: not asked again
local broken = {}
--- Counts the questions: an answer belongs to the question that is still the newest.
local generation = 0
---@type fun()|nil  Tells the previewer of the newest question that nobody waits any more.
local cancel_running = nil

---@param key string
---@param what string
---@param err any
local function give_up(key, what, err)
  if broken[key] then return end
  broken[key] = true
  notify.warn(("%s failed and is not asked again: %s"):format(what, tostring(err)))
end

---Bring an answer into one of the three shapes, or nil when it is none.
---@param result any
---@param note? any  The second argument of `done(nil, "why")`.
---@return Filetree.Preview.Result|nil
local function shaped(result, note)
  if result == nil and type(note) == "string" and note ~= "" then return { note = note } end
  if type(result) ~= "table" then return nil end
  local title = type(result.title) == "string" and result.title or nil
  if type(result.image) == "string" and result.image ~= "" then
    return { image = result.image, title = title }
  end
  if type(result.lines) == "table" then
    local lines = {}
    for _, line in ipairs(result.lines) do
      -- a buffer line holds no line break
      for part in (tostring(line) .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = part
      end
    end
    return {
      lines = lines,
      filetype = type(result.filetype) == "string" and result.filetype or nil,
      title = title,
    }
  end
  if type(result.note) == "string" and result.note ~= "" then
    return { note = result.note, title = title }
  end
  return nil
end

---The registered previewers, highest priority first, registration order among equals.
---@return Filetree.Previewer[]
local function previewers()
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok then return {} end
  -- a lib.nvim that does not know the kind raises on it
  local listed, list = pcall(registry.list, "previewer")
  if not listed or type(list) ~= "table" then return {} end
  local order = {}
  for i, entry in ipairs(list) do
    order[i] = { entry = entry, at = i }
  end
  table.sort(order, function(a, b)
    local pa, pb = a.entry.priority or 0, b.entry.priority or 0
    if pa ~= pb then return pa > pb end
    return a.at < b.at
  end)
  return vim.tbl_map(function(item)
    return item.entry
  end, order)
end

---The node under the cursor of the tree, as its source handed it over, and the name of that source.
---On the own tree that is the node itself (a test case, a symbol, a file). Another backend knows
---files only: the node is made up from the path, so that a previewer can still be asked.
---@param adapter FiletreeAdapter?
---@return Filetree.Node|nil node
---@return string|nil source
function M.node(adapter)
  if not adapter then return nil, nil end
  if adapter.name == "native" and type(adapter.get_state) == "function" then
    local ok, view = pcall(adapter.get_state)
    if ok and type(view) == "table" and type(view.current) == "function" then
      local row = view:current()
      if not row or type(row.node) ~= "table" then return nil, nil end
      return row.node, view:source_of(row.id)
    end
  end
  local current = type(adapter.get_current_node) == "function" and adapter.get_current_node() or nil
  if type(current) ~= "table" or type(current.path) ~= "string" or current.path == "" then
    return nil, nil
  end
  return {
    id = current.path,
    label = current.name or vim.fn.fnamemodify(current.path, ":t"),
    kind = current.type == "directory" and "dir" or "file",
    path = current.path,
  },
    "files"
end

---Is there somebody to ask for this node? Cheap: table lookups and the `match` of the previewers.
---@param node Filetree.Node
---@param source string|nil
---@return boolean
function M.has(node, source)
  if source and source ~= "files" and not broken["source:" .. source] then
    local ok, registry = pcall(require, "lib.nvim.tree.registry")
    local entry = ok and registry.get("source", source) or nil
    if entry and type(entry.preview) == "function" then return true end
  end
  for _, entry in ipairs(previewers()) do
    if not broken["previewer:" .. entry.name] then
      local ok, matches = pcall(entry.match, node)
      if not ok then
        give_up("previewer:" .. entry.name, ("previewer %s (match)"):format(entry.name), matches)
      elseif matches == true then
        return true
      end
    end
  end
  return false
end

---Nobody waits for the answer of the question before any more.
function M.cancel()
  generation = generation + 1
  local cancel = cancel_running
  cancel_running = nil
  if cancel then pcall(cancel) end
end

---Ask the source of the node, then the previewers, for what to show. `cb` is called at most once, and
---never for a question that was replaced by a newer one or cancelled.
---@param node Filetree.Node
---@param source string|nil
---@param ctx Filetree.Preview.Ctx
---@param cb fun(result: Filetree.Preview.Result)
---@return boolean asked  false: nobody has a preview for this node, `cb` is never called.
function M.resolve(node, source, ctx, cb)
  M.cancel()
  local mine = generation

  if source and source ~= "files" and not broken["source:" .. source] then
    local ok_reg, registry = pcall(require, "lib.nvim.tree.registry")
    local entry = ok_reg and registry.get("source", source) or nil
    if entry and type(entry.preview) == "function" then
      local ok, answer = pcall(entry.preview, node, ctx)
      if not ok then
        give_up("source:" .. source, ("source %s (preview)"):format(source), answer)
      else
        local result = shaped(answer)
        if result then
          cb(result)
          return true
        end
      end
    end
  end

  for _, entry in ipairs(previewers()) do
    local key = "previewer:" .. entry.name
    if not broken[key] then
      local ok_match, matches = pcall(entry.match, node)
      if not ok_match then
        give_up(key, ("previewer %s (match)"):format(entry.name), matches)
      elseif matches == true then
        local answered = false
        local function done(answer, note)
          if answered then return end
          answered = true
          -- an answer may come from a callback of a job: the window is touched on the main loop
          vim.schedule(function()
            if mine ~= generation then return end
            cancel_running = nil
            cb(shaped(answer, note) or { note = ("%s has nothing to show"):format(entry.name) })
          end)
        end
        local ok, cancel = pcall(entry.preview, node, ctx, done)
        if not ok then
          give_up(key, ("previewer %s (preview)"):format(entry.name), cancel)
        else
          if not answered and type(cancel) == "function" then cancel_running = cancel end
          return true
        end
      end
    end
  end
  return false
end

---Forget who raised (tests, and a plugin that was fixed and loaded again).
function M.reset()
  M.cancel()
  broken = {}
end

return M
