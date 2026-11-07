local t = dofile("tests/helpers.lua")
local util, tools = require("toolchain.parser_util"), require("toolchain.tools")
local toolchain = require("toolchain")
local temp = vim.fn.stdpath("cache") .. "/download-fixture"
vim.fn.mkdir(temp .. "/source", "p")
vim.fn.writefile({ "#!/bin/sh", "echo downloaded" }, temp .. "/source/program")
assert(vim.system({ "tar", "-czf", temp .. "/fixture.tar.gz", "-C", temp .. "/source", "program" }):wait().code == 0)
assert(vim.system({ "zip", "-jq", temp .. "/fixture.zip", temp .. "/source/program" }):wait().code == 0)
assert(vim.uv.fs_copyfile(temp .. "/source/program", temp .. "/program"))
assert(vim.system({ "gzip", "-k", temp .. "/program" }):wait().code == 0)
local target = require("toolchain.tool_installers").target()
local function recipe(kind, filename)
  local bin = { downloaded = { path = "payload/program" } }
  return {
    kind = "download",
    version = "1",
    bin = bin,
    assets = {
      [target] = {
        bin = bin,
        files = { { url = vim.uri_from_fname(temp .. "/" .. filename), name = filename, archive = kind } },
      },
    },
  }
end
local function install(entry)
  toolchain.setup({
    notify = false,
    log_file = false,
    tools = { install_dir = temp .. "/store", sources = { downloaded = entry } },
  })
  toolchain.install({ { provider = "tool", name = "downloaded" } })
  assert(toolchain.wait(10000))
  return toolchain.status()[1]
end
for _, format in ipairs({
  { "tar", "fixture.tar.gz" },
  { "zip", "fixture.zip" },
  { "gzip", "program.gz" },
  { "file", "program" },
}) do
  t.test("real " .. format[1] .. " extraction publishes a runnable binary", function()
    local entry = recipe(unpack(format))
    entry.version = format[1]
    t.eq(install(entry).state, "installed")
    t.eq(vim.system({ tools.executable("downloaded") }, { text = true }):wait().stdout, "downloaded\n")
    assert(tools.info("downloaded").intact)
  end)
end

t.test("checksum rejection keeps the previous runnable version", function()
  local old = tools.path("downloaded")
  local entry = recipe("file", "program")
  entry.assets[target].files[1].sha256 = string.rep("0", 64)
  t.eq(install(entry).state, "failed")
  t.eq(tools.path("downloaded"), old)
end)

t.test("all bundled recipes normalize on macOS and Linux without templates or Mason", function()
  local registry = assert(util.json("data/tools.json"))
  t.eq(vim.tbl_count(registry.packages), 38)
  local original = vim.uv.os_uname
  for _, platform in ipairs({
    { "Darwin", "arm64" },
    { "Darwin", "x86_64" },
    { "Linux", "x86_64" },
    { "Linux", "aarch64" },
  }) do
    vim.uv.os_uname = function()
      return { sysname = platform[1], machine = platform[2] }
    end
    tools.setup()
    for name in pairs(registry.packages) do
      local ok, entry = pcall(tools.definition, name)
      if platform[1] == "Linux" and platform[2] == "aarch64" and name == "clangd" then
        assert(not ok and entry:find("use a system package", 1, true))
      else
        assert(ok, name .. ": " .. tostring(entry))
        assert(not vim.json.encode(entry):find("{{", 1, true), name)
      end
    end
  end
  vim.uv.os_uname = original
  assert(not package.loaded.mason and not package.loaded["mason-registry"])
end)

t.test("offline registry imports preserve curated release recipes", function()
  local output, source, info = temp .. "/registry.json", temp .. "/source.json", temp .. "/info.json"
  vim.fn.writefile({ vim.json.encode({ packages = { fixture = {} } }) }, output)
  vim.fn.writefile(
    {
      vim.json.encode({
        { name = "fixture", source = { id = "pkg:npm/fixture@1.0.0" }, bin = { fixture = "npm:fixture" } },
      }),
    },
    source
  )
  vim.fn.writefile({ '{"version":"fixture"}' }, info)
  local result = vim
    .system({ "python3", "scripts/import-tools.py", source, "--info", info, "--output", output }, { text = true })
    :wait()
  assert(result.code == 0, result.stderr)
  local imported = assert(util.json(output)).packages
  local additions = assert(util.json("data/tool-additions.json"))
  t.eq(imported["ltex-ls-plus"], additions["ltex-ls-plus"])
  t.eq(assert(util.json("data/tools.json")).packages["ltex-ls-plus"], additions["ltex-ls-plus"])
  t.eq(imported.fixture.version, "1.0.0")
end)

t.done()
