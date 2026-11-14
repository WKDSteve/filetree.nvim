---@module 'filetree.util.markdown_refs'
--- Shared soft-dependency bridge to markdown.nvim's `find_references`,
--- plus a reference-rewriting helper. Used by `trash` (flag broken refs with
--- "REF!") and `smart_rename`/`rename_batch`/`copy_move` (rewrite refs to the
--- new path after a move).
---
---   local refs_util = require("filetree.util.markdown_refs")
---   local refs = refs_util.find(old_path)          -- {} if markdown.nvim absent
---   for _, r in ipairs(refs) do r.new_target = "REF!" end
---   refs_util.update(refs)                          -- rewrites ](target) -> ](new_target)
---
--- `new_target` is looked up per-ref (not passed once for the whole list) so a
--- single `update()` call can cover a batch of renames where different refs
--- point at different old paths that moved to different new paths.

-- Path separator normalization: `/` is the one separator anything user-facing
-- displays, and the form buffer-name comparisons key on.
local ftpath = require("filetree.util.path")

local M = {}

---Whether markdown.nvim (with the reference API) is installed. Call sites use
---this to stay fully synchronous when it isn't — there is nothing to prefetch,
---so no reason to defer a delete/rename/move by an event-loop tick.
---@return boolean
function M.available()
  local ok_md, md = pcall(require, "markdown")
  return ok_md and type(md.find_references) == "function"
end

---@internal
---Resolve the search root for a path: the nearest project root (via the
---project_root feature), or nil to let markdown.nvim default to cwd.
---@param path string
---@param opts? { root?: string }
---@return string|nil
local function resolve_root(path, opts)
  local root = opts and opts.root
  if root then return root end
  local ok_pr, project_root = require("filetree.features").load("project_root")
  if ok_pr and project_root and type(project_root.find) == "function" then
    local ok_find, found = pcall(project_root.find, vim.fn.fnamemodify(path, ":h"))
    if ok_find and type(found) == "string" then return found end
  end
  return nil
end

---Find markdown files referencing `path` (soft-dep on markdown.nvim). Returns
---{} when markdown.nvim isn't installed, or the search itself errors. This is
---the synchronous path (ripgrep-prefiltered inside markdown.nvim, so fast) —
---for delete, where refs must be known before the confirm popup appears.
---@param path string
---@param opts? { root?: string }  `root` defaults to the nearest project root.
---@return table[]  MarkdownFileRef[] — { file, line, target, display, base_dir, ... }
function M.find(path, opts)
  local ok_md, md = pcall(require, "markdown")
  if not ok_md or type(md.find_references) ~= "function" then return {} end
  local ok_refs, refs = pcall(md.find_references, path, { root = resolve_root(path, opts) })
  if not ok_refs or type(refs) ~= "table" then return {} end
  return refs
end

---Async variant of `find`. `callback` always fires (with {} on any failure/
---absence), scheduled on the main loop.
---@param path string
---@param opts? { root?: string }
---@param callback fun(refs: table[])
function M.find_async(path, opts, callback)
  local ok_md, md = pcall(require, "markdown")
  if not ok_md or type(md.find_references_async) ~= "function" then
    vim.schedule(function()
      callback({})
    end)
    return
  end
  local ok = pcall(
    md.find_references_async,
    path,
    { root = resolve_root(path, opts) },
    function(refs)
      callback(type(refs) == "table" and refs or {})
    end
  )
  if not ok then vim.schedule(function()
    callback({})
  end) end
end

---Start an async reference search NOW and return a handle whose `await(cb)`
---delivers the result — immediately if already done, else when it completes.
---
---This is the race-free prefetch primitive: kick it off the moment the user
---presses the keymap (while the file still exists on disk), let it run while
---they type a new name / navigate to a move target, and `await` it right
---before performing the rename/move. Because the destructive step happens
---only inside the await callback, the scan is always finished (with the file
---still present) before anything moves — no torn read.
---@param path string
---@param opts? { root?: string }
---@return { await: fun(cb: fun(refs: table[])) }
function M.prefetch(path, opts)
  local state = { done = false, refs = nil, waiters = {} }
  M.find_async(path, opts, function(refs)
    state.refs = refs
    state.done = true
    local waiters = state.waiters
    state.waiters = {}
    for _, w in ipairs(waiters) do
      w(refs)
    end
  end)
  return {
    await = function(cb)
      if state.done then
        cb(state.refs or {})
      else
        state.waiters[#state.waiters + 1] = cb
      end
    end,
  }
end

---Await a whole set of prefetch handles keyed by path, then call `cb` with a
---`{ [path] = refs }` map once every one has resolved.
---@param handles table<string, { await: fun(cb: fun(refs: table[])) }>
---@param cb fun(refs_by_path: table<string, table[]>)
function M.await_all(handles, cb)
  local pending, results = 0, {}
  for _ in pairs(handles) do
    pending = pending + 1
  end
  if pending == 0 then
    cb(results)
    return
  end
  for path, handle in pairs(handles) do
    handle.await(function(refs)
      results[path] = refs
      pending = pending - 1
      if pending == 0 then cb(results) end
    end)
  end
end

---Re-express a moved/renamed target in the same style the original link used
---(absolute stays absolute, `./x` → `./y`, `docs/x` → `docs/y`), via
---markdown.nvim's `retarget`. Falls back to a cwd-relative path when
---markdown.nvim is absent or errors.
---@param ref table   A MarkdownFileRef (carries the base info retarget needs).
---@param new_path string  New absolute path of the moved/renamed file.
---@return string
function M.retarget(ref, new_path)
  local ok_md, md = pcall(require, "markdown")
  if ok_md and type(md.retarget) == "function" then
    local ok_t, t = pcall(md.retarget, ref, new_path)
    if ok_t and type(t) == "string" and t ~= "" then return t end
  end
  return M.relative_target(new_path)
end

---The cwd-relative link target a moved/renamed file should be written as —
---the fallback when style-preserving `retarget` isn't available. Matches the
---convention `markdown_links` uses for generated links (`fnamemodify(path,
---":.")`).
---@param new_path string
---@return string
function M.relative_target(new_path)
  return (vim.fn.fnamemodify(new_path, ":."):gsub("\\", "/"))
end

---@internal
---Rewrite `](old_target)` → `](new_target)` on a single line for one ref.
---Content-verified: only changes the line if it actually still holds the exact
---`](r.target)` that was scanned, so a live buffer whose lines have drifted
---(unsaved edits above the ref) is never corrupted — a stale ref is skipped.
---@param line string|nil
---@param r table  MarkdownFileRef with `.new_target`
---@return string|nil  possibly-rewritten line; nil in, nil out
---@return boolean changed
local function apply_ref(line, r)
  if not line or not r.new_target then return line, false end
  local pattern = "%]%(" .. vim.pesc(r.target) .. "%)"
  local repl = "](" .. r.new_target:gsub("%%", "%%%%") .. ")"
  local new_line, n = line:gsub(pattern, repl)
  return new_line, n > 0
end

---@internal
---Find a loaded buffer whose name is `file` (separator-normalized compare so a
---forward-slash buffer name matches an OS-native path on Windows).
---@param file string
---@return integer|nil bufnr
local function open_buffer_for(file)
  local key = ftpath.slashify(file)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and ftpath.slashify(name) == key then return b end
    end
  end
  return nil
end

---Display-friendly, deduplicated, cwd-relative list of the files a set of
---refs point at — the ":.":modified path of each unique `r.file`, in order
---of first appearance. Shared by every call site that reports "N markdown
---reference(s) found in: <files>" (trash/smart_rename/rename_batch/copy_move).
---@param refs table[]  MarkdownFileRef[]
---@return string[]
function M.unique_files(refs)
  local seen, files = {}, {}
  for _, r in ipairs(refs) do
    -- `ftpath.relative` is this repo's display form: cwd-relative, home
    -- tildified, forward slashes on every OS. Hand-rolling it as
    -- `fnamemodify(":.")` -- which is what stood here -- returns native
    -- separators, so prompts and notifications listed `lua\proj\a.lua`. The
    -- dedup key is slashified for the same reason: two spellings of one file
    -- must not list it twice.
    local key = ftpath.slashify(r.file)
    if not seen[key] then
      seen[key] = true
      files[#files + 1] = ftpath.relative(r.file)
    end
  end
  return files
end

---Rewrite each ref's link target to its own `r.new_target` (must be set on
---every ref before calling — e.g. `"REF!"` for a delete, or a retargeted path
---for a rename/move). Grouped by file so each is touched at most once.
---
---When the referencing file is open in a buffer, its **buffer** is patched
---directly (not just the file on disk): Neovim does not auto-reload a buffer
---when its underlying file changes on disk until a checktime/autoread event
---fires, so a plain `writefile` would only show up after the user switched
---away and back. If that buffer had no unsaved changes, the patch is written
---straight back to disk (so it stays unmodified and in sync); if it did have
---unsaved changes, the buffer is left modified for the user to save, and disk
---is not touched (their edits win). Files not open anywhere are edited on disk.
---@param refs table[]  MarkdownFileRef[], each with `.new_target` set.
---@return integer files_changed
function M.update(refs)
  local by_file = {}
  for _, r in ipairs(refs) do
    by_file[r.file] = by_file[r.file] or {}
    table.insert(by_file[r.file], r)
  end

  local files_changed = 0
  for file, file_refs in pairs(by_file) do
    local bufnr = open_buffer_for(file)

    if bufnr then
      local was_modified = vim.bo[bufnr].modified
      local changed = false
      for _, r in ipairs(file_refs) do
        local line = vim.api.nvim_buf_get_lines(bufnr, r.line - 1, r.line, false)[1]
        local new_line, did = apply_ref(line, r)
        if did then
          vim.api.nvim_buf_set_lines(bufnr, r.line - 1, r.line, false, { new_line })
          changed = true
        end
      end
      if changed then
        files_changed = files_changed + 1
        if not was_modified then
          -- Persist without firing BufWritePre autocmds (formatters/trim etc.)
          -- so this stays a minimal, surgical edit; keeps the buffer unmodified.
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("silent noautocmd keepjumps write")
          end)
        end
      end
    else
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok and lines then
        local changed = false
        for _, r in ipairs(file_refs) do
          local new_line, did = apply_ref(lines[r.line], r)
          if did then
            lines[r.line] = new_line
            changed = true
          end
        end
        if changed then
          vim.fn.writefile(lines, file)
          files_changed = files_changed + 1
        end
      end
    end
  end
  return files_changed
end

return M
