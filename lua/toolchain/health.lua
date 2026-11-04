local M = {}

function M.check()
  vim.health.start("toolchain-tools")
  local ok, plan = pcall(require("toolchain").plan)
  if not ok then
    vim.health.error("Invalid requirements: " .. tostring(plan))
    return
  end
  vim.health.ok("Configured requirements: " .. #plan)
  local needed = {}
  for _, entry in ipairs(plan) do
    if entry.state == "failed" or entry.state == "missing" then
      vim.health.warn(entry.id .. ": " .. entry.message)
    elseif entry.state == "unavailable" then
      vim.health.info(entry.id .. ": " .. entry.message)
    elseif entry.state == "check" then
      needed[entry.provider] = true
    end
  end
  for provider in pairs(needed) do
    if provider == "parser" then
      vim.health.info("Independent parsers use git, tree-sitter CLI and a C compiler; no nvim-treesitter API is used")
    else
      local module = provider == "mason" and "mason" or "nvim-treesitter"
      if #vim.api.nvim_get_runtime_file("lua/" .. module .. "/init.lua", false) == 0 then
        vim.health.warn(module .. " is not on runtimepath (it may need to be loaded by your plugin manager)")
      else
        vim.health.ok(module .. " is on runtimepath; backend checks run only on explicit installation")
      end
    end
  end
  vim.health.info("Plans and health checks never refresh registries or install packages")
  vim.health.info("Concurrency bounds toolchain tasks; backends may spawn additional processes")
end

return M
