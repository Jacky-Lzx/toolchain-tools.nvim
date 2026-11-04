vim.opt.rtp:prepend(vim.fn.getcwd())
local tc, tools = require("toolchain"), require("toolchain.tools")
local temp = assert(vim.env.TOOLCHAIN_VERSIONS_TMP)
local function setup(version)
  tc.setup({
    notify = false,
    log_file = false,
    tools = {
      install_dir = temp .. "/store",
      sources = {
        fixture = {
          kind = "commands",
          version = version,
          commands = { { "sh", vim.fn.getcwd() .. "/tests/tool-fixture.sh", "{root}", version } },
          bin = { ["fixture-tool"] = { path = "libexec/fixture" } },
        },
      },
    },
    requirements = { { provider = "tool", name = "fixture" } },
  })
  tc.install()
  assert(tc.wait(10000) and tc.status()[1].state == "installed")
  return tools.path("fixture")
end
local first = setup("1.0.0")
local second = setup("2.0.0")
vim.fn.writefile({ vim.fs.basename(first) }, temp .. "/rollback-id")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local unsaved = true" })
local source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local stage, timer = nil, vim.uv.new_timer()
local function mark(value)
  stage = value
  vim.fn.writefile({ value }, temp .. "/stage")
end
mark("versions")
local function check()
  local report = vim.bo.filetype == "toolchain-versions"
  if stage == "versions" and report then
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(text:find("1.0.0", 1, true) and text:find("2.0.0", 1, true) and not vim.bo.modifiable)
    mark("close_versions")
  elseif stage == "close_versions" and vim.api.nvim_get_current_win() == win then
    mark("rollback")
  elseif stage == "rollback" and tools.path("fixture") == first then
    assert(vim.system({ tools.executable("fixture", "fixture-tool") }, { text = true }):wait().stdout == "1.0.0\n")
    mark("prune")
  elseif stage == "prune" and report then
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(text:find("No files deleted", 1, true) and text:find("live session", 1, true))
    assert(vim.fn.isdirectory(first) == 1 and vim.fn.isdirectory(second) == 1)
    mark("close_prune")
  elseif stage == "close_prune" and vim.api.nvim_get_current_win() == win then
    assert(vim.api.nvim_get_current_buf() == source and vim.bo[source].modified)
    assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "local unsaved = true")
    timer:stop()
    timer:close()
    vim.fn.writefile(
      { "PASS versions, rollback, read-only prune, live leases and unsaved source preservation" },
      temp .. "/result"
    )
    vim.cmd("qa!")
  end
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(check, debug.traceback)
    if not ok then
      timer:stop()
      timer:close()
      vim.fn.writefile(vim.split(err, "\n", { plain = true }), temp .. "/result")
      vim.cmd("cquit 1")
    end
  end)
)
