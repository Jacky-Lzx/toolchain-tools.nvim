local t = dofile("tests/helpers.lua")
local tools, toolchain = require("toolchain.tools"), require("toolchain")
local temp = vim.fn.stdpath("cache") .. "/tools-fixture"
local install = temp .. "/managed tools"
local fixture = vim.fn.getcwd() .. "/tests/tool-fixture.sh"
local recipe = {
  kind = "commands",
  version = "1.0.0",
  commands = { { "sh", fixture, "{root}", "1.0.0" } },
  bin = { ["fixture-tool"] = { path = "libexec/fixture" } },
  resources = { payload = "libexec/fixture" },
}
local function setup(entry)
  toolchain.setup({
    notify = false,
    log_file = false,
    tools = { install_dir = install, sources = { fixture = entry or recipe } },
    requirements = { { provider = "tool", name = "fixture", executable = "fixture-tool" } },
  })
end
local function run()
  toolchain.install()
  assert(toolchain.wait(10000))
  return toolchain.status()[1]
end

t.test("setup and planning are offline, lazy and filesystem read-only", function()
  setup()
  assert(vim.fn.isdirectory(install) == 0)
  t.eq(toolchain.plan()[1].state, "check")
  assert(not package.loaded["toolchain.tool_installers"] and not package.loaded.mason)
end)

t.test("independent install publishes wrappers, resource paths and matching receipts", function()
  t.eq(run().state, "installed")
  local info = tools.info("fixture")
  assert(info.intact and tools.executable("fixture", "fixture-tool"))
  t.eq(vim.system({ tools.executable("fixture", "fixture-tool") }, { text = true }):wait().stdout, "1.0.0\n")
  assert(tools.path("fixture", "payload") and tools.owns(tools.executable("fixture", "fixture-tool")))
  t.eq(run().state, "skipped")
  t.eq(tools.info("fixture").current, info.current)
end)

t.test("modified artifacts are repaired in a fresh version", function()
  local previous = tools.info("fixture").current
  vim.fn.writefile({ "broken" }, previous .. "/libexec/fixture")
  assert(not tools.info("fixture").intact)
  t.eq(run().state, "installed")
  assert(tools.info("fixture").current ~= previous and tools.info("fixture").intact)
  assert(vim.fn.isdirectory(previous) == 1)
end)

t.test("failed upgrade retains the prior version and removes incomplete directories", function()
  local previous = tools.info("fixture").current
  local bad = vim.deepcopy(recipe)
  bad.version, bad.commands = "2.0.0", { { "sh", "-c", "exit 7" } }
  setup(bad)
  t.eq(run().state, "failed")
  t.eq(tools.info("fixture").current, previous)
  assert(vim.fn.executable(tools.executable("fixture", "fixture-tool")) == 1)
  setup()
end)

t.test("locks reject simultaneous writers and retry after release", function()
  local unlock = require("toolchain.parser_util").lock(install .. "/locks/fixture.lock")
  t.eq(run().state, "failed")
  unlock()
  t.eq(toolchain.retry({ "tool:fixture" })[1], "tool:fixture")
  assert(toolchain.wait(10000))
  t.eq(toolchain.status()[1].state, "skipped")
end)

t.test("post-install hooks receive neutral paths before publication", function()
  local saw
  local changed = vim.deepcopy(recipe)
  changed.version = "3.0.0"
  toolchain.setup({
    notify = false,
    log_file = false,
    tools = { install_dir = install, sources = { fixture = changed } },
  })
  toolchain.install({
    {
      provider = "tool",
      name = "fixture",
      post_install_async = function(package, done)
        saw = package
        assert(package.path ~= tools.path("fixture"))
        vim.schedule(function()
          done()
        end)
      end,
    },
  })
  assert(toolchain.wait(10000))
  t.eq(toolchain.status()[1].state, "installed")
  assert(saw.name == "fixture" and saw.path == tools.path("fixture") and saw.version == "3.0.0")
end)

t.test("system tools retain priority; managed binaries are not treated as external", function()
  local system = require("toolchain.backends.system")
  assert(system.external({ provider = "tool", name = "fixture", executable = "fixture-tool" }) == nil)
  assert(system.external({ provider = "tool", name = "fixture", executable = "sh" }))
  assert(not package.loaded.mason and not package.loaded["mason-registry"])
end)

t.done()
