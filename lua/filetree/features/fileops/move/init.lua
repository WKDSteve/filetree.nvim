---@module 'filetree.features.fileops.move'
--- Move the node under the cursor (or every marked node) to a destination
--- typed into a prompt — the one-step counterpart to copy_move's stage-and-
--- paste, and the place the reference engine's move flow is most visible.
---
---   M   Move current node / all marked nodes
---
--- The prompt takes anything a path can be: relative to the cwd (`docs/`),
--- absolute, or `~`-prefixed, with `<Tab>` completing directories. What the
--- destination *means* depends on what is being moved:
---
---   * several nodes, or a destination that already exists as a directory
---     → the items are moved **into** it, keeping their names;
---   * a single node and a destination that does not exist
---     → that becomes the item's new full path, so `M` doubles as a
---       move-and-rename (`docs/Test.md` from a `Test.md` at the root).
---
--- A destination directory that doesn't exist yet is offered for creation
--- rather than silently created, and a name collision asks the same
--- Overwrite / Keep both / Cancel question copy_move's paste does.
---
--- Reference handling: the scan starts the moment the keymap is pressed — that
--- is, while the sources still sit at their old paths — and the move itself
--- happens inside its callback, so links and imports are always resolved
--- against the layout they were written for. See `filetree.refs`.
---
--- Commands (via :Filetree dispatcher):
---   :Filetree move [destination]

local notify = require("filetree.util.notify").create("[filetree.move]")

local path = require("filetree.util.path")
local buffer = require("filetree.util.buffer")
local conflict = require("filetree.util.conflict")
-- Case-insensitive-FS guard: a single-target move whose destination differs
-- from the source only by case is a rename, not a collision — and "Overwrite"
-- on such a "collision" would delete the source. See filetree.util.case_clash.
local case_clash = require("filetree.util.case_clash")
local mutate = require("filetree.util.mutate")
local confirm_choice = require("filetree.util.confirm_choice")
local progress = require("filetree.util.progress")
local refs = require("filetree.refs")

local kit = require("ui.kit")
local bind = require("filetree.util.bind")
local hooks = require("filetree.util.hooks")

local M = {}

---@type FiletreeMoveConfig
local DEFAULTS = {
  enabled = false,
  keymap = "M",
  use_safety = true,
  dry_run = false,
}

---@type FiletreeMoveConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.move` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  use_safety = "boolean",
  dry_run = "boolean",
}

---@type FiletreeAdapter?
local _adapter = nil

-- ── Targets ───────────────────────────────────────────────────────────────────

---@internal
---Marked nodes if there are any, else the node under the cursor.
---@return string[]
local function get_targets()
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks and marks.count() > 0 then return marks.get_marked() end
  if not _adapter then return {} end
  local node = _adapter.get_current_node()
  return node and node.path and { node.path } or {}
end

---@internal
local function clear_marks()
  local ok, marks = require("filetree.features").load("marks")
  if ok and marks then pcall(marks.clear_all) end
end

-- ── Destination resolution ────────────────────────────────────────────────────

---@class FiletreeMovePlan
---@field ops { src: string, dst: string }[]
---@field dir string   Directory that must exist before the move runs.

---@internal
---Turn the raw prompt input into a concrete list of `src → dst` pairs.
---@param input string
---@param targets string[]
---@return FiletreeMovePlan|nil plan, string? err
local function build_plan(input, targets)
  local dest = path.slashify(path.to_absolute(path.slashify(input)))
  dest = dest:gsub("/+$", "")
  if dest == "" then return nil, "empty destination" end

  -- A single target whose destination is just its own name re-cased is a
  -- rename: `isdirectory(dest)` would otherwise be true (the OS folds the
  -- casing) and wrongly route it "into" the directory it already is.
  local single_case_rename = #targets == 1 and case_clash.is_alias(targets[1], dest)

  local into_dir = not single_case_rename
    and (
      #targets > 1
      or vim.fn.isdirectory(dest) == 1
      -- A trailing slash is the user saying "this is a directory" even when it
      -- does not exist yet, so honour it instead of treating the last segment
      -- as the item's new name.
      or input:match("[/\\]%s*$") ~= nil
    )

  local ops = {}
  if into_dir then
    for _, src in ipairs(targets) do
      ops[#ops + 1] = { src = src, dst = dest .. "/" .. path.basename(src) }
    end
    return { ops = ops, dir = dest }, nil
  end

  ops[1] = { src = targets[1], dst = dest }
  return { ops = ops, dir = path.parent(dest) }, nil
end

-- ── Execution ─────────────────────────────────────────────────────────────────

---@internal
---@param plan FiletreeMovePlan
---@param resolution "Overwrite"|"Keep both"|nil
---@param scan_result FiletreeRefScanResult
local function run(plan, resolution, scan_result)
  if _cfg.use_safety then
    local ok_s, safety = require("filetree.features").load("safety")
    if ok_s and safety then
      for _, op in ipairs(plan.ops) do
        pcall(safety.before_move, op.src, op.dst)
      end
    end
  end

  local prog = #plan.ops > 1 and progress.create({ title = "[filetree.move]" }) or nil
  local moves, errors, relocated = {}, 0, 0
  local claimed = {}

  for i, op in ipairs(plan.ops) do
    if prog then
      prog:update({ text = path.basename(op.src), current = i - 1, total = #plan.ops })
    end

    local dst = op.dst
    -- Set below when a collision cannot be resolved; the operation is then
    -- counted as an error and skipped. A flag rather than `dst = nil`, so the
    -- collision handling below still works on a plain string.
    local skip = false
    -- A case-only rename resolves to the source itself: not a real collision,
    -- and clearing it (the "Overwrite" path) would delete the source.
    if conflict.exists(dst) and not case_clash.is_alias(op.src, dst) then
      if resolution == "Overwrite" then
        if not conflict.remove_existing(dst) then
          notify.error("Could not clear existing target: " .. path.relative(dst))
          errors = errors + 1
          skip = true
        end
      elseif resolution == "Keep both" then
        local dir = path.parent(dst)
        dst = dir
          .. "/"
          .. conflict.unique_name(dir, path.basename(dst), claimed, vim.fn.isdirectory(op.src) == 1)
      else
        notify.error("Target exists, skipping: " .. path.relative(dst))
        errors = errors + 1
        skip = true
      end
    end

    if not skip then
      hooks.emit("before_move", { src = op.src, dst = dst })
      local ok, err = mutate.move(op.src, dst)
      hooks.emit("after_move", { src = op.src, dst = dst, ok = ok == true })
      if not ok then
        notify.error(
          string.format(
            "Failed: %s → %s (%s)",
            path.relative(op.src),
            path.relative(dst),
            tostring(err)
          )
        )
        errors = errors + 1
      else
        relocated = relocated + buffer.relocate(op.src, dst)
        moves[op.src] = dst
      end
    end
  end

  local done = #plan.ops - errors
  local msg = string.format("Moved %d/%d item(s) to %s", done, #plan.ops, path.relative(plan.dir))
  if relocated > 0 then msg = msg .. string.format(" (%d open buffer(s) repointed)", relocated) end
  if prog then prog:finish(msg) end
  notify.info(msg)

  -- Refresh only once handle_result's own apply (incoming refs AND, when
  -- enabled, the moved file(s)' own outgoing links -- own_links.collect is
  -- asynchronous) has actually landed, not immediately after this call
  -- returns: handle_result is fire-and-forget for a reason, but a refresh
  -- that runs before the rewrite is on disk would show the tree mid-apply.
  refs.handle_result(scan_result, moves, { op = "move" }, function()
    clear_marks()
    if _adapter and _adapter.refresh then pcall(_adapter.refresh) end
  end)
end

---@internal
---Ask about collisions (if any), then run.
---@param plan FiletreeMovePlan
---@param scan_result FiletreeRefScanResult
local function run_with_conflict_check(plan, scan_result)
  local clashing = {}
  for _, op in ipairs(plan.ops) do
    if conflict.exists(op.dst) and not case_clash.is_alias(op.src, op.dst) then
      clashing[#clashing + 1] = path.basename(op.dst)
    end
  end

  if #clashing == 0 then
    run(plan, nil, scan_result)
    return
  end

  confirm_choice(
    string.format(
      "%d item(s) already exist in %s:\n  %s",
      #clashing,
      path.relative(plan.dir),
      table.concat(clashing, ", ")
    ),
    { "Overwrite", "Keep both", "Cancel" },
    function(choice)
      if choice == nil or choice == "Cancel" then
        notify.info("Move cancelled")
        return
      end
      run(plan, choice, scan_result)
    end
  )
end

---@internal
---Make sure `dir` exists, asking first when it doesn't, then continue.
---@param dir string
---@param continue fun()
local function ensure_dir(dir, continue)
  if vim.fn.isdirectory(dir) == 1 then return continue() end

  confirm_choice(
    "Directory does not exist: " .. path.relative(dir),
    { "Create", "Cancel" },
    function(choice)
      if choice ~= "Create" then
        notify.info("Move cancelled")
        return
      end
      if vim.fn.mkdir(dir, "p") == 0 then
        notify.error("Could not create " .. path.relative(dir))
        return
      end
      continue()
    end
  )
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Move the current node (or all marked nodes). With `destination` given the
---prompt is skipped — that is what `:Filetree move <dir>` uses.
---@param destination string?
function M.move(destination)
  local targets = get_targets()
  if #targets == 0 then
    notify.warn("No node selected")
    return
  end

  -- Start the reference scan NOW, while every source is still at its old path:
  -- the move only happens inside `await`, strictly after this finished.
  local refs_handle = refs.prefetch(targets, { op = "move" })

  ---@param input string
  local function proceed(input)
    if not input or vim.trim(input) == "" then return end

    local plan, err = build_plan(input, targets)
    if not plan then
      notify.error(err or "invalid destination")
      return
    end

    for _, op in ipairs(plan.ops) do
      if path.slashify(op.src) == path.slashify(op.dst) then
        notify.info("Source and destination are the same")
        return
      end
      if
        vim.fn.isdirectory(op.src) == 1
        and vim.startswith(path.slashify(op.dst) .. "/", path.slashify(op.src) .. "/")
      then
        notify.error("Cannot move a directory into itself: " .. path.relative(op.src))
        return
      end
    end

    if _cfg.dry_run then
      local lines = { "-- Move plan (dry-run) --" }
      for _, op in ipairs(plan.ops) do
        lines[#lines + 1] = "  " .. path.relative(op.src) .. " → " .. path.relative(op.dst)
      end
      notify.info(table.concat(lines, "\n"))
      return
    end

    ensure_dir(plan.dir, function()
      refs_handle.await(function(scan_result)
        run_with_conflict_check(plan, scan_result)
      end)
    end)
  end

  if destination and destination ~= "" then
    proceed(destination)
    return
  end

  local what = #targets == 1 and path.basename(targets[1]) or string.format("%d items", #targets)
  kit.input({
    title = "Move " .. what .. " to: ",
    completion = "dir",
    on_submit = proceed,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeMoveConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  bind.bind("move", _cfg, {
    {
      name = "move",
      field = "keymap",
      rhs = function()
        M.move()
      end,
      desc = "move node(s) to…",
    },
  })
end

function M.teardown()
  _adapter = nil
end

return M
