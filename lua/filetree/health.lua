---@module 'filetree.health'
--- :checkhealth filetree — validates adapter availability and feature config.

local M = {}

--- `ℹ️ INFO` reads faster than a bare `info()` line in a status list (adapter,
--- backend, engine) where the column itself carries information; a plain
--- fact (version, path, count) stays a bare `vim.health.info()`. Paired with
--- `after/syntax/checkhealth.vim` in lib.nvim (a hard dependency here, so it
--- ships for every consumer, not just this repo's own config), which colors
--- the `INFO` keyword the same as the built-in `OK`/`WARNING`/`ERROR` ones.
---@param msg string
local function note(msg)
  vim.health.info("ℹ️ INFO " .. msg)
end

---Run all :checkhealth filetree checks (lib.nvim, Neovim version, config,
---adapters, active adapter, features, optional dependencies, composer routes).
function M.check()
  vim.health.start("filetree.nvim")

  -- lib.nvim: required for the :Filetree/:Ft command layer
  -- (lib.nvim.bindings.usercmd.composer), which registers unconditionally (no pcall).
  if pcall(require, "lib.nvim.bindings.usercmd.composer") then
    vim.health.ok("lib.nvim detected (:Filetree/:Ft command layer available)")
  else
    vim.health.error(
      "lib.nvim not found — :Filetree/:Ft will fail to register",
      { 'Install "WKDSteve/lib.nvim" as a dependency' }
    )
  end

  -- lib.nvim.ui.dialog: every yes/no and choice dialog asks through it (lib.nvim of 2026-10-28 or newer)
  local dialog_ok, dialog = pcall(require, "lib.nvim.ui.dialog")
  if dialog_ok and type(dialog) == "table" and dialog.yesno then
    vim.health.ok("lib.nvim.ui.dialog (the dialogs of the tree and the trash)")
  else
    vim.health.error("this lib.nvim has no ui.dialog.yesno -- the confirmations will fail", {
      "Update lib.nvim to a version of 2026-10-28 or newer",
    })
  end

  -- ── Neovim version ────────────────────────────────────────────────────────
  local version = vim.version()
  if version.major == 0 and version.minor < 10 then
    vim.health.error(
      "Neovim >= 0.11 is required (found " .. tostring(version) .. ")",
      { "Upgrade Neovim to 0.11+" }
    )
  else
    vim.health.ok("Neovim " .. tostring(version))
  end

  -- ── Configuration ─────────────────────────────────────────────────────────
  local ok_cfg, config_mod = pcall(require, "filetree.config")
  if not ok_cfg then
    vim.health.error("filetree.config could not be loaded: " .. tostring(config_mod))
    return
  end

  local cfg = config_mod.get()
  if vim.tbl_isempty(cfg) then
    vim.health.info("filetree.setup() has not been called yet")
    return
  end
  vim.health.ok("Configuration loaded (adapter = " .. tostring(cfg.adapter) .. ")")

  -- validate() degrades an invalid field to its default rather than
  -- aborting setup() (ERR-22), so a failure here is informational, not an
  -- error -- the plugin is running, just not with the value that was asked
  -- for.
  local valid, err = config_mod.validate()
  if not valid then
    vim.health.warn(
      "Config validation found an issue (using the default instead): " .. (err or "unknown")
    )
  else
    vim.health.ok("Config validated")
  end

  -- Named roots absolute paths are written with (`env_roots`): say which are
  -- live on this machine, so a `$REPOS_DIR` that silently is not set is visible.
  do
    local env_roots = require("filetree.util.env_roots")
    if not env_roots.enabled() then
      vim.health.info("env_roots: off -- absolute paths are written as plain absolute paths")
    else
      local names = {}
      for _, r in ipairs(env_roots.roots()) do
        names[#names + 1] = ("$%s = %s"):format(r.name, r.root)
      end
      if #names == 0 then
        vim.health.info("env_roots: on, but no root has a value on this machine")
      else
        vim.health.ok("env_roots: " .. table.concat(names, "; "))
      end
      -- Names filetree's own `env_roots` asks for that came to nothing (a
      -- `vars = { "MY-DIR" }` would otherwise be silently without effect).
      for _, u in ipairs(env_roots.unresolved()) do
        vim.health.warn(
          ("env_roots.%s: $%s is no root -- %s"):format(
            u.kind == "var" and "vars" or "extra",
            u.name,
            u.reason
          )
        )
      end
      -- The registry's own configuration (the user's `lib.nvim.fs.roots`
      -- setup, roots other plugins registered) is reported in full by
      -- `:checkhealth lib`; point there when something in it is unusable.
      local bad = {}
      for _, st in ipairs(require("lib.nvim.fs.roots").status()) do
        if st.problem then bad[#bad + 1] = ("$%s (%s)"):format(st.name, st.problem) end
      end
      if #bad > 0 then
        vim.health.info(
          "env_roots: shared roots without a usable value: "
            .. table.concat(bad, ", ")
            .. " -- see :checkhealth lib"
        )
      end
    end
  end

  -- Unknown top-level option / feature name from the last setup() call
  -- (ERR-50) -- dropped before the merge, reported here.
  local cfg_issues = type(config_mod.issues) == "function" and config_mod.issues() or {}
  if #cfg_issues == 0 then
    vim.health.ok("No unknown or wrongly-typed setup() options")
  else
    for _, issue in ipairs(cfg_issues) do
      vim.health.warn(issue)
    end
  end

  -- ── Adapters ──────────────────────────────────────────────────────────────
  vim.health.start("filetree.nvim — adapters")

  local adapters = {
    { name = "neotree", plugin = "neo-tree" },
    { name = "nvimtree", plugin = "nvim-tree" },
    { name = "netrw", plugin = "netrw (builtin)" },
    { name = "oil", plugin = "oil.nvim" },
    { name = "mini_files", plugin = "mini.files" },
  }

  local found_any = false
  for _, a in ipairs(adapters) do
    -- netrw is always available as it is built in to Neovim
    local avail = a.name == "netrw" or pcall(require, a.plugin)
    if avail then
      vim.health.ok(a.name .. " (" .. a.plugin .. ") — available")
      found_any = true
    else
      note(a.name .. " (" .. a.plugin .. ") — not installed")
    end
  end

  if not found_any then
    vim.health.error(
      "No supported filetree plugin found",
      { "Install one of: neo-tree.nvim, nvim-tree.lua, oil.nvim, mini.files" }
    )
  end

  -- ── Active adapter ────────────────────────────────────────────────────────
  local ok_reg, adapter_mod = pcall(require, "filetree.adapter")
  if ok_reg then
    local active = adapter_mod.get()
    if active then
      local is_open = active.is_open()
      vim.health.ok("Active adapter: " .. active.name .. (is_open and " (open)" or " (closed)"))
    else
      vim.health.info("No adapter resolved yet (call setup() first)")
    end
  end

  -- ── Features (grouped by category, driven by the registry) ─────────────────
  local feat_cfg = cfg.features or {}
  local registry = require("filetree.features")

  -- Resolve enabled-state under the opt-out model (on by default unless the
  -- user disabled it, or it is in the default-disabled set).
  local ok_ft, ft = pcall(require, "filetree")
  local function is_enabled(key)
    if ok_ft and type(ft.is_feature_enabled) == "function" then
      return ft.is_feature_enabled(key)
    end
    local fc = feat_cfg[key]
    return type(fc) == "table" and fc.enabled == true
  end

  -- Extra check for trash backend availability
  if is_enabled("trash") then
    local ok_tp, tp = pcall(require, "filetree.features.fileops.trash.platform")
    if ok_tp then
      if tp.available() then
        vim.health.ok("Trash backend: " .. tp.backend_name())
      else
        vim.health.warn("No trash backend found — trash feature may not work")
      end
    end
  end

  -- marks: which order every consumer gets the marked paths in. Info only --
  -- both values are valid; an invalid one is already reported (and dropped)
  -- by the config validation above.
  if is_enabled("marks") then
    local order = (feat_cfg.marks or {}).order or "marked"
    vim.health.info(
      ("marks: order = %q (%s)"):format(
        order,
        order == "tree" and "sorted by full path" or "the order the nodes were marked in"
      )
    )
  end

  -- pdf_open: pdfport.nvim is optional; without it PDFs open in the system viewer
  if is_enabled("pdf_open") and not pcall(require, "pdfport") then
    vim.health.info("pdf_open: pdfport.nvim not installed — PDFs open in the system viewer only")
  end

  -- mdview_open: mdview.nvim is optional; without it the key only warns
  if is_enabled("mdview_open") and not pcall(require, "mdview") then
    vim.health.info("mdview_open: mdview.nvim not installed — the key only warns")
  end

  -- pdf_create: pdfport.nvim is a hard soft-dependency here (no fallback —
  -- there is no dependency-free way to turn a file into a PDF), so flag it
  -- more strongly than pdf_open's info-only note.
  if is_enabled("pdf_create") then
    local ok_pp, pp = pcall(require, "pdfport")
    if not (ok_pp and type(pp.create) == "function") then
      vim.health.warn(
        "pdf_create: pdfport.nvim not installed (or has no create() API) — the gP keymap is a no-op",
        { 'Install "WKDSteve/pdfport.nvim"' }
      )
    end
  end

  -- Watcher quarantine: note Windows-only relevance
  if is_enabled("watcher_quarantine") then
    local plat_ok, plat = pcall(require, "filetree.util.platform")
    if plat_ok and not plat.is_windows() and not plat.is_wsl() then
      vim.health.info("watcher_quarantine: no-op on non-Windows platforms")
    end
  end

  -- handle_guard: report install state + flag leaked watchers (a tracked handle
  -- still pointing at a path that no longer exists = neo-tree left it behind).
  if is_enabled("handle_guard") then
    local ok_hg, hg = registry.load("handle_guard")
    if ok_hg and hg then
      if hg.installed() then
        local list = hg.handles()
        local leaked = 0
        for _, h in ipairs(list) do
          if not h.exists then leaked = leaked + 1 end
        end
        if leaked > 0 then
          vim.health.warn(
            (
              "handle_guard: %d of %d tracked watcher(s) point at a "
              .. "gone path (see :Filetree handles)"
            ):format(leaked, #list)
          )
        else
          vim.health.ok(("handle_guard installed (%d watcher(s) tracked)"):format(#list))
        end
      else
        local plat_ok, plat = pcall(require, "filetree.util.platform")
        if plat_ok and not plat.is_windows() and not plat.is_wsl() then
          vim.health.info("handle_guard: no-op on non-Windows platforms")
        else
          vim.health.info(
            "handle_guard enabled but not installed "
              .. "(needs the neo-tree adapter; fs_watch not reachable yet)"
          )
        end
      end
    end
  end

  -- tree_integrity: whether the nui set_nodes guard is actually in place, and
  -- whether it has had to repair anything (a non-zero count means this session
  -- did hit the upstream corruption — and survived it).
  if is_enabled("tree_integrity") then
    local ok_ti, ti = registry.load("tree_integrity")
    if ok_ti and ti then
      local healed = ti.healed()
      if ti.installed() then
        if healed > 0 then
          vim.health.ok(
            ("tree_integrity installed (%d stale child id(s) healed this session)"):format(healed)
          )
        else
          vim.health.ok("tree_integrity installed")
        end
      else
        vim.health.info(
          "tree_integrity enabled but not installed "
            .. "(needs the neo-tree adapter; patched on the first tree buffer)"
        )
      end
    end
  end

  -- sidebar_guard: which strategy is in force, and -- for the opt-in pin only
  -- -- whether the open tree windows actually carry it. The default redirect
  -- has no per-window state to inspect: it is an autocmd, and reporting
  -- "unpinned" for it would read as a fault when it is the normal case.
  if is_enabled("sidebar_guard") then
    local ok_ad, adapter_mod2 = pcall(require, "filetree.adapter")
    local active_adapter = ok_ad and adapter_mod2.get() or nil
    local ok_gcfg, ft_cfg = pcall(require, "filetree.config")
    local guard_cfg = ok_gcfg and ((ft_cfg.get().features or {}).sidebar_guard or {}) or {}
    local hard_pin = guard_cfg.winfixbuf == true

    if active_adapter and active_adapter.name ~= "neotree" then
      vim.health.info("sidebar_guard: no-op — only the neo-tree adapter is affected")
    elseif not hard_pin then
      vim.health.ok(
        "sidebar_guard active (redirect: a foreign buffer in the sidebar is moved "
          .. "to an editor window and the tree put back)"
      )
    elseif vim.fn.exists("&winfixbuf") ~= 1 then
      vim.health.warn(
        "sidebar_guard: winfixbuf = true was asked for, but this Neovim build has "
          .. "no &winfixbuf (< 0.10) — unset it to get the redirect instead"
      )
    else
      local pinned, total = 0, 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local ok_b, is_tree = pcall(function()
          return require("filetree.util.buffer").is_tree_buffer(vim.api.nvim_win_get_buf(w))
        end)
        if ok_b and is_tree and vim.api.nvim_win_get_config(w).relative == "" then
          total = total + 1
          local ok_w, v = pcall(function()
            return vim.wo[w].winfixbuf
          end)
          if ok_w and v then pinned = pinned + 1 end
        end
      end
      if total == 0 then
        vim.health.ok("sidebar_guard active (winfixbuf pin; no tree window open to check)")
      elseif pinned == total then
        vim.health.ok(("sidebar_guard active (%d tree window(s) pinned)"):format(total))
      else
        vim.health.warn(
          ("sidebar_guard: %d of %d tree window(s) not pinned"):format(total - pinned, total)
        )
      end
    end
  end

  -- Human-readable category headings + feature names.
  local CATEGORY_LABELS = {
    nav = "navigation & reveal",
    ui = "display / UI",
    fileops = "file operations",
    search = "search & filter",
    paths = "paths & clipboard",
    git = "git",
    org = "marks & organization",
    system = "system integration",
    lsp = "LSP",
    compare = "diff & compare",
    infra = "infrastructure",
  }
  local ACRONYM = { lsp = "LSP", fm = "FM", ui = "UI" }
  local function humanize(key)
    local out = {}
    for word in key:gmatch("[^_]+") do
      out[#out + 1] = ACRONYM[word] or (word:sub(1, 1):upper() .. word:sub(2))
    end
    return table.concat(out, " ")
  end

  local by_cat = registry.by_category()
  for _, cat in ipairs(registry.CATEGORY_ORDER) do
    vim.health.start("filetree.nvim — features: " .. (CATEGORY_LABELS[cat] or cat))
    for _, name in ipairs(by_cat[cat] or {}) do
      if is_enabled(name) then
        vim.health.ok(humanize(name) .. " — enabled")
      else
        vim.health.info(humanize(name) .. " — disabled")
      end
    end
  end

  -- ── Optional dependencies ─────────────────────────────────────────────────
  vim.health.start("filetree.nvim — optional dependencies")

  local optionals = {
    { mod = "telescope", label = "Telescope (for future telescope integration)" },
    { mod = "fzf-lua", label = "fzf-lua (for future fzf integration)" },
    { mod = "pdfport", label = "pdfport.nvim (for pdf_open text extraction and pdf_create)" },
    { mod = "mdview", label = "mdview.nvim (for mdview_open)" },
    {
      mod = "menu",
      label = "nvzone/menu (optional renderer for context_menu; ui.kit.menu is used otherwise)",
    },
    { mod = "images", label = "images.nvim (preview image backend, works on native Windows)" },
    { mod = "image", label = "image.nvim (preview image backend, Kitty protocol terminals)" },
    { mod = "gopath", label = "gopath.nvim (link_create repair: broken-link target search)" },
    { mod = "netman", label = "netman.nvim (remote sources in the source switcher)" },
    {
      mod = "markdown_nvim",
      label = "markdown.nvim (markdown reference updates on rename/move/delete)",
    },
  }
  for _, o in ipairs(optionals) do
    if pcall(require, o.mod) then
      vim.health.ok(o.label .. " — found")
    else
      vim.health.info(o.label .. " — not installed (optional)")
    end
  end

  -- ── pickers.nvim integration ──────────────────────────────────────────────
  -- find_files / grep_in_dir hand the node's directory to pickers.nvim when it is
  -- installed and neither side opted out; say which of the three conditions
  -- holds, so "why did `f` not use pickers.nvim?" has an answer here.
  vim.health.start("filetree.nvim — pickers.nvim integration")
  local ok_pk, pk_bridge = pcall(require, "pickers.integrations.filetree")
  if not ok_pk then
    vim.health.info("pickers.nvim (with `pickers.integrations.filetree`) not installed (optional)")
  else
    vim.health.ok("pickers.nvim found")
    local int = require("filetree.config").get().integrations
    if type(int) == "table" and int.pickers == false then
      vim.health.info(
        "`integrations.pickers = false` here — find_files / grep_in_dir use their own backends"
      )
    elseif pk_bridge.available() then
      vim.health.ok("active — `f` / `gr` / `tf` / `tg` run through pickers.nvim")
    else
      vim.health.info(
        "not active — pickers.nvim has `filetree = { enabled = false }` or no picker engine "
          .. "(telescope / fzf-lua / snacks) installed; find_files / grep_in_dir use their own backends"
      )
    end
  end

  -- ── Key conflicts ─────────────────────────────────────────────────────────
  -- Two actions on one key: the later `:map` wins silently and the other action
  -- is unreachable. Read from the registry, so it sees every tree attached so far.
  vim.health.start("filetree.nvim — key conflicts")
  local ok_kc, key_conflicts = pcall(require, "filetree.util.key_conflicts")
  if not ok_kc then
    vim.health.warn("filetree.util.key_conflicts failed to load: " .. tostring(key_conflicts))
  else
    local conflicts = key_conflicts.find(vim.api.nvim_get_current_buf())
    if #conflicts == 0 then
      vim.health.ok("no key is claimed by more than one action")
    else
      for _, c in ipairs(conflicts) do
        local names = {}
        for _, claim in ipairs(c.claims) do
          names[#names + 1] = key_conflicts.label(claim, c.active)
        end
        vim.health.warn(
          ("%s is claimed by: %s"):format(c.lhs, table.concat(names, "; ")),
          { "run :Filetree keys to move one of them, or set one of the keys in setup()" }
        )
      end
    end
  end

  -- ── Reference engine ──────────────────────────────────────────────────────
  -- What the engine would do on the next rename/move, and whether it has the
  -- fast path (ripgrep) available -- the single question behind "why did my
  -- links not get updated?".
  vim.health.start("filetree.nvim — reference engine")
  local ok_refs, refs = pcall(require, "filetree.refs")
  if not ok_refs then
    vim.health.warn("filetree.refs failed to load: " .. tostring(refs))
  else
    for _, line in ipairs(refs.status()) do
      vim.health.info(line)
    end
    if vim.fn.executable("rg") == 1 then
      vim.health.ok("ripgrep found — reference scans use the fast pre-filter")
    else
      vim.health.warn(
        "ripgrep not found — reference scans fall back to a capped "
          .. "directory walk (slower; raise refs.scan.max_files if it stops early)",
        { "install ripgrep" }
      )
    end
  end

  -- ── Declared tools (lib.nvim.deps) ───────────────────────────────────────
  -- filetree.nvim's own docs/install.json — the same trash/rg tools probed
  -- above, but with their declared `why` and a pointer to `:Lib deps show`.
  -- Does nothing if lib.nvim.deps is unavailable (older lib.nvim).
  local ok_deps, deps_health = pcall(require, "lib.nvim.deps.health")
  if ok_deps then
    vim.health.start("filetree.nvim — declared tools (lib.nvim.deps)")
    deps_health.report_for("filetree.nvim")
  end

  -- ── Composer route pre-flight ─────────────────────────────────────────────
  -- Same soft-dependency as the very first check above (lib.nvim may be
  -- absent) -- an unguarded require here used to turn a machine without
  -- lib.nvim into a :checkhealth that itself throws, right after this
  -- function already reported that condition gracefully via vim.health.error.
  local ok_composer, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if ok_composer then
    -- The name the command was registered under (`setup({ command = "Foo" })`
    -- registers no :Filetree at all, and a literal would report it missing).
    local ok_name, verb = pcall(function()
      return require("filetree.commands").command_name()
    end)
    composer.checkhealth(ok_name and verb or "Filetree")
  end
end

return M
