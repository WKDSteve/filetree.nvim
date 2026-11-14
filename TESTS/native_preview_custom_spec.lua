-- Test code: when something here comes back nil this file must crash and name it.
---@diagnostic disable: need-check-nil, missing-fields, duplicate-set-field
-- TESTS/native_preview_custom_spec.lua -- a preview of the node's own on the own tree: a registered
-- previewer for files another plugin can draw (lines, an image, a note; answered at once or later),
-- and `preview(node, ctx)` of a source for a node that is no file. In the float and in the editor
-- window; an answer for a node the cursor has left is dropped, a previewer that raises is not asked
-- again, and a file nobody claims is previewed as always.
--
--   nvim --clean --headless -u NONE -l TESTS/native_preview_custom_spec.lua

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local T = dofile(here .. "/native_drive.lua")({
  name = "native_preview_custom_spec",
  setup = { native = { watch = false, views = { { "files" }, { "cases" } } } },
  features = {
    file_watcher = { enabled = false },
    preview = { enabled = true, mode = "float", cursor_debounce_ms = 10 },
  },
  files = { "clip.mp4", "song.wav", "pic.shot", "broken.boom", "lua/init.lua", "README.md" },
  before_setup = function(bench)
    -- a source whose nodes are no files: a failed case shows its output
    require("lib.nvim.tree.registry").source({
      name = "cases",
      root = function()
        return {
          id = "cases:root",
          label = "Cases",
          children = {
            { id = "case:red", label = "adds two numbers", kind = "case" },
            { id = "case:green", label = "subtracts", kind = "case" },
          },
        }
      end,
      preview = function(node, ctx)
        bench.source_ctx = ctx
        if node.id ~= "case:red" then return nil end
        return { lines = { "expected 4", "got 5" }, filetype = "diff", title = "adds two numbers" }
      end,
    })
  end,
})
local eq, ok, feed, dir = T.eq, T.ok, T.feed, T.dir
local adapter = T.adapter
local registry = require("lib.nvim.tree.registry")
local filetree = T.filetree
local preview = filetree.feature("preview")
local custom = require("filetree.features.ui.preview.custom")

if type(registry.previewer) ~= "function" then
  T.na("this lib.nvim has no registry.previewer yet")
  T.finish()
  return
end

-- the image viewer: what it was handed
local images_shown = {}
package.loaded["images"] = {
  show = function(path)
    images_shown[#images_shown + 1] = path
    return true
  end,
}

---The preview float: its lines and title, nil when there is none.
local function float()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" and win ~= adapter.get_winid() then
      local title = config.title
      if type(title) == "table" then
        title = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, title))
      end
      return {
        lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
        title = vim.trim(tostring(title or "")),
        filetype = vim.bo[vim.api.nvim_win_get_buf(win)].filetype,
      }
    end
  end
  return nil
end
local function tab()
  feed("<Tab>")
  T.settle(60)
end
local function move_to(rel)
  T.on(rel)
  T.settle(80)
end

-- ── a previewer ────────────────────────────────────────────────────────────────
local asked, cancelled, pending = {}, 0, nil
local remove = filetree.previewer({
  name = "spec_media",
  match = function(node)
    return type(node.path) == "string"
      and node.path:match("%.(%w+)$") ~= "lua"
      and node.path:match("%.md$") == nil
      and node.kind ~= "dir"
  end,
  preview = function(node, ctx, done)
    asked[#asked + 1] = { path = node.path, ctx = ctx }
    local ext = node.path:match("%.(%w+)$")
    if ext == "mp4" then
      done({ lines = { "frame 1 of 240", "00:00:10" }, title = "clip (frame)" })
    elseif ext == "shot" then
      done({ image = dir .. "/cache/pic.png", title = "pic" })
    elseif ext == "boom" then
      error("boom")
    else
      -- answered later, as a job would
      pending = done
      return function()
        cancelled = cancelled + 1
      end
    end
  end,
})
ok("previewer registered through require('filetree').previewer", #registry.list("previewer") == 1)

T.on("clip.mp4")
tab()
local f = float()
eq(
  "<Tab> on a file a previewer claims shows its lines",
  f and f.lines,
  { "frame 1 of 240", "00:00:10" }
)
eq("... under its title", f and f.title, "clip (frame)")
eq("the previewer was asked with the node", asked[1].path, dir .. "/clip.mp4")
eq("... and with what the preview is", {
  asked[1].ctx.mode,
  asked[1].ctx.trigger,
  asked[1].ctx.width,
  asked[1].ctx.height,
  asked[1].ctx.source,
}, { "float", "toggle", 80, 25, "files" })
eq("... in the context of the view", asked[1].ctx.root, dir)
tab()
eq("<Tab> on the same node takes it away", float(), nil)

-- a file nobody claims
T.on("README.md")
tab()
f = float()
ok("a file no previewer claims is previewed as always", f ~= nil and f.title == "README.md")
local before = #asked
move_to("clip.mp4")
f = float()
eq("the preview follows the cursor onto a claimed file", f and f.lines[1], "frame 1 of 240")
eq("... asked as a cursor move", asked[#asked].ctx.trigger, "cursor")
ok("... once", #asked == before + 1)
move_to("README.md")
f = float()
eq("... and back onto a plain file", f and f.title, "README.md")
preview.close()

-- an image
T.on("pic.shot")
tab()
eq("an image answer goes to the image viewer on <Tab>", images_shown, { dir .. "/cache/pic.png" })
eq("... and opens no text float", float(), nil)
T.on("README.md")
tab()
move_to("pic.shot")
f = float()
eq("while the cursor moves an image answer shows its title only", f and f.lines, { "pic" })
eq("... no second viewer", #images_shown, 1)
preview.close()

-- answered later
T.on("song.wav")
tab()
eq("a previewer that answers later shows nothing yet", float(), nil)
pending({ lines = { "▁▂▃▅▇▅▃▂▁" }, title = "song (waveform)" })
T.settle(60)
f = float()
eq("... and its answer when it comes", f and f.title, "song (waveform)")
preview.close()

T.on("song.wav")
tab()
local late = pending
move_to("README.md")
eq("leaving the node tells the previewer that nobody waits", cancelled >= 1, true)
late({ lines = { "too late" } })
T.settle(60)
f = float()
ok("an answer for a node the cursor has left is dropped", f == nil or f.lines[1] ~= "too late")
preview.close()

T.on("song.wav")
tab()
pending(nil, "ffmpeg not found")
T.settle(60)
f = float()
eq("done(nil, why) is one line in the preview", f and f.lines, { "ffmpeg not found" })
eq("... and no warning", T.loud(), {})
preview.close()

-- a previewer that raises
local mark = T.mark()
T.on("broken.boom")
tab()
T.settle(60)
ok(
  "a previewer that raises is named once",
  #T.loud(mark) == 1 and T.loud(mark)[1]:find("spec_media", 1, true) ~= nil
)
mark = T.mark()
preview.close()
T.on("clip.mp4")
tab()
f = float()
ok(
  "... and not asked again: the file is previewed as a file",
  f == nil or f.title ~= "clip (frame)"
)
eq("... without a second warning", T.loud(mark), {})
preview.close()
custom.reset()
T.on("clip.mp4")
tab()
eq("after a reset it is asked again", (float() or {}).title, "clip (frame)")
preview.close()

-- priority
local remove_high = filetree.previewer({
  name = "spec_high",
  priority = 10,
  match = function(node)
    return type(node.path) == "string" and node.path:match("%.mp4$") ~= nil
  end,
  preview = function(_, _, done)
    done({ note = "the higher one" })
  end,
})
T.on("clip.mp4")
tab()
eq("the previewer with the higher priority is asked", (float() or {}).lines, { "the higher one" })
preview.close()
eq("it unregisters", remove_high(), true)

-- ── a source ───────────────────────────────────────────────────────────────────
local view = adapter.get_state()
eq("the view of the source", { view:show("cases") }, { true })
T.settle(150)
local function on_label(label)
  T.tree()
  for i, text in ipairs(T.lines()) do
    if text:find(label, 1, true) then
      vim.api.nvim_win_set_cursor(adapter.get_winid(), { i, 0 })
      vim.cmd("doautocmd CursorMoved")
      T.settle(80)
      return true
    end
  end
  return false
end
ok("the cursor is on a node without a path", on_label("adds two numbers"))
tab()
f = float()
eq(
  "<Tab> on a node of a source shows what the source answers",
  f and f.lines,
  { "expected 4", "got 5" }
)
eq("... with its filetype", f and f.filetype, "diff")
eq("... and title", f and f.title, "adds two numbers")
eq(
  "the source was asked with its own name and the mode",
  { T.source_ctx.source, T.source_ctx.mode },
  { "cases", "float" }
)
ok("the cursor on a node the source has nothing for", on_label("subtracts"))
eq("... takes the preview of the node before away", float(), nil)
on_label("adds two numbers")
tab()
ok("(the preview is back on the red case)", float() ~= nil)
-- one line down without the cursor event: <Tab> itself has to see that the node is another one
vim.api.nvim_win_set_cursor(
  adapter.get_winid(),
  { vim.api.nvim_win_get_cursor(adapter.get_winid())[1] + 1, 0 }
)
mark = T.mark()
tab()
eq("<Tab> there closes the preview and shows nothing else", float(), nil)
eq("... without a warning", T.loud(mark), {})
preview.close()
view:show("files")
T.settle(100)

-- ── in the editor window ───────────────────────────────────────────────────────
preview.setup({ enabled = true, mode = "buffer", cursor_debounce_ms = 10 }, adapter)
local editor_buf = vim.api.nvim_win_get_buf(T.editor_win)
T.on("clip.mp4")
tab()
local shown = vim.api.nvim_win_get_buf(T.editor_win)
eq(
  "buffer mode: the lines stand in the editor window",
  vim.api.nvim_buf_get_lines(shown, 0, -1, false),
  { "frame 1 of 240", "00:00:10" }
)
ok("... in a scratch buffer, not a file", vim.bo[shown].buftype == "nofile" and shown ~= editor_buf)
eq("... asked with the mode", asked[#asked].ctx.mode, "buffer")
eq("... the tree keeps the focus", vim.api.nvim_get_current_win(), adapter.get_winid())
tab()
eq("<Tab> again puts the buffer back", vim.api.nvim_win_get_buf(T.editor_win), editor_buf)
ok("... and the scratch buffer is gone", not vim.api.nvim_buf_is_valid(shown))

eq("the previewer unregisters", remove(), true)
T.on("clip.mp4")
tab()
T.settle(60)
ok(
  "without a previewer the binary file is refused as before",
  vim.api.nvim_win_get_buf(T.editor_win) == editor_buf
)
preview.close()

T.finish()
