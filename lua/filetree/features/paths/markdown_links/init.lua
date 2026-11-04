---@module 'filetree.features.paths.markdown_links'
---@brief Copy the current node (or a whole tree, or marked nodes) as Markdown links.
---@description
--- Every generated line is `[name](relative/path)`, joined with newlines and
--- written to both the "+" (system) and unnamed '"' registers, matching the
--- copy-to-clipboard convention used by path_copy/copy_file_list.
---
--- Keymaps (in tree buffer, default):
---   ML   Markdown link for the current node
---   MR   Markdown links for every file under the current node, recursively
---   MM   Markdown links for all marked nodes
---   MI   INSERT links (marked nodes if any, else the current one) into the
---        window you came from, instead of the clipboard, and put the cursor
---        into the first link -- its empty title, else its path -- in insert
---        mode (lib.nvim.markdown.link_cursor)
---
--- The link path of `MI` is spelled by `insert_path`: `"buffer"` (default,
--- relative to the TARGET buffer's directory, `./x` / `../x`), `"cwd"`,
--- `"absolute"` (the real path), or `"env"` (`$REPOS_DIR/…`, `$NVIM_CONFIG_DIR/…`, falling back
--- to `"buffer"` for a file under no known root).

local notify = require("filetree.util.notify").create("[filetree.markdown_links]")

local fs = require("filetree.util.fs")
local path_util = require("filetree.util.path")
local env_roots = require("filetree.util.env_roots")
local ignore = require("filetree.util.ignore")
local bind = require("filetree.util.bind")
local M = {}

---@type FiletreeMarkdownLinksConfig
local DEFAULTS = {
  enabled = false,
  keymap = "ML",
  keymap_recursive = "MR",
  keymap_from_marked = "MM",
  keymap_insert = "MI",
  insert_path = "buffer",
  env_roots = { "REPOS_DIR" },
  cursor = {},
}

---@type FiletreeMarkdownLinksConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.markdown_links` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  keymap_recursive = "keymap",
  keymap_from_marked = "keymap",
  keymap_insert = "keymap",
  insert_path = { "string", enum = { "buffer", "cwd", "absolute", "env" } },
  env_roots = { "table", of = "string" },
  cursor = "table",
}

---@type FiletreeAdapter?
local _adapter = nil

---The link text for `path`: its last segment. A trailing separator (`dir/`) must
---not leave the title empty -- `:t` of `dir/` is "".
---@param path string
---@return string
local function link_name(path)
  local trimmed = path:gsub("[/\\]+$", "")
  local name = vim.fn.fnamemodify(trimmed, ":t")
  return name ~= "" and name or path
end

---@param path string
---@return string  markdown link "[name](relative/path)"
local function to_link(path)
  local rel = vim.fn.fnamemodify(path_util.in_cwd(path), ":."):gsub("\\", "/")
  local name = link_name(path)
  return string.format("[%s](%s)", name, rel)
end

---@param lines string[]
local function copy_to_reg(lines)
  if #lines == 0 then
    notify.warn("No entries to copy")
    return
  end
  local text = table.concat(lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  notify.info(string.format("Copied %d markdown link(s)", #lines))
end

local function current_node()
  if not _adapter then return nil end
  local node = _adapter.get_current_node()
  if not node or not node.path then
    notify.warn("No current node")
    return nil
  end
  return node
end

---Markdown link for the current node, or one link per marked node when any
---are marked (same "marks if any, else current" idiom as copy_file_list /
---fileops' copy_move and trash) — `MM` (`link_from_marked`) stays as an
---explicit, marks-only alias.
function M.link_current()
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks and marks.count() > 0 then
    local lines = {}
    for _, path in ipairs(marks.get_marked()) do
      lines[#lines + 1] = to_link(path)
    end
    copy_to_reg(lines)
    return
  end

  local node = current_node()
  if not node then return end
  copy_to_reg({ to_link(node.path) })
end

---Markdown links for every file under the current node, recursively. If the
---current node is a file, falls back to a single link for that file.
function M.link_recursive()
  local node = current_node()
  if not node then return end

  if node.type ~= "directory" then
    copy_to_reg({ to_link(node.path) })
    return
  end

  local files = fs.collect_files((node.path:gsub("\\", "/")), ignore.predicate())
  local lines = {}
  for _, f in ipairs(files) do
    lines[#lines + 1] = to_link(f)
  end
  copy_to_reg(lines)
end

---The link target for `path` as written into the buffer `buf`, per `insert_path`.
---@param path string
---@param buf integer  The buffer the link goes into.
---@return string
local function insert_target(path, buf)
  local mode = _cfg.insert_path
  -- The real absolute path, like path_copy's `[a`: the `$NAME/rest` form is
  -- "env", asked for by name (it folds even with `env_roots.enable = false`).
  if mode == "absolute" then return path_util.slashify(path) end

  if mode == "env" then
    local rooted, name =
      env_roots.fold(path, { names = _cfg.env_roots, nvim_config = true, force = true })
    if name then return rooted end
  end

  if mode == "cwd" then
    return path_util.slashify(vim.fn.fnamemodify(path_util.in_cwd(path), ":."))
  end

  -- "buffer" (and the "env" fallback): relative to where the link will live.
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return path_util.slashify(vim.fn.fnamemodify(path_util.in_cwd(path), ":.")) end
  return path_util.dot_relative(path, vim.fn.fnamemodify(name, ":p:h"))
end

---The markdown links `paths` would produce for `buf` (one `[name](target)` each).
---@param paths string[]
---@param buf integer
---@return string[]
local function build_insert_links(paths, buf)
  local links = {}
  for _, path in ipairs(paths) do
    links[#links + 1] = string.format("[%s](%s)", link_name(path), insert_target(path, buf))
  end
  return links
end
M.build_insert_links = build_insert_links

---Insert markdown links into the window the tree was opened from: one per
---marked node when any are marked, else one for the current node. The cursor
---ends up in the first link (empty title, else path) in insert mode, per
---`cursor`/lib.nvim.markdown.link_cursor. Nothing is copied.
function M.insert_current()
  local paths ---@type string[]
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks and marks.count() > 0 then
    paths = marks.get_marked()
  else
    local node = current_node()
    if not node then return end
    paths = { node.path }
  end

  local fu_ok, find_usable = pcall(require, "lib.nvim.window.find_usable")
  local lc_ok, link_cursor = pcall(require, "lib.nvim.markdown.link_cursor")
  if not (fu_ok and lc_ok) or type(link_cursor.insert_links) ~= "function" then
    notify.warn("Inserting links needs a newer lib.nvim (markdown.link_cursor.insert_links)")
    return
  end

  -- The current window when the command was typed in the editor, the previous
  -- one when the key was pressed in the tree (older lib.nvim: previous only).
  local win = (find_usable.insertion_window or find_usable.previous_window)()
  if not win then
    notify.warn("No editor window to insert into")
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then
    notify.warn("The window you came from is not an editable file buffer")
    return
  end

  local links = build_insert_links(paths, buf)
  if link_cursor.insert_links(buf, win, links, _cfg.cursor) then
    notify.info(string.format("Inserted %d markdown link(s)", #links))
  else
    notify.warn("Could not insert the link(s)")
  end
end

---Markdown links for all marked nodes.
function M.link_from_marked()
  local ok, marks = require("filetree.features").load("marks")
  if not ok or not marks or marks.count() == 0 then
    notify.warn("No marked nodes")
    return
  end
  local lines = {}
  for _, path in ipairs(marks.get_marked()) do
    lines[#lines + 1] = to_link(path)
  end
  copy_to_reg(lines)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeMarkdownLinksConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("markdown_links", _cfg, {
    {
      name = "link",
      field = "keymap",
      rhs = M.link_current,
      desc = "markdown link for current node",
    },
    {
      name = "link_recursive",
      field = "keymap_recursive",
      rhs = M.link_recursive,
      desc = "markdown links recursively",
    },
    {
      name = "link_insert",
      field = "keymap_insert",
      rhs = M.insert_current,
      desc = "insert markdown link(s) into the editor window",
    },
    {
      name = "link_from_marked",
      field = "keymap_from_marked",
      rhs = M.link_from_marked,
      desc = "markdown links from marked nodes",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
