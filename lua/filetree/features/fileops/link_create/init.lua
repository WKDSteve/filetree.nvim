---@module 'filetree.features.fileops.link_create'
--- Create a symlink or hardlink inside the current tree directory, pointing
--- at a path entered via prompt, or via a two-step mark/paste usercmd pair.
---
--- `:Filetree symlink` (no default keymap — usercmd-first, like path_copy's
--- format picker) asks for a target path, then creates the link named after
--- the target's basename inside the node under the cursor (its own directory
--- if it's a directory, else its parent — same resolution as smart_create).
--- A directory target only ever gets a symlink (neither Windows nor POSIX
--- allows an unprivileged hard link to a directory); a file target is offered
--- a Symlink/Hardlink choice via kit.confirm.
---
--- `:Filetree symlink mark [path]` / `:Filetree symlink paste` are the fast-path
--- pair: mark a source once (the node under the cursor, the focused editor
--- buffer's file, or an explicit path), then paste it as a link into any
--- number of nodes without retyping the source or being asked to choose a
--- link kind each time — that choice is picked automatically instead (see
--- `M.paste`). Marking again replaces the previous source; pasting does not
--- clear it, so the same source can be linked into several places in a row
--- (mirrors copy_move's copy-stays-staged behaviour).
---
--- Env roots (`filetree.util.env_roots`, the top-level `env_roots` option):
---   * a target typed as `$REPOS_DIR/x`, `$NVIM_CONFIG_DIR/x` (no environment
---     variable needed for that one) or any user-defined root is expanded;
---   * a symlink whose link and target live under the SAME root (one of
---     filetree's own `env_roots` roots -- one another plugin registered
---     inside it does not split it) is created with
---     a RELATIVE target (`relative = "auto"`), so it keeps working on another
---     machine where that root sits on another drive/home -- an absolute
---     `E:/repos/x` would not;
---   * a symlink across two roots (link in `$REPOS_DIR`, target in
---     `$NVIM_CONFIG_DIR`) has no portable form -- a symlink cannot carry an
---     environment variable -- so it stays absolute, the message names the env
---     form, and `repair` re-anchors it on the other machine (it looks the
---     recorded path up under THIS machine's roots before searching the disk).

local confirm_choice = require("filetree.util.confirm_choice")
local ui_select = require("filetree.util.select")
local path = require("filetree.util.path")
local platform = require("filetree.util.platform")
local buffer = require("filetree.util.buffer")
local symlink_util = require("filetree.util.symlink")
local progress = require("filetree.util.progress")
local env_roots = require("filetree.util.env_roots")
local mutate = require("lib.nvim.cross.fs.mutate")

local M = {}

---@type FiletreeLinkCreateConfig
local DEFAULTS = {
  enabled = true,
  keymap = nil, -- off by default; set e.g. keymap = "gl" to bind one
  keymap_mark = nil,
  keymap_paste = nil,
  relative = "auto",
  -- On by default: a real measurement (5.8k files/737MB Neovim config,
  -- worst case -- nothing found, full walk) came back in ~0.1s, so the
  -- earlier worry about gopath.nvim's async walker being slow here doesn't
  -- hold up in practice. Still only searched as a SECOND pass, after the
  -- fast default roots come up empty (see `find_repair_candidates`), and
  -- `repair_search_slow_hint_ms` below still warns if a particular machine's
  -- filesystem (network drive, etc.) makes this pass genuinely slow.
  repair_roots = { "$REPOS_DIR" },
  repair_nvim_config_root = true,
  repair_search_progress = "auto",
  -- If the second-pass search (repair_roots/repair_nvim_config_root) takes
  -- longer than this, notify with a hint on how to narrow or disable it,
  -- rather than silently staying slow on every future repair. `false`
  -- disables the hint entirely.
  repair_search_slow_hint_ms = 2000,
}

---@type FiletreeLinkCreateConfig
local _cfg = vim.deepcopy(DEFAULTS)

---Option schema (see `filetree.config.schema`): exactly what
---`features.link_create` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap = "keymap",
  keymap_mark = "keymap",
  keymap_paste = "keymap",
  relative = { "string", enum = { "auto", "always", "never" } },
  repair_roots = { "table", of = "string" },
  repair_nvim_config_root = "boolean",
  repair_search_progress = {
    "string|false",
    enum = { "auto", "notify", "statusline", "fidget", "float", "kit" },
  },
  repair_search_slow_hint_ms = { "number|false", min = 0 },
}
---@type FiletreeAdapter?
local _adapter = nil

---@class FiletreeLinkMarkedSource
---@field path   string   Absolute path.
---@field name   string   Basename, used both to notify and to name the link.
---@field is_dir boolean

---@type FiletreeLinkMarkedSource?
local _marked = nil

local notify = require("filetree.util.notify").create("[filetree.link_create]")
local bind = require("filetree.util.bind")

---@internal
---Get the directory to create the link in (current node's dir or cwd) —
---identical resolution to smart_create's resolve_parent_dir.
---@return string
local function resolve_parent_dir()
  if not _adapter then return path.slashify(vim.fn.getcwd()) end
  local node = _adapter.get_current_node()
  if not node then return path.slashify(vim.fn.getcwd()) end
  if node.type == "directory" then return path.slashify(node.path) end
  return path.parent(node.path)
end

---@internal
---Absolute-ize a raw, possibly relative, possibly trailing-slashed path.
---`to_absolute`'s `fnamemodify(":p")` appends a trailing OS-native separator
---for a path that is currently an existing directory; strip it again, or
---`path.basename()` below returns "" and the link would be misnamed (e.g.
---its own parent directory).
---@param raw string
---@return string
local function to_target(raw)
  -- `$REPOS_DIR/x` / `$NVIM_CONFIG_DIR/x` / user-defined roots first: they
  -- need no real environment variable, which `to_absolute`'s generic `$VAR`
  -- expansion does.
  local target = path.slashify(path.to_absolute(path.slashify(env_roots.expand(raw))))
  if #target > 1 and target:sub(-1) == "/" then target = target:sub(1, -2) end
  return target
end

---@internal
---@param err string|nil
---@return string
local function friendly_error(err)
  if
    platform.is_windows()
    and type(err) == "string"
    and (err:find("EPERM", 1, true) or err:find("privilege", 1, true))
  then
    return tostring(err)
      .. " (creating a symlink on Windows needs Developer Mode, "
      .. "or an elevated Neovim; a hardlink to a file doesn't need either)"
  end
  return tostring(err)
end

---@internal
---The target text a SYMLINK is created with (see the header and the `relative`
---option): relative to the link's directory when `target` and `link_path` sit
---under the same env root -- or always, with `relative = "always"` -- else the
---absolute path. `nil` second value = a relative form was used.
---"The same root" counts filetree's own `env_roots` roots only
---(`own_root_of`): a folder another plugin or the user's registry config
---registered inside `$REPOS_DIR` does not split it in two, so a link and a
---target that both sit under `$REPOS_DIR` stay relative.
---@param target string    Absolute path the link points to.
---@param link_path string Absolute path of the link to create.
---@return string text
---@return boolean relative
local function symlink_text(target, link_path)
  local mode = _cfg.relative or "auto"
  if mode == "never" then return target, false end
  if mode == "auto" then
    local t_root = env_roots.own_root_of(target)
    if not t_root or t_root ~= env_roots.own_root_of(link_path) then return target, false end
  end
  local rel = path.dot_relative(target, path.parent(link_path))
  -- No relative form exists across drive letters: dot_relative hands the
  -- absolute path back.
  if rel:match("^%a:/") or rel:sub(1, 1) == "/" then return target, false end
  rel = rel:gsub("^%./", "")
  -- Windows resolves a RELATIVE symlink target only with backslashes: with `/`
  -- the link is created and `readlink` shows it, but `stat` fails -- an
  -- absolute target does not have this problem, a relative one does.
  if platform.is_windows() then rel = rel:gsub("/", "\\") end
  return rel, true
end

---@internal
---Whether `link_path` (just created) resolves to the same place as `target`.
---@param link_path string
---@param target string
---@return boolean
local function resolves_to(link_path, target)
  local uv = vim.uv or vim.loop
  local real_link, real_target = uv.fs_realpath(link_path), uv.fs_realpath(target)
  if not real_link or not real_target then return false end
  local function norm(p)
    p = path.slashify(p)
    return platform.is_windows() and vim.fn.tolower(p) or p
  end
  return norm(real_link) == norm(real_target)
end

---@internal
---A path for a message: its env form when it sits under a root, else relative
---to the cwd like everywhere else in this plugin.
---@param p string
---@return string
local function display(p)
  local folded, name = env_roots.fold(p)
  if name then return folded end
  return path.relative(p)
end

---@internal
---@param target string    Absolute path the link points to.
---@param link_path string Absolute path of the link to create.
---@param kind "Symlink"|"Hardlink"
---@param is_dir boolean
local function do_create(target, link_path, kind, is_dir)
  local ok, err
  local fell_back = false
  local text, is_relative = target, false
  if kind == "Hardlink" then
    ok, err = mutate.hardlink(target, link_path)
    if not ok and type(err) == "string" and err:match("^EXDEV") then
      -- A hard link cannot cross filesystems or drive letters, on any OS --
      -- unlike a move (see filetree.util.mutate), there is no copy-based
      -- fallback that would still BE a hard link, so a symlink is the only
      -- link that still works here. Same trigger (EXDEV, not transient, so
      -- not retried), different fallback: this can be reached both from
      -- `M.paste`'s own Hardlink pick (files, on Windows) and from `M.create`'s
      -- user-chosen one, on any platform.
      kind = "Symlink"
      fell_back = true
      text, is_relative = symlink_text(target, link_path)
      ok, err = mutate.symlink(text, link_path, is_dir)
    end
  else
    text, is_relative = symlink_text(target, link_path)
    ok, err = mutate.symlink(text, link_path, is_dir)
  end

  if not ok then
    notify.error("Failed to create " .. kind:lower() .. ": " .. friendly_error(err))
    return
  end

  -- A relative target is resolved by the OS against the link's PHYSICAL
  -- directory, but `symlink_text` worked it out from the path as written: when
  -- some ancestor of the link is itself a symlink (`notes/x -> elsewhere`)
  -- the two differ and the link would dangle. Check it really lands on the
  -- target, and store the absolute path instead when it does not.
  if kind == "Symlink" and is_relative and not resolves_to(link_path, target) then
    local ok_del = mutate.delete_file(link_path)
    if not ok_del then
      notify.error(
        "Created a relative symlink that does not resolve, and could not remove it: " .. link_path
      )
      return
    end
    text, is_relative = target, false
    ok, err = mutate.symlink(text, link_path, is_dir)
    if not ok then
      notify.error("Failed to create symlink: " .. friendly_error(err))
      return
    end
  end

  local msg = kind .. " created: " .. path.relative(link_path) .. " -> " .. display(target)
  if kind == "Symlink" and is_relative then
    msg = msg .. " (stored relative: " .. text .. " -- survives a moved root)"
  elseif
    kind == "Symlink"
    and (_cfg.relative or "auto") ~= "never"
    and env_roots.own_root_of(target)
    and env_roots.root_of(target)
  then
    -- Absolute, with the target under a root: the link text itself cannot say
    -- `$ROOT/...`, so say what can be done about it. Under one of filetree's
    -- own roots only -- that is what `symlink_text` decided "relative" by; a
    -- target under a foreign root alone was never offered a relative form.
    msg = msg
      .. " (stored absolute -- a symlink cannot carry $"
      .. env_roots.root_of(target)
      .. " and no relative form fits; on another machine `:Filetree symlink repair` re-anchors it)"
  end
  if fell_back then
    msg = msg .. " (hardlink not possible across drives/filesystems, used a symlink instead)"
  end
  notify.info(msg)
  local changed = require("filetree.util.changed")
  changed.emit("create", nil, link_path)
  changed.refresh(_adapter)
end

---Prompt for a target path and create a link to it inside the current tree
---directory (the node under the cursor, or its parent if it's a file).
function M.create()
  local parent = resolve_parent_dir()

  local shown = path.relative(parent)
  if shown == "" or shown == "." then
    shown = "./"
  else
    shown = shown .. "/"
  end

  require("ui.kit").input({
    title = "Link target (path or $ROOT/path to link to), created in " .. shown .. ": ",
    on_submit = function(input)
      if not input or input == "" then return end

      local target = to_target(input)
      local stat = vim.uv.fs_stat(target)
      if not stat then
        notify.error("Target does not exist: " .. path.relative(target))
        return
      end

      local is_dir = stat.type == "directory"
      local name = path.basename(target)
      local link_path = parent .. "/" .. name

      if vim.uv.fs_stat(link_path) then
        notify.error("Already exists, not overwriting: " .. path.relative(link_path))
        return
      end

      if is_dir then
        -- Hard links can't target a directory on any supported platform —
        -- no meaningful choice to offer, just create the symlink.
        do_create(target, link_path, "Symlink", true)
      else
        confirm_choice('Link "' .. name .. '" as:', { "Symlink", "Hardlink" }, function(choice)
          if not choice then return end
          do_create(target, link_path, choice, false)
        end)
      end
    end,
  })
end

-- ── Mark / paste ──────────────────────────────────────────────────────────────

---@internal
---Resolve what "the current source" means with no explicit path given: the
---node under the cursor when the tree is the focused buffer, else the
---focused editor buffer's file. Returns nil when neither applies (e.g. the
---focused buffer is a terminal or an unnamed scratch buffer).
---@return string?
local function resolve_implicit_source()
  if buffer.is_tree_buffer() and _adapter then
    local node = _adapter.get_current_node()
    if node then return path.slashify(node.path) end
  end

  local ctx = buffer.context()
  return ctx and path.slashify(ctx.file) or nil
end

---Mark a link source: an explicit path, else the node under the cursor (run
---from the tree), else the focused editor buffer's file. Replaces whatever
---was marked before; use `M.paste()` to insert it as a link.
---@param raw_path string?
function M.mark(raw_path)
  local target = (raw_path and raw_path ~= "") and to_target(raw_path) or resolve_implicit_source()

  if not target then
    notify.warn("Nothing to mark: not on a tree node, no file buffer focused, and no path given")
    return
  end

  local stat = vim.uv.fs_stat(target)
  if not stat then
    notify.error("Path does not exist: " .. path.relative(target))
    return
  end

  _marked = { path = target, name = path.basename(target), is_dir = stat.type == "directory" }
  notify.info("Marked link source: " .. path.relative(target))
end

---Paste the marked source as a link into the node under the cursor (its own
---directory if it's a directory, else its parent — same resolution as
---`M.create`). The link kind is picked automatically rather than prompted,
---since this pair is the fast path; `:Filetree symlink` still offers the
---Symlink/Hardlink choice for anyone who wants to override it.
---
---Directories only ever get a symlink (neither OS allows an unprivileged hard
---link to one). Files get a hardlink on Windows — needs no elevation or
---Developer Mode, unlike a Windows symlink — and a symlink elsewhere, the
---POSIX idiom. If the source and destination turn out to be on different
---drives/filesystems, a hardlink can't be created at all (EXDEV, on any OS);
---`do_create` falls back to a symlink automatically in that case.
function M.paste()
  if not _marked then
    notify.warn("No link source marked — use `:Filetree symlink mark` first")
    return
  end
  if not vim.uv.fs_stat(_marked.path) then
    notify.error("Marked source no longer exists: " .. path.relative(_marked.path))
    _marked = nil
    return
  end

  local parent = resolve_parent_dir()
  local link_path = parent .. "/" .. _marked.name

  if vim.uv.fs_stat(link_path) then
    notify.error("Already exists, not overwriting: " .. path.relative(link_path))
    return
  end

  local kind = _marked.is_dir and "Symlink" or (platform.is_windows() and "Hardlink" or "Symlink")
  do_create(_marked.path, link_path, kind, _marked.is_dir)
end

-- ── Check / repair / delete ───────────────────────────────────────────────────

---@internal
---Paths to act on for the marks-aware commands (`checkall`, `repairall`,
---`delete`): every marked node when any are marked, else the node under the
---cursor — same idiom `trash`'s own `gather_paths()` uses (deliberately
---duplicated per-feature in this codebase rather than shared; see its
---comment). `check`/`repair` (singular) do NOT use this — they resolve like
---`M.mark` instead (explicit path, else cursor node/focused buffer), since
---those are meant as a quick single-node lookup that ignores stale marks.
---@return string[]
local function gather_paths()
  local ok_m, marks = require("filetree.features").load("marks")
  if ok_m and marks and marks.count() > 0 then return marks.get_marked() end
  local node = _adapter and _adapter.get_current_node()
  return (node and node.path) and { node.path } or {}
end

---@internal
---One-line status for `path`, or nil when it isn't a symlink at all.
---@param p string
---@return string? line
---@return boolean? broken
local function status_line(p)
  if not symlink_util.is_link(p) then return nil, nil end
  local broken = symlink_util.is_broken(p)
  local tgt = symlink_util.read_target(p) or "?"
  local tag = broken and "[broken]" or "[ok]    "
  return string.format("%s %s -> %s", tag, path.relative(p), tgt), broken
end

---Report whether `raw_path` (or the node under the cursor / focused buffer's
---file, same resolution as `M.mark`) is a symlink, and if so whether it
---still resolves.
---@param raw_path string?
function M.check(raw_path)
  local target = (raw_path and raw_path ~= "") and to_target(raw_path) or resolve_implicit_source()
  if not target then
    notify.warn("Nothing to check: not on a tree node, no file buffer focused, and no path given")
    return
  end

  local line, broken = status_line(target)
  if not line then
    notify.info("Not a symlink: " .. path.relative(target))
    return
  end
  if broken then
    notify.warn(line)
  else
    notify.info(line)
  end
end

---`M.check` over every marked node (or the node under the cursor if nothing
---is marked). Non-symlinks in the set are silently skipped (counted in the
---summary), so it is safe to run over a mixed marks batch.
function M.check_all()
  local paths = gather_paths()
  if #paths == 0 then
    notify.warn("No node selected")
    return
  end

  local lines = {}
  local n_ok, n_broken, n_skip = 0, 0, 0
  for _, p in ipairs(paths) do
    local line, broken = status_line(p)
    if not line then
      n_skip = n_skip + 1
    elseif broken then
      n_broken = n_broken + 1
      lines[#lines + 1] = line
    else
      n_ok = n_ok + 1
      lines[#lines + 1] = line
    end
  end

  if n_ok + n_broken == 0 then
    notify.info(
      string.format("No symlinks among the %d selected node(s)", n_skip > 0 and n_skip or #paths)
    )
    return
  end

  table.sort(lines)
  table.insert(lines, 1, string.rep("─", 50))
  table.insert(lines, 1, string.format("Symlink check (%d node(s))", #paths))
  lines[#lines + 1] = string.rep("─", 50)
  lines[#lines + 1] = string.format("%d ok, %d broken", n_ok, n_broken)
    .. (n_skip > 0 and string.format(", %d not a symlink", n_skip) or "")

  require("ui.kit").viewer({
    lines = lines,
    title = "Symlink Check",
    width = math.min(90, vim.o.columns - 4),
    height = math.min(#lines + 1, vim.o.lines - 6),
  })
end

local KEEP_CHOICE = "Keep broken (do nothing)"
local DELETE_CHOICE = "Delete symlink instead"

---@internal
---Send `link_path` (a symlink) to trash through the trash feature, so a
---repair's "delete instead" choice respects the same confirm/undo/dry-run
---behavior as every other delete in this plugin, rather than a bespoke unlink.
---@param link_path string
local function delete_via_trash(link_path)
  local ok_t, trash = require("filetree.features").load("trash")
  if ok_t and trash then
    -- require_symlink = true: re-verify right before the OS-level delete
    -- that this is still a symlink, not just at the point repair found it.
    trash.delete(link_path, nil, true)
  else
    notify.warn(
      "trash feature not available — leaving the broken symlink in place: " .. link_path
    )
  end
end

---@internal
---Replace `link_path`'s target with `new_target`: remove the stale link
---(`fs_unlink` — never follows it, safe for a file- or directory-typed link
---on every platform `lib.nvim.cross.fs.mutate` supports) and recreate it as a
---symlink. Always a symlink, never a hardlink: repair has no way to know
---what the ORIGINAL link kind was (POSIX doesn't record it), and a symlink is
---the only kind that can point at either a file or a directory.
---
---Re-checks `link_path` is STILL a symlink right before deleting it, and
---`new_target` still EXISTS right before pointing anything at it: the
---caller reaches here only after an async filesystem search and an
---interactive picker (repair_one → find_repair_candidates → offer_repair →
---this), a window easily long enough (the user deliberating, a slow
---search) for something else to have replaced `link_path` with a real file,
---or removed/moved the chosen `new_target`, in the meantime (a git
---checkout, a build script, another Neovim instance). `mutate.delete_file`
---is an unconditional `fs_unlink` with no type check of its own, so skipping
---the first check would silently delete whatever real file now sits at
---`link_path`; skipping the second would delete the old (working) link and
---replace it with a new symlink dangling at a target that no longer exists —
---`mutate.symlink` never checks the target itself, so that "succeeds" and
---reports as much, while the link is left exactly as broken as before.
---@param link_path string
---@param new_target string
local function relink(link_path, new_target)
  if not symlink_util.is_link(link_path) then
    notify.error(
      "Not relinking "
        .. path.relative(link_path)
        .. " — it is no longer a symlink (something else changed it in the meantime)"
    )
    return
  end

  local stat = vim.uv.fs_stat(new_target)
  if not stat then
    notify.error(
      "Not relinking "
        .. path.relative(link_path)
        .. " — repair target no longer exists: "
        .. path.relative(new_target)
    )
    return
  end
  local is_dir = stat.type == "directory"

  local ok_del, err_del = mutate.delete_file(link_path)
  if not ok_del then
    notify.error("Failed to remove old symlink: " .. friendly_error(err_del))
    return
  end
  do_create(new_target, link_path, "Symlink", is_dir)
end

---@internal
---Directories a repair search must never walk into, or return a hit from:
---Neovim's own cache/data/state dirs — among other things, where the undo
---directory lives. A REAL regression: gopath.nvim's default roots include
---`stdpath("data"/"cache")`, so an unrelated file's *undofile* (named by
---mangling ITS real path with `%` in place of separators) can spuriously
---tail-match a broken link's basename and get offered as a "candidate" —
---picking it relinks the symlink to binary undo-file garbage. Filtered at
---both ends below: dropped from the roots handed to the live search (so the
---walk never descends into them at all) and, since gopath.nvim's own
---persisted cache may already have indexed one from an earlier scan, from
---any hit it returns too.
---@return string[]
local function unsafe_roots()
  local out = {}
  for _, sp in ipairs({ "cache", "data", "state" }) do
    local ok, p = pcall(vim.fn.stdpath, sp)
    if ok and type(p) == "string" and p ~= "" then out[#out + 1] = path.slashify(p) end
  end
  return out
end

---@internal
---Windows compares paths case-insensitively, and a drive letter/segment
---commonly disagrees in case between an env-var-derived path (`stdpath()`)
---and one a filesystem walk turns up — a case-sensitive compare would just
---never match there and silently let an unsafe path through. Same fold
---`lib.nvim.fs.roots` uses for the identical "is path A under root B"
---question. `vim.fn.tolower`, not Lua's `string.lower` — the latter only
---folds ASCII (`("BJÖRN"):lower()` == `"bjÖrn"`, the `Ö` untouched), which
---would leave exactly this comparison broken again for a non-ASCII profile
---path (e.g. a Windows username with an accented letter).
---@param s string
---@return string
local function fold_case(s)
  return platform.is_windows() and vim.fn.tolower(s) or s
end

---@internal
---True when `p` is exactly one of `roots`, or nested under one of them.
---@param p string
---@param roots string[]
---@return boolean
local function is_under_any(p, roots)
  local norm = fold_case(path.slashify(p))
  for _, root in ipairs(roots) do
    local folded_root = fold_case(root)
    if norm == folded_root or norm:sub(1, #folded_root + 1) == (folded_root .. "/") then
      return true
    end
  end
  return false
end

---@internal
---Search the filesystem for a replacement target via gopath.nvim's truncated-
---path search (an OPTIONAL soft dependency, same pattern as `util/pdf.lua`'s
---pdfport.nvim bridge — nothing here breaks if gopath.nvim is not installed,
---repair just falls back to a plain delete/keep choice).
---
---Three passes, cheapest first, each only run when the previous one came up
---empty:
---  1. `tailsearch.cache_lookup` — gopath's own persisted cache, instant and
---     in-memory.
---  2. gopath's own fast default roots (buffer dir/cwd/git root/its own
---     stdpath set) — a live walk, but bounded to what a project normally is.
---  3. `features.link_create.repair_roots`/`.repair_nvim_config_root` (ON by
---     default: `repair_roots = {"$REPOS_DIR"}`, `repair_nvim_config_root =
---     true`) — ONLY reached if 1 and 2 both found nothing, since these can
---     point at something genuinely large (a whole repos root, a real Neovim
---     config: measured at 5.8k files/737MB on one real machine). gopath's
---     async walker only reports once the WHOLE root set it was given has
---     been walked, not as soon as a match turns up, so this pass gets its
---     own progress indicator (`repair_search_progress`) — it is the one
---     that can take a real, noticeable while. Never widened to Neovim's own
---     cache/data/state dirs regardless of what these are set to,
---     `unsafe_roots()` always wins — see its own doc comment for why.
---@param tail string  cleaned path tail (see gopath's tailsearch.sanitize)
---@param on_done fun(hits: string[]|nil)  nil = gopath.nvim not installed
local function find_repair_candidates(tail, on_done)
  local ok, tailsearch = pcall(require, "gopath.resolvers.common.tailsearch")
  if not ok or type(tailsearch.cache_lookup) ~= "function" then
    on_done(nil)
    return
  end

  local unsafe = unsafe_roots()
  ---@param hits string[]
  ---@return string[]
  local function safe(hits)
    local out = {}
    for _, h in ipairs(hits) do
      if not is_under_any(h, unsafe) then out[#out + 1] = h end
    end
    return out
  end

  local cached = safe(tailsearch.cache_lookup(tail))
  if #cached > 0 then
    on_done(cached)
    return
  end

  local ok_f, finder = pcall(require, "gopath.truncated.finder")
  if not ok_f then
    on_done({})
    return
  end

  -- `finder.find_async` matches a SINGLE tail as an exact suffix and does
  -- not itself shorten it the way `cache_lookup` does internally — so search
  -- by BASENAME ALONE, not the full sanitized tail: a moved file's PARENT
  -- directory commonly changes along with the move (the exact regression
  -- this is guarding — the recorded target's `gone/` became `ROADMAP/IDEAS/`
  -- at the real location), so any longer suffix would just never match.
  -- Also a real perf concern, not just a correctness one: unlike
  -- `cache_lookup`'s cheap in-memory suffix retries, `find_async` walks the
  -- root directories on disk — trying several suffix lengths here would
  -- re-walk the SAME tree once per length. Every hit still goes through the
  -- picker for the user to judge, same as gopath's own ambiguous-match
  -- chooser (`tailsearch.probe`) does when a search turns up more than one.
  local basename = tailsearch.suffix_candidates(tail, 1)[1] or tail

  -- gopath's own `guess_roots()` unconditionally bakes in
  -- stdpath("config"/"data"/"cache"). data/cache are already excluded via
  -- `unsafe` (the undo-file danger); stdpath("config") is not unsafe, just
  -- potentially large (measured: 5.8k files/737MB on one real machine) --
  -- exclude it from stage 1 too, regardless of `repair_nvim_config_root`,
  -- so "the fast pass" is actually fast. That setting only controls whether
  -- stage 2 (below) searches it — never stage 1.
  local config_root = { path.slashify(vim.fn.stdpath("config")) }
  local fast_roots = {}
  for _, r in ipairs(tailsearch.guess_roots()) do
    if not is_under_any(r, unsafe) and not is_under_any(r, config_root) then
      fast_roots[#fast_roots + 1] = r
    end
  end

  ---@internal
  ---Stage 2: `repair_roots`/`repair_nvim_config_root`, only reached once
  ---stage 1 came up empty (or had nothing safe left to search at all).
  local function try_slow_pass()
    -- `to_target` (not `vim.fn.expand`, SEC-34): `repair_roots` entries are
    -- config values, and `$VAR`-style env references in them need the
    -- shellout-free expansion every other config path in this plugin uses.
    local extra_roots = {}
    for _, r in ipairs(_cfg.repair_roots or {}) do
      extra_roots[#extra_roots + 1] = to_target(r)
    end
    if _cfg.repair_nvim_config_root then
      extra_roots[#extra_roots + 1] = path.slashify(vim.fn.stdpath("config"))
    end
    if #extra_roots == 0 then
      on_done({})
      return
    end

    local slow_roots = {}
    for _, r in ipairs(extra_roots) do
      if not is_under_any(r, unsafe) then slow_roots[#slow_roots + 1] = r end
    end
    if #slow_roots == 0 then
      on_done({})
      return
    end

    local prog = _cfg.repair_search_progress ~= false
      and progress.create({
        title = "[filetree.link_create]",
        style = _cfg.repair_search_progress,
      })
    if prog then
      prog:update({ text = "Searching " .. table.concat(slow_roots, ", ") .. " for a target…" })
    end

    local slow_t0 = vim.uv.hrtime()
    finder.find_async(basename, { roots = slow_roots }, function(hits2)
      local filtered2 = safe(hits2 or {})
      if prog then
        prog:finish(
          #filtered2 > 0 and "Found a replacement target" or "No replacement target found"
        )
      end

      -- The whole point of a second pass over possibly-large roots is that
      -- it usually finishes fast anyway (measured: ~0.1s against a real
      -- 5.8k-file Neovim config) -- but "usually" isn't "always" (a network
      -- drive, an exceptionally large repos root, ...), so a genuinely slow
      -- run gets a one-time, actionable notice instead of just staying slow
      -- silently on every future repair.
      local elapsed_ms = (vim.uv.hrtime() - slow_t0) / 1e6
      if _cfg.repair_search_slow_hint_ms and elapsed_ms > _cfg.repair_search_slow_hint_ms then
        notify.warn(
          string.format(
            "Repair's extra search took %.1fs. To narrow or turn it off, set "
              .. "features.link_create.repair_roots and/or .repair_nvim_config_root "
              .. "in your setup() call (currently searching: %s).",
            elapsed_ms / 1000,
            table.concat(slow_roots, ", ")
          )
        )
      end

      on_done(filtered2)
    end)
  end

  notify.info("Searching filesystem for a replacement target…")

  -- NEVER call finder.find_async with an empty roots list: gopath.nvim's own
  -- find_async silently substitutes ITS OWN default_roots() (cwd + stdpath
  -- config/data/cache) for an empty/nil `opts.roots` -- exactly the roots
  -- `fast_roots` was just filtered to exclude. An empty fast_roots (a real
  -- case: e.g. cwd/bufdir/git-root all equal stdpath("config"), which the
  -- filter above then removes, leaving nothing) would otherwise silently
  -- reintroduce the whole excluded search space, bypassing
  -- repair_nvim_config_root=false and the cache/data/state exclusion alike.
  -- Treat "nothing left to search" as a stage-1 miss instead.
  if #fast_roots == 0 then
    try_slow_pass()
    return
  end

  finder.find_async(basename, { roots = fast_roots }, function(hits)
    local filtered = safe(hits or {})
    if #filtered > 0 then
      on_done(filtered)
      return
    end
    try_slow_pass()
  end)
end

---@internal
---Present the repair outcome for `link_path`: a picker of `candidates` (plus
---"delete instead" / "keep broken") when any were found, else a smaller
---delete-or-keep chooser. `candidates == nil` means gopath.nvim itself is not
---installed (as opposed to it running and finding nothing) — worded
---differently so the user knows to install it rather than that the search
---came up empty.
---@param link_path string
---@param candidates string[]|nil
---@param on_done fun()?
local function offer_repair(link_path, candidates, on_done)
  on_done = on_done or function() end

  if not candidates or #candidates == 0 then
    if not candidates then
      notify.warn(
        "gopath.nvim not installed — no automatic target search available for "
          .. path.relative(link_path)
      )
    else
      notify.warn("No replacement target found for: " .. path.relative(link_path))
    end
    confirm_choice(
      "Repair " .. path.relative(link_path) .. " — no candidate found",
      { DELETE_CHOICE, KEEP_CHOICE },
      function(choice)
        if choice == DELETE_CHOICE then delete_via_trash(link_path) end
        on_done()
      end
    )
    return
  end

  local items = vim.deepcopy(candidates)
  items[#items + 1] = DELETE_CHOICE
  items[#items + 1] = KEEP_CHOICE

  -- format_item only ever receives the item itself, not its index (kit.select
  -- numbers nothing on its own) -- precompute item -> row number instead of
  -- scanning `items` on every call.
  local row_of = {}
  for i, it in ipairs(items) do
    row_of[it] = i
  end

  ui_select(items, {
    prompt = "Repair " .. path.relative(link_path) .. " — pick a new target:",
    -- kit.select defaults to cursor-anchored placement, which reads poorly
    -- for a list of full paths; centered like kit.confirm's own default.
    relative = "editor",
    format_item = function(item)
      local label = (item == DELETE_CHOICE or item == KEEP_CHOICE) and item or path.relative(item)
      return string.format("[%02d] %s", row_of[item], label)
    end,
  }, function(choice)
    if not choice or choice == KEEP_CHOICE then
      on_done()
      return
    end
    if choice == DELETE_CHOICE then
      delete_via_trash(link_path)
      on_done()
      return
    end
    relink(link_path, choice)
    on_done()
  end)
end

---@internal
---@param link_path string
---@param on_done fun()?
local function repair_one(link_path, on_done)
  on_done = on_done or function() end

  if not symlink_util.is_link(link_path) then
    notify.warn("Not a symlink: " .. path.relative(link_path))
    return on_done()
  end
  if not symlink_util.is_broken(link_path) then
    notify.info("Symlink already resolves, nothing to repair: " .. path.relative(link_path))
    return on_done()
  end

  local raw_target = symlink_util.read_target(link_path)
  if not raw_target then
    notify.error("Could not read link target: " .. path.relative(link_path))
    return on_done()
  end

  -- A link recorded on another machine: the same path under THIS machine's
  -- roots (`E:/repos/x` -> `$REPOS_DIR/x` here) is far likelier right than
  -- anything a disk search turns up, and costs a stat -- so it goes first and,
  -- when it exists, spares the search.
  local remapped = env_roots.remap(raw_target)
  if #remapped > 0 then
    offer_repair(link_path, remapped, on_done)
    return
  end

  local ok_ts, tailsearch = pcall(require, "gopath.resolvers.common.tailsearch")
  if not ok_ts or type(tailsearch.sanitize) ~= "function" then
    offer_repair(link_path, nil, on_done)
    return
  end

  local tail = tailsearch.sanitize(raw_target)
  find_repair_candidates(tail, function(hits)
    offer_repair(link_path, hits, on_done)
  end)
end

---Repair the symlink under the cursor (or an explicit path, or the focused
---editor buffer's file — same resolution as `M.mark`): when it is broken,
---search the filesystem for a file with a matching name/tail via gopath.nvim
---(optional; a plain delete-or-keep choice is offered when it is not
---installed, or when the search finds nothing) and offer a picker of
---candidates, plus "delete instead" / "keep broken". A no-op (with a notify)
---for anything that is not currently a broken symlink.
---@param raw_path string?
function M.repair(raw_path)
  local target = (raw_path and raw_path ~= "") and to_target(raw_path) or resolve_implicit_source()
  if not target then
    notify.warn("Nothing to repair: not on a tree node, no file buffer focused, and no path given")
    return
  end
  repair_one(target)
end

---`M.repair` over every broken symlink among the marked nodes (or the node
---under the cursor if nothing is marked) — one at a time, so each picker is
---resolved before the next one opens.
function M.repair_all()
  local paths = gather_paths()
  local broken = {}
  for _, p in ipairs(paths) do
    if symlink_util.is_broken(p) then broken[#broken + 1] = p end
  end

  if #broken == 0 then
    notify.info("No broken symlinks in the current selection")
    return
  end

  local i = 0
  local function step()
    i = i + 1
    if i > #broken then return end
    repair_one(broken[i], step)
  end
  step()
end

---Remove every symlink among the marked nodes (or the node under the cursor
---if nothing is marked), through the trash feature — same confirm/undo/
---dry-run behavior as `d`, just restricted to symlinks. A non-symlink caught
---up in the same marks batch (e.g. a stale mark) is skipped, never deleted,
---and never followed to whatever it points at.
function M.delete()
  local paths = gather_paths()
  local links, skipped = {}, 0
  for _, p in ipairs(paths) do
    if symlink_util.is_link(p) then
      links[#links + 1] = p
    else
      skipped = skipped + 1
    end
  end

  if #links == 0 then
    notify.warn(
      "No symlink among the selected node(s)"
        .. (skipped > 0 and string.format(" (%d non-symlink skipped)", skipped) or "")
    )
    return
  end
  if skipped > 0 then
    notify.info(
      string.format(
        "%d non-symlink node(s) skipped — this command only removes symlinks",
        skipped
      )
    )
  end

  local ok_t, trash = require("filetree.features").load("trash")
  if not ok_t or not trash then
    notify.warn("trash feature not available")
    return
  end
  -- `links` was validated above, but the actual OS-level delete happens
  -- later, behind an async ref/asset scan plus (by default) an interactive
  -- confirm dialog — arbitrarily long if the user is deliberating.
  -- require_symlink = true asks trash to re-verify each path is still a
  -- symlink right before it actually deletes it, so this command's "never a
  -- real file" guarantee holds even if something else replaces one of these
  -- paths in the meantime.
  trash.delete_current({ paths = links, require_symlink = true })
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@param cfg FiletreeLinkCreateConfig
---@param adapter FiletreeAdapter
function M.setup(cfg, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), cfg or {})
  _adapter = adapter

  bind.bind("link_create", _cfg, {
    {
      name = "create",
      field = "keymap",
      rhs = function()
        M.create()
      end,
      desc = "create link",
    },
    {
      name = "mark",
      field = "keymap_mark",
      rhs = function()
        M.mark()
      end,
      desc = "mark link source",
    },
    {
      name = "paste",
      field = "keymap_paste",
      rhs = function()
        M.paste()
      end,
      desc = "paste marked source as link",
    },
  })
end

function M.teardown()
  _adapter = nil
  _marked = nil
end

return M
