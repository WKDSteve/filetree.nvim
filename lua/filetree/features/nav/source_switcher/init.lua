---@module 'filetree.features.nav.source_switcher'
---@brief Switch between the sources of the tree: a picker, a cycle, and their names.
---@description
--- neo-tree renders a filesystem, a buffer list, a git status, a symbol
--- outline, a diagnostics list and (with neo-tree-tests-source) a test tree
--- through the same window. Its own keys for moving between them (`<`/`>`)
--- re-open the tree at the *configured* position, which is not where it is
--- when you pressed the key in a float. This feature keeps the position.
---
--- On the own tree (`adapter = "native"`) the same three ways in drive its
--- views (`native.views`, the tabs of its view bar): a view is what a source is
--- there, the window is never touched, so there is no position to keep. The
--- other foreign adapters have one tree and nothing to switch.
---
--- Three ways in:
---
---   * `pick()` -- a floating list (ui.kit when present, `vim.ui.select`
---     otherwise) with each source's icon and name, the current one marked,
---     and a `[!]` on a source that cannot load right now (`document_symbols`
---     without an LSP client, an uninstalled diagnostics/tests source).
---   * `next()` / `prev()` -- cycle in either direction, wrapping, in the
---     tree window; the window keeps focus.
---   * `switch(name)` -- by name, from `:Filetree source <name>`.
---
--- `display_name()` is the pure half: the ` <icon> <Name>` string neo-tree's
--- `source_selector` wants, in one of three icon families (`nerd`, `codicons`,
--- `common` for a font without glyphs) and two name lengths. It needs no
--- `setup()`, so a host can call it while building neo-tree's own opts.
---
--- `icons.family` left unset resolves to "nerd" only when the user declared
--- `vim.g.have_nerd_font = true` (`lib.nvim.ui.nerd_font`'s own convention --
--- Neovim cannot see the terminal's font), "common" otherwise; an explicit
--- family always wins. Passing `family = "nerd"` without that declaration is
--- a deliberate override and renders exactly what it asks for -- tofu boxes
--- included, if the terminal font lacks the glyphs.
---
--- Config:
---   enabled       boolean
---   keymap_next   string?   In the tree (default `"`).
---   keymap_prev   string?   In the tree (default `!`).
---   keymap_pick   string?   Global, normal mode (default nil).
---   sources       string[]? Override the source list (default: neo-tree's).
---   icons         { family?: "nerd"|"codicons"|"common", variant?: "v1"|"v2", length?: "long"|"short" }

local notify = require("filetree.util.notify").create("[filetree.source_switcher]")
local bind = require("filetree.util.bind")
local nerd_font = require("lib.nvim.ui.nerd_font")

local M = {}

---@type FiletreeSourceSwitcherConfig
local DEFAULTS = {
  enabled = true,
  keymap_next = '"',
  keymap_prev = "!",
  keymap_pick = nil,
  sources = nil,
  -- `family` deliberately absent: `icon_opts()` below picks "nerd" only when
  -- `vim.g.have_nerd_font = true` is declared, "common" otherwise -- an
  -- explicit `family = "nerd"|"codicons"|"common"` here always wins over
  -- that default.
  icons = { variant = "v1", length = "long" },
}

---Option schema (see `filetree.config.schema`): exactly what
---`features.source_switcher` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  keymap_next = "keymap",
  keymap_prev = "keymap",
  keymap_pick = "keymap",
  sources = { "table", of = "string" },
  icons = {
    "table",
    fields = {
      family = { "string", enum = { "nerd", "codicons", "common" } },
      variant = { "string", enum = { "v1", "v2" } },
      length = { "string", enum = { "long", "short" } },
    },
  },
}

---@type FiletreeSourceSwitcherConfig
local _cfg = vim.deepcopy(DEFAULTS)
---@type FiletreeAdapter|nil
local _adapter = nil

-- ── Icons and names ───────────────────────────────────────────────────────────

---@class FiletreeSourceIcon
---@field icon string
---@field long string
---@field short string

---Icon and display names per source, per family and variant. `common` is
---for a terminal without a glyph font.
---@type table<string, table<string, table<string, FiletreeSourceIcon>>>
M.ICONS = {
  common = {
    v1 = {
      filesystem = { icon = "[DIR]", long = "File System", short = "DIR" },
      buffers = { icon = "[BUF]", long = "Buffers", short = "BUF" },
      git_status = { icon = "[GIT]", long = "Git Status", short = "GIT" },
      document_symbols = { icon = "[SYM]", long = "Document Symbols", short = "SYM" },
      netman = { icon = "[NET]", long = "Network", short = "NET" },
      tests = { icon = "[TST]", long = "Test Cases", short = "TST" },
      diagnostics = { icon = "[DIAG]", long = "Diagnostics", short = "DIAG" },
    },
    v2 = {
      filesystem = { icon = "[F]", long = "File System", short = "F" },
      buffers = { icon = "[B]", long = "Buffers", short = "B" },
      git_status = { icon = "[G]", long = "Git Status", short = "G" },
      document_symbols = { icon = "[D]", long = "Document Symbols", short = "D" },
      netman = { icon = "[N]", long = "Network", short = "N" },
      tests = { icon = "[T]", long = "Test Cases", short = "T" },
      diagnostics = { icon = "[Dx]", long = "Diagnostics", short = "Dx" },
    },
  },
  nerd = {
    v1 = {
      filesystem = { icon = "", long = "File System", short = "FS" },
      buffers = { icon = "", long = "Buffers", short = "Buf" },
      git_status = { icon = "", long = "Git Status", short = "Git" },
      document_symbols = { icon = "", long = "Document Symbols", short = "Sym" },
      netman = { icon = "", long = "Network", short = "Net" },
      tests = { icon = "⏱", long = "Test Cases", short = "Tst" },
      diagnostics = { icon = "", long = "Diagnostics", short = "Diag" },
    },
    v2 = {
      filesystem = { icon = "", long = "File System", short = "FS" },
      buffers = { icon = "", long = "Buffers", short = "Buf" },
      git_status = { icon = "", long = "Git Status", short = "Git" },
      document_symbols = { icon = "", long = "Document Symbols", short = "Sym" },
      netman = { icon = "", long = "Network", short = "Net" },
      tests = { icon = "⏱", long = "Test Cases", short = "Tst" },
      diagnostics = { icon = "", long = "Diagnostics", short = "Diag" },
    },
  },
  codicons = {
    v1 = {
      filesystem = { icon = "", long = "File System", short = "FS" },
      buffers = { icon = "", long = "Buffers", short = "Buf" },
      git_status = { icon = "", long = "Git Status", short = "Git" },
      document_symbols = { icon = "", long = "Document Symbols", short = "Sym" },
      netman = { icon = "", long = "Network", short = "Net" },
      tests = { icon = "⏱", long = "Test Cases", short = "Tst" },
      diagnostics = { icon = "", long = "Diagnostics", short = "Diag" },
    },
    v2 = {
      filesystem = { icon = "", long = "File System", short = "FS" },
      buffers = { icon = "", long = "Buffers", short = "Buf" },
      git_status = { icon = "", long = "Git Status", short = "Git" },
      document_symbols = { icon = "", long = "Document Symbols", short = "Sym" },
      netman = { icon = "", long = "Network", short = "Net" },
      tests = { icon = "⏱", long = "Test Cases", short = "Tst" },
      diagnostics = { icon = "", long = "Diagnostics", short = "Diag" },
    },
  },
}

---The views of the own tree under the names the icon tables know.
---@type table<string, string>
local NATIVE_NAMES = { files = "filesystem", git = "git_status", symbols = "document_symbols" }

---@internal
---@return boolean
local function on_native()
  return _adapter ~= nil and _adapter.name == "native"
end

---@internal
---The views of the own tree, in the order of its bar.
---@return Filetree.View.Spec[]
local function native_views()
  local native = require("filetree.native")
  local view = native.current()
  return view and view:views() or native.views()
end

---@internal
---Normalise a source name to its icon key: `netman.ui.neo-tree` -> `netman`, the own
---tree's `git` -> `git_status`.
---@param source string
---@return string
local function icon_key(source)
  if source:find("netman", 1, true) then return "netman" end
  return NATIVE_NAMES[source] or source
end

---@internal
---An explicit `family` ("nerd"/"codicons"/"common") always wins. Left unset
---(the default), it resolves to "nerd" only when the user declared
---`vim.g.have_nerd_font = true` -- Neovim cannot see the terminal's font
---(see `lib.nvim.ui.nerd_font`'s own module doc) -- and to "common"
---otherwise, so a tree with no declared Nerd Font gets the ASCII-bracket
---icons instead of glyphs that render as tofu boxes.
---@param opts { family?: string, variant?: string, length?: string }|nil
---@return string family, string variant, string length
local function icon_opts(opts)
  local o = opts or _cfg.icons or {}
  local family = o.family
  if not (family and M.ICONS[family]) then family = nerd_font.available() and "nerd" or "common" end
  local variant = M.ICONS[family][o.variant] and o.variant or "v1"
  local length = (o.length == "short") and "short" or "long"
  return family, variant, length
end

---The icon glyph for a source.
---@param source string
---@param opts { family?: string, variant?: string }|nil  defaults to the feature's `icons`
---@return string
function M.icon(source, opts)
  local family, variant = icon_opts(opts)
  local def = M.ICONS[family][variant][icon_key(source)]
  return def and def.icon or "?"
end

---The ` <icon> <Name>` string for neo-tree's `source_selector`.
---A source the table does not know is shown by its own name.
---@param source string
---@param opts { family?: string, variant?: string, length?: string }|nil
---@return string
function M.display_name(source, opts)
  local family, variant, length = icon_opts(opts)
  local def = M.ICONS[family][variant][icon_key(source)]
  if not def then return " " .. source end
  return " " .. def.icon .. " " .. def[length]
end

---`{ { source = ..., display_name = ... }, ... }` for a list of sources --
---the shape `source_selector.sources` takes.
---@param sources string[]
---@param opts { family?: string, variant?: string, length?: string }|nil
---@return { source: string, display_name: string }[]
function M.display_names(sources, opts)
  local out = {}
  for i, s in ipairs(sources) do
    out[i] = { source = s, display_name = M.display_name(s, opts) }
  end
  return out
end

-- ── Sources ───────────────────────────────────────────────────────────────────

---@internal
---@return table|nil
local function neotree()
  local ok, nt = pcall(require, "neo-tree")
  return ok and nt or nil
end

---The first real failure of the `tests` source module, kept because LuaJIT
---leaves a "loading" sentinel in `package.loaded` behind a throwing `require`:
---only the FIRST probe sees the real error, every later one gets "loop or
---previous error loading module".
---@type string|nil
local tests_failure = nil

---@internal
---Can neo-tree's `tests` source (neo-tree-tests-source.nvim) be used, and if
---not, why? The plugin ships no module of its own name, only the source itself
---(`neo-tree.sources.tests`) and a neotest consumer -- so the source module is
---what gets probed. Requiring it pulls in neo-tree's source manager and nothing
---of neotest, which a host may load only right before the source first
---renders; never probe `neotest` here.
---
---neo-tree comes first: that module requires neo-tree's manager, which makes a
---lazy-loaded neo-tree run its own `config()` in the middle of the probe, and a
---`pcall(require, "neo-tree.sources.tests")` in that config (the host's
---on-demand neotest wrapper does exactly that) would then hit "loop or
---previous error loading module". And only "module not found" means "not
---installed"; a module that exists but throws is reported as that -- its first
---failure line, remembered (see `tests_failure`), since a missing dependency's
---error is the whole search-path dump.
---@return boolean ok
---@return string|nil why
local function tests_source_status()
  if not neotree() then return false, "neo-tree is not loaded" end
  local ok, err = pcall(require, "neo-tree.sources.tests")
  if ok then
    tests_failure = nil
    return true, nil
  end
  local text = tostring(err)
  if text:find("module 'neo-tree.sources.tests' not found", 1, true) then
    return false, "neo-tree-tests-source.nvim is not installed"
  end
  if tests_failure and text:find("loop or previous error loading module", 1, true) then
    return false, tests_failure
  end
  tests_failure = "neo-tree.sources.tests failed to load: " .. text:match("^[^\n]*")
  return false, tests_failure
end

---@internal
---The `sources` list neo-tree was set up with, or nil. neo-tree v3 merges its
---config lazily, on the first command, so `nt.config` is nil until then (and
---the fallback list below would be used for a configured neo-tree);
---`peek_config()` is its cheap way to read a key in the meantime -- the user's
---unmerged config, or the merged one once it exists.
---@return string[]|nil
local function configured_sources()
  local nt = neotree()
  if not nt then return nil end
  local cfg = nt.config
  if type(nt.peek_config) == "function" then
    local ok, peeked = pcall(nt.peek_config)
    if ok and type(peeked) == "table" then cfg = peeked end
  end
  local list = type(cfg) == "table" and cfg.sources or nil
  return type(list) == "table" and #list > 0 and list or nil
end

---The sources to switch between: the config's override, else what neo-tree
---was set up with, else a fallback of the four built-ins plus whatever
---optional source modules are installed.
---@return string[]
function M.sources()
  if on_native() then
    -- the views of the tree are the list: `native.views` decides it, not this feature
    return vim.tbl_map(function(spec)
      return spec.name
    end, native_views())
  end
  if type(_cfg.sources) == "table" and #_cfg.sources > 0 then return vim.deepcopy(_cfg.sources) end
  local configured = configured_sources()
  if configured then return vim.deepcopy(configured) end
  local out = { "filesystem", "buffers", "git_status", "document_symbols" }
  if pcall(require, "neo-tree.sources.diagnostics") then out[#out + 1] = "diagnostics" end
  if tests_source_status() then out[#out + 1] = "tests" end
  if pcall(require, "netman") then out[#out + 1] = "netman.ui.neo-tree" end
  return out
end

---The source shown in the current window, or nil when it is not a tree.
---@return string|nil
function M.current()
  if on_native() then
    local view = require("filetree.native").current()
    return view and view.view_name or nil
  end
  if vim.bo.filetype ~= "neo-tree" then return nil end
  local s = vim.b.neo_tree_source
  return type(s) == "string" and s or nil
end

---Can `source` be shown right now?
---@param source string
---@return boolean ok
---@return string|nil why
function M.loadable(source)
  if on_native() then
    for _, spec in ipairs(native_views()) do
      if spec.name == source then return require("filetree.native.bar").available(spec) end
    end
    return false, "no view of this name"
  end
  if source == "document_symbols" then
    if #vim.lsp.get_clients({ bufnr = 0 }) == 0 then
      return false, "no LSP client attached to the current buffer"
    end
  elseif source == "diagnostics" then
    if not pcall(require, "neo-tree.sources.diagnostics") then
      return false, "neo-tree-diagnostics.nvim is not installed"
    end
  elseif source == "tests" then
    local ok, why = tests_source_status()
    if not ok then return false, why end
  elseif source:find("netman", 1, true) then
    if not pcall(require, "netman") then return false, "netman.nvim is not installed" end
  end
  return true, nil
end

---@internal
---@return table|nil
local function commands()
  local ok, cmd = pcall(require, "neo-tree.command")
  return ok and cmd or nil
end

---Show `source`, keeping the tree where it is. A source that cannot load is
---refused with the reason.
---@param source string
---@param opts { position?: FiletreeTreePosition, keep_focus?: boolean }|nil
---@return boolean ok
---@return string|nil err
function M.switch(source, opts)
  opts = opts or {}
  if not vim.tbl_contains(M.sources(), source) then
    return false, ("unknown source %q (known: %s)"):format(source, table.concat(M.sources(), ", "))
  end
  if on_native() then
    -- a view that cannot load is shown all the same: its one line says why, and it comes alive
    -- when its source can load (a language server attaches)
    local view = require("filetree.native").ensure()
    local shown, why = view:show(source)
    if not shown then return false, why end
    if not view:is_open() then view:open(opts.position, false) end
    return true, nil
  end
  local ok, why = M.loadable(source)
  if not ok then return false, ("cannot show %s: %s"):format(source, why) end
  local cmd = commands()
  if not cmd then return false, "neo-tree is not loaded" end

  local win = vim.api.nvim_get_current_win()
  local position = opts.position
    or (_adapter and type(_adapter.get_position) == "function" and _adapter.get_position())
    or "left"
  local in_tree = vim.bo.filetype == "neo-tree"

  -- From inside the tree, `position = "current"` replaces the tree's own
  -- window and nothing moves; from outside, the tree is (re)opened where it
  -- lives. That distinction is why neo-tree's own `<`/`>` were replaced.
  local ok_exec, err = pcall(cmd.execute, {
    action = "show",
    source = source,
    position = in_tree and "current" or position,
    reveal = false,
  })
  if not ok_exec then return false, tostring(err) end

  if opts.keep_focus ~= false and in_tree then
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    end)
  end
  return true, nil
end

---@internal
---@param step integer  +1 or -1
local function cycle(step)
  if on_native() then
    local view = require("filetree.native").current()
    if not view or not view:cycle(step) then notify.warn("no other view to switch to") end
    return
  end
  local list = M.sources()
  if #list == 0 then
    notify.warn("no sources to switch between")
    return
  end
  local current = M.current() or "filesystem"
  local idx = 1
  for i, s in ipairs(list) do
    if s == current then
      idx = i
      break
    end
  end
  local target = list[((idx - 1 + step) % #list) + 1]
  local ok, err = M.switch(target)
  if not ok then notify.warn(err or "switch failed") end
end

---Show the next source, wrapping.
function M.next()
  cycle(1)
end

---Show the previous source, wrapping.
function M.prev()
  cycle(-1)
end

---Pick a source from a floating list.
function M.pick()
  local list = M.sources()
  if #list == 0 then
    notify.warn("no sources to pick from")
    return
  end
  local current = M.current()
  local items = {}
  for i, name in ipairs(list) do
    local ok = M.loadable(name)
    items[i] = ("%s %s%s%s"):format(
      M.icon(name),
      name,
      name == current and " ←" or "",
      ok and "" or " [!]"
    )
  end
  local prompt = on_native() and "tree view" or "neo-tree source"
  require("filetree.util.select")(items, { prompt = prompt }, function(_, idx)
    local name = idx and list[idx] or nil
    if not name then return end
    if name == current then
      notify.info("already showing " .. name)
      return
    end
    local ok, err = M.switch(name)
    if not ok then notify.warn(err or "switch failed") end
  end)
end

---What the switcher sees: the source list and where it came from, the
---current source and position, the loadability of each source.
---@return table
function M.info()
  local status = {}
  for _, s in ipairs(M.sources()) do
    local ok, why = M.loadable(s)
    status[s] = ok and "ok" or why
  end
  return {
    sources = M.sources(),
    source_list_from = (on_native() and "native.views")
      or (type(_cfg.sources) == "table" and #_cfg.sources > 0) and "config"
      or (configured_sources() and "neo-tree")
      or "fallback",
    current = M.current(),
    position = _adapter and type(_adapter.get_position) == "function" and _adapter.get_position()
      or nil,
    loadable = status,
    icons = _cfg.icons,
  }
end

---Print `info()`.
function M.debug()
  vim.print(M.info())
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

---@param config FiletreeSourceSwitcherConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config or {})
  if not _cfg.enabled then return end
  _adapter = adapter
  if adapter.name ~= "neotree" and adapter.name ~= "native" then
    -- One tree, nothing to switch. Silent: the feature is on by default and
    -- a warning on every start for every user of such a tree is noise.
    return
  end

  bind.bind("source_switcher", _cfg, {
    { name = "next", field = "keymap_next", rhs = M.next, desc = "next tree source" },
    { name = "prev", field = "keymap_prev", rhs = M.prev, desc = "previous tree source" },
  })
  bind.bind("source_switcher/global", _cfg, {
    { name = "pick", field = "keymap_pick", rhs = M.pick, desc = "pick a tree source" },
  }, "global")
end

function M.teardown()
  if _cfg.keymap_pick then pcall(vim.keymap.del, "n", _cfg.keymap_pick) end
  _adapter = nil
end

return M
