local M = {}
local util = require("toolchain.parser_util")

function M.install(entry, root, log)
  assert(entry.kind == "commands", "Unsupported tool installer: " .. entry.kind)
  for _, command in ipairs(entry.commands) do
    local args = vim.tbl_map(function(arg)
      return arg:gsub("{root}", function()
        return root
      end)
    end, command)
    util.command(args, { cwd = root }, log)
  end
end

return M
