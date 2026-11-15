-- Feature sheet: the folders the top row of the own tree lies in stay pinned while the tree is scrolled
-- (`native.sticky_parents`, docs/FEATURES/BACKENDS.md).
-- Automated, in a child editor with a UI attached (so WinScrolled fires as it does for a person): a
-- project with a deep folder of forty files, everything open. Not scrolled: nothing is pinned. Scrolled
-- with the keyboard: the three nearest folders stand on top, drawn as their rows, and the cursor is
-- not under them. Scrolled on with the wheel: still pinned. A click on the first pinned row puts the
-- cursor on that folder. Scrolled back to the top: the pinned rows are gone.
-- Left for a person: how it reads (the pinned rows against the rows below), and a real terminal with a
-- touchpad.
return {
  id = "filetree.native-sticky-parents",
  title = "filetree.nvim: the folders of the top row stay pinned while the own tree is scrolled",
  task = "filetree.nvim/abnahme-own-tree-pinned-folders-history-helper",
  feature = "filetree.native-sticky-parents",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line (it would name the temporary path), no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/sticky_" .. vim.uv.hrtime() .. "/proj"
      for i = 1, 40 do
        local path = ("%s/deep/a/b/f%02d.lua"):format(work, i)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "return " .. i }, path)
      end
      vim.fn.writefile({ "x" }, work .. "/deep/d.lua")
      vim.fn.writefile({ "x" }, work .. "/deep/a/a.lua")
      vim.fn.writefile({ "# Readme" }, work .. "/README.md")
      vim.cmd.cd(vim.fn.fnameescape(work))
      vim.cmd.edit(vim.fn.fnameescape(work .. "/README.md"))
      _G.work = work]],
      note = "a project: deep/a/b with forty files, a file on every level, README.md",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.view = _G.adapter.get_state()
      _G.view:expand_all()
      _G.sticky = require("filetree.native.sticky")
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      ---The texts of the pinned rows, top to bottom; nil when nothing is pinned.
      _G.pinned = function()
        local state = _G.sticky.state(_G.view)
        if not state then return nil end
        local out = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
          out[#out + 1] = vim.trim(line)
        end
        return table.concat(out, " | ")
      end]],
      note = "the own tree on the left, every folder open, the tree focused",
    },
    { wait = "_G.view.tree:count() > 40", note = "the folders are read" },
    { keys = "gg" },
    { settle = 3000, note = "what the features started after the open has run" },
    { expect = "_G.pinned() == nil", note = "not scrolled: nothing is pinned" },
    { keys = "10<C-e>", note = "scroll down with the keyboard" },
    {
      wait = "_G.pinned() ~= nil and select(2, _G.pinned():gsub('|', '')) == 2",
      note = "three folders are pinned",
    },
    {
      expect = "_G.pinned():find('a', 1, true) ~= nil and _G.pinned():find('b', 1, true) ~= nil",
      note = "the nearest ones: a and b among them",
    },
    {
      expect = "vim.api.nvim_win_get_cursor(_G.win)[1] >= vim.fn.line('w0', _G.win) + 3",
      note = "the cursor was taken along: it is not under the pinned rows",
    },
    { screen = "pinned", note = "three pinned folders above the files of the deep folder" },
    {
      lua = [[_G.top_before = vim.fn.line("w0", _G.win)
      vim.api.nvim_input_mouse("wheel", "down", "", 0, 8, 5)]],
      note = "scroll on with the wheel",
    },
    { wait = "vim.fn.line('w0', _G.win) > _G.top_before", note = "the wheel scrolled the tree" },
    {
      expect = "_G.pinned() ~= nil and select(2, _G.pinned():gsub('|', '')) == 2",
      note = "still three pinned folders",
    },
    {
      lua = [[-- screen row of the first text row of the tree: below its view bar
      local row = (vim.fn.getwininfo(_G.win)[1] or {}).winbar or 0
      vim.api.nvim_input_mouse("left", "press", "", 0, row, 5)
      vim.api.nvim_input_mouse("left", "release", "", 0, row, 5)]],
      note = "click on the first pinned row",
    },
    {
      wait = "(_G.adapter.get_current_node() or {}).path == _G.work .. '/deep'",
      note = "the cursor is on the folder that was pinned first",
    },
    { keys = "gg" },
    { wait = "_G.pinned() == nil", note = "back at the top: nothing is pinned" },
    {
      expect = "#vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end, vim.api.nvim_list_wins()) == 0",
      note = "and no float is left",
    },
  },
  judge = {
    "In the snapshot the three pinned folders read as part of the tree and can be told from the rows below them",
  },
  manual = {
    "In a real terminal: scrolling with the wheel or a touchpad through a deep folder, the pinned rows follow without flicker",
    "With the tree not focused: a click on a pinned row focuses the tree first, a second click jumps to the folder",
  },
}
