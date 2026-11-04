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
        local message = state == "skipped" and "Already installed by Mason" or "Installed by Mason"
        if not (spec.post_install or spec.post_install_async) then
          return ctx.done(state, message)
        end
        ctx.log("Running " .. (spec.post_install_async and "asynchronous " or "") .. "post_install hook")
        local finished = false
        local function finish(err)
          if finished then
            return
          end
          finished = true
          -- A hook may report completion from a vim.system/libuv callback.
          vim.schedule(function()
            if err ~= nil then
              ctx.done("failed", "post_install failed: " .. tostring(err))
            else
              ctx.done(state, message)
            end
          end)
        end
        local hook_ok, hook_err
        if spec.post_install_async then
          hook_ok, hook_err = pcall(spec.post_install_async, package, finish, ctx.log)
        else
          hook_ok, hook_err = pcall(spec.post_install, package)
        end
        if not hook_ok then
          finish(hook_err or "hook raised an error")
        elseif not spec.post_install_async then
          finish()
        end
      end
      if package:is_installed() then
        complete("skipped")
        return
      end
      local installation_finished = false
      local handle = package:install({}, function(installed, receipt_or_error)
        if installation_finished then
          return
        end
        installation_finished = true
        vim.schedule(function()
          if installed then
            complete("installed")
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
