-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_drive_search_system_spec.lua -- the search and system features on the own tree, each
-- through its key on a real tree window: `find_files`, `grep_in_dir`, `live_search`, `spotlight_node`;
-- `open_in_fm`, `open_with`, `shell_run`, `file_clipboard`, `pdf_open`, `pdf_create`, `compress`,
-- `mdview_open`. What leaves the editor (another plugin, a program of the system) is a stand-in that
-- records what it was asked; what is checked is the node the feature took and what the tree shows
-- afterwards. `compress` runs the real archiver.
--
--   nvim --clean --headless -u NONE -l TESTS/native_drive_search_system_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

---What the stand-ins were asked, newest last.
local calls = {} ---@type { what: string, [string]: any }[]
local function called(what)
  for i = #calls, 1, -1 do
    if calls[i].what == what then return calls[i] end
  end
  return nil
end
local live_input ---@type table?  The options of the last `kit.live_input`.
local real_system, real_jobstart = vim.system, vim.fn.jobstart

local T = dofile(here .. "/native_drive.lua")({
  name = "native_drive_search_system_spec",
  files = {
    "lua/mod/a.lua",
    "lua/mod/b.lua",
    "lua/init.lua",
    "docs/guide.md",
    "docs/paper.pdf",
    "README.md",
  },
  before_setup = function()
    -- pickers.nvim's side of the bridge (`filetree.util.pickers`)
    package.loaded["pickers.integrations.filetree"] = {
      available = function()
        return true
      end,
      files = function(dir, o)
        calls[#calls + 1] = { what = "files", dir = dir, on_select = o and o.on_select }
        return true
      end,
      grep = function(dir, o)
        calls[#calls + 1] = { what = "grep", dir = dir, query = o and o.query }
        return true
      end,
    }
    package.loaded["spotlight"] = {
      add = function(token)
        calls[#calls + 1] = { what = "spotlight", token = token }
      end,
    }
    package.loaded["lib.nvim.cross.reveal_in_fm"] = function(target, o)
      calls[#calls + 1] = { what = "fm", target = target, opts = o }
      return true
    end
    package.loaded["lib.nvim.cross.open_default"] = function(path)
      calls[#calls + 1] = { what = "open_default", path = path }
      return true
    end
    require("filetree.features.system.file_clipboard.backend").copy = function(paths, on_done)
      calls[#calls + 1] = { what = "clipboard", paths = vim.deepcopy(paths) }
      on_done(true, nil, #paths, "")
    end
    require("filetree.util.pdf").open = function(path, o)
      calls[#calls + 1] = { what = "pdf_open", path = path, opts = o }
    end
    -- pdfport: writes the PDF next to its input, like the real one
    package.loaded["pdfport"] = {
      can_create = function()
        return true
      end,
      create = function(o)
        local out = o.inputs[1]:gsub("%.%w+$", "") .. ".pdf"
        vim.fn.writefile({ "%PDF-1.4" }, out)
        calls[#calls + 1] = { what = "pdf_create", input = o.inputs[1] }
        vim.schedule(function()
          o.__callback({ status = "ok", path = out })
        end)
      end,
    }
    package.loaded["mdview"] = {
      open = function()
        calls[#calls + 1] = { what = "mdview", file = vim.api.nvim_buf_get_name(0) }
      end,
    }
    require("ui.kit").live_input = function(o)
      live_input = o
    end
  end,
  -- Without the tree's own watcher: a file a feature creates shows up because it was announced.
  setup = { native = { watch = false } },
  features = {
    file_watcher = { enabled = false },
    open_with = {
      enabled = true,
      apps = { { name = "Probe", cmd = "ft-probe", args = { "-x" }, keymap = "gO" } },
    },
    pdf_create = { enabled = true, confirm = true },
  },
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir

-- ── find_files: f, tf ──────────────────────────────────────────────────────────
T.on("lua/mod/a.lua")
feed("f")
eq("f on a file searches the folder it lies in", T.norm(called("files").dir), dir .. "/lua/mod")
T.on("lua")
feed("f")
eq("f on a folder searches that folder", T.norm(called("files").dir), dir .. "/lua")
-- the picker reports the file it opened: the tree goes to it
called("files").on_select(dir .. "/lua/mod/b.lua")
T.wait(function()
  local node = T.adapter.get_current_node()
  return node ~= nil and T.norm(node.path) == dir .. "/lua/mod/b.lua"
end, 3000)
eq(
  "a file picked there is revealed in the tree",
  T.norm((T.adapter.get_current_node() or {}).path or ""),
  dir .. "/lua/mod/b.lua"
)
calls = {}
T.on("docs/guide.md")
feed("tf")
eq("tf does the same through pickers.nvim", T.norm(called("files").dir), dir .. "/docs")

-- ── grep_in_dir: gr, tg ────────────────────────────────────────────────────────
T.on("lua/init.lua")
feed("gr")
eq("gr on a file greps the folder it lies in", T.norm(called("grep").dir), dir .. "/lua")
calls = {}
T.on("docs")
feed("tg")
eq("tg on a folder greps that folder", T.norm(called("grep").dir), dir .. "/docs")

-- ── live_search: gs ────────────────────────────────────────────────────────────
T.on("lua/init.lua")
feed("gs")
ok("gs opens the input bar", live_input ~= nil)
local search_ns = vim.api.nvim_get_namespaces()["filetree_live_search"]
local function line_hl(rel)
  local line = T.adapter.get_node_line(dir .. "/" .. rel)
  local marks = vim.api.nvim_buf_get_extmarks(
    T.buf,
    search_ns,
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )
  return marks[1] and marks[1][4].line_hl_group or nil
end
live_input.on_change("init")
local match_hl, dim_hl = line_hl("lua/init.lua"), line_hl("README.md")
ok("typing marks the lines that match: " .. tostring(match_hl), match_hl ~= nil)
ok("... and dims the others: " .. tostring(dim_hl), dim_hl ~= nil and dim_hl ~= match_hl)
live_input.on_cancel()
eq(
  "leaving the bar clears the marks",
  #vim.api.nvim_buf_get_extmarks(T.buf, search_ns, 0, -1, {}),
  0
)
eq("... and the focus is back in the tree", vim.api.nvim_get_current_win(), T.adapter.get_winid())

-- ── spotlight_node: <leader>sp ─────────────────────────────────────────────────
T.on("lua/mod/a.lua")
feed("\\sp")
eq("<leader>sp spotlights the name of the node", called("spotlight").token, "a.lua")

-- ── open_in_fm: <leader>fm ─────────────────────────────────────────────────────
T.on("docs/guide.md")
feed("\\fm")
eq(
  "<leader>fm hands the node to the file manager",
  T.norm(called("fm").target),
  dir .. "/docs/guide.md"
)

-- ── open_with: <leader>sm, an app key, the list ────────────────────────────────
feed("\\sm")
eq(
  "<leader>sm opens the node with the system's default program",
  T.norm(called("open_default").path),
  dir .. "/docs/guide.md"
)
vim.system = function(cmd, o, on_exit)
  if cmd[1] ~= "ft-probe" then return real_system(cmd, o, on_exit) end
  calls[#calls + 1] = { what = "app", cmd = vim.deepcopy(cmd) }
  if on_exit then on_exit({ code = 0, stdout = "", stderr = "" }) end
  return {}
end
feed("gO")
eq(
  "the key of a configured app runs it on the node",
  { called("app").cmd[1], called("app").cmd[2], T.norm(called("app").cmd[3]) },
  { "ft-probe", "-x", dir .. "/docs/guide.md" }
)
calls = {}
T.answer("select", T.item("Probe"))
T.filetree.feature("open_with").pick()
eq(
  "the app list offers the system default and the configured apps",
  vim.tbl_map(function(app)
    return app.name
  end, T.asked[#T.asked].items),
  { "System default", "Probe" }
)
ok("... and runs the one that was picked", called("app") ~= nil)
vim.system = real_system

-- ── shell_run: i ───────────────────────────────────────────────────────────────
local windows_before = #vim.api.nvim_tabpage_list_wins(0)
local ran ---@type { cmd: any, cwd: string? }?
vim.fn.jobstart = function(cmd, o)
  ran = { cmd = cmd, cwd = o and o.cwd }
  return 1
end
T.on("lua/mod/a.lua")
T.answer("input", "echo hi")
feed("i")
vim.fn.jobstart = real_jobstart
eq("i runs the command that was typed", ran and ran.cmd, "echo hi")
eq("... in the folder of the node", ran and T.norm(ran.cwd), dir .. "/lua/mod")
eq("... in a split of its own", #vim.api.nvim_tabpage_list_wins(0), windows_before + 1)
ok("... which is not the tree window", vim.api.nvim_get_current_win() ~= T.adapter.get_winid())
vim.cmd("bwipeout!")

-- ── file_clipboard: gy ─────────────────────────────────────────────────────────
T.on("lua/mod/a.lua")
feed("gy")
eq(
  "gy copies the node as a file to the system clipboard",
  vim.tbl_map(T.norm, called("clipboard").paths),
  { dir .. "/lua/mod/a.lua" }
)
feed("m")
T.on("lua/mod/b.lua")
feed("m")
feed("gy")
local copied = vim.tbl_map(T.norm, called("clipboard").paths)
table.sort(copied)
eq("... with marks, the marked ones", copied, { dir .. "/lua/mod/a.lua", dir .. "/lua/mod/b.lua" })
T.filetree.feature("marks").clear_all()

-- ── pdf_open: go ───────────────────────────────────────────────────────────────
T.on("docs/paper.pdf")
feed("go")
eq("go opens the PDF under the cursor", T.norm(called("pdf_open").path), dir .. "/docs/paper.pdf")
calls = {}
local before = T.mark()
T.on("README.md")
feed("go")
eq("go on another file opens nothing", called("pdf_open"), nil)
ok("... and says so", T.told("No PDF under cursor", before))

-- ── pdf_create: gP ─────────────────────────────────────────────────────────────
T.on("docs/guide.md")
T.answer("confirm", true)
feed("gP")
T.wait(function()
  return T.shown("docs/guide.pdf")
end, 4000)
eq(
  "gP asks, then creates the PDF of the node",
  T.norm(called("pdf_create").input),
  dir .. "/docs/guide.md"
)
ok("... the tree shows the new file", T.shown("docs/guide.pdf"))

-- ── compress: gz ───────────────────────────────────────────────────────────────
if require("filetree.features.system.compress.archiver").detect() then
  T.on("lua/mod")
  before = T.mark()
  feed("gz")
  T.wait(function()
    return T.shown("lua/mod.zip")
  end, 20000)
  ok("gz writes a zip next to the node", T.exists("lua/mod.zip"))
  ok("... the tree shows it", T.shown("lua/mod.zip"))
  ok("... and the feature says what it made", T.told("mod.zip", before))
else
  T.na("compress: neither zip nor a bsdtar on this machine")
end

-- ── mdview_open: gM ────────────────────────────────────────────────────────────
T.on("docs/guide.md")
feed("gM")
eq(
  "gM opens the markdown file in the preview",
  T.norm(called("mdview").file),
  dir .. "/docs/guide.md"
)
eq(
  "... and the tree window still shows the tree",
  vim.api.nvim_win_get_buf(T.adapter.get_winid()),
  T.buf
)

eq("no prompt went unanswered", T.unanswered, 0)
eq("no warning or error in the whole run", T.loud(), { "[filetree.pdf_open] No PDF under cursor" })

T.finish()
