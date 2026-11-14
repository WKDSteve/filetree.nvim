---@module 'filetree.util.other_view'
---@brief The view the tree shows when it is not the files.
---@description
--- The own tree shows views of other sources in the same window (buffers, git, symbols, diagnostics,
--- what plugins register). A feature that acts on the listing of the files -- the filter, the sort --
--- has nothing to act on there and says so instead of looking as if it had worked.
---
---   local view = require("filetree.util.other_view")(adapter)
---   if view then notify.info(("nothing to filter in the view %q"):format(view)) return end
---
--- Every other backend has one view: nil there.

---@param adapter FiletreeAdapter?
---@return string?  The name of the view on screen ("buffers", "git", ...), nil while the files are shown.
return function(adapter)
  if not adapter or adapter.name ~= "native" or type(adapter.get_state) ~= "function" then
    return nil
  end
  local ok, view = pcall(adapter.get_state)
  if not ok or type(view) ~= "table" then return nil end
  local name = view.view_name
  if type(name) ~= "string" or name == "" or name == "files" then return nil end
  return name
end
