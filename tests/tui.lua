vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.TOOLCHAIN_TUI_DIR)
local toolchain = require("toolchain")
local ready, stage = false, "initial"
local source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "unsaved source", "keep this text" })
local errors = {}
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then
    errors[#errors + 1] = message
  end
end
local function next_stage(name)
  stage = name
  vim.fn.writefile({ name }, root .. "/stage")
end
toolchain.setup({
  notify = false,
  log_file = root .. "/events.jsonl",
  requirements = {
    { provider = "system", name = "sh" },
    {
      provider = "system",
      name = "fixture",
      resolve = function()
        return ready and vim.fn.exepath("sh") or nil
      end,
    },
  },
})
vim.cmd("ToolchainPlan")
local plan_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_lines(plan_buf, 0, 1, false)[1]:find("local checks", 1, true))
next_stage("plan")
local timer = vim.uv.new_timer()
local function tick()
  local tasks = toolchain.status()
  if stage == "plan" and #tasks == 2 and tasks[2].state == "failed" then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if not lines[5]:find("failed", 1, true) then
      return
    end
    assert(tasks[1].state == "skipped")
    next_stage("installed")
  elseif stage == "installed" then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if lines[4] == "system:fixture  [failed]" then
      ready = true
      next_stage("detail")
    end
  elseif stage == "detail" and tasks[2].attempt == 2 and tasks[2].state == "skipped" then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if lines[4] == "system:fixture  [skipped]" then
      next_stage("retried")
    end
  elseif stage == "retried" and vim.o.columns == 40 then
    assert(vim.api.nvim_win_get_config(0).width == 36)
    next_stage("narrow")
  elseif stage == "narrow" and vim.api.nvim_get_current_win() == source_win then
    assert(not vim.api.nvim_buf_is_valid(plan_buf))
    vim.cmd("Toolchain")
    next_stage("reopened")
  elseif stage == "reopened" and vim.api.nvim_get_current_win() == source_win then
    assert(vim.api.nvim_get_current_buf() == source_buf)
    assert(vim.bo[source_buf].modified)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), { "unsaved source", "keep this text" }))
    vim.cmd("ToolchainLog")
    assert(vim.bo.buftype == "nofile" and not vim.bo.modifiable)
    vim.cmd("close")
    assert(vim.api.nvim_get_current_buf() == source_buf)
    assert(#errors == 0, table.concat(errors, "\n"))
    timer:stop()
    timer:close()
    vim.fn.writefile(
      { "PASS plan, install, details, retry, resize, close/reopen, logs, unsaved source preserved" },
      root .. "/result"
    )
    vim.cmd("qa!")
  end
end
timer:start(
  20,
  20,
  vim.schedule_wrap(function()
    local ok, err = xpcall(tick, debug.traceback)
    if not ok then
      timer:stop()
      timer:close()
      vim.fn.writefile({ "FAIL " .. err }, root .. "/result")
      vim.cmd("cquit 1")
    end
  end)
)
