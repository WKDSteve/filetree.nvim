---@module 'filetree.features.fileops.smart_create'
--- Enhanced file/directory creation with clipboard paste and LuaLS templates.

local confirm_choice = require("filetree.util.confirm_choice")
local path = require("filetree.util.path")
local bufutil = require("filetree.util.buffer")
local window = require("filetree.util.window")
local place_cursor = require("filetree.util.place_cursor")
local M = {}

---@type FiletreeSmartCreateConfig
local DEFAULTS = {
  enabled = false,
  keymap = "a",
  -- LuaLS scaffolding for new files — all OFF by default (opt in per key):
  auto_module_annot = false, -- new .lua files get a `---@module '<derived>'` header
  auto_types_template = false, -- files under an `@types` path get `---@meta` + `---@module`
  auto_init_lua = false, -- creating a directory also creates init.lua (with the header)
  ask_clipboard = false, -- if the clipboard is non-empty, offer to paste it into the file
  notify_level = "verbose", -- "verbose" | "short" | "off" — success message verbosity
}

---@type FiletreeSmartCreateConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.smart_create` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  auto_module_annot = "boolean",
  auto_types_template = "boolean",
  auto_init_lua = "boolean",
  ask_clipboard = "boolean",
  notify_level = { "string", enum = { "verbose", "short", "off" } },
}
---@type FiletreeAdapter?
local _adapter = nil

local notify = require("filetree.util.notify").create("[filetree.smart_create]")
local bind = require("filetree.util.bind")

---@internal
---Find the lua/ root above a path.
---@param filepath string
---@return string?
local function find_lua_root(filepath)
  local cur = filepath
  while true do
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur then break end
    local candidate = parent .. "/lua"
    local stat = vim.uv.fs_stat(candidate)
    if stat and stat.type == "directory" then return candidate end
    cur = parent
  end
  return vim.fn.stdpath("config") .. "/lua"
end

---@internal
---Derive module path from an absolute file path.
---@param filepath string
---@return string
local function path_to_module(filepath)
  local lua_root = find_lua_root(filepath)
  if not lua_root then return filepath end
  local root_norm = path.slashify(lua_root):gsub("/?$", "/")
  local rel = path.slashify(filepath):gsub("^" .. vim.pesc(root_norm), "")
  return (rel:gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")) -- parens: gsub returns (str, count)
end

---Show a success notification for a created file/directory, at the
---configured verbosity: "verbose" (default) names what was created, "short"
---is little more than the path, "off" is silent.
---@internal
---@param kind "file"|"directory"
---@param target string  Absolute path of what was created.
local function notify_created(kind, target)
  local level = _cfg.notify_level or "verbose"
  if level == "off" then return end
  local rel = path.relative(target)
  if level == "short" then
    notify.info("Path: " .. rel)
  else
    notify.info("Created " .. kind .. ": " .. rel)
  end
end

---Open `filepath` for editing in a real editor window — never in the tree
---window itself. Loading a new buffer into the tree's own window fights neo-
---tree's window-management autocmds (and this plugin's own layout_guard),
---which can spiral into an autocmd storm that looks like Neovim hanging.
---@internal
---@return integer winid  The editor window now showing filepath.
local function open_editor_window()
  local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid()
  local win = bufutil.find_editor_win(tree_win)
  if not win then
    -- No editor window yet: open one next to the tree instead of editing here —
    -- on the side away from the tree, so a bare `:vsplit` following 'splitright'
    -- can't flip the sidebar to the other side of the screen.
    win = window.open_editor_window(_adapter) or vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  return win
end

---@internal
---Open `filepath` in an editor window and, when it does not exist yet, write
---it with `lines` -- also when `lines` is empty: only a file on disk shows up
---in the tree (and gets the tree cursor), and the success message says it was
---created. Opened through `:edit` so `BufNewFile` handlers still run, and
---whatever they put in is what gets written. An existing file is only opened,
---never overwritten with a template.
---
---A buffer still loaded for that name -- the file was deleted outside Neovim
---(`git checkout`, `rm`) while it was open -- is that old file's content, not
---a new one: written as "created", it brought the deleted text back. Unchanged
---since it was read, it is replaced by the new file's lines; with changes of
---the user's in it, nothing is written and the buffer is left as it is.
---@param filepath string
---@param lines string[]
---@return boolean created  false when nothing new was written.
---@return string|nil why  set when it was not written for another reason than the file existing
local function create_with_content(filepath, lines)
  local existed = vim.uv.fs_stat(filepath) ~= nil
  local old = vim.fn.bufnr(filepath)
  local stale = not existed and old > 0 and vim.api.nvim_buf_is_loaded(old)
  if stale and vim.bo[old].modified then
    open_editor_window()
    vim.cmd("buffer " .. old)
    return false, "a buffer with unsaved changes is open for it — left as it is, not created"
  end
  open_editor_window()
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  if existed then return false end
  -- Opened read-only (the swap-file prompt's "Open Read-Only"): another
  -- Neovim is editing it, so it is not ours to write.
  if vim.bo.readonly then
    return false, "opened read-only (another Neovim has a swap file for it) — not created"
  end
  if #lines > 0 or stale then vim.api.nvim_buf_set_lines(0, 0, -1, false, lines) end
  vim.cmd("write")
  return true
end

---@internal
---`create_with_content` plus the message for it.
---@param filepath string
---@param lines string[]
local function create_file(filepath, lines)
  local created, why = create_with_content(filepath, lines)
  if created then
    notify_created("file", filepath)
  elseif why then
    notify.warn(path.relative(filepath) .. ": " .. why)
  elseif _cfg.notify_level ~= "off" then
    notify.info("Already exists, opened: " .. path.relative(filepath))
  end
end

---@internal
---Build template lines for a new file.
---@param filepath string
---@param paste_clipboard boolean
---@return string[]
local function build_template(filepath, paste_clipboard)
  if paste_clipboard then
    local clip = vim.fn.getreg("+")
    if clip and clip ~= "" then return vim.split(clip, "\n", { plain = true }) end
  end

  local lines = {}

  -- LuaLS @types template
  if _cfg.auto_types_template and filepath:find("@types") then
    lines[#lines + 1] = "---@meta"
    local mod = path_to_module(filepath)
    lines[#lines + 1] = "---@module '" .. mod .. "'"
    lines[#lines + 1] = ""
    return lines
  end

  -- Module annotation for .lua files
  if _cfg.auto_module_annot and filepath:match("%.lua$") then
    local mod = path_to_module(filepath)
    lines[#lines + 1] = "---@module '" .. mod .. "'"
    lines[#lines + 1] = ""
  end

  return lines
end

---@internal
---Get the directory to create in (current node's dir or cwd).
---@return string dir
---@return FiletreeNode? dir_node  The node under the cursor when it is that directory.
local function resolve_parent_dir()
  if not _adapter then return path.slashify(vim.fn.getcwd()) end
  local node = _adapter.get_current_node()
  if not node then return path.slashify(vim.fn.getcwd()) end
  if node.type == "directory" then return path.slashify(node.path), node end
  return path.parent(node.path)
end

---How long to keep looking for the created node after the refresh, in ms
---(see `util.place_cursor`). A little longer than a reveal's: the refresh
---rescans the whole tree, not one branch.
---@type integer[]
local CURSOR_RETRY_MS = { 50, 100, 200, 400, 800 }

---Refresh the tree and put its cursor on what was just created.
---
---A bare refresh leaves the cursor on the node it was on -- with folders
---sorted first, a new folder lands lines above a file the cursor was on, so the
---cursor ended up "5-6 lines below" it. A folder created inside a collapsed one
---would not be rendered at all, so that one is opened first.
---
---The refresh puts the cursor back on the LINE it was on when it renders (neo-
---tree saves the line, not the node), also after the cursor was already moved
----- a path that was in the tree before it drew. So the cursor is held there
---through the retry schedule (`util.place_cursor`'s `hold`), and let go as soon
---as the user moves it.
---@internal
---@param target string  Absolute path of what was created (or its first new folder, see `first_new`).
---@param dir_node FiletreeNode?  The directory node it was created in, when the cursor was on it.
---@param hold FiletreePlaceCursorHold?  Where the tree cursor was before the create.
local function refresh_onto(target, dir_node, hold)
  if not _adapter then return end
  if dir_node and dir_node.is_expanded == false and _adapter.expand_node then
    pcall(_adapter.expand_node, dir_node)
  end
  local changed = require("filetree.util.changed")
  changed.emit("create", nil, target)
  -- the own tree reads the one folder the new entry lies in on that event; the others read everything
  changed.refresh(_adapter)
  place_cursor.when_rendered(function()
    return _adapter
  end, target, { delays = CURSOR_RETRY_MS, hold = hold, key = "smart_create" })
end

---@internal
---Where the tree cursor is now (line, and the node's path), nil without a tree window.
---@return FiletreePlaceCursorHold?
local function tree_line()
  local win = _adapter and _adapter.get_winid and _adapter.get_winid()
  if not (win and win > 0 and vim.api.nvim_win_is_valid(win)) then return nil end
  local node = _adapter.get_current_node and _adapter.get_current_node()
  return { line = vim.api.nvim_win_get_cursor(win)[1], path = node and node.path or nil }
end

---@internal
---The outermost folder of `target` below `parent` that does not exist yet, or
---`target` itself when only it is new. `a/b/c/` in a folder: the new folders
---below `a` are rendered collapsed, so the cursor goes to `a`, the one that
---shows up -- not to a `c` that never does.
---@param parent string
---@param target string
---@return string
local function first_new(parent, target)
  local base = vim.fs.normalize(parent, { expand_env = false }):gsub("/+$", "")
  if target:sub(1, #base + 1) ~= base .. "/" then return target end
  local cur = base
  for part in target:sub(#base + 2):gmatch("[^/]+") do
    cur = cur .. "/" .. part
    if not vim.uv.fs_stat(cur) then return cur end
  end
  return target
end

---Create a file or directory interactively.
function M.create()
  local parent, dir_node = resolve_parent_dir()

  -- Show the parent directory in the prompt (relative to cwd) rather than
  -- pre-filling the absolute path — the user only types the new name. Always
  -- displayed with "/" regardless of OS (see path.slashify).
  local display = path.relative(parent)
  if display == "" or display == "." then
    display = "./"
  else
    display = display .. "/"
  end

  require("ui.kit").input({
    title = "Create in " .. display .. "  (append / for a directory): ",
    -- Pre-filled when a plugin knows what belongs here (filetree.create_names),
    -- e.g. the next round folder in a casedesk case's assets/.
    default = require("filetree.create_names").suggest((parent:gsub("/+$", ""))),
    on_submit = function(input)
      if not input or input == "" then return end

      -- Sanitize immediately: the user may type "/" or "\" — both are accepted,
      -- and everything from here on uses "/" (see path.slashify).
      input = path.slashify(input)

      local is_dir = input:sub(-1) == "/"
      local name = input:gsub("/?$", "") -- strip trailing slash for ops

      -- Relative names are created inside the parent dir; an absolute path (or
      -- Windows drive path) is honoured as-is.
      local target
      if name:match("^/") or name:match("^%a:/") then
        target = name
      else
        target = parent .. "/" .. name
      end
      -- `./x`, `a//b`, `C:/` + `/x`, a lowercase drive: spelled the way the
      -- tree spells its paths, or the cursor never finds the node. No `$VAR`
      -- expansion: a `$` in a name is a character.
      target = vim.fs.normalize(target, { expand_env = false })
      local focus = first_new(parent, target)
      local hold = tree_line()

      if is_dir then
        -- Create directory
        local ok = vim.fn.mkdir(target, "p")
        if ok == 0 then
          notify.error("Failed to create directory: " .. target)
          return
        end
        notify_created("directory", target)

        -- Auto init.lua
        if _cfg.auto_init_lua then
          local init_path = target .. "/init.lua"
          create_with_content(init_path, build_template(init_path, false))
        end
      else
        -- Create file — ensure parent directory exists
        local dir = vim.fn.fnamemodify(target, ":h")
        vim.fn.mkdir(dir, "p")

        local paste = false
        -- No question for a file that is there: it is only opened, whatever
        -- the answer would be.
        if _cfg.ask_clipboard and not vim.uv.fs_stat(target) then
          local clip = vim.fn.getreg("+")
          if clip and clip ~= "" then
            confirm_choice(
              "Create " .. vim.fn.fnamemodify(target, ":t") .. " with:",
              { "Empty", "Paste clipboard" },
              function(choice)
                if not choice then return end
                paste = choice == "Paste clipboard"
                create_file(target, build_template(target, paste))
                refresh_onto(focus, dir_node, hold)
              end
            )
            return
          end
        end

        create_file(target, build_template(target, false))
      end

      refresh_onto(focus, dir_node, hold)
    end,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param cfg FiletreeSmartCreateConfig
---@param adapter FiletreeAdapter
function M.setup(cfg, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), cfg or {})
  _adapter = adapter

  bind.bind("smart_create", _cfg, {
    {
      name = "create",
      field = "keymap",
      rhs = function()
        M.create()
      end,
      desc = "smart create",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
