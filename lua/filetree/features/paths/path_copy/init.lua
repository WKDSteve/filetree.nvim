---@module 'filetree.features.paths.path_copy'
---@brief Copy the current node's path in various formats to the system clipboard.
---@description
--- Provides quick access to multiple path representations, all written to
--- both the "+" (system) register and the unnamed '"' register.
---
--- Formats:
---   absolute  /home/user/project/src/foo.lua  (the real path, never folded)
---   absolute_raw  the same (kept for `:Filetree copy absolute_raw`)
---   relative  src/foo.lua             (relative to cwd)
---   name      foo.lua                 (filename only)
---   dirname   /home/user/project/src  (parent directory)
---   uri       file:///home/user/...   (file:// URI)
---   line      src/foo.lua:42          (path + cursor line in tree win)
---   stem      foo                     (filename without extension)
---   project_root      /home/user/project        (detected project root, cwd-independent)
---   project_relative  src/foo.lua               (path relative to that root)
---   buffer_relative   ./ROADMAP.md              (relative to the OPEN buffer's directory)
---   env_rooted        $REPOS_DIR/foo.nvim/x.lua (absolute, with an env-var root folded in;
---                     $NVIM_CONFIG_DIR/lua/x.lua under stdpath("config"), see nvim_config_root)
---
--- `absolute`, `dirname` and `project_root` write the REAL absolute path, also
--- with the top-level `env_roots` option on: the `$NAME/rest` form has a key of
--- its own (`env_rooted`, `[e`), so asking for the absolute path means asking
--- for the real one. `env_rooted` folds under `$REPOS_DIR`, `$NVIM_CONFIG_DIR`
--- or a user-defined root, whatever `env_roots.enable` says.
---
--- Config:
---   enabled              boolean
---   keymap_pick          string?  Opens format picker (default nil, off).
---   keymap_abs           string?  Copy absolute path directly (default "[a").
---   keymap_dirname       string?  Copy absolute parent dir directly (default "]a").
---   keymap_name          string?  Copy name directly (default nil, off).
---   keymap_project_root  string?  Copy project root directly (default "[R").
---   keymap_project_rel   string?  Copy path relative to project root (default "]R").
---   keymap_buffer_rel    string?  Copy path relative to the open buffer (default "]b").
---   keymap_env_root      string?  Copy path with an env-var root (default "[e").
---   root_markers         string[]|false  Markers for the project-root walk (default {".git"}).
---   env_roots            string[]  Env vars tried for `env_rooted` (default { "REPOS_DIR" }).
---   nvim_config_root     boolean  `env_rooted` also tries `$NVIM_CONFIG_DIR`, backed by
---                                 `vim.fn.stdpath("config")` -- no environment variable of
---                                 that name needs to actually be set (default true).
---   notify               boolean  Show a notification after copying (default true).
---
--- Commands (via :Filetree dispatcher):
---   :Filetree copy absolute|absolute_raw|relative|name|dirname|uri|line|stem|project_root|project_relative|buffer_relative|env_rooted|pick

local notify = require("filetree.util.notify").create("[filetree.path_copy]")

local ui_select = require("filetree.util.select")
local bind = require("filetree.util.bind")
-- Copied paths follow the plugin's canonical separator, like everything else
-- the user sees -- see `build()` below.
local ftpath = require("filetree.util.path")
local env_roots = require("filetree.util.env_roots")
local find_root = require("lib.nvim.fs.find_root")
local lib_relpath = require("lib.nvim.fs.relpath")
local M = {}

---@type FiletreePathCopyConfig
local DEFAULTS = {
  enabled = false,
  keymap_pick = nil,
  keymap_abs = "[a",
  keymap_dirname = "]a",
  keymap_name = nil,
  keymap_project_root = "[R", -- copy absolute project root path
  keymap_project_rel = "]R", -- copy node path relative to project root
  keymap_buffer_rel = "]b", -- copy path relative to the buffer open in the editor
  keymap_env_root = "[e", -- copy absolute path with $REPOS_DIR-style root
  root_markers = { ".git" },
  env_roots = { "REPOS_DIR" },
  nvim_config_root = true, -- also fold in $NVIM_CONFIG_DIR (stdpath("config"))
  notify = true,
}

---@type FiletreePathCopyConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.path_copy` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap_pick = "keymap",
  keymap_abs = "keymap",
  keymap_dirname = "keymap",
  keymap_name = "keymap",
  keymap_project_root = "keymap",
  keymap_project_rel = "keymap",
  keymap_buffer_rel = "keymap",
  keymap_env_root = "keymap",
  root_markers = { "table|false", of = "string" },
  env_roots = { "table", of = "string" },
  nvim_config_root = "boolean",
  notify = "boolean",
}

---@type FiletreeAdapter?
local _adapter = nil

---Cached marker-based root finder. The shape was hand-copied here as
---`FiletreeRootFinder` before lib.nvim shipped `Lib.Fs.FindRoot` for it; the
---copy is what made every assignment from `find_root()` a type mismatch.
---nil when disabled via root_markers=false.
---@type Lib.Fs.FindRoot?
local _root_finder = nil

---Resolve the project root for `path` (falls back to cwd when unresolved).
---@param path string
---@return string
local function resolve_root(path)
  if _root_finder then
    local ok, root = pcall(_root_finder.find, path)
    if ok and root and root ~= "" then return root end
  end
  return vim.fn.getcwd()
end

-- ── Format builders ───────────────────────────────────────────────────────────

---Directory the *open buffer* lives in — the base a Markdown link written
---into that buffer resolves against.
---
---cwd is the wrong base for this and that is the whole point: with the cwd at
---the repo root, `docs/ROADMAP/ROADMAP.md` is right for a link written in the
---root README and wrong for one written in `docs/ROADMAP/Notes.md`, where the
---same file is `./ROADMAP.md`. So the base is the editor window's file, then
---the alternate file, and only then the cwd.
---@return string
local function editor_dir()
  local buffer = require("filetree.util.buffer")
  local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid() or nil
  if tree_win and tree_win <= 0 then tree_win = nil end

  local win = buffer.find_editor_win(tree_win)
  if win then
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if name ~= "" then return vim.fn.fnamemodify(name, ":p:h") end
  end

  -- No editor window in this tab (tree opened alone): the alternate file is
  -- the last thing that was edited, which is what the user still means by
  -- "the open buffer".
  --
  -- pcall'd because `expand("#:p")` THROWS E194 when there is no alternate
  -- file rather than returning "" -- which made the cwd fallback below
  -- unreachable in exactly the situation it was written for, and turned `]b`
  -- into an error for anyone who opens Neovim on a directory and copies
  -- before editing anything.
  local ok_alt, alt = pcall(vim.fn.expand, "#:p")
  if ok_alt and type(alt) == "string" and alt ~= "" then return vim.fn.fnamemodify(alt, ":h") end

  return vim.fn.getcwd()
end

local function current_node_path()
  if not _adapter then return nil end
  local node = _adapter.get_current_node()
  return node and node.path or nil
end

local function cursor_line()
  local winid = _adapter and _adapter.get_winid and _adapter.get_winid() or -1
  if winid > 0 and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_cursor(winid)[1]
  end
  return nil
end

---The real absolute path. Not folded into `$NAME/rest`: that is `env_rooted`.
---@param path string
---@return string
local function absolute(path)
  return path
end

---@type table<string, fun(path: string): string>
local FORMATS = {
  absolute = absolute,
  -- Older name of the same, from when `absolute` was folded.
  absolute_raw = absolute,
  relative = function(path)
    return vim.fn.fnamemodify(ftpath.in_cwd(path), ":.")
  end,
  name = function(path)
    return vim.fn.fnamemodify(path, ":t")
  end,
  dirname = function(path)
    return vim.fn.fnamemodify(path, ":h")
  end,
  stem = function(path)
    return vim.fn.fnamemodify(path, ":t:r")
  end,
  uri = function(path)
    local abs = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
    return "file://" .. (abs:sub(1, 1) == "/" and abs or "/" .. abs)
  end,
  line = function(path)
    -- Per-node line via the adapter's line map (needed once `path` can be one
    -- of several marked nodes, not just the one under the cursor); falls back
    -- to the window cursor for the single-node case, or when a marked node
    -- isn't currently rendered (e.g. inside a collapsed directory).
    local ln = _adapter and _adapter.get_node_line and _adapter.get_node_line(path)
    if not ln then ln = cursor_line() end
    local rel = vim.fn.fnamemodify(ftpath.in_cwd(path), ":.")
    return ln and (rel .. ":" .. ln) or rel
  end,
  -- Absolute path of the detected project root ([R). cwd-independent.
  project_root = function(path)
    return resolve_root(path)
  end,
  -- Relative to the directory of the buffer open in the editor (]b), in the
  -- `./x` / `../x` form a Markdown link target needs. See `editor_dir`.
  buffer_relative = function(path)
    return ftpath.dot_relative(path, editor_dir())
  end,
  -- Absolute, but with a configured env var folded back into the root ([e):
  -- `$REPOS_DIR/foo.nvim/x.lua` instead of `E:/repos/foo.nvim/x.lua`. Also
  -- tries `$NVIM_CONFIG_DIR` (stdpath("config")) unless `nvim_config_root`
  -- is turned off -- otherwise a node inside the Neovim config itself always
  -- fell through every `env_roots` entry (it typically lives nowhere near
  -- `$REPOS_DIR`) straight to the plain absolute path.
  -- The one format that folds -- even with `env_roots.enable = false`; the
  -- roots are the central `env_roots` ones plus this feature's own
  -- `env_roots` / `nvim_config_root`.
  env_rooted = function(path)
    return (
      env_roots.fold(path, {
        names = _cfg.env_roots or {},
        nvim_config = _cfg.nvim_config_root ~= false,
        force = true,
      })
    )
  end,
  -- Path relative to the project root (]R), independent of the current cwd.
  project_relative = function(path)
    local root = resolve_root(path)
    return lib_relpath(path, root)
  end,
}

local FORMAT_ORDER = {
  "absolute",
  "absolute_raw",
  "relative",
  "name",
  "dirname",
  "stem",
  "uri",
  "line",
  "project_root",
  "project_relative",
  "buffer_relative",
  "env_rooted",
}

-- ── Copy helper ───────────────────────────────────────────────────────────────

---Paths to copy: every marked node when any are marked, else just the node
---under the cursor — same "marks if any, else current" idiom as
---copy_file_list / fileops' copy_move and trash.
---@return string[]
local function get_targets()
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks and marks.count() > 0 then return marks.get_marked() end
  local path = current_node_path()
  return path and { path } or {}
end

---@internal
---One format's output for one path, in this plugin's canonical separator.
---
---Every format goes through here rather than each one having to remember.
---`fnamemodify`'s `:.` and `:h` hand back NATIVE separators on Windows the
---moment they touch a path, so `relative` put `src\foo.lua` on the clipboard
---while this module's own documented examples -- and `uri`, which always
---slashified -- show `src/foo.lua`. What lands in the clipboard is not an
---OS-shell invocation, the one case `util.path` exempts from the rule, so it
---follows the same convention as everything else the user sees.
---
---Applied at the exit rather than inside each builder: there are eleven of
---them, `pick()` renders its preview from the same strings, and a twelfth
---would otherwise start out wrong.
---@param fmt string
---@param path string
---@return string
local function build(fmt, path)
  return ftpath.slashify(FORMATS[fmt](path))
end

local function do_copy(fmt)
  if not FORMATS[fmt] then
    notify.warn("Unknown format: " .. fmt)
    return
  end

  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No node under cursor")
    return
  end

  local lines = {}
  for _, path in ipairs(targets) do
    lines[#lines + 1] = build(fmt, path)
  end
  local text = table.concat(lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)

  if _cfg.notify then
    if #lines == 1 then
      notify.info(string.format("[%s] %s", fmt, lines[1]))
    else
      notify.info(string.format("[%s] Copied %d path(s)", fmt, #lines))
    end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

for _, fmt in ipairs(FORMAT_ORDER) do
  M["copy_" .. fmt] = function()
    do_copy(fmt)
  end
end

function M.pick()
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No node under cursor")
    return
  end

  local built = {}
  for _, fmt in ipairs(FORMAT_ORDER) do
    -- `absolute_raw` is `absolute` under its old name: one row is enough.
    if fmt ~= "absolute_raw" then
      local lines = {}
      for _, path in ipairs(targets) do
        lines[#lines + 1] = build(fmt, path)
      end
      built[#built + 1] = { fmt = fmt, text = table.concat(lines, "\n") }
    end
  end

  ui_select(built, {
    prompt = "Copy path",
    format_item = function(item)
      return string.format("%-10s %s", item.fmt, (item.text:gsub("\n", " | ")))
    end,
  }, function(item)
    if not item then return end
    vim.fn.setreg("+", item.text)
    vim.fn.setreg('"', item.text)
    if _cfg.notify then notify.info(string.format("[%s] %s", item.fmt, item.text)) end
  end)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreePathCopyConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  -- Build the cached project-root finder unless disabled (root_markers = false).
  _root_finder = nil
  local markers = _cfg.root_markers
  if markers == nil then markers = { ".git" } end
  if markers ~= false then _root_finder = find_root({ markers = markers }) end

  bind.bind("path_copy", _cfg, {
    { name = "pick", field = "keymap_pick", rhs = M.pick, desc = "copy path (pick format)" },
    { name = "absolute", field = "keymap_abs", rhs = M.copy_absolute, desc = "copy absolute path" },
    {
      name = "dirname",
      field = "keymap_dirname",
      rhs = M.copy_dirname,
      desc = "copy absolute parent directory",
    },
    { name = "name", field = "keymap_name", rhs = M.copy_name, desc = "copy filename" },
    {
      name = "project_root",
      field = "keymap_project_root",
      rhs = M.copy_project_root,
      desc = "copy absolute project root",
    },
    {
      name = "project_relative",
      field = "keymap_project_rel",
      rhs = M.copy_project_relative,
      desc = "copy path relative to project root",
    },
    {
      name = "buffer_relative",
      field = "keymap_buffer_rel",
      rhs = M.copy_buffer_relative,
      desc = "copy path relative to the open buffer",
    },
    {
      name = "env_rooted",
      field = "keymap_env_root",
      rhs = M.copy_env_rooted,
      desc = "copy path with an env-var root ($REPOS_DIR/…)",
    },
  })
end

function M.teardown()
  _adapter = nil
  _root_finder = nil
end

return M
