---@module 'filetree.util.buffer'
---@brief Buffer validation and window-context utilities.

local path = require("filetree.util.path")
local au = require("filetree.util.autocmd")

local M = {}

---Is `bufnr` one of the tree plugin's own buffers?
---
---Asks the active adapter for its filetypes instead of testing against a
---hardcoded pair. Eight features tested `ft == "neo-tree" or ft == "NvimTree"`
---inline -- ten copies of the same line -- which meant every one of them
---silently did nothing under netrw, oil or mini_files, all of which filetree
---otherwise supports. The adapters have declared their own `filetypes` the
---whole time.
---
---Falls back to the neo-tree/nvim-tree pair only when no adapter is resolved
---yet, which is what `tree_attach` already does for its FileType pattern.
---@param bufnr integer|nil  Defaults to the current buffer.
---@return boolean
function M.is_tree_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local ft = vim.bo[bufnr].filetype

  local ok, ft_mod = pcall(require, "filetree")
  local adapter = ok and type(ft_mod.adapter) == "function" and ft_mod.adapter() or nil
  local types = (adapter and type(adapter.filetypes) == "table" and #adapter.filetypes > 0)
      and adapter.filetypes
    or { "neo-tree", "NvimTree" }

  for _, t in ipairs(types) do
    if ft == t then return true end
  end
  return false
end

---Filetypes treated as tree/explorer windows — never valid editor targets.
---@type table<string, true>
M.TREE_FT = {
  ["neo-tree"] = true,
  ["NvimTree"] = true,
  ["netrw"] = true,
  ["oil"] = true,
  ["minifiles"] = true,
  ["filetree"] = true,
}

-- Buffer-validity cache. Deliberately a TTL + explicit-invalidation cache, NOT
-- `lib.nvim.memo` (which is pure LRU memoization): buffer validity changes over
-- time (a buffer can become unlisted, unreadable, or wiped without our seeing a
-- BufDelete), so results must expire (TTL) and be invalidatable — semantics memo
-- does not provide. Cleanup on deletion is the `BufDelete` autocmd below
-- (`M.invalidate`), not table GC: a plain integer bufnr is never a
-- collectible value, so `setmetatable(_cache, { __mode = "k" })` — tried
-- here previously — never actually dropped anything on its own.
---@type table<integer, {valid:boolean, timestamp:number}>
local _cache = {}

local CACHE_TTL = 1000 -- ms

---@type boolean
local _hooked = false

---Install the BufDelete autocmd that keeps the cache clean. Lazy (first cache
---write) so requiring this module has no side effect; nothing can be cached
---before that, so there is nothing to invalidate earlier.
local function ensure_hook()
  if _hooked then return end
  _hooked = true
  au.create("BufDelete", function(args)
    M.invalidate(args.buf)
  end, {
    -- Lowercase-prefixed like every other group here: `bindings.autocmds` picks
    -- this plugin's records out by a `^filetree` match on the group name, and
    -- `FiletreeBufferCache` fell straight through it.
    group = au.group("filetree_buffer_cache", true),
    desc = "[filetree] Drop a deleted buffer from the buffer cache",
  })
end

---Return true when bufnr is a valid, normal, listed file buffer with a readable path.
---@param bufnr integer|nil  0 or nil = current buffer.
---@return boolean
function M.is_valid_file_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local cached = _cache[bufnr]
  local now = (vim.uv or vim.loop).now()
  if cached and (now - cached.timestamp < CACHE_TTL) then return cached.valid end

  local valid = true
  if not vim.api.nvim_buf_is_valid(bufnr) then
    valid = false
  elseif not vim.api.nvim_buf_is_loaded(bufnr) then
    valid = false
  elseif vim.bo[bufnr].buftype ~= "" then
    valid = false
  elseif not vim.bo[bufnr].buflisted then
    valid = false
  else
    local name = vim.api.nvim_buf_get_name(bufnr)
    if not name or name == "" then
      valid = false
    elseif vim.fn.filereadable(name) ~= 1 then
      valid = false
    end
  end

  ensure_hook()
  _cache[bufnr] = { valid = valid, timestamp = now }
  return valid
end

---Invalidate cache entry for a buffer (e.g. on BufDelete).
---@param bufnr integer
function M.invalidate(bufnr)
  _cache[bufnr] = nil
end

---Return {buf, file, dir} for bufnr, or nil if the buffer is not a valid file.
---@param bufnr integer|nil
---@return {buf:integer, file:string, dir:string}|nil
function M.context(bufnr)
  if not M.is_valid_file_buffer(bufnr) then return nil end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  return { buf = bufnr, file = file, dir = vim.fn.fnamemodify(file, ":p:h") }
end

---True for a buffer that is exactly the shape of a stray, freshly-spawned
---[No Name] buffer: normal buftype, unnamed, listed, unmodified, empty.
---Deliberately state-based rather than tag-based, so it only ever matches the
---shape Neovim itself creates as a fallback — a buffer a plugin creates on
---purpose for scratch/temp input almost always sets `buftype` (e.g. "nofile",
---"acwrite") or `nobuflisted`, so it never matches here.
---@param bufnr integer
---@return boolean
function M.is_stray_no_name(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.bo[bufnr].buftype ~= "" then return false end
  if not vim.bo[bufnr].buflisted then return false end
  if vim.bo[bufnr].modified then return false end
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then return false end
  if vim.api.nvim_buf_line_count(bufnr) > 1 then return false end
  return (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == ""
end

---Find a real (named, listed, loaded, normal-buftype) buffer to redirect a
---stray [No Name] window to. Prefers the alternate buffer (`#`) so the window
---lands on "the next file", matching `close_for_path`'s own replacement
---policy. Deliberately only ever returns a *named* buffer — swapping one
---blank buffer for another blank one would defeat the point.
---@param exclude table<integer, true>  Buffer numbers to skip (e.g. the one just deleted).
---@return integer?
function M.find_named_buffer(exclude)
  local function usable(b)
    return b
      and b > 0
      and not exclude[b]
      and vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
      and vim.api.nvim_buf_get_name(b) ~= ""
  end
  local alt = vim.fn.bufnr("#")
  if usable(alt) then return alt end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if usable(b) then return b end
  end
  return nil
end

---Find the last window in the current tabpage that holds a valid file buffer.
---`exclude_win` is skipped (pass the tree's winid to exclude it).
---@param exclude_win integer|nil
---@return integer|nil bufnr, integer|nil winid
function M.find_last_normal_buffer(exclude_win)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for i = #wins, 1, -1 do
    local win = wins[i]
    if win ~= exclude_win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if M.is_valid_file_buffer(buf) then return buf, win end
    end
  end
  return nil, nil
end

---Find the most-recently-focused normal editor window: non-tree filetype,
---editable (`buftype == ""`), non-floating. Prefers the alternate window
---(`winnr("#")`), then falls back to the first matching window.
---Replaces the per-feature `find_adjacent_win()` / `find_editor_win()` helpers.
---@param exclude_win integer|nil  Window to skip (e.g. the tree window).
---@return integer|nil winid
function M.find_editor_win(exclude_win)
  local function is_editor(win)
    if not win or win == 0 or win == exclude_win then return false end
    if not vim.api.nvim_win_is_valid(win) then return false end
    if vim.api.nvim_win_get_config(win).relative ~= "" then return false end -- float
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= "" then return false end
    return not M.TREE_FT[vim.bo[buf].filetype]
  end

  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if is_editor(prev) then return prev end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if is_editor(win) then return win end
  end
  return nil
end

---Repoint every open buffer whose name is `old_path` (or nested under it, for
---a directory move/rename) to the corresponding path under `new_path`. Used
---after any on-disk move/rename (copy_move's cut+paste, rename_batch,
---smart_rename) so a stale buffer doesn't linger pointing at a path that no
---longer exists while a second, disconnected buffer gets created for the file
---at its new location.
---
---For an exact match: renames the buffer via `nvim_buf_set_name`. When the
---buffer has no unsaved changes, also does a silent `:edit!` to clear the
---"file changed on disk" state, matching what a normal external rename would
---leave behind. When the buffer IS modified, the rename alone is enough --
---content and undo history are untouched, and the next `:w` simply writes to
---the new path. Forcing a reload here would silently discard the user's
---unsaved edits.
---
---For a directory move/rename: any buffer nested under `old_path` (name
---starts with `old_path .. "/"`) gets that prefix replaced with `new_path`,
---preserving the relative sub-path -- covers every buffer open anywhere under
---a moved directory tree, not just a single file.
---
---Both `old_path`/`new_path` and every buffer name are normalized
---(forward-slash) before comparing: a path sourced from a tree adapter's
---node.path can use a different separator convention than
---`nvim_buf_get_name()` returns on Windows, which would otherwise make every
---comparison silently miss (the same class of bug fixed across all 5 tree
---adapters this session).
---
---Renaming onto a path that collides with an already-open, DIFFERENT buffer
---(Neovim raises E95 "buffer already exists") is caught and skipped with a
---warning rather than aborting the whole sweep.
---@param old_path string
---@param new_path string
---@return integer  count of buffers relocated
function M.relocate(old_path, new_path)
  local old_key = path.slashify(old_path)
  local new_key = path.slashify(new_path)
  local prefix = old_key .. "/"

  local count = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local key = path.slashify(name)
        local target
        if key == old_key then
          target = new_key
        elseif key:sub(1, #prefix) == prefix then
          target = new_key .. "/" .. key:sub(#prefix + 1)
        end

        if target then
          local was_modified = vim.bo[bufnr].modified
          local ok = pcall(vim.api.nvim_buf_set_name, bufnr, target)
          if ok then
            count = count + 1
            if not was_modified then
              pcall(vim.api.nvim_buf_call, bufnr, function()
                vim.cmd("edit!")
              end)
            end
          else
            local notify = require("filetree.util.notify").create("[filetree.buffer]")
            notify.warn(
              "could not relocate buffer to "
                .. target
                .. " (a different open buffer already uses that name)"
            )
          end
        end
      end
    end
  end
  return count
end

---Force-close every open buffer whose file is `path` (or, for a directory,
---nested anywhere under it) after that path has been sent to trash / deleted
---on disk, so no buffer lingers pointing at a file that no longer exists.
---
---Deliberately force-deletes (`force = true`), discarding any unsaved changes
---in a modified buffer: the backing file is already gone, so there is nothing
---left to save it back to, and leaving the buffer open just invites a confusing
---"E211: File no longer available" write later. (This matches the behavior of
---the neo-tree trash config this replaces.) Callers that want a softer policy
---should check `vim.bo[bufnr].modified` before trashing and prompt/skip.
---
---Both `path` and every buffer name are normalized to forward slashes before
---comparison — a path sourced from a tree adapter's node.path can use a
---different separator convention than `nvim_buf_get_name()` returns on Windows,
---which would otherwise make every comparison silently miss (the same
---separator-mismatch class of bug fixed across the adapters and in relocate()).
---
---Before deleting a buffer that is displayed in one or more windows, each of
---those windows is first switched to another real, listed file buffer (the
---alternate `#` when suitable, else any other loaded listed buffer). Otherwise
---Neovim, needing to keep the window open, would replace the deleted buffer
---with a fresh empty [No Name] buffer — which is not only pointless when other
---buffers exist, but also perturbs the window layout (e.g. a tree plugin
---repositioning around the new buffer). Only when NO other suitable buffer
---exists at all is the window left for Neovim's default [No Name] fallback.
---@param target_path string  Absolute path of the trashed/deleted file or directory.
---@return integer  count of buffers closed
function M.close_for_path(target_path)
  local slashify = require("filetree.util.path").slashify
  local key = slashify(target_path)
  local prefix = key .. "/"

  -- Collect the buffers to close.
  local doomed, doomed_set = {}, {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local bkey = slashify(name)
        if bkey == key or bkey:sub(1, #prefix) == prefix then
          doomed[#doomed + 1] = bufnr
          doomed_set[bufnr] = true
        end
      end
    end
  end
  if #doomed == 0 then return 0 end

  ---A real, listed, loaded file buffer that is NOT itself being deleted — a safe
  ---thing to show in a window whose buffer is about to go. Prefers a *named*
  ---file (so the window lands on an actual next file, per "focus the next
  ---available buffer"), trying the alternate `#` first, then any other named
  ---buffer, and only as a last resort an unnamed-but-existing listed buffer —
  ---which is still better than making Neovim spawn a brand-new [No Name].
  ---@return integer?
  local function replacement()
    local function usable(b)
      return b
        and b > 0
        and not doomed_set[b]
        and vim.api.nvim_buf_is_valid(b)
        and vim.api.nvim_buf_is_loaded(b)
        and vim.bo[b].buflisted
        and vim.bo[b].buftype == ""
    end
    local function named(b)
      return usable(b) and vim.api.nvim_buf_get_name(b) ~= ""
    end
    local alt = vim.fn.bufnr("#")
    if named(alt) then return alt end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if named(b) then return b end
    end
    -- No named file left — reuse any existing listed buffer rather than create one.
    if usable(alt) then return alt end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if usable(b) then return b end
    end
    return nil
  end

  local count = 0
  for _, bufnr in ipairs(doomed) do
    -- Re-point every window showing this buffer to a replacement first, so the
    -- delete below doesn't spawn a [No Name] to fill the vacated window.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        local repl = replacement()
        if repl then pcall(vim.api.nvim_win_set_buf, win, repl) end
      end
    end
    if pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) then count = count + 1 end
  end
  return count
end

return M
