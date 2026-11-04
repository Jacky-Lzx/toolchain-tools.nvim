local t = dofile("tests/helpers.lua")
local toolchain = require("toolchain")
local function setup(opts)
  toolchain.setup(vim.tbl_extend("force", { notify = false, log_file = false }, opts or {}))
end

t.test("require and setup do not load installers or register buffer hooks", function()
  t.eq(vim.fn.exists(":Toolchain"), 0)
  setup({ requirements = { { provider = "mason", name = "stylua" }, { provider = "treesitter", name = "lua" } } })
  assert(not package.loaded.mason and not package.loaded["nvim-treesitter"])
  t.eq(vim.fn.exists(":Toolchain"), 2)
  local plan = toolchain.plan()
  t.eq(plan[1].state, "check")
  assert(not package.loaded.mason and not package.loaded["nvim-treesitter"])
  t.eq(#toolchain.status(), 0)
end)

t.test("existing executables bypass Mason and its post_install hook", function()
  local called = false
  setup({
    requirements = {
      {
        provider = "mason",
        name = "fixture",
        executable = "sh",
        post_install = function()
          called = true
        end,
      },
    },
  })
  t.eq(toolchain.plan()[1].state, "available")
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "skipped")
  assert(not called and not package.loaded.mason)
end)

t.test("system requirements validate executable paths and report missing tools", function()
  setup({
    requirements = {
      {
        provider = "system",
        name = "shell",
        resolve = function()
          return vim.fn.exepath("sh")
        end,
      },
      { provider = "system", name = "toolchain-impossible-executable-123" },
      {
        provider = "system",
        name = "invalid",
        resolve = function()
          return true
        end,
      },
    },
  })
  t.eq(
    vim.tbl_map(function(entry)
      return entry.state
    end, toolchain.plan()),
    { "available", "missing", "failed" }
  )
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(
    vim.tbl_map(function(entry)
      return entry.state
    end, toolchain.status()),
    { "skipped", "failed", "failed" }
  )
end)

t.test("ID selection resolves dynamic configuration once and rejects unknown IDs atomically", function()
  local count = 0
  setup({
    requirements = function()
      count = count + 1
      return { { provider = "system", name = "sh" }, { provider = "system", name = "missing-fixture" } }
    end,
  })
  assert(not pcall(toolchain.install_ids, { "system:sh", "system:unknown" }))
  t.eq(#toolchain.status(), 0)
  toolchain.install_ids({ "system:sh", "system:sh" })
  t.eq(count, 2)
  assert(not pcall(setup))
  assert(toolchain.wait(1000))
  t.eq(#toolchain.status(), 1)
  vim.cmd("ToolchainInstall system:sh")
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].attempt, 2)
end)

t.test("durable logs contain transitions while status snapshots are isolated", function()
  local path = vim.fn.stdpath("state") .. "/fixture-log.jsonl"
  setup({ log_file = path, requirements = { { provider = "system", name = "sh" } } })
  toolchain.install()
  assert(toolchain.wait(1000))
  local records = vim.tbl_map(vim.json.decode, vim.fn.readfile(path))
  t.eq(
    vim.tbl_map(function(record)
      return record.state
    end, records),
    { "queued", "running", "skipped" }
  )
  assert(records[1].time)
  toolchain.status()[1].logs[1] = "changed"
  t.eq(#toolchain.status()[1].logs, 0)
end)

t.test("failed tasks retry after a missing executable becomes available", function()
  local ready = false
  setup({
    requirements = {
      {
        provider = "system",
        name = "fixture",
        resolve = function()
          return ready and vim.fn.exepath("sh") or nil
        end,
      },
    },
  })
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "failed")
  ready = true
  vim.cmd("ToolchainRetry")
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "skipped")
  t.eq(toolchain.status()[1].attempt, 2)
end)

t.done()
