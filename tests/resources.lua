local t = dofile("tests/helpers.lua")
local resources = require("toolchain.resources")
local tools, util = require("toolchain.tools"), require("toolchain.parser_util")
local exepath, resolve, stat = vim.fn.exepath, vim.fn.resolve, vim.uv.fs_stat
local found
vim.fn.resolve = function(path)
  return path
end
vim.fn.exepath = function()
  return found or ""
end
local expected
vim.uv.fs_stat = function(path)
  return path == expected and {} or nil
end
for _, paths in ipairs({
  {
    "/homebrew/lib/node_modules/@vue/language-server/bin/vue-language-server.js",
    "/homebrew/lib/node_modules/@vue/language-server",
  },
  { "/npm/vue-language-server/bin/vue-language-server", "/npm/vue-language-server/node_modules/@vue/language-server" },
}) do
  found, expected = paths[1], paths[2]
  assert(resources.npm_package("vue-language-server", "@vue/language-server") == expected)
end
found, expected = nil, nil
assert(resources.npm_package("vue-language-server", "@vue/language-server") == nil)
vim.fn.exepath, vim.fn.resolve, vim.uv.fs_stat = exepath, resolve, stat
local path = tools.path
tools.path = function(name, resource)
  assert(name == "vue-language-server" and resource == "server")
  return "/managed/server"
end
vim.fn.exepath = function()
  return ""
end
assert(resources.resolve("vue-language-server", "server") == "/managed/server")
tools.path, vim.fn.exepath = path, exepath
assert(not package.loaded["toolchain.tool_installers"])
local recipe = tools.definition("vue-language-server", true)
assert(recipe.overrides.typescript == "6.0.3")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root)
local command = util.command
util.command = function(argv, opts)
  assert(argv[1] == "npm" and opts.cwd == root)
  local manifest = util.json(root .. "/package.json")
  assert(manifest.dependencies.typescript == manifest.overrides.typescript)
  util.write_json(root .. "/package-lock.json", { packages = {} })
  return ""
end
local metadata = require("toolchain.tool_installers").install(recipe, root, function() end)
assert(metadata.locks["package-lock.json"])
util.command = command
vim.fn.delete(root, "rf")
print("Resources: npm/Homebrew paths, managed fallback, cold reads and pinned override manifest passed")
