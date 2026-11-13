---@module 'filetree'
--- filetree.nvim — adapter-agnostic filetree features for Neovim.
---
--- Entry point. Call require("filetree").setup({}) with your configuration.
--- See :help filetree or README.md for full option reference.

local config_mod = require("filetree.config")
local adapter_mod = require("filetree.adapter")
local commands = require("filetree.commands")
local registry = require("filetree.features")
local tree_attach = require("filetree.util.tree_attach")
local notify = require("filetree.util.notify").create("[filetree]")
local au = require("filetree.util.autocmd")
local map = require("filetree.util.map")

local M = {}

---@type boolean
local _initialized = false

-- ── Feature registry ─────────────────────────────────────────────────────────
-- The name → module-path mapping lives in `filetree.features` (a single source of
-- truth) so features can be organized into category subfolders without any
-- consumer hard-coding those paths.
local FEATURES = registry.FEATURES

-- ── Default-disabled features ─────────────────────────────────────────────────
--
-- filetree.nvim is opt-out: every feature in FEATURES is ON by default. The user
-- disables what they don't want with `{ enabled = false }`. The short list below
-- is the exception — features that stay OFF until explicitly enabled, each for a
-- concrete reason:
--
--   cwd_sync              Changes the global cwd automatically on buffer switch;
--                         aggressive and overlaps auto_reveal / tree_traverse.
--   current_hl            Purely cosmetic; ships hardcoded colours that only fit
--                         some colorschemes — better tuned by the user.
--   safety                A backup API with no keymaps; enabling it has no visible
--                         effect unless other code calls into it.
--   auto_resize           Automatic width management fights the manual
--                         window_size_cycler (kept on by default).
--   handle_guard          Patches a neo-tree internal and closes libuv handles
--                         to fix a Windows watcher-lock; opt-in until the user
--                         wants that behaviour.
--   quickpick             Two global leader keys, and a temporary mode that takes over
--                         (and silences) the tree buffer's keys; the user opts in.
--   size_info             Purely cosmetic — an eol extmark next to every node —
--                         and `dir_async = true` runs `du`/`Get-ChildItem` per
--                         directory node by default; better opted into than
--                         sprung on someone who just wanted a tree.
--
---@type table<string, boolean>
local DEFAULT_DISABLED = {
  cwd_sync = true,
  current_hl = true,
  safety = true,
  auto_resize = true,
  handle_guard = true, -- patches a neo-tree internal + closes uv handles; opt-in.
  size_info = true, -- cosmetic clutter + per-node `du`/`Get-ChildItem` by default; opt-in.
  tree_toggle = true, -- four global Alt keys; a claim on the keyboard the user makes, not the plugin.
  quickpick = true, -- two global leader keys and a mode that takes over the tree's keys; opt-in.
}

---@type table<string, table>  name → loaded feature module
local _active_features = {}

---@type integer?
local _adapter_keymaps_augroup = nil

---@type boolean  A setup() registered sources, decorators or actions: the next one has to replace them.
local _registered_from_setup = false

-- ── Setup ─────────────────────────────────────────────────────────────────────

---Initialize filetree.nvim.
---@param user_config FiletreeOpts?
function M.setup(user_config)
  config_mod.setup(user_config)

  local cfg = config_mod.get()

  -- A wrongly-typed adapter/features slipping past config.setup()'s own
  -- sanitize step (see config/init.lua) is not expected, but validate()
  -- stays a defensive backstop -- and, per ERR-22, an invalid single value
  -- degrades to its default here rather than aborting the whole plugin.
  local ok, err = config_mod.validate()
  if not ok then
    notify.warn("Invalid config (" .. (err or "?") .. ") -- using the default instead")
    if type(cfg.adapter) ~= "string" then cfg.adapter = "auto" end
    if type(cfg.features) ~= "table" then cfg.features = {} end
  end

  -- Report anything config.setup()'s sanitize step had to drop (unknown
  -- option, wrong type) -- surfaced, never silently swallowed.
  for _, issue in ipairs(config_mod.issues()) do
    notify.warn(issue)
  end

  -- Resolve adapter. An explicitly requested but unresolvable adapter name
  -- degrades to "auto" (the documented default) instead of aborting setup;
  -- only the genuine "no supported tree plugin installed at all" case has no
  -- sensible default to fall back to.
  local adapter = adapter_mod.resolve(cfg.adapter)
  if not adapter and cfg.adapter ~= "auto" then
    notify.warn(
      "Adapter '" .. tostring(cfg.adapter) .. '\' could not be resolved -- falling back to "auto"'
    )
    adapter = adapter_mod.resolve("auto")
  end
  if not adapter then
    notify.error("No supported filetree plugin found. Aborting setup.")
    return
  end
  -- Write the actually-resolved adapter back into the config cfg.get() returns
  -- by reference, so anything reading cfg.adapter afterwards (health.lua's
  -- "Configuration loaded (adapter = ...)" line) reports what is really
  -- running, not the unresolvable name that was asked for and silently
  -- fell back from above.
  cfg.adapter = adapter.name
  if adapter.name == "native" then require("filetree.native").setup(cfg.native) end

  -- Apply the global debug switch so notifier.debug(...) becomes visible.
  require("filetree.util.notify").set_debug(cfg.debug == true)

  -- Apply the global progress style (e.g. "statusline") so batch operations
  -- (trash, paste, …) render through it without each feature needing its
  -- own progress_style option.
  require("filetree.util.progress").set_style(cfg.progress_style)

  -- Named roots ($REPOS_DIR, $NVIM_CONFIG_DIR, user-defined) that absolute
  -- paths are written with. Before any feature sets up: every one of them
  -- reads it at call time, but a re-setup() must not leave the old roots in
  -- place.
  require("filetree.util.env_roots").setup(cfg.env_roots)

  -- Sources, decorators and actions listed in setup() (see filetree.registry). Only touched when one
  -- of the three is given or was given before, so a setup() without them never needs the registry.
  if cfg.sources or cfg.decorators or cfg.actions or _registered_from_setup then
    _registered_from_setup = true
    for _, issue in ipairs(require("filetree.registry").apply_setup(cfg)) do
      notify.warn(issue)
    end
  end

  -- Configure the reference engine before any feature sets up: every fileops
  -- feature that mutates paths reads its scan/ask/apply policy from here
  -- rather than carrying its own copy (see filetree/refs/init.lua).
  require("filetree.refs").setup(cfg.refs)

  -- Reset the central tree-buffer keymap dispatcher; features re-register their
  -- on_attach callbacks during their own setup() below, then install() wires the
  -- single FileType autocmd.
  tree_attach.reset()

  -- Tear down previous features (re-setup is idempotent)
  for _, feat in pairs(_active_features) do
    if type(feat.teardown) == "function" then pcall(feat.teardown) end
  end
  _active_features = {}

  -- Set up each enabled feature.
  -- Opt-out model: a feature runs unless the user set `enabled = false`, or it is
  -- in DEFAULT_DISABLED and the user did not explicitly set `enabled = true`.
  local feat_cfg = cfg.features or {}
  for name, info in pairs(FEATURES) do
    local fcfg = feat_cfg[name]
    local enabled
    if type(fcfg) == "table" and fcfg.enabled ~= nil then
      enabled = fcfg.enabled -- explicit user choice always wins
    else
      enabled = not DEFAULT_DISABLED[name] -- default: on, except the opt-in few
    end
    if enabled then
      fcfg = fcfg or {}
      fcfg.enabled = true
      feat_cfg[name] = fcfg -- keep M.config() in sync
      local ok2, feat_mod = pcall(require, info.mod)
      if ok2 and type(feat_mod.setup) == "function" then
        local ok3, setup_err = pcall(feat_mod.setup, fcfg, adapter)
        if ok3 then
          _active_features[name] = feat_mod
        else
          notify.warn("Feature '" .. name .. "' setup failed: " .. tostring(setup_err))
        end
      else
        notify.warn("Feature module '" .. info.mod .. "' not found or has no setup()")
      end
    end
  end

  -- Wire the single FileType autocmd that dispatches to every feature's
  -- on_attach callback registered above.
  tree_attach.install(adapter)

  -- Same shape for the buffer-lifecycle events: one autocmd set fanning out
  -- to every handler the features registered above, in `PRIORITY` order.
  -- Each feature's teardown() un-registers its own, so the loop above has
  -- already emptied the registry of the previous cycle.
  require("filetree.util.bufevents").install()

  commands.setup(cfg.command)

  -- Register which-key group labels (no-op when which-key is absent).
  pcall(function()
    require("filetree.bindings").setup_which_key()
  end)

  -- After registering all FileType autocmds, re-fire them for any tree buffer
  -- that is already open.  Handles two cases:
  --   (a) filetree loads after the tree was opened (e.g. event="VeryLazy" in real config)
  --   (b) filetree.setup() is called a second time while the tree is already visible
  vim.schedule(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        if require("filetree.util.buffer").is_tree_buffer(buf) then
          -- The filetype is still needed as the pattern, so it is read here
          -- rather than being the guard: which filetypes count as "a tree"
          -- is the adapter's answer, not this loop's.
          local ft = vim.api.nvim_get_option_value("filetype", { buf = buf })
          -- Fire FileType with the tree buffer current so the feature autocmd
          -- callbacks see the correct ev.buf.  (pattern and buf are mutually
          -- exclusive in nvim_exec_autocmds, hence nvim_buf_call.)
          vim.api.nvim_buf_call(buf, function()
            vim.api.nvim_exec_autocmds("FileType", { pattern = ft, modeline = false })
          end)
        end
      end
    end
  end)

  -- Apply adapter_keymaps: override / noop the adapter's own native keymaps.
  -- false → <Nop>, string → remap target.
  -- Runs in vim.schedule inside a FileType autocmd to fire AFTER the adapter
  -- has set its own buffer-local keymaps.
  if type(cfg.adapter_keymaps) == "table" then
    if _adapter_keymaps_augroup then au.del_group(_adapter_keymaps_augroup) end
    _adapter_keymaps_augroup = au.group("filetree_adapter_keymaps", true)

    local overrides = cfg.adapter_keymaps or {}
    au.create("FileType", function(ev)
      local buf = ev.buf
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        for key, target in pairs(overrides) do
          if target == false then
            map("n", key, "<Nop>", { buffer = buf }, "Filetree: adapter keymap disabled")
          elseif type(target) == "string" then
            -- remap: forward to the target key
            map("n", key, target, { buffer = buf }, "Filetree: adapter keymap remapped")
          end
        end
      end)
    end, {
      group = _adapter_keymaps_augroup,
      -- the active backend's own filetypes: with a fixed neo-tree/nvim-tree pair the overrides
      -- never reached another backend's tree buffer
      pattern = (type(adapter.filetypes) == "table" and #adapter.filetypes > 0)
          and adapter.filetypes
        or { "neo-tree", "NvimTree" },
    })
  end

  if adapter.name == "neotree" then
    -- Give `/` back its native search inside neo-tree's own help popup (filetree's
    -- `?` cheatsheet replaces it by default; this is for when it is reachable).
    require("filetree.attach").native_search_in_help()
    -- Prevent neo-tree's own "File not in cwd. Change cwd to ...?" prompt from
    -- ever firing, regardless of which code calls neo-tree's command API (see
    -- install_reveal_guard's own doc comment for the full mechanism). Run as
    -- early as setup() itself so it protects any tree-opening keymap the user
    -- may press before neo-tree finishes its own startup.
    if type(adapter.install_reveal_guard) == "function" then adapter.install_reveal_guard() end
  end

  _initialized = true

  -- One-time (persisted across restarts) popup on the first setup() after
  -- installing this plugin: which CLI tools it wants and why
  -- (docs/install.json). `:Lib deps show filetree.nvim` thereafter.
  -- `cfg.deps_popup = false` (set right in the setup() spec,
  -- config/DEFAULTS.lua) disables it for this plugin specifically. pcall'd:
  -- an older lib.nvim without lib.nvim.deps mustn't break setup() over an
  -- informational popup.
  if cfg.deps_popup ~= false then
    local ok_deps, deps = pcall(require, "lib.nvim.deps")
    if ok_deps then deps.show_once("filetree.nvim") end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Return the active adapter, or nil if setup was not called.
---@return FiletreeAdapter?
function M.adapter()
  return adapter_mod.get()
end

---Return the active configuration.
---@return FiletreeConfig
function M.config()
  return config_mod.get()
end

---Return a loaded feature module by name, or nil.
---@param name string
---@return table?
function M.feature(name)
  return _active_features[name]
end

---Return whether `name` is enabled under the current config and the opt-out
---rules: on by default unless the user set `enabled = false`, or it is in the
---default-disabled set and the user did not explicitly set `enabled = true`.
---@param name string
---@return boolean
function M.is_feature_enabled(name)
  local features = config_mod.get().features
  local fcfg = features and features[name]
  if type(fcfg) == "table" and fcfg.enabled ~= nil then return fcfg.enabled == true end
  return not DEFAULT_DISABLED[name]
end

---Register a source for the tree: it supplies the nodes of one view. See docs/api.md.
---@param entry Filetree.Source
---@return fun(): boolean unregister
function M.source(entry)
  return require("filetree.registry").source(entry)
end

---Register a decorator for the tree: badges on nodes, looked up by path or id.
---@param entry Filetree.Decorator
---@return fun(): boolean unregister
function M.decorator(entry)
  return require("filetree.registry").decorator(entry)
end

---Register an action for the tree: something to do with the node under the cursor or the selection.
---@param entry Filetree.Action
---@return fun(): boolean unregister
function M.action(entry)
  return require("filetree.registry").action(entry)
end

---Register a custom adapter.
---Must be called before setup().
---@param adapter FiletreeAdapter
function M.register_adapter(adapter)
  adapter_mod.register(adapter)
end

---Deprecated no-op, kept so a config that calls it before `neo-tree.setup(opts)`
---keeps working. filetree no longer injects its keys into neo-tree's
---`window.mappings`: it binds them itself, and its `?` cheatsheet lists what is
---bound. `opts` comes back untouched.
---@deprecated
---@param opts table  neo-tree opts table.
---@param _config? FiletreeOpts  Unused.
---@return table opts
function M.attach(opts, _config)
  return require("filetree.attach").neotree(opts)
end

---Return true when setup() has completed successfully.
---@return boolean
function M.is_initialized()
  return _initialized
end

return M
