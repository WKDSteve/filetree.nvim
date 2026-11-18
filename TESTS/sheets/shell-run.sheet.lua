-- Feature sheet: run a shell command in the folder of the node under the cursor (key `i`).
-- Automated, in a child editor with a UI attached: the own tree on a project, the cursor on a file in
-- a folder. `i` asks for a command, naming the folder; the command typed runs in a terminal split
-- below with that folder as its working directory, and its output is there.
-- Left for a person: an interactive command (a password prompt) and the split closing by itself
-- after a command that exits 0 (`close_on_ok`, on by default).
return {
  id = "filetree.shell-run",
  title = "filetree.nvim: run a shell command in the folder of the node under the cursor",
  task = "filetree.nvim/abnahme-von-hand-prozess-features-papierkorb-dateimanager-sy",
  feature = "filetree.shell-run",
  engine = "rpc",
  sizes = { { rows = 20, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[if vim.fn.has("win32") == 1 then
        vim.o.shell = "cmd.exe"
        vim.o.shellcmdflag = "/s /c"
        vim.o.shellquote = ""
        vim.o.shellxquote = '"'
      else
        vim.o.shell = "sh"
        vim.o.shellcmdflag = "-c"
      end]],
      note = "the platform's plain shell: an inherited $SHELL (Git Bash on Windows) may not fit the editor's flags",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/sh_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "tools/build.txt", "README.md" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "x" }, path)
      end
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      ---The text of the terminal buffer the command runs in, "" while there is none.
      _G.term_text = function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].buftype == "terminal" then
            return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          end
        end
        return ""
      end]],
      note = "a project with tools/build.txt and README.md",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          shell_run = { enabled = true, close_on_ok = false },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/tools" })
      vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/tools/build.txt"), 0 })]],
      note = "the own tree on the left, tools open, the cursor on tools/build.txt (the split stays open)",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_current_node() ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { input = "i", note = "ask for a command (input: the prompt opens in insert mode)" },
    { wait = "vim.fn.mode() == 'i'", note = "the prompt takes input" },
    {
      input = "echo filetree-shell-ok\r",
      note = "type a command every shell knows (cmd, sh, PowerShell), and run it",
    },
    {
      wait = "_G.term_text():find('filetree%-shell%-ok') ~= nil",
      timeout = 10000,
      note = "its output is in the terminal split",
    },
    {
      expect = [[(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].buftype == "terminal" then
            local job = vim.b[buf].terminal_job_id
            return job ~= nil
          end
        end
        return false
      end)()]],
      note = "the split is a terminal of its own",
    },
  },
  manual = {
    "An interactive command (one that asks for input) can be answered in the split",
    "With the default close_on_ok the split closes after a command that exits 0, and stays after one that fails",
  },
}
