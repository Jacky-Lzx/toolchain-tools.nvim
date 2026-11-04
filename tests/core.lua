local t = dofile("tests/helpers.lua")
local config = require("toolchain.config")
local Queue = require("toolchain.queue")
local function spec(name)
  return { provider = "mason", name = name }
end

t.test("declarations deduplicate without changing their inputs", function()
  local input = { spec("one"), spec("one"), { provider = "treesitter", name = "one" } }
  local result = config.normalize(input)
  t.eq(#result, 2)
  result[1].name = "changed"
  t.eq(input[1].name, "one")
end)

t.test("invalid and conflicting declarations fail before execution", function()
  for _, input in ipairs({
    { { provider = "unknown", name = "one" } },
    { { provider = "mason", name = "../one" } },
    { { provider = "mason", name = "one", version = "unimplemented" } },
    { spec("one"), { provider = "mason", name = "one", executable = "other" } },
    { { provider = "treesitter", name = "lua", executable = "lua" } },
  }) do
    assert(not pcall(config.normalize, input))
  end
  assert(not pcall(config.options, { concurrency = 0 }))
  assert(not pcall(config.options, { concurrency = 1.5 }))
end)

t.test("shared queue bounds concurrency and deduplicates active tasks", function()
  local callbacks, starts = {}, {}
  local q = Queue.new({
    concurrency = 2,
    max_log_lines = 2,
    execute = function(s, ctx)
      starts[#starts + 1] = s.name
      callbacks[s.name] = ctx.done
    end,
  })
  q:submit({ spec("one"), spec("two"), spec("three") })
  q:submit({ spec("one") })
  t.wait(function()
    return #starts == 2
  end)
  t.eq(q.active, 2)
  callbacks.one("installed", "done")
  callbacks.one("failed", "late duplicate callback")
  t.wait(function()
    return #starts == 3
  end)
  t.eq(q.active, 2)
  callbacks.two("failed", "network unavailable")
  callbacks.three("skipped", "already installed")
  t.wait(function()
    return not q:busy()
  end)
  t.eq(
    vim.tbl_map(function(task)
      return task.state
    end, q:snapshot()),
    { "installed", "failed", "skipped" }
  )
  local snapshot = q:snapshot()
  snapshot[1].state = "bad"
  t.eq(q:snapshot()[1].state, "installed")
end)

t.test("cancelled queue entries do not start and can be retried", function()
  local starts = 0
  local q = Queue.new({
    concurrency = 1,
    max_log_lines = 2,
    execute = function(_, ctx)
      starts = starts + 1
      ctx.done("installed")
    end,
  })
  q:submit({ spec("one") })
  assert(q:cancel("mason:one"))
  q:retry()
  t.wait(function()
    return not q:busy()
  end)
  t.eq(starts, 1)
  t.eq(q:snapshot()[1].attempt, 2)
end)

t.test("exceptions release slots and failed tasks retry explicitly", function()
  local fails = true
  local q = Queue.new({
    concurrency = 1,
    max_log_lines = 2,
    execute = function(_, ctx)
      if fails then
        error("installer exception")
      end
      ctx.done("installed")
    end,
  })
  q:submit({ spec("one"), spec("two") })
  t.wait(function()
    return not q:busy()
  end)
  t.eq(q:snapshot()[2].state, "failed")
  fails = false
  q:retry()
  t.wait(function()
    return not q:busy()
  end)
  t.eq(q:snapshot()[1].state, "installed")
  t.eq(q:snapshot()[2].attempt, 2)
end)

t.test("active conflicts are atomic and running tasks cannot be cancelled", function()
  local finish
  local q = Queue.new({
    concurrency = 1,
    max_log_lines = 2,
    execute = function(_, ctx)
      finish = ctx.done
    end,
  })
  q:submit({ spec("one") })
  t.wait(function()
    return finish ~= nil
  end)
  assert(not q:cancel("mason:one"))
  assert(not pcall(q.submit, q, { spec("two"), { provider = "mason", name = "one", executable = "other" } }))
  t.eq(#q:snapshot(), 1)
  finish("installed")
  t.wait(function()
    return not q:busy()
  end)
end)

t.test("installer output is bounded and invalid completion states fail safely", function()
  local q = Queue.new({
    concurrency = 1,
    max_log_lines = 2,
    execute = function(_, ctx)
      ctx.log("discard this chunk")
      ctx.log("keep this chunk")
      ctx.log(string.rep("x", 9000))
      vim.schedule(function()
        ctx.done("unknown")
      end)
    end,
  })
  q:submit({ spec("one") })
  t.wait(function()
    return not q:busy()
  end)
  local task = q:snapshot()[1]
  t.eq(#task.logs, 2)
  t.eq(task.logs[1], "keep this chunk")
  t.eq(#task.logs[2], 8192)
  t.eq(task.state, "failed")
end)

t.done()
