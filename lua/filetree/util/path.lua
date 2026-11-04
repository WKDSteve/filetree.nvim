---@module 'filetree.util.path'
--- Pure path operations: normalize, convert, transform, escape.
---
--- No global state, no project-root lookup — every function derives its result
--- purely from its arguments (relative paths resolve against an explicit base or
--- the cwd). Features that need project-root-relative paths pass the base in.

local platform = require("filetree.util.platform")

-- lib.nvim is a hard dependency (see filetree/commands.lua, required
-- unconditionally from filetree/init.lua), so these are plain requires, not
-- presence probes. They stay separate locals (rather than one `require("lib.nvim")`)
-- because each is its own lib.nvim submodule.
local cross_unify = require("lib.nvim.cross.fs.separators.unify_slashes")
local lib_relpath = require("lib.nvim.fs.relpath")
local lib_expand_path = require("lib.nvim.cross.fs.expand_path")

local M = {}

---Expand env references, resolve to absolute path and strip surrounding quotes.
---
---Deliberately not `vim.fn.expand` (SEC-34): `p` here can be a raw path typed
---by the user or read from a config value, and vim.fn.expand runs a backtick
---span through `&shell` and treats `%`/`#`/`<cfile>`/`<cword>` as command-line
---specials, none of which belong on arbitrary path text.
---`lib.nvim.cross.fs.expand_path` is a pure string expansion (no shellout), so
---this is safe.
---@param p string
---@return string
function M.to_absolute(p)
  p = lib_expand_path(p)
  p = vim.fn.fnamemodify(p, ":p")
  return (p:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
end

---Expand to absolute path and normalize separators to the OS default.
---Kept as an alias of to_absolute for backwards compatibility.
---@param p string
---@return string
function M.normalize(p)
  return M.to_absolute(p)
end

---Convert to a Unix-style absolute path (forward slashes).
---@param p string
---@return string
function M.to_unix(p)
  return (M.to_absolute(p):gsub("\\", "/"))
end

---Replace backslashes with forward slashes, without touching absoluteness or
---the path's meaning otherwise (no fnamemodify, no cwd resolution) — a pure
---string transform. This is filetree's single canonical separator: prompts,
---notifications and any other path shown to the user always display with `/`,
---on every OS, and any raw path typed by the user (who may type either `/` or
---`\`) is sanitized to this form immediately after `vim.ui.input` returns, before
---it is used for anything. Forward slashes work fine for Neovim's own path/buffer
---APIs and for libuv on Windows; only literal OS-shell invocations (e.g.
---explorer.exe, cmd /c) need native backslashes, and those call sites convert
---explicitly at the point of use (see open_in_fm/open_with).
---@param p string
---@return string
function M.slashify(p)
  return cross_unify(p)
end

---Convert to a Windows-style absolute path (backslashes).
---@param p string
---@return string
function M.to_win(p)
  return (M.to_absolute(p):gsub("/", "\\"))
end

---Return the parent directory of a path (forward-slash, see M.slashify).
---@param p string
---@return string
function M.parent(p)
  return M.slashify(vim.fn.fnamemodify(p, ":h"))
end

---Return the filename (tail) of a path.
---@param p string
---@return string
function M.basename(p)
  return vim.fn.fnamemodify(p, ":t")
end

---Resolve a path to a directory: a file yields its parent, a directory yields
---itself. Used to turn a node path into a working directory.
---@param p string
---@return string
function M.ensure_dir(p)
  if p == nil or p == "" then return platform.get_cwd() end
  if vim.fn.isdirectory(p) == 1 then return p end
  local parent = M.parent(p)
  if parent == "" or parent == "." then return platform.get_cwd() end
  return parent
end

---The leading part of `p` that names the cwd, or nil when `p` is not under it.
---
---`getcwd()` reports the physical directory while a node keeps the spelling the tree was rooted
---with, so `/tmp/x` and a cwd of `/private/tmp/x` (macOS), or any project reached through a symlink,
---do not share a prefix although the one is inside the other. A plain prefix check is tried first;
---only a path that fails it pays for the `fs_realpath` walk up its ancestors. Forward slashes.
---@param p string  Absolute path.
---@return string?
function M.cwd_alias(p)
  local cwd = vim.fn.getcwd()
  local slashed_cwd = M.slashify(cwd):gsub("/+$", "")
  local q = M.slashify(p)
  if q == slashed_cwd or q:sub(1, #slashed_cwd + 1) == slashed_cwd .. "/" then
    return slashed_cwd
  end

  local uv = vim.uv or vim.loop
  local real_cwd = uv.fs_realpath(cwd)
  if not real_cwd then return nil end
  local function canon(real)
    real = M.slashify(real)
    return platform.is_windows() and real:lower() or real
  end
  real_cwd = canon(real_cwd)

  local dir = q:gsub("/+$", "")
  while dir ~= "" do
    local real = uv.fs_realpath(dir)
    if real and canon(real) == real_cwd then return dir end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then return nil end
    dir = parent
  end
  return nil
end

---`p` with a symlinked spelling of the cwd replaced by the cwd itself, so that `fnamemodify(":.")`
---can strip it; every other path comes back untouched. See `M.cwd_alias`.
---@param p string  Absolute path.
---@return string
function M.in_cwd(p)
  local alias = M.cwd_alias(p)
  if not alias then return p end
  local cwd = M.slashify(vim.fn.getcwd()):gsub("/+$", "")
  if alias == cwd then return p end
  return cwd .. M.slashify(p):sub(#alias + 1)
end

---Return `p` relative to `base` (default: cwd). Falls back to `:~:.` form when
---`p` is not under `base`. Purely argument-driven — no project-root lookup.
---@param p    string
---@param base string?  Base directory (default: cwd).
---@return string
function M.relative(p, base)
  base = base or platform.get_cwd()
  local abs_p = M.to_unix(p):gsub("/$", "")
  local abs_base = M.to_unix(base):gsub("/$", "")

  -- Descendant check happens locally first (not by inspecting lib.nvim's
  -- return value) so this stays correct regardless of what lib.nvim.fs.relpath
  -- does for the non-descendant case — it only gets called for the exact case
  -- both algorithms are known to agree on.
  if abs_p:sub(1, #abs_base) == abs_base then return lib_relpath(abs_p, abs_base) end

  -- Not under base: fall back to fnamemodify's ":~:.", which additionally
  -- tildifies the home directory — a UX nicety this plugin's display
  -- convention wants that lib.nvim.fs.relpath doesn't do. slashify keeps the
  -- result consistent with the forward-slash convention.
  return M.slashify(vim.fn.fnamemodify(abs_p, ":~:."))
end

---Return `p` relative to `base` in the form a Markdown link target needs:
---`./x/y` for a descendant, `../x/y` for anything else under a shared root.
---
---This is deliberately not `M.relative`. That one answers "how do I *show* this
---path" and falls back to a `~`-tildified `:~:.` form for a non-descendant,
---which is unusable as a link target; this one answers "what do I *write* into
---a file living in `base`", so it climbs out with `..` and marks a descendant
---with an explicit `./` — a bare `docs/X.md` resolves against the reader's cwd
---in some renderers, `./docs/X.md` never does.
---
---Returns the absolute path unchanged when the two share no root at all
---(different Windows drive letters) — there is no relative form then.
---@param p    string
---@param base string  Base *directory* (for a file, pass its parent).
---@return string
function M.dot_relative(p, base)
  local abs_p = M.to_unix(p):gsub("/+$", "")
  local abs_base = M.to_unix(base):gsub("/+$", "")

  local rel = lib_relpath(abs_p, abs_base)

  -- An absolute result is the "no relative form exists" case; leave it be.
  if rel:match("^%a:/") or rel:sub(1, 1) == "/" then return rel end
  if rel == "." or rel == ".." then return rel end
  if rel:match("^%.%.?/") then return rel end
  return "./" .. rel
end

---Escape a path for use as a vim command argument.
---@param p string
---@return string
function M.fnameescape(p)
  return vim.fn.fnameescape(p)
end

---Escape a path as a single shell argument (cross-platform quoting).
---@param p string
---@return string
function M.escape_shell_arg(p)
  if platform.is_windows() then return '"' .. p:gsub('"', '""') .. '"' end
  return "'" .. p:gsub("'", "'\\''") .. "'"
end

---Wrap a path in double quotes only when it contains whitespace.
---@param p string
---@return string
function M.quote_if_needed(p)
  if p:find("%s") then return '"' .. p .. '"' end
  return p
end

return M
