local M = {}

function M.install(spec, ctx)
  local ok, ts = pcall(require, "nvim-treesitter")
  if not ok or type(ts.install) ~= "function" or type(ts.get_installed) ~= "function" then
    return ctx.done("failed", "nvim-treesitter main API is required (the legacy master branch is unsupported)")
  end
  assert(vim.list_contains(ts.get_available(), spec.name), "Unknown Tree-sitter parser: " .. spec.name)
  if vim.list_contains(ts.get_installed("parsers"), spec.name) then
    return ctx.done("skipped", "Parser already installed in the nvim-treesitter install directory")
  end
  ctx.log("Installing parser and queries with nvim-treesitter; details: :TSLog")
  -- Force repairs queries-only installs that upstream's combined installed list
  -- would otherwise treat as complete. One job also bounds implicit dependencies.
  local task = ts.install({ spec.name }, { max_jobs = 1, force = true, summary = false })
  assert(task and type(task.await) == "function", "nvim-treesitter did not return an asynchronous task")
  task:await(function(err, success)
    vim.schedule(function()
      local checked, installed = pcall(function()
        return vim.list_contains(ts.get_installed("parsers"), spec.name)
      end)
      if err or success ~= true or not checked or not installed then
        ctx.done("failed", "Tree-sitter installation failed: " .. tostring(err or "see :TSLog for build output"))
      else
        ctx.done("installed", "Installed parser and queries with nvim-treesitter")
      end
    end)
  end)
end

return M
