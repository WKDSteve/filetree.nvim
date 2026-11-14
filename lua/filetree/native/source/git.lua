---@module 'filetree.native.source.git'
---@brief The source `git`: the changed files of the repository the view's root lies in, grouped by state.
---@description
--- Written against the source contract only (`Filetree.Source`). The root answers lazily: one
--- `git status` (`lib.nvim.git.status_porcelain_async`), never blocking, and its answer as groups
--- `Conflicts`, `Staged`, `Changes`, `Untracked`. A file that is staged and changed again stands in
--- both groups. Every file node carries its absolute `path`.
---
--- Key responsibilities:
--- - `groups(map, repo, root)`: pure, a status map to group nodes (specs call it without a repository)
--- - `subscribe`: ask again after a write, on focus, after a file operation and when files came or went
---
--- A root outside a repository and a failed `git status` show one line that says so.

local list = require("filetree.native.fs.list")

local api = vim.api

local M = {}

---@type { key: string, label: string }[]
local GROUPS = {
  { key = "conflicts", label = "Conflicts" },
  { key = "staged", label = "Staged" },
  { key = "changes", label = "Changes" },
  { key = "untracked", label = "Untracked" },
}

---@type table<string, string>  One letter of an XY code -> the status of the node.
local STATUS =
  { M = "modified", T = "modified", A = "added", D = "deleted", R = "renamed", C = "renamed" }

--- Worst first: what the head of a group and of the view add up to.
M.SEVERITY = { "conflict", "deleted", "modified", "renamed", "added", "untracked" }

---The groups one XY code puts a file in.
---@param code string  Two characters, e.g. " M", "MM", "??", "UU".
---@return { group: string, letter: string, status: string }[]
function M.classify(code)
  local x, y = code:sub(1, 1), code:sub(2, 2)
  if code:find("U", 1, true) or code == "AA" or code == "DD" then
    return { { group = "conflicts", letter = "!", status = "conflict" } }
  end
  if x == "?" then return { { group = "untracked", letter = "?", status = "untracked" } } end
  if x == "!" then return {} end
  local out = {}
  if x ~= " " and x ~= "" then
    out[#out + 1] = { group = "staged", letter = x, status = STATUS[x] or "modified" }
  end
  if y ~= " " and y ~= "" then
    out[#out + 1] = { group = "changes", letter = y, status = STATUS[y] or "modified" }
  end
  return out
end

---@param id string
---@param label string
---@return Filetree.Node
local function note(id, label)
  return { id = id, label = label, kind = "note" }
end

---The repository a directory lies in, found without a process.
---@param dir string
---@return string|nil
function M.repo_of(dir)
  local found = vim.fs.find(".git", { upward = true, path = dir, limit = 1 })[1]
  return found and list.norm(vim.fs.dirname(found)) or nil
end

---A status map as the nodes below the root: one group per state that has files, the files by name.
---@param map table<string, { code: string, orig_path?: string }>  Paths relative to `repo`.
---@param repo string  Normalized root of the repository.
---@param root string  The root directory of the view; a file below it is named relative to it.
---@return Filetree.Node[]
function M.groups(map, repo, root)
  local prefix = list.join(root, "")
  ---@type table<string, Filetree.Node[]>
  local by_group = {}
  for rel, entry in pairs(map) do
    local path = list.norm(repo .. "/" .. rel)
    local label = (path:sub(1, #prefix) == prefix and #path > #prefix) and path:sub(#prefix + 1)
      or rel
    for _, state in ipairs(M.classify(entry.code or "")) do
      by_group[state.group] = by_group[state.group] or {}
      table.insert(by_group[state.group], {
        id = ("git:%s:%s"):format(state.group, path),
        label = label,
        kind = "file",
        path = path,
        status = state.status,
        columns = { state.letter },
        data = { git = { group = state.group, code = entry.code, orig_path = entry.orig_path } },
      })
    end
  end
  local out = {}
  for _, group in ipairs(GROUPS) do
    local files = by_group[group.key]
    if files then
      table.sort(files, function(a, b)
        local la, lb = a.label:lower(), b.label:lower()
        if la ~= lb then return la < lb end
        return a.label < b.label
      end)
      out[#out + 1] = {
        id = "git:" .. group.key,
        label = group.label,
        kind = "group",
        open = true,
        columns = { tostring(#files) },
        children = files,
      }
    end
  end
  if #out == 0 then out[1] = note("git:clean", "nothing changed") end
  return out
end

local subscriptions = 0

---@return Filetree.Source
function M.source()
  return {
    name = "git",
    title = "Git",
    severity = M.SEVERITY,
    available = function()
      if vim.fn.executable("git") == 1 then return true end
      return false, "git is not on PATH"
    end,
    root = function(ctx)
      return {
        id = "git:root",
        label = "Git",
        children = function(_, cb)
          local repo = M.repo_of(ctx.root)
          if not repo then
            cb({ note("git:none", "not a git repository") })
            return
          end
          require("lib.nvim.git").status_porcelain_async({ dir = repo }, function(map, err)
            if not map then
              cb({ note("git:failed", "git status failed: " .. tostring(err or "unknown")) })
              return
            end
            cb(M.groups(map, repo, ctx.root))
          end)
        end,
      }
    end,
    subscribe = function(_, emit)
      subscriptions = subscriptions + 1
      local group = api.nvim_create_augroup("filetree_source_git_" .. subscriptions, {})
      local alive = true
      local debounce = require("lib.nvim.debounce").new(function()
        if alive then emit.reset() end
      end, 200)
      api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
        group = group,
        desc = "[filetree] The git view asks for the status again",
        callback = function()
          debounce.call()
        end,
      })
      api.nvim_create_autocmd("User", {
        group = group,
        pattern = {
          "FiletreeChanged",
          "GitsuiteBranchSwitched",
          "GitsuiteConflictsResolved",
          "GitsuiteIndexChanged",
        },
        desc = "[filetree] The git view asks for the status again",
        callback = function()
          debounce.call()
        end,
      })
      api.nvim_create_autocmd("User", {
        group = group,
        pattern = "FiletreeFsChanged",
        desc = "[filetree] The git view asks for the status again when files came or went",
        callback = function(ev)
          for _, dir in ipairs((ev.data and ev.data.dirs) or {}) do
            -- `git status` may write the index itself: answering that with another one would never end
            if not (dir .. "/"):find("/.git/", 1, true) then
              debounce.call()
              return
            end
          end
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
