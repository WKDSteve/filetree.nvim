---@module 'filetree.features.fileops.trash'
---@brief Send files to system trash with in-session undo support.
---@description
--- Moves the node's file/directory to the system trash (platform-specific) and
--- records it for later restoration. Integrates with the safety feature for
--- optional pre-trash backup.
---
--- `mode = "permanent"` (opt-in; default is "trash") skips the OS trash
--- entirely and deletes the path for good via the same libuv/Vim-builtin
--- primitive `util.conflict` already uses for an "Overwrite" paste — no
--- shell, no undo, no trash history entry: there is nothing left to
--- restore, so `U`/`:Filetree trash history` have nothing to show for it.
---
--- Deleting `d` (current node, or all marked nodes if any are marked):
---   - `confirm = false`: deletes everything straight away, no prompt.
---   - a single item: one y/N.
---   - multiple items: ONE batch chooser (via the shared hover_select float)
---     offering "delete all at once" / "confirm each individually" / "cancel",
---     instead of prompting once per file.
--- Every successful delete force-closes any buffer still open for the deleted
--- file (or, for a directory, nested under it) so a stale buffer never lingers
--- pointing at a file that no longer exists (see util.buffer.close_for_path).
---
--- The single-item confirm popup also runs both directions of the reference
--- engine: incoming refs (other files pointing at the one being deleted —
--- offered to mark REF!) and outgoing asset links (files the one being
--- deleted points at, under a configured assets folder — offered for
--- cascade-deletion when nothing else still references them). Neither exists for a
--- multi-item "delete all at once" batch, same as before this feature.
---
--- That makes a delete two mutations, so `U` undoes two: the incoming-ref
--- rewrite's undo token is handed to the trash history entry this delete
--- created (`undo.attach_refs`), and restoring the file reverts exactly that
--- rewrite — not merely "the last reference update", which a rename in the
--- meantime would have made someone else's.
---
--- Keymaps (in tree buffer, default):
---   d            Trash current node (or all marked nodes)
---   U            Undo last trash operation (file + its REF! markers)
---   <leader>th   Show trash history

local trash_platform = require("filetree.features.fileops.trash.platform")
local undo = require("filetree.features.fileops.trash.undo")
local notify = require("filetree.util.notify").create("[filetree.trash]")

local buffer = require("filetree.util.buffer")
-- The same cross-platform (no shell) recursive delete `copy_move`'s
-- "Overwrite" resolution already uses — reused here for `mode = "permanent"`
-- instead of a second delete primitive.
local conflict = require("filetree.util.conflict")
local symlink_util = require("filetree.util.symlink")
local confirm_choice = require("filetree.util.confirm_choice")
local ui_confirm = require("filetree.util.confirm")
local refs_picker = require("filetree.util.refs_picker")
-- References that would dangle once the file is gone (markdown links only —
-- see refs.for_delete), AND assets the file itself links out to that would be
-- orphaned by its deletion (refs.outgoing_assets). This feature decides what to
-- do with both before the delete happens.
local refs = require("filetree.refs")
-- Optional: progress indicator for a multi-item batch (no other feedback
-- otherwise while several files are sent to trash one after another).
-- No-op (returns nil) when lib.nvim isn't installed.
local progress = require("filetree.util.progress")
-- Release the directory-watcher handles (neo-tree's and the own tree's) before
-- the external trash command touches the path.
local release = require("filetree.util.release")
local bind = require("filetree.util.bind")
local hooks = require("filetree.util.hooks")

local M = {}

---@type FiletreeTrashConfig
local DEFAULTS = {
  enabled = false,
  -- "permanent" is opt-in: it is a genuine, unrecoverable delete (no OS
  -- trash, no `U`/history entry), so the safer default stays "trash" even
  -- though it costs an extra config line to opt into "gone for good".
  mode = "trash",
  -- Deliberately true, unlike copy_move/rename_batch's confirm=false default:
  -- trashing is the one destructive action here whose target files aren't
  -- necessarily what the user thinks they are (mis-clicks on the wrong node,
  -- accidental multi-mark deletes) and it's meaningfully harder to notice/
  -- undo than a move or rename. Override with `confirmations = false` (or
  -- `features.trash.confirm = false`) to opt back out.
  confirm = true,
  use_safety = false,
  dry_run = false,
  -- How many trash operations stay undoable. 0 = unlimited.
  max_history = 50,
  keymap = "d",
  keymap_undo = "U",
  keymap_history = "<leader>th",
}

---@type FiletreeTrashConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.trash` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  mode = { "string", enum = { "trash", "permanent" } },
  confirm = "boolean",
  use_safety = "boolean",
  dry_run = "boolean",
  max_history = { "number", min = 0 },
  keymap = "keymap",
  keymap_undo = "keymap",
  keymap_history = "keymap",
  -- Deprecated, migrated by config/init.lua's apply_legacy_refs().
  check_markdown_refs = "boolean",
  refs_picker_prefer = { "string", enum = { "auto", "telescope", "fzf-lua", "quickfix" } },
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

---@internal
---Whether `path` is going to be gone for good.
---@return boolean
local function is_permanent()
  return _cfg.mode == "permanent"
end

---@internal
---A caller that already validated `path` at gather time (e.g.
---`link_create.M.delete()` checking it IS a symlink, never a real file) can
---ask for that same guarantee to be re-checked right before each path is
---actually acted on, by passing `require_symlink = true` through
---`M.delete`/`M.delete_current`'s `opts`. This is a plain call-scoped
---argument, not a persistent registry keyed by path — nothing to leak or
---go stale if a delete is later cancelled, declined, or never reaches an
---OS-level delete call at all, and every code path that can actually touch
---disk (the per-path `do_trash` chain AND the batched `run_all_batched`,
---which bypasses `do_trash` entirely) checks it, not just one of them.
---
---Not a mathematical guarantee: the trash-mode delete itself still runs via
---a separately spawned OS process (`trash_platform.send`/`send_batch`),
---whose own startup latency (measured at "several hundred milliseconds" for
---the Windows PowerShell backend — see `trash/platform.lua`) sits between
---this check and the moment that process actually touches the path. This
---closes the large, unbounded window (an async ref/asset scan plus an
---interactive confirm dialog the user can leave open indefinitely) down to
---that external process's own, much smaller and bounded startup cost — not
---to zero.
---@param path string
---@param require_symlink boolean|nil
---@return boolean ok  false already notified why; caller just bails.
local function symlink_still_ok(path, require_symlink)
  if not require_symlink then return true end
  if symlink_util.is_link(path) then return true end
  notify.warn(
    "Skipped — no longer a symlink (something else changed it in the meantime): " .. path
  )
  return false
end

---@internal
---The confirm question for `path` (or the whole-batch variant when `path`
---is omitted) — worded so a permanent delete never reads like a trash
---(recoverable) one, since the two share every dialog in this module.
---
---Also branches on whether the SINGLE path being trashed is itself a
---symlink: "Send to trash?" reads exactly like "delete this file" with
---nothing to tell the two apart, which is precisely what prompted this —
---trashing a symlink only ever removes the link dirent (the OS-level
---primitive never follows it), the target is never touched, and that needs
---to be said in the question itself rather than left to be inferred from the
---"Type: link (symlink)" line in the popup body above it.
---@param path string?  Only used to detect a symlink (never appended for
---                     display — the popup body already shows it via node_info).
---@param extra string?  Appended as-is (e.g. " (2 ref(s) will be marked REF!)").
---@return string
local function confirm_question(path, extra)
  local symlink = path ~= nil and symlink_util.is_link(path)
  local q
  if symlink then
    q = is_permanent() and "Permanently delete symlink (target is not touched, cannot be undone)?"
      or "Send symlink to trash (target is not touched)?"
  else
    q = is_permanent() and "Permanently delete (cannot be undone)?" or "Send to trash?"
  end
  if extra then q = q .. extra end
  return q
end

---@internal
---"Moved N/M to trash" vs "Permanently deleted N/M" — see `confirm_question`.
---
---A dry-run reports in the conditional too. Every individual step of it
---already says "[dry-run] would …", so a closing "Moved 1/1 to trash" was the
---one line of the whole run claiming something had actually happened.
---@param ok_count integer
---@param total integer
---@return string
local function summary_line(ok_count, total)
  if _cfg.dry_run then
    if is_permanent() then
      return string.format("[dry-run] would permanently delete %d/%d", ok_count, total)
    end
    return string.format("[dry-run] would move %d/%d to trash", ok_count, total)
  end
  if is_permanent() then return string.format("Permanently deleted %d/%d", ok_count, total) end
  return string.format("Moved %d/%d to trash", ok_count, total)
end

---Single-item y/N confirm for the SYNCHRONOUS `M.delete(path)` API path only
---(direct/programmatic callers, not the interactive `d` keymap — that goes
---through the nicer async `confirm_popup` below). Deliberately stays on the
---blocking native `vim.fn.confirm` rather than `kit.confirm`: `M.delete`
---returns a boolean synchronously, and kit.confirm is callback-based, so
---switching here would turn `M.delete` async and break its documented
---return contract for any external caller. Same category as the
---`replacer.nvim`/`diff.nvim` kit-migration exceptions — not a quick win.
---@param path string
---@return boolean confirmed
local function confirm(path)
  local answer = vim.fn.confirm(confirm_question(path), "&Yes\n&No", 2) -- native-prompt: M.delete answers synchronously (documented)
  return answer == 1
end

---Actually delete one path — NO confirmation (the caller has already handled
---that, at whatever granularity). Force-closes any open buffer for the file
---(or, for a directory, nested under it) so a stale buffer never lingers
---pointing at a deleted file. Does NOT refresh the tree; callers refresh once
---after a whole batch.
---
---`mode = "trash"` (default) sends to the OS trash and records undo;
---`mode = "permanent"` deletes for good via `util.conflict` — no undo, no
---history entry, since there is nothing left to restore.
---@param path string
---@param cb fun(ok: boolean)  invoked on the main loop once the delete attempt settled
---@param require_symlink boolean|nil  see `symlink_still_ok`'s doc comment
---@return nil
local function do_trash_impl(path, cb, require_symlink)
  if not symlink_still_ok(path, require_symlink) then
    cb(false)
    return
  end

  -- `conflict.exists` (not a bare filereadable/isdirectory check): a broken
  -- symlink is neither, yet is very much a path that needs trashing.
  if not conflict.exists(path) then
    notify.warn("path does not exist: " .. path)
    cb(false)
    return
  end

  if _cfg.dry_run then
    notify.info(
      "[dry-run] would " .. (is_permanent() and "permanently delete: " or "trash: ") .. path
    )
    -- No history entry: nothing was trashed, so there is nothing to restore.
    -- Recording one made `<leader>th` list deletes that never happened, and
    -- `U` on such an entry went looking for a file the Recycle Bin had never
    -- seen and failed with "Item not found" -- a dry-run leaving state behind
    -- for the rest of the session, which is the one thing it must not do.
    cb(true)
    return
  end

  -- Optional pre-trash backup via safety feature (arguably more useful in
  -- permanent mode than trash mode, since it is the only way back at all).
  if _cfg.use_safety then
    local ok_sf, safety = require("filetree.features").load("safety")
    if ok_sf and safety then pcall(safety.before_delete, path) end
  end

  if is_permanent() then
    if not conflict.remove_existing(path) then
      notify.error("Delete failed: " .. path)
      cb(false)
      return
    end
    buffer.close_for_path(path)
    cb(true)
    return
  end

  local released, resume = release.path(path)

  local function spawn()
    trash_platform.send(path, function(result)
      resume() -- the own tree watches again whatever is still there
      if not result.ok then
        notify.error("Trash failed: " .. (result.err or "unknown error"))
        cb(false)
        return
      end

      undo.record(path)
      buffer.close_for_path(path) -- close any buffer(s) for the now-deleted file
      cb(true)
    end)
  end

  -- The trash command runs in a SEPARATE process (mv / trash / gio), so unlike
  -- cross.fs.mutate it has no on_retry retry seam. Instead, proactively release
  -- any watcher holding `path` (or a subpath) open (above) before spawning it —
  -- otherwise our own libuv handle causes the very Windows sharing violation the
  -- external move would then fail on. libuv closes handles asynchronously, so
  -- give the close a moment to land before the external process runs. This used
  -- to be a blocking `vim.wait(20)`; vim.defer_fn yields to the loop for the
  -- same 20ms without freezing the editor, which is what actually lets the
  -- close callbacks run.
  if released > 0 then
    vim.defer_fn(spawn, 20)
  else
    spawn()
  end
end

---@internal
---`do_trash_impl` announcing itself on the `hooks_api` bus: `before_delete`, then
---`after_delete` with the outcome. A dry run deletes nothing, so it announces nothing.
---@param path string
---@param cb fun(ok: boolean)
---@param require_symlink boolean|nil
---@return nil
local function do_trash(path, cb, require_symlink)
  if _cfg.dry_run then return do_trash_impl(path, cb, require_symlink) end
  hooks.emit("before_delete", { path = path })
  do_trash_impl(path, function(ok)
    hooks.emit("after_delete", { path = path, ok = ok })
    cb(ok)
  end, require_symlink)
end

---Metadata lines for the confirm popup — reuses node_info's formatter so the
---popup shows the same Path/Size/Modified/Lines info as the `I` keymap.
---@param path string
---@return string[]
local function info_body(path)
  local ok, ni = require("filetree.features").load("node_info")
  if ok and ni and type(ni.info_lines) == "function" then
    local ok2, lines = pcall(ni.info_lines, path)
    if ok2 and type(lines) == "table" and #lines > 0 then return lines end
  end
  return { "  " .. path }
end

---@internal
---Delete every approved asset through the same trash/undo path as the
---primary file (`do_trash`, defined above) — not a plain `fs_unlink` — so
---`:Filetree trash undo`/`U` can bring an asset back the same way it brings
---back the file that linked to it (each asset
---still lands as its OWN undo entry, not grouped with the primary file's —
---undoing the whole batch as one unit is a follow-up, not built here).
---Sequential like `run_all`, for the same reason: parallel trashing would
---race the watcher-release dance `do_trash` does per path.
---A failed asset trash does not stop the rest of the batch (the other
---candidates are independent), but it must not be silently swallowed either
---— `done` still fires so the caller isn't left hanging, and the failure is
---surfaced via a single summary notify.
---@param candidates FiletreeAssetCandidate[]
---@param done fun()
local function delete_assets(candidates, done)
  local i, failed = 0, 0
  local function step()
    i = i + 1
    if i > #candidates then
      if failed > 0 then notify.warn(string.format("%d asset(s) could not be trashed", failed)) end
      return done()
    end
    do_trash(candidates[i].resolved, function(ok)
      if not ok then failed = failed + 1 end
      step()
    end)
  end
  step()
end

---Show the nice info+yes/no popup for a single path, THEN (once the user
---agrees) actually trash it and run any approved cleanup. When the file has
---incoming references, outgoing links to now-orphaned assets, or both, a
---chooser replaces the plain yes/no — one dialog for both directions rather
---than two separate popups.
---
---Unlike a rename, both scans have to finish *before* the dialog can be
---drawn — its text depends on what was found — so this waits for them
---rather than overlapping either with the delete itself. The two scans
---(incoming refs, outgoing assets) run concurrently with EACH OTHER, since
---neither depends on the other's result.
---@param path string
---@param cb fun(ok: boolean)  Whether `path` actually ended up trashed
---                            (declining, or the trash attempt itself
---                            failing, both report false).
---@param require_symlink boolean|nil  see `symlink_still_ok`'s doc comment
local function confirm_popup(path, cb, require_symlink)
  local name = vim.fn.fnamemodify(path, ":t")
  local pending = 2
  ---@type FiletreeRef[]?
  local incoming_refs
  ---@type FiletreeAssetCandidate[]?, FiletreeAssetCandidate[]?
  local deletable_assets, kept_assets

  local function proceed()
    if pending > 0 or not incoming_refs or not deletable_assets then return end

    -- An asset that qualifies (right root, right extension) but is still
    -- linked from some OTHER surviving file is never offered — but the user
    -- should still learn why an apparent orphan wasn't offered, rather than
    -- silently seeing nothing.
    if #kept_assets > 0 then
      notify.info(
        string.format(
          "%d asset(s) still referenced elsewhere, left alone: %s",
          #kept_assets,
          table.concat(refs.assets.basenames(kept_assets), ", ")
        )
      )
    end

    local has_refs = #incoming_refs > 0
    local has_assets = #deletable_assets > 0

    if not has_refs and not has_assets then
      ui_confirm({
        title = " Trash ",
        body = info_body(path),
        question = confirm_question(path),
        on_choice = function(yes)
          if yes then
            do_trash(path, cb, require_symlink)
          else
            cb(false)
          end
        end,
      })
      return
    end

    if has_refs then
      notify.info(
        refs.ui.summary(incoming_refs)
          .. ": "
          .. table.concat(refs.ui.unique_files(incoming_refs), ", ")
      )
    end
    if has_assets then
      notify.info(
        string.format(
          "%d orphaned asset(s) found: %s",
          #deletable_assets,
          table.concat(refs.assets.basenames(deletable_assets), ", ")
        )
      )
    end

    ---@internal
    ---Trash `path` itself FIRST, and only once that actually succeeded,
    ---rewrite `refs_to_apply` (if any) and delete every approved asset (if
    ---any). Primary-first, on purpose: an asset is only truly orphaned, and
    ---an incoming ref only truly dangling, once the file that made it so is
    ---actually gone — not merely approved for deletion. Doing cleanup before
    ---the primary trash was confirmed to have succeeded meant a failed trash
    ---(permission error, external process failure) could still leave assets
    ---deleted and refs rewritten out from under a file that was still sitting
    ---there, unchanged, pointing at them.
    ---@param refs_to_apply FiletreeRef[]
    ---@param done fun(ok: boolean)
    local function trash_then_cleanup(refs_to_apply, done)
      do_trash(path, function(ok)
        if not ok then return done(false) end -- do_trash already notified the error
        local function after_refs()
          if has_assets then
            delete_assets(deletable_assets, function()
              done(true)
            end)
          else
            done(true)
          end
        end
        -- dry-run means "log the plan, change nothing" -- and a reference
        -- rewrite is a change to OTHER people's files, which a dry-run of a
        -- delete has even less business making than the delete itself. Both
        -- other halves (the trash, each cascaded asset) already route through
        -- do_trash and log instead of acting; this one used to fall straight
        -- through and really write REF! into every referencing file.
        if _cfg.dry_run and #refs_to_apply > 0 then
          notify.info(string.format("[dry-run] would mark %d reference(s) REF!", #refs_to_apply))
          after_refs()
        elseif #refs_to_apply > 0 then
          -- Hand the rewrite's undo token to the trash history entry this
          -- delete just created, so `U` puts the `REF!` markers back together
          -- with the file instead of restoring a file every link still calls
          -- broken.
          --
          -- Marked pending BEFORE the rewrite starts, not after: above
          -- APPLY_CHUNK_SIZE referencing files, refs.apply.run chunks the
          -- rewrite across several event-loop ticks, and nothing stops `U`
          -- from firing (and removing this delete's history entry) during
          -- that yield -- without this, attach_refs below would silently
          -- find nothing to attach the finished rewrite's undo token to.
          -- Not marked for a permanent delete: it never gets a history entry
          -- in the first place (see do_trash), so there is nothing to race.
          if not is_permanent() then undo.mark_refs_pending(path) end
          refs.apply.run(
            refs_to_apply,
            { label = "delete: " .. name },
            function(applied, _, undo_id)
              undo.attach_refs(path, undo_id, applied)
              after_refs()
            end
          )
        else
          after_refs()
        end
      end, require_symlink)
    end

    -- `refs.on_delete = "auto"` means "don't ask about the cleanup specifics"
    -- -- not "don't ask about the delete". So the ordinary confirmation still
    -- runs, and the cleanup happens only once it came back yes: a cancelled
    -- delete must not leave blanked-out links or half-deleted assets behind.
    --
    -- refs.on_delete and refs.outgoing_assets.on_delete are independent
    -- switches (step 4's config block) -- a direction that found nothing
    -- (has_refs/has_assets false) never gets a say, and between the two that
    -- did, "ask" from either wins over "auto" from the other: auto-applying
    -- a change the user asked to be asked about is the wrong default to err
    -- toward. A dialog that independently offers/withholds each direction
    -- (rather than "ask" promoting the WHOLE thing to asking) would need two
    -- separate toggles, not one chooser -- a real follow-up, not this step.
    local ref_wants_ask = has_refs and refs.mode("delete") == "ask"
    local asset_wants_ask = has_assets and refs.outgoing_assets_mode() == "ask"
    if not ref_wants_ask and not asset_wants_ask then
      local parts = {}
      if has_refs then
        parts[#parts + 1] = string.format("%d ref(s) will be marked REF!", #incoming_refs)
      end
      if has_assets then
        parts[#parts + 1] = string.format("%d asset(s) will be deleted", #deletable_assets)
      end
      ui_confirm({
        title = " Trash ",
        body = info_body(path),
        question = confirm_question(path, string.format(" (%s)", table.concat(parts, "; "))),
        on_choice = function(yes)
          if yes then
            trash_then_cleanup(incoming_refs, cb)
          else
            cb(false)
          end
        end,
      })
      return
    end

    local title_parts = {}
    if has_refs then title_parts[#title_parts + 1] = string.format("%d ref(s)", #incoming_refs) end
    if has_assets then
      title_parts[#title_parts + 1] = string.format("%d asset(s)", #deletable_assets)
    end
    local title = string.format("Trash %s (%s found)", name, table.concat(title_parts, ", "))

    -- Labels adapt to what was actually found, rather than a fixed fifth
    -- branch, so a ref-only or asset-only delete keeps reading exactly like
    -- it did before this feature existed.
    local delete_label = "Delete + remove refs"
    if has_refs and has_assets then
      delete_label = "Delete + clean up refs & assets"
    elseif has_assets then
      delete_label = "Delete + remove assets"
    end
    local keep_label = "Delete, keep refs"
    if has_refs and has_assets then
      keep_label = "Delete, keep refs & assets"
    elseif has_assets then
      keep_label = "Delete, keep assets"
    end

    -- "Inspect first" only ever selects among INCOMING refs (unchanged from
    -- before this feature) — a second, asset-specific picker is a follow-up,
    -- not part of wiring this into the existing dialog. It's left out of the
    -- option list entirely for an asset-only delete, where there is nothing
    -- incoming to inspect.
    local options = { delete_label }
    if has_refs then options[#options + 1] = "Inspect first" end
    options[#options + 1] = keep_label
    options[#options + 1] = "Cancel"

    confirm_choice(title, options, function(choice)
      if choice == delete_label then
        trash_then_cleanup(incoming_refs, cb)
      elseif choice == "Inspect first" then
        refs_picker.pick(
          incoming_refs,
          {
            prefer = refs.config().picker,
            title = "References to " .. name .. (has_assets and string.format(
              " (%d asset(s) will also be cleaned up)",
              #deletable_assets
            ) or ""),
          },
          function(selected)
            -- Selecting zero refs to update still cascades the approved
            -- assets: "Inspect first" is selectivity over WHICH refs get
            -- rewritten, not an opt-out of the asset cleanup.
            trash_then_cleanup(selected, cb)
          end,
          function()
            confirm_popup(path, cb, require_symlink)
          end -- Esc/cancel -> back to this same chooser
        )
      elseif choice == keep_label then
        do_trash(path, cb, require_symlink)
      else
        cb(false)
      end
    end)
  end

  refs.for_delete({ path }, nil, function(found)
    incoming_refs = found
    pending = pending - 1
    proceed()
  end)

  refs.outgoing_assets(path, nil, function(candidates)
    deletable_assets, kept_assets = refs.assets.split(candidates)
    pending = pending - 1
    proceed()
  end)
end

---Finalize a batch: clear marks + refresh the tree once (only when something was
---actually deleted), and report a single summary.
---@param ok_count integer
---@param total integer
---@param cancelled integer
local function finalize(ok_count, total, cancelled)
  if ok_count > 0 then
    local ok_m, marks = require("filetree.features").load("marks")
    if ok_m and marks then pcall(marks.clear_all) end
    require("filetree.util.changed").refresh(_adapter)
  end
  local parts = { summary_line(ok_count, total) }
  if cancelled > 0 then parts[#parts + 1] = string.format("(%d skipped)", cancelled) end
  notify.info(table.concat(parts, " "))
end

---@internal
---Same contract/outcome as `run_all` below, for the case batching actually
---helps: real trash mode (not dry-run — nothing external to batch there),
---more than one path (a lone path gains nothing from building and parsing a
---batch script it still has to pay for). Permanent mode never reaches this
---either — `run_all` keeps it on the per-path chain, same as dry-run.
---
---Existence checks still happen per path up front (a stale mark pointing at
---an already-deleted file — exactly what produced the confusing "path does
---not exist" warnings in the original bug report — must not be sent to
---`trash_platform.send_batch` at all), and safety-backup/undo/buffer-close
---bookkeeping still runs per path, just once the whole batch has settled
---rather than interleaved between individual OS calls.
---
---Also where a `require_symlink` re-check lands for this route: unlike the
---per-path chain below, this never calls `do_trash` (that's the whole point
---of batching), so it needs the exact same `symlink_still_ok` guard inline
---— a path dropped here is simply excluded from `existing`, same as one
---that no longer exists.
---@param paths string[]
---@param require_symlink boolean|nil  see `symlink_still_ok`'s doc comment
local function run_all_batched(paths, require_symlink)
  local prog = progress.create({ title = "[filetree.trash]" })

  local existing = {}
  for _, p in ipairs(paths) do
    if not conflict.exists(p) then
      notify.warn("path does not exist: " .. p)
    elseif symlink_still_ok(p, require_symlink) then
      existing[#existing + 1] = p
    end
  end

  if _cfg.use_safety then
    local ok_sf, safety = require("filetree.features").load("safety")
    if ok_sf and safety then
      for _, p in ipairs(existing) do
        pcall(safety.before_delete, p)
      end
    end
  end

  for _, p in ipairs(existing) do
    hooks.emit("before_delete", { path = p })
  end

  local released, resume = release.paths(existing)

  local function spawn()
    if prog then
      prog:update({ text = string.format("%d item(s)", #existing), current = 0, total = #existing })
    end
    trash_platform.send_batch(existing, function(results)
      resume() -- the own tree watches again whatever is still there
      local ok_count = 0
      for i, p in ipairs(existing) do
        local result = results[i]
        local deleted = result and result.ok
        hooks.emit("after_delete", { path = p, ok = deleted == true })
        if deleted then
          ok_count = ok_count + 1
          undo.record(p)
          buffer.close_for_path(p)
        else
          notify.error(
            "Trash failed: " .. ((result and result.err) or "unknown error") .. " (" .. p .. ")"
          )
        end
      end
      if prog then prog:finish(summary_line(ok_count, #paths)) end
      finalize(ok_count, #paths, 0)
    end)
  end

  -- Release every watcher up front rather than per path -- do_trash's own
  -- 20ms defer-before-spawn dance, just paid once for the whole batch
  -- instead of once per path.
  if released > 0 then
    vim.defer_fn(spawn, 20)
  else
    spawn()
  end
end

---Delete every path with no further prompting (the "all" decision).
---@param paths string[]
---@param require_symlink boolean|nil  see `symlink_still_ok`'s doc comment
local function run_all(paths, require_symlink)
  -- Batching only helps the one thing that's actually slow: spawning a
  -- fresh OS trash process per path (see platform.lua's run_windows_batch).
  -- Permanent delete and dry-run never do that — do_trash short-circuits
  -- before ever touching trash_platform for either — so both, along with
  -- the trivial single-path case, keep the existing per-path chain below.
  if not is_permanent() and not _cfg.dry_run and #paths > 1 then
    return run_all_batched(paths, require_symlink)
  end

  local prog = progress.create({ title = "[filetree.trash]" })
  local ok_count = 0

  -- do_trash() is asynchronous now, so the batch is a chain rather than a
  -- `for` loop: each path starts the next one from its own callback. Strictly
  -- sequential on purpose - trashing in parallel would race the watcher
  -- release/handle-close dance do_trash performs per path, and the progress
  -- indicator would no longer describe one identifiable file.
  local i = 0
  local function step()
    i = i + 1
    if i > #paths then
      if prog then prog:finish(summary_line(ok_count, #paths)) end
      finalize(ok_count, #paths, 0)
      return
    end
    if prog then
      prog:update({ text = vim.fn.fnamemodify(paths[i], ":t"), current = i - 1, total = #paths })
    end
    do_trash(paths[i], function(ok)
      if ok then ok_count = ok_count + 1 end
      step()
    end, require_symlink)
  end
  step()
end

---Delete each path after its own info+yes/no popup (the "individual" decision).
---Async, chained one popup at a time so the flow stays modal-feeling.
---@param paths string[]
---@param require_symlink boolean|nil  see `symlink_still_ok`'s doc comment
local function run_individual(paths, require_symlink)
  local prog = progress.create({ title = "[filetree.trash]" })
  local ok_count, cancelled = 0, 0
  local i = 0
  local function step()
    i = i + 1
    if i > #paths then
      if prog then prog:finish(summary_line(ok_count, #paths)) end
      finalize(ok_count, #paths, cancelled)
      return
    end
    if prog then
      prog:update({ text = vim.fn.fnamemodify(paths[i], ":t"), current = i - 1, total = #paths })
    end
    -- confirm_popup now owns the actual trash attempt (see its own doc
    -- comment) — a `false` here covers both "declined" and "trash failed"
    -- (do_trash already showed a specific error notify for the latter), so
    -- both fold into the same `cancelled`/"skipped" tally.
    confirm_popup(paths[i], function(ok)
      if ok then
        ok_count = ok_count + 1
      else
        cancelled = cancelled + 1
      end
      step()
    end, require_symlink)
  end
  step()
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Send the given path to the system trash (single-path API; confirms when the
---feature's `confirm` is on). Kept for direct/programmatic callers and the
---command dispatcher; the interactive `d` keymap goes through delete_current.
---BREAKING (async conversion): this no longer returns the outcome. Trashing
---goes through an external process, which is now spawned asynchronously, so the
---result is only known later - pass `on_done` to observe it.
---@param path string  Absolute path of the file or directory.
---@param on_done fun(ok: boolean)|nil  invoked once the trash attempt settled
---@param require_symlink boolean|nil  see `symlink_still_ok`'s doc comment
---@return nil
function M.delete(path, on_done, require_symlink)
  local function done(ok)
    if on_done then on_done(ok) end
  end

  if not _cfg.enabled then
    notify.warn("trash feature is disabled")
    return done(false)
  end
  -- `conflict.exists` (not a bare filereadable/isdirectory check): a broken
  -- symlink is neither, yet is very much a path that needs trashing.
  if not conflict.exists(path) then
    notify.warn("path does not exist: " .. path)
    return done(false)
  end
  if _cfg.confirm and not confirm(path) then return done(false) end
  do_trash(path, function(ok)
    if ok then require("filetree.util.changed").refresh(_adapter) end
    done(ok)
  end, require_symlink)
end

---Collect the paths to trash: all marked nodes if any are marked, else the
---node under the cursor. Does NOT clear marks (that happens after a successful
---delete, so a cancelled operation leaves the marks intact).
---@return string[]
local function gather_paths()
  local ok_m, marks = require("filetree.features").load("marks")
  if ok_m and marks and marks.count() > 0 then return marks.get_marked() end
  local node = _adapter and _adapter.get_current_node()
  return (node and node.path) and { node.path } or {}
end

---Trash the current node, or all marked nodes if any are marked.
---
--- - `confirm = false`: delete everything straight away, no prompt.
--- - a single item: one info+yes/no popup (util.confirm — a small float with the
---   file's metadata, not the native "more" prompt).
--- - multiple items: one batch chooser (hover_select float) offering
---   "delete all at once", "confirm each individually", or "cancel" — instead
---   of asking once per file. "individual" then shows the info popup per file.
---@param opts { paths?: string[], require_symlink?: boolean }|nil  `paths`
---  overrides `gather_paths()` — for a caller that has already picked (and
---  filtered) its own path set, e.g. `:Filetree symlink delete` restricting
---  a marks-or-cursor batch down to just the symlinks in it. `require_symlink`
---  additionally re-verifies each path is STILL a symlink right before it is
---  actually acted on (see `symlink_still_ok`'s doc comment) — every route
---  below (single-item popup, "delete all at once" whether batched or not,
---  "confirm individually") passes it straight through, so there is no route
---  through this function that skips the re-check once asked for. Everything
---  else (confirm, the batch chooser, undo, refresh) still goes through the
---  exact same path as `d`.
function M.delete_current(opts)
  if not _adapter then return end
  opts = opts or {}

  local paths = opts.paths or gather_paths()
  if #paths == 0 then
    notify.warn("No node selected")
    return
  end

  -- No confirmation configured → just delete everything.
  if not _cfg.confirm then
    run_all(paths, opts.require_symlink)
    return
  end

  -- Single item → the nice info+yes/no popup. confirm_popup performs the
  -- actual trash itself (see its own doc comment), so this only reports the
  -- outcome — it does not hand off to run_all.
  if #paths == 1 then
    confirm_popup(paths[1], function(ok)
      if ok then finalize(1, 1, 0) end
    end, opts.require_symlink)
    return
  end

  -- Multiple items → one chooser for the whole set (h/l to move, <CR> to
  -- pick, <Esc>/q to cancel).
  confirm_choice(
    string.format("Move %d items to trash", #paths),
    { "Delete all at once", "Confirm individually", "Cancel" },
    function(choice)
      if choice == "Delete all at once" then
        run_all(paths, opts.require_symlink)
      elseif choice == "Confirm individually" then
        run_individual(paths, opts.require_symlink)
      end
      -- "Cancel" or nil (dismissed) → do nothing, marks stay.
    end
  )
end

---Restore the last trashed item.
---@return boolean ok
function M.undo_last()
  return undo.restore_last()
end

---Show the in-session trash history.
function M.show_history()
  undo.show_history()
end

---Toggle dry-run mode.
function M.toggle_dry_run()
  _cfg.dry_run = not _cfg.dry_run
  notify.info("dry-run: " .. (_cfg.dry_run and "ON" or "OFF"))
end

---Return true when the current platform has a supported trash backend.
---@return boolean
function M.available()
  return trash_platform.available()
end

---@param config FiletreeTrashConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  if not trash_platform.available() then
    notify.warn("No trash backend found on this platform. Feature disabled.")
    _cfg.enabled = false
    return
  end

  bind.bind("trash", _cfg, {
    { name = "trash", field = "keymap", rhs = M.delete_current, desc = "trash current node" },
    { name = "undo", field = "keymap_undo", rhs = M.undo_last, desc = "undo last trash" },
    {
      name = "history",
      field = "keymap_history",
      rhs = M.show_history,
      desc = "show trash history",
    },
  })
end

function M.teardown()
  _adapter = nil
  _cfg.enabled = false
end

return M
