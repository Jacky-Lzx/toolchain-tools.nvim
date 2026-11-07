local M = {}

function M.check()
  vim.health.start("toolchain-tools.nvim")
  if vim.fn.has("nvim-0.11") == 0 then
    vim.health.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local plugin = package.loaded.toolchain
  if not plugin or not plugin.configured() then
    vim.health.info("Not configured; toolchain checks skipped.")
    return
  end
  local ok, plan = pcall(plugin.plan)
  if not ok then
    problem("error", "Invalid requirements: " .. tostring(plan), { "Correct toolchain requirements" })
  else
    local deferred = false
    for _, entry in ipairs(plan) do
      if entry.state == "check" then
        deferred = true
      end
      if entry.state == "failed" or entry.state == "missing" then
        problem(
          "warn",
          entry.id .. ": " .. entry.message,
          { "Inspect :ToolchainPlan and run :ToolchainInstall for required tools" }
        )
      end
    end
    if deferred and #issues == 0 then
      vim.health.info("Declarations are valid; backend installation checks are deferred. Details: :ToolchainPlan")
      return
    end
  end

  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == "error"
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Declared toolchain requirements have no known failures.")
  end
  vim.health.info("Details: :ToolchainPlan")
end

return M
