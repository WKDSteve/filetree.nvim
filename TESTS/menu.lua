-- menu.lua — headless unit tests for filetree.nvim's nvzone/menu integration.
--
-- Complements TESTS/smoke.lua and TESTS/units.lua. Exercises
-- filetree.integrations.menu, which is a soft, opt-in layer: it reads
-- require("filetree").feature(name) and require("filetree").config().menu, so
-- it can be tested without a real adapter/tree window by stubbing the
-- top-level "filetree" module — exactly the seam a host (RightMouse
-- dispatcher) uses, so this is de-facto coverage of the real contract.
--
-- Usage (from the repo root):
--   nvim --clean --headless -u NONE -l TESTS/menu.lua
--
-- Exit 0 = all passed, 1 = a check failed.

-- ── Locate the repo root relative to this file, put it (and lib.nvim) on rtp ──
-- See TESTS/smoke.lua for why this block exists: filetree.integrations.menu
-- now requires lib.nvim.ui.nerd_font (icon glyphs), so this suite needs
-- lib.nvim findable too, same as smoke.lua/units.lua already do.
local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.rtp:prepend(root)
local lib_candidates = {}
for _, env in ipairs({ "FILETREE_LIB_NVIM", "LIB_NVIM_PATH" }) do
  local v = vim.env[env]
  if v and v ~= "" then lib_candidates[#lib_candidates + 1] = v end
end
lib_candidates[#lib_candidates + 1] = vim.fn.fnamemodify(root, ":h") .. "/lib.nvim"
lib_candidates[#lib_candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"
for _, candidate in ipairs(lib_candidates) do
  if vim.fn.isdirectory(candidate .. "/lua/lib") == 1 then
    vim.opt.rtp:prepend(candidate)
    break
  end
end

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  — " .. detail) or ""))
  end
end
local function eq(name, got, want)
  check(name, got == want, ("got %q want %q"):format(tostring(got), tostring(want)))
end

-- ── stub helpers ────────────────────────────────────────────────────────────

local function stub_action(name, fns)
  local calls = {}
  local t = {}
  for _, fn in ipairs(fns) do
    t[fn] = function()
      calls[#calls + 1] = name .. "." .. fn
    end
  end
  return t, calls
end

local function install_stub(menu_cfg, present_features, adapter)
  package.loaded["filetree"] = {
    feature = function(n)
      return present_features[n]
    end,
    config = function()
      return { menu = menu_cfg }
    end,
    adapter = function()
      return adapter
    end,
  }
  package.loaded["filetree.integrations.menu"] = nil
  return require("filetree.integrations.menu")
end

local function names(items)
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = it.name
  end
  return out
end
local function has(list, needle)
  for _, x in ipairs(list) do
    if x == needle then return true end
  end
  return false
end

-- ── Full menu: every group present; a disabled feature omits its entry ──────
do
  local create_calls
  local features = {}
  features.smart_create, create_calls = stub_action("smart_create", { "create" })
  features.smart_rename = (stub_action("smart_rename", { "rename_current" }))
  features.rename_batch = (stub_action("rename_batch", { "open" }))
  -- create_from_template intentionally omitted -> its entry must not appear.
  features.copy_move = (stub_action("copy_move", { "stage_copy", "stage_cut", "paste" }))
  features.file_clipboard = (stub_action("file_clipboard", { "copy" }))
  features.trash = (stub_action("trash", { "delete_current" }))
  features.open_variants = (
    stub_action("open_variants", { "open_vsplit", "open_split", "open_tabnew" })
  )
  features.open_with = (stub_action("open_with", { "open_system" }))
  features.open_in_fm = (stub_action("open_in_fm", { "open" }))
  features.path_copy = (stub_action("path_copy", { "pick" }))
  features.markdown_links = (stub_action("markdown_links", { "link_current" }))
  features.find_files = (stub_action("find_files", { "find" }))
  features.grep_in_dir = (stub_action("grep_in_dir", { "grep" }))
  features.node_info = (stub_action("node_info", { "show_current" }))

  local menu = install_stub({ enable = true }, features)
  local items = menu.items()
  local list = names(items)

  check("menu: create entry present (feature enabled)", has(list, "Create file / dir"))
  check("menu: trash entry present", has(list, "Trash"))
  check("menu: system-clipboard entry present", has(list, "Copy to system clipboard"))
  check("menu: path_copy entry present", has(list, "Copy path…"))
  check("menu: node_info entry present", has(list, "Node info"))
  check("menu: Inspect entry present (not feature-gated)", has(list, "Inspect"))
  check(
    "menu: entry omitted when its feature is disabled/absent",
    not has(list, "New from template")
  )

  check("menu: does not start with a separator", items[1] and items[1].name ~= "separator")
  check("menu: does not end with a separator", items[#items] and items[#items].name ~= "separator")

  -- Every real row carries an icon (separators/headings don't need one).
  local missing_icon
  for _, it in ipairs(items) do
    if it.name ~= "separator" and not it.__heading and (it.icon == nil or it.icon == "") then
      missing_icon = it.name
      break
    end
  end
  check("menu: every entry has an icon", missing_icon == nil, tostring(missing_icon))

  items[1].cmd()
  eq("menu entry cmd() invokes the underlying feature function (count)", #create_calls, 1)
  eq("menu entry cmd() calls the right feature.function", create_calls[1], "smart_create.create")

  -- Group-level opt-out: disabling clipboard + search removes exactly those.
  local menu2 = install_stub({ enable = true, clipboard = false, search = false }, features)
  local list2 = names(menu2.items())
  check("menu opt-out: clipboard=false hides the copy entry", not has(list2, "Copy"))
  check(
    "menu opt-out: clipboard=false hides the system-clipboard entry too",
    not has(list2, "Copy to system clipboard")
  )
  check("menu opt-out: search=false hides find_files", not has(list2, "Find files"))
  check("menu opt-out: unrelated groups (delete) stay", has(list2, "Trash"))

  -- info=false hides both node_info AND Inspect — the latter isn't gated by
  -- its own feature (there is none), only by the group.
  local menu_no_info = install_stub({ enable = true, info = false }, features)
  local list_no_info = names(menu_no_info.items())
  check("menu opt-out: info=false hides node_info", not has(list_no_info, "Node info"))
  check("menu opt-out: info=false hides Inspect too", not has(list_no_info, "Inspect"))

  -- Master switch: enable=false yields nothing at all.
  local menu3 = install_stub({ enable = false }, features)
  eq("menu master switch: enable=false yields zero entries", #menu3.items(), 0)

  -- submenu() wraps the same entries as a single fly-out; nil when empty.
  local menu4 = install_stub({ enable = true }, features)
  local sub = menu4.submenu()
  check(
    "menu.submenu(): non-empty fly-out entry",
    sub ~= nil and sub.name ~= nil and #sub.items > 0
  )
  local menu5 = install_stub({ enable = false }, features)
  eq("menu.submenu(): nil when there is nothing to show", menu5.submenu(), nil)

  package.loaded["filetree"] = nil
  package.loaded["filetree.integrations.menu"] = nil
end

-- ── Image/PDF group: follows the node under the cursor ──────────────────────
do
  local features = {}
  features.open_with = (stub_action("open_with", { "open_system" }))
  local preview_calls
  features.preview, preview_calls = stub_action("preview", { "toggle_or_open" })
  features.preview.media_kind = function(path)
    if not path then return nil end
    if path:match("%.png$") then return "image" end
    if path:match("%.pdf$") then return "pdf" end
  end

  local function menu_for(path, menu_cfg)
    return install_stub(menu_cfg or { enable = true }, features, {
      get_current_node = function()
        return path and { path = path } or nil
      end,
    })
  end

  local pdf = names(menu_for("/x/book.pdf").items())
  check("media: PDF node gets Preview PDF", has(pdf, "Preview PDF"))
  check("media: PDF node gets Open externally", has(pdf, "Open externally"))
  check("media: PDF node gets no OCR/Image info", not has(pdf, "OCR (recognise text)"))

  local png = names(menu_for("/x/shot.png").items())
  check("media: image node gets Preview image", has(png, "Preview image"))
  check("media: no OCR row without images.nvim", not has(png, "OCR (recognise text)"))

  -- With images.nvim present, OCR and info are offered for images and get the node's path.
  local ocr_path
  package.loaded["images"] = {
    ocr = function(p)
      ocr_path = p
    end,
    info = function() end,
  }
  local png_items = menu_for("/x/shot.png").items()
  local png_names = names(png_items)
  check("media: image node gets OCR with images.nvim", has(png_names, "OCR (recognise text)"))
  check("media: image node gets Image info with images.nvim", has(png_names, "Image info"))
  for _, it in ipairs(png_items) do
    if it.name == "OCR (recognise text)" then it.cmd() end
  end
  eq("media: OCR is called with the clicked node's path", ocr_path, "/x/shot.png")
  local pdf_with_images = names(menu_for("/x/book.pdf").items())
  check(
    "media: PDF still gets no OCR with images.nvim",
    not has(pdf_with_images, "OCR (recognise text)")
  )
  package.loaded["images"] = nil

  for _, it in ipairs(menu_for("/x/shot.png").items()) do
    if it.name == "Preview image" then it.cmd() end
  end
  eq("media: Preview row calls preview.toggle_or_open", preview_calls[1], "preview.toggle_or_open")

  local txt = names(menu_for("/x/notes.txt").items())
  check(
    "media: text node gets no media group",
    not has(txt, "Preview image") and not has(txt, "Preview PDF")
  )
  local none = names(menu_for(nil).items())
  check("media: no node under the cursor -> no media group", not has(none, "Open externally"))
  local off = names(menu_for("/x/book.pdf", { enable = true, media = false }).items())
  check("media: media=false hides the group", not has(off, "Preview PDF"))

  package.loaded["filetree"] = nil
  package.loaded["filetree.integrations.menu"] = nil
end

-- ── Regression: a disabled entry in the MIDDLE of a group must not drop ─────
-- entries after it (a table constructor with a nil in a non-trailing slot
-- makes `ipairs` stop early — add_group must not iterate that way).
do
  local features = {}
  -- fileops group order is: smart_create, smart_rename, rename_batch, move,
  -- create_from_template. Disable smart_rename (position 2) only — every
  -- entry after it must still appear.
  features.smart_create = (stub_action("smart_create", { "create" }))
  -- smart_rename intentionally omitted (disabled) -> position 2 is nil.
  features.rename_batch = (stub_action("rename_batch", { "open" }))
  features.move = (stub_action("move", { "move" }))
  features.create_from_template = (stub_action("create_from_template", { "open_current" }))

  local menu = install_stub({ enable = true }, features)
  local list = names(menu.items())

  check("hole regression: entry before the gap present", has(list, "Create file / dir"))
  check(
    "hole regression: disabled entry (the gap itself) absent",
    not has(list, "Rename (LSP refs)")
  )
  check("hole regression: entry right after the gap present", has(list, "Batch rename"))
  check("hole regression: entry two after the gap present", has(list, "Move to…"))
  check("hole regression: last entry in the group present", has(list, "New from template"))

  package.loaded["filetree"] = nil
  package.loaded["filetree.integrations.menu"] = nil
end

-- ── marks group ───────────────────────────────────────────────────────────────
do
  local features = {}
  features.marks = (
    stub_action(
      "marks",
      { "toggle_current", "mark_all_visible", "unmark_all_visible", "clear_all", "show" }
    )
  )

  local menu = install_stub({ enable = true }, features)
  local list = names(menu.items())

  check("marks: toggle entry present", has(list, "Toggle mark"))
  check("marks: mark all entry present", has(list, "Mark all visible"))
  check("marks: unmark all entry present", has(list, "Unmark all visible"))
  check("marks: clear entry present", has(list, "Clear marks"))
  check("marks: show entry present", has(list, "Show marked nodes"))

  local menu2 = install_stub({ enable = true, marks = false }, features)
  check("marks opt-out: marks=false hides the group", not has(names(menu2.items()), "Toggle mark"))

  package.loaded["filetree"] = nil
  package.loaded["filetree.integrations.menu"] = nil
end

-- ── window group / window_entry() ────────────────────────────────────────────
do
  local closed_calls, opened_calls = 0, 0
  local open_reveal_arg

  local adapter_open = {
    is_open = function()
      return true
    end,
    close = function()
      closed_calls = closed_calls + 1
    end,
  }
  local adapter_closed = {
    is_open = function()
      return false
    end,
    open_reveal = function(path)
      opened_calls = opened_calls + 1
      open_reveal_arg = path
    end,
    open_cwd = function()
      opened_calls = opened_calls + 1
    end,
  }

  -- Tree open -> "Close filetree", both via items() and window_entry() directly.
  local menu_open = install_stub({ enable = true }, {}, adapter_open)
  local list_open = names(menu_open.items())
  check("window: tree open -> Close entry present", has(list_open, "Close filetree"))
  check("window: tree open -> Open entry absent", not has(list_open, "Open filetree"))

  local we = menu_open.window_entry()
  check("window_entry(): non-nil when tree is open", we ~= nil)
  assert(we, "window_entry() returned nil while the stub adapter reports the tree open")
  we.cmd()
  eq("window_entry(): cmd() calls adapter.close()", closed_calls, 1)

  -- Tree closed -> "Open filetree", reveals the given buffer's file.
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(scratch, "/tmp/filetree-menu-test.lua")
  -- filereadable() gates the reveal-vs-cwd branch; this file need not exist
  -- on disk for the "falls back to open_cwd" branch, so cover that instead.
  local menu_closed = install_stub({ enable = true }, {}, adapter_closed)
  local list_closed = names(menu_closed.items())
  check("window: tree closed -> Open entry present", has(list_closed, "Open filetree"))
  check("window: tree closed -> Close entry absent", not has(list_closed, "Close filetree"))

  local we2 = menu_closed.window_entry(scratch)
  assert(we2, "window_entry() returned nil while the stub adapter reports the tree closed")
  we2.cmd()
  eq("window_entry(): cmd() calls adapter.open_cwd() for an unreadable path", opened_calls, 1)
  eq("window_entry(): open_reveal() was not called for an unreadable path", open_reveal_arg, nil)
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })

  -- Group opt-out and master switch.
  local menu3 = install_stub({ enable = true, window = false }, {}, adapter_open)
  check(
    "window opt-out: window=false hides the group",
    not has(names(menu3.items()), "Close filetree")
  )

  local menu4 = install_stub({ enable = false }, {}, adapter_open)
  check(
    "window: master switch enable=false yields nil from window_entry()",
    menu4.window_entry() == nil
  )

  -- No adapter resolved at all (e.g. setup() not called yet) -> nil, not an error.
  local menu5 = install_stub({ enable = true }, {}, nil)
  check("window: no adapter -> window_entry() is nil, not an error", menu5.window_entry() == nil)

  package.loaded["filetree"] = nil
  package.loaded["filetree.integrations.menu"] = nil
end

-- ── enabled(): what ui.nvim's ui.menu asks first ─────────────────────────────
do
  local menu_e = install_stub({ enable = true }, {}, nil)
  check("enabled(): true by default", menu_e.enabled() == true)

  package.loaded["filetree"].config = function()
    return { menu = { enable = true }, integrations = { ui_menu = false } }
  end
  check("enabled(): integrations.ui_menu = false -> false", menu_e.enabled() == false)

  package.loaded["filetree"].config = function()
    return { menu = { enable = false }, integrations = { ui_menu = true } }
  end
  check("enabled(): menu.enable = false -> false", menu_e.enabled() == false)

  package.loaded["filetree"] = nil
  package.loaded["filetree.integrations.menu"] = nil
end

-- ── Report ────────────────────────────────────────────────────────────────────
print(("\nfiletree.nvim menu: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
  vim.cmd("cq")
else
  vim.cmd("qa!")
end
