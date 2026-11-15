-- Feature sheet: the history of roots of the own tree and "expand all" (docs/FEATURES/BACKENDS.md,
-- keys `-`, `<BS>`, `g<BS>`, `E`).
-- Automated, in a child editor with a UI attached: the tree is opened on a folder two levels down.
-- `-` shows the parent as the root, twice. `<BS>` goes back through the roots shown before, with the
-- cursor on the folder it came from; at the start of the history it says so. `g<BS>` goes forward
-- again. `E` on a folder opens everything below it and says how many folders it opened; with a cap
-- of two it stops and says how many it left closed.
-- Left for a person: whether the keys are where the hand expects them.
return {
  id = "filetree.native-root-history",
  title = "filetree.nvim: back and forward through the roots of the own tree, and expand all",
  task = "filetree.nvim/abnahme-own-tree-pinned-folders-history-helper",
  feature = "filetree.native-root-history",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false',
      note = "no intro, no status line (it would name the temporary path), no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/roots_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "a/one/x.lua", "a/two/deep/y.lua", "a/two/deep/er/z.lua", "a/two/t.lua", "b/three/w.lua", "README.md" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "x" }, path)
      end
      vim.cmd.cd(vim.fn.fnameescape(work))
      vim.cmd.edit(vim.fn.fnameescape(work .. "/README.md"))
      _G.work = work
      _G.notes = {}
      local real_notify = vim.notify
      vim.notify = function(msg, level, opts)
        _G.notes[#_G.notes + 1] = tostring(msg)
        return real_notify(msg, level, opts)
      end
      ---Was something that holds `text` said since `from` notes?
      _G.told = function(text, from)
        for i = (from or 0) + 1, #_G.notes do
          if _G.notes[i]:find(text, 1, true) then return true end
        end
        return false
      end]],
      note = "a project: a/one, a/two/deep/er, b/three; what is said is recorded",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false, expand_all_max = 200 },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work .. "/a/two" })
      _G.view = _G.adapter.get_state()
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.root = function() return (_G.view.root:gsub("^" .. vim.pesc(_G.work), "")) end
      _G.on = function() return ((_G.adapter.get_current_node() or {}).path or ""):gsub("^" .. vim.pesc(_G.work), "") end
      _G.put = function(rel)
        vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. rel), 0 })
        vim.cmd("doautocmd CursorMoved")
      end]],
      note = "the own tree on a/two, focused",
    },
    { settle = 3000, note = "what the features started after the open has run" },
    { expect = "_G.root() == '/a/two'", note = "the tree shows a/two" },
    { keys = "<BS>", note = "back with no history" },
    { wait = "_G.told('no root to go back to')", note = "it says that there is none" },
    { keys = "-", note = "the parent as the root" },
    { wait = "_G.root() == '/a'", note = "the root is a" },
    { keys = "-" },
    { wait = "_G.root() == ''", note = "the root is the project" },
    { screen = "project", note = "the project as the root" },
    { keys = "<BS>", note = "back" },
    { wait = "_G.root() == '/a'", note = "back to a" },
    { keys = "<BS>" },
    { wait = "_G.root() == '/a/two'", note = "back to a/two" },
    { keys = "g<BS>", note = "forward" },
    { wait = "_G.root() == '/a'", note = "forward to a" },
    { expect = "_G.on() == '/a/two'", note = "the cursor is on the folder it came from" },
    { keys = "g<BS>" },
    { wait = "_G.root() == ''", note = "forward to the project" },
    { lua = "_G.mark = #_G.notes" },
    { keys = "g<BS>", note = "forward at the end of the history" },
    { wait = "_G.told('no root to go forward to', _G.mark)", note = "it says that there is none" },
    { lua = "_G.put('/a'); _G.mark = #_G.notes", note = "the cursor on the folder a" },
    { keys = "E", note = "expand all below a" },
    {
      wait = "_G.adapter.get_node_line(_G.work .. '/a/two/deep/er/z.lua') ~= nil",
      note = "every level below a is open",
    },
    {
      expect = "_G.adapter.get_node_line(_G.work .. '/b/three') == nil",
      note = "nothing next to it",
    },
    {
      wait = "_G.told('opened 5 folder(s)', _G.mark)",
      note = "it says how many folders it opened",
    },
    { screen = "expanded", note = "a with everything below it open, b closed" },
    {
      lua = [[_G.adapter.collapse_all()
      _G.put('/a')
      _G.opened, _G.left = _G.view:expand_all(_G.work .. '/a', 2)]],
      note = "again with a cap of two",
    },
    {
      expect = "_G.opened == 2 and _G.left >= 1",
      note = "two opened, and it counts what it left closed",
    },
  },
  manual = {
    "In daily use: <BS> and g<BS> are where the hand expects back and forward, and E on a large folder is not a surprise",
  },
}
