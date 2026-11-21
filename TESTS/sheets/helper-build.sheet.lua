-- Feature sheet: `:Filetree helper build` puts the helper program in place in the background.
-- Automated, in a child editor with a UI attached, with recording stand-ins for cargo and curl (no
-- real build, no network). The command starts cargo by its bare name without a shell and the editor
-- does not wait for it (testing perf: no freeze); when cargo ends, the program built into
-- $CARGO_TARGET_DIR is copied below stdpath("data") (the sandbox's) and the user is told where.
-- `download` asks curl for the release asset instead. A cancel with no build running says so.
-- Left for a person: a real first cargo build (minutes) with the progress indicator, and cancelling it.
return {
  id = "filetree.helper-build",
  title = "filetree.nvim: :Filetree helper build in the background",
  feature = "filetree.helper-build",
  engine = "rpc",
  fakes = { "cargo", "curl" },
  sizes = { { rows = 16, cols = 160 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.o.cmdheight = 4',
      note = "no intro, no status line, room for the messages (no hit-enter prompt)",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.fn.tempname()) .. "_helper_build"
      local helper = require("filetree.native.fs.helper")
      _G.built = work .. "/target/release/" .. helper.binary_name()
      vim.fn.mkdir(vim.fs.dirname(_G.built), "p")
      vim.fn.writefile({ "the built program" }, _G.built)
      vim.env.CARGO_TARGET_DIR = work .. "/target"
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
      _G.calls = function(program)
        return require("testing.fake_programs").read(vim.env.TESTING_FAKES, program)
      end]],
      note = "what cargo would build lies in $CARGO_TARGET_DIR; what is said is recorded",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        progress_style = "statusline",
        native = { watch = false },
        features = { file_watcher = { enabled = false }, auto_reveal = { enabled = false }, git_status = { enabled = false } },
      })]],
      note = "filetree set up (the :Filetree command), its progress in the status line, not as messages",
    },
    { keys = ":Filetree helper build<CR>", note = "build the helper" },
    {
      wait = "_G.told('filetree-helper installed')",
      timeout = 10000,
      note = "the build ends and the user is told",
    },
    {
      expect = "#_G.calls('cargo') == 1 and vim.tbl_contains(_G.calls('cargo')[1].argv, '--release')",
      note = "cargo build --release ran once, by its bare name",
    },
    {
      expect = "vim.fn.readfile(require('filetree.native.fs.helper').default_path())[1] == 'the built program'",
      note = "the program is in place below stdpath('data')",
    },
    {
      expect = "not require('filetree.native.fs.helper').building()",
      note = "and no build is left running",
    },
    { keys = ":Filetree helper cancel<CR>", note = "cancel with nothing running" },
    { wait = "_G.told('no build is running')", note = "says there is none" },
    { keys = ":Filetree helper build download<CR>", note = "download instead of building" },
    {
      wait = "#_G.calls('curl') == 1 and not require('filetree.native.fs.helper').building()",
      timeout = 10000,
      note = "curl was asked once and the build is over",
    },
    {
      expect = "_G.calls('curl')[1].argv[#_G.calls('curl')[1].argv]:find('/releases/latest/download/filetree%-helper%-') ~= nil",
      note = "for the release asset of this system",
    },
    { expect = "#_G.calls('cargo') == 1", note = "and cargo was not started again" },
  },
  manual = {
    "A real first build (cargo, minutes): the editor stays usable, the progress indicator shows it, the tree lists meanwhile",
    ":Filetree helper cancel during that build: cargo stops, 'build cancelled' is said, the old program stays",
  },
}
