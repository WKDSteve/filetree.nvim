---@module 'filetree.native.source.files'
---@brief The entries of a directory as tree nodes: sorted, filtered, empty folder chains merged.
---@description
--- Turns what `filetree.native.fs.list` read into the nodes the tree shows. Everything a view can
--- change about a listing without reading the disk again happens here: the order, which names are
--- hidden, and whether a chain of folders that hold nothing but one folder is drawn as one line.
---
--- Key responsibilities:
--- - `nodes(entries, opts)`: `Filetree.Node[]` for one folder
--- - Folders first, then by name (case-insensitive), size or modification time
--- - A merged line `a/b/c`: id and `path` are the innermost folder, `data.chain` lists all of them
---
--- Every folder node has `kind = "dir"`: the tree core calls a folder that turned out empty a leaf,
--- and it has to stay a folder for everything that looks at the node.

local list = require("filetree.native.fs.list")

local M = {}

---@class Filetree.Files.Opts
---@field loader fun(node: Filetree.Node, cb: fun(list?: Filetree.Node[], err?: string))  The lazy `children` of every folder node.
---@field sort? { kind: "name"|"size"|"mtime", descending?: boolean }
---@field hide? fun(name: string, path: string): boolean  True for an entry that is not shown.
---@field group_empty? boolean  Merge chains of folders that hold exactly one folder (default true).
---@field group_limit? integer  Folders are only looked into for merging when the listing has at most this many (default 200).

---@param entry Filetree.Fs.Entry
---@param field string  "size" or "mtime".
---@return number
local function stat_of(entry, field)
  local stat = vim.uv.fs_stat(entry.path)
  if not stat then return 0 end
  if field == "size" then return stat.size end
  return stat.mtime.sec + stat.mtime.nsec / 1e9
end

---@param entries Filetree.Fs.Entry[]
---@param sort { kind: "name"|"size"|"mtime", descending?: boolean }
---@return Filetree.Fs.Entry[]
local function sorted(entries, sort)
  local out = vim.list_slice(entries)
  local keys = {}
  if sort.kind ~= "name" then
    for _, entry in ipairs(out) do
      keys[entry] = stat_of(entry, sort.kind)
    end
  end
  local lower = {}
  for _, entry in ipairs(out) do
    lower[entry] = entry.name:lower()
  end
  table.sort(out, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    if sort.kind ~= "name" and keys[a] ~= keys[b] then
      if sort.descending then return keys[a] > keys[b] end
      return keys[a] < keys[b]
    end
    if lower[a] ~= lower[b] then
      if sort.descending and sort.kind == "name" then return lower[a] > lower[b] end
      return lower[a] < lower[b]
    end
    return a.name < b.name
  end)
  return out
end

---The chain a folder starts when it holds exactly one visible entry and that is a folder.
---@param entry Filetree.Fs.Entry
---@param hide fun(name: string, path: string): boolean
---@return string[] chain  Paths, outermost first; just the folder itself when nothing merges.
---@return string label
local function chain_of(entry, hide)
  local chain, label = { entry.path }, entry.name
  local current = entry
  -- a link is never merged: the line would hide that it is one
  while not current.is_link do
    local inner = list.list_sync(current.path)
    if not inner then break end
    local only = nil
    for _, child in ipairs(inner) do
      if not hide(child.name, child.path) then
        if only then
          only = nil
          break
        end
        only = child
      end
    end
    if not only or not only.is_dir or only.is_link then break end
    chain[#chain + 1] = only.path
    label = label .. "/" .. only.name
    current = only
  end
  return chain, label
end

---The nodes of one folder.
---@param entries Filetree.Fs.Entry[]
---@param opts Filetree.Files.Opts
---@return Filetree.Node[]
function M.nodes(entries, opts)
  local hide = opts.hide or function()
    return false
  end
  local visible = {}
  local dirs = 0
  for _, entry in ipairs(entries) do
    if not hide(entry.name, entry.path) then
      visible[#visible + 1] = entry
      if entry.is_dir then dirs = dirs + 1 end
    end
  end
  local group = opts.group_empty ~= false and dirs <= (opts.group_limit or 200)

  local out = {}
  for _, entry in ipairs(sorted(visible, opts.sort or { kind = "name" })) do
    ---@type table
    local node = {
      id = entry.path,
      label = entry.name,
      kind = entry.is_dir and "dir" or "file",
      path = entry.path,
    }
    if entry.is_link then
      node.data = { is_link = true, link_to = entry.link_to, link_broken = entry.link_broken }
    end
    if entry.is_dir then
      node.children = opts.loader
      if group then
        local chain, label = chain_of(entry, hide)
        if #chain > 1 then
          node.id, node.path, node.label = chain[#chain], chain[#chain], label
          node.data = vim.tbl_extend("force", node.data or {}, { chain = chain })
        end
      end
    end
    out[#out + 1] = node
  end
  return out
end

return M
