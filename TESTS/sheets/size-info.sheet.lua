-- Feature sheet: the size of each file and folder in a column of the tree (features.size_info).
-- Automated, in a child editor with a UI attached, without the helper process: the own tree on a
-- project with a folder of two files. A file shows its size right away (from the file system); the
-- folder's size is added up in a process of its own (PowerShell on Windows, `du` elsewhere, run for
-- real) and appears in its row once that process is done.
-- Left for a person: a large folder (the size comes later, the tree stays responsive while the
-- processes run one after another) and the same with the helper process (one walk in that process).
return {
  id = "filetree.size-info",
  title = "filetree.nvim: the size of each file and folder in a column of the tree",
  task = "filetree.nvim/abnahme-von-hand-prozess-features-papierkorb-dateimanager-sy",
  feature = "filetree.size-info",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/size_" .. vim.uv.hrtime() .. "/proj"
      vim.fn.mkdir(work .. "/data", "p")
      local function write(rel, bytes)
        local fd = assert(io.open(work .. "/" .. rel, "wb"))
        fd:write(string.rep("x", bytes))
        fd:close()
      end
      write("data/big.bin", 20480)
      write("data/small.bin", 3000)
      write("README.md", 100)
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      ---What the row of `path` shows on the screen (the column is drawn while the tree redraws).
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
      end
      ---Does the row of `path` show a size ("20 KB", "1.2 MB", "100 B")?
      _G.has_size = function(path)
        return _G.row(path):find("%d[%d%.]* ?[KMGT]?i?B") ~= nil
      end]],
      note = "a project: data/ with a 20 KB and a 3 KB file, README.md of 100 bytes",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false, fs = { helper = false } },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          size_info = { enabled = true },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/data" })]],
      note = "the own tree on the left with data/ open, no helper process",
    },
    {
      wait = "_G.has_size(_G.work .. '/data/big.bin') and _G.has_size(_G.work .. '/README.md')",
      timeout = 5000,
      note = "the files show their size",
    },
    {
      expect = "_G.row(_G.work .. '/data/big.bin'):find('20', 1, true) ~= nil",
      note = "big.bin about 20 KB",
    },
    {
      wait = "_G.has_size(_G.work .. '/data')",
      timeout = 15000,
      note = "the folder's size appears once its process is done",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "A large folder: its size comes later, and the tree stays responsive meanwhile",
    "With the helper process built (native.fs.helper): the folder sizes come from it, no process per folder",
  },
}
