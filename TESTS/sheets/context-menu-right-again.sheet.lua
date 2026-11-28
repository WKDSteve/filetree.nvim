-- Feature sheet: the context menu of the own tree (features.context_menu, docs/FEATURES/UI.md "Context Menu").
-- Automated, in a child editor with a UI attached: right click on a node, <Esc>, right click on the same node
-- again opens the menu again. Neovim counts the second click as <2-RightMouse> when it lands on the same cell
-- within 'mousetime'; with only <RightMouse> mapped, Neovim took it itself and no menu came up. 'mousetime' is
-- set long here, so the second click is always a double click, however slow the machine.
return {
  id = "filetree.context-menu-right-again",
  title = "filetree.nvim: a quick second right click on a node (a double click) opens the context menu again",
  task = "lib.nvim/contextmenu-bind-buffer-a-quick-second-right-click",
  feature = "filetree.context-menu",
  engine = "rpc",
  sizes = { { rows = 30, cols = 100 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("IAF"); vim.o.swapfile = false; vim.g.have_nerd_font = false
      vim.o.mouse = "a"
      -- what lib.nvim.contextmenu.setup() sets: a click no map takes extends a selection instead of opening
      -- Neovim's own PopUp menu, which would block the child editor
      vim.o.mousemodel = "extend"
      vim.o.mousetime = 10000
      local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/rmenu_" .. vim.uv.hrtime()
      vim.fn.mkdir(work, "p")
      vim.fn.writefile({ "beta" }, work .. "/beta.txt")
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      require("filetree").setup({
        adapter = "native",
        native = { watch = false, width = 30 },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
        },
      })
      require("filetree").adapter().toggle_at("left", { dir = work })
      ---Right click on the first cell of beta.txt's name in the tree (grid 0, 0-based row and column).
      _G.right_click = function()
        vim.cmd.redraw()
        local adapter = require("filetree").adapter()
        local win, line = adapter.get_winid(), adapter.get_node_line(_G.work .. "/beta.txt")
        local pos = vim.fn.screenpos(win, line, 1)
        local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), line - 1, line, false)[1]
        local col = pos.col - 1 + vim.fn.strdisplaywidth(text:sub(1, (text:find("beta.txt", 1, true) or 1) - 1))
        vim.api.nvim_input_mouse("right", "press", "", 0, pos.row - 1, col)
        vim.api.nvim_input_mouse("right", "release", "", 0, pos.row - 1, col)
      end
      ---Whether `text` stands anywhere on the screen.
      _G.on_screen = function(text)
        vim.cmd.redraw()
        for r = 1, vim.o.lines do
          local row = {}
          for c = 1, vim.o.columns do
            row[#row + 1] = vim.fn.screenstring(r, c)
          end
          if table.concat(row):find(text, 1, true) then return true end
        end
        return false
      end]],
      note = "a project with beta.txt, the own tree open on the left, 'mousetime' 10 s",
    },
    { wait = [[_G.on_screen("beta.txt")]], timeout = 10000, note = "the tree shows beta.txt" },
    { lua = [[_G.right_click()]], note = "right click on beta.txt" },
    {
      wait = [[_G.on_screen("Create file / dir")]],
      timeout = 5000,
      note = "the context menu opens",
    },
    { input = "<Esc>", note = "close it with <Esc>" },
    { wait = [[not _G.on_screen("Create file / dir")]], timeout = 5000, note = "the menu is gone" },
    { lua = [[_G.right_click()]], note = "right click on beta.txt again (Neovim: <2-RightMouse>)" },
    {
      wait = [[_G.on_screen("Create file / dir")]],
      timeout = 5000,
      note = "the context menu opens again",
    },
    {
      expect = [[vim.api.nvim_get_mode().mode == "n"]],
      note = "no selection was started (mode n, not v)",
    },
    { input = "<Esc>", note = "close it" },
    { wait = [[not _G.on_screen("Create file / dir")]], timeout = 5000, note = "the menu is gone" },
  },
}
