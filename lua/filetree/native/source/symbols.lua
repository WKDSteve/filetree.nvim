---@module 'filetree.native.source.symbols'
---@brief The source `symbols`: the LSP document symbols of the editor buffer, as a tree that follows the cursor.
---@description
--- Written against the source contract only (`Filetree.Source`). The root asks the language servers
--- of the editor buffer (`ctx.alt_buf`) for `textDocument/documentSymbol`, without blocking, and
--- answers both shapes a server may send: a hierarchy (`DocumentSymbol[]`) or a flat list with
--- container names (`SymbolInformation[]`).
---
--- Key responsibilities:
--- - `nodes(result, bufnr)`: pure, a server answer to nodes; ids are name paths, so they survive an edit
--- - `at(nodes, lnum)`: pure, the innermost symbol a line lies in
--- - `subscribe`: another editor buffer or an edit asks again; the cursor in the editor moves the
---   cursor of the tree (`emit.focus`)
---
--- A symbol is no file: its node has no `path` (a file action on a symbol would hit the whole file).
--- It opens its buffer at the symbol's name.

local api = vim.api

local M = {}

local METHOD = "textDocument/documentSymbol"

---@type string[]  `SymbolKind` of the protocol, by number.
local KINDS = {
  "file",
  "module",
  "namespace",
  "package",
  "class",
  "method",
  "property",
  "field",
  "constructor",
  "enum",
  "interface",
  "function",
  "variable",
  "constant",
  "string",
  "number",
  "boolean",
  "array",
  "object",
  "key",
  "null",
  "enum member",
  "struct",
  "event",
  "operator",
  "type parameter",
}

---@param parent string  The id the children hang below.
---@param name string
---@param counts table<string, integer>  Names seen among these siblings.
---@return string
local function id_of(parent, name, counts)
  counts[name] = (counts[name] or 0) + 1
  -- the second `M.setup` of a file is another node than the first
  local nth = counts[name] > 1 and ("#" .. counts[name]) or ""
  return parent .. "/" .. name .. nth
end

---@param symbol table  A `DocumentSymbol` or a `SymbolInformation`.
---@param id string
---@param bufnr integer
---@return Filetree.Node
local function node_of(symbol, id, bufnr)
  local range = symbol.range or (symbol.location and symbol.location.range) or {}
  local name_at = symbol.selectionRange or range
  local first = range.start and range.start.line or 0
  local last = range["end"] and range["end"].line or first
  local kind = KINDS[symbol.kind] or "symbol"
  return {
    id = id,
    label = symbol.name or "?",
    kind = kind,
    columns = { kind },
    data = {
      bufnr = bufnr,
      lnum = (name_at.start and name_at.start.line or first) + 1,
      col = name_at.start and name_at.start.character or 0,
      first = first + 1,
      last = last + 1,
    },
  }
end

---A server answer as nodes. The containers of the first level start open.
---@param result table[]|nil  `DocumentSymbol[]` or `SymbolInformation[]`.
---@param bufnr integer  The buffer the symbols are of.
---@return Filetree.Node[]
function M.nodes(result, bufnr)
  if type(result) ~= "table" or #result == 0 then return {} end
  local root_id = "symbols:" .. bufnr

  if result[1].location then
    -- a flat list: a symbol names its container, the container stands before it
    local out, by_name, counts = {}, {}, {}
    for _, symbol in ipairs(result) do
      local name = symbol.name or "?"
      local parent = symbol.containerName and by_name[symbol.containerName] or nil
      local parent_id = parent and parent.id or root_id
      counts[parent_id] = counts[parent_id] or {}
      local node = node_of(symbol, id_of(parent_id, name, counts[parent_id]), bufnr)
      node.data.depth = parent and (parent.data.depth + 1) or 0
      if parent then
        parent.children = parent.children or {}
        table.insert(parent.children, node)
        if parent.data.depth == 0 then parent.open = true end
      else
        out[#out + 1] = node
      end
      by_name[name] = node
    end
    return out
  end

  ---@param symbols table[]
  ---@param parent_id string
  ---@param depth integer
  ---@return Filetree.Node[]
  local function walk(symbols, parent_id, depth)
    local out, counts = {}, {}
    for _, symbol in ipairs(symbols) do
      local node = node_of(symbol, id_of(parent_id, symbol.name or "?", counts), bufnr)
      node.data.depth = depth
      if type(symbol.children) == "table" and #symbol.children > 0 then
        node.children = walk(symbol.children, node.id, depth + 1)
        if depth == 0 then node.open = true end
      end
      out[#out + 1] = node
    end
    return out
  end
  return walk(result, root_id, 0)
end

---The innermost symbol a line lies in.
---@param nodes Filetree.Node[]
---@param lnum integer  1-based.
---@return any|nil id
function M.at(nodes, lnum)
  local found = nil
  for _, node in ipairs(nodes) do
    local data = node.data
    if data and lnum >= data.first and lnum <= data.last then
      found = node.id
      if type(node.children) == "table" then found = M.at(node.children, lnum) or found end
      -- symbols of one level do not overlap: the first that holds the line is the one
      break
    end
  end
  return found
end

---The buffer whose symbols a view shows: the editor buffer it belongs to, when it is a file.
---@param ctx Filetree.Ctx
---@return integer|nil
local function buffer_of(ctx)
  local buf = ctx.alt_buf
  if not buf or not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return nil end
  return buf
end

---@param buf integer
---@return boolean
local function has_server(buf)
  return #vim.lsp.get_clients({ bufnr = buf, method = METHOD }) > 0
end

---@type table<integer, Filetree.Node[]>  buffer -> the nodes last answered for it (for `at`)
local last_nodes = {}

local subscriptions = 0

---@return Filetree.Source
function M.source()
  return {
    name = "symbols",
    title = "Symbols",
    available = function()
      local view = require("filetree.native").current()
      local buf = view and view:alt_buf() or nil
      if not buf then return false, "no file in the editor window" end
      if not has_server(buf) then return false, "no language server with document symbols" end
      return true
    end,
    root = function(ctx)
      local buf = buffer_of(ctx)
      local name = buf and vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":t") or ""
      return {
        id = "symbols:root",
        label = name ~= "" and ("Symbols  " .. name) or "Symbols",
        children = function(_, cb)
          if not buf or not api.nvim_buf_is_valid(buf) or not has_server(buf) then
            cb({
              {
                id = "symbols:none",
                label = "no language server with document symbols",
                kind = "note",
              },
            })
            return
          end
          local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
          vim.lsp.buf_request_all(buf, METHOD, params, function(results)
            -- the first server that has symbols: two answers for one file would be two trees
            local answer = nil
            local ids = vim.tbl_keys(results or {})
            table.sort(ids)
            for _, id in ipairs(ids) do
              local got = results[id]
              if got and type(got.result) == "table" and #got.result > 0 then
                answer = got.result
                break
              end
            end
            local nodes = M.nodes(answer, buf)
            last_nodes[buf] = nodes
            if #nodes == 0 then
              nodes = { { id = "symbols:empty", label = "no symbols in this file", kind = "note" } }
            end
            cb(nodes)
          end)
        end,
      }
    end,
    subscribe = function(ctx, emit)
      subscriptions = subscriptions + 1
      local group = api.nvim_create_augroup("filetree_source_symbols_" .. subscriptions, {})
      local alive = true
      local shown = buffer_of(ctx)
      local debounce = require("lib.nvim.debounce")
      local reset = debounce.new(function()
        if alive then emit.reset() end
      end, 300)
      local follow = debounce.new(function()
        if not alive then return end
        local buf = api.nvim_get_current_buf()
        local nodes = last_nodes[buf]
        if buf ~= shown or not nodes then return end
        local id = M.at(nodes, api.nvim_win_get_cursor(0)[1])
        if id ~= nil then emit.focus(id) end
      end, 120)

      ---@param buf integer
      ---@return boolean
      local function is_file(buf)
        return api.nvim_buf_is_valid(buf)
          and vim.bo[buf].buftype == ""
          and require("filetree.native.view").of_buf(buf) == nil
      end

      api.nvim_create_autocmd("BufEnter", {
        group = group,
        desc = "[filetree] The symbols view shows the symbols of the buffer that was entered",
        callback = function(ev)
          if not is_file(ev.buf) or ev.buf == shown then return end
          shown = ev.buf
          reset.call()
        end,
      })
      api.nvim_create_autocmd(
        { "LspAttach", "LspDetach", "BufWritePost", "InsertLeave", "TextChanged" },
        {
          group = group,
          desc = "[filetree] The symbols view asks for the symbols again",
          callback = function(ev)
            if ev.buf == shown then reset.call() end
          end,
        }
      )
      api.nvim_create_autocmd("CursorMoved", {
        group = group,
        desc = "[filetree] The symbols view follows the cursor of the editor",
        callback = function(ev)
          if ev.buf == shown then follow.call() end
        end,
      })
      api.nvim_create_autocmd("BufWipeout", {
        group = group,
        desc = "[filetree] The symbols view forgets the symbols of a buffer that is gone",
        callback = function(ev)
          last_nodes[ev.buf] = nil
        end,
      })
      return function()
        alive = false
        reset.cancel()
        follow.cancel()
        pcall(api.nvim_del_augroup_by_id, group)
      end
    end,
  }
end

return M
