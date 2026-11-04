local t = dofile("tests/helpers.lua")
local toolchain = require("toolchain")
local function setup(requirements)
  toolchain.setup({ requirements = requirements, notify = false, log_file = false })
end
local function run()
  toolchain.install()
  assert(toolchain.wait(1000))
  return toolchain.status()
end

t.test("missing backend dependencies fail tasks without blocking other work", function()
  setup({ { provider = "mason", name = "fixture" }, { provider = "treesitter", name = "fixture" } })
  local tasks = run()
  t.eq(tasks[1].state, "failed")
  t.eq(tasks[2].state, "failed")
end)

t.test("Mason registry refresh coalesces and installer failures release slots", function()
  package.loaded.mason = { has_setup = true }
  local refreshes, hooks = 0, 0
  local callbacks = {}
  package.loaded["mason-registry"] = {
    refresh = function(callback)
      refreshes = refreshes + 1
      vim.defer_fn(function()
        callback(true, {})
      end, 20)
    end,
    get_package = function(name)
      return {
        is_installing = function()
          return false
        end,
        is_installed = function()
          return name == "existing"
        end,
        install = function(_, _, callback)
          callbacks[name] = callback
          vim.defer_fn(function()
            callback(name == "good", "fixture failure")
          end, 20)
          return {
            on = function(_, _, log)
              log("fixture output")
            end,
          }
        end,
      }
    end,
  }
  setup({
    {
      provider = "mason",
      name = "good",
      post_install = function(pkg)
        assert(pkg)
        hooks = hooks + 1
      end,
    },
    { provider = "mason", name = "bad" },
  })
  local tasks = run()
  t.eq(refreshes, 1)
  t.eq(hooks, 1)
  t.eq(tasks[1].state, "installed")
  t.eq(tasks[2].state, "failed")
  assert(#tasks[1].logs >= 2)
  callbacks.good(false, "late duplicate")
  vim.wait(30, function()
    return false
  end)
  t.eq(toolchain.status()[1].state, "installed")
  setup({
    {
      provider = "mason",
      name = "existing",
      post_install = function()
        hooks = hooks + 1
      end,
    },
  })
  t.eq(run()[1].state, "skipped")
  t.eq(hooks, 2)
end)

t.test("Mason registry errors, unknown packages and hook errors become failures", function()
  package.loaded["mason-registry"] = {
    refresh = function(callback)
      callback(false, "offline")
    end,
  }
  setup({ { provider = "mason", name = "fixture" } })
  assert(run()[1].message:find("refresh failed", 1, true))
  package.loaded["mason-registry"] = {
    refresh = function(callback)
      callback(true, {})
    end,
    get_package = function()
      error("Unknown package")
    end,
  }
  setup({ { provider = "mason", name = "fixture" } })
  t.eq(run()[1].state, "failed")
  package.loaded["mason-registry"].get_package = function()
    return {
      is_installing = function()
        return false
      end,
      is_installed = function()
        return true
      end,
    }
  end
  setup({
    {
      provider = "mason",
      name = "fixture",
      post_install = function()
        error("hook failed")
      end,
    },
  })
  t.eq(run()[1].state, "failed")
end)

t.test("Tree-sitter detects false results and never confuses queries with parsers", function()
  local installed, succeeds, calls = {}, false, 0
  package.loaded["nvim-treesitter"] = {
    get_available = function()
      return { "fixture" }
    end,
    get_installed = function(kind)
      t.eq(kind, "parsers")
      return installed
    end,
    install = function(names, opts)
      calls = calls + 1
      t.eq(names, { "fixture" })
      t.eq(opts.max_jobs, 1)
      assert(opts.force)
      return {
        await = function(_, callback)
          vim.schedule(function()
            if succeeds then
              installed = { "fixture" }
            end
            callback(nil, succeeds)
          end)
        end,
      }
    end,
  }
  setup({ { provider = "treesitter", name = "fixture" } })
  t.eq(run()[1].state, "failed")
  succeeds = true
  toolchain.retry()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "installed")
  toolchain.install()
  assert(toolchain.wait(1000))
  t.eq(toolchain.status()[1].state, "skipped")
  t.eq(calls, 2)
  setup({ { provider = "treesitter", name = "unknown" } })
  assert(run()[1].message:find("Unknown Tree-sitter parser", 1, true))
end)

t.test("Tree-sitter task errors and unsupported legacy APIs fail explicitly", function()
  local ts = package.loaded["nvim-treesitter"]
  ts.get_installed = function()
    return {}
  end
  ts.install = function()
    return {
      await = function(_, callback)
        callback("compiler failed")
      end,
    }
  end
  setup({ { provider = "treesitter", name = "fixture" } })
  assert(run()[1].message:find("compiler failed", 1, true))
  package.loaded["nvim-treesitter"] = {}
  setup({ { provider = "treesitter", name = "fixture" } })
  assert(run()[1].message:find("legacy", 1, true))
end)

t.done()
