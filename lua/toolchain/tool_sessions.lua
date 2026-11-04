local M = {}
local util = require("toolchain.parser_util")
local uv = vim.uv
local token = string.format("%d-%.0f", uv.os_getpid(), uv.hrtime())
local stores, registered = {}, false

function M.alive(pid)
  if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then
    return nil
  end
  local called, alive, reason = pcall(uv.kill, pid, 0)
  if not called then
    return nil
  end
  if alive then
    return true
  end
  if tostring(reason):find("ESRCH", 1, true) then
    return false
  end
end

function M.record(store, roots)
  if #roots == 0 then
    return true
  end
  local state = stores[store] or { file = store .. "/sessions/" .. token .. ".json", roots = {} }
  stores[store] = state
  local changed = not uv.fs_stat(state.file)
  for _, root in ipairs(roots) do
    local relative = root:sub(#store + #"/versions/" + 1)
    assert(vim.startswith(root, store .. "/versions/"), "Session root is outside the tool store")
    if not state.roots[relative] then
      state.roots[relative], changed = true, true
    end
  end
  if not registered then
    registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        for _, lease in pairs(stores) do
          uv.fs_unlink(lease.file)
        end
      end,
    })
  end
  if not changed and not state.unrecorded then
    return true
  end
  local ok, err = pcall(function()
    vim.fn.mkdir(store .. "/sessions", "p")
    local versions = vim.tbl_keys(state.roots)
    table.sort(versions)
    util.write_json(state.file .. ".tmp", { schema = 1, pid = uv.os_getpid(), versions = versions })
    assert(uv.fs_rename(state.file .. ".tmp", state.file))
  end)
  state.unrecorded = not ok
  if not ok then
    uv.fs_unlink(state.file .. ".tmp")
  end
  if ok then
    state.reported = nil
    return true
  end
  local report = not state.reported and err or nil
  state.reported = true
  return false, report
end

function M.protection(store)
  local result = { roots = {}, uncertain = false, active = 0, stale = 0, errors = {} }
  local local_state = stores[store]
  if local_state and local_state.unrecorded then
    result.uncertain = true
    for root in pairs(local_state.roots) do
      result.roots[root] = true
    end
  end
  local directory = store .. "/sessions"
  if vim.fn.isdirectory(directory) == 0 then
    return result
  end
  local ok, err = pcall(function()
    for file, kind in vim.fs.dir(directory) do
      if file:match("%.json$") then
        local entry = kind == "file" and util.json(directory .. "/" .. file) or nil
        local alive = entry and M.alive(entry.pid)
        if alive == false then
          result.stale = result.stale + 1
        elseif
          not entry
          or entry.schema ~= 1
          or type(entry.versions) ~= "table"
          or not vim.islist(entry.versions)
          or #entry.versions == 0
          or alive == nil
        then
          result.uncertain = true
          result.errors[#result.errors + 1] = file
        else
          result.active = result.active + 1
          for _, root in ipairs(entry.versions) do
            if type(root) == "string" and root:match("^[%w_][%w_.+-]*/[a-f0-9]+%-%d+%-%d+$") then
              result.roots[root] = true
            else
              result.uncertain = true
              result.errors[#result.errors + 1] = file
            end
          end
        end
      end
    end
  end)
  if not ok then
    result.uncertain = true
    result.errors[#result.errors + 1] = tostring(err)
  end
  return result
end

return M
