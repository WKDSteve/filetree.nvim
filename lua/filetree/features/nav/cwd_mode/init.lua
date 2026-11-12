---@module 'filetree.features.nav.cwd_mode'
--- Root policy: decide *where* the cwd and the tree root belong.
---
--- cwd_sync answers "the buffer changed, now what?" statelessly — it
--- re-resolves a root from the file on every BufEnter. A *mode* is by
--- definition state: "keep the cwd here regardless of which buffer is
--- focused". This module holds that state; cwd_sync stays the executor and
--- asks `decide()` before it changes anything.
---
--- Modes:
---
---   follow    No policy — cwd_sync's own resolution applies unchanged
---             (root_markers → project_root → the file's parent). `decide()`
---             deliberately returns nil here, so enabling this feature with
---             the default mode changes no behaviour at all.
---   project   The cwd stays at the current project root as long as the
---             focused file lives inside it, and only moves when a file
---             outside it is opened. With `project.sticky` (default) a file
---             with no detectable root of its own — a scratch note, a file
---             in /tmp — does not drag the cwd along either.
---   nearest   Same shape as `project`, but walks to the nearest *package*
---             boundary (package.json, Cargo.toml, go.mod, …) instead of the
---             repository root — monorepo work, where "the project" means
---             "the package I'm editing".
---   lock      The cwd is pinned to one directory. Buffer switches never
---             move it, and with `lock.enforce` (default) neither does
---             foreign code: a `lib.nvim.fs.dir_guard` reverts a `:cd` from
---             a picker, a session restore or another plugin.
---   manual    Nothing automatic. The cwd and the tree root only change
---             through explicit action (`+`/`-`, `:Filetree cwd …`).
---   tree_leads  Direction reversed: the tree root is authoritative and the
---             cwd follows it, rather than the cwd driving the tree.
---
--- Full per-mode config surface: docs/FEATURES/CORE.md.
---
--- The mode is shown as a badge in the bottom-left of the tree window
--- ("PROJECT", "LOCK", "MANUAL", …; nothing in follow mode) — see `indicator`.
---
--- Because the pinned root is real state, other features can read it instead
--- of guessing from the cwd: `M.root()` is the authoritative answer to "which
--- project are we in right now".

local notify = require("filetree.util.notify").create("[filetree.cwd_mode]")
local path_util = require("filetree.util.path")
local au = require("filetree.util.autocmd")

local chdir = require("lib.nvim.fs.chdir")
local find_root = require("lib.nvim.fs.find_root")
local normkey = require("lib.nvim.fs.normkey")
local root_policy = require("lib.nvim.fs.root_policy")
local path_shorten = require("lib.nvim.fs.path_shorten")
local ui_statusline = require("lib.nvim.ui.statusline")
local store_project = require("lib.nvim.store.project")

local M = {}

---Every valid mode name. Also the source for `:Filetree cwd mode`'s enum and
---for validating a persisted value, so a mode can only be added in one place.
---@type table<FiletreeCwdModeName, true>
local MODES = {
  follow = true,
  project = true,
  nearest = true,
  lock = true,
  manual = true,
  tree_leads = true,
}

-- Shared with `filetree.config.DEFAULTS`, which merges the same table into the
-- user-facing config -- see that module for why it is not inlined here.
---@type FiletreeCwdModeConfig
local DEFAULTS = require("filetree.features.nav.cwd_mode.DEFAULTS")
local bind = require("filetree.util.bind")

---@type FiletreeCwdModeConfig
local _cfg = vim.deepcopy(DEFAULTS)

local MODE_NAMES = { "follow", "project", "nearest", "lock", "manual", "tree_leads" }

---A record with one spec per cwd mode (`labels`, `icons`, `hl`, ...).
---@param spec FiletreeOptSpec
---@return FiletreeOptSpec
local function per_mode(spec)
  local fields = {}
  for _, mode in ipairs(MODE_NAMES) do
    fields[mode] = spec
  end
  return { "table", fields = fields }
end

---Option schema (see `filetree.config.schema`): exactly what
---`features.cwd_mode` accepts. Keep it in step with `DEFAULTS.lua`;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  mode = { "string", enum = MODE_NAMES },
  scope = { "string", enum = { "global", "tab", "win" } },
  project = {
    "table",
    fields = {
      markers = { "table", of = "string" },
      skip_dirs = { "table", of = "string" },
      max_depth = { "number", min = 1 },
      sticky = "boolean",
    },
  },
  nearest = { "table", fields = { markers = { "table", of = "string" } } },
  lock = { "table", fields = { enforce = "boolean", follow_manual_root = "boolean" } },
  reveal_outside = { "string", enum = { "skip", "reveal" } },
  persist = "boolean",
  indicator = {
    "table",
    fields = {
      enabled = "boolean",
      mode = { "string", enum = { "auto", "statusline", "float" } },
      align = { "string", enum = { "left", "center", "right" } },
      show_path = { "string", enum = { "never", "lock", "always" } },
      style = { "string", enum = { "text", "short", "numeric", "icon" } },
      labels = per_mode("string"),
      labels_short = per_mode("string"),
      labels_numeric = per_mode("string"),
      icons = per_mode("string"),
      hl = per_mode("string"),
    },
  },
  cycle = { "table", of = { "string", enum = MODE_NAMES } },
  keymap_cycle = "keymap",
  keymap_lock_here = "keymap",
}

---@type FiletreeAdapter?
local _adapter = nil

---The state machine itself (modes, the pin, the lock's guard, `decide`) is `lib.nvim.fs.root_policy`; this file is
---what stays filetree's: the roots-provider and finder chain, persistence, the badge and the commands. Built in
---`new_policy()` so a config change (sticky, enforce, reveal_outside) gets a fresh one.
---@type Lib.Fs.RootPolicy.Handle
local P

---@type Lib.Fs.FindRoot?  VCS-marker walk, used by `project`
local _finder = nil

---@type Lib.Fs.FindRoot?  package-marker walk, used by `nearest`
local _finder_nearest = nil

---@type Lib.UI.Statusline.Segment?
local _badge = nil
---@type integer?  window the badge is currently attached to
local _badge_win = nil

---@type integer?
local _augroup = nil

---Directory the persisted state is keyed by: where Neovim was started, taken
---once at setup() before any mode can move the cwd. Keying by the *current*
---cwd instead would make the key change with the very state being saved — lock
---onto another project and the entry lands under that project, so the session
---you were actually in never finds it again.
---@type string?
local _persist_path = nil

local STORE_KEY = "filetree/cwd_mode"

-- ── Helpers ───────────────────────────────────────────────────────────────────

---Canonical form for comparisons and storage. Everything kept in `P.pinned()`
---goes through here, so a Windows path that arrives as `E:\repos` compares
---equal to the `E:/repos` the same directory produces elsewhere.
---@param dir string?
---@return string?
---@internal
local function canon(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  local out = normkey(dir)
  return out ~= "" and out or nil
end

---Directory of a file path (or the path itself when it is a directory).
---@param p string
---@return string
---@internal
local function dir_of(p)
  if vim.fn.isdirectory(p) == 1 then return p end
  return path_util.parent(p)
end

---Root for `file` per the marker set the given mode walks with.
---
---`project` and `nearest` differ only in that marker set — VCS boundaries
---versus package boundaries — which is exactly why they are two modes rather
---than one option: in a monorepo you want to switch between "the repository"
---and "the package I am editing" at runtime, not at config time.
---
---A root provider (`filetree.roots`) answers first, in every mode: a plugin
---that knows a folder is its own root (a case folder inside a repository)
---says so, and `project` then holds that folder instead of the repository
---around it.
---@param file string
---@param mode FiletreeCwdModeName
---@return string?
---@internal
local function root_of(file, mode)
  local roots = require("filetree.roots")
  if roots.any() then
    local provided = canon(roots.resolve(file))
    if provided then return provided end
  end
  local finder = (mode == "nearest") and _finder_nearest or _finder
  if not finder then return nil end
  local ok, root = pcall(finder.find, file)
  if not ok then return nil end
  return canon(root)
end

-- ── Decision ──────────────────────────────────────────────────────────────────

---What should happen for `file`, per the active mode.
---
---Returns nil in `follow` mode — that is the "no policy" answer, and it lets
---cwd_sync keep its own resolution chain instead of this module quietly
---replacing it.
---@see filetree.features.nav.cwd_sync
---@param file string  Absolute path of the buffer being entered.
---@return FiletreeCwdDecision?
function M.decide(file)
  if not _cfg.enabled then return nil end
  return P.decide(file)
end

-- ── Enforcement ───────────────────────────────────────────────────────────────

---A fresh policy for the current config. `find_root` is the provider/finder chain above; `seed` is where
---`tree_leads` takes its root from (the tree, not the buffer); `on_change` is the badge.
---@return Lib.Fs.RootPolicy.Handle
---@internal
local function new_policy()
  return root_policy.new({
    scope = _cfg.scope,
    sticky = _cfg.project.sticky,
    enforce = _cfg.lock.enforce,
    reveal_outside = _cfg.reveal_outside,
    find_root = function(file, kind)
      return root_of(file, kind)
    end,
    seed = function(mode)
      if mode == "tree_leads" then
        return _adapter and _adapter.get_root_path and _adapter.get_root_path() or nil
      end
      return nil
    end,
    on_error = function(e)
      notify.warn("lock could not be restored: " .. e)
    end,
    on_change = function()
      M.refresh_indicator()
    end,
  })
end

P = new_policy()

---Run `fn` without the lock guard fighting it (used by deliberate moves).
---@internal
---@param fn fun()
local function unguarded(fn)
  P.bypass(fn)
end

-- ── Persistence ───────────────────────────────────────────────────────────────

---The project store, or nil when persistence is off.
---@return Lib.Store.Project?
---@internal
local function store()
  if not _cfg.persist or not _persist_path then return nil end
  return store_project
end

---Write the current policy for this project.
---
---Called only from explicit user actions, never from `decide()`. `project`
---mode re-pins itself on every buffer switch, and persisting each of those
---would mean a disk write per BufEnter for a value that is re-derived at
---startup anyway.
---@internal
local function persist_save()
  local s = store()
  if not s then return end
  pcall(s.save, STORE_KEY, {
    version = 1,
    mode = P.mode(),
    scope = _cfg.scope,
    -- Only a lock's pin is worth keeping: project mode derives its root from
    -- the buffer, follow and manual hold nothing that outlives the session.
    pinned = (P.mode() == "lock") and P.pinned() or nil,
  }, { path = _persist_path })
end

---Apply the policy saved for this project, if any.
---@return boolean restored
---@internal
local function persist_restore()
  local s = store()
  if not s then return false end

  local ok, data = pcall(s.load, STORE_KEY, { path = _persist_path })
  if not ok or type(data) ~= "table" or data.version ~= 1 then return false end

  if data.scope then M.set_scope(data.scope) end

  -- A mode name written by an older (or newer) version may no longer exist.
  local mode = data.mode
  if not MODES[mode] or mode == "follow" then return false end

  -- A stored lock whose directory has since been deleted or moved must not
  -- take the session hostage: fall through to the configured mode instead.
  if mode == "lock" then
    if not data.pinned or vim.fn.isdirectory(data.pinned) == 0 then return false end
    return M.set_mode("lock", data.pinned)
  end

  return M.set_mode(mode)
end

---Drop the policy saved for this project. The live mode is left alone.
---@return boolean ok
function M.forget()
  local s = store()
  if not s then
    notify.info("persistence is off (features.cwd_mode.persist)")
    return false
  end
  local ok = pcall(s.clear, STORE_KEY, { path = _persist_path })
  if ok then notify.info("forgot the saved cwd policy for this project") end
  return ok
end

-- ── Public API ────────────────────────────────────────────────────────────────

---The directory the active mode considers authoritative — the pinned lock, the
---current project, or the cwd when no mode holds one. Other features should
---prefer this over `getcwd()` so a locked session greps the locked project.
---@return string
function M.root()
  -- Every mode that holds a root answers with it; `follow` holds none and
  -- `manual` deliberately does not claim authority over anything.
  local mode, pinned = P.mode(), P.pinned()
  if
    pinned and (mode == "lock" or mode == "project" or mode == "nearest" or mode == "tree_leads")
  then
    return pinned
  end
  return canon(vim.fn.getcwd()) or vim.fn.getcwd()
end

---@return FiletreeCwdModeName
function M.mode()
  return P.mode()
end

---The pinned directory, or nil when the mode holds none.
---@return string?
function M.pinned()
  return P.pinned()
end

---Walk up from `path` to its root, using this feature's marker set.
---
---This is the plugin's one marker-based root walk. `util.root` and cwd_sync
---both call it rather than keeping their own: three walkers with three marker
---sets meant the cwd could land on the git root while a search scoped itself
---to the nearest package.json, with nothing to say which was right.
---
---Returns nil when the feature never ran (disabled, or torn down), which is
---the signal for callers to fall back to their own chain.
---@param path string     File or directory to resolve for.
---@param mode FiletreeCwdModeName?  Marker set to use; defaults to the active mode's.
---@return string?
function M.resolve(path, mode)
  if not _cfg.enabled or type(path) ~= "string" or path == "" then return nil end
  return root_of(path, mode or P.mode())
end

---The directory scope every change goes through: "global", "tab" or "win".
---
---Read by cwd_sync too, so its per-buffer chdir lands in the same scope as the
---mode's own — a `tab`-scoped policy whose buffer switches still changed the
---global cwd would only be half a policy.
---@return Lib.Fs.Chdir.Scope
function M.scope()
  return _cfg.scope or "global"
end

---Change the directory scope, re-anchoring a held root in the new one.
---
---NOTE: leaving "tab"/"win" cannot undo a `:tcd`/`:lcd` that was set in some
---*other* tab or window — Vim has no "clear everywhere" for those. The root is
---re-applied in the new scope; stale local directories elsewhere stay until
---something else changes them.
---@param scope Lib.Fs.Chdir.Scope
---@return boolean ok
function M.set_scope(scope)
  if scope ~= "global" and scope ~= "tab" and scope ~= "win" then
    notify.error("unknown cwd scope: " .. tostring(scope))
    return false
  end
  if scope == _cfg.scope then return true end

  _cfg.scope = scope

  -- The policy re-anchors a held root in the new scope (a lock's guard is dropped and held again).
  local ok, err = P.set_scope(scope)
  if not ok then notify.warn(err or "could not move the root to the new scope") end

  persist_save()
  M.refresh_indicator()
  return true
end

---`project`/`nearest` mode's whole promise — following the focused file as
---it moves between projects/packages — runs through cwd_sync's BufEnter hook
---calling `decide()`. cwd_sync defaults to disabled (see
---|filetree-default-disabled|), and without it enabled, switching into either
---mode only seeds the initial pin from the current buffer and then does
---nothing on the next switch — which looks identical to a plain lock with no
---enforcement until you notice files elsewhere no longer move the root.
---`lock` and `tree_leads` do not have this dependency: dir_guard and
---tree_traverse's manual re-root drive those directly, so this only warns for
---the two modes that actually need cwd_sync to do anything beyond the seed.
---@internal
---@param mode FiletreeCwdModeName
local function warn_if_cwd_sync_missing(mode)
  if mode ~= "project" and mode ~= "nearest" then return end

  -- `registry.require("cwd_sync")` (features.load/require) only tests that
  -- the module file can be `require`d — true the moment anything, anywhere,
  -- has loaded it, regardless of whether filetree.setup() actually turned it
  -- on. Whether it is genuinely *active* lives in filetree.init's own
  -- `_active_features`, reachable only via `require("filetree").feature(…)`.
  local ok, filetree = pcall(require, "filetree")
  if ok and filetree.feature("cwd_sync") then return end

  notify.warn(
    (
      "%s mode needs features.cwd_sync = { enabled = true } to follow "
      .. "buffer switches — without it the root is set once now and will not "
      .. "move again"
    ):format(mode)
  )
end

---Switch modes.
---@param mode FiletreeCwdModeName
---@param dir string?  Directory to pin (lock mode; defaults to the current cwd).
---@return boolean ok
function M.set_mode(mode, dir)
  if not MODES[mode] then
    notify.error("unknown cwd mode: " .. tostring(mode))
    return false
  end

  -- A lock pins `dir`, else wherever the active mode currently holds the root.
  local ok, err = P.set_mode(mode, mode == "lock" and (dir or M.root()) or nil)
  if not ok then
    notify.error(err or ("could not switch to cwd mode " .. mode))
    return false
  end
  if err then notify.warn(err) end

  warn_if_cwd_sync_missing(mode)
  persist_save()
  M.refresh_indicator()
  return true
end

---Pin the cwd to `dir` (default: the current cwd) and switch to lock mode.
---@param dir string?
---@return boolean ok
function M.lock(dir)
  return M.set_mode("lock", dir)
end

---Lock onto the directory of the node under the cursor in the tree.
---@return boolean ok
function M.lock_here()
  if not _adapter then
    notify.warn("no adapter available")
    return false
  end
  local node = _adapter.get_current_node()
  local target = node and node.path or (_adapter.get_root_path and _adapter.get_root_path())
  if not target then
    notify.warn("no node under the cursor")
    return false
  end
  return M.lock(dir_of(target))
end

---Leave lock mode, returning to whatever mode preceded it.
---@return boolean ok
function M.unlock()
  if P.mode() ~= "lock" then
    notify.info("not locked")
    return false
  end
  local ok, err = P.unlock()
  if not ok then
    notify.error(err or "could not unlock")
    return false
  end
  if err then notify.warn(err) end
  warn_if_cwd_sync_missing(P.mode())
  persist_save()
  M.refresh_indicator()
  return true
end

---Advance to the next mode in `cycle`.
---@return boolean ok
function M.cycle()
  local list = _cfg.cycle
  if type(list) ~= "table" or #list == 0 then return false end
  local index = 1
  for i, name in ipairs(list) do
    if name == P.mode() then
      index = i % #list + 1
      break
    end
  end
  local ok = M.set_mode(list[index])
  if ok then notify.info("cwd mode: " .. P.mode()) end
  return ok
end

---Report the current policy.
function M.status()
  local mode = P.mode()
  local label = _cfg.indicator.labels[mode]
  local lines = {
    ("mode:   %s%s"):format(mode, (label and label ~= "") and (" (" .. label .. ")") or ""),
    ("scope:  %s"):format(M.scope()),
    ("root:   %s"):format(M.root()),
    ("cwd:    %s"):format(vim.fn.getcwd()),
  }
  if mode == "lock" then
    lines[#lines + 1] = ("enforce: %s"):format(P.enforced() and "on" or "off")
    lines[#lines + 1] = ("outside: %s"):format(_cfg.reveal_outside)
  end
  notify.info(table.concat(lines, "\n"))
end

---Called by tree_traverse when the user re-roots the tree by hand.
---
---Without this a lock would fight its own user: pressing `+` on a directory
---re-roots the tree, the lock reverts the cwd, and the tree and cwd disagree.
---A deliberate re-root moves the pin instead.
---@param dir string
function M.notify_manual_root(dir)
  if not _cfg.enabled then return end
  local target = canon(dir_of(dir))
  if not target then return end

  local mode = P.mode()
  if mode == "lock" then
    if not _cfg.lock.follow_manual_root then return end
    local ok, err = P.repin(target)
    if not ok then notify.warn(err or ("could not move the lock to " .. target)) end
    persist_save()
    M.refresh_indicator()
  elseif mode ~= "follow" then
    -- project / nearest / manual / tree_leads: a deliberate re-root becomes the
    -- new root. For tree_leads this is not a concession but the whole contract
    -- — the tree leads, the cwd follows.
    P.repin(target)
    unguarded(function()
      local ok, err = chdir(target, { scope = _cfg.scope })
      if not ok then notify.warn(err or ("could not change cwd to " .. target)) end
    end)
    M.refresh_indicator()
  end
end

-- ── Indicator ─────────────────────────────────────────────────────────────────

---Which `indicator.*` table a given style reads labels from.
---@type table<string, string>
local LABEL_SET_BY_STYLE = {
  text = "labels",
  short = "labels_short",
  numeric = "labels_numeric",
  icon = "icons",
}

---The tree window's width, or a fixed fallback when the badge is not
---attached anywhere. Reading it is a single field access on the window
---struct (cheap), but it is also the one input to `badge_text()` that can
---change without any mode/root/scope/pin mutation ever running -- the tree
---window simply gets resized -- so every cache check below re-reads it live
---instead of trusting whatever was true last time.
---@return integer
---@internal
local function badge_width()
  if _badge_win and vim.api.nvim_win_is_valid(_badge_win) then
    return vim.api.nvim_win_get_width(_badge_win)
  end
  return 30
end

---@type string?
local _cache_text = nil
---@type string?
local _cache_hl = nil
---@type FiletreeCwdModeName?
local _cache_mode = nil
---@type string?
local _cache_pinned = nil
---@type integer?
local _cache_width = nil
---@type boolean
local _cache_valid = false

---The badge text for the current mode, e.g. `LOCK  …/Notes`.
---
---Memoized against (mode, pinned, tree-window width): those are the only
---inputs that can change the result, since `indicator` config is fixed for
---the life of a `setup()` call. `component()`/`badge()` are pulled by
---external statusline frameworks (lualine, heirline, …) on every redraw --
---potentially many times a second -- so comparing three cheap values up
---front lets an unchanged badge skip the label lookup and, more to the
---point, `path_shorten`'s split/rebuild loop, rather than repeating that work
---for a result that comes out identical.
---
---Deliberately re-derives the key from live state instead of requiring every
---mutation site to call a separate `invalidate()`: a comparison can never
---drift out of sync with the state it compares, where a forgotten
---invalidation call at some future call site could.
---@return string text
---@return string? hl
---@internal
local function badge_text()
  local width = badge_width()
  if
    _cache_valid
    and P.mode() == _cache_mode
    and P.pinned() == _cache_pinned
    and width == _cache_width
  then
    return _cache_text, _cache_hl
  end

  local cfg = _cfg.indicator
  local label_set = cfg[LABEL_SET_BY_STYLE[cfg.style]] or cfg.labels
  local label = (label_set and label_set[P.mode()]) or ""

  local text, hl
  if label == "" then
    text, hl = "", nil
  else
    text = label
    hl = cfg.hl[P.mode()]
    local show = cfg.show_path
    if P.pinned() and (show == "always" or (show == "lock" and P.mode() == "lock")) then
      -- The tree width is the budget: a badge that wraps is worse than one
      -- that elides, and the trailing segments are the informative ones.
      local budget = width - #label - 3
      if budget > 6 then text = label .. "  " .. path_shorten(P.pinned(), budget) end
    end
  end

  _cache_mode, _cache_pinned, _cache_width = P.mode(), P.pinned(), width
  _cache_text, _cache_hl = text, hl
  _cache_valid = true
  return text, hl
end

---@internal
local function detach_badge()
  if _badge then
    pcall(_badge.detach)
    _badge = nil
  end
  _badge_win = nil
end

-- Last text/hl a change was announced for, so a window-lifecycle-only refresh
-- (WinEnter, TabEnter, …) — which calls refresh_indicator() without any mode/
-- pin change — does not re-fire the event below on every such event.
---@type string?
local _last_text = nil
---@type string?
local _last_hl = nil

---Tell the rest of the world the badge would render differently now.
---
---Fires unconditionally, independent of `indicator.enabled`: a host statusline
---consuming `M.badge()`/`M.component()` directly (with the internal badge
---turned off to avoid showing the mode twice) still needs to know when to
---redraw. `redrawstatus` is scheduled rather than called inline because this
---runs from inside command handlers and autocmd callbacks, where a raw
---`:redrawstatus` can be a no-op or error depending on what is mid-flight.
---@internal
local function announce_change()
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "FiletreeCwdModeChanged" })
  vim.schedule(function()
    pcall(function()
      vim.cmd("redrawstatus")
    end)
  end)
end

---Re-attach (if the tree window changed) and redraw the badge; announce the
---change to external consumers when the rendered text/highlight actually
---differs from last time.
function M.refresh_indicator()
  -- Computed unconditionally — an `indicator.enabled = false` setup (badge
  -- rendering left entirely to the host's own statusline) must still notice
  -- when there is something new to show.
  local text, hl = badge_text()
  if text ~= _last_text or hl ~= _last_hl then
    _last_text, _last_hl = text, hl
    announce_change()
  end

  if not _cfg.enabled or not _cfg.indicator.enabled then
    detach_badge()
    return
  end

  local win = _adapter and _adapter.get_winid and _adapter.get_winid() or nil
  if not win or not vim.api.nvim_win_is_valid(win) then
    detach_badge()
    return
  end

  if _badge_win ~= win then
    detach_badge()
    local segment, err = ui_statusline.attach(win, {
      mode = _cfg.indicator.mode,
      align = _cfg.indicator.align,
    })
    if not segment then
      notify.debug(err or "could not attach the cwd-mode badge")
      return
    end
    _badge = segment
    _badge_win = win
  end

  -- Same reasoning as breadcrumbs' float: a matched window does not by itself
  -- mean a segment was attached.
  if not _badge then return end
  if text == "" then
    _badge.clear()
  else
    _badge.set(text, hl)
  end
end

---Badge text only, for a one-line statusline function (e.g. lualine's
---`sections.lualine_x = { function() return cwd_mode.component() end }`).
---Set `indicator.enabled = false` first, or the mode shows up twice — once
---here, once in the tree window.
---@return string
function M.component()
  return (badge_text())
end

---Everything a hand-rolled statusline or heirline-style component needs to
---render the badge itself: text, its highlight group, and the raw mode/root
---for a consumer that wants to style or gate on them directly rather than
---parsing the text. As with `component()`, set `indicator.enabled = false`
---so filetree does not also draw its own copy in the tree window.
---
---A `User FiletreeCwdModeChanged` autocmd fires (plus a scheduled
---`redrawstatus`) whenever the text or highlight this returns would change —
---hook it to refresh a statusline plugin that does not already redraw on
---every Neovim event (`autocmd User FiletreeCwdModeChanged lua
---require("lualine").refresh()`, or heirline's equivalent).
---@return { text: string, hl: string?, mode: FiletreeCwdModeName, root: string? }
function M.badge()
  local text, hl = badge_text()
  return { text = text, hl = hl, mode = P.mode(), root = P.pinned() }
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param config FiletreeCwdModeOpts
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  _adapter = adapter

  -- Two finders, one per marker set. They share skip_dirs and max_depth: those
  -- describe the filesystem (vendor trees, how far to climb), not the question
  -- being asked, and duplicating them would only let them drift.
  _finder = find_root({
    markers = _cfg.project.markers,
    skip_dirs = _cfg.project.skip_dirs,
    max_depth = _cfg.project.max_depth,
    cache_chain = true,
  })
  _finder_nearest = find_root({
    markers = _cfg.nearest.markers,
    skip_dirs = _cfg.project.skip_dirs,
    max_depth = _cfg.project.max_depth,
    cache_chain = true,
  })

  P.release()
  P = new_policy()
  detach_badge()
  _last_text = nil
  _last_hl = nil
  _cache_valid = false
  _cache_mode = nil
  _cache_pinned = nil
  _cache_width = nil
  _cache_text = nil
  _cache_hl = nil

  -- Captured before anything can move the cwd, so the persistence key is the
  -- workspace Neovim was opened in — not wherever a restored lock points.
  _persist_path = vim.fn.getcwd()

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_cwd_mode", true)

  -- The tree window comes and goes; the badge follows it. These are the events
  -- after which a different window (or none) may be the tree.
  au.acmd({ "WinEnter", "BufWinEnter", "WinClosed", "TabEnter" }, {
    group = _augroup,
    desc = "[filetree] Move the cwd-mode badge to wherever the tree window now is",
    callback = function()
      vim.schedule(M.refresh_indicator)
    end,
  })

  bind.bind("cwd_mode", _cfg, {
    {
      name = "cycle",
      field = "keymap_cycle",
      desc = "cycle cwd mode",
      rhs = function()
        M.cycle()
      end,
    },
    {
      name = "lock_here",
      field = "keymap_lock_here",
      desc = "lock cwd here",
      rhs = function()
        M.lock_here()
      end,
    },
  })

  -- Deferred: the adapter's window (and the startup buffer) may not exist yet,
  -- and both matter for seeding a project pin and for drawing the badge.
  --
  -- A saved policy wins over the configured `mode`: it is what the user chose
  -- last, in this project, at runtime — the config value is the starting point
  -- for a project that has no saved policy yet. When the restore declines (no
  -- entry, or a stored lock whose directory is gone) the configured mode
  -- applies as usual.
  vim.schedule(function()
    if persist_restore() then return end
    if _cfg.mode and _cfg.mode ~= "follow" then M.set_mode(_cfg.mode) end
  end)
end

function M.teardown()
  P.release()
  detach_badge()
  _finder = nil
  _finder_nearest = nil
  _adapter = nil
  _persist_path = nil
  P = root_policy.new()
  _cache_valid = false
  _cache_mode = nil
  _cache_pinned = nil
  _cache_width = nil
  _cache_text = nil
  _cache_hl = nil
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
