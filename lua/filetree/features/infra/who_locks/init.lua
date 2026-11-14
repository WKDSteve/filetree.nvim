---@module 'filetree.features.infra.who_locks'
---@brief `:Filetree wholocks [path] [--json]` — diagnose a Windows file lock
---(EBUSY/EPERM/EACCES) on any path.
---@description
--- Run it right after a file operation failed with `EBUSY: resource busy or
--- locked`. It measures rather than guesses:
---
---   1. A live `uv.fs_rename` probe, so "is it locked *now*" is a fact.
---   2. The processes holding the file, via the Windows Restart Manager.
---   3. The `fs_event` watchers of this Neovim covering the file's folder: the own tree's
---      (`adapter = "native"`, read through `filetree.fs_state()`) and neo-tree's.
---
--- (1) and (2) live in `lib.nvim.cross.fs.lock`. What this module adds is (3),
--- and that it works on *any* path with no buffer needed: it tells a foreign
--- holder apart from a handle leaked inside this very Neovim, the one case no
--- retry can outwait. (3) sits here, next to `handle_guard` and
--- `watcher_quarantine`, because all three reach into neo-tree's `fs_watch`
--- internals — one place to fix when those change.
---
--- An open buffer is never the cause: Neovim closes a file after reading it and
--- keeps only its swap file open.
---
--- `--json` prints the same findings as one `vim.json.encode`d object.
--- `lib.nvim.cross.fs.lock.report` only produces text lines, so the JSON path
--- calls `probe`/`who` directly and assembles the object itself.

local notify = require("filetree.util.notify").create("[filetree.who_locks]")

local M = {}

local fn = vim.fn

---Reach neo-tree's watcher registry. The table is a module local, so it is
---only observable as an upvalue of the accessor neo-tree exposes.
---@return table<string, any>|nil
local function neotree_watchers()
  local ok, fs_watch = pcall(require, "neo-tree.sources.filesystem.lib.fs_watch")
  if not ok or type(fs_watch.show_watched) ~= "function" then return nil end
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fs_watch.show_watched, i)
    if not name then break end
    if name == "watchers" and type(value) == "table" then return value end
  end
  return nil
end

---Normalise a path for comparison (forward slashes, lower case, no trailing slash).
---@param p string
---@return string
local function norm(p)
  local s = tostring(p):gsub("\\", "/"):lower():gsub("/$", "")
  return s
end

---Watchers registered on the folder that contains `path`.
---@param path string
---@return { status: "not_loaded"|"unreachable"|"ok", total?: integer, entries?: table[] }
local function watcher_data(path)
  if not package.loaded["neo-tree"] then return { status = "not_loaded" } end
  local watchers = neotree_watchers()
  if not watchers then return { status = "unreachable" } end

  local dir = norm(fn.fnamemodify(path, ":p:h"))
  local entries, total = {}, 0
  for watched, w in pairs(watchers) do
    total = total + 1
    if norm(watched) == dir then
      entries[#entries + 1] = {
        folder = watched,
        references = (w and w.references) or vim.NIL,
        active = (w and w.active) or false,
        handle_open = (w and w.handle) ~= nil,
      }
    end
  end
  return { status = "ok", total = total, entries = entries }
end

---Human-readable counterpart of `watcher_data`.
---@param path string
---@return string[]
local function watcher_lines(path)
  local data = watcher_data(path)
  if data.status == "not_loaded" then
    return { "  neo-tree not loaded — cannot be the holder in this session" }
  end
  if data.status == "unreachable" then
    return { "  neo-tree loaded, but its watcher table is not reachable (internals changed?)" }
  end
  local lines = {
    ("  %d watched folder(s) total, %d covering this file's folder"):format(
      data.total,
      #data.entries
    ),
  }
  for _, e in ipairs(data.entries) do
    lines[#lines + 1] = ("  WATCHES THIS FOLDER: %s (references=%s, active=%s, handle=%s)"):format(
      e.folder,
      tostring(e.references),
      tostring(e.active),
      e.handle_open and "open" or "nil"
    )
  end
  return lines
end

---The own tree's watcher handles that hold the folder `path` lies in: a handle on that folder itself,
---or, where one handle watches a whole tree (Windows, macOS), a handle on a folder above it.
---@param path string
---@return { status: "inactive"|"off"|"ok", total?: integer, recursive?: boolean, entries?: table[], released?: table[] }
local function own_tree_data(path)
  local ok, state = pcall(function()
    return require("filetree").fs_state()
  end)
  if not ok or type(state) ~= "table" then return { status = "inactive" } end
  -- handles of a tree opened before the backend changed are still handles of this Neovim
  if not state.active and #state.watchers == 0 and #state.released == 0 then
    return { status = "inactive" }
  end
  if not state.watch and #state.watchers == 0 then return { status = "off" } end

  local dir = norm(fn.fnamemodify(path, ":p:h"))
  ---@param watched string
  ---@return boolean
  local function covers(watched)
    local w = norm(watched)
    return w == dir or (state.recursive and dir:sub(1, #w + 1) == w .. "/")
  end
  local entries, released = {}, {}
  for _, watcher in ipairs(state.watchers) do
    if covers(watcher.dir) then
      entries[#entries + 1] = {
        folder = watcher.dir,
        references = watcher.refs,
        same_folder = norm(watcher.dir) == dir,
        error = watcher.error or vim.NIL,
      }
    end
  end
  for _, watcher in ipairs(state.released) do
    if covers(watcher.dir) then
      released[#released + 1] = { folder = watcher.dir, references = watcher.refs }
    end
  end
  return {
    status = "ok",
    total = #state.watchers,
    recursive = state.recursive,
    entries = entries,
    released = released,
  }
end

---Human-readable counterpart of `own_tree_data`.
---@param path string
---@return string[]
local function own_tree_lines(path)
  local data = own_tree_data(path)
  if data.status == "inactive" then
    return { "  the own tree is not the active backend and holds no handle" }
  end
  if data.status == "off" then return { "  native.watch = false: the own tree holds no handle" } end
  local lines = {
    ("  %d handle(s) open (%s), %d holding this file's folder"):format(
      data.total,
      data.recursive and "one per root, watching everything below it" or "one per folder read",
      #data.entries
    ),
  }
  for _, e in ipairs(data.entries) do
    lines[#lines + 1] = ("  %s: %s (references=%d)"):format(
      e.same_folder and "WATCHES THIS FOLDER" or "WATCHES A FOLDER ABOVE",
      e.folder,
      e.references
    )
  end
  for _, e in ipairs(data.released) do
    lines[#lines + 1] = ("  released for a running operation: %s (references=%d)"):format(
      e.folder,
      e.references
    )
  end
  if #data.entries > 0 then
    lines[#lines + 1] =
      "  a file operation of filetree.nvim closes these first; an operation from outside does not"
  end
  return lines
end

---Diagnose `path` (default: the current buffer's file).
---@param path? string
---@param as_json? boolean
---@return nil
function M.run(path, as_json)
  path = (path and path ~= "") and fn.fnamemodify(fn.expand(path), ":p") or fn.expand("%:p")
  if path == "" then
    notify.warn("no file: pass a path or run this from a buffer with a file name")
    return
  end

  local ok_lock, lock = pcall(require, "lib.nvim.cross.fs.lock")
  if not ok_lock then
    notify.error("lib.nvim.cross.fs.lock unavailable — update lib.nvim")
    return
  end

  local bufnr = fn.bufnr(path)

  if as_json then
    local probe_ok, probe_err = lock.probe(path)
    ---@type table
    local report = {
      path = path,
      cwd = fn.getcwd(),
      exists = fn.filereadable(path) == 1,
      buffer = bufnr ~= -1 and { open = true, bufnr = bufnr, modified = vim.bo[bufnr].modified }
        or { open = false },
      probe = { renameable = probe_ok, error = probe_ok and vim.NIL or probe_err },
      watchers = watcher_data(path),
      own_tree = own_tree_data(path),
    }
    if not lock.supported() then
      report.holders = { supported = false }
      print(vim.json.encode(report))
      return
    end
    lock.who(path, function(holders, werr)
      report.holders = werr and { supported = true, error = werr }
        or { supported = true, list = holders }
      print(vim.json.encode(report))
    end)
    return
  end

  lock.report(path, function(lines)
    table.insert(lines, 2, "cwd:    " .. fn.getcwd())
    table.insert(
      lines,
      3,
      "buffer: "
        .. (
          bufnr ~= -1 and ("#%d, modified=%s"):format(bufnr, tostring(vim.bo[bufnr].modified))
          or "not open in any buffer"
        )
    )
    lines[#lines + 1] = ""
    lines[#lines + 1] = "own tree fs_event watchers:"
    vim.list_extend(lines, own_tree_lines(path))
    -- neo-tree's section only where neo-tree can be the holder: on the own tree with neo-tree not
    -- loaded it said "not loaded" and nothing else
    if package.loaded["neo-tree"] or own_tree_data(path).status == "inactive" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "neo-tree fs_event watchers:"
      vim.list_extend(lines, watcher_lines(path))
    end

    local text = table.concat(lines, "\n")
    notify.info(text)
    -- Also to :messages, so the block survives the notification timeout and
    -- can be yanked out for a bug report.
    print(text)
  end)
end

return M
