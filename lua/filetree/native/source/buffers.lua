---@module 'filetree.native.source.buffers'
---@brief The source `buffers`: the listed buffers and the terminals, as one flat list.
---@description
--- Written against the source contract only (`Filetree.Source`): `root` answers the list as it is now,
--- `subscribe` follows the buffer list and asks the view to read it again.
---
--- Key responsibilities:
--- - A file buffer is a node with a `path`: every file action and path decorator applies to it
--- - A terminal and an unnamed buffer are nodes without one; `data.bufnr` is what opens them
--- - `buffers.delete` (`dd`): delete the buffer, the windows that show it keep their place
---
--- The tree's own buffers and other special buffers (help, quickfix, prompts) are left out.

local list = require("filetree.native.fs.list")
local notify = require("filetree.util.notify").create("[filetree.native]")

local api = vim.api

local M = {}

---@param path string  Normalized.
---@param root string
---@return string
local function label_of(path, root)
  local prefix = list.join(root, "")
  if path:sub(1, #prefix) == prefix and #path > #prefix then return path:sub(#prefix + 1) end
  return (vim.fn.fnamemodify(path, ":~"):gsub("\\", "/"))
end

---The buffers as nodes: files first, by name; then unnamed buffers; then terminals.
---@param root string  The root directory of the view; a file below it is named relative to it.
---@return Filetree.Node[]
function M.nodes(root)
  local files, unnamed, terminals = {}, {}, {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) then
      local buftype = vim.bo[buf].buftype
      local name = api.nvim_buf_get_name(buf)
      if buftype == "terminal" then
        local title = vim.b[buf].term_title
        terminals[#terminals + 1] = {
          id = "buffers:" .. buf,
          label = (type(title) == "string" and title ~= "") and title or name,
          kind = "terminal",
          data = { bufnr = buf },
        }
      elseif buftype == "" and vim.bo[buf].buflisted then
        local modified = vim.bo[buf].modified
        if name == "" then
          unnamed[#unnamed + 1] = {
            id = "buffers:" .. buf,
            label = "[No Name]",
            kind = "buffer",
            status = modified and "modified" or nil,
            data = { bufnr = buf },
          }
        else
          local path = list.norm(name)
          files[#files + 1] = {
            id = "buffers:" .. buf,
            label = label_of(path, root),
            kind = "buffer",
            path = path,
            status = modified and "modified" or nil,
            data = { bufnr = buf },
          }
        end
      end
    end
  end
  table.sort(files, function(a, b)
    local la, lb = a.label:lower(), b.label:lower()
    if la ~= lb then return la < lb end
    return a.id < b.id
  end)
  return vim.list_extend(vim.list_extend(files, unnamed), terminals)
end

---Delete a buffer. A window that shows it shows its alternate buffer instead (an empty one when it
---has none), so no window closes. A modified file buffer is kept and named.
---@param buf integer
---@return boolean deleted
function M.delete(buf)
  if not api.nvim_buf_is_valid(buf) then return false end
  local terminal = vim.bo[buf].buftype == "terminal"
  if not terminal and vim.bo[buf].modified then
    local name = api.nvim_buf_get_name(buf)
    notify.info(
      ("%s has unsaved changes: write it first"):format(
        name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
      )
    )
    return false
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(api.nvim_win_call, win, function()
      local alt = vim.fn.bufnr("#")
      if alt > 0 and alt ~= buf and api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
        vim.cmd("buffer " .. alt)
      else
        vim.cmd("enew")
      end
    end)
  end
  -- a terminal's job is still running: only force ends it
  return (pcall(api.nvim_buf_delete, buf, { force = terminal }))
end

local subscriptions = 0

---@return Filetree.Source
function M.source()
  return {
    name = "buffers",
    title = "Buffers",
    severity = { "modified" },
    root = function(ctx)
      local nodes = M.nodes(ctx.root)
      return {
        id = "buffers:root",
        label = "Buffers",
        columns = { tostring(#nodes) },
        children = nodes,
      }
    end,
    subscribe = function(_, emit)
      subscriptions = subscriptions + 1
      local group = api.nvim_create_augroup("filetree_source_buffers_" .. subscriptions, {})
      local alive, pending = true, false
      api.nvim_create_autocmd({
        "BufAdd",
        "BufDelete",
        "BufWipeout",
        "BufFilePost",
        "BufModifiedSet",
        "BufWritePost",
        "TermOpen",
        "TermClose",
      }, {
        group = group,
        desc = "[filetree] The buffers view reads the buffer list again",
        callback = function()
          -- once per tick, and after the event: a buffer being deleted is still listed while it fires
          if pending then return end
          pending = true
          vim.schedule(function()
            pending = false
            if alive then emit.reset() end
          end)
        end,
      })
      return function()
        alive = false
        pcall(api.nvim_del_augroup_by_id, group)
      end
    end,
    actions = {
      {
        name = "buffers.delete",
        key = "dd",
        desc = "Delete the buffer",
        when = function(node)
          return type(node.data) == "table" and type(node.data.bufnr) == "number"
        end,
        run = function(nodes)
          for _, node in ipairs(nodes) do
            M.delete(node.data.bufnr)
          end
        end,
      },
    },
  }
end

return M
