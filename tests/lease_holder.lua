vim.opt.rtp:prepend(vim.fn.getcwd())
local store, ready, stop = assert(arg[1]), assert(arg[2]), assert(arg[3])
local tc = require("toolchain")
tc.setup({
  notify = false,
  log_file = false,
  tools = {
    path = arg[4] or "append",
    install_dir = store,
    sources = {
      fixture = {
        kind = "commands",
        version = "1.0.0",
        commands = { { "sh", vim.fn.getcwd() .. "/tests/tool-fixture.sh", "{root}", "1.0.0" } },
        bin = { ["fixture-tool"] = { path = "libexec/fixture" } },
      },
    },
  },
})
tc.install({ { provider = "tool", name = "fixture" } })
assert(tc.wait(10000) and (tc.status()[1].state == "installed" or tc.status()[1].state == "skipped"))
require("toolchain.parser_util").write_json(
  ready,
  { root = require("toolchain.tools").path("fixture"), pid = vim.uv.os_getpid() }
)
assert(
  vim.wait(90000, function()
    return vim.fn.filereadable(stop) == 1
  end, 20),
  "Lease holder timed out"
)
