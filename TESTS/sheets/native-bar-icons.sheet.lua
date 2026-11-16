-- Feature sheet: the icons of the views in the bar of the own tree (docs/FEATURES/BACKENDS.md, "Icons in
-- the bar").
-- Automated, in a child editor with a UI attached and a Nerd Font declared: a wide tree shows every view
-- with its icon in front of its title; a narrow one keeps the title of the view on screen and the icon
-- alone for the others, where without icons they were cut to one letter. A view of `native.views` with
-- an icon and a title of its own shows those. With `native.icons = false` the titles are cut as before.
-- Left for a person: whether the glyphs read well in the font of the real terminal.
return {
  id = "filetree.native-bar-icons",
  title = "filetree.nvim: the views show an icon in the bar of the own tree",
  task = "filetree.nvim/abnahme-own-tree-pinned-folders-history-helper",
  feature = "filetree.native-views",
  engine = "rpc",
  sizes = { { rows = 10, cols = 90 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = true',
      note = "no intro, no status line (it would name the temporary path), a Nerd Font declared",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/icons_" .. vim.uv.hrtime() .. "/proj"
      vim.fn.mkdir(work .. "/lua", "p")
      vim.fn.writefile({ "x" }, work .. "/lua/init.lua")
      vim.fn.writefile({ "# Readme" }, work .. "/README.md")
      vim.cmd.cd(vim.fn.fnameescape(work))
      vim.cmd.edit(vim.fn.fnameescape(work .. "/README.md"))
      _G.work = work
      ---Open the own tree with these native options and answer the text of its bar.
      _G.open = function(native)
        require("filetree.native").reset()
        require("filetree").setup({
          adapter = "native",
          native = vim.tbl_extend("force", { watch = false }, native),
          features = {
            file_watcher = { enabled = false },
            auto_reveal = { enabled = false },
            git_status = { enabled = false },
          },
        })
        local adapter = require("filetree").adapter()
        adapter.toggle_at("left", { dir = _G.work })
        _G.win = adapter.get_winid()
        _G.view = adapter.get_state()
      end
      _G.bar = function()
        require("filetree.native.bar").write(_G.view)
        return vim.api.nvim_eval_statusline(vim.wo[_G.win].winbar, { winid = _G.win, use_winbar = true }).str
      end
      _G.icon = function(name)
        return require("filetree.native.bar").ICONS[name]
          or require("lib.nvim.tree.registry").get("source", name).icon
      end]],
      note = "a project; helpers to open the tree with given options and to read its bar",
    },
    {
      lua = '_G.open({ width = 80, views = { { "files" }, { "buffers" }, { "git" }, { "diagnostics" } } })',
      note = "a wide tree with four views",
    },
    { settle = 3000, note = "what the features started after the open has run" },
    {
      expect = "_G.bar():find(_G.icon('files') .. ' Files', 1, true) ~= nil and _G.bar():find(_G.icon('git') .. ' Git', 1, true) ~= nil",
      note = "every view with its icon in front of its title",
    },
    {
      lua = '_G.open({ width = 18, views = { { "files" }, { "buffers" }, { "git" }, { "diagnostics" } } })',
      note = "the same views in a narrow tree",
    },
    { settle = 1000 },
    {
      expect = "_G.bar():find(_G.icon('files') .. ' Files', 1, true) ~= nil",
      note = "the view on screen keeps icon and title",
    },
    {
      expect = "_G.bar():find(_G.icon('buffers'), 1, true) ~= nil and not _G.bar():find('Buf', 1, true)",
      note = "the others keep the icon alone",
    },
    { screen = "narrow", note = "the bar of a narrow tree" },
    {
      lua = '_G.open({ width = 80, views = { { "files" }, { name = "work", title = "Work", icon = "W", "buffers", "files" } } })',
      note = "a view of native.views with its own icon and title",
    },
    { settle = 1000 },
    { expect = "_G.bar():find('W Work', 1, true) ~= nil", note = "it shows them" },
    {
      lua = '_G.open({ width = 18, icons = false, views = { { "files" }, { "buffers" }, { "git" } } })',
      note = "icons switched off",
    },
    { settle = 1000 },
    {
      expect = "_G.bar():find(_G.icon('buffers'), 1, true) == nil and _G.bar():find(' Buf ', 1, true) ~= nil",
      note = "no icon: the titles are cut as before",
    },
  },
  judge = {
    "In the snapshot the icons of the bar can be told apart and match their views (folder, buffers, git branch, warning)",
  },
  manual = {
    "In the real terminal with your Nerd Font: the icons of the bar are drawn whole and line up with the tree below (none cut, none twice as wide)",
  },
}
