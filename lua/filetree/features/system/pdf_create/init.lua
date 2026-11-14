---@module 'filetree.features.system.pdf_create'
---@brief Create PDF(s) from the tree via pdfport.nvim (optional dependency).
---@description
--- The write-direction counterpart to pdf_open: turns image/markdown/text/
--- html/office file(s) under the cursor into PDF(s). Always asks first via
--- filetree.util.confirm (ui.kit) — unlike pdf_open (which only
--- reads), this writes new files to disk.
---
--- Targets, same gather order as trash/copy_move:
---   - marked nodes, if any are marked (see features.org.marks); a marked
---     directory expands to its own creatable direct children
---   - else the node under the cursor:
---       - a file        -> that one file
---       - a directory   -> every direct child file pdfport can turn into a
---                          PDF (non-recursive; subdirectories are skipped —
---                          "all files in the folder" means this folder's
---                          own files, not a recursive project-wide sweep)
---
--- One PDF is created PER input file (next to its source, `on_conflict =
--- "suffix"` by default) — not one merged PDF from a multi-file selection.
--- Files pdfport has no producer for (unknown kind, or the kind's fallback
--- chain has nothing available right now) are silently skipped and reported
--- in the summary, not treated as an error.
---
--- pdfport.nvim is a SOFT dependency (see filetree.util.pdf). Absent it, the
--- keymap is a no-op with a warning — filetree never requires pdfport just
--- to load.
---
--- Keymap (in tree buffer, default):
---   gP   Create PDF(s) from the current node/marks/folder, after confirming.

local pdf = require("filetree.util.pdf")
local notify = require("filetree.util.notify").create("[filetree.pdf_create]")
local ui_confirm = require("filetree.util.confirm")
local bind = require("filetree.util.bind")

local M = {}

---@type FiletreePdfCreateConfig
local DEFAULTS = {
  enabled = false,
  keymap = "gP",
  on_conflict = "suffix",
  confirm = true,
}

---@type FiletreePdfCreateConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.pdf_create` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  on_conflict = { "string", enum = { "overwrite", "suffix", "error" } },
  confirm = "boolean",
}

---@type FiletreeAdapter?
local _adapter = nil

---@internal Direct (non-recursive) child files of `dir` that pdfport can
---turn into a PDF right now. Subdirectories are skipped.
---@param dir string
---@return string[]
local function creatable_children(dir)
  local ok_ig, ignore = pcall(require, "filetree.util.ignore")
  local ignored = (ok_ig and ignore.predicate()) or function(_)
    return false
  end

  local out = {}
  for _, name in ipairs(vim.fn.readdir(dir) or {}) do
    if not ignored(name) then
      local path = dir .. "/" .. name
      if vim.fn.isdirectory(path) == 0 and pdf.can_create(path) then out[#out + 1] = path end
    end
  end
  table.sort(out)
  return out
end

---@internal Marked nodes if any (directories expand to their creatable
---direct children), else the current node resolved the same way.
---@return string[]
local function gather_paths()
  local ok_m, marks = require("filetree.features").load("marks")
  if ok_m and marks and marks.count() > 0 then
    local out = {}
    for _, p in ipairs(marks.get_marked()) do
      if vim.fn.isdirectory(p) == 1 then
        vim.list_extend(out, creatable_children(p))
      elseif pdf.can_create(p) then
        out[#out + 1] = p
      end
    end
    return out
  end

  if not _adapter then return {} end
  local node = _adapter.get_current_node()
  if not node then return {} end
  if node.type == "directory" then return creatable_children(node.path) end
  if pdf.can_create(node.path) then return { node.path } end
  return {}
end

---@internal Summarize a batch pdf.create() run and refresh the tree once,
---only when at least one PDF was actually written.
---@param results FiletreePdfCreateResult[]
local function report(results)
  local ok_count, err_count, skip_count = 0, 0, 0
  for _, r in ipairs(results) do
    if r.status == "ok" then
      ok_count = ok_count + 1
      if r.output then require("filetree.util.changed").emit("create", nil, r.output) end
    elseif r.status == "skipped" then
      skip_count = skip_count + 1
    else
      err_count = err_count + 1
    end
  end

  local parts = { string.format("Created %d PDF(s)", ok_count) }
  if err_count > 0 then parts[#parts + 1] = string.format("%d failed", err_count) end
  if skip_count > 0 then
    parts[#parts + 1] = string.format("%d skipped (unsupported)", skip_count)
  end
  notify.info(table.concat(parts, ", "))

  if ok_count > 0 then require("filetree.util.changed").refresh(_adapter) end
end

---@internal Run pdf.create() for `paths`, no further prompting.
---@param paths string[]
local function run(paths)
  pdf.create(paths, { on_conflict = _cfg.on_conflict, on_done = report })
end

---@internal First few basenames of `paths`, for the multi-file confirm body.
---@param paths string[]
---@param limit integer
---@return string[]
local function preview_lines(paths, limit)
  local lines = {}
  for i = 1, math.min(limit, #paths) do
    lines[#lines + 1] = "  " .. vim.fn.fnamemodify(paths[i], ":t")
  end
  if #paths > limit then lines[#lines + 1] = string.format("  ... (%d more)", #paths - limit) end
  return lines
end

---Create PDF(s) from the current node, marks, or folder — prompting first
---unless `confirm = false`.
function M.create()
  if not pdf.has_pdfport_create() then
    notify.warn("pdfport.nvim not installed (or has no create() API) — cannot create PDFs")
    return
  end

  local paths = gather_paths()
  if #paths == 0 then
    notify.warn("No file here pdfport can turn into a PDF")
    return
  end

  if _cfg.confirm == false then
    run(paths)
    return
  end

  if #paths == 1 then
    ui_confirm({
      title = " Create PDF ",
      question = string.format("Create a PDF from %s?", vim.fn.fnamemodify(paths[1], ":t")),
      on_choice = function(yes)
        if yes then run(paths) end
      end,
    })
    return
  end

  ui_confirm({
    title = " Create PDF ",
    body = preview_lines(paths, 5),
    question = string.format("Create %d PDF(s)?", #paths),
    on_choice = function(yes)
      if yes then run(paths) end
    end,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreePdfCreateConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("pdf_create", _cfg, {
    { name = "create", field = "keymap", rhs = M.create, desc = "create PDF (pdfport)" },
  })
end

function M.teardown()
  _adapter = nil
end

return M
