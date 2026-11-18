-- Feature sheet: open the node under the cursor with an application of the user's list
-- (features.open_with.apps, each with its own key).
-- Automated, in a child editor with a UI attached: the own tree on a project, the cursor on a file,
-- one application configured with its key `ov` and an argument (a recording stand-in, so no window
-- opens). `ov` starts the application with the argument and the file's path last, and says so.
-- Left for a person: a real application (an editor, an image viewer) opening the file.
return {
  id = "filetree.open-with",
  title = "filetree.nvim: open the node under the cursor with a configured application",
  task = "filetree.nvim/abnahme-von-hand-prozess-features-papierkorb-dateimanager-sy",
  feature = "filetree.open-with",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  fakes = { "ft-viewer" },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/ow_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "docs/guide.md", "README.md" }) do
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
      _G.told = function(text)
        for _, note in ipairs(_G.notes) do
          if note:find(text, 1, true) then return true end
        end
        return false
      end
      _G.calls = function()
        return require("testing.fake_programs").read(vim.env.TESTING_FAKES, "ft-viewer")
      end]],
      note = "a project with docs/guide.md and README.md; what is said is recorded",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          open_with = {
            enabled = true,
            apps = { { name = "Viewer", cmd = "ft-viewer", args = { "--new-window" }, keymap = "ov" } },
          },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/docs" })
      vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/docs/guide.md"), 0 })]],
      note = "the own tree on the left, docs open, the cursor on docs/guide.md",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_current_node() ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { keys = "ov", note = "open the file with the viewer" },
    { wait = "#_G.calls() == 1", timeout = 5000, note = "the viewer is started once" },
    { expect = "_G.calls()[1].argv[1] == '--new-window'", note = "with its argument first" },
    {
      expect = "vim.fs.normalize(_G.calls()[1].argv[2]) == _G.work .. '/docs/guide.md'",
      note = "and the file last",
    },
    { wait = "_G.told('Opening with Viewer: guide.md')", note = "the user is told" },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "A real application from the list (an editor, an image viewer) opens the file and the editor stays usable",
  },
}
