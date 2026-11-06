vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("toolchain")
local root = vim.fn.tempname()
local options = {
  notify = false,
  requirements = {},
  parsers = { install_dir = root .. "/parsers" },
  tools = { install_dir = root .. "/tools", path = "skip" },
}
local caller = vim.deepcopy(options)
plugin.setup(options)
assert(vim.deep_equal(caller, options), "setup mutated caller configuration")
local commands = vim.api.nvim_get_commands({})
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, false), "setup(false) must reject an invalid configuration type")
assert(vim.deep_equal(commands, vim.api.nvim_get_commands({})), "Invalid setup replaced commands")
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})), "Invalid setup replaced handlers")
plugin.setup(caller)
assert(#vim.api.nvim_get_autocmds({}) == #handlers, "Repeated setup duplicated automatic handlers")
print("toolchain-tools.nvim: setup input isolation, invalid configuration and registration lifetime passed")

local path = require("toolchain.parsers").info("lua").path
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, { parsers = { install_dir = root .. "/other" }, tools = { path = "invalid" } }))
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})))
assert(require("toolchain.parsers").info("lua").path == path)
plugin.dispose()
plugin.dispose()
assert(vim.fn.exists(":Toolchain") == 0)
plugin.setup(caller)
plugin.dispose()
vim.fn.delete(root, "rf")
