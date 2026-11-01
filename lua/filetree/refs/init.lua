---@module 'filetree.refs'
--- Reference engine — the single place that knows "file X moves to Y, who
--- points at X, and how must that pointer read afterwards?".
---
--- Every filesystem mutation in filetree.nvim routes through here instead of
--- carrying its own copy of the scan/ask/rewrite dance:
---
---   smart_rename ─┐
---   copy_move   ──┼──►  filetree.refs  ──►  providers ──► confirm ──► apply
---   rename_batch ─┤     (scan/resolve)      (markdown,     (chooser,   (buffer
---   move        ──┤                          lua, python,   picker,     or disk,
---   trash       ──┘                          ts_js, …)      diff)       undoable)
---
--- Usage — always prefetch first, mutate second:
---
---   local handle = refs.prefetch({ old_path }, { op = "rename" })
---   -- ... user types a new name / navigates to a target ...
---   handle.await(function(result)
---     -- the scan is finished and saw the file at its OLD location
---     do_the_rename()
---     refs.handle_result(result, { [old_path] = new_path }, { op = "rename" })
---   end)
---
--- The prefetch/await split is what makes this race-free: the scan starts while
--- the file still exists and the mutation happens strictly inside the await
--- callback, so a reference can never be missed because the file moved out from
--- under the scanner.

local registry = require("filetree.refs.registry")
local scan = require("filetree.refs.scan")
local apply = require("filetree.refs.apply")
local ui = require("filetree.refs.ui")
local outgoing = require("filetree.refs.outgoing")
local own_links = require("filetree.refs.own_links")
local assets = require("filetree.refs.assets")
local usage = require("filetree.refs.usage")
local ftpath = require("filetree.util.path")
local notify = require("filetree.util.notify").create("[filetree.refs]")

local M = {}

M.registry = registry
M.apply = apply
M.ui = ui
M.assets = assets
M.usage = usage

-- ── Config ────────────────────────────────────────────────────────────────────

-- Shared with `filetree.config.DEFAULTS` (one table, two consumers — see
-- filetree/refs/DEFAULTS.lua) so a default can never mean one thing to
-- `setup({ refs = … })` and another to the engine itself.
---@type FiletreeRefsConfig
local DEFAULTS = require("filetree.refs.DEFAULTS")

---@type FiletreeRefsConfig
local _cfg = vim.deepcopy(DEFAULTS)

---@param cfg FiletreeRefsConfig?
function M.setup(cfg)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), cfg or {})
end

---@return FiletreeRefsConfig
function M.config()
  return _cfg
end

---Register an extra provider (see `filetree.refs.registry`).
---@param provider FiletreeRefProvider
---@return boolean ok, string? err
function M.register(provider)
  return registry.register(provider)
end

-- ── Built-in providers ────────────────────────────────────────────────────────
-- Registration order doubles as display order in the chooser's summary.

registry.register(require("filetree.refs.providers.markdown"))
registry.register(require("filetree.refs.providers.lua"))
registry.register(require("filetree.refs.providers.python"))
registry.register(require("filetree.refs.providers.ts_js"))
-- Experimental, self-gated: its `plan()` returns nil unless
-- `refs.experimental.plaintext.enabled` is set, so registering it
-- unconditionally is inert until asked for.
registry.register(require("filetree.refs.providers.plaintext"))

-- ── Mode helpers ──────────────────────────────────────────────────────────────

---The configured mode for an operation, honouring a per-call override.
---@param op "rename"|"move"|"delete"|"copy"
---@param override? "ask"|"auto"|"off"
---@return "ask"|"auto"|"off"
function M.mode(op, override)
  if override then return override end
  if not _cfg.enabled then return "off" end
  if op == "copy" then return _cfg.copy and _cfg.on_move or "off" end
  if op == "delete" then return _cfg.on_delete end
  if op == "move" then return _cfg.on_move end
  return _cfg.on_rename
end

---Whether a scan for `op` would do anything at all — checked by call sites
---before they pay for a prefetch.
---@param op "rename"|"move"|"delete"|"copy"
---@param override? "ask"|"auto"|"off"
---@return boolean
function M.active(op, override)
  return M.mode(op, override) ~= "off" and #registry.enabled(_cfg) > 0
end

---The configured mode for the cascade-delete-assets check, honouring a
---per-call override. Deliberately its own switch, not folded into `M.mode`:
---it governs the OPPOSITE direction (what a file about to be deleted points
---at, not who points at it), so a user may want one without the other —
---see `FiletreeRefsOutgoingAssetsConfig`.
---@param override? "ask"|"auto"|"off"
---@return "ask"|"auto"|"off"
function M.outgoing_assets_mode(override)
  if override then return override end
  local oa = _cfg.outgoing_assets
  if not oa or not oa.enabled then return "off" end
  return oa.on_delete or "ask"
end

---The configured mode for rewriting a moved/renamed/copied file's OWN
---outgoing links, honouring a per-call override. Unset `outgoing_links.mode`
---inherits `on_move`/`on_rename` for the same op (the common case: both
---directions should behave the same way, so a move asks — or auto-applies —
---once, not twice).
---
---For "copy" specifically this does NOT go through `M.mode("copy")`, which is
---gated behind `_cfg.copy` — a DIFFERENT, unrelated switch for whether a copy
---gets an INCOMING-ref scan at all (default off: a copy leaves the original
---in place, so nothing points at it needs fixing). A copy's own outgoing
---links are a real, separate problem (the pasted copy's relative links may
---now be wrong even though nothing else references it), so an unset
---`outgoing_links.mode` inherits `on_move` directly for a copy instead.
---@param op "rename"|"move"|"copy"
---@param override? "ask"|"auto"|"off"
---@return "ask"|"auto"|"off"
function M.outgoing_links_mode(op, override)
  if override then return override end
  local ol = _cfg.outgoing_links
  if not ol or not ol.enabled or not _cfg.enabled then return "off" end
  if ol.mode then return ol.mode end
  if op == "copy" then return _cfg.on_move end
  return M.mode(op)
end

-- ── Context ───────────────────────────────────────────────────────────────────

---Search root for `path`: the nearest project root, or the cwd.
---@param path string
---@return string
local function resolve_root(path)
  if _cfg.scan and _cfg.scan.root == "cwd" then return vim.fn.getcwd() end
  local ok_pr, project_root = require("filetree.features").load("project_root")
  if ok_pr and project_root and type(project_root.find) == "function" then
    local ok_find, found = pcall(project_root.find, ftpath.parent(path))
    if ok_find and type(found) == "string" and found ~= "" then return found end
  end
  return vim.fn.getcwd()
end

---@param path string
---@param opts? { root?: string }
---@return FiletreeRefCtx
local function make_ctx(path, opts)
  return {
    root = (opts and opts.root) or resolve_root(path),
    -- Computed while the path still exists — a moved-away directory would
    -- otherwise report as "not a directory" and silently disable the
    -- prefix matching every provider needs for a directory move.
    is_dir = vim.fn.isdirectory(path) == 1,
    cfg = _cfg,
  }
end

---The search root `refs` would use for `path` (nearest project root, or the cwd).
---@param path string
---@return string
function M.resolve_root(path)
  return resolve_root(path)
end

---The scan context for `path` — what a provider's `plan()` is handed.
---@param path string
---@param opts? { root?: string }
---@return FiletreeRefCtx
function M.context(path, opts)
  return make_ctx(path, opts)
end

-- ── Scan ──────────────────────────────────────────────────────────────────────

---Start scanning for references to `paths` and return a handle whose
---`await(cb)` delivers the result — immediately when the scan already
---finished, else when it does.
---
---Call this the moment the user triggers the action (while the files still
---exist), and perform the mutation inside `await`.
---@param paths string[]
---@param opts? { op?: "rename"|"move"|"delete"|"copy", mode?: "ask"|"auto"|"off", root?: string }
---@return { await: fun(cb: fun(result: FiletreeRefScanResult)) }
function M.prefetch(paths, opts)
  opts = opts or {}
  local state = { done = false, result = nil, waiters = {} }

  ---@param result FiletreeRefScanResult
  local function finish(result)
    state.result = result
    state.done = true
    local waiters = state.waiters
    state.waiters = {}
    for _, w in ipairs(waiters) do
      w(result)
    end
  end

  ---@type FiletreeRefScanResult
  local result = { refs = {}, plans = {} }

  -- Nothing to scan resolves *synchronously*, on purpose: `await` then runs its
  -- callback inline, so a paste with no cut items, or a setup with references
  -- switched off, is not deferred by an event-loop tick it has no use for.
  if not M.active(opts.op or "move", opts.mode) or #paths == 0 then
    finish(result)
    return {
      await = function(cb)
        if state.done then
          cb(state.result)
        else
          state.waiters[#state.waiters + 1] = cb
        end
      end,
    }
  end

  -- Build every (path, provider) plan up front, then run them all in parallel.
  local jobs = {}
  for _, path in ipairs(paths) do
    local ctx = make_ctx(path, opts)
    for _, provider in ipairs(registry.enabled(_cfg)) do
      local ok, plan = pcall(provider.plan, path, ctx)
      if ok and plan then
        result.plans[path] = result.plans[path] or {}
        result.plans[path][provider.name] = plan
        jobs[#jobs + 1] = { plan = plan, ctx = ctx }
      elseif not ok then
        notify.debug(
          string.format(
            "provider '%s' failed to plan for %s: %s",
            provider.name,
            path,
            tostring(plan)
          )
        )
      end
    end
  end

  if #jobs == 0 then
    finish(result) -- no provider had anything to look for
  else
    local pending = #jobs
    -- One session for all jobs: when their ripgrep runs die together, the
    -- fallback lists the tree once and warns once, not once per job.
    local session = scan.new_session()
    for _, job in ipairs(jobs) do
      scan.run_plan(job.plan, job.ctx, function(refs, incomplete)
        if incomplete then result.incomplete = true end
        for _, r in ipairs(refs) do
          result.refs[#result.refs + 1] = r
        end
        pending = pending - 1
        if pending == 0 then finish(result) end
      end, session)
    end
  end

  return {
    await = function(cb)
      if state.done then
        cb(state.result)
      else
        state.waiters[#state.waiters + 1] = cb
      end
    end,
  }
end

---The candidate search was cut short (ripgrep failed and the fallback walk hit its cap or was
---cancelled), so references may be missing. Says so right where the user decides, because the
---dialog (or its absence when nothing was found) would otherwise read as "all references seen".
---@param result FiletreeRefScanResult
local function warn_if_incomplete(result)
  if result and result.incomplete then
    notify.warn("The reference search was cut short: some references may be missing")
  end
end

---Scan without the prefetch/await split, for callers that have nothing to
---overlap it with (the delete flow, which must know the refs before it can
---even draw its confirmation).
---@param paths string[]
---@param opts? table
---@param cb fun(result: FiletreeRefScanResult)
function M.scan(paths, opts, cb)
  M.prefetch(paths, opts).await(cb)
end

-- ── Resolve ───────────────────────────────────────────────────────────────────

---Set `new_target` on every ref of a scan result, given what moved where.
---
---Refs whose provider cannot express the new location (a Python relative
---import that left its package, a Lua file moved outside every `lua/` root)
---are dropped from the returned list and counted separately, so the caller can
---say so instead of silently doing nothing.
---@param result FiletreeRefScanResult
---@param moves table<string, string>  old path → new path
---@param opts? { lsp_handled?: boolean }
---@return FiletreeRef[] resolved, integer unresolved
function M.resolve(result, moves, opts)
  opts = opts or {}
  local out, unresolved = {}, 0

  for _, ref in ipairs(result.refs) do
    local new_path = moves[ref.source]
    local plan = result.plans[ref.source] and result.plans[ref.source][ref.provider]

    -- An LSP client that handled the rename already rewrote the code
    -- references; re-applying them textually would be at best a no-op and at
    -- worst a double edit. Providers whose language never gets that treatment
    -- (markdown has no server, lua_ls does not implement willRenameFiles) opt
    -- out of the skip via `lsp_exempt`.
    local provider = registry.get(ref.provider)
    local skip_lsp = opts.lsp_handled and _cfg.prefer_lsp and not (provider and provider.lsp_exempt)

    if new_path and plan and not skip_lsp then
      local ok, target = pcall(plan.retarget, ref, new_path)
      if ok and type(target) == "string" and target ~= "" and target ~= ref.target then
        ref.new_target = target
        out[#out + 1] = ref
      elseif not ok or target == nil then
        unresolved = unresolved + 1
      end
    end
  end

  return out, unresolved
end

-- ── High-level flows ──────────────────────────────────────────────────────────

---Resolve a finished scan against the moves that just happened, then ask (or
---not, per config) and apply. The one call a mutating feature needs after its
---rename/move succeeded.
---
---Also collects `outgoing_links` edits — the moved file(s)' OWN outgoing
---links, rewritten to still resolve from their new location (see
---`filetree.refs.own_links`) — and folds them in alongside the incoming-refs
---list: in the common case (both directions land on the same effective
---mode), everything goes through ONE confirmation dialog and ONE undo token.
---Only an explicitly configured divergent `outgoing_links.mode` splits it
---into two independent applies.
---
---`own_links.collect` is asynchronous (a large batch is chunked across
---event-loop ticks, see its own doc comment), so everything after it is
---known runs inside its callback — this function itself stays fire-and-
---forget for its caller, same as it always has been (`done` is already the
---only completion signal callers rely on).
---
---No batch-wide root is computed here (unlike the incoming-refs path just
---above): `own_links.collect` resolves each file's project root on its own,
---per file, since a batch can legitimately span more than one nested
---project root and any single shared value would be wrong for every file
---but the one it happened to be resolved from.
---@param result FiletreeRefScanResult
---@param moves table<string, string>   old path → new path
---@param opts? { op?: "rename"|"move"|"copy", mode?: "ask"|"auto"|"off", picker?: string, title?: string, lsp_handled?: boolean, root?: string, own_links_mode?: "ask"|"auto"|"off" }
---@param done? fun(applied: integer)
function M.handle_result(result, moves, opts, done)
  opts = opts or {}
  done = done or function() end
  warn_if_incomplete(result)

  local resolved, unresolved = M.resolve(result, moves, opts)
  if unresolved > 0 then
    notify.warn(
      string.format(
        "%d reference(s) could not be rewritten automatically (left untouched)",
        unresolved
      )
    )
  end

  local op = opts.op or "move"
  local own_mode = M.outgoing_links_mode(op, opts.own_links_mode)

  ---@param own_edits FiletreeRef[]
  local function continue_with_own_edits(own_edits)
    if #resolved == 0 and #own_edits == 0 then return done(0) end

    local names = {}
    for old in pairs(moves) do
      names[#names + 1] = ftpath.basename(old)
    end

    local incoming_mode = M.mode(op, opts.mode)
    local picker = opts.picker or _cfg.picker
    local title = opts.title or ("References to " .. table.concat(names, ", "))
    local label = string.format("%s: %s", op, table.concat(names, ", "))

    -- Common case: nothing to split, or both directions share one effective
    -- mode — one dialog, one undo token for the whole operation. The mode to
    -- apply under is whichever side actually has edits when only one does;
    -- with both present they only reach this branch by already sharing one.
    if #own_edits == 0 or #resolved == 0 or own_mode == incoming_mode then
      local combined = {}
      for _, r in ipairs(resolved) do
        combined[#combined + 1] = r
      end
      for _, r in ipairs(own_edits) do
        combined[#combined + 1] = r
      end
      local mode = #own_edits == 0 and incoming_mode or own_mode
      ui.apply_with_confirmation(
        combined,
        { mode = mode, picker = picker, title = title, label = label },
        done
      )
      return
    end

    -- Explicitly divergent modes: two independent applies/undo entries.
    local pending, total_applied = 2, 0
    local function one_done(n)
      total_applied = total_applied + n
      pending = pending - 1
      if pending == 0 then done(total_applied) end
    end
    ui.apply_with_confirmation(
      resolved,
      { mode = incoming_mode, picker = picker, title = title, label = label },
      one_done
    )
    ui.apply_with_confirmation(own_edits, {
      mode = own_mode,
      picker = picker,
      title = "Links inside the moved file(s)",
      label = string.format("%s (own links): %s", op, table.concat(names, ", ")),
    }, one_done)
  end

  if own_mode == "off" or not next(moves) then
    continue_with_own_edits({})
    return
  end

  local ok, err = pcall(own_links.collect, moves, {
    op = op,
    root = opts.root,
    cfg = _cfg,
  }, continue_with_own_edits)
  if not ok then
    notify.debug("own_links.collect failed: " .. tostring(err))
    continue_with_own_edits({})
  end
end

---Await `handle` and hand its result to `handle_result` — the shorthand for
---the common "prefetch, mutate, then deal with the refs" shape.
---@param handle { await: fun(cb: fun(result: FiletreeRefScanResult)) }|nil
---@param moves table<string, string>
---@param opts? table
---@param done? fun(applied: integer)
function M.handle_move(handle, moves, opts, done)
  if not handle then return (done or function() end)(0) end
  handle.await(function(result)
    M.handle_result(result, moves, opts, done)
  end)
end

---References that would break if `paths` were deleted, each pre-set to the
---provider's "broken reference" marker (markdown links become `REF!`).
---
---Only providers that declare a `delete_target` take part: blanking a
---`require("…")` would leave code that no longer parses meaningfully, which is
---worse than an obviously dangling link, so the code providers deliberately
---sit this one out.
---@param paths string[]
---@param opts? table
---@param cb fun(refs: FiletreeRef[])
function M.for_delete(paths, opts, cb)
  opts = vim.tbl_extend("force", { op = "delete" }, opts or {})
  M.scan(paths, opts, function(result)
    warn_if_incomplete(result)
    local out = {}
    for _, ref in ipairs(result.refs) do
      local provider = registry.get(ref.provider)
      local marker = provider and provider.delete_target
      if marker then
        ref.new_target = marker
        out[#out + 1] = ref
      end
    end
    cb(out)
  end)
end

---Outgoing links found in `path`'s own current content, resolved to absolute
---paths — the mirror of `for_delete` above: that one asks "who points at
---this file", this asks "what does this file point at". Step 1 of the
---cascade-delete-assets feature — no assets-folder/extension classifier
---here (see `filetree.refs.assets`), every resolved link target comes back. Call it the moment a delete is triggered, while `path` still
---exists (same prefetch-before-mutation discipline as `prefetch` above).
---@param path string
---@param opts? { root?: string }
---@param cb fun(links: FiletreeOutgoingLink[])
function M.outgoing(path, opts, cb)
  outgoing.scan(path, opts, cb)
end

---Outgoing links of `path` (the file about to be deleted), classified: which
---of them resolve under a configured assets root with an allowed extension
---(`is_asset`), and — only for those — whether some other surviving file
---still references the same target (`still_referenced`). Wired into `d`/
---`trash`'s confirm dialog (step 3).
---
---Gated on `refs.outgoing_assets.enabled`/`on_delete` (default: off — see
---`outgoing_assets_mode`), independently of the main `on_delete` switch
---above; `opts.mode` overrides it for one call the same way `opts.mode`
---overrides `M.mode` elsewhere in this module. `opts.roots`/`opts.extensions`
---override the configured defaults for one call; when omitted, the
---configured (or built-in default) values are used.
---@param path string
---@param opts? { root?: string, roots?: string[], extensions?: string[], mode?: "ask"|"auto"|"off" }
---@param cb fun(candidates: FiletreeAssetCandidate[])
function M.outgoing_assets(path, opts, cb)
  opts = opts or {}
  if M.outgoing_assets_mode(opts.mode) == "off" then return cb({}) end
  local oa = _cfg.outgoing_assets or {}
  assets.classify(path, {
    root = opts.root,
    roots = opts.roots or oa.roots,
    extensions = opts.extensions or oa.extensions,
  }, cb)
end

-- ── Undo ──────────────────────────────────────────────────────────────────────

---Undo the most recent reference update.
function M.undo()
  if not apply.can_undo() then
    notify.info("Nothing to undo")
    return
  end
  local label = apply.last_label()
  apply.undo(function(restored, files, _, skipped)
    if restored > 0 then
      local msg = string.format(
        "Reverted %d line(s) in %d file(s) (%s)",
        restored,
        files,
        label or "reference update"
      )
      -- A line that changed since the rewrite is left alone on purpose, but
      -- saying nothing about it would present a partial revert as a complete
      -- one -- and those lines still hold the rewritten target.
      if skipped > 0 then
        notify.warn(msg .. string.format("; %d line(s) changed since, left alone", skipped))
      else
        notify.info(msg)
      end
    else
      notify.warn("Nothing was reverted (files changed since the update?)")
    end
  end)
end

---Summary of the current state, for `:Filetree refs status`.
---@return string[]
function M.status()
  local lines = {
    string.format("enabled: %s", tostring(_cfg.enabled)),
    string.format(
      "rename: %s   move: %s   delete: %s   copy: %s",
      _cfg.on_rename,
      _cfg.on_move,
      _cfg.on_delete,
      tostring(_cfg.copy)
    ),
    string.format(
      "scan root: %s   ripgrep: %s",
      (_cfg.scan and _cfg.scan.root) or "project",
      vim.fn.executable("rg") == 1 and "yes" or "no (capped fallback walk)"
    ),
    "providers:",
  }
  local flags = _cfg.providers or {}
  local plaintext_on = _cfg.experimental
    and _cfg.experimental.plaintext
    and _cfg.experimental.plaintext.enabled == true
  for _, p in ipairs(registry.all()) do
    -- `plaintext` is gated by `experimental.plaintext.enabled`, not by the
    -- `providers` map every other provider reads, so report its real state.
    -- Branch explicitly: `cond and plaintext_on or <other>` falls through to
    -- the other branch whenever plaintext_on is false/nil -- i.e. exactly when
    -- the provider is off -- and reported it as on.
    local on
    if p.name == "plaintext" then
      on = plaintext_on == true
    else
      on = flags[p.name] ~= false
    end
    local tag = p.name == "plaintext" and "  (experimental)" or ""
    lines[#lines + 1] = string.format("  %s %s%s", on and "●" or "○", p.name, tag)
  end

  local oa = _cfg.outgoing_assets or {}
  lines[#lines + 1] = string.format(
    "outgoing_assets: enabled=%s  on_delete=%s  roots=%s  extensions=%s",
    tostring(oa.enabled == true),
    oa.on_delete or "ask",
    -- `roots`/`extensions` are unset by default (see DEFAULTS.lua) and fall
    -- back to `assets`' own built-in lists at call time — mirror that here so
    -- the status line reflects what a scan would actually use.
    table.concat(oa.roots or assets.DEFAULT_ROOTS, ","),
    table.concat(oa.extensions or assets.DEFAULT_EXTENSIONS, ",")
  )

  local ol = _cfg.outgoing_links or {}
  lines[#lines + 1] = string.format(
    "outgoing_links: enabled=%s  mode=%s  env_vars=%s",
    tostring(ol.enabled == true),
    ol.mode or "(inherits move/rename)",
    table.concat(ol.env_vars or {}, ",")
  )

  lines[#lines + 1] = apply.can_undo() and ("undo available: " .. (apply.last_label() or "?"))
    or "undo available: —"
  return lines
end

return M
