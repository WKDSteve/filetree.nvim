-- Feature sheet: the marker of the active buffer in the own tree (features.current_hl.icon,
-- docs/FEATURES/UI.md "Current Highlight").
-- Automated, in a child editor with a UI attached, reading the cells the screen really shows: the marker
-- stands in the last cell of the row's indent, one cell right of the parent folder's expander and never
-- under it; a wide marker ends in that cell instead of starting there, so the row's own expander stays
-- free; `icon = ""` draws no marker at all.
-- Left for a person: whether the marker reads well in the font of the real terminal.
return {
  id = "filetree.native-current-marker",
  title = "filetree.nvim: the marker of the active buffer stands one level in, not under the parent's arrow",
  task = "filetree.nvim/abnahme-native-current-marker",
  feature = "filetree.native-current-marker",
  engine = "rpc",
  sizes = { { rows = 12, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line, no Nerd Font (the icons are plain text)",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/marker_" .. vim.uv.hrtime() .. "/proj"
      vim.fn.mkdir(work .. "/docs", "p")
      vim.fn.writefile({ "x" }, work .. "/docs/guide.md")
      vim.fn.writefile({ "# Readme" }, work .. "/README.md")
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      ---Open the own tree with this marker, show docs/guide.md as the active buffer.
      _G.open = function(icon)
        pcall(function() require("filetree").adapter().close() end)
        require("filetree.native").reset()
        require("filetree").setup({
          adapter = "native",
          native = { watch = false, width = 30 },
          features = {
            file_watcher = { enabled = false },
            auto_reveal = { enabled = false },
            git_status = { enabled = false },
            current_hl = { enabled = true, debounce_ms = 10, icon = icon },
          },
        })
        vim.cmd.edit(vim.fn.fnameescape(work .. "/docs/guide.md"))
        local file_win = vim.api.nvim_get_current_win()
        local adapter = require("filetree").adapter()
        adapter.toggle_at("left", { dir = work })
        adapter.expand_node({ path = work .. "/docs" })
        vim.api.nvim_set_current_win(file_win)
        vim.cmd.doautocmd("BufEnter")
      end
      ---The cells the screen shows on the tree row of `path`, one string per cell (a wide glyph
      ---fills its first cell, the next one is "").
      _G.cells = function(path)
        vim.cmd.redraw()
        local adapter = require("filetree").adapter()
        local win, line = adapter.get_winid(), adapter.get_node_line(path)
        if not win or not line then return {} end
        local pos = vim.fn.screenpos(win, line, 1)
        if not pos.col or pos.col == 0 then return {} end
        local out = {}
        for c = 0, 9 do
          out[#out + 1] = vim.fn.screenstring(pos.row, pos.col + c)
        end
        return out
      end
      ---The first cell (1-based) of `path`'s row that shows `text`, nil when none does.
      _G.cell_of = function(path, text)
        for i, s in ipairs(_G.cells(path)) do
          if s == text then return i end
        end
      end]],
      note = "a project with docs/guide.md; helpers to open the tree and to read the cells of a row",
    },
    { lua = '_G.open(">")', note = "marker > on the active buffer docs/guide.md" },
    { settle = 1500, note = "the debounced current_hl has drawn" },
    {
      expect = "#_G.cells(_G.work .. '/docs/guide.md') > 0 and #_G.cells(_G.work .. '/docs') > 0",
      note = "the tree is on screen and shows both rows",
    },
    {
      expect = "_G.cell_of(_G.work .. '/docs/guide.md', '>') ~= nil",
      note = "the row of the active buffer shows the marker",
    },
    {
      expect = "_G.cell_of(_G.work .. '/docs/guide.md', '>') == _G.cell_of(_G.work .. '/docs', '▾') + 1",
      note = "one cell right of the parent folder's expander, not under it",
    },
    {
      expect = "_G.cells(_G.work .. '/docs/guide.md')[_G.cell_of(_G.work .. '/docs/guide.md', '>') + 1] == ' '",
      note = "right before the row's own (blank) expander",
    },
    { lua = '_G.open("中")', note = "a wide marker (two cells)" },
    { settle = 1500 },
    {
      expect = "_G.cell_of(_G.work .. '/docs/guide.md', '中') == _G.cell_of(_G.work .. '/docs', '▾')",
      note = "it ends in the last indent cell: it starts one cell earlier",
    },
    { lua = '_G.open("")', note = "icon switched off" },
    { settle = 1500 },
    {
      expect = "_G.cell_of(_G.work .. '/docs/guide.md', '>') == nil and _G.cell_of(_G.work .. '/docs/guide.md', '中') == nil",
      note = "no marker is drawn",
    },
  },
  manual = {
    "In your real terminal and font, with `features.current_hl.icon` set: the marker of the active file stands one level in from the parent folder's arrow (not in the same column), and a folder's arrow next to a marked row stays visible",
    "Optional: set `icon` to an emoji you like and check it neither covers the row's arrow nor the icon after it",
  },
}
