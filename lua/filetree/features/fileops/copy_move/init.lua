---@module 'filetree.features.fileops.copy_move'
--- Filesystem clipboard: stage files for copy or cut, then paste.
---
--- Works like a vim register for files. Stage one or more nodes for copy
--- or cut, then paste them into any directory node.
---
--- Multiple-file staging uses the marks feature: if files are marked when
--- c/x is pressed, all marked files are staged at once.
---
--- If any staged item's name already exists at the paste target, a
--- kit.confirm prompt asks how to resolve the whole batch before anything
--- is written: Overwrite / Keep both (auto-renamed) / Skip / Cancel. See
--- `paste_resolving_conflicts` and `find_conflicts`.
---
--- Keymaps (in tree buffer):
---   c      Stage current node for copy (or all marked)
---   x      Stage current node for cut  (or all marked)
---   p      Paste staged files into the directory of the current node
---   P      Show the current clipboard
---   X      Clear the current clipboard
---
--- Extmark: staged-for-copy nodes get a "C" indicator, cut nodes get "X".

local notify = require("filetree.util.notify").create("[filetree.copy_move]")

-- cwd-relative, forward-slash display form -- this repo's canonical way to
-- show a path in a message (see move/init.lua's identical use for the same
-- "Failed: src -> dst (reason)" shape). Named `ftpath`, not `path`: this file
-- already uses `path` as a parameter name for "the path under test" in
-- several local helpers below (is_symlink, etc.).
local ftpath = require("filetree.util.path")
local bufevents = require("filetree.util.bufevents")
local tree_attach = require("filetree.util.tree_attach")
local buffer = require("filetree.util.buffer")
local confirm_choice = require("filetree.util.confirm_choice")
local ui_confirm = require("filetree.util.confirm")
-- Destination-collision helpers (exists / remove_existing / unique_name) and
-- the shared move-with-retry, both also used by the `move` feature.
local conflict = require("filetree.util.conflict")
-- Case-insensitive-FS guard. On Windows/macOS a copy into a name that differs
-- from the source only by case can't produce a second entry, and the shared
-- "Overwrite" path would delete the source. See filetree.util.case_clash.
local case_clash = require("filetree.util.case_clash")
local mutate = require("filetree.util.mutate")
-- Cross-file references after a cut+paste (= move). Copies never break one,
-- so only cuts are ever scanned — see filetree.refs.
local refs = require("filetree.refs")
-- Optional: progress indicator for a multi-item paste. No-op (returns nil)
-- when lib.nvim isn't installed.
local progress = require("filetree.util.progress")

-- Central FS-mutation chokepoint (libuv-based, no shell). Retries transient
-- Windows sharing errors (EPERM/EACCES/EBUSY) that a raw uv.fs_copyfile would
-- surface as a hard failure — see the handle_guard plan.
local fsops = require("lib.nvim.cross.fs.mutate")
local bind = require("filetree.util.bind")
local hooks = require("filetree.util.hooks")

local M = {}

---@type FiletreeCopyMoveConfig
local DEFAULTS = {
  enabled = false,
  keymaps = {
    copy = "c",
    cut = "x",
    paste = "p",
    show = "P",
    clear = "X",
  },
  confirm = false,
  use_safety = true,
  dry_run = false,
}

---@type FiletreeCopyMoveConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.copy_move` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymaps = {
    "table",
    fields = {
      copy = "keymap",
      cut = "keymap",
      paste = "keymap",
      show = "keymap",
      clear = "keymap",
    },
  },
  confirm = "boolean",
  use_safety = "boolean",
  dry_run = "boolean",
  -- Deprecated per-feature reference options: `config/init.lua`'s
  -- apply_legacy_refs() migrates them into the central `refs` block.
  check_markdown_refs = "boolean",
  refs_picker_prefer = { "string", enum = { "auto", "telescope", "fzf-lua", "quickfix" } },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer  extmark namespace
local _ns = -1

---@alias ClipboardOp "copy"|"cut"

---@class ClipboardEntry
---@field path string
---@field op   ClipboardOp

---@type ClipboardEntry[]
local _clipboard = {}

-- Sentinel: an entry the user chose to skip while resolving a case-only
-- collision in the pre-paste prompt (see `resolve_case_clashes`).
local SKIP = {}

---Reference scan for the staged cut items, started at stage time so it
---overlaps with the user navigating to the paste target.
---@type { await: fun(cb: fun(result: FiletreeRefScanResult)) }|nil
local _cut_prefetch = nil

-- ── Clipboard state ───────────────────────────────────────────────────────────

---@internal
local function clear_marks()
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks then marks.clear_all() end
end

---@internal
local function get_targets()
  -- Prefer marks if any are set
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks and marks.count() > 0 then return marks.get_marked() end
  -- Fall back to current node
  if not _adapter then return {} end
  local node = _adapter.get_current_node()
  return node and { node.path } or {}
end

---The own tree's decorator for the staged clipboard; nil on every other backend.
---@type Filetree.Decorate.Paths|nil
local _decor = nil

---@internal
local function render_clipboard()
  if not _adapter then return end
  if _decor then
    local map = {}
    for _, e in ipairs(_clipboard) do
      map[e.path] = e.op == "copy" and { text = "C", hl = "DiagnosticHint" }
        or { text = "X", hl = "DiagnosticWarn" }
    end
    _decor.set(map)
    return
  end
  local bufnr = _adapter.get_bufnr and _adapter.get_bufnr() or -1
  if bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  if #_clipboard == 0 then return end

  -- Build lookup
  local staged = {}
  for _, e in ipairs(_clipboard) do
    staged[e.path] = e.op
  end

  if not _adapter.get_node_at_line then return end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for linenr = 0, line_count - 1 do
    local node = _adapter.get_node_at_line(bufnr, linenr)
    if node then
      local op = staged[node.path]
      if op then
        local text = op == "copy" and " C" or " X"
        local hl = op == "copy" and "DiagnosticHint" or "DiagnosticWarn"
        pcall(vim.api.nvim_buf_set_extmark, bufnr, _ns, linenr, -1, {
          virt_text = { { text, hl } },
          virt_text_pos = "eol",
          priority = 80,
        })
      end
    end
  end
end

-- ── Stage ─────────────────────────────────────────────────────────────────────

---@param op ClipboardOp
function M.stage(op)
  local paths = get_targets()
  if #paths == 0 then
    notify.warn("no node selected")
    return
  end
  _clipboard = {}
  for _, p in ipairs(paths) do
    _clipboard[#_clipboard + 1] = { path = p, op = op }
  end

  -- For a cut (= move), start the reference scan NOW, while the sources still
  -- exist, so it overlaps with the time the user spends navigating to the
  -- paste target. Copies never break a reference (the original stays put), so
  -- only cuts prefetch. See refs.prefetch.
  _cut_prefetch = op == "cut" and refs.prefetch(paths, { op = "move" }) or nil

  clear_marks()
  render_clipboard()
  local verb = op == "copy" and "Copied" or "Cut"
  notify.info(string.format("%s %d item(s) to clipboard", verb, #paths))
end

function M.stage_copy()
  M.stage("copy")
end
function M.stage_cut()
  M.stage("cut")
end

function M.clear()
  _clipboard = {}
  _cut_prefetch = nil -- nothing staged to move, so its reference scan is moot
  render_clipboard()
  notify.info("Clipboard cleared")
end

function M.show()
  if #_clipboard == 0 then
    notify.info("Clipboard is empty")
    return
  end
  local lines = { string.format("Clipboard (%d items):", #_clipboard), "" }
  for _, e in ipairs(_clipboard) do
    lines[#lines + 1] =
      string.format("  [%s] %s", e.op:upper():sub(1, 1), vim.fn.fnamemodify(e.path, ":~"))
  end
  notify.info(table.concat(lines, "\n"))
end

-- ── Paste ─────────────────────────────────────────────────────────────────────

---@internal
---Clipboard entries whose name would collide with an existing entry of
---`dst_dir` if pasted as-is. Purely a preflight check -- the authoritative
---existence check happens again at execution time in `do_paste_impl`, right
---before each item is actually written.
---@param dst_dir string
---@return ClipboardEntry[]
local function find_conflicts(dst_dir)
  local conflicts = {}
  for _, e in ipairs(_clipboard) do
    if conflict.exists(dst_dir .. "/" .. vim.fn.fnamemodify(e.path, ":t")) then
      conflicts[#conflicts + 1] = e
    end
  end
  return conflicts
end

---@internal
---Whether `path` is itself a symlink (not whatever it points to).
---`vim.fn.isdirectory()`/`filereadable()` both follow a link transparently,
---so this is the one place below that needs `fs_lstat` instead.
---@param path string
---@return boolean
local function is_symlink(path)
  local lst = (vim.uv or vim.loop).fs_lstat(path)
  return lst ~= nil and lst.type == "link"
end

---@internal
---Recreate the symlink at `src` as a new symlink at `dst`, pointing at the
---same (possibly relative) target, instead of letting a plain file/directory
---copy dereference it. Two reasons this matters, not just fidelity: a
---dereferenced *directory* symlink would deep-copy whatever it points at
---(potentially huge, and unboundedly recursive through a symlink cycle —
---`copy_dir` below has no cycle guard because a real directory tree cannot
---contain one), and a dereferenced *file* symlink silently turns a link into
---an independent full copy of its target's content.
---@param src string
---@param dst string
---@return boolean ok
---@return string? err  libuv-style failure reason, when not ok
local function copy_symlink(src, dst)
  local target = (vim.uv or vim.loop).fs_readlink(src)
  if not target then return false, "could not read the symlink's own target" end
  return fsops.symlink(target, dst, vim.fn.isdirectory(src) == 1)
end

---@internal
---Recursively copy a directory tree without shelling out (shell-agnostic:
---works identically whether &shell is cmd.exe, PowerShell, or a POSIX shell).
---@param src string
---@param dst string
---@return integer rc   0 on success, 1 on any failure
---@return string? err  libuv-style failure reason of whichever entry failed first
local function copy_dir(src, dst)
  if vim.fn.mkdir(dst, "p") == 0 then return 1, "could not create directory: " .. dst end
  for _, name in ipairs(vim.fn.readdir(src)) do
    local s = src .. "/" .. name
    local d = dst .. "/" .. name
    if is_symlink(s) then
      local ok, err = copy_symlink(s, d)
      if not ok then return 1, err end
    elseif vim.fn.isdirectory(s) == 1 then
      local rc, err = copy_dir(s, d)
      if rc ~= 0 then return rc, err end
    else
      local ok, err = fsops.copy_file(s, d)
      if not ok then return 1, err end
    end
  end
  return 0, nil
end

---@internal
---Copy `src` to the already-resolved destination `dst` -- no collision
---handling here, the caller has already decided how to deal with an
---existing target before calling this.
---@param src string
---@param dst string
---@return integer rc   0 on success, 1 on failure
---@return string? err  libuv-style failure reason, when rc == 1 -- e.g. the
---  same kind of Windows sharing lock `do_move` now reports (see that
---  function's own doc comment); a copy can hit it exactly the same way.
local function do_copy_impl(src, dst)
  if is_symlink(src) then
    local ok, err = copy_symlink(src, dst)
    return ok and 0 or 1, err
  end
  if vim.fn.isdirectory(src) == 1 then return copy_dir(src, dst) end
  local ok, err = fsops.copy_file(src, dst)
  return ok and 0 or 1, err
end

---@internal
---`do_copy_impl` announcing itself on the `hooks_api` bus: `before_copy`, then
---`after_copy` with the outcome.
---@param src string
---@param dst string
---@return integer rc
---@return string? err
local function do_copy(src, dst)
  hooks.emit("before_copy", { src = src, dst = dst })
  local rc, err = do_copy_impl(src, dst)
  hooks.emit("after_copy", { src = src, dst = dst, ok = rc == 0 })
  return rc, err
end

---@internal
---Move `src` to the already-resolved destination `dst`.
---@param src string
---@param dst string
---@return integer rc    0 on success, 1 on failure
---@return string? dst   the destination path actually used, when rc == 0
---@return string? err   the libuv-style failure reason, when rc == 1 (e.g. a
---  Windows sharing lock that outlasted `mutate.move`'s own retries — a
---  file-explorer window, an indexer or an AV scan still holding the source
---  open — see the "silent no-op" bug this return value fixes below)
local function do_move(src, dst)
  -- Windows sharing-lock retry and the cross-drive EXDEV fallback both live in
  -- util.mutate, shared with rename_batch/move/smart_rename.
  hooks.emit("before_move", { src = src, dst = dst })
  local ok, err = mutate.move(src, dst)
  hooks.emit("after_move", { src = src, dst = dst, ok = ok == true })
  if ok then return 0, dst end
  return 1, nil, err
end

---@internal
---Previously silent: a failed copy or move only incremented `errors`, with
---no notify at all -- a transfer blocked by a Windows sharing lock (a file
---explorer window, an indexer or an AV scan still holding the source open)
---looked exactly like nothing had happened. Matches `move`/`smart_rename`'s
---own per-item failure notify.
---@param src string
---@param dst string
---@param err string?
local function notify_transfer_failure(src, dst, err)
  notify.error(
    string.format(
      "Failed: %s → %s (%s)",
      ftpath.relative(src),
      ftpath.relative(dst),
      tostring(err)
    )
  )
end

---@internal
---Actually perform an already-confirmed paste into `dst_dir`.
---@param dst_dir string
---@param conflict_mode? "Overwrite"|"Keep both"|"Skip"  How to resolve an
---  item whose name already exists at the destination. Set only when
---  `find_conflicts` found at least one during the preflight scan and the
---  user picked a resolution for the batch; nil means none were found (in
---  which case a target that turns out to exist anyway at execution time —
---  a race since the scan — is treated as an error, not a silent guess).
---@param overrides? table<string, string|table>  Per-source-path destination
---  override chosen up-front while resolving a case-only collision: a string
---  path to use instead of `dst_dir/<name>`, or the `SKIP` sentinel to drop
---  the item.
local function do_paste_impl(dst_dir, conflict_mode, overrides)
  overrides = overrides or {}
  if _cfg.use_safety then
    local ok_s, safety = require("filetree.features").load("safety")
    if ok_s and safety then
      for _, e in ipairs(_clipboard) do
        pcall(safety.before_move, e.path, dst_dir .. "/" .. vim.fn.fnamemodify(e.path, ":t"))
      end
    end
  end

  -- Await the reference scan for the cut items (started on stage_cut, so
  -- likely long finished by the time the user navigated here). It saw the
  -- sources at their old locations, and the copy/move loop runs only inside
  -- this continuation, so no move happens before the scan is complete.
  local cut_paths = {}
  for _, e in ipairs(_clipboard) do
    if e.op ~= "copy" then cut_paths[#cut_paths + 1] = e.path end
  end
  local refs_handle = _cut_prefetch or refs.prefetch(cut_paths, { op = "move" })

  refs_handle.await(function(scan_result)
    local prog = progress.create({ title = "[filetree.copy_move]" })
    local errors = 0
    local done = 0
    local skipped = 0
    local relocated = 0
    -- old path → new path, filled in only once a cut has actually landed, so a
    -- failed or skipped item never gets its references rewritten.
    local moves = {}
    -- old source → new pasted path, copy entries only. Kept separate from
    -- `moves` above: a copy never breaks an INCOMING reference (the original
    -- stays put, `refs.prefetch` above only ever scanned `cut_paths`), but
    -- the pasted COPY's own outgoing links (e.g. a markdown file's relative
    -- links) can still need rewriting for ITS new location — see the second
    -- `refs.handle_result` call below.
    local copied_moves = {}
    local moved = {} -- entry -> true, once its cut has actually landed
    local claimed = {} -- names already handed out by "Keep both" this batch

    for i, e in ipairs(_clipboard) do
      if prog then
        prog:update({
          text = vim.fn.fnamemodify(e.path, ":t"),
          current = i - 1,
          total = #_clipboard,
        })
      end
      local name = vim.fn.fnamemodify(e.path, ":t")
      local override = overrides[e.path]
      local dst
      if override == SKIP then
        skipped = skipped + 1
        dst = nil
      elseif type(override) == "string" then
        dst = override
      else
        dst = dst_dir .. "/" .. name
      end

      -- `is_alias`: `dst` resolves to the item's own source (case-only match on
      -- a case-insensitive FS). Never route that through the conflict handling
      -- — "Overwrite" would `delete(dst, "rf")` the source. A cut lands as a
      -- plain re-casing rename via do_move(); a copy can't happen and was
      -- already turned into an override above.
      if dst and conflict.exists(dst) and not case_clash.is_alias(e.path, dst) then
        if conflict_mode == "Overwrite" then
          if _cfg.use_safety then
            local ok_s, safety = require("filetree.features").load("safety")
            if ok_s and safety then pcall(safety.before_delete, dst) end
          end
          if not conflict.remove_existing(dst) then
            notify.error("Could not clear existing target: " .. dst)
            errors = errors + 1
            dst = nil
          end
        elseif conflict_mode == "Keep both" then
          local is_dir = vim.fn.isdirectory(e.path) == 1
          dst = dst_dir .. "/" .. conflict.unique_name(dst_dir, name, claimed, is_dir)
        elseif conflict_mode == "Skip" then
          skipped = skipped + 1
          dst = nil
        else
          notify.error("Target exists, skipping: " .. dst)
          errors = errors + 1
          dst = nil
        end
      end

      if dst then
        if e.op == "copy" then
          local rc, err = do_copy(e.path, dst)
          if rc ~= 0 then
            notify_transfer_failure(e.path, dst, err)
            errors = errors + 1
          else
            done = done + 1
            copied_moves[e.path] = dst
          end
        else
          local rc, moved_dst, err = do_move(e.path, dst)
          if rc ~= 0 or not moved_dst then
            notify_transfer_failure(e.path, dst, err)
            errors = errors + 1
          else
            done = done + 1
            moved[e] = true
            -- Repoint any open buffer(s) at the old path (or nested under it, for
            -- a moved directory) so a stale buffer for the file's old location
            -- doesn't linger alongside a second, disconnected buffer for its new
            -- one. Per-item, right after that item's own move succeeds, so a
            -- partial failure in a multi-item paste still fixes up the items that
            -- did succeed.
            relocated = relocated + buffer.relocate(e.path, moved_dst)
            moves[e.path] = moved_dst
          end
        end
      end
    end

    local msg = string.format(
      "Pasted %d/%d item(s) into %s",
      done,
      #_clipboard,
      vim.fn.fnamemodify(dst_dir, ":t")
    )
    if skipped > 0 then msg = msg .. string.format(" (%d skipped)", skipped) end
    if relocated > 0 then
      msg = msg .. string.format(" (%d open buffer(s) repointed)", relocated)
    end
    if prog then prog:finish(msg) end
    notify.info(msg)

    -- Both handle_result calls below are fire-and-forget in shape but land
    -- asynchronously (own_links.collect, when outgoing_links is enabled, is
    -- never fully synchronous) -- the clipboard cleanup and refresh must wait
    -- for BOTH (when there are two) to actually finish, not just for this
    -- function to return, or the tree/clipboard could refresh before the
    -- rewrite(s) landed on disk.
    local has_own_links_call = next(copied_moves) ~= nil
    local pending_handled = has_own_links_call and 2 or 1
    local function after_refs_handled()
      pending_handled = pending_handled - 1
      if pending_handled > 0 then return end

      -- Clear clipboard entries that actually landed: copy items always stay
      -- (kept for potential re-paste); cut items only clear once their move
      -- has actually happened, so a skipped or failed cut stays staged for
      -- the user to resolve and paste again instead of vanishing silently.
      local remaining = {}
      for _, e in ipairs(_clipboard) do
        if e.op == "copy" or not moved[e] then remaining[#remaining + 1] = e end
      end
      _clipboard = remaining
      _cut_prefetch = nil

      render_clipboard()
      require("filetree.util.changed").refresh(_adapter)
    end

    -- One chooser for every reference across every moved item, rather than one
    -- popup per file.
    refs.handle_result(scan_result, moves, {
      op = "move",
      title = "References across the moved item(s)",
    }, after_refs_handled)

    -- Copies never carry an incoming-ref scan (only `cut_paths` was
    -- prefetched above — a copy leaves the original in place, so nothing
    -- points at it needs fixing), but a pasted copy's OWN outgoing links can
    -- still need rewriting for its new location. An empty scan result means
    -- `refs.resolve` contributes nothing, so only `own_links.collect` runs.
    if has_own_links_call then
      refs.handle_result({ refs = {}, plans = {} }, copied_moves, {
        op = "copy",
        title = "Links inside the copied item(s)",
      }, after_refs_handled)
    end
  end)
end

---@internal
---A copy entry whose destination would be just its own source re-cased: the
---filesystem can't hold both, so it needs the case_clash prompt rather than
---the normal Overwrite/Keep both flow. (A cut in the same situation is a
---legitimate re-casing rename and needs no prompt.)
---@param dst_dir string
---@param e ClipboardEntry
---@return boolean
local function is_impossible_copy(dst_dir, e)
  if e.op ~= "copy" then return false end
  local dst = dst_dir .. "/" .. vim.fn.fnamemodify(e.path, ":t")
  return case_clash.is_alias(e.path, dst)
end

---@internal
---Resolve every case-only copy collision (one prompt each), accumulating a
---per-source override map, then continue to `next(overrides)`.
---@param dst_dir string
---@param next fun(overrides: table<string, string|table>)
local function resolve_case_clashes(dst_dir, next)
  local overrides = {}
  local pending = {}
  for _, e in ipairs(_clipboard) do
    if is_impossible_copy(dst_dir, e) then pending[#pending + 1] = e end
  end

  local i = 0
  local function step()
    i = i + 1
    local e = pending[i]
    if not e then
      next(overrides)
      return
    end
    local dst = dst_dir .. "/" .. vim.fn.fnamemodify(e.path, ":t")
    case_clash.resolve(e.path, dst, function(final_dst)
      overrides[e.path] = final_dst or SKIP
      step()
    end)
  end
  step()
end

---@internal
---Preflight-check `dst_dir` for name collisions; if any exist, ask the user
---once how to resolve the whole batch (Overwrite / Keep both / Skip /
---Cancel) before touching the filesystem. No conflicts -> straight to paste,
---same as before this feature existed.
---@param dst_dir string
local function paste_resolving_conflicts(dst_dir)
  resolve_case_clashes(dst_dir, function(overrides)
    -- Genuine collisions still needing the batch resolution — excluding the
    -- case-only ones just handled and the case-only cut renames (harmless).
    local conflicts = {}
    for _, e in ipairs(find_conflicts(dst_dir)) do
      local dst = dst_dir .. "/" .. vim.fn.fnamemodify(e.path, ":t")
      if overrides[e.path] == nil and not case_clash.is_alias(e.path, dst) then
        conflicts[#conflicts + 1] = e
      end
    end

    if #conflicts == 0 then
      do_paste_impl(dst_dir, nil, overrides)
      return
    end

    local names = {}
    for _, e in ipairs(conflicts) do
      names[#names + 1] = vim.fn.fnamemodify(e.path, ":t")
    end

    confirm_choice(
      string.format(
        "%d item(s) already exist in %s:\n  %s",
        #conflicts,
        vim.fn.fnamemodify(dst_dir, ":t"),
        table.concat(names, ", ")
      ),
      { "Overwrite", "Keep both", "Skip", "Cancel" },
      function(choice)
        if choice == nil or choice == "Cancel" then
          notify.info("Paste cancelled")
          return
        end
        do_paste_impl(dst_dir, choice, overrides)
      end
    )
  end)
end

function M.paste()
  if #_clipboard == 0 then
    notify.warn("Clipboard is empty")
    return
  end
  if not _adapter then return end

  local node = _adapter.get_current_node()
  local dst_dir
  if node then
    dst_dir = node.type == "directory" and node.path or vim.fn.fnamemodify(node.path, ":h")
  else
    dst_dir = vim.fn.getcwd()
  end

  if _cfg.dry_run then
    local lines = { "-- Paste plan (dry-run) --", "  → " .. dst_dir }
    for _, e in ipairs(_clipboard) do
      lines[#lines + 1] = "  [" .. e.op .. "] " .. vim.fn.fnamemodify(e.path, ":t")
    end
    notify.info(table.concat(lines, "\n"))
    return
  end

  if _cfg.confirm then
    ui_confirm({
      question = string.format(
        "Paste %d item(s) into %s?",
        #_clipboard,
        vim.fn.fnamemodify(dst_dir, ":~")
      ),
      on_choice = function(yes)
        if not yes then
          notify.info("Cancelled")
          return
        end
        paste_resolving_conflicts(dst_dir)
      end,
    })
    return
  end

  paste_resolving_conflicts(dst_dir)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---Toggle dry-run for copy/move.
---
--- `dry_run` was config-only here, while `trash` and `safety` both had a
--- runtime toggle. That asymmetry is the wrong way round: these two are the
--- destructive bulk operations you most want to preview once before letting
--- them run, and turning it on meant editing the config and reloading.
---@return boolean dry_run  the new state
function M.toggle_dry_run()
  _cfg.dry_run = not _cfg.dry_run
  notify.info("copy/move dry-run: " .. (_cfg.dry_run and "ON" or "OFF"))
  return _cfg.dry_run
end

---@param config FiletreeCopyMoveConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter
  _ns = vim.api.nvim_create_namespace("filetree_copy_move")
  if _decor then _decor.remove() end
  _decor = require("filetree.util.decorate").by_path(
    adapter,
    { name = "clipboard", slot = "badge", priority = 80 }
  )

  local km = _cfg.keymaps or {}

  -- neo-tree's own native keymaps (y/x/p/...) are registered with a
  -- global `nowait = true`, which makes Vim resolve the ambiguity
  -- between a single-char native mapping and our own longer "yy"/"xx"
  -- sequence immediately in the native mapping's favour -- the second
  -- keypress never gets a chance to complete the double-tap. Re-binding
  -- the bare prefix char to a plain <Nop> (no nowait) on this buffer
  -- overrides neo-tree's mapping and restores Vim's normal
  -- wait-for-more-input behaviour, making "yy"/"xx" reachable again.
  --
  -- Declared as actions of their own rather than bound behind the others'
  -- backs: a key this plugin claims is a key a user may need to see, and
  -- `unblock_copy = false` is the only way to get `y` back if they want it.
  ---@param key string|nil
  ---@return string|nil
  local function prefix_of(key)
    if type(key) == "string" and #key == 2 and key:sub(1, 1) == key:sub(2, 2) then
      local prefix = key:sub(1, 1)
      if prefix ~= km.paste and prefix ~= km.show then return prefix end
    end
    return nil
  end

  ---@type FiletreeBindSpec[]
  local specs = {
    { name = "copy", field = "copy", cfg = km, rhs = M.stage_copy, desc = "stage copy" },
    { name = "cut", field = "cut", cfg = km, rhs = M.stage_cut, desc = "stage cut" },
    { name = "paste", field = "paste", cfg = km, rhs = M.paste, desc = "paste clipboard" },
    { name = "show", field = "show", cfg = km, rhs = M.show, desc = "show clipboard" },
    { name = "clear", field = "clear", cfg = km, rhs = M.clear, desc = "clear clipboard" },
  }

  for _, which in ipairs({ { "copy", "stage copy" }, { "cut", "stage cut" } }) do
    local prefix = prefix_of(km[which[1]])
    if prefix then
      specs[#specs + 1] = {
        name = "unblock_" .. which[1],
        field = "_prefix",
        cfg = { _prefix = prefix },
        rhs = "<Nop>",
        desc = ("unblock %s (%s)"):format(which[2], km[which[1]]),
      }
    end
  end

  bind.bind("copy_move", _cfg, specs)

  tree_attach.on_attach(function(_buf)
    render_clipboard()
  end)

  bufevents.register("copy_move", "BufEnter:tree", {
    desc = "[filetree] Re-draw the copy/move clipboard marks in the tree",
    load = function()
      render_clipboard()
    end,
  })
end

function M.teardown()
  bufevents.unregister("copy_move")
  if _decor then _decor.remove() end
  _decor = nil
  _clipboard = {}
  _adapter = nil
end

return M
