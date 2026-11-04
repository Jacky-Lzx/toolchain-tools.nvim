local M = {}
local waiting

local function refresh(registry, callback)
  if waiting then
    waiting[#waiting + 1] = callback
    return
  end
  waiting = { callback }
  local completed = false
  local function finish(ok, result)
    if completed then
      return
    end
    completed = true
    local callbacks = waiting
    waiting = nil
    for _, cb in ipairs(callbacks) do
      vim.schedule(function()
        cb(ok, result)
      end)
    end
  end
  local ok, err = pcall(registry.refresh, finish)
  if not ok then
    finish(false, err)
  end
end

function M.install(spec, ctx)
  local ok, mason = pcall(require, "mason")
  if not ok then
    return ctx.done("failed", "mason.nvim is unavailable; install and configure it before using the Mason backend")
  end
  if not mason.has_setup then
    return ctx.done("failed", "mason.nvim has not been configured; call require('mason').setup() first")
  end
  local registry = require("mason-registry")
  ctx.log("Refreshing Mason package metadata")
  refresh(registry, function(success, result)
    local function run()
      assert(success, "Mason registry refresh failed: " .. vim.inspect(result))
      local package = registry.get_package(spec.name)
      assert(not package:is_installing(), "Package is already installing outside toolchain-tools; retry later")
      local function complete(state)
        if spec.post_install then
          ctx.log("Running post_install hook")
          spec.post_install(package)
        end
        ctx.done(state, state == "skipped" and "Already installed by Mason" or "Installed by Mason")
      end
      if package:is_installed() then
        complete("skipped")
        return
      end
      local handle = package:install({}, function(installed, receipt_or_error)
        vim.schedule(function()
          if installed then
            local hook_ok, hook_err = pcall(complete, "installed")
            if not hook_ok then
              ctx.done("failed", "post_install failed: " .. tostring(hook_err))
            end
          else
            ctx.done("failed", "Mason installation failed: " .. tostring(receipt_or_error))
          end
        end)
      end)
      handle:on("stdout", ctx.log)
      handle:on("stderr", ctx.log)
    end
    local ran, err = pcall(run)
    if not ran then
      ctx.done("failed", tostring(err))
    end
  end)
end

return M
