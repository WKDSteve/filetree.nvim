---@module 'filetree.native.fs.deep'
---@brief Every file below a folder, as a stream: for a search that reaches folders the tree never opened.
---@description
--- The tree reads a folder when it is opened; a search has to look into all of them. This module lists
--- the files below a root in batches, with the fastest tool the machine has, and can be stopped. The
--- work is done by `lib.nvim.fs.fast.list` (shared with every plugin); this module keeps the tree's
--- rules for it.
---
--- Key responsibilities:
--- - `files(root, on_batch, on_done, opts)`: paths (normalized) in batches on the main loop; returns `cancel`
--- - Four tiers behind one call: the helper process (`lib.nvim.fs.helper`, set up by
---   `filetree.native.fs.helper`), `fd`, `rg --files`, else a walk with `uv.fs_scandir`
--- - `tier()`: which one this machine uses, for `:checkhealth`
--- - `resolve(path)`: the program behind a scoop shim; `running()`: tools that have not ended
---
--- `.git` is never entered. The helper, `fd` and `rg` leave out what `.gitignore` names; the walk leaves
--- out the names of the tree's ignore list (`filetree.util.ignore`), which is the nearest thing it has.
--- A cancelled listing calls nothing more. A helper that ends during a listing hands it to the next
--- tier, which leaves out what the helper had handed over already.
---
--- Links: a link to a file (and a link whose target is gone) is listed like a file, a link to a folder
--- is neither listed nor followed. `rg --files` cannot list a link without following it: on a machine
--- that has `rg` and no `fd`, links are not found.

-- the tree's option `native.fs.helper` reaches lib.nvim's client through this module
require("filetree.native.fs.helper")

local fast = require("lib.nvim.fs.fast")

local M = {}

--- How many paths the walk hands over at most (the tools have no such limit: they stream).
M.WALK_LIMIT = fast.WALK_LIMIT

---@alias Filetree.Fs.Deep.Tier Lib.Fs.Fast.Tier

M.resolve = fast.resolve
M.running = fast.running

---Which tier lists files on this machine.
---@return Filetree.Fs.Deep.Tier tier
---@return string|nil exe
function M.tier()
  return fast.tier()
end

---List every file below `root`.
---@param root string  Normalized.
---@param on_batch fun(paths: string[])  Normalized absolute paths, in the order they are found.
---@param on_done fun(ok: boolean)  Called once, after the last batch; false when the tool failed or the walk hit its limit.
---@param opts? { tier?: Filetree.Fs.Deep.Tier }  Force a tier (specs); default: `tier()`.
---@return fun() cancel  After it nothing more is called.
function M.files(root, on_batch, on_done, opts)
  local ignored = require("filetree.util.ignore").predicate()
  return fast.list(root, {
    tier = opts and opts.tier or nil,
    skip = function(name)
      return ignored(name)
    end,
  }, on_batch, on_done)
end

return M
