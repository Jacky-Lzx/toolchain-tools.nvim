local t = dofile("tests/helpers.lua")
local tc, tools, util = require("toolchain"), require("toolchain.tools"), require("toolchain.parser_util")
local temp = vim.fn.stdpath("cache") .. "/lock-fixture"
local lock = temp .. "/toolchain-lock.json"
local recipe = {
  kind = "commands",
  version = "1.0.0",
  commands = { { "sh", vim.fn.getcwd() .. "/tests/tool-fixture.sh", "{root}", "1.0.0" } },
  bin = { ["fixture-tool"] = { path = "libexec/fixture" } },
}
local function setup(store, source, frozen)
  tc.setup({
    notify = false,
    log_file = false,
    tools = {
      install_dir = temp .. "/" .. store,
      sources = { fixture = source or recipe },
      lockfile = frozen and lock or false,
    },
    requirements = { { provider = "tool", name = "fixture", executable = "fixture-tool" } },
  })
end
local function install()
  tc.install()
  assert(tc.wait(10000))
  return tc.status()[1]
end

t.test("frozen setup stays offline and missing locks fail only explicit installation", function()
  setup("missing", nil, true)
  assert(not vim.uv.fs_stat(lock))
  t.eq(tc.plan()[1].state, "check")
  t.eq(install().state, "failed")
  assert(tc.status()[1].message:find("lock is missing", 1, true))
end)

t.test("explicit lock resolution installs managed recipes even when an external tool exists", function()
  setup("first")
  tc.setup({
    notify = false,
    log_file = false,
    tools = { install_dir = temp .. "/first", sources = { fixture = recipe } },
    requirements = { { provider = "tool", name = "fixture", executable = "sh" } },
  })
  tc.lock(lock, true)
  assert(tc.wait(10000))
  t.eq(tc.status()[1].state, "installed")
  t.eq(tc.lock_status().state, "written")
  assert(util.json(lock).targets[require("toolchain.tool_lock").target()].packages.fixture)
end)

t.test("the lock reproduces an older recipe in a fresh store after bundled sources change", function()
  local newer = vim.deepcopy(recipe)
  newer.version = "2.0.0"
  newer.commands[1][4] = "2.0.0"
  setup("fresh", newer, true)
  t.eq(install().state, "installed")
  t.eq(vim.system({ tools.executable("fixture", "fixture-tool") }, { text = true }):wait().stdout, "1.0.0\n")
  assert(tools.info("fixture").intact)
  t.eq(install().state, "skipped")
end)

t.test("lock export is stable and preserves other platform entries", function()
  local value = util.json(lock)
  value.targets.other_platform = { packages = { retained = { recipe = recipe } } }
  util.write_json(lock, value)
  tc.lock(lock)
  assert(util.json(lock).targets.other_platform.packages.retained)
  local first = util.read(lock)
  tc.lock(lock)
  t.eq(util.read(lock), first)
  assert(not first:find('"path": "/', 1, true), "No installation root should be exported")
end)

t.test("an unsuccessful explicit update leaves the old lock byte-for-byte intact", function()
  local before = util.read(lock)
  local bad = vim.deepcopy(recipe)
  bad.version = "broken"
  bad.commands = { { "sh", "-c", "exit 9" } }
  setup("failed", bad, true)
  tc.lock(lock, true)
  assert(tc.wait(10000))
  t.eq(tc.lock_status().state, "failed")
  t.eq(util.read(lock), before)
end)

t.test("locked download checksums refuse changed upstream bytes", function()
  local path = temp .. "/program"
  vim.fn.writefile({ "#!/bin/sh", "echo original" }, path)
  local target = require("toolchain.tool_installers").target()
  local bin = { downloaded = { path = "payload/program" } }
  local entry = {
    kind = "download",
    version = "1",
    bin = bin,
    assets = {
      [target] = { bin = bin, files = { { url = vim.uri_from_fname(path), name = "program", archive = "file" } } },
    },
  }
  tc.setup({
    notify = false,
    log_file = false,
    tools = { install_dir = temp .. "/download", sources = { downloaded = entry } },
    requirements = { { provider = "tool", name = "downloaded" } },
  })
  tc.install()
  assert(tc.wait(10000))
  t.eq(tc.status()[1].state, "installed")
  tc.lock(lock)
  vim.fn.writefile({ "#!/bin/sh", "echo altered" }, path)
  tc.setup({
    notify = false,
    log_file = false,
    tools = { install_dir = temp .. "/download-fresh", lockfile = lock },
    requirements = { { provider = "tool", name = "downloaded" } },
  })
  tc.install()
  assert(tc.wait(10000))
  t.eq(tc.status()[1].state, "failed")
  assert(tc.status()[1].message:find("checksum", 1, true))
  assert(tools.path("downloaded") == nil)
end)

t.test("malformed frozen dependencies are rejected before a backend can resolve them", function()
  local lockmod = require("toolchain.tool_lock")
  local value = util.json(lock)
  value.targets[lockmod.target()].packages.invalid =
    { recipe = { kind = "npm", version = "1", package = "invalid", bin = {} } }
  util.write_json(lock, value)
  assert(not pcall(lockmod.entry, lock, "invalid"))
end)

t.test("a direct export failure reports failure and preserves the malformed file", function()
  setup("first")
  local broken = temp .. "/invalid-lock.json"
  vim.fn.writefile({ "not json" }, broken)
  local ok = pcall(tc.lock, broken)
  assert(not ok and tc.lock_status().state == "failed")
  t.eq(util.read(broken), "not json\n")
end)

t.test("lock completion remains successful when an observer raises an error", function()
  setup("first")
  local observer = vim.api.nvim_create_autocmd("User", {
    pattern = "ToolchainLockWritten",
    callback = function()
      error("observer fixture")
    end,
  })
  tc.lock(temp .. "/observed-lock.json")
  vim.api.nvim_del_autocmd(observer)
  t.eq(tc.lock_status().state, "written")
  assert(util.json(temp .. "/observed-lock.json"))
end)

t.done()
