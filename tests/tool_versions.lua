local t = dofile("tests/helpers.lua")
local tc, tools, util = require("toolchain"), require("toolchain.tools"), require("toolchain.parser_util")
local temp = vim.fn.stdpath("cache") .. "/versions-fixture"
local store, ready, stop = temp .. "/store", temp .. "/ready.json", temp .. "/stop"
vim.fn.mkdir(temp, "p")
tc.setup({
  notify = false,
  log_file = false,
  tools = {
    install_dir = store,
    sources = {
      fixture = {
        kind = "commands",
        version = "2.0.0",
        commands = { { "sh", vim.fn.getcwd() .. "/tests/tool-fixture.sh", "{root}", "2.0.0" } },
        bin = { ["fixture-tool"] = { path = "libexec/fixture" } },
      },
    },
  },
  requirements = { { provider = "tool", name = "fixture" } },
})
local child, first, second
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if child then
      child:kill(15)
    end
  end,
})
local function find(id)
  for _, item in ipairs(tools.prune_plan("fixture")) do
    if item.id == id then
      return item
    end
  end
  error("Missing managed version: " .. id)
end

t.test("an independent editor lease protects a retired version", function()
  child = vim.system({
    vim.v.progpath,
    "--headless",
    "-n",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "--noplugin",
    "-l",
    "tests/lease_holder.lua",
    store,
    ready,
    stop,
  }, { text = true })
  assert(
    vim.wait(15000, function()
      return vim.fn.filereadable(ready) == 1
    end, 10),
    "Other editor did not activate a version"
  )
  first = assert(util.json(ready)).root
  tc.install()
  assert(tc.wait(10000))
  t.eq(tc.status()[1].state, "installed")
  second = tools.path("fixture")
  assert(second ~= first)
  local old = find(vim.fs.basename(first))
  assert(not old.current and old.protected and not old.candidate)
  assert(vim.list_contains(old.reasons, "live session"))
  assert(find(vim.fs.basename(second)).current)
end)

t.test("a damaged rollback target and an active writer both retain the current version", function()
  local path = first .. "/libexec/fixture"
  local original = util.read(path)
  vim.fn.writefile({ "broken" }, path)
  assert(not pcall(tools.rollback, "fixture", vim.fs.basename(first)))
  t.eq(tools.path("fixture"), second)
  vim.fn.writefile(vim.split(original, "\n", { plain = true }), path)
  -- Preserve exact bytes, including the fixture's final newline.
  local file = assert(io.open(path, "wb"))
  file:write(original)
  file:close()
  local receipt_path = first .. "/receipt.json"
  local bytes = util.read(receipt_path)
  local record = util.json(receipt_path)
  record.version = "wrong-version"
  util.write_json(receipt_path, record)
  assert(not pcall(tools.rollback, "fixture", vim.fs.basename(first)))
  t.eq(tools.path("fixture"), second)
  local output = assert(io.open(receipt_path, "wb"))
  output:write(bytes)
  output:close()
  local release = util.lock(store .. "/locks/fixture.lock")
  assert(not pcall(tools.rollback, "fixture", vim.fs.basename(first)))
  t.eq(tools.path("fixture"), second)
  release()
end)

t.test("ending the other editor releases only its protected versions", function()
  vim.fn.writefile({ "stop" }, stop)
  local result = child:wait(10000)
  assert(result.code == 0, result.stderr)
  child = nil
  local old = find(vim.fs.basename(first))
  assert(old.candidate and not old.protected)
  assert(vim.fn.isdirectory(first) == 1, "Prune preview must not delete versions")
end)

t.test("corrupt session metadata protects all versions conservatively", function()
  local incomplete = store .. "/versions/fixture/aaaaaaaaaaaaaaaa-4242-1234"
  vim.fn.mkdir(incomplete, "p")
  assert(find(vim.fs.basename(incomplete)).candidate)
  vim.fn.writefile({ "not json" }, store .. "/sessions/invalid.json")
  local entry = find(vim.fs.basename(incomplete))
  assert(entry.protected and not entry.candidate and vim.list_contains(entry.reasons, "unverified session metadata"))
  assert(vim.uv.fs_unlink(store .. "/sessions/invalid.json"))
  util.write_json(
    store .. "/sessions/stale.json",
    { schema = 1, pid = 2147483647, versions = { "fixture/" .. vim.fs.basename(first) } }
  )
  assert(find(vim.fs.basename(first)).candidate)
  assert(find(vim.fs.basename(incomplete)).state == "incomplete")
end)

t.test("rollback publishes a verified version without discarding files used by this session", function()
  t.eq(tools.rollback("fixture", vim.fs.basename(first)), first)
  t.eq(tools.path("fixture"), first)
  t.eq(vim.system({ tools.executable("fixture", "fixture-tool") }, { text = true }):wait().stdout, "1.0.0\n")
  local old = find(vim.fs.basename(second))
  assert(not old.current and old.protected and vim.list_contains(old.reasons, "live session"))
  assert(tools.installed("fixture").intact)
  assert(not tools.info("fixture").intact, "Rollback must not silently rewrite the configured recipe/lock")
  assert(not pcall(tools.rollback, "fixture", "../../outside"))
end)

t.test("version and prune commands produce read-only reports", function()
  local buffer = vim.api.nvim_get_current_buf()
  for _, command in ipairs({ "ToolchainVersions tool:fixture", "ToolchainPrune tool:fixture" }) do
    vim.cmd(command)
    assert(vim.bo.filetype == "toolchain-versions" and not vim.bo.modifiable)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(text:find(vim.fs.basename(first), 1, true) and text:find(vim.fs.basename(second), 1, true))
    vim.cmd("close")
    assert(vim.api.nvim_get_current_buf() == buffer)
  end
end)

t.test("PATH opt-out still records versions available through resource APIs", function()
  tc.setup({ notify = false, log_file = false, tools = { install_dir = store, path = "skip" } })
  assert(not vim.env.PATH:find(first .. "/bin", 1, true))
  assert(find(vim.fs.basename(first)).protected)
  vim.fn.mkdir(store .. "/versions/empty-failure", "p")
  t.eq(tools.packages(), { "fixture" })
  local skip_ready, skip_stop = temp .. "/skip-ready.json", temp .. "/skip-stop"
  child = vim.system({
    vim.v.progpath,
    "--headless",
    "-n",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "--noplugin",
    "-l",
    "tests/lease_holder.lua",
    store,
    skip_ready,
    skip_stop,
    "skip",
  }, { text = true })
  assert(vim.wait(15000, function()
    return vim.fn.filereadable(skip_ready) == 1
  end, 10))
  local pid, recorded = util.json(skip_ready).pid, false
  for file in vim.fs.dir(store .. "/sessions") do
    local entry = util.json(store .. "/sessions/" .. file)
    if entry and entry.pid == pid and vim.list_contains(entry.versions, "fixture/" .. vim.fs.basename(first)) then
      recorded = true
    end
  end
  assert(recorded, "A fresh PATH-opt-out editor must persist its resource lease")
  vim.fn.writefile({ "stop" }, skip_stop)
  assert(child:wait(10000).code == 0)
  child = nil
end)

t.done()
