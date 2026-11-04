local M = {}
local util = require("toolchain.parser_util")

function M.names(store)
  local result, directory = {}, store .. "/versions"
  if vim.fn.isdirectory(directory) == 0 then
    return result
  end
  for name, kind in vim.fs.dir(directory) do
    if kind == "directory" and name:match("^[%w_][%w_.+-]*$") then
      for id, child in vim.fs.dir(directory .. "/" .. name) do
        if child == "directory" and id:match("^[a-f0-9]+%-%d+%-%d+$") then
          result[#result + 1] = name
          break
        end
      end
    end
  end
  table.sort(result)
  return result
end

function M.list(store, selected, fingerprint, consistent)
  local directory = store .. "/versions"
  local result = {}
  local protection = require("toolchain.tool_sessions").protection(store)
  if vim.fn.isdirectory(directory) == 0 then
    return result
  end
  for name, kind in vim.fs.dir(directory) do
    if kind == "directory" and name:match("^[%w_][%w_.+-]*$") and (not selected or selected == name) then
      local pointer_path = store .. "/current/" .. name .. ".json"
      local current = util.json(pointer_path)
      local unknown_current = vim.uv.fs_stat(pointer_path)
        and (not current or type(current.version) ~= "string" or not current.version:match("^[a-f0-9]+%-%d+%-%d+$"))
      local lock_path = store .. "/locks/" .. name .. ".lock"
      local lock = util.json(lock_path)
      local building = vim.uv.fs_stat(lock_path)
        and (not lock or require("toolchain.tool_sessions").alive(lock.pid) ~= false)
      for id, entry_kind in vim.fs.dir(directory .. "/" .. name) do
        if entry_kind == "directory" and id:match("^[a-f0-9]+%-%d+%-%d+$") then
          local root = directory .. "/" .. name .. "/" .. id
          local receipt = util.json(root .. "/receipt.json")
          local recorded = consistent(receipt, name)
          local active = current and current.version == id or false
          local reasons = {}
          if unknown_current then
            reasons[#reasons + 1] = "unverified current pointer"
          end
          if active then
            reasons[#reasons + 1] = "current"
          end
          if protection.roots[name .. "/" .. id] then
            reasons[#reasons + 1] = "live session"
          end
          if protection.uncertain then
            reasons[#reasons + 1] = "unverified session metadata"
          end
          if building then
            reasons[#reasons + 1] = "installation lock"
          end
          local stat = vim.uv.fs_stat(root)
          result[#result + 1] = {
            name = name,
            id = id,
            root = root,
            version = recorded and receipt.version or "unknown",
            current = active,
            recorded = not not recorded,
            compatible = recorded and fingerprint(receipt.recipe) == receipt.fingerprint or false,
            state = active and "current" or #reasons > 0 and "protected" or recorded and "retired" or "incomplete",
            protected = #reasons > 0,
            reasons = reasons,
            candidate = #reasons == 0,
            created = stat and stat.mtime.sec or 0,
          }
        end
      end
    end
  end
  table.sort(result, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    if a.created ~= b.created then
      return a.created > b.created
    end
    return a.id > b.id
  end)
  return result
end

return M
