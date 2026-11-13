---@module 'filetree.features.lsp.lsp_diagnostics'
--- Decorate tree nodes with LSP diagnostic counts via extmarks.
---
--- Subscribes to the DiagnosticChanged autocmd and recomputes error/warning
--- counts per file using vim.diagnostic.get(). Results are rendered as eol
--- virtual text on the matching tree node lines.
---
--- Default format:  the `icons` option, else the sign texts of vim.diagnostic.config(), before
--- each count, e.g. "✘ 2 ▲ 1"; E:2 W:1 where neither is set (configurable)
--- Highlight groups follow the severity (DiagnosticError, DiagnosticWarn).
---
--- Updates on DiagnosticChanged and when the tree buffer is entered.

local bufevents = require("filetree.util.bufevents")
local au = require("filetree.util.autocmd")
local lib_debounce = require("lib.nvim.debounce")
local notify = require("filetree.util.notify").create("[filetree.lsp_diagnostics]")
local M = {}

---Fallback prefixes of the default badge, for a severity without a sign text.
local FALLBACK_LABELS = { error = "E:", warning = "W:", hint = "H:", info = "I:" }

---Count key → severity name, as `vim.diagnostic.severity` spells it.
local SEVERITY_NAMES = { error = "ERROR", warning = "WARN", hint = "HINT", info = "INFO" }

---Badge order of the count keys.
local COUNT_KEYS = { "error", "warning", "hint", "info" }

---@internal
---`t` trimmed and followed by a space; nil for a non-string or a blank one.
---@param t any
---@return string?
local function as_label(t)
  if type(t) ~= "string" then return nil end
  t = vim.trim(t)
  return t ~= "" and t .. " " or nil
end

---@internal
---The prefix per severity, first non-blank of: the `icons` option, the sign
---text the user configured in `vim.diagnostic.config({ signs = { text = … } })`,
---`E:`/`W:`/`H:`/`I:`. `signs.text` may be keyed by severity number or name; a
---`signs` given as a function (per namespace/buffer) has no global answer, so
---it is skipped.
---@param icons? table<string, string>  the `icons` option
---@return table<string, string>
local function resolve_labels(icons)
  if type(icons) ~= "table" then icons = nil end
  local ok, dcfg = pcall(vim.diagnostic.config)
  local signs = ok and type(dcfg) == "table" and dcfg.signs
  local text = type(signs) == "table" and type(signs.text) == "table" and signs.text or nil
  -- FALLBACK_LABELS is only ever read, so the common case without either shares it.
  if not icons and not text then return FALLBACK_LABELS end
  local severity = vim.diagnostic.severity
  local labels = {}
  for key, name in pairs(SEVERITY_NAMES) do
    labels[key] = as_label(icons and icons[key])
      or as_label(text and (text[severity[name]] or text[name]))
      or FALLBACK_LABELS[key]
  end
  return labels
end

---Prefixes for the render in progress, resolved once per `M._render`.
---@type table<string, string>?
local _labels = nil

---@internal
---Default badge text, e.g. `✘ 2 ▲ 1` with icons or sign texts, `E:2 W:1`
---without; nil when there is nothing to show.
---@param counts { error: integer, warning: integer, hint: integer, info: integer }
---@return string?
local function default_format(counts)
  local labels = _labels or resolve_labels()
  local parts = {}
  for _, key in ipairs(COUNT_KEYS) do
    if counts[key] > 0 then parts[#parts + 1] = labels[key] .. counts[key] end
  end
  return #parts > 0 and table.concat(parts, " ") or nil
end

---Shipped defaults. Never mutated: every `setup()` merges onto a fresh copy, so
---an option dropped from the user's config falls back instead of lingering.
---@type FiletreeLspDiagnosticsConfig
local DEFAULTS = {
  enabled = false,
  show_errors = true,
  show_warnings = true,
  show_hints = false,
  show_info = false,
  format = default_format,
  debounce_ms = 300,
}

---@type FiletreeLspDiagnosticsConfig
local _cfg = DEFAULTS

---Option schema (see `filetree.config.schema`): exactly what
---`features.lsp_diagnostics` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  show_errors = "boolean",
  show_warnings = "boolean",
  show_hints = "boolean",
  show_info = "boolean",
  format = "function",
  icons = {
    "table",
    fields = { error = "string", warning = "string", hint = "string", info = "string" },
  },
  debounce_ms = { "number", min = 0 },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer  extmark namespace
local _ns = -1

---Unsubscribe handle for `_adapter.on_render`, when the adapter supports it.
---@type fun()|nil
local _unsubscribe_render = nil

-- ── Count aggregation ─────────────────────────────────────────────────────────

---@class DiagCounts
---@field error   integer
---@field warning integer
---@field hint    integer
---@field info    integer

---@type table<string, DiagCounts>  abs_path ("/"-normalised) → counts
local _counts = {}

---Directory path ("/"-normalised, no trailing slash) → counts of everything
---below it. Built once per `recompute()` so a render is O(lines), not
---O(directory lines × files with diagnostics).
---@type table<string, DiagCounts>
local _dir_counts = {}

---Whether the user's `format` already failed since `setup()` (warn only once).
local _format_warned = false

local sev = vim.diagnostic and vim.diagnostic.severity
  or {
    ERROR = 1,
    WARN = 2,
    INFO = 3,
    HINT = 4,
  }

---Buffer name ("/"-normalised) → its resolved path ("/"-normalised), or false when it resolves to
---itself. One fs_realpath per name, not per recompute (a name not on disk is not cached).
---@type table<string, string|false>
local _real = {}

---@internal
---The resolved spelling of `path` when it differs (a path through a symlink or a junction, macOS
---/var → /private/var), else nil. A backend such as neo-tree draws the tree from the resolved
---cwd, so a buffer opened through the link would otherwise never match its node.
---@param path string  "/"-normalised
---@return string?
local function resolved(path)
  local hit = _real[path]
  if hit == nil then
    local uv = vim.uv or vim.loop
    local real = uv.fs_realpath(path)
    real = real and real:gsub("\\", "/")
    if not real then return nil end -- not on disk (yet): ask again next time
    hit = real ~= path and real or false
    _real[path] = hit
  end
  return hit or nil
end

---@internal
local function recompute()
  local new_counts = {}
  ---File path → every key it is counted under (its buffer name and, if different, the resolved one).
  local spellings = {}
  local all = vim.diagnostic.get(nil)
  for _, d in ipairs(all) do
    local bufnr = d.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      -- Normalised to "/" so the lookup in M._render (which normalises the node
      -- path the same way) hits on Windows, where buffer names carry "\\".
      local path = vim.api.nvim_buf_get_name(bufnr):gsub("\\", "/")
      if path ~= "" then
        local c = new_counts[path]
        if not c then
          c = { error = 0, warning = 0, hint = 0, info = 0 }
          new_counts[path] = c
          spellings[path] = { path, resolved(path) }
        end
        if d.severity == sev.ERROR then
          c.error = c.error + 1
        elseif d.severity == sev.WARN then
          c.warning = c.warning + 1
        elseif d.severity == sev.HINT then
          c.hint = c.hint + 1
        elseif d.severity == sev.INFO then
          c.info = c.info + 1
        end
      end
    end
  end

  -- Fold every file's counts into each of its ancestor directories, under both spellings; a
  -- directory both spellings share (the link inside the project) gets the file once.
  local new_dirs = {}
  for path, pc in pairs(new_counts) do
    local seen = {}
    for _, spelling in ipairs(spellings[path]) do
      local dir = spelling:match("^(.*)/[^/]*$")
      while dir do
        local key = dir ~= "" and dir or "/"
        if not seen[key] then
          seen[key] = true
          local agg = new_dirs[key]
          if not agg then
            agg = { error = 0, warning = 0, hint = 0, info = 0 }
            new_dirs[key] = agg
          end
          agg.error = agg.error + pc.error
          agg.warning = agg.warning + pc.warning
          agg.hint = agg.hint + pc.hint
          agg.info = agg.info + pc.info
        end
        if dir == "" then break end
        dir = dir:match("^(.*)/[^/]*$")
      end
    end
  end
  -- The file nodes under the resolved spelling too (after the fold: counted once above).
  for path, list in pairs(spellings) do
    if list[2] and not new_counts[list[2]] then new_counts[list[2]] = new_counts[path] end
  end
  _counts = new_counts
  _dir_counts = new_dirs
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

---@internal
---@param counts DiagCounts
---@return string
local function sev_hl(counts)
  if counts.error > 0 then return "DiagnosticError" end
  if counts.warning > 0 then return "DiagnosticWarn" end
  if counts.hint > 0 then return "DiagnosticHint" end
  return "DiagnosticInfo"
end

---`bufnr`, when given, is the tree buffer to redraw -- passed by the adapter's
---`on_render` bridge with the tree pass that just rendered, so a second tree on
---another tab is never decorated by mistake. Omitted, the ambient lookup applies.
---@internal
---@param bufnr? integer
---The badges of the own tree's decorator: normalized path (file or folder) -> badge.
---@type table<string, { text: string, hl: string }>
local _badges = {}
---@type fun()|nil
local _emit = nil
---@type fun()|nil
local _unregister = nil

---What a set of counts is drawn as, after the `show_*` switches: text and highlight, or nil.
---@param c DiagCounts
---@return string|nil text
---@return string|nil hl
local function badge_of(c)
  local filtered = {
    error = _cfg.show_errors and c.error or 0,
    warning = _cfg.show_warnings and c.warning or 0,
    hint = _cfg.show_hints and c.hint or 0,
    info = _cfg.show_info and c.info or 0,
  }
  if filtered.error + filtered.warning + filtered.hint + filtered.info == 0 then return nil, nil end
  local format = type(_cfg.format) == "function" and _cfg.format or default_format
  _labels = format == default_format and resolve_labels(_cfg.icons) or nil
  local ok, text = pcall(format, filtered)
  if ok and type(text) == "string" and text ~= "" then return text, sev_hl(filtered) end
  if not ok and not _format_warned then
    _format_warned = true
    notify.warn("`format` raised an error, badges are not drawn: " .. tostring(text))
  end
  return nil, nil
end

---On the own tree: hand the counts to the tree as badges, files and folders alike (the folder sums
---are this module's own, so the decorator asks for no roll-up).
local function rebuild_badges()
  local norm = require("filetree.native.fs.list").norm
  local out = {}
  for _, counts in ipairs({ _dir_counts, _counts }) do
    for path, c in pairs(counts) do
      local text, hl = badge_of(c)
      if text then out[norm(path)] = { text = text, hl = hl } end
    end
  end
  _badges = out
  if _emit then _emit() end
end

function M._render(bufnr)
  if not _adapter then return end
  if _adapter.name == "native" then
    rebuild_badges()
    return
  end
  bufnr = bufnr or (_adapter.get_bufnr and _adapter.get_bufnr()) or -1
  if bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  if not _adapter.get_node_at_line then return end
  -- No diagnostics anywhere: nothing to draw, skip the per-line node walk.
  if next(_counts) == nil then return end

  local format = type(_cfg.format) == "function" and _cfg.format or default_format
  -- Read the sign texts on every render, so a later vim.diagnostic.config()
  -- shows up with the next redraw.
  _labels = format == default_format and resolve_labels(_cfg.icons) or nil
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for linenr = 0, line_count - 1 do
    local node = _adapter.get_node_at_line(bufnr, linenr)
    if node and node.path then
      local c
      local path = node.path:gsub("\\", "/")
      if node.type == "directory" then
        path = path:gsub("/+$", "")
        c = _dir_counts[path ~= "" and path or "/"]
      else
        c = _counts[path]
      end

      if c then
        local filtered = {
          error = _cfg.show_errors and c.error or 0,
          warning = _cfg.show_warnings and c.warning or 0,
          hint = _cfg.show_hints and c.hint or 0,
          info = _cfg.show_info and c.info or 0,
        }
        local total = filtered.error + filtered.warning + filtered.hint + filtered.info
        if total > 0 then
          -- A user `format` may throw or return nothing: no badge for that
          -- node, never an aborted render of the whole tree.
          local ok, text = pcall(format, filtered)
          if ok and type(text) == "string" and text ~= "" then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, linenr, -1, {
              virt_text = { { " " .. text, sev_hl(filtered) } },
              virt_text_pos = "eol",
              priority = 60,
            })
          elseif not ok and not _format_warned then
            _format_warned = true
            notify.warn("`format` raised an error, badges are not drawn: " .. tostring(text))
          end
        end
      end
    end
  end
end

-- ── Debounce ──────────────────────────────────────────────────────────────────

---Debounce handle built in M.setup() (needs `_cfg.debounce_ms`); `{ call, cancel }`.
---@type table?
local _debounce = nil

---@internal
local function do_update()
  recompute()
  M._render()
end

---@internal
local function schedule_update()
  if _debounce then _debounce.call() end
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreeLspDiagnosticsConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("keep", config, DEFAULTS)
  _adapter = adapter
  _format_warned = false
  _ns = vim.api.nvim_create_namespace("filetree_lsp_diagnostics")

  if _debounce then _debounce.cancel() end
  _debounce = lib_debounce.new(do_update, _cfg.debounce_ms)

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_lsp_diagnostics", true)

  au.acmd("DiagnosticChanged", {
    group = _augroup,
    desc = "[filetree] Re-draw the tree's diagnostic badges when diagnostics change",
    callback = schedule_update,
  })

  bufevents.register("lsp_diagnostics", { "BufEnter:tree", "BufWritePost:tree" }, {
    desc = "[filetree] Recount LSP diagnostics and re-draw the tree's badges",
    load = function()
      recompute()
      M._render()
    end,
  })

  -- ...and whenever the adapter re-renders the tree on ITS OWN schedule (git
  -- status landing, watcher event, follow_current_file, async scan finishing):
  -- a full content replace does not carry extmarks over, so without this the
  -- badges appear on focus and are gone after the next redraw. Counts are not
  -- recomputed here -- only the decoration is redrawn.
  if _unregister then _unregister() end
  _unregister = nil
  if adapter.name == "native" then
    _unregister = require("filetree.registry").decorator({
      name = "diagnostics",
      slot = "badge",
      priority = 60,
      get = function(path)
        return _badges[path]
      end,
      all = function()
        return _badges
      end,
      subscribe = function(emit)
        _emit = emit
        return function()
          _emit = nil
        end
      end,
    })
  end

  if _unsubscribe_render then pcall(_unsubscribe_render) end
  _unsubscribe_render = nil
  -- the own tree draws the decorator with every line: there is nothing to draw again after a render
  if adapter.name ~= "native" and type(adapter.on_render) == "function" then
    _unsubscribe_render = adapter.on_render(M._render)
  end

  -- Initial render after adapters set up
  vim.defer_fn(function()
    recompute()
    M._render()
  end, 500)
end

function M.teardown()
  bufevents.unregister("lsp_diagnostics")
  if _unregister then _unregister() end
  _unregister = nil
  _badges = {}
  if _unsubscribe_render then
    pcall(_unsubscribe_render)
    _unsubscribe_render = nil
  end
  if not _adapter then return end
  local bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or -1
  if bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  end
  _counts = {}
  _dir_counts = {}
  _real = {}
  _adapter = nil
  if _debounce then
    if _debounce then _debounce.cancel() end
    _debounce = nil
  end
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
