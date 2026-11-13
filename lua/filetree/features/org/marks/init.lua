---@module 'filetree.features.org.marks'
---@brief Node marking system — toggle marks, visual indicators, batch operations.
---@description
--- Marks are stored per-session as a set of absolute paths. Visual indicators
--- are rendered as extmarks in the tree buffer. Marked paths are exposed for
--- use in batch operations (copy, move, delete, etc.).
---
--- Auto-clear on idle (`auto_clear_ms`, default 60000): marks otherwise live
--- forever until an explicit `keymap_clear`, or until a batch op that
--- CONSUMED them clears them itself (trash/move/copy_move/diff do; the
--- read-only consumers — pdf_create, markdown_links, path_copy,
--- copy_file_list — deliberately don't, so the same marks can feed several
--- of those in a row). That is a footgun on its own: mark a batch, run one
--- of the read-only actions, get pulled away, come back much later and run
--- an unrelated single-node action (trash/move/... again) expecting it to
--- act on just the node under the cursor — those all PREFER the marked set
--- over the cursor node whenever any mark exists, so it silently acts on the
--- long-stale marks instead. `touch()` below re-arms a `lib.nvim.debounce`
--- countdown on every mark-facing keymap (toggle, mark/unmark all, visual
--- mark, goto/next/prev, show) — genuine mark activity — and once `ms` pass
--- without another touch, all marks clear on their own, with a notify so the
--- "why did that just act on everything" moment has an obvious cause instead
--- of none. Deliberately NOT tied to closing/reopening the tree (nothing in
--- here calls `touch()` from adapter open/close) and NOT touched by internal
--- callers (`M.count()`/`M.get_marked()`/`M.is_marked()`) that merely CHECK
--- for marks as part of unrelated logic (e.g. every trash/move/copy_move
--- call, marked or not) — hooking those would keep re-arming the timer from
--- actions that have nothing to do with actually using the marks, defeating
--- the point of the timeout entirely.
---
--- Output order (`order`, default "marked"): every mark carries a sequence
--- number taken when it was set, and `get_marked()` -- the one accessor every
--- consumer (path_copy incl. `[e`, copy_file_list, markdown_links,
--- file_clipboard, link_create, fileops, pdf_create, diff, ...) goes through -- returns the paths in the
--- order they were marked. Unmarking and re-marking a path moves it to the
--- end. A bulk mark (mark all visible, Visual selection) numbers the newly
--- marked nodes in tree order and leaves already-marked ones where they are.
--- `order = "tree"` restores the old output: sorted by full path.

local notify = require("filetree.util.notify").create("[filetree.marks]")

local bufevents = require("filetree.util.bufevents")
local kit = require("ui.kit")
local bind = require("filetree.util.bind")
local lib_debounce = require("lib.nvim.debounce")
local M = {}

---@type FiletreeMarksConfig
local DEFAULTS = {
  enabled = false,
  indicator = "✓",
  hl_group = "DiagnosticOk",
  keymap = "m",
  keymap_all = "]m",
  keymap_unmark_all = "[m",
  -- Deliberately NOT "<C-m>": outside an extended encoding ("CSI u" /
  -- modifyOtherKeys) Ctrl+M and Enter are the same byte, 0x0D, and Neovim
  -- always resolves that byte to <CR> -- even when nothing maps <CR> at all.
  -- So a "<C-m>" mapping is not "last registration wins" shadowing, it simply
  -- never fires on such a terminal. See TESTS/smoke.lua check 6.
  keymap_clear = "<leader>mc",
  keymap_show = "<leader>ms",
  -- Navigation between marks. `Ngm` jumps to the Nth marked node.
  keymap_goto = "gm",
  keymap_next = "]M",
  keymap_prev = "[M",
  -- Clear all marks after this many ms of no mark activity (see the module
  -- doc comment above); 0 disables the timeout, same "0 = off" convention
  -- as trash's max_history.
  auto_clear_ms = 60000,
  -- Order in which marked paths are handed to every consumer: "marked" (the
  -- order they were marked in) or "tree" (sorted by full path).
  order = "marked",
}

---@type FiletreeMarksConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.marks` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  indicator = "string",
  hl_group = "string",
  keymap = "keymap",
  keymap_all = "keymap",
  keymap_unmark_all = "keymap",
  keymap_clear = "keymap",
  keymap_show = "keymap",
  keymap_goto = "keymap",
  keymap_next = "keymap",
  keymap_prev = "keymap",
  auto_clear_ms = { "number", min = 0 },
  order = { "string", enum = { "marked", "tree" } },
}

---@type FiletreeAdapter?
local _adapter = nil

---Unsubscribe handle for `_adapter.on_render`, when the adapter supports it.
---@type fun()?
local _unsubscribe_render = nil

---@type table<string, integer>  absolute path → sequence number it was marked with
local _marks = {}

---Last sequence number handed out; only ever grows until the set is cleared.
local _seq = 0

---Mark `path` unless it already is (an existing mark keeps its position).
---@param path string
local function set_mark(path)
  if _marks[path] then return end
  _seq = _seq + 1
  _marks[path] = _seq
end

local _ns = nil
local function ns()
  if not _ns then _ns = vim.api.nvim_create_namespace("filetree_marks") end
  return _ns
end

---One lib.nvim.debounce handle, built in M.setup() when auto_clear_ms > 0.
---Every genuine mark-activity keymap re-arms it via `touch()`; once it fires
---uninterrupted, all marks clear themselves. nil when the feature is off
---(auto_clear_ms == 0) or before setup() has run.
---@type Lib.Debounce.Handle|nil
local _debounce = nil

---Re-arm the idle-clear countdown. Call from every mark-facing keymap
---handler (toggle, mark/unmark all, visual mark, goto/next/prev, show) —
---see the module doc comment for why internal "does a mark exist" checks
---(M.count()/M.get_marked()/M.is_marked(), called by unrelated features on
---every run whether or not anything is marked) must NOT call this.
---@internal
local function touch()
  if _debounce then _debounce.call() end
end

-- ── Internal ──────────────────────────────────────────────────────────────────

---`bufnr`, when given, is the tree buffer to redraw -- passed by the
---adapter's `on_render` bridge with the bufnr of whichever tree pass just
---rendered, so this redraws that one specifically instead of falling back to
---the ambient `_adapter.is_open()`/`get_visible_nodes()` "current tab" tree,
---which, with a second tree simultaneously live on another tab, can silently
---be the wrong one (see `adapter/neotree.lua`'s `on_render` doc comment).
---Omitted (the BufEnter/BufWritePost-driven call below, and every keymap-
---driven caller of `redraw()` elsewhere in this file), the ambient lookup is
---already correct -- those only ever run while actually on the tree's own tab.
---@param bufnr? integer
---The own tree's decorator for the marks; nil on every other backend.
---@type Filetree.Decorate.Paths|nil
local _decor = nil

local function redraw(bufnr)
  if not _adapter then return end
  if _decor then
    local map = {}
    for path in pairs(_marks) do
      map[path] = { text = _cfg.indicator, hl = _cfg.hl_group }
    end
    _decor.set(map)
    return
  end
  if not bufnr then
    local is_open, ambient_bufnr = _adapter.is_open()
    if not is_open then return end
    bufnr = ambient_bufnr
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, ns(), 0, -1)

  -- Nothing marked -- clearing the namespace above (stale extmarks from a
  -- prior, now-unmarked state) is still correct and necessary, but the full
  -- tree walk below exists only to find nodes worth marking, so skip it. Worth
  -- doing now specifically: `redraw` fires on every neo-tree narrow redraw
  -- (`on_render`, wired through `renderer.redraw` -- see
  -- `adapter/neotree.lua`'s "Render-event bridge" comment), i.e. any buffer
  -- opening or closing ANYWHERE in the session, not just full tree rescans --
  -- for a session with no marks set (the common case for a user who has never
  -- marked anything) that is a full tree walk on every such event for no
  -- payoff at all.
  if next(_marks) == nil then return end

  local nodes = _adapter.get_visible_nodes(nil, bufnr)
  for _, node in ipairs(nodes) do
    if _marks[node.path] then
      local line = node.line_number - 1
      if line >= 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns(), line, 0, {
          virt_text = { { _cfg.indicator .. " ", _cfg.hl_group } },
          virt_text_pos = "overlay",
          priority = 100,
        })
      end
    end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Toggle the mark on `path`.
---@param path string
---@return boolean  New marked state.
function M.toggle(path)
  if _marks[path] then
    _marks[path] = nil
  else
    set_mark(path)
  end
  touch()
  redraw()
  return _marks[path] ~= nil
end

---Toggle mark on the node currently under the cursor.
---@return boolean?  New marked state, or nil when no node is found.
function M.toggle_current()
  if not _adapter then return nil end
  local node = _adapter.get_current_node()
  if not node then
    notify.warn("no node under cursor")
    return nil
  end
  return M.toggle(node.path)
end

---Return true when `path` is marked.
---@param path string
---@return boolean
function M.is_marked(path)
  return _marks[path] ~= nil
end

---Return all currently marked paths, in the configured `order`: the order
---they were marked in ("marked", default) or sorted by full path ("tree").
---@return string[]
function M.get_marked()
  local out = {}
  for p in pairs(_marks) do
    out[#out + 1] = p
  end
  if _cfg.order == "tree" then
    table.sort(out)
  else
    -- Sequence numbers are unique, so this order is total.
    table.sort(out, function(a, b)
      return _marks[a] < _marks[b]
    end)
  end
  return out
end

---Return the count of marked items.
---@return integer
function M.count()
  local n = 0
  for _ in pairs(_marks) do
    n = n + 1
  end
  return n
end

---Clear all marks. Also cancels any pending auto-clear countdown -- nothing
---left to expire, and letting a stale one fire later would just re-clear an
---already-empty set (harmless, but there's no reason to leave it armed).
function M.clear_all()
  if _debounce then _debounce.cancel() end
  _marks = {}
  _seq = 0
  redraw()
end

---Mark all currently visible nodes. Newly marked nodes are numbered in tree
---order after the existing marks; already-marked ones keep their position.
function M.mark_all_visible()
  if not _adapter then return end
  local nodes = _adapter.get_visible_nodes()
  for _, node in ipairs(nodes) do
    set_mark(node.path)
  end
  touch()
  redraw()
end

---Unmark all currently visible nodes.
function M.unmark_all_visible()
  if not _adapter then return end
  local nodes = _adapter.get_visible_nodes()
  for _, node in ipairs(nodes) do
    _marks[node.path] = nil
  end
  touch()
  redraw()
end

---Marked nodes that are actually on screen, in buffer order.
---
--- `get_marked()` returns paths in mark (or path) order, which is the right
--- answer for "what is marked" and the wrong one for navigation: jumping
--- between marks has to follow the tree as it is rendered, and a marked node
--- inside a collapsed directory has no line to jump to at all.
---@return { path: string, line: integer }[]
---@internal
local function visible_marks()
  if not _adapter then return {} end
  local out = {}
  for _, node in ipairs(_adapter.get_visible_nodes()) do
    if _marks[node.path] and node.line_number and node.line_number > 0 then
      out[#out + 1] = { path = node.path, line = node.line_number }
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line
  end)
  return out
end

---@internal
---@param line integer  1-based
local function goto_line(line)
  if not _adapter then return end
  local is_open, bufnr = _adapter.is_open()
  if not is_open or not bufnr then return end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      return
    end
  end
end

---Jump to the `n`-th marked node (1-based, in render order).
---
--- Clamped rather than refused: with three marks, `9` going to the last one
--- is more useful than an error, and matches how `G` treats an out-of-range
--- count.
---@param n integer|nil  defaults to 1
---@return boolean moved
function M.goto_mark(n)
  local marks = visible_marks()
  if #marks == 0 then
    notify.info("No marked nodes visible")
    return false
  end
  touch()
  local idx = math.max(1, math.min(n or 1, #marks))
  goto_line(marks[idx].line)
  return true
end

---Jump to the next marked node below the cursor, wrapping to the first.
---@param dir integer  1 forward, -1 backward
---@return boolean moved
function M.goto_adjacent_mark(dir)
  if not _adapter then return false end
  local marks = visible_marks()
  if #marks == 0 then
    notify.info("No marked nodes visible")
    return false
  end
  touch()

  local is_open, bufnr = _adapter.is_open()
  if not is_open or not bufnr then return false end
  local cur = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      cur = vim.api.nvim_win_get_cursor(win)[1]
      break
    end
  end

  if dir > 0 then
    for _, m in ipairs(marks) do
      if m.line > cur then
        goto_line(m.line)
        return true
      end
    end
    goto_line(marks[1].line) -- wrap
  else
    for i = #marks, 1, -1 do
      if marks[i].line < cur then
        goto_line(marks[i].line)
        return true
      end
    end
    goto_line(marks[#marks].line) -- wrap
  end
  return true
end

---Mark every node in the current Visual selection.
---
--- The tree had no Visual-mode keymaps at all: marking a run of files meant
--- pressing `m` once per line. The selection's line range maps onto the
--- rendered nodes directly, which is the one thing a tree buffer's Visual
--- mode is genuinely good for.
---@param unmark boolean|nil  # clear instead of set
---@return integer changed
function M.mark_visual(unmark)
  if not _adapter then return 0 end
  local s_line = vim.fn.line("v")
  local e_line = vim.fn.line(".")
  if s_line > e_line then
    s_line, e_line = e_line, s_line
  end

  -- Leave Visual mode first: the marks redraw sets extmarks, and staying in
  -- Visual over a buffer that just changed leaves a stale selection.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)

  local changed = 0
  for _, node in ipairs(_adapter.get_visible_nodes()) do
    local ln = node.line_number
    if ln and ln >= s_line and ln <= e_line then
      -- Explicit branches, not `unmark and nil or true`: `x and nil or y` is
      -- always `y`, which once made unmarking a selection mark it instead.
      if unmark then
        if _marks[node.path] then
          _marks[node.path] = nil
          changed = changed + 1
        end
      elseif not _marks[node.path] then
        set_mark(node.path)
        changed = changed + 1
      end
    end
  end

  touch()
  redraw()
  return changed
end

---Show a floating summary of all marked paths.
function M.show()
  local marked = M.get_marked()
  if #marked == 0 then
    notify.info("No nodes marked")
    return
  end
  touch()

  local lines = {
    string.format("Marked nodes (%d)", #marked),
    string.rep("─", 50),
  }
  for i, p in ipairs(marked) do
    lines[#lines + 1] = string.format("[%02d] %s", i, p)
  end

  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines + 1, vim.o.lines - 6)

  kit.viewer({
    lines = lines,
    title = "Marked Nodes",
    width = width,
    height = height,
  })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeMarksConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter
  if _decor then _decor.remove() end
  _decor = require("filetree.util.decorate").by_path(
    adapter,
    { name = "marks", slot = "sign", priority = 100 }
  )

  -- Cancel any handle from a previous setup() before replacing it -- same
  -- guard every other lib.nvim.debounce owner in this codebase takes (see
  -- e.g. file_watcher/git_status/auto_reveal's own setup()). Normally
  -- unreachable because the top-level filetree.setup() tears down previous
  -- features (which cancels this) before re-running setup(), but that
  -- safety net only holds while teardown() itself does not error -- and
  -- without this guard a stray timer from an aborted teardown would keep
  -- running, uncancellable, since nothing would reference it any more.
  if _debounce then _debounce.cancel() end
  _debounce = nil

  if _cfg.auto_clear_ms and _cfg.auto_clear_ms > 0 then
    _debounce = lib_debounce.new(function()
      -- clear_all() already cancels this timer, so an empty set here should
      -- be rare -- but debounce firing right as some other caller clears the
      -- marks itself is still a race worth guarding, rather than notifying
      -- about clearing a set that's already empty.
      if next(_marks) == nil then return end
      M.clear_all()
      notify.info(
        ("Marks auto-cleared after %ds idle"):format(math.floor(_cfg.auto_clear_ms / 1000))
      )
    end, _cfg.auto_clear_ms)
  end

  -- Redraw marks whenever the tree buffer is entered/refreshed
  bufevents.register("marks", { "BufEnter:*", "BufWritePost:*" }, {
    desc = "[filetree] Re-draw node marks in the tree",
    load = function()
      vim.defer_fn(redraw, 50)
    end,
  })

  -- ...and whenever the adapter re-renders the tree on ITS OWN schedule (a
  -- git-status fetch landing, a filesystem-watcher event, ...). Without this,
  -- a checkmark placed as an extmark on the previous render gets wiped by the
  -- next such redraw and only reappears on the next BufEnter/BufWritePost --
  -- which reads as "the checkmark vanishes after a second". Optional: only
  -- adapters that expose `on_render` (currently neo-tree) get this.
  if type(adapter.on_render) == "function" then _unsubscribe_render = adapter.on_render(redraw) end

  -- Keymaps inside tree buffer
  bind.bind("marks", _cfg, {
    -- `keymap` is one action with two modes: on a line it toggles that node,
    -- over a selection it marks every node the range spans. Same key, same
    -- intent -- so one name, and one thing for a user to move.
    {
      name = "toggle",
      field = "keymap",
      desc = "toggle mark",
      binds = {
        {
          mode = "n",
          desc = "toggle mark",
          rhs = function()
            M.toggle_current()
          end,
        },
        {
          mode = "x",
          desc = "mark selection",
          rhs = function()
            local n = M.mark_visual(false)
            notify.info(("Marked %d node(s)"):format(n))
          end,
        },
      },
    },
    {
      name = "mark_all",
      field = "keymap_all",
      rhs = M.mark_all_visible,
      desc = "mark all visible",
    },
    {
      name = "unmark_all",
      field = "keymap_unmark_all",
      desc = "unmark all visible",
      binds = {
        { mode = "n", desc = "unmark all visible", rhs = M.unmark_all_visible },
        {
          mode = "x",
          desc = "unmark selection",
          rhs = function()
            local n = M.mark_visual(true)
            notify.info(("Unmarked %d node(s)"):format(n))
          end,
        },
      },
    },
    {
      name = "clear",
      field = "keymap_clear",
      desc = "clear all marks",
      rhs = function()
        M.clear_all()
      end,
    },
    {
      name = "show",
      field = "keymap_show",
      desc = "show marked nodes",
      rhs = function()
        M.show()
      end,
    },

    -- Navigation between marks. `Ngm` jumps to the Nth mark, matching how a
    -- count reads on `G`; `]M`/`[M` cycle, wrapping like every other
    -- next/prev pair in this plugin.
    {
      name = "goto",
      field = "keymap_goto",
      desc = "jump to the Nth marked node",
      rhs = function()
        M.goto_mark(vim.v.count ~= 0 and vim.v.count or 1)
      end,
    },
    {
      name = "next",
      field = "keymap_next",
      desc = "next marked node",
      rhs = function()
        M.goto_adjacent_mark(1)
      end,
    },
    {
      name = "prev",
      field = "keymap_prev",
      desc = "previous marked node",
      rhs = function()
        M.goto_adjacent_mark(-1)
      end,
    },
  })
end

function M.teardown()
  bufevents.unregister("marks")
  if _decor then _decor.remove() end
  _decor = nil
  if _unsubscribe_render then
    _unsubscribe_render()
    _unsubscribe_render = nil
  end
  if _debounce then
    _debounce.cancel()
    _debounce = nil
  end
  _marks = {}
  _seq = 0
  if _adapter then
    local _, bufnr = _adapter.is_open()
    if bufnr then pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns(), 0, -1) end
  end
  _adapter = nil
end

return M
