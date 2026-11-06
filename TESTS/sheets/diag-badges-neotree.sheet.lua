-- Live check: the E:/W: diagnostic badges in a real neo-tree
-- (task filetree.nvim/diag-badges-vanish-live-check, part "Diagnostik-Badges").
-- Automated: a real neo-tree (the commits CI pins, see TESTS/minimal_init_sheet_neotree.lua) on a
-- small project, `lsp_diagnostics` on. Diagnostics are published with vim.diagnostic.set (no
-- language server needed: the feature reads vim.diagnostic.get); the file nodes get their own
-- counts and the folder the sum. Then the two ways the badges used to vanish: neo-tree redraws the
-- tree on its own (refresh, as a git status, a watcher event or an async scan does) and the focus
-- leaves the tree and comes back (every focus change is checked). The badges stay. Finally the
-- diagnostics are cleared and every badge is gone. neo-tree's own diagnostics and git status are
-- off, so every badge on screen is filetree's. Left for a person: a week of normal
-- work with a real language server; flicker on collapse and handle_guard/EPERM are not covered.
return {
  id = "filetree.diag-badges-neotree",
  title = "filetree.nvim: E:/W: diagnostic badges in neo-tree stay, and go with the diagnostics",
  task = "filetree.nvim/diag-badges-vanish-live-check",
  engine = "rpc",
  minit = "TESTS/minimal_init_sheet_neotree.lua",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false',
      note = "no intro, no status line (it would name the temporary path)",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.fn.tempname()) .. "/proj"
      vim.fn.mkdir(work .. "/src", "p")
      -- the real path (on macOS the temp dir /var/... links to /private/var/...): the sheet works
      -- in the directory neo-tree shows; filetree matches a buffer opened through a link as well
      -- (TESTS/gaps.lua, lsp_diagnostics link case)
      work = vim.fs.normalize(vim.uv.fs_realpath(work))
      vim.fn.writefile({ "return 1" }, work .. "/src/a.lua")
      vim.fn.writefile({ "return 2" }, work .. "/src/b.lua")
      vim.fn.writefile({ "return 3" }, work .. "/src/clean.lua")
      vim.fn.writefile({ "# Readme" }, work .. "/README.md")
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work]],
      note = "a project: src/a.lua, src/b.lua, src/clean.lua, README.md",
    },
    {
      lua = [[require("neo-tree").setup({
        close_if_last_window = false,
        enable_git_status = false,
        enable_diagnostics = false,
        -- its window-size poll re-arms a timer for ever: the editor would never be idle for `settle`
        resize_timer_interval = -1,
        filesystem = { use_libuv_file_watcher = false, follow_current_file = { enabled = false } },
        window = { position = "left", width = 40 },
      })
      require("filetree").setup({
        adapter = "neotree",
        features = {
          lsp_diagnostics = { enabled = true, debounce_ms = 50 },
          git_status = { enabled = false },
          -- its fs_event on the root never ends, so the editor would never be idle for `settle`
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
        },
      })
      _G.adapter = require("filetree.adapter.neotree")
      -- Badge text per node name, read from filetree's extmarks on the tree buffer.
      _G.badges = function()
        local out, n = {}, 0
        local b = _G.adapter.get_bufnr()
        local ns = vim.api.nvim_get_namespaces().filetree_lsp_diagnostics
        if not (b and ns and vim.api.nvim_buf_is_valid(b)) then return out, 0 end
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
          local node = _G.adapter.get_node_at_line(b, m[2])
          local text = {}
          for _, chunk in ipairs(m[4].virt_text or {}) do text[#text + 1] = chunk[1] end
          if node and node.path then
            out[vim.fs.basename((node.path:gsub("[\\/]+$", "")))] = vim.trim(table.concat(text))
            n = n + 1
          end
        end
        return out, n
      end
      _G.has = function(want)
        local got, n = _G.badges()
        local count = 0
        for _ in pairs(want) do count = count + 1 end
        if n ~= count then return false end
        for name, text in pairs(want) do
          if got[name] ~= text then return false end
        end
        return true
      end]],
      note = "neo-tree with its own diagnostics and git status off; filetree on it with lsp_diagnostics",
    },
    {
      lua = [[require("neo-tree.command").execute({
        action = "show", source = "filesystem", dir = _G.work, reveal_file = _G.work .. "/src/b.lua",
      })]],
      note = "show the tree, src/ expanded",
    },
    {
      wait = [[(function()
        local b = _G.adapter.get_bufnr()
        if not b then return false end
        local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        return text:find("clean.lua", 1, true) ~= nil and text:find("README.md", 1, true) ~= nil
      end)()]],
      timeout = 10000,
      note = "the tree lists src/ with its three files and README.md",
    },
    {
      lua = "vim.api.nvim_set_current_win(_G.adapter.get_winid())",
      note = "focus the tree (`show` opens it without focusing it)",
    },
    {
      expect = "vim.api.nvim_get_current_win() == _G.adapter.get_winid()",
      note = "the tree has the focus",
    },
    { settle = 500 },
    {
      expect = [[select(2, _G.badges()) == 0]],
      note = "no diagnostics yet: no badge",
    },
    {
      lua = [[_G.diag_ns = vim.api.nvim_create_namespace("sheet_diag")
      local function buf(name)
        local b = vim.fn.bufadd(_G.work .. "/src/" .. name)
        vim.fn.bufload(b)
        return b
      end
      local E, W = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
      vim.diagnostic.set(_G.diag_ns, buf("b.lua"), {
        { lnum = 0, col = 0, severity = E, message = "boom" },
        { lnum = 0, col = 1, severity = E, message = "boom again" },
        { lnum = 0, col = 2, severity = W, message = "careful" },
      })
      vim.diagnostic.set(_G.diag_ns, buf("a.lua"), {
        { lnum = 0, col = 0, severity = W, message = "careful" },
      })]],
      note = "publish diagnostics: src/b.lua two errors and a warning, src/a.lua one warning",
    },
    {
      wait = [[_G.has({ proj = "E:2 W:2", src = "E:2 W:2", ["a.lua"] = "W:1", ["b.lua"] = "E:2 W:1" })]],
      timeout = 5000,
      note = "the file nodes carry their own counts, src/ and the root the sum; clean.lua and README.md none",
    },
    { settle = 300 },
    { screen = "badges", masks = { { row = 1 } } },
    {
      lua = [[_G.renders = 0
      _G.adapter.on_render(function() _G.renders = _G.renders + 1 end)
      require("neo-tree.sources.manager").refresh("filesystem")]],
      note = "neo-tree redraws the tree on its own (what a git status, a watcher or an async scan does)",
    },
    { wait = "_G.renders > 0", timeout = 5000, note = "neo-tree did render again" },
    { settle = 300 },
    {
      expect = [[_G.has({ proj = "E:2 W:2", src = "E:2 W:2", ["a.lua"] = "W:1", ["b.lua"] = "E:2 W:1" })]],
      note = "the badges survived neo-tree's own redraw",
    },
    {
      lua = [[local tree = _G.adapter.get_winid()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if w ~= tree and vim.api.nvim_win_get_config(w).relative == "" then
          vim.api.nvim_set_current_win(w)
          break
        end
      end]],
      note = "focus leaves the tree",
    },
    {
      expect = "vim.api.nvim_get_current_win() ~= _G.adapter.get_winid()",
      note = "the focus is outside the tree",
    },
    { settle = 300 },
    {
      lua = "vim.api.nvim_set_current_win(_G.adapter.get_winid())",
      note = "focus back on the tree",
    },
    {
      expect = "vim.api.nvim_get_current_win() == _G.adapter.get_winid()",
      note = "the tree has the focus again",
    },
    { settle = 500 },
    {
      expect = [[_G.has({ proj = "E:2 W:2", src = "E:2 W:2", ["a.lua"] = "W:1", ["b.lua"] = "E:2 W:1" })]],
      note = "the badges are still there after the focus change",
    },
    { screen = "badges-after-redraw", masks = { { row = 1 } } },
    { lua = "vim.diagnostic.reset(_G.diag_ns)", note = "clear every diagnostic" },
    {
      wait = [[select(2, _G.badges()) == 0]],
      timeout = 5000,
      note = "every badge is gone with the diagnostics",
    },
    { settle = 300 },
    { screen = "cleared", masks = { { row = 1 } } },
  },
  judge = {
    "badges: the counts sit at the end of the src/, a.lua and b.lua rows, readable, in the error / warning colour, nothing else on those rows is shifted",
    "badges-after-redraw: the same picture as badges after neo-tree's redraw and the focus change",
    "cleared: no badge is left anywhere in the tree",
  },
  manual = {
    "A week of normal work in the real config with a language server and files that have warnings (focus the tree, open and save files, open and close folders): the badges stay and do not flicker",
    "If they still vanish: note when and why (focus change, save, LSP restart), and whether the count itself went to 0 (the server dropped stale diagnostics) or only the badge was wiped",
    "Enter the result in filetree.nvim/diag-badges-vanish-live-check (R6)",
  },
}
