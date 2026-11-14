---@module 'filetree.util.hooks'
---@brief Emit a `hooks_api` event from a feature, whether or not the bus is on.

local M = {}

---Emit `event` on the `hooks_api` bus. A no-op (returns 0) while that feature
---is disabled or not loaded, and never raises: a feature must not fail because a
---subscriber (or the bus itself) misbehaved.
---@param event string  e.g. `before_delete`, see `filetree.features.infra.hooks_api`
---@param data? table
---@return integer called  Number of handlers called.
function M.emit(event, data)
  -- a copy or a delete that is done is also announced to whoever shows files (`User FiletreeChanged`);
  -- moves are announced by `util.mutate`, which every move goes through
  if type(data) == "table" and data.ok then
    if event == "after_copy" then
      require("filetree.util.changed").emit("copy", data.src, data.dst)
    elseif event == "after_delete" then
      require("filetree.util.changed").emit("delete", data.path, nil)
    end
  end
  local ok, ft = pcall(require, "filetree")
  if not ok or type(ft.feature) ~= "function" then return 0 end
  local bus = ft.feature("hooks_api")
  if not bus or type(bus.emit) ~= "function" then return 0 end
  local good, called = pcall(bus.emit, event, data)
  return good and called or 0
end

return M
