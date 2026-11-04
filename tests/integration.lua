local t = dofile("tests/helpers.lua")
for _, variable in ipairs({ "TOOLCHAIN_MASON_ROOT", "TOOLCHAIN_TREESITTER_ROOT" }) do
  local root = assert(vim.env[variable], "Set " .. variable .. " to an actual upstream checkout")
  assert(vim.fn.isdirectory(root) == 1, "Missing checkout: " .. root)
  vim.opt.rtp:append(root)
end
vim.opt.rtp:append(vim.fn.getcwd() .. "/tests/fixtures")
local root = vim.fn.stdpath("data")
require("mason").setup({
  install_root_dir = root .. "/mason",
  PATH = "append",
  registries = { "lua:toolchain-test-registry.index" },
  system_registries = {},
})
require("nvim-treesitter").setup({ install_dir = root .. "/site" })

local grammar_root = root .. "/grammar"
vim.fn.mkdir(grammar_root, "p")
vim.fn.writefile({
  "module.exports = grammar({ name: 'toolchain_fixture', rules: {",
  "source_file: $ => repeat($.word), word: $ => /[a-z]+/ }});",
}, grammar_root .. "/grammar.js")
local generated = vim.system({ "tree-sitter", "generate" }, { cwd = grammar_root, text = true }):wait()
assert(generated.code == 0, generated.stderr)
local group = vim.api.nvim_create_augroup("ToolchainIntegration", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "TSUpdate",
  callback = function()
    require("nvim-treesitter.parsers").toolchain_fixture = {
      tier = 1,
      install_info = { path = grammar_root, revision = "offline-fixture" },
    }
  end,
})

local toolchain = require("toolchain")
local hooks = 0
toolchain.setup({
  concurrency = 2,
  notify = false,
  requirements = {
    {
      provider = "mason",
      name = "toolchain-fixture",
      executable = "toolchain-fixture",
      post_install = function()
        hooks = hooks + 1
      end,
    },
    { provider = "treesitter", name = "toolchain_fixture" },
  },
})

t.test("actual Mason installs a package and Tree-sitter builds a loadable parser", function()
  toolchain.install()
  assert(toolchain.wait(30000), "integration installers timed out")
  local tasks = toolchain.status()
  assert(tasks[1].state == "installed", vim.inspect(tasks[1]))
  assert(tasks[2].state == "installed", vim.inspect(tasks[2]))
  local executable = root .. "/mason/bin/toolchain-fixture"
  t.eq(vim.system({ executable }, { text = true }):wait().stdout, "toolchain fixture\n")
  vim.treesitter.language.add("toolchain_fixture", { path = root .. "/site/parser/toolchain_fixture.so" })
  local parser = vim.treesitter.get_string_parser("hello world", "toolchain_fixture")
  local tree = parser:parse()[1]
  t.eq(tree:root():type(), "source_file")
  assert(not tree:root():has_error())
  assert(#tasks[1].logs > 0)
  assert(table.concat(tasks[1].logs, "\n"):find("Created offline fixture", 1, true))
  t.eq(hooks, 1)
  assert(vim.fn.filereadable(toolchain.log_file()) == 1)
end)

t.test("actual backend rechecks skip packages already installed", function()
  toolchain.install()
  assert(toolchain.wait(5000))
  t.eq(
    vim.tbl_map(function(task)
      return task.state
    end, toolchain.status()),
    { "skipped", "skipped" }
  )
  t.eq(hooks, 2)
end)

t.done()
