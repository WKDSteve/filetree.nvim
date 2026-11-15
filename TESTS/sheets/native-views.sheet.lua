-- Feature sheet: the views of the own tree and the bar of them in its winbar
-- (docs/FEATURES/BACKENDS.md; keys `"` and `!` of source_switcher, a click on a title of the bar).
-- Automated, in a child editor with a UI attached: a project with two files open in the editor. The
-- tree starts on the files. `"` shows the next view, the buffers: the two open files as its rows, the
-- title marked in the bar. A click on "Files" in the bar brings the files back, with the folder that
-- was open still open and the cursor where it was. `!` goes back one view (to the last one of the
-- bar). A view whose source is not there says why in one line and does not raise.
-- Left for a person: how the bar reads at the widths of a real sidebar, and the views of the real
-- config (git in a real repository, symbols with a real language server).
return {
  id = "filetree.native-views",
  title = "filetree.nvim: the views of the own tree, by key and by a click on the bar",
  task = "filetree.nvim/abnahme-own-tree-pinned-folders-history-helper",
  feature = "filetree.native-views",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false; vim.o.mouse = "a"',
      note = "no intro, no status line (it would name the temporary path), no icon font, the mouse on",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/views_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "lua/init.lua", "lua/mod/a.lua", "docs/guide.md", "README.md" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "x" }, path)
      end
      vim.cmd.cd(vim.fn.fnameescape(work))
      vim.cmd.edit(vim.fn.fnameescape(work .. "/lua/init.lua"))
      vim.cmd.edit(vim.fn.fnameescape(work .. "/README.md"))
      _G.work = work]],
      note = "a project; lua/init.lua and README.md are open in the editor",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          source_switcher = { enabled = true },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.view = _G.adapter.get_state()
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/lua" })
      vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/lua/init.lua"), 0 })
      vim.cmd("doautocmd CursorMoved")
      ---The lines of the tree buffer, without leading blanks.
      _G.rows = function()
        local out = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(_G.adapter.get_bufnr(), 0, -1, false)) do
          out[#out + 1] = vim.trim(line)
        end
        return table.concat(out, " | ")
      end
      ---The screen column (0-based) where a title of the bar starts; nil when it is not in the bar.
      _G.bar_col = function(title)
        local text = vim.api.nvim_eval_statusline(vim.wo[_G.win].winbar, { winid = _G.win, use_winbar = true }).str
        local at = text:find(title, 1, true)
        return at and (vim.fn.strdisplaywidth(text:sub(1, at - 1))) or nil
      end]],
      note = "the own tree on the left with the folder lua open, the cursor on lua/init.lua",
    },
    { settle = 3000, note = "what the features started after the open has run" },
    { expect = "_G.adapter.get_view() == 'files'", note = "the tree starts on the files" },
    { keys = '"', note = "the next view" },
    { wait = "_G.adapter.get_view() == 'buffers'", note = "the buffers are shown" },
    {
      wait = "_G.rows():find('init.lua', 1, true) ~= nil and _G.rows():find('README.md', 1, true) ~= nil",
      note = "the two open files are its rows",
    },
    {
      expect = "_G.rows():find('guide.md', 1, true) == nil",
      note = "a file that is not open is not",
    },
    { screen = "buffers", note = "the view of the buffers, its title marked in the bar" },
    {
      lua = [[-- the titles of the views that are not on screen are cut to a letter: the files are "F", first in the bar
      local col = assert(_G.bar_col("F"), "the bar has no title F")
      local row = vim.api.nvim_win_get_position(_G.win)[1]
      vim.api.nvim_input_mouse("left", "press", "", 0, row, col + 1)
      vim.api.nvim_input_mouse("left", "release", "", 0, row, col + 1)]],
      note = "click on the title of the files in the bar",
    },
    { wait = "_G.adapter.get_view() == 'files'", note = "the files are back" },
    {
      expect = "_G.adapter.get_node_line(_G.work .. '/lua/init.lua') ~= nil",
      note = "the folder that was open is still open",
    },
    {
      expect = "(_G.adapter.get_current_node() or {}).path == _G.work .. '/lua/init.lua'",
      note = "and the cursor is where it was",
    },
    { keys = "!", note = "one view back from the first: the last one of the bar" },
    { wait = "_G.adapter.get_view() ~= 'files'", note = "another view is shown" },
    {
      expect = "#vim.api.nvim_buf_get_lines(_G.adapter.get_bufnr(), 0, -1, false) >= 1",
      note = "it has at least its head",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
    { lua = "_G.adapter.show_view('files')" },
    { wait = "_G.adapter.get_view() == 'files'" },
  },
  judge = {
    "In the snapshot the bar reads well at the width of the sidebar: the view on screen is marked, the others are cut in a way one can still tell them apart",
  },
  manual = {
    "In the real config: the view git in a real repository shows changed files in their groups, and a click on one opens it",
    "In the real config: the view symbols follows the cursor of the editor with a real language server",
    "Dragging the sidebar narrower and wider: the bar is cut and comes back without a wrap",
  },
}
