local t = dofile("tests/helpers.lua")
local toolchain = require("toolchain")
local config = require("toolchain.config")
local existing, install_callbacks, installs = {}, {}, {}
package.loaded.mason = { has_setup = true }
package.loaded["mason-registry"] = {
  refresh = function(done)
    done(true, {})
  end,
  get_package = function(name)
    return {
      is_installing = function()
        return false
      end,
      is_installed = function()
        return existing[name] == true
      end,
      install = function(_, _, done)
        installs[name] = (installs[name] or 0) + 1
        install_callbacks[name] = done
        existing[name] = true
        done(true, {})
        return { on = function() end }
      end,
    }
  end,
}
local function setup(requirements, options)
  toolchain.setup(vim.tbl_extend("force", {
    requirements = requirements,
    concurrency = 1,
    notify = false,
    log_file = false,
  }, options or {}))
end

t.test("async hook retains its queue slot and wait times out until callback completion", function()
  local finish, hook_calls = nil, 0
  setup({
    {
      provider = "mason",
      name = "fresh",
      post_install_async = function(pkg, done, log)
        assert(pkg)
        hook_calls = hook_calls + 1
        log("child process started")
        finish = done
      end,
    },
    { provider = "system", name = "sh" },
  })
  toolchain.install()
  t.wait(function()
    return finish ~= nil
  end)
  local completed, tasks = toolchain.wait(10)
  assert(not completed)
  t.eq(tasks[1].state, "running")
  t.eq(tasks[2].state, "queued")
  -- Duplicate backend results must not re-run the hook or end its task early.
  install_callbacks.fresh(true, {})
  install_callbacks.fresh(false, "late installer error")
  t.eq(hook_calls, 1)
  finish()
  finish("late hook error")
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "installed")
  t.eq(toolchain.status()[2].state, "skipped")
end)

t.test("async hook failures remain retryable without reinstalling the package", function()
  local fail = true
  local path = vim.fn.stdpath("state") .. "/async-hook.jsonl"
  setup({
    {
      provider = "mason",
      name = "repair",
      post_install_async = function(_, done, log)
        vim.defer_fn(function()
          log("child process finished")
          done(fail and "npm exited with status 1" or nil)
        end, 10)
      end,
    },
  }, { log_file = path })
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "failed")
  assert(toolchain.status()[1].message:find("npm exited with status 1", 1, true))
  assert(table.concat(vim.fn.readfile(path), "\n"):find("npm exited with status 1", 1, true))
  fail = false
  toolchain.retry()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "skipped")
  t.eq(toolchain.status()[1].attempt, 2)
  t.eq(installs.repair, 1)
end)

t.test("hook exceptions fail fresh and already installed packages", function()
  existing.old_exception = true
  setup({
    {
      provider = "mason",
      name = "fresh_exception",
      post_install_async = function()
        error("fresh hook exception")
      end,
    },
    {
      provider = "mason",
      name = "old_exception",
      post_install_async = function()
        error("existing hook exception")
      end,
    },
  })
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "failed")
  t.eq(toolchain.status()[2].state, "failed")
end)

t.test("callback completion is safe in a fast event and external tools bypass hooks", function()
  setup({
    {
      provider = "mason",
      name = "fast_event",
      post_install_async = function(_, done)
        local timer = vim.uv.new_timer()
        timer:start(5, 0, function()
          assert(vim.in_fast_event())
          timer:stop()
          timer:close()
          done()
        end)
      end,
    },
    {
      provider = "mason",
      name = "external",
      executable = "sh",
      post_install_async = function()
        error("external hook must not run")
      end,
    },
  })
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "installed")
  t.eq(toolchain.status()[2].state, "skipped")
end)

t.test("ambiguous or invalid hook declarations are rejected", function()
  for _, requirement in ipairs({
    { provider = "mason", name = "bad", post_install_async = true },
    { provider = "system", name = "bad", post_install_async = function() end },
    { provider = "mason", name = "bad", post_install = function() end, post_install_async = function() end },
  }) do
    assert(not pcall(config.normalize, { requirement }))
  end
end)

t.done()
