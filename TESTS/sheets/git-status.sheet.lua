-- Feature sheet: the git state of each file as a sign on its row of the tree (features.git_status).
-- Automated, in a child editor with a UI attached, git run for real: a repository with one commit, one
-- committed file changed and one new file, the own tree open on it with the folder open. The changed
-- file carries the sign of "modified", the new one that of "untracked", the unchanged one none, and
-- the folder shows the worst state below it. After the change is committed and the buffer written,
-- the sign of the changed file goes away.
-- Left for a person: how the signs read in the colours of a real colour scheme.
return {
  id = "filetree.git-status",
  title = "filetree.nvim: the git state of each file as a sign on its row of the tree",
  task = "filetree.nvim/abnahme-von-hand-prozess-features-papierkorb-dateimanager-sy",
  feature = "filetree.git-status",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/gitst_" .. vim.uv.hrtime() .. "/repo"
      vim.fn.mkdir(work .. "/src", "p")
      vim.fn.writefile({ "one" }, work .. "/src/changed.lua")
      vim.fn.writefile({ "same" }, work .. "/src/same.lua")
      _G.git = function(...)
        local res = vim.system({ "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.test", "-c", "commit.gpgsign=false", ... }, { cwd = work, text = true }):wait()
        assert(res.code == 0, table.concat({ ... }, " ") .. ": " .. (res.stderr or ""))
        return res.stdout or ""
      end
      _G.git("init", "-q")
      _G.git("add", ".")
      _G.git("commit", "-q", "-m", "first")
      vim.fn.writefile({ "one", "two" }, work .. "/src/changed.lua")
      vim.fn.writefile({ "new" }, work .. "/src/new.lua")
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      ---What the row of `path` shows on the screen (the tree draws its badges while it redraws, as
      ---ephemeral marks: only the screen has them).
      _G.row = function(path)
        local lnum = _G.adapter.get_node_line(path)
        if not lnum then return "" end
        vim.cmd.redraw()
        local at = vim.fn.screenpos(_G.win, lnum, 1)
        if at.row == 0 then return "" end
        local wincol = vim.fn.win_screenpos(_G.win)[2]
        local cells = {}
        for col = wincol, wincol + vim.api.nvim_win_get_width(_G.win) - 1 do
          cells[#cells + 1] = vim.fn.screenstring(at.row, col)
        end
        return table.concat(cells)
      end]],

      note = "a repository with one commit (the sheet's preparation); src/changed.lua changed, src/new.lua new, src/same.lua as committed",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = {
            enabled = true,
            debounce_ms = 0,
            signs = {
              modified = { text = "M!", hl = "DiagnosticWarn" },
              untracked = { text = "U?", hl = "Comment" },
            },
          },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/src" })]],
      note = "the own tree on the left with src open; the signs of modified and untracked as plain letters",
    },
    {
      wait = "_G.row(_G.work .. '/src/changed.lua'):find('M!', 1, true) ~= nil",
      timeout = 10000,
      note = "the changed file carries the sign of modified",
    },
    {
      wait = "_G.row(_G.work .. '/src/new.lua'):find('U?', 1, true) ~= nil",
      timeout = 5000,
      note = "the new file that of untracked",
    },
    {
      expect = "_G.row(_G.work .. '/src/same.lua'):find('M!', 1, true) == nil and _G.row(_G.work .. '/src/same.lua'):find('U?', 1, true) == nil",
      note = "the unchanged file none",
    },
    {
      lua = [[_G.git("add", "src/changed.lua")
      _G.git("commit", "-q", "-m", "second")]],
      note = "the change is committed outside the editor (the sheet's preparation, as in a terminal next to it)",
    },
    {
      lua = 'vim.api.nvim_exec_autocmds("FocusGained", {})',
      note = "the editor gets the focus back",
    },
    {
      wait = "_G.row(_G.work .. '/src/changed.lua'):find('M!', 1, true) == nil",
      timeout = 10000,
      note = "the sign of the committed file is gone",
    },
    {
      expect = "_G.row(_G.work .. '/src/new.lua'):find('U?', 1, true) ~= nil",
      note = "the new file keeps its sign",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "In a real repository and colour scheme the default signs (●, +, ?, ...) read well next to the names",
  },
}
