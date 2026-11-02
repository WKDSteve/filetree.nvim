---@module 'filetree.refs.scan'
--- Candidate discovery for the reference engine.
---
--- Two stages, both cheap:
---
---   1. a fixed-string ripgrep pre-filter (`--files-with-matches`) using the
---      provider's `needles`, restricted to the provider's `extensions`, so a
---      project-wide scan only ever reads a handful of files;
---   2. per candidate file, every line is handed to the provider's `extract`,
---      which does the real (path-resolving) verification.
---
--- Line content comes from a *loaded buffer* when the candidate file has one,
--- and from disk otherwise — the same source the apply step will write back
--- to, so the content-verify in `filetree.refs.apply` can never be defeated by
--- unsaved edits sitting between scan and apply.
---
--- Without ripgrep the pre-filter degrades to a capped libuv walk
--- (`scan.max_files`) rather than turning the whole feature off.

local ftpath = require("filetree.util.path")
local ftfs = require("filetree.util.fs")
local notify = require("filetree.util.notify").create("[filetree.refs]")

-- Optional: a project without ripgrep can hold thousands of files, and the
-- fallback walk below reads every extension-matching one. No-op without
-- lib.nvim.
local progress = require("filetree.util.progress")

local M = {}

-- Directories never worth scanning for references. Not routed through
-- util.ignore on purpose: util.ignore is the *display* ignore list, which the
-- user may legitimately want to differ from what a reference scan traverses.
-- Exported (not `@internal`) so `filetree.refs.own_links`'s directory-move
-- walk -- the same "walk a tree for reference-bearing files" concern, just
-- the outgoing direction -- prunes the identical set instead of drifting.
-- Pruned at any depth and on every scan path alike: ripgrep, the walk's git
-- listing (even for a tracked folder of that name) and the plain walk, so
-- the two candidate searches never disagree about such a folder.
---@type table<string, boolean>
M.PRUNE_DIRS = {
  [".git"] = true,
  ["node_modules"] = true,
  [".venv"] = true,
  ["venv"] = true,
  ["dist"] = true,
  ["build"] = true,
  ["target"] = true,
  ["vendor"] = true,
  [".next"] = true,
  [".cache"] = true,
  ["__pycache__"] = true,
}
local PRUNE_DIRS = M.PRUNE_DIRS

-- ── Line access ───────────────────────────────────────────────────────────────

---@internal
---Find a loaded buffer whose name is `file` (separator-normalized compare, so a
---forward-slash buffer name matches an OS-native path on Windows).
---@param file string
---@return integer|nil
function M.buffer_for(file)
  local key = ftpath.slashify(file)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and ftpath.slashify(name) == key then return b end
    end
  end
  return nil
end

---Lines of `file`, preferring a loaded buffer over the on-disk content.
---@param file string
---@return string[]|nil
function M.lines_of(file)
  local bufnr = M.buffer_for(file)
  if bufnr then return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok or type(lines) ~= "table" then return nil end
  return lines
end

-- ── Candidate discovery ───────────────────────────────────────────────────────

---@internal
---@param exts string[]
---@return table<string, boolean>
local function ext_set(exts)
  local set = {}
  for _, e in ipairs(exts) do
    set[e:lower()] = true
  end
  return set
end

-- Needle bytes above which `candidates_rg` feeds its patterns through stdin.
local STDIN_PATTERN_BYTES = 6000

---@internal
---The ripgrep binary to start (see `filetree.util.platform.rg_binary`).
---A field so the specs can swap it.
---@return string
M.rg_binary = require("filetree.util.platform").rg_binary

---@internal
---The monotonic clock (nanoseconds) the shared submodule deadline is measured with.
---A field so the specs can swap it for a deterministic one.
---@return integer
function M.clock()
  return vim.uv.hrtime()
end

-- ripgrep processes still running, keyed by their `vim.SystemObj`.
--
-- Neovim does not stop a `vim.system` child when it exits (on POSIX; on
-- Windows libuv's job object does, but only for its direct children, see
-- `rg_binary`). A search still running at `:qa` (a test that ends while a
-- second plan of the same rename is in flight, an editor closed mid-scan)
-- would outlive the editor. VimLeavePre kills them all.
---@type table<vim.SystemObj, true>
local live_rg = {}
local leave_hook = false

---@internal
---Kill every ripgrep this module started that has not exited yet.
---@return integer killed  how many were still running
function M.kill_live()
  local n = 0
  for obj in pairs(live_rg) do
    live_rg[obj] = nil
    if pcall(obj.kill, obj, "sigkill") then n = n + 1 end
  end
  return n
end

---@internal
---How many ripgrep searches are running right now (for the specs).
---@return integer
function M.live_count()
  local n = 0
  for _ in pairs(live_rg) do
    n = n + 1
  end
  return n
end

local function ensure_leave_hook()
  if leave_hook then return end
  leave_hook = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("filetree.refs.scan.rg", { clear = true }),
    desc = "filetree.refs: stop ripgrep searches still running",
    callback = function()
      M.kill_live()
    end,
  })
end

---@internal
---ripgrep-based candidate search.
---@param root string
---@param needles string[]
---@param exts string[]
---@param cfg FiletreeRefsConfig
---@param cb fun(files: string[]|nil)  nil signals "ripgrep unusable, fall back"
local function candidates_rg(root, needles, exts, cfg, cb)
  if vim.fn.executable("rg") == 0 then return cb(nil) end

  -- argv form (not a shell string) on purpose: rg is exec'd directly, so
  -- there is nothing to quote and no dependency on &shell — the same
  -- reasoning as the scan this replaces in smart_rename.
  local cmd =
    { M.rg_binary(), "--files-with-matches", "--fixed-strings", "--color=never", "--ignore-case" }
  if cfg.scan and cfg.scan.respect_gitignore == false then cmd[#cmd + 1] = "--no-ignore" end
  for _, e in ipairs(exts) do
    cmd[#cmd + 1] = "-g"
    cmd[#cmd + 1] = "*." .. e
  end
  -- `**/dir/**`, not `dir/*`: a glob with a slash is anchored at the search
  -- root, so `dir/*` left a nested `pkg/vendor/` searched while the walk
  -- prunes that folder at any depth.
  for dir in pairs(PRUNE_DIRS) do
    cmd[#cmd + 1] = "-g"
    cmd[#cmd + 1] = "!**/" .. dir .. "/**"
  end
  -- A sweep over a whole folder (`filetree.refs.usage`) hands over one needle
  -- per file; hundreds of `-e` arguments would blow Windows' command-line
  -- limit. Past `STDIN_PATTERN_BYTES` the patterns travel through stdin
  -- (`-f -`) instead -- ordinary renames never get near it.
  local pattern_bytes = 0
  for _, n in ipairs(needles) do
    pattern_bytes = pattern_bytes + #n + 4
  end
  local stdin
  if pattern_bytes > STDIN_PATTERN_BYTES then
    cmd[#cmd + 1] = "-f"
    cmd[#cmd + 1] = "-"
    stdin = table.concat(needles, "\n") .. "\n"
  else
    for _, n in ipairs(needles) do
      cmd[#cmd + 1] = "-e"
      cmd[#cmd + 1] = n
    end
  end
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = root

  local timeout = (cfg.scan and cfg.scan.timeout_ms) or 3000
  ensure_leave_hook()
  -- Set before the spawn: `on_exit` may run before `vim.system` returns.
  local obj
  local exited = false
  local ok_spawn, spawned = pcall(
    vim.system,
    cmd,
    -- `cwd = root`: rg matches `-g` globs against the path relative to its
    -- process cwd, not to the search root. From any other cwd the unanchored
    -- `!**/build/**` also matched a pruned name in an *ancestor* of the root
    -- (a project under `.../build/proj`) and dropped every file.
    { text = true, timeout = timeout, stdin = stdin, cwd = root },
    function(result)
      -- `on_exit` runs in a fast event; table writes are allowed there. The
      -- `timeout` above makes vim.system kill a hung search itself.
      exited = true
      if obj then live_rg[obj] = nil end
      vim.schedule(function()
        -- rg: 0 = matches, 1 = no matches, >1 = error (including a timeout kill)
        -- A dead search (timeout kill on a loaded machine, a crash) is never
        -- "nothing matches": a rename would then land without its reference
        -- rewrites and nobody would notice. The walk takes over instead; when
        -- its cap cuts it short, it warns and the result is flagged incomplete.
        --
        -- rg also exits 2 when it merely hit an error on the way (one
        -- unreadable directory, a locked file) and still printed every hit it
        -- found. Those hits are a usable answer -- the walk could not read
        -- the unreadable files either -- so only a killed run (timeout: code
        -- 124 or a signal) or one without any output counts as dead.
        local stdout = result.stdout or ""
        if result.code > 1 then
          local killed = result.code == 124 or (result.signal ~= nil and result.signal ~= 0)
          if killed or not stdout:find("%S") then
            notify.debug(
              "ripgrep scan failed (code "
                .. tostring(result.code)
                .. "), falling back to the walk: "
                .. vim.trim(result.stderr or "")
            )
            return cb(nil)
          end
          notify.debug(
            "ripgrep reported errors (code "
              .. tostring(result.code)
              .. "), using its hits: "
              .. vim.trim(result.stderr or "")
          )
        end
        local files = {}
        for line in stdout:gmatch("[^\r\n]+") do
          files[#files + 1] = ftpath.to_absolute(line)
        end
        cb(files)
      end)
    end
  )
  if not ok_spawn then return cb(nil) end
  obj = spawned
  if not exited then live_rg[obj] = true end
end

-- Candidates read per event-loop tick during the ripgrep-free walk. Each cycle
-- here costs a `readfile`, so a project without ripgrep touching thousands of
-- files does not lock the editor for the whole scan. A candidate set this
-- size or smaller stays on the single-tick path below with its timing
-- unchanged.
local WALK_CHUNK_SIZE = 20

---@internal
---Whether `file` holds any of `needles` in its content.
---@param file string
---@param needles string[]
---@return boolean
local function file_hits(file, needles)
  local lines = M.lines_of(file)
  if not lines then return false end
  for _, line in ipairs(lines) do
    local lower = line:lower()
    for _, n in ipairs(needles) do
      if lower:find(n:lower(), 1, true) then return true end
    end
  end
  return false
end

---State shared by the candidate searches of one scan (one `refs.prefetch`,
---one `refs unused` sweep). Every (path, provider) job of a rename runs its
---own ripgrep, and on a loaded machine they tend to time out together: without
---this, each one would list the whole tree again and warn again.
---@class FiletreeRefScanSession
---@field listings table<string, string[]>  listing key → every file under the root
---@field warned   boolean                   the walk cap warning was shown already

---A fresh scan session, to hand to every `candidates` / `run_plan` call of one scan.
---@return FiletreeRefScanSession
function M.new_session()
  return { listings = {}, warned = false }
end

---@internal
---Whether any segment of the slash-separated `rel` is a pruned directory.
---@param rel string
---@return boolean
local function pruned(rel)
  for seg in rel:gmatch("[^/]+") do
    if PRUNE_DIRS[seg] then return true end
  end
  return false
end

---@internal
---Nesting limit for submodules inside submodules, against a gitlink loop.
local MAX_SUBMODULE_DEPTH = 8

---@internal
---Every file under `dir` minus the pruned build and dependency folders: what
---the walk looks at when git cannot list `dir`.
---@param dir string
---@return string[]
local function plain_listing(dir)
  return ftfs.collect_recursive(dir, "files", function(name)
    return PRUNE_DIRS[name] == true
  end)
end

local git_listing

---@internal
---The files of the nested repository at `abs` (a checked-out submodule or an
---embedded clone), listed by git within what is left of the time budget. When
---that listing fails or the budget is used up, the plain walk of `abs` stands
---in, so the repository's files are never silently dropped.
---@param abs string
---@param deadline integer  `vim.uv.hrtime()` deadline in nanoseconds
---@param depth integer  nesting level of the nested repository
---@return string[]
local function nested_listing(abs, deadline, depth)
  local remaining = math.floor((deadline - M.clock()) / 1e6)
  return (remaining > 0 and git_listing(abs, remaining, depth, deadline)) or plain_listing(abs)
end

---@internal
---The files under `root` that git does not ignore (tracked plus untracked,
---minus `.gitignore` / `info/exclude` / the global excludes), so the walk
---honours `scan.respect_gitignore` like ripgrep does. nil when git is missing,
---`root` is not inside a work tree, or git fails.
---
---`git ls-files` lists a submodule only as its gitlink (and
---`--recurse-submodules` cannot be combined with `--others`), and an
---untracked embedded repository only as `dir/`, so each checked-out one is
---listed again from inside, with its own ignore rules. ripgrep searches those
---files too. All nested listings share the one `timeout` budget.
---@param root string
---@param timeout integer  milliseconds
---@param depth? integer  nesting level, 0 for the root
---@param deadline? integer  shared `vim.uv.hrtime()` deadline (nanoseconds)
---@return string[]|nil
function git_listing(root, timeout, depth, deadline)
  depth = depth or 0
  deadline = deadline or (M.clock() + timeout * 1e6)
  if vim.fn.isdirectory(root) ~= 1 or vim.fn.executable("git") == 0 then return nil end
  local ok, res = pcall(function()
    return vim
      .system({
        "git",
        "-C",
        root,
        "ls-files",
        "-z",
        "--stage",
        "--cached",
        "--others",
        "--exclude-standard",
      }, { text = true, timeout = timeout })
      :wait()
  end)
  if not ok or not res or res.code ~= 0 then return nil end
  local base = ftpath.slashify(root):gsub("/+$", "")
  local out, seen = {}, {}
  for entry in (res.stdout or ""):gmatch("[^%z]+") do
    -- `--stage` prefixes tracked entries with "<mode> <object> <stage><TAB>";
    -- untracked ones (`--others`) come bare.
    local mode, rel = entry:match("^(%d+) %x+ %d\t(.*)$")
    rel = rel or entry
    if not seen[rel] and not pruned(rel) then
      seen[rel] = true
      local abs = (base .. "/" .. rel):gsub("/+$", "")
      -- A gitlink, or an untracked directory git lists as `dir/` because it
      -- holds a repository of its own. Not checked out (no `.git` inside):
      -- nothing to search, and `git -C` there would answer for the
      -- superproject.
      local nested = mode == "160000" or (mode == nil and rel:sub(-1) == "/")
      if nested then
        if depth < MAX_SUBMODULE_DEPTH and vim.uv.fs_stat(abs .. "/.git") then
          for _, file in ipairs(nested_listing(abs, deadline, depth + 1)) do
            out[#out + 1] = file
          end
        end
      else
        out[#out + 1] = abs
      end
    end
  end
  return out
end

---@internal
---`git_listing` for the specs (the deadline sharing is checked against a fake `M.clock`).
M.git_listing = git_listing

---@internal
---Every file under `root` the walk may look at, listed once per session.
---@param root string
---@param cfg FiletreeRefsConfig
---@param session FiletreeRefScanSession
---@return string[]
local function list_files(root, cfg, session)
  local respect = not (cfg.scan and cfg.scan.respect_gitignore == false)
  local key = (respect and "git:" or "all:") .. root
  local cached = session.listings[key]
  if cached then return cached end
  local all = respect and git_listing(root, (cfg.scan and cfg.scan.timeout_ms) or 3000) or nil
  if not all then all = plain_listing(root) end
  session.listings[key] = all
  return all
end

---@internal
---ripgrep-free fallback: walk the tree, keep files with a matching extension,
---and plain-find the needles in their content. Capped by `scan.max_files`.
---With `scan.respect_gitignore` (the default) and `root` inside a git work
---tree, the listing comes from git, so gitignored files stay out exactly as
---they do for ripgrep.
---
---Over `WALK_CHUNK_SIZE` candidates the reads are spread `WALK_CHUNK_SIZE` per
---event-loop tick with a `[filetree.refs]` progress indicator, mirroring
---`filetree.refs.apply`'s chunked path.
---@param root string
---@param needles string[]
---@param exts string[]
---@param cfg FiletreeRefsConfig
---@param cb fun(files: string[], incomplete?: boolean)  `incomplete`: the cap cut the walk short or it was cancelled
---@param rg_failed boolean  ripgrep exists but its run died (timeout, crash); only changes the cap warning
---@param session FiletreeRefScanSession
local function candidates_walk(root, needles, exts, cfg, cb, rg_failed, session)
  local max_files = (cfg.scan and cfg.scan.max_files) or 5000
  local wanted = ext_set(exts)

  local all = list_files(root, cfg, session)

  ---@type string[]
  local candidates = {}
  for _, file in ipairs(all) do
    local ext = file:match("%.([%w_]+)$")
    if ext and wanted[ext:lower()] then candidates[#candidates + 1] = file end
  end

  local capped = #candidates > max_files
  local total = capped and max_files or #candidates
  -- One warning per scan, however many of its jobs hit the cap.
  if capped and not session.warned then
    session.warned = true
    notify.warn(
      rg_failed
          and string.format(
            "ripgrep reference scan failed or timed out; the fallback walk stopped at %d files, references may be missing (raise refs.scan.timeout_ms or refs.scan.max_files)",
            max_files
          )
        or string.format(
          "reference scan stopped at %d files (install ripgrep for the fast path, or raise refs.scan.max_files)",
          max_files
        )
    )
  end

  local out = {}

  if total <= WALK_CHUNK_SIZE then
    for i = 1, total do
      if file_hits(candidates[i], needles) then out[#out + 1] = candidates[i] end
    end
    return vim.schedule(function()
      cb(out, capped)
    end)
  end

  local h = progress.create({ title = "[filetree.refs]" })
  local i = 0

  local function step()
    if h and h.cancelled then
      -- Candidates found so far are still reported -- a partial reference
      -- scan is more useful than none. Flagged incomplete so a counting
      -- caller (`filetree.refs.usage`) does not mistake it for a full answer.
      return cb(out, true)
    end

    local last = math.min(i + WALK_CHUNK_SIZE, total)
    for j = i + 1, last do
      if file_hits(candidates[j], needles) then out[#out + 1] = candidates[j] end
    end
    i = last

    if h then h:update({ text = "scanning references…", current = i, total = total }) end

    if i < total then
      vim.schedule(step)
      return
    end

    if h then h:finish(string.format("%d candidate(s) found", #out)) end
    cb(out, capped)
  end

  step()
end

---Files that may contain a reference matching `needles`.
---@param root string
---@param needles string[]
---@param exts string[]
---@param cfg FiletreeRefsConfig
---@param cb fun(files: string[], incomplete?: boolean)  `incomplete` only ever comes from the walk fallback (capped or cancelled), which also takes over when ripgrep is missing or its run died
---@param session? FiletreeRefScanSession  shared by the calls of one scan (see `new_session`); a fresh one when omitted
function M.candidates(root, needles, exts, cfg, cb, session)
  if #needles == 0 or #exts == 0 then return cb({}) end
  session = session or M.new_session()

  -- Both backends funnel through here, and they did NOT agree on how to spell
  -- a path. ripgrep is handed a root with forward slashes and prints its hits
  -- as `<root>\rel\path.lua`, so on Windows every candidate came back with
  -- mixed separators; the libuv walk returns clean forward slashes. Same file,
  -- two spellings, decided by whether the user happens to have ripgrep
  -- installed -- and `ref.file` is what `apply` groups by, what the undo stack
  -- keys on, and what the chooser shows.
  --
  -- Nothing was visibly broken (`buffer_for` compares slashified, and one scan
  -- never mixes the two backends), but "the same file has two names depending
  -- on the machine" is the kind of thing that stays harmless only until
  -- something dedups on it. `slashify` is this repo's canonical separator, so
  -- candidates get it once, here, rather than at each of the places that
  -- would otherwise have to remember.
  local function normalized(files, next_cb, incomplete)
    for i = 1, #files do
      files[i] = ftpath.slashify(files[i])
    end
    return next_cb(files, incomplete)
  end

  candidates_rg(root, needles, exts, cfg, function(files)
    if files then return normalized(files, cb) end
    candidates_walk(root, needles, exts, cfg, function(walked, incomplete)
      return normalized(walked, cb, incomplete)
    end, vim.fn.executable("rg") == 1, session)
  end)
end

-- ── Plan execution ────────────────────────────────────────────────────────────

---Run one provider plan for one moved path and deliver the refs it found.
---@param plan FiletreeRefPlan
---@param ctx FiletreeRefCtx
---@param cb fun(refs: FiletreeRef[], incomplete?: boolean)  `incomplete`: the candidate search was cut short, refs may be missing
---@param session? FiletreeRefScanSession  shared by every job of one scan (see `new_session`)
function M.run_plan(plan, ctx, cb, session)
  M.candidates(ctx.root, plan.needles, plan.extensions, ctx.cfg, function(files, incomplete)
    local refs = {}
    for _, file in ipairs(files) do
      local lines = M.lines_of(file)
      if lines then
        for i, text in ipairs(lines) do
          local found = plan.extract(file, i, text)
          for _, r in ipairs(found or {}) do
            refs[#refs + 1] = r
          end
        end
      end
    end
    cb(refs, incomplete)
  end, session)
end

return M
