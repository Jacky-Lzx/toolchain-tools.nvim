local t = dofile("tests/helpers.lua")
local toolchain = require("toolchain")
local config = require("toolchain.config")
local missing = "toolchain-optional-missing-fixture-123"
local function setup(requirements, opts)
  toolchain.setup(vim.tbl_extend("force", {
    requirements = requirements,
    concurrency = 1,
    log_file = false,
    notify = false,
  }, opts or {}))
end

t.test("missing optional tools finish as unavailable and do not stop required work", function()
  local messages = {}
  local notify = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  local log_file = vim.fn.stdpath("state") .. "/optional.jsonl"
  setup({
    { provider = "system", name = missing, optional = true },
    { provider = "system", name = "sh" },
  }, { notify = true, log_file = log_file })
  local plan = toolchain.plan()
  t.eq(plan[1].state, "unavailable")
  assert(plan[1].optional)
  toolchain.install()
  assert(toolchain.wait(1000))
  local tasks = toolchain.status()
  t.eq(tasks[1].state, "unavailable")
  assert(tasks[1].optional)
  t.eq(tasks[2].state, "skipped")
  t.eq(#messages, 0)
  vim.notify = notify
  local records = vim.tbl_map(vim.json.decode, vim.fn.readfile(log_file))
  local found = false
  for _, record in ipairs(records) do
    if record.state == "unavailable" then
      assert(record.optional)
      found = true
    end
  end
  assert(found)
  assert(not package.loaded.mason and not package.loaded["nvim-treesitter"])
end)

t.test("required absence and optional resolver errors remain failures", function()
  setup({
    { provider = "system", name = missing },
    {
      provider = "system",
      name = "resolver_error",
      optional = true,
      resolve = function()
        error("broken resolver")
      end,
    },
    {
      provider = "system",
      name = "resolver_type",
      optional = true,
      resolve = function()
        return true
      end,
    },
  })
  t.eq(
    vim.tbl_map(function(task)
      return task.state
    end, toolchain.plan()),
    { "missing", "failed", "failed" }
  )
  toolchain.install()
  assert(toolchain.wait(1000))
  for _, task in ipairs(toolchain.status()) do
    t.eq(task.state, "failed")
  end
end)

t.test("unavailable tools can be explicitly retried when they become available", function()
  local ready = false
  setup({
    {
      provider = "system",
      name = missing,
      optional = true,
      resolve = function()
        return ready and vim.fn.exepath("sh") or nil
      end,
    },
  })
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "unavailable")
  ready = true
  vim.cmd("ToolchainRetry")
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "skipped")
  t.eq(toolchain.status()[1].attempt, 2)
  -- Submitting completed optional work must also create a new attempt.
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].attempt, 3)
end)

t.test("health reports optional absence as information and required absence as a warning", function()
  setup({
    { provider = "system", name = missing, optional = true },
    { provider = "system", name = missing .. "-required" },
  })
  local original, messages = {}, {}
  for _, level in ipairs({ "start", "ok", "warn", "error", "info" }) do
    original[level] = vim.health[level]
    vim.health[level] = function(message)
      messages[#messages + 1] = { level = level, message = message }
    end
  end
  require("toolchain.health").check()
  for level, fn in pairs(original) do
    vim.health[level] = fn
  end
  local optional_info, required_warning = false, false
  for _, message in ipairs(messages) do
    if message.message:find(missing .. "-required", 1, true) then
      t.eq(message.level, "warn")
      required_warning = true
    elseif message.message:find(missing, 1, true) then
      t.eq(message.level, "info")
      optional_info = true
    end
  end
  assert(optional_info and required_warning)
end)

t.test("optional flags are explicit booleans for system requirements", function()
  for _, requirement in ipairs({
    { provider = "system", name = "bad", optional = "yes" },
    { provider = "mason", name = "bad", optional = true },
    { provider = "treesitter", name = "lua", optional = true },
  }) do
    assert(not pcall(config.normalize, { requirement }))
  end
  assert(config.normalize({ { provider = "system", name = missing, optional = false } }))
end)

t.done()
