-- Feature sheet: words to actions of the own tree (`native.ai`, docs/FEATURES/AI.md).
-- Automated, in a child editor with a UI attached. ai.nvim is a stand-in here (no model, no network):
-- the next answer comes from a queue and every request is kept. `:Filetree ask open init as a
-- vsplit` runs the action the answer names, without a question, because it changes no file. `:Filetree
-- ask trash the guide` asks first and names the file; No leaves it where it is, Yes sends it to the
-- trash (a folder next to the project here). An answer that names an action there is not is refused
-- in one line, and nothing runs. What is sent to the model holds names and paths, never what is in a
-- file.
-- Left for a person: a real provider (the live part of the hand test) and the microphone.
return {
  id = "filetree.native-ai",
  title = "filetree.nvim: :Filetree ask turns a sentence into actions of the tree, and asks before it changes a file",
  task = "filetree.nvim/abnahme-own-tree-pinned-folders-history-helper",
  feature = "filetree.native-ai",
  engine = "rpc",
  sizes = { { rows = 20, cols = 90 } },
  steps = {
    {
      lua = 'vim.opt.shortmess:append("IAF"); vim.o.laststatus = 0; vim.o.ruler = false; vim.o.showmode = false; vim.o.swapfile = false; vim.g.have_nerd_font = false; vim.o.cmdheight = 2',
      note = "no intro, no status line (it would name the temporary path), no icon font",
    },
    {
      lua = [[local work = vim.fs.normalize(vim.uv.fs_realpath(vim.fs.dirname(vim.fn.tempname()))) .. "/ai_" .. vim.uv.hrtime() .. "/proj"
      for rel, text in pairs({ ["lua/init.lua"] = "return 1", ["docs/guide.md"] = "SECRET_CONTENT_42", ["README.md"] = "# Readme" }) do
        local path = work .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ text }, path)
      end
      vim.cmd.cd(vim.fn.fnameescape(work))
      vim.cmd.edit(vim.fn.fnameescape(work .. "/README.md"))
      _G.work = work
      -- ai.nvim, a stand-in: the next answer comes from a queue, every request is kept
      _G.requests, _G.answers = {}, {}
      package.loaded["ai"] = {
        ask = function(req, cb)
          _G.requests[#_G.requests + 1] = req
          cb(true, { text = table.remove(_G.answers, 1) or "[]", provider = "stand-in" })
        end,
        policy = function()
          return { allowed = nil, restricted = false, granted = {}, bulk_granted = {} }
        end,
      }
      -- the trash of the system, replaced by a folder next to the project
      _G.bin = work .. "_bin"
      vim.fn.mkdir(_G.bin, "p")
      local platform = require("filetree.features.fileops.trash.platform")
      local function send(path)
        local moved = vim.uv.fs_rename(path, _G.bin .. "/" .. vim.fn.fnamemodify(path, ":t"))
        return { ok = moved == true, err = moved and nil or "could not move" }
      end
      platform.available = function() return true end
      platform.send = function(path, cb) vim.schedule(function() cb(send(path)) end) end
      platform.send_batch = function(paths, cb) vim.schedule(function() cb(vim.tbl_map(send, paths)) end) end
      _G.notes = {}
      local real_notify = vim.notify
      vim.notify = function(msg, level, opts)
        _G.notes[#_G.notes + 1] = tostring(msg)
        return real_notify(msg, level, opts)
      end
      _G.told = function(text, from)
        for i = (from or 0) + 1, #_G.notes do
          if _G.notes[i]:find(text, 1, true) then return true end
        end
        return false
      end
      _G.floats = function()
        return #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
      end]],
      note = "a project; ai.nvim and the trash are stand-ins; what is said is recorded",
    },
    {
      lua = [[require("filetree").setup({
        adapter = "native",
        native = { watch = false, group_empty_dirs = false, ai = { enabled = true } },
        features = {
          file_watcher = { enabled = false },
          auto_reveal = { enabled = false },
          git_status = { enabled = false },
          open_variants = { enabled = true },
          trash = { enabled = true, confirm = false },
          cwd_mode = { persist = false },
          -- the tree stays while a file is opened: the sheet goes on in it
          close_on_open = { enabled = false },
        },
      })
      _G.adapter = require("filetree").adapter()
      _G.adapter.toggle_at("left", { dir = _G.work })
      _G.win = _G.adapter.get_winid()
      vim.api.nvim_set_current_win(_G.win)
      _G.adapter.expand_node({ path = _G.work .. "/lua" })
      _G.adapter.expand_node({ path = _G.work .. "/docs" })]],
      note = "the own tree with native.ai on, the folders open",
    },
    { settle = 3000, note = "what the features started after the open has run" },
    {
      lua = [[_G.answers[1] = '[{"action": "open_variants.vsplit", "target": "init"}]'
      _G.wins_before = #vim.api.nvim_list_wins()]],
      note = "the model will answer: open init in a vertical split",
    },
    { input = ":Filetree ask open init as a vsplit<CR>" },
    {
      wait = "#vim.api.nvim_list_wins() == _G.wins_before + 1 and _G.floats() == 0",
      note = "a split more, and no question: it changes no file",
    },
    {
      expect = "vim.tbl_contains(vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):gsub('\\\\', '/') end, vim.api.nvim_list_wins()), _G.work .. '/lua/init.lua')",
      note = "lua/init.lua is shown in it",
    },
    {
      expect = "not vim.inspect(_G.requests):find('SECRET_CONTENT_42', 1, true) and vim.inspect(_G.requests):find('guide.md', 1, true) ~= nil",
      note = "the model got names and paths, not what is in a file",
    },
    {
      lua = [[vim.api.nvim_set_current_win(_G.win)
      _G.answers[1] = '[{"action": "trash.trash", "target": "docs/guide.md"}]']],
      note = "the model will answer: trash docs/guide.md",
    },
    { input = ":Filetree ask trash the guide<CR>" },
    { wait = "_G.floats() >= 1", note = "it asks first" },
    { screen = "question", note = "the question names the file", masks = { { row = 1 } } },
    { input = "<Esc>", note = "No" },
    { wait = "_G.floats() == 0" },
    {
      expect = "vim.uv.fs_stat(_G.work .. '/docs/guide.md') ~= nil",
      note = "No: the file is where it was",
    },
    {
      lua = [[vim.api.nvim_set_current_win(_G.win)
      _G.answers[1] = '[{"action": "trash.trash", "target": "docs/guide.md"}]']],
    },
    { input = ":Filetree ask trash the guide<CR>" },
    { wait = "_G.floats() >= 1", note = "it asks again" },
    {
      lua = [[-- Yes: the button is found by its text, whichever one has the focus
      local win = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())[1]
      _G.dialog_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")]],
    },
    {
      expect = "_G.dialog_text:find('guide.md', 1, true) ~= nil",
      note = "the question names the file",
    },
    { input = "y", note = "Yes" },
    {
      wait = "vim.uv.fs_stat(_G.work .. '/docs/guide.md') == nil and vim.uv.fs_stat(_G.bin .. '/guide.md') ~= nil",
      note = "Yes: the file is in the trash",
      timeout = 4000,
    },
    {
      lua = [[vim.api.nvim_set_current_win(_G.win)
      _G.mark = #_G.notes
      _G.answers[1] = '[{"action": "os.execute", "target": "README.md"}]']],
      note = "the model will answer with an action there is not",
    },
    { input = ":Filetree ask do something clever<CR>" },
    { wait = "#_G.notes > _G.mark", note = "it says something" },
    {
      expect = "vim.uv.fs_stat(_G.work .. '/README.md') ~= nil and _G.floats() == 0",
      note = "and nothing ran",
    },
  },
  judge = {
    "In the snapshot the question reads clearly: what will happen, to which file, and which button is the safe one",
  },
  manual = {
    "With a real provider (ollama, and one in the cloud): a sentence of your own is understood, and the time from <CR> to the action is acceptable",
    "With a real microphone: the button in the view bar records, stops at a pause and runs what was said",
  },
}
