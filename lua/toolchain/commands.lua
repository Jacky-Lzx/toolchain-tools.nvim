local M = {}

function M.setup()
  local function guarded(fn)
    return function(args)
      local ok, err = pcall(fn, args)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "toolchain-tools" })
      end
    end
  end
  local function completion(prefix)
    local result = {}
    for _, entry in ipairs(require("toolchain").plan()) do
      if vim.startswith(entry.id, prefix) then
        result[#result + 1] = entry.id
      end
    end
    return result
  end
  local function command(name, fn, opts)
    vim.api.nvim_create_user_command(name, guarded(fn), vim.tbl_extend("force", { force = true }, opts or {}))
  end
  command("Toolchain", function()
    require("toolchain").open()
  end, { desc = "Show toolchain installation tasks" })
  command("ToolchainPlan", function()
    require("toolchain.ui").open(true)
  end, { desc = "Inspect configured requirements without downloading" })
  command("ToolchainInstall", function(args)
    local toolchain = require("toolchain")
    if #args.fargs == 0 then
      toolchain.install()
    else
      -- Pass IDs through the public selector; configuration is resolved once there.
      toolchain.install_ids(args.fargs)
    end
  end, { nargs = "*", complete = completion, desc = "Install configured parsers and tools" })
  command("ToolchainRetry", function(args)
    require("toolchain").retry(#args.fargs > 0 and args.fargs or nil)
  end, { nargs = "*", complete = completion, desc = "Retry failed or cancelled installation tasks" })
  command("ToolchainCancel", function(args)
    local ok, err = require("toolchain").cancel(args.args)
    assert(ok, err)
  end, { nargs = 1, complete = completion, desc = "Cancel an installation that has not started" })
  command("ToolchainLog", function()
    local path = require("toolchain").log_file()
    assert(path, "Persistent logging is disabled")
    assert(vim.fn.filereadable(path) == 1, "No installation log has been written yet")
    local lines = vim.fn.readfile(path)
    vim.cmd("new")
    vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile = "nofile", "wipe", false
    vim.bo.filetype = "json"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.modifiable = false
  end, { desc = "Open the persistent toolchain log" })
end

return M
