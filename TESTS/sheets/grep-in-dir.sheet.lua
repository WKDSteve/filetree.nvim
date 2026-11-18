-- Feature sheet: search the text of the files below the folder under the cursor (key `gr`).
-- Automated, in a child editor with a UI attached, without a picker plugin: the own tree on a project,
-- the cursor on a folder. `gr` asks for a pattern; the search runs in that folder only (ripgrep, or
-- grep where there is none, run for real) and its matches fill the quickfix list, one item per line
-- with its file and line, and the user is told how many. A file outside the folder is not searched.
-- A pattern nothing matches says so and leaves the list as it was.
-- Left for a person: the same key with a picker plugin installed (pickers.nvim, telescope, fzf-lua)
-- opens that one's live grep instead.
return {
  id = "filetree.grep-in-dir",
  title = "filetree.nvim: search the text of the files below the folder under the cursor",
  feature = "filetree.grep-in-dir",
  engine = "rpc",
  sizes = { { rows = 20, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false; vim.o.cmdheight = 3',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/grep_" .. vim.uv.hrtime() .. "/proj"
      local files = {
        ["src/a.lua"] = { "local needle_one = 1", "return needle_one" },
        ["src/sub/b.lua"] = { "-- nothing here", "print('needle_two')" },
        ["other/c.lua"] = { "needle_outside" },
      }
      for rel, lines in pairs(files) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile(lines, path)
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
      ---The quickfix items as "<file below the project>:<line>", sorted.
      _G.qf = function()
        local out = {}
        for _, item in ipairs(vim.fn.getqflist()) do
          local name = vim.fs.normalize(vim.api.nvim_buf_get_name(item.bufnr))
          out[#out + 1] = name:sub(#_G.work + 2) .. ":" .. item.lnum
        end
        table.sort(out)
        return table.concat(out, " ")
      end]],
      note = "a project: src/a.lua and src/sub/b.lua hold 'needle', other/c.lua too",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          grep_in_dir = { enabled = true },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/src"), 0 })]],
      note = "the own tree on the left, the cursor on the folder src",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_current_node() ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { input = "gr", note = "search in src (input: the prompt opens in insert mode)" },
    { wait = "vim.fn.mode() == 'i'", note = "the prompt takes a pattern" },
    { input = "needle\r", note = "search for 'needle'" },
    { wait = "_G.told('Found 3 match(es) in src')", timeout = 10000, note = "the user is told" },
    {
      expect = "_G.qf() == 'src/a.lua:1 src/a.lua:2 src/sub/b.lua:2'",
      note = "the matches below src are the quickfix list, other/c.lua is not",
    },
    {
      lua = "vim.api.nvim_set_current_win(_G.win); vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. '/src'), 0 })",
      note = "back in the tree on src",
    },
    { input = "gr", note = "search again" },
    { wait = "vim.fn.mode() == 'i'" },
    { input = "nowhere_to_be_found\r", note = "a pattern nothing matches" },
    {
      wait = "_G.told('No matches for: nowhere_to_be_found')",
      timeout = 10000,
      note = "it says so",
    },
    {
      expect = "_G.qf() == 'src/a.lua:1 src/a.lua:2 src/sub/b.lua:2'",
      note = "and the list is as it was",
    },
  },
  manual = {
    "With pickers.nvim, telescope or fzf-lua installed, gr opens that picker's live grep in the folder",
  },
}
