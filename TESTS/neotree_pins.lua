-- TESTS/neotree_pins.lua -- the neo-tree, nui and plenary commits CI pins, for the real-neo-tree
-- suites (adapter_lines.lua, collapse_all_backends.lua, ...). Not a spec: they `dofile` it.
--
-- Their checks lean on neo-tree internals (per-tab states, placeholder states, window handling)
-- that change between neo-tree versions: against an older neo-tree found in some editor's lazy
-- directory (a WSL checkout from May 2026 made `filter-tab` red), a gated suite would report a
-- difference between versions as a bug. So a checkout the suites FIND by themselves is used only
-- when it is at the commit CI pins; one named explicitly ($NEO_TREE_NVIM_DIR, $FILETREE_NEOTREE)
-- is used as it is. The pins are read from .github/workflows/ci.yml (the steps
-- `repository: <owner>/<name>` + `ref: <sha>`), so the workflow stays their one source.

local M = {}

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))

---@param path string
---@return string? line The first line of a readable file.
local function first_line(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  return vim.fn.readfile(path, "", 1)[1]
end

---name ("neo-tree.nvim") -> the 40-hex commit CI checks it out at.
---@return table<string, string>
function M.pins()
  local pins = {}
  local file = root .. "/.github/workflows/ci.yml"
  if vim.fn.filereadable(file) ~= 1 then return pins end
  local repo
  for _, line in ipairs(vim.fn.readfile(file)) do
    -- a new step: the repository of the step before never takes this step's ref
    if line:match("^%s*%-%s") then repo = nil end
    repo = line:match("repository:%s*[\"']?[%w_.-]+/([%w_.-]+)") or repo
    local sha = line:match("^%s*ref:%s*[\"']?(%x+)")
    if repo and sha and #sha == 40 then pins[repo] = sha:lower() end
  end
  return pins
end

---The commit a git checkout is at, read from its files (no `git` process), or nil.
---@param dir string
---@return string?
function M.head(dir)
  local git = dir .. "/.git"
  local link = first_line(git)
  if link then
    -- a linked worktree or a submodule: `.git` is a file naming the real git directory
    local target = link:match("^gitdir:%s*(.-)%s*$")
    if not target then return nil end
    if not (target:match("^/") or target:match("^%a:")) then target = dir .. "/" .. target end
    git = vim.fs.normalize(target)
  end
  local head = first_line(git .. "/HEAD")
  if not head then return nil end
  local ref = head:match("^ref:%s*(.-)%s*$")
  if not ref then return head:match("^(%x+)%s*$") end
  local common = git
  local cd = first_line(git .. "/commondir")
  if cd then
    common = vim.fs.normalize((cd:match("^/") or cd:match("^%a:")) and cd or (git .. "/" .. cd))
  end
  for _, base in ipairs({ git, common }) do
    local sha = first_line(base .. "/" .. ref)
    if sha then return sha:match("^(%x+)") end
  end
  for _, base in ipairs({ git, common }) do
    local packed = base .. "/packed-refs"
    if vim.fn.filereadable(packed) == 1 then
      for _, line in ipairs(vim.fn.readfile(packed)) do
        local sha, name = line:match("^(%x+)%s+(%S+)$")
        if name == ref then return sha end
      end
    end
  end
  return nil
end

---Why the checkout `dir` of `name` found on its own is not used, or nil when it is (no pin for
---`name`, the pinned commit, or a commit that cannot be read).
---@param name string
---@param dir string
---@param pins? table<string, string> Default `M.pins()`.
---@return string? why
function M.off_pin(name, dir, pins)
  local pin = (pins or M.pins())[name]
  if not pin then return nil end
  local sha = M.head(dir)
  if not sha or sha:lower() == pin then return nil end
  return ("%s is %s at %s, not at the commit CI pins (%s); not used -- put the pinned checkout in .deps/%s or name one in $%s"):format(
    dir,
    name,
    sha:sub(1, 8),
    pin:sub(1, 8),
    name,
    (name:upper():gsub("[^%w]", "_")) .. "_DIR"
  )
end

return M
