---@module 'filetree.features.paths.copy_file_list'
---@brief Copy recursive file/directory lists of the current node to clipboard.

local M = {}

---@type FiletreeCopyFileListConfig
local _cfg = {}
---@type FiletreeAdapter?
local _adapter = nil

local notify = require("filetree.util.notify").create("[filetree.copy_file_list]")
local fs = require("filetree.util.fs")
local ignore = require("filetree.util.ignore")
local bind = require("filetree.util.bind")
local ftpath = require("filetree.util.path")

---`p` relative to `base`: `.` for `base` itself, `p` unchanged when it is not below `base`.
---@param p string
---@param base string  Forward slashes, no trailing one.
---@return string
local function strip_base(p, base)
  if p == base then return "." end
  local prefix = base .. "/"
  if p:sub(1, #prefix) == prefix then return p:sub(#prefix + 1) end
  return p
end

---The directory the paths collected under `target` are made relative to: the spelling of the cwd
---`target` uses (a symlink to it counts, see `filetree.util.path.cwd_alias`), else the cwd itself.
---Asked once per target, not per collected path.
---@param target string
---@return string
local function relative_base(target)
  return ftpath.cwd_alias(target) or (ftpath.slashify(vim.fn.getcwd()):gsub("/+$", ""))
end

---Recursively collect all file paths under a path. Skips `.git`,
---`node_modules`, etc. per the ignore_list feature (see filetree.util.ignore).
---@param path string
---@param relative boolean  If true, make paths relative to cwd.
---@return string[]
local function collect_files(path, relative)
  local raw = fs.collect_files((path:gsub("\\", "/")), ignore.predicate())
  if not relative then
    return vim.tbl_map(function(p)
      return p:gsub("\\", "/")
    end, raw)
  end
  local base = relative_base(path)
  return vim.tbl_map(function(p)
    return strip_base((p:gsub("\\", "/")), base)
  end, raw)
end

---Recursively collect all directory paths under a path (including root).
---Skips ignored subtrees; see `collect_files` above.
---@param path string
---@param relative boolean
---@return string[]
local function collect_dirs(path, relative)
  local raw = fs.collect_folders((path:gsub("\\", "/")), ignore.predicate())
  if not relative then
    return vim.tbl_map(function(p)
      return p:gsub("\\", "/")
    end, raw)
  end
  local base = relative_base(path)
  return vim.tbl_map(function(p)
    return strip_base((p:gsub("\\", "/")), base)
  end, raw)
end

---Write lines to clipboard and show notification.
---@param lines string[]
local function copy_to_reg(lines)
  if #lines == 0 then
    notify.warn("No entries found")
    return
  end

  local sep = _cfg.separator or "\n"
  local text = table.concat(lines, sep)
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)

  local limit = _cfg.preview_limit or 5
  local preview = {}
  for i = 1, math.min(limit, #lines) do
    preview[#preview + 1] = "  " .. lines[i]
  end
  if #lines > limit then preview[#preview + 1] = "  ... (" .. (#lines - limit) .. " more)" end

  notify.info(string.format("Copied %d path(s):\n%s", #lines, table.concat(preview, "\n")))
end

---Collect the paths to operate on: every marked node when any are marked,
---else just the node under the cursor. Same "marks if any, else current"
---idiom as `copy_move`/`trash` (fileops), applied here so `[f`/`]f`/`[F`/`]F`
---act on a multi-node selection instead of only ever the cursor's node.
---@return string[]
local function get_targets()
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks and marks.count() > 0 then return marks.get_marked() end
  if not _adapter then return {} end
  local node = _adapter.get_current_node()
  return node and node.path and { node.path } or {}
end

---@param targets string[]
---@param relative boolean
---@return string[]
local function collect_files_multi(targets, relative)
  local seen, out = {}, {}
  for _, path in ipairs(targets) do
    for _, f in ipairs(collect_files(path, relative)) do
      if not seen[f] then
        seen[f] = true
        out[#out + 1] = f
      end
    end
  end
  return out
end

---@param targets string[]
---@param relative boolean
---@return string[]
local function collect_dirs_multi(targets, relative)
  local seen, out = {}, {}
  for _, path in ipairs(targets) do
    local items
    if vim.fn.isdirectory(path) == 1 then
      items = collect_dirs(path, relative)
    else
      -- File node: contribute just its parent directory.
      local dir = vim.fn.fnamemodify(path, ":h"):gsub("\\", "/")
      if relative then dir = strip_base(dir, relative_base(path)) end
      items = { dir }
    end
    for _, d in ipairs(items) do
      if not seen[d] then
        seen[d] = true
        out[#out + 1] = d
      end
    end
  end
  return out
end

function M.copy_files_abs()
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No current node")
    return
  end
  copy_to_reg(collect_files_multi(targets, false))
end

function M.copy_files_rel()
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No current node")
    return
  end
  copy_to_reg(collect_files_multi(targets, true))
end

function M.copy_dirs_abs()
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No current node")
    return
  end
  copy_to_reg(collect_dirs_multi(targets, false))
end

function M.copy_dirs_rel()
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No current node")
    return
  end
  copy_to_reg(collect_dirs_multi(targets, true))
end

---Write `lines` to `path` (one per line), creating missing parent directories.
---@param path string
---@param lines string[]
---@return boolean ok
---@return string? err
function M.write_list(path, lines)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    local made = pcall(vim.fn.mkdir, dir, "p")
    if not made then return false, "cannot create " .. dir end
  end
  local wrote, rc = pcall(vim.fn.writefile, lines, path)
  if not wrote or rc ~= 0 then return false, "cannot write " .. path end
  return true
end

---The file list of `targets` (what `]f`/`[f` copy), for the specs and other callers.
---@param targets string[]
---@param relative boolean
---@return string[]
function M.files_for(targets, relative)
  return collect_files_multi(targets, relative)
end

---Save the relative file list of the marked nodes (else the node under the cursor) to a file.
---Asks for the target path (default `file-list.txt` in the cwd) and confirms before it overwrites.
function M.save_files()
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No current node")
    return
  end
  local lines = collect_files_multi(targets, true)
  if #lines == 0 then
    notify.warn("No entries found")
    return
  end
  local default = (vim.fn.getcwd():gsub("\\", "/"):gsub("/$", "")) .. "/file-list.txt"
  vim.ui.input(
    { prompt = "Save file list to: ", default = default, completion = "file" },
    function(input)
      if not input or input == "" then return end
      local path = vim.fs.normalize(input)
      local function write()
        local ok, err = M.write_list(path, lines)
        if ok then
          notify.info(("Saved %d path(s) to %s"):format(#lines, path))
        else
          notify.error(err or "write failed")
        end
      end
      if vim.fn.filereadable(path) == 0 then return write() end
      require("filetree.util.confirm")({
        title = " Overwrite ",
        body = { "  " .. path },
        question = "File exists. Overwrite?",
        on_choice = function(yes)
          if yes then write() end
        end,
      })
    end
  )
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type FiletreeCopyFileListConfig
local DEFAULTS = {
  keymap_files_abs = "[f",
  keymap_files_rel = "]f",
  keymap_dirs_abs = "[F",
  keymap_dirs_rel = "]F",
  keymap_save = false,
}

---Option schema (see `filetree.config.schema`): exactly what
---`features.copy_file_list` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap_files_abs = "keymap",
  keymap_files_rel = "keymap",
  keymap_dirs_abs = "keymap",
  keymap_dirs_rel = "keymap",
  keymap_save = "keymap",
  preview_limit = { "number", min = 0 },
  separator = "string",
}

---@param cfg FiletreeCopyFileListConfig
---@param adapter FiletreeAdapter
function M.setup(cfg, adapter)
  _cfg = vim.tbl_extend("force", DEFAULTS, cfg or {})
  cfg = _cfg
  _adapter = adapter

  bind.bind("copy_file_list", cfg, {
    {
      name = "files_abs",
      field = "keymap_files_abs",
      rhs = M.copy_files_abs,
      desc = "copy file list (abs)",
    },
    {
      name = "files_rel",
      field = "keymap_files_rel",
      rhs = M.copy_files_rel,
      desc = "copy file list (rel)",
    },
    {
      name = "dirs_abs",
      field = "keymap_dirs_abs",
      rhs = M.copy_dirs_abs,
      desc = "copy dir list (abs)",
    },
    {
      name = "dirs_rel",
      field = "keymap_dirs_rel",
      rhs = M.copy_dirs_rel,
      desc = "copy dir list (rel)",
    },
    {
      name = "save",
      field = "keymap_save",
      rhs = M.save_files,
      desc = "save file list to a file",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
