-- Feature sheet: show the node under the cursor in the file manager (docs/FEATURES, key `<leader>fm`).
-- Automated, in a child editor with a UI attached: the own tree on a project, the cursor on a file.
-- `<leader>fm` hands the file to the file manager the user configured (`features.open_in_fm.command`,
-- here a recording stand-in, so no window opens) with the file's path as its last argument, and says
-- so in a message. On a folder the folder itself is handed over.
-- Left for a person: the platform's own file manager (Explorer with the file selected, Finder, the
-- Linux managers) without `command`.
return {
  id = "filetree.open-in-fm",
  title = "filetree.nvim: show the node under the cursor in the file manager",
  feature = "filetree.open-in-fm",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  fakes = { "ft-file-manager" },
  steps = {
    {
      lua = 'vim.g.mapleader = " "; vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no icon font; the leader is space",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/fm_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "src/main.lua", "README.md" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "x" }, path)
      end
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      _G.notes = {}
      local real_notify = vim.notify
      vim.notify = function(msg, level, opts)
        _G.notes[#_G.notes + 1] = tostring(msg)
        return real_notify(msg, level, opts)
      end
      ---Was something that holds `text` said?
      _G.told = function(text)
        for _, note in ipairs(_G.notes) do
          if note:find(text, 1, true) then return true end
        end
        return false
      end
      ---The calls of the stand-in file manager.
      _G.calls = function()
        return require("testing.fake_programs").read(vim.env.TESTING_FAKES, "ft-file-manager")
      end]],
      note = "a project with src/main.lua and README.md; what is said is recorded",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          open_in_fm = { enabled = true, command = "ft-file-manager" },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/src" })
      vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/src/main.lua"), 0 })]],
      note = "the own tree on the left, the folder src open, the cursor on src/main.lua",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_current_node() ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { keys = " fm", note = "show the file in the file manager" },
    { wait = "#_G.calls() == 1", timeout = 5000, note = "the file manager is started once" },
    {
      expect = "vim.fs.normalize(_G.calls()[1].argv[#_G.calls()[1].argv]) == _G.work .. '/src/main.lua'",
      note = "with the file as its last argument",
    },
    { expect = "_G.told('Opening in file manager')", note = "and the user is told" },
    {
      lua = "vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. '/src'), 0 })",
      note = "the cursor on the folder src",
    },
    { keys = " fm", note = "show the folder" },
    { wait = "#_G.calls() == 2", timeout = 5000, note = "the file manager is started again" },
    {
      expect = "vim.fs.normalize(_G.calls()[2].argv[#_G.calls()[2].argv]) == _G.work .. '/src'",
      note = "with the folder",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "Without `command`: on Windows Explorer opens with the file selected, on macOS Finder, on Linux the installed file manager",
  },
}
