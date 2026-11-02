---@module 'filetree.features.ui.preview'
---@brief File content preview + image/PDF dispatch triggered from the tree.
---@description
--- Two preview modes (config `mode`):
---
---   "buffer" (default) — show the file in the editor window (the non-tree
---     window). Moving the cursor over file nodes live-updates it, like
---     neo-tree's built-in preview. Focus stays in the tree. Toggling off (or
---     leaving the tree) restores the buffer that was there before.
---   "float"            — a floating window next to the tree showing the first
---     N lines / hex dump / directory listing. Auto-closes on leaving the tree.
---
--- Images and PDFs are dispatched to an external/inline viewer in both modes.
---
--- Keymaps (defaults):
---   <Tab>  — toggle preview; image/PDF dispatch for those file types.
---   <CR>   — image/PDF/system_exts dispatch only; other nodes pass through to adapter's <CR>.

local notify = require("filetree.util.notify").create("[filetree.preview]")
local line_count = require("filetree.util.line_count")
local bufutil = require("filetree.util.buffer")

local au = require("filetree.util.autocmd")
local tree_attach = require("filetree.util.tree_attach")
local lib_debounce = require("lib.nvim.debounce")
local bind = require("filetree.util.bind")
local M = {}

local uv = vim.uv or vim.loop

---Shipped defaults. Never mutated: every `setup()` merges onto a fresh copy, so
---an option dropped from the user's config falls back instead of lingering.
---@type FiletreePreviewConfig
local DEFAULTS = {
  enabled = false,
  mode = "buffer", -- "buffer" | "float"
  highlight = true, -- syntax/treesitter highlighting in the preview
  cursor_debounce_ms = 80, -- delay live-update while scrolling the tree
  keymap = "<Tab>",
  keymap_open = "<CR>",
  max_lines = 40,
  max_bytes = 1024 * 1024, -- buffer mode: larger files are not loaded (0 = no limit)
  max_width = 80,
  max_height = 25,
  wrap = false,
  keymap_scroll_up = "<C-b>",
  keymap_scroll_down = "<C-f>",
  keymap_scroll_up10 = "<PageUp>",
  keymap_scroll_down10 = "<PageDown>",
  image = {
    backend = "auto", -- "auto" | "images.nvim" | "snacks" | "image.nvim" | "system" | false
    -- <CR> on an image: images.nvim's zen float at this size (fractions of the
    -- editor), <S-Up>/<S-Down> in it step the size. false = the backend's own view.
    -- `viewport = false` opens it plain: no zoom, pan, mouse, selection or
    -- save/copy keys in it (images.nvim's own keys, see its docs/BINDINGS.md).
    float = { width = 0.66, height = 0.66, viewport = true },
  },
  pdf = {
    backend = "pdfport", -- "pdfport" | "system" | false
  },
  -- Extensions that only make sense in their own application (a mail file is a
  -- binary container, not text): <CR>/<Tab> hand them to the OS default handler
  -- instead of loading them into a buffer. `{}` turns it off.
  system_exts = { "msg", "eml", "oft" },
}

---@type FiletreePreviewConfig
local _cfg = DEFAULTS

---Option schema (see `filetree.config.schema`): exactly what
---`features.preview` accepts. Keep it in step with the keys this module reads;
---`TESTS/config_schema.lua` fails when it drifts.
---@type FiletreeSchema
M.SCHEMA = {
  mode = { "string", enum = { "buffer", "float" } },
  highlight = "boolean",
  cursor_debounce_ms = { "number", min = 0 },
  keymap = "keymap",
  keymap_open = "keymap",
  max_lines = { "number", min = 1 },
  max_bytes = { "number", min = 0 },
  max_width = { "number", min = 1 },
  max_height = { "number", min = 1 },
  wrap = "boolean",
  keymap_scroll_up = "keymap",
  keymap_scroll_down = "keymap",
  keymap_scroll_up10 = "keymap",
  keymap_scroll_down10 = "keymap",
  image = {
    "table",
    fields = {
      backend = {
        "string|false",
        enum = { "auto", "images.nvim", "snacks", "image.nvim", "system" },
      },
      float = {
        "table|false",
        fields = {
          width = { "number", min = 0 },
          height = { "number", min = 0 },
          viewport = "boolean",
        },
      },
    },
  },
  pdf = {
    "table",
    fields = { backend = { "string|false", enum = { "pdfport", "system" } } },
  },
  system_exts = { "table", of = "string" },
}

---@type FiletreeAdapter?
local _adapter = nil

---@type integer?  current float preview window
local _win = nil
---@type integer?  current float preview buffer
local _bufnr = nil

---Debounce handle for the CursorMoved live-update, built in M.setup() (needs
---`_cfg.cursor_debounce_ms`); `{ call, cancel }`.
---@type table?
local _cm_debounce = nil

-- Buffer-mode state: preview shown inside an existing editor window.
---@type boolean
local _buf_active = false
---@type integer?  editor window used for buffer-mode preview
local _editor_win = nil
---@type integer?  buffer that was in _editor_win before preview started (to restore)
local _saved_buf = nil

-- ── File-type detection ───────────────────────────────────────────────────────

local _IMAGE_EXTS = {
  png = 1,
  jpg = 1,
  jpeg = 1,
  gif = 1,
  bmp = 1,
  svg = 1,
  webp = 1,
  ico = 1,
  tiff = 1,
  tif = 1,
  avif = 1,
  heic = 1,
}

local _PDF_EXTS = { pdf = 1 }

local function ext(path)
  return (path:match("%.([^.]+)$") or ""):lower()
end

local function is_image(path)
  return _IMAGE_EXTS[ext(path)] == 1
end

---Enable treesitter highlighting on a preview buffer, if configured and a
---parser is available. Explicit (rather than relying on the user's own
---FileType-triggered auto-attach) so it works reliably for the float mode's
---synthetic scratch buffer too — some treesitter setups skip auto-attaching
---to `buftype=nofile` buffers. Safe/idempotent to call on a buffer that
---already has treesitter running (e.g. buffer-mode's real file buffers).
---@param bufnr integer
---@param ft string  filetype, may be "".
local function apply_highlight(bufnr, ft)
  if _cfg.highlight == false then return end
  if ft == "" then return end
  local ok_lang, lang = pcall(vim.treesitter.language.get_lang, ft)
  lang = (ok_lang and lang) or ft
  pcall(vim.treesitter.start, bufnr, lang)
end
local function is_pdf(path)
  return _PDF_EXTS[ext(path)] == 1
end

---A file (not a folder that happens to be named `x.msg`) whose extension is in
---`system_exts`.
local function is_system_ext(path)
  local wanted = _cfg.system_exts
  local e = ext(path)
  if type(wanted) ~= "table" or e == "" then return false end
  for _, want in ipairs(wanted) do
    if type(want) == "string" and want:gsub("^%.", ""):lower() == e then
      -- The filesystem is asked only for a name that matched.
      return vim.fn.isdirectory(path) ~= 1
    end
  end
  return false
end

-- ── Cross-platform system-open ────────────────────────────────────────────────

local function system_open(path)
  local ok = require("lib.nvim.cross.open_default")(path)
  if not ok then notify.warn("Could not open in system app: " .. path) end
end

-- ── Image backend dispatch ────────────────────────────────────────────────────

local function open_image(path)
  local backend = (_cfg.image or {}).backend or "auto"
  if backend == false then return false end -- caller falls through to text preview

  -- images.nvim first in "auto": it is the only backend that works on native
  -- Windows Neovim. snacks.image and image.nvim both speak Kitty APC only, and
  -- Kitty sequences coming from Neovim are never drawn in WezTerm on Windows —
  -- so "auto" would silently degrade to the system app there.
  if backend == "images.nvim" or backend == "auto" then
    local ok0, images = pcall(require, "images")
    if ok0 and images.show then
      -- pcall's first return is only "did this throw", not the callee's own
      -- ok/fail result — images.show() never throws (it catches its own
      -- errors and returns false), so that first value was always true here,
      -- masking every real failure and short-circuiting the fallbacks below.
      local call_ok0, shown0 = pcall(images.show, path)
      if call_ok0 and shown0 then return true end
    end
    if backend == "images.nvim" then
      notify.warn("images.nvim not available — install WKDSteve/images.nvim")
      return true
    end
  end

  if backend == "snacks" or backend == "auto" then
    local ok, snacks = pcall(require, "snacks")
    -- snacks.image has no `open()` and never had one, so this branch always
    -- threw inside the pcall and fell through. It renders an image buffer when
    -- one is displayed; `supports()` is its public "can I draw this file", and
    -- opening the file is what puts it in charge of the drawing.
    if
      ok
      and snacks.image
      and type(snacks.image.supports) == "function"
      and snacks.image.supports(path)
    then
      local call_ok = pcall(function()
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end)
      if call_ok then return true end
    end
    if backend == "snacks" then
      notify.warn("snacks.image not available — install folke/snacks.nvim")
      return true -- don't fall through
    end
  end

  if backend == "image.nvim" or backend == "auto" then
    local ok2, img = pcall(require, "image")
    if ok2 and img.open then
      local call_ok2, opened2 = pcall(img.open, path)
      if call_ok2 and opened2 then return true end
    end
    if backend == "image.nvim" then
      notify.warn("image.nvim not available — install 3rd/image.nvim")
      return true
    end
  end

  -- "system" or "auto" fallback
  system_open(path)
  return true
end

---Open `path` in images.nvim's zen float at `image.float`'s size, for <CR>.
---Only when the configured backend may be images.nvim ("auto" or
---"images.nvim"); false when the float is off, images.nvim (or its `zen`) is
---missing, or `zen` raised, so the caller goes on to `open_image`. A `zen`
---that returned false has handled the image already: it reports its own
---failures, and on a terminal that cannot draw it hands the image to
---`images.show` itself, so going on to `open_image` would show it twice.
---@param path string
---@return boolean handled
local function open_image_float(path)
  local cfg_img = _cfg.image or {}
  local box = cfg_img.float
  if type(box) ~= "table" then return false end
  local backend = cfg_img.backend or "auto"
  if backend ~= "auto" and backend ~= "images.nvim" then return false end
  local ok, images = pcall(require, "images")
  if not ok or type(images) ~= "table" or type(images.zen) ~= "function" then return false end
  -- `viewport` only when it is off: an images.nvim older than the option
  -- ignores it either way, and the default needs no word.
  local zen_opts = { width = box.width, height = box.height }
  if box.viewport == false then zen_opts.viewport = false end
  return (pcall(images.zen, path, zen_opts))
end

-- ── PDF backend dispatch ──────────────────────────────────────────────────────

local function open_pdf(path)
  local backend = (_cfg.pdf or {}).backend or "pdfport"
  if backend == false then return false end

  -- Route through the shared opener so the pdfport require + call signature live
  -- in one place (filetree.util.pdf). `mode = "system"` there is dependency-free;
  -- "buffer" dispatches to pdfport.nvim with an automatic system-viewer fallback.
  local pdf = require("filetree.util.pdf")
  if backend == "system" then
    pdf.system_open(path)
  else
    pdf.open(path, { mode = "buffer", split = "vsplit", focus = true })
  end
  return true
end

-- ── Text preview helpers ──────────────────────────────────────────────────────

---Bytes read from the start of a file of unknown type to look for a NUL.
local PROBE_BYTES = 512

local function is_binary(path)
  local e = ext(path)
  if line_count.is_binary_ext(e) then return true end
  -- Unknown extension: probe the first bytes for a NUL. Not through readfile():
  -- it hands a NUL back as "\n", so no test for a zero byte on its result can
  -- ever fire, and it reads a whole first line, which in a file without
  -- newlines is the whole file. (uv, not io.open: libuv takes a UTF-8 path on
  -- Windows, the C runtime's fopen does not.)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return false end
  local head = uv.fs_read(fd, PROBE_BYTES, 0)
  uv.fs_close(fd)
  return type(head) == "string" and head:find("\0", 1, true) ~= nil
end

local function hex_dump(path)
  local ok, data = pcall(vim.fn.readfile, path, "b", 16)
  if not ok then return { "(cannot read file)" } end
  local out = {}
  for i, l in ipairs(data) do
    local hex = {}
    for j = 1, #l do
      hex[#hex + 1] = string.format("%02x", l:byte(j))
    end
    out[i] = table.concat(hex, " ")
  end
  out[#out + 1] = "(binary — first 16 lines as hex)"
  return out
end

local function read_text(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", _cfg.max_lines)
  if not ok then return { "(cannot read file)" } end
  return lines
end

local function list_dir(path)
  local ok, entries = pcall(vim.fn.readdir, path)
  if not ok then return { "(cannot list directory)" } end
  table.sort(entries)
  local out = { "Directory: " .. path, "" }
  for _, e in ipairs(entries) do
    local full = path .. "/" .. e
    local prefix = vim.fn.isdirectory(full) == 1 and "  /" or "   "
    out[#out + 1] = prefix .. e
  end
  return out
end

-- ── Preview window ────────────────────────────────────────────────────────────

local function close_preview()
  if _win and vim.api.nvim_win_is_valid(_win) then pcall(vim.api.nvim_win_close, _win, true) end
  if _bufnr and vim.api.nvim_buf_is_valid(_bufnr) then
    pcall(vim.api.nvim_buf_delete, _bufnr, { force = true })
  end
  _win = nil
  _bufnr = nil
end

local function open_preview(node)
  close_preview()

  local path = node.path
  local is_dir = vim.fn.isdirectory(path) == 1
  local lines, ft

  if is_dir then
    lines = list_dir(path)
    ft = ""
  elseif is_binary(path) then
    lines = hex_dump(path)
    ft = ""
  else
    lines = read_text(path)
    ft = vim.filetype.match({ filename = path }) or ""
  end

  -- `or <default>` mirrors the defaults above; see watcher_quarantine.
  local max_w = _cfg.max_width or 80
  local content_w = 0
  for _, l in ipairs(lines) do
    content_w = math.max(content_w, #l)
  end
  local width = math.max(math.min(content_w + 2, max_w), 20)
  local height = math.min(#lines + 1, _cfg.max_height or 25)

  local cur_win = vim.api.nvim_get_current_win()
  local win_pos = vim.api.nvim_win_get_position(cur_win)
  local win_w = vim.api.nvim_win_get_width(cur_win)
  local cur_row = vim.api.nvim_win_get_cursor(cur_win)[1] - 1

  local col = win_pos[2] + win_w + 1
  if col + width > vim.o.columns then col = math.max(0, win_pos[2] - width - 1) end
  local row = math.max(0, win_pos[1] + cur_row - math.floor(height / 2))
  row = math.min(row, vim.o.lines - height - 3)

  -- `ui.kit.surface` (a required dependency, see docs/installation.md), not a
  -- raw `nvim_open_win` -- its border/colors come from the active
  -- `ui.kit.theme` preset like every other popup in the fleet, instead of
  -- being pinned to "always rounded, always NormalFloat/FloatBorder"
  -- regardless of a preset switch (`:UI kit-preset ascii`, say).
  local surface = require("ui.kit.surface")
  local opened = surface.open({
    lines = lines,
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    focusable = false,
    -- `focusable = false` alone does NOT stop the window from becoming
    -- current on creation -- that is `enter`'s own, separate `nvim_open_win`
    -- parameter, which `ui.kit.surface`/`lib.nvim.window.make_scratch`
    -- default to true when omitted. Without this, opening the float moved
    -- focus (and hence tree navigation, the CursorMoved live-update, and
    -- the float-mode scroll keymaps) off the tree and onto the read-only
    -- preview buffer on every `<Tab>`.
    enter = false,
    modifiable = false,
    filetype = ft ~= "" and ft or nil,
    title = " " .. vim.fn.fnamemodify(path, ":t") .. " ",
    title_pos = "center",
    wo = { wrap = _cfg.wrap },
  })
  if not opened then return end

  _win = opened.winid
  _bufnr = opened.bufnr
  if ft ~= "" then apply_highlight(_bufnr, ft) end
  pcall(vim.api.nvim_win_set_cursor, _win, { 1, 0 })
end

-- ── Scroll helper ─────────────────────────────────────────────────────────────

---@param delta integer  positive = up (lower line numbers)
local function scroll_preview(delta)
  if not (_win and vim.api.nvim_win_is_valid(_win)) then return end
  local buf = vim.api.nvim_win_get_buf(_win)
  local total = vim.api.nvim_buf_line_count(buf)
  local cur = vim.api.nvim_win_get_cursor(_win)[1]
  local next = math.max(1, math.min(total, cur - delta))
  pcall(vim.api.nvim_win_set_cursor, _win, { next, 0 })
end

---Scroll the BUFFER-mode preview (the file shown in the editor window) by
---`count` full pages, without leaving the tree. Returns false when
---buffer-mode preview isn't active, so the caller can fall through to the
---tree's own native scroll.
---@param dir integer  1 = down (<PageDown>/<C-f>), -1 = up (<PageUp>/<C-b>)
---@param count integer|nil  defaults to 1.
---@return boolean handled
local function scroll_buf_preview(dir, count)
  if not (_buf_active and _editor_win and vim.api.nvim_win_is_valid(_editor_win)) then
    return false
  end
  count = (type(count) == "number" and count > 0) and count or 1
  -- \6 = <C-f> (page down), \2 = <C-b> (page up); run in the preview window's
  -- context so its own view scrolls while the cursor stays in the tree.
  -- <C-f>/<C-b> already honor a leading count natively ("3<C-f>" = 3 pages),
  -- so the count is prefixed onto the same one-page command rather than
  -- looping it.
  local key = dir > 0 and "\6" or "\2"
  pcall(vim.api.nvim_win_call, _editor_win, function()
    vim.cmd("normal! " .. count .. key)
  end)
  return true
end

-- ── Buffer-mode preview (show file in the editor window) ────────────────────────

---Editor window to preview into: not the tree window, holds a normal buffer.
---@return integer?
local function editor_target()
  local tree_win = _adapter and _adapter.get_winid and _adapter.get_winid() or nil
  return bufutil.find_editor_win(tree_win)
end

-- A preview is a transient display, not a navigation — but bufload() and
-- nvim_win_set_buf() fire BufEnter/BufWinEnter/WinEnter in the TARGET (editor)
-- window's context, with the previewed file as `%`. Features that follow the
-- current file then wrongly treat the preview as a real buffer switch:
-- cwd_sync chdir's to the previewed file's project root (very visible when
-- Neovim was started above the project, e.g. in a repos parent dir), neo-tree's
-- own follow_current_file re-roots, auto_reveal jumps. Suppress exactly those
-- navigation events around the buffer swap — not FileType/BufReadPost, so the
-- previewed buffer's syntax still attaches.
local NAV_EVENTS = "BufEnter,BufWinEnter,WinEnter,BufLeave,WinLeave,BufWinLeave"
local function without_nav_events(fn)
  local save = vim.o.eventignore
  vim.o.eventignore = NAV_EVENTS
  local ok, err = pcall(fn)
  vim.o.eventignore = save
  if not ok then error(err) end
end

---Why `path` must not be loaded into a buffer for the preview, or nil when it
---may. Decided before any bufadd/bufload, cheapest probe first: one stat for the
---size, then the extension / NUL probe the float mode already uses to choose
---its hex dump.
---@param path string
---@return string? reason  Completes "<name> is ...".
local function buf_refusal(path)
  local limit = _cfg.max_bytes
  if type(limit) == "number" and limit > 0 then
    local stat = uv.fs_stat(path)
    if stat and stat.size > limit then
      return ("larger than %d bytes (features.preview.max_bytes)"):format(limit)
    end
  end
  if is_binary(path) then return "a binary file" end
  return nil
end

---The file the last "preview skipped" notice was for. The cursor-follow calls
---buf_show() again on every CursorMoved over the same node (a column move
---included), which must not repeat the notice.
---@type string?
local _refused = nil

---Display `path` in the buffer-mode editor window without stealing focus.
---A file the preview must not load (see `buf_refusal`) leaves the window as it
---is and says so once; `<Tab>`/`<CR>` still hand images and PDFs to their viewer.
---@param path string
local function buf_show(path)
  local win = _editor_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if vim.fn.filereadable(path) ~= 1 then return end
  local refusal = buf_refusal(path)
  if refusal then
    if _refused ~= path then
      _refused = path
      notify.info(("preview skipped: %s is %s"):format(vim.fn.fnamemodify(path, ":t"), refusal))
    end
    return
  end
  _refused = nil
  local b = vim.fn.bufadd(path)
  without_nav_events(function()
    vim.fn.bufload(b) -- triggers filetype/syntax
    pcall(vim.api.nvim_win_set_buf, win, b) -- set buffer, focus stays in tree
  end)
  apply_highlight(b, vim.bo[b].filetype)
end

---Stop buffer-mode preview. When `restore` is true, put the original buffer back.
---@param restore boolean
local function buf_stop(restore)
  if
    restore
    and _editor_win
    and vim.api.nvim_win_is_valid(_editor_win)
    and _saved_buf
    and vim.api.nvim_buf_is_valid(_saved_buf)
  then
    -- Restoring the original buffer is just as much a non-navigation as showing
    -- the preview was, so suppress the same follow-the-file events (otherwise
    -- ending a preview would itself trigger a spurious cwd_sync chdir).
    without_nav_events(function()
      pcall(vim.api.nvim_win_set_buf, _editor_win, _saved_buf)
    end)
  end
  _buf_active = false
  _editor_win = nil
  _saved_buf = nil
  _refused = nil
end

---Start buffer-mode preview for `node`, remembering the editor window's buffer.
---@param node FiletreeNode
local function buf_start(node)
  local win = editor_target()
  if not win then
    notify.warn("no editor window to preview into")
    return
  end
  _editor_win = win
  _saved_buf = vim.api.nvim_win_get_buf(win)
  _buf_active = true
  if node and node.path and node.path ~= "" and vim.fn.isdirectory(node.path) ~= 1 then
    buf_show(node.path)
  end
end

---Re-check state and refresh the live preview at CursorMoved-debounce fire
---time (the cursor/tree may have changed since the event fired).
local function do_cursor_update()
  if vim.bo.filetype ~= "neo-tree" and vim.bo.filetype ~= "NvimTree" then return end
  local node = _adapter and _adapter.get_current_node()
  if not node then return end

  if _cfg.mode == "float" then
    if _win and vim.api.nvim_win_is_valid(_win) then open_preview(node) end
  elseif _buf_active then
    if node.path and node.path ~= "" and vim.fn.isdirectory(node.path) ~= 1 then
      buf_show(node.path)
    end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

---Toggle text/dir preview in the configured mode.
function M.toggle()
  if not _adapter then return end

  if _cfg.mode == "float" then
    if _win and vim.api.nvim_win_is_valid(_win) then
      close_preview()
      return
    end
    local node = _adapter.get_current_node()
    if not node then
      notify.warn("no node under cursor")
      return
    end
    open_preview(node)
    return
  end

  -- buffer mode
  if _buf_active then
    buf_stop(true)
    return
  end
  local node = _adapter.get_current_node()
  if not node then
    notify.warn("no node under cursor")
    return
  end
  buf_start(node)
end

---Dispatch for <Tab>: image/PDF open, text preview toggle for everything else.
function M.toggle_or_open()
  if not _adapter then return end
  local node = _adapter.get_current_node()
  if not node or not node.path or node.path == "" then
    notify.warn("no node under cursor")
    return
  end

  local cfg_img = _cfg.image or {}
  local cfg_pdf = _cfg.pdf or {}

  if cfg_img.backend ~= false and is_image(node.path) then
    close_preview() -- close any open text preview first
    open_image(node.path)
    return
  end

  if cfg_pdf.backend ~= false and is_pdf(node.path) then
    close_preview()
    open_pdf(node.path)
    return
  end

  if is_system_ext(node.path) then
    close_preview()
    system_open(node.path)
    return
  end

  -- Text / directory preview (toggle)
  M.toggle()
end

---Dispatch for <CR>: image/PDF open; calls `fallback` for other nodes.
---@param fallback function?
function M.open_or_fallback(fallback)
  if not _adapter then return end
  local node = _adapter.get_current_node()
  if not node or not node.path or node.path == "" then
    if fallback then fallback() end
    return
  end

  local cfg_img = _cfg.image or {}
  local cfg_pdf = _cfg.pdf or {}

  if cfg_img.backend ~= false and is_image(node.path) then
    if not open_image_float(node.path) then open_image(node.path) end
    return
  end

  if cfg_pdf.backend ~= false and is_pdf(node.path) then
    open_pdf(node.path)
    return
  end

  if is_system_ext(node.path) then
    system_open(node.path)
    return
  end

  if fallback then fallback() end
end

---"image" or "pdf" when `path` is a node the image/PDF dispatch of `<Tab>`/`<CR>` would handle
---(backend not switched off in `features.preview.image`/`.pdf`), else nil. The context menu uses
---it to decide whether to offer its Image/PDF group.
---@param path string?
---@return "image"|"pdf"|nil
function M.media_kind(path)
  if type(path) ~= "string" or path == "" then return nil end
  if (_cfg.image or {}).backend ~= false and is_image(path) then return "image" end
  if (_cfg.pdf or {}).backend ~= false and is_pdf(path) then return "pdf" end
  return nil
end

function M.close()
  close_preview()
  buf_stop(true)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

---@type integer?
local _augroup = nil

---@param config FiletreePreviewConfig
---@param adapter FiletreeAdapter
function M.setup(config, adapter)
  if not config.enabled then return end
  _cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), config)
  _adapter = adapter

  if _cm_debounce then _cm_debounce.cancel() end
  _cm_debounce = lib_debounce.new(do_cursor_update, _cfg.cursor_debounce_ms or 80)

  if _augroup then au.del_group(_augroup) end
  _augroup = au.group("filetree_preview", true)

  tree_attach.on_attach(function(buf)
    -- Per buffer, not once: `<CR>` wraps whatever the adapter had mapped
    -- there, which can only be read off the buffer it is being bound in.
    local original_cr_cb = nil
    if _cfg.keymap_open then
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == _cfg.keymap_open then
          original_cr_cb = m.callback
          break
        end
      end
    end

    -- The lhs each scroll key ended up on, filled in once the registry has
    -- resolved the overrides. The page keys feed their own key back to the
    -- tree when no preview is active, and that has to be the key the user
    -- actually pressed, not the default it was declared with.
    ---@type table<string, string|nil>
    local lhs_of_action = {}

    ---@type FiletreeBindSpec[]
    local specs = {
      -- <Tab>: toggle text preview, or dispatch image/PDF
      {
        name = "toggle",
        field = "keymap",
        rhs = M.toggle_or_open,
        desc = "preview / open image or PDF",
      },
      -- <CR>: image/PDF dispatch; save and call the adapter's original <CR>
      -- for other nodes
      {
        name = "open",
        field = "keymap_open",
        desc = "open image/PDF, or adapter default",
        rhs = function()
          M.open_or_fallback(original_cr_cb)
        end,
      },
    }

    if _cfg.mode == "float" then
      -- Float mode: the scroll keys move the float's cursor. A count prefix
      -- multiplies the fixed step (1 line for <C-b>/<C-f>, 10 for
      -- <PageUp>/<PageDown>) rather than looping scroll_preview, since its
      -- delta is plain cursor-line arithmetic.
      for _, entry in ipairs({
        { "scroll_up", "keymap_scroll_up", 1 },
        { "scroll_down", "keymap_scroll_down", -1 },
        { "scroll_up10", "keymap_scroll_up10", 10 },
        { "scroll_down10", "keymap_scroll_down10", -10 },
      }) do
        local delta = entry[3]
        specs[#specs + 1] = {
          name = entry[1],
          field = entry[2],
          desc = "scroll preview " .. (delta > 0 and "up" or "down") .. " (×count)",
          rhs = function()
            scroll_preview(delta * vim.v.count1)
          end,
        }
      end
    else
      -- Buffer mode: <PageUp>/<PageDown> page the previewed file in the
      -- editor window while the cursor stays in the tree. When no preview is
      -- active the key falls through to the tree's own native scroll (fed
      -- back with noremap so this mapping doesn't re-trigger) — the count is
      -- carried along in both cases.
      for _, entry in ipairs({
        { "page_up", "keymap_scroll_up10", -1 },
        { "page_down", "keymap_scroll_down10", 1 },
      }) do
        local name, dir = entry[1], entry[3]
        specs[#specs + 1] = {
          name = name,
          field = entry[2],
          desc = "page preview " .. (dir > 0 and "down" or "up") .. " (×count)",
          rhs = function()
            local count = vim.v.count1
            if not scroll_buf_preview(dir, count) then
              local lhs = lhs_of_action[name]
              if not lhs then return end
              local k = vim.api.nvim_replace_termcodes(tostring(count) .. lhs, true, false, true)
              vim.api.nvim_feedkeys(k, "n", false)
            end
          end,
        }
      end
    end

    for _, e in ipairs(bind.bind_buffer("preview", _cfg, specs, buf)) do
      if e.bound and e.lhs then lhs_of_action[e.name] = e.lhs end
    end
  end)

  -- Leaving the tree ends the preview. Float: close it. Buffer: deactivate but
  -- keep the shown file (the user is moving into the editor to use it); toggling
  -- off from inside the tree is what restores the original buffer.
  au.acmd({ "BufLeave", "WinLeave" }, {
    group = _augroup,
    pattern = "*",
    desc = "[filetree] End the preview when the cursor leaves the tree",
    callback = function(ev)
      if bufutil.is_tree_buffer(ev.buf) then
        if _cfg.mode == "float" then
          close_preview()
        elseif _buf_active then
          buf_stop(false)
        end
      end
    end,
  })

  -- Live-update the preview as the cursor moves over tree nodes — debounced so
  -- fast scrolling through the tree doesn't run a bufadd+bufload+treesitter (or a
  -- full float rebuild) on every single line. The node is re-read when the timer
  -- fires, so the update always reflects the cursor's final resting line.
  au.acmd("CursorMoved", {
    group = _augroup,
    pattern = "*",
    desc = "[filetree] Follow the tree node under the cursor with the preview (debounced)",
    callback = function()
      local ft = vim.bo.filetype
      if ft ~= "neo-tree" and ft ~= "NvimTree" then return end

      -- Nothing to update unless a preview is actually active.
      if _cfg.mode == "float" then
        if not (_win and vim.api.nvim_win_is_valid(_win)) then return end
      elseif not _buf_active then
        return
      end

      if _cm_debounce then _cm_debounce.call() end
    end,
  })
end

function M.teardown()
  close_preview()
  buf_stop(true)
  if _cm_debounce then
    if _cm_debounce then _cm_debounce.cancel() end
    _cm_debounce = nil
  end
  _adapter = nil
  if _augroup then
    au.del_group(_augroup)
    _augroup = nil
  end
end

return M
