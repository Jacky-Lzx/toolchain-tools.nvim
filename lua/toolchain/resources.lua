local M = {}
function M.npm_package(executable, package)
  local exe = vim.fn.exepath(executable)
  if exe == "" then
    return
  end
  local directory = vim.fs.dirname(vim.fn.resolve(exe))
  while directory and directory ~= "" do
    local nested = directory .. "/node_modules/" .. package
    if vim.uv.fs_stat(nested) then
      return nested
    end
    if directory:sub(-#("/" .. package)) == "/" .. package and vim.uv.fs_stat(directory) then
      return directory
    end
    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
end
function M.resolve(name, resource)
  local tools = require("toolchain.tools")
  -- System package layouts belong to the registry, independently of tool locks.
  local recipe = tools.definition(name, true)
  local external = recipe.external_resources and recipe.external_resources[resource]
  if external then
    local path = M.npm_package(external.executable, external.package)
    if path then
      return path
    end
  end
  return tools.path(name, resource)
end
return M
