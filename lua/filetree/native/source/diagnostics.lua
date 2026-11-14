---@module 'filetree.native.source.diagnostics'
---@brief The source `diagnostics`: every diagnostic the editor holds, by folder and file, worst first.
---@description
--- Written against the source contract only (`Filetree.Source`). The root answers the diagnostics of
--- all loaded buffers as they are now (`vim.diagnostic.get()`), `subscribe` follows
--- `DiagnosticChanged`.
---
--- Key responsibilities:
--- - `tree(items, root)`: pure, a flat list of diagnostics to folder, file and diagnostic nodes
--- - Order: the folder, the file and the diagnostic with the worst severity first, then by name or place
--- - Folder and file nodes carry their `path`; a diagnostic opens its buffer at its place
---
--- A diagnostic of a buffer without a file name (a scratch buffer) is left out: it has no folder.

local list = require("filetree.native.fs.list")

local api = vim.api

local M = {}

--- Worst first; also the order the tree adds statuses up in.
M.SEVERITY = { "error", "warn", "info", "hint" }

---@type table<string, integer>
local RANK = { error = 1, warn = 2, info = 3, hint = 4 }

---@type table<string, string>
local HL = {
  error = "DiagnosticError",
  warn = "DiagnosticWarn",
  info = "DiagnosticInfo",
  hint = "DiagnosticHint",
}

---@class Filetree.Diagnostics.Item
---@field path string  Normalized path of the file.
---@field bufnr? integer
---@field lnum integer  0-based, as `vim.diagnostic` gives it.
---@field col integer  0-based.
---@field severity "error"|"warn"|"info"|"hint"
---@field message string
---@field source? string

---@param a { rank: integer, label: string }
---@param b { rank: integer, label: string }
---@return boolean
local function worst_then_name(a, b)
  if a.rank ~= b.rank then return a.rank < b.rank end
  local la, lb = a.label:lower(), b.label:lower()
  if la ~= lb then return la < lb end
  return a.label < b.label
end

---Diagnostics as the nodes below the root.
---@param items Filetree.Diagnostics.Item[]
---@param root string  The root directory of the view; a folder below it is named relative to it.
---@return Filetree.Node[]
function M.tree(items, root)
  local prefix = list.join(root, "")
  ---@type table<string, { rank: integer, label: string, path: string, items: Filetree.Diagnostics.Item[] }>
  local files = {}
  for _, item in ipairs(items) do
    local file = files[item.path]
    if not file then
      file = { rank = 5, label = list.basename(item.path), path = item.path, items = {} }
      files[item.path] = file
    end
    file.items[#file.items + 1] = item
    file.rank = math.min(file.rank, RANK[item.severity] or 5)
  end

  ---@type table<string, { rank: integer, label: string, path: string, files: table[] }>
  local dirs = {}
  for _, file in pairs(files) do
    local dir = list.parent(file.path) or file.path
    local folder = dirs[dir]
    if not folder then
      local label = "."
      if dir ~= root then
        label = (dir:sub(1, #prefix) == prefix) and dir:sub(#prefix + 1)
          or (vim.fn.fnamemodify(dir, ":~"):gsub("\\", "/"))
      end
      folder = { rank = 5, label = label, path = dir, files = {} }
      dirs[dir] = folder
    end
    folder.files[#folder.files + 1] = file
    folder.rank = math.min(folder.rank, file.rank)
  end

  local out = {}
  local folders = vim.tbl_values(dirs)
  table.sort(folders, worst_then_name)
  for _, folder in ipairs(folders) do
    table.sort(folder.files, worst_then_name)
    local file_nodes = {}
    for _, file in ipairs(folder.files) do
      table.sort(file.items, function(a, b)
        local ra, rb = RANK[a.severity] or 5, RANK[b.severity] or 5
        if ra ~= rb then return ra < rb end
        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
        if a.col ~= b.col then return a.col < b.col end
        -- two at one place: a fixed order, so that each keeps its id when the list is read again
        return a.message < b.message
      end)
      local leaves, seen = {}, {}
      for _, item in ipairs(file.items) do
        -- several diagnostics may stand at one place: the nth of them keeps its id over a reload
        local at = ("%s:%d:%d"):format(file.path, item.lnum, item.col)
        seen[at] = (seen[at] or 0) + 1
        leaves[#leaves + 1] = {
          id = ("diagnostics:%s:%d"):format(at, seen[at]),
          label = (item.message:gsub("%s*\n%s*", " ")),
          kind = "diagnostic",
          status = item.severity,
          hl = HL[item.severity],
          columns = { ("%d:%d"):format(item.lnum + 1, item.col + 1) },
          data = { bufnr = item.bufnr, lnum = item.lnum + 1, col = item.col, source = item.source },
        }
      end
      file_nodes[#file_nodes + 1] = {
        id = "diagnostics:file:" .. file.path,
        label = file.label,
        kind = "file",
        path = file.path,
        open = true,
        columns = { tostring(#leaves) },
        children = leaves,
      }
    end
    out[#out + 1] = {
      id = "diagnostics:dir:" .. folder.path,
      label = folder.label,
      kind = "dir",
      path = folder.path,
      open = true,
      children = file_nodes,
    }
  end
  if #out == 0 then
    out[1] = { id = "diagnostics:none", label = "no diagnostics", kind = "note" }
  end
  return out
end

---@type table<integer, string>
local NAMES = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warn",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

---What the editor holds right now, as items.
---@return Filetree.Diagnostics.Item[]
function M.collect()
  local out = {}
  ---@type table<integer, string|false>
  local paths = {}
  for _, d in ipairs(vim.diagnostic.get()) do
    local buf = d.bufnr
    if buf and paths[buf] == nil then
      local name = api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) or ""
      paths[buf] = (name ~= "" and vim.bo[buf].buftype == "") and list.norm(name) or false
    end
    local path = buf and paths[buf]
    if path then
      out[#out + 1] = {
        path = path,
        bufnr = buf,
        lnum = d.lnum or 0,
        col = d.col or 0,
        severity = NAMES[d.severity] or "info",
        message = d.message or "",
        source = d.source,
      }
    end
  end
  return out
end

local subscriptions = 0

---@return Filetree.Source
function M.source()
  return {
    name = "diagnostics",
    title = "Diagnostics",
    severity = M.SEVERITY,
    root = function(ctx)
      return {
        id = "diagnostics:root",
        label = "Diagnostics",
        children = M.tree(M.collect(), ctx.root),
      }
    end,
    subscribe = function(_, emit)
      subscriptions = subscriptions + 1
      local group = api.nvim_create_augroup("filetree_source_diagnostics_" .. subscriptions, {})
      local alive = true
      -- a language server reports file after file: one read for a burst of them
      local debounce = require("lib.nvim.debounce").new(function()
        if alive then emit.reset() end
      end, 150)
      api.nvim_create_autocmd("DiagnosticChanged", {
        group = group,
        desc = "[filetree] The diagnostics view reads the diagnostics again",
        callback = function()
          debounce.call()
        end,
      })
      return function()
        alive = false
        debounce.cancel()
        pcall(api.nvim_del_augroup_by_id, group)
      end
    end,
  }
end

return M
