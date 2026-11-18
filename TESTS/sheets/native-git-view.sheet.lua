-- Feature sheet: the view git of the own tree, its groups and staging from the tree (keys `"`, `ga`, `gu`).
-- Automated, in a child editor with a UI attached, git run for real: a repository with one commit, one
-- committed file changed and one new file. `"` goes from the files to the view git: the changed file
-- under "Changes", the new one under "Untracked". `ga` on the new file stages it (`git add`): it moves
-- to "Staged" and the index has it. `gu` takes it out again (`git reset`).
-- Left for a person: a real repository with conflicts and a long list, and `gd`/`gB` with gitsuite.nvim.
return {
  id = "filetree.native-git-view",
  title = "filetree.nvim: the view git of the own tree, staging and unstaging a file from it",
  feature = "filetree.native-git-view",
  engine = "rpc",
  sizes = { { rows = 20, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false; vim.o.cmdheight = 3',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/gitview_" .. vim.uv.hrtime() .. "/repo"
      vim.fn.mkdir(work .. "/src", "p")
      vim.fn.writefile({ "one" }, work .. "/src/kept.lua")
      vim.fn.writefile({ "readme" }, work .. "/README.md")
      ---Run git in the repository; raises when it fails.
      _G.git = function(...)
        local res = vim.system({ "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.test", "-c", "commit.gpgsign=false", ... }, { cwd = work, text = true }):wait()
        assert(res.code == 0, table.concat({ ... }, " ") .. ": " .. (res.stderr or ""))
        return res.stdout or ""
      end
      _G.git("init", "-q")
      _G.git("add", ".")
      _G.git("commit", "-q", "-m", "first")
      vim.fn.writefile({ "one", "two" }, work .. "/src/kept.lua")
      vim.fn.writefile({ "new" }, work .. "/src/fresh.lua")
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      ---The lines of the tree buffer, without leading blanks, joined by " | ".
      _G.rows = function()
        local out = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(_G.adapter.get_bufnr(), 0, -1, false)) do
          out[#out + 1] = vim.trim(line)
        end
        return table.concat(out, " | ")
      end
      ---The heading of the group a row lies in (the last line before it that starts with a letter group name).
      _G.group_of = function(name)
        local group
        for _, line in ipairs(vim.api.nvim_buf_get_lines(_G.adapter.get_bufnr(), 0, -1, false)) do
          for _, g in ipairs({ "Conflicts", "Staged", "Changes", "Untracked" }) do
            if line:find(g, 1, true) then group = g end
          end
          if line:find(name, 1, true) then return group end
        end
      end]],
      note = "a repository with one commit (the commit is the sheet's preparation); src/kept.lua changed, src/fresh.lua new",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false, views = { "files", "git" } },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          source_switcher = { enabled = true },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)]],
      note = "the own tree on the left with the views files and git",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_current_node() ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { keys = '"', note = "the next view: git" },
    { wait = "_G.adapter.get_view() == 'git'", note = "the view git is shown" },
    {
      wait = "_G.group_of('fresh.lua') == 'Untracked' and _G.group_of('kept.lua') == 'Changes'",
      timeout = 10000,
      note = "the new file under Untracked, the changed one under Changes",
    },
    {
      lua = [[local buf = _G.adapter.get_bufnr()
      for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("fresh.lua", 1, true) then vim.api.nvim_win_set_cursor(_G.win, { i, 0 }) end
      end]],
      note = "the cursor on fresh.lua",
    },
    { keys = "ga", note = "stage it" },
    {
      wait = "_G.group_of('fresh.lua') == 'Staged'",
      timeout = 10000,
      note = "it moves to Staged",
    },
    {
      expect = "_G.git('diff', '--cached', '--name-only'):find('src/fresh.lua', 1, true) ~= nil",
      note = "and the index has it",
    },
    {
      lua = [[local buf = _G.adapter.get_bufnr()
      for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("fresh.lua", 1, true) then vim.api.nvim_win_set_cursor(_G.win, { i, 0 }) end
      end]],
      note = "the cursor on fresh.lua again",
    },
    { keys = "gu", note = "take it out of the index" },
    {
      wait = "_G.rows():find('Staged', 1, true) == nil and _G.rows():find('Untracked', 1, true) ~= nil",
      timeout = 10000,
      note = "Staged is gone and Untracked is back",
    },
    {
      lua = [[local buf = _G.adapter.get_bufnr()
      for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find("Untracked", 1, true) then vim.api.nvim_win_set_cursor(_G.win, { i, 0 }) end
      end]],
      note = "the cursor on Untracked (it comes back closed: filetree.nvim/git-ansicht-wieder-erscheinende-gruppe-zugeklappt)",
    },
    { keys = "<CR>", note = "open the group" },
    {
      wait = "_G.group_of('fresh.lua') == 'Untracked'",
      timeout = 5000,
      note = "the file is untracked again",
    },
    {
      expect = "_G.git('diff', '--cached', '--name-only') == ''",
      note = "and the index is empty",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "A real repository with a merge conflict: the file is under Conflicts",
    "With gitsuite.nvim: gd shows the diff of the file, gB its blame",
  },
}
