-- Feature sheet: move the node under the cursor, or the marked ones, to the system trash (`d`), and undo
-- the last one (`U`).
-- Automated, in a child editor with a UI attached, with recording stand-ins for the trash programs of
-- every system (PowerShell on Windows, gio or trash-put on Linux, trash or osascript on macOS), so no
-- file really goes anywhere: two files marked with `m`, `d` hands both to ONE call of the trash program
-- (the batch), then `d` on a third file alone hands that one over. On Windows `U` asks PowerShell to
-- restore it from the Recycle Bin. A stand-in moves nothing, so the files stay and the outcome said
-- differs by system (Windows and Linux read their program's answer, macOS and Linux check the file is
-- gone): the sheet checks what is CALLED, not what the system does.
-- Left for a person: the real trash of each system, the file in it and back after `U`
-- (TESTS/live/trash_*.lua, TESTS/MANUAL.md).
return {
  id = "filetree.trash",
  title = "filetree.nvim: move nodes to the system trash (one process for a marked batch) and undo",
  task = "filetree.nvim/abnahme-von-hand-prozess-features-papierkorb-dateimanager-sy",
  feature = "filetree.trash",
  engine = "rpc",
  sizes = { { rows = 16, cols = 80 } },
  fakes = { "powershell", "gio", "trash-put", "trash", "osascript" },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false; vim.o.cmdheight = 3',
      note = "no intro, no status line, no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/trash_" .. vim.uv.hrtime() .. "/proj"
      for _, rel in ipairs({ "old/first.log", "old/second.log", "old/third.log", "README.md" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "x" }, path)
      end
      vim.cmd.cd(vim.fn.fnameescape(work))
      _G.work = work
      -- recorded, not shown: the outcome reported for a stand-in differs by system, and a
      -- warning per file would stop the sheet at a hit-enter prompt
      _G.notes = {}
      vim.notify = function(msg)
        _G.notes[#_G.notes + 1] = tostring(msg)
      end
      ---Every call of a trash stand-in, in order, with its arguments joined.
      _G.calls = function()
        local out = {}
        for _, call in ipairs(require("testing.fake_programs").read(vim.env.TESTING_FAKES)) do
          out[#out + 1] = { program = call.program, args = table.concat(call.argv, " ") }
        end
        return out
      end
      ---The stand-in the trash of this system goes to.
      _G.program = vim.fn.has("win32") == 1 and "powershell" or vim.fn.has("mac") == 1 and "trash" or "gio"
      ---Put the cursor on a row of the tree.
      _G.cursor_on = function(rel)
        vim.api.nvim_win_set_cursor(_G.win, { _G.adapter.get_node_line(_G.work .. "/" .. rel), 0 })
      end]],
      note = "a project with three log files in old/; what is said and what the trash programs get is recorded",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          marks = { enabled = true },
          trash = { enabled = true, confirm = false },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/old" })]],
      note = "the own tree on the left with old/ open; trash without the question (confirm = false)",
    },
    {
      wait = "vim.api.nvim_get_current_win() == _G.win and _G.adapter.get_node_line(_G.work .. '/old/third.log') ~= nil",
      note = "the tree is drawn, the cursor in it",
    },
    { lua = "_G.cursor_on('old/first.log')" },
    { keys = "m", note = "mark first.log" },
    { lua = "_G.cursor_on('old/second.log')" },
    { keys = "m", note = "mark second.log" },
    {
      expect = "require('filetree.features.org.marks').count() == 2",
      note = "two nodes are marked",
    },
    { keys = "d", note = "trash the marked nodes" },
    { wait = "#_G.calls() >= 1", timeout = 10000, note = "the trash program is started" },
    {
      wait = "table.concat(_G.notes, ' '):find('/2 to trash', 1, true) ~= nil",
      timeout = 10000,
      note = "the outcome of the batch is said (moved n/2)",
    },
    {
      expect = "#_G.calls() == 1 and _G.calls()[1].program == _G.program",
      note = "once, for both files: the system's trash program",
    },
    {
      expect = "_G.calls()[1].args:find('first.log', 1, true) ~= nil and _G.calls()[1].args:find('second.log', 1, true) ~= nil",
      note = "with both files",
    },
    { lua = "require('filetree.features.org.marks').clear_all(); _G.cursor_on('old/third.log')" },
    { keys = "d", note = "trash third.log alone" },
    { wait = "#_G.calls() >= 2", timeout = 10000, note = "the trash program is started again" },
    {
      expect = "_G.calls()[2].program == _G.program and _G.calls()[2].args:find('third.log', 1, true) ~= nil",
      note = "with third.log",
    },
    {
      wait = "table.concat(_G.notes, ' '):find('/1 to trash', 1, true) ~= nil",
      timeout = 10000,
      note = "the outcome is said (moved n/1)",
    },
    { lua = "_G.before_undo = #_G.notes" },
    { keys = "U", note = "undo the last trash" },
    {
      wait = "#_G.notes > _G.before_undo",
      timeout = 10000,
      note = "U says how the restore went (on Windows PowerShell was asked to bring third.log back from the Recycle Bin; its script holds & and |, which a .cmd stand-in cannot record)",
    },
    { expect = "vim.v.errmsg == ''", note = "and nothing raised" },
  },
  manual = {
    "On each system with its real trash: d moves the file there, U brings it back to where it was",
    "A marked batch of many files on Windows is one PowerShell start, not one per file (the tree stays responsive)",
  },
}
