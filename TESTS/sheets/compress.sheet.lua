-- Feature sheet: compress the node under the cursor to a zip beside it (key `gz`).
-- Automated, in a child editor with a UI attached: the own tree on a project, the cursor on a folder
-- with two files. `gz` writes `<folder>.zip` next to it with the archiver of the machine (Info-ZIP
-- `zip` or a bsdtar, run for real), says so, and the zip appears in the tree; the folder is untouched.
-- A second `gz` does not overwrite it: the new zip is `<folder>_2.zip`.
-- Left for a person: several marked nodes and the question "each" or "together".
return {
  id = "filetree.compress",
  title = "filetree.nvim: compress the node under the cursor to a zip",
  feature = "filetree.compress",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/zip_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "assets/a.txt", "assets/b.txt", "README.md" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "content of " .. rel }, path)
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
      ---The size of a file, 0 when it is not there.
      _G.size = function(path)
        local st = vim.uv.fs_stat(path)
        return st and st.size or 0
      end]],
      note = "a project with a folder assets of two files",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          compress = { enabled = true },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/assets"), 0 })]],
      note = "the own tree on the left, the cursor on the folder assets",
    },
    {
      expect = "require('filetree.features.system.compress.archiver').detect() ~= nil",
      note = "the machine has an archiver (zip, or the bsdtar Windows and macOS ship)",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_current_node() ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { keys = "gz", note = "compress the folder" },
    {
      wait = "_G.told('Created 1 zip')",
      timeout = 10000,
      note = "the zip is written and the user told",
    },
    {
      expect = "_G.size(_G.work .. '/assets.zip') > 0",
      note = "assets.zip lies next to the folder",
    },
    {
      wait = "_G.adapter.get_node_line(_G.work .. '/assets.zip') ~= nil",
      timeout = 5000,
      note = "and is a row of the tree",
    },
    {
      expect = "vim.fn.filereadable(_G.work .. '/assets/a.txt') == 1 and vim.fn.filereadable(_G.work .. '/assets/b.txt') == 1",
      note = "the folder is untouched",
    },
    {
      lua = "vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. '/assets'), 0 })",
      note = "the cursor back on the folder",
    },
    { keys = "gz", note = "compress it again" },
    {
      wait = "_G.size(_G.work .. '/assets_2.zip') > 0",
      timeout = 10000,
      note = "the second zip gets a new name",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "Several marked nodes: gz asks 'each' or 'together', and the zip of 'together' holds all of them",
    "The zip opens in the system's archive tool with the folder at its top",
  },
}
