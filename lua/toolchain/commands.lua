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
    require("toolchain.user_command").create(name, guarded(fn), vim.tbl_extend("force", { force = true }, opts or {}))
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
  command(
    "ToolchainUninstall",
    function(args)
      local name = args.args:match("^tool:([%w_][%w_.+-]*)$")
      assert(name, "Expected tool:<package>; only independent tools can be removed")
      require("toolchain.tools").remove(name)
    end,
    { nargs = 1, complete = completion, desc = "Deactivate an independent tool, retaining files for running processes" }
  )
  command("ToolchainLock", function(args)
    require("toolchain").lock(args.fargs[1], args.bang)
  end, {
    nargs = "?",
    bang = true,
    complete = "file",
    desc = "Export a portable tool lock; ! resolves configured recipes explicitly",
  })
  local function tool_name(value)
    if not value or value == "" then
      return
    end
    return assert(value:match("^tool:([%w_][%w_.+-]*)$"), "Expected tool:<package>")
  end
  local function version_completion(prefix, line)
    local selected = line:match("ToolchainRollback%s+tool:([%w_][%w_.+-]*)%s+")
    local items = {}
    local tools = require("toolchain.tools")
    if selected then
      for _, entry in ipairs(tools.versions(selected)) do
        if entry.recorded and entry.compatible and vim.startswith(entry.id, prefix) then
          items[#items + 1] = entry.id
        end
      end
    else
      for _, name in ipairs(tools.packages()) do
        if vim.startswith("tool:" .. name, prefix) then
          items[#items + 1] = "tool:" .. name
        end
      end
    end
    return items
  end
  local function versions(args, prune)
    local tools = require("toolchain.tools")
    local entries = (prune and tools.prune_plan or tools.versions)(tool_name(args.fargs[1]))
    local lines = { prune and "Toolchain prune preview (read-only)" or "Installed tool versions", "" }
    for _, entry in ipairs(entries) do
      lines[#lines + 1] = string.format(
        "%s  %s  %s  [%s]%s",
        entry.name,
        entry.version,
        entry.id,
        prune and (entry.candidate and "candidate" or "keep") or entry.state,
        #entry.reasons > 0 and "  " .. table.concat(entry.reasons, ", ") or ""
      )
    end
    if #entries == 0 then
      lines[#lines + 1] = "No managed versions"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = prune
        and "No files deleted. Current versions, recorded live sessions and active writers are protected."
      or "Rollback selects an existing verified version; existing processes keep their files."
    vim.cmd("botright new")
    vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype = "nofile", "wipe", false, "toolchain-versions"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.modifiable = false
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = true, silent = true })
  end
  command("ToolchainVersions", function(args)
    versions(args, false)
  end, { nargs = "?", complete = version_completion, desc = "List installed independent tool versions" })
  command("ToolchainPrune", function(args)
    versions(args, true)
  end, { nargs = "?", complete = version_completion, desc = "Preview retired versions without deleting files" })
  command("ToolchainRollback", function(args)
    assert(#args.fargs == 2, "Expected tool:<package> <version-id>")
    require("toolchain.tools").rollback(tool_name(args.fargs[1]), args.fargs[2])
  end, { nargs = "+", complete = version_completion, desc = "Activate a verified previous tool version" })
  command("ToolchainRefreshParsers", function()
    local result = require("toolchain.parsers").refresh_activation()
    vim.notify(("Parser activation metadata: %d updated, %d unchanged"):format(result.updated, result.unchanged))
  end, { desc = "Refresh parser activation metadata without changing installed versions" })
  command("ToolchainRetry", function(args)
    require("toolchain").retry(#args.fargs > 0 and args.fargs or nil)
  end, { nargs = "*", complete = completion, desc = "Retry failed, unavailable or cancelled tasks" })
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
