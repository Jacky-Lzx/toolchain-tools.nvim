local M = {}
local config = require("toolchain.config")
local options, queue
local log_error_reported = false

local function changed(event)
  if options.log_file then
    local ok, err = pcall(function()
      vim.fn.mkdir(vim.fs.dirname(options.log_file), "p")
      local record = vim.tbl_extend("force", { time = os.date("!%Y-%m-%dT%H:%M:%SZ") }, event)
      assert(vim.fn.writefile({ vim.json.encode(record) }, options.log_file, "a") == 0, "cannot append log")
    end)
    if not ok and not log_error_reported then
      log_error_reported = true
      vim.notify("toolchain log unavailable: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  if options.notify and event.state == "failed" then
    vim.notify(event.id .. ": " .. event.message, vim.log.levels.ERROR, { title = "toolchain-tools" })
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "ToolchainUpdated", modeline = false, data = event })
end

local function execute(spec, ctx)
  if spec.provider == "mason" then
    local path = require("toolchain.backends.system").external(spec)
    if path then
      return ctx.done("skipped", "Using existing executable: " .. path)
    end
  end
  return require("toolchain.backends." .. spec.provider).install(spec, ctx)
end

local function ensure_setup()
  if not queue then
    M.setup()
  end
end

function M.setup(opts)
  assert(not queue or not queue:busy(), "Cannot reconfigure toolchain-tools while tasks are queued or running")
  local new_options = config.options(opts)
  require("toolchain.parsers").setup(new_options.parsers)
  options = new_options
  require("toolchain.parsers").activate()
  log_error_reported = false
  queue = require("toolchain.queue").new({
    concurrency = options.concurrency,
    max_log_lines = options.max_log_lines,
    execute = execute,
    on_change = changed,
  })
  require("toolchain.commands").setup()
end

local function requirements(input)
  if input == nil then
    input = options.requirements
    if type(input) == "function" then
      input = input()
    end
  end
  return config.normalize(input)
end

-- Resolves local executables only: no backend modules, registries or downloads.
function M.plan(input)
  ensure_setup()
  local result = {}
  for _, spec in ipairs(requirements(input)) do
    local state, message = "check", "Check the backend when installation is requested"
    if spec.provider ~= "treesitter" and spec.provider ~= "parser" then
      local system = require("toolchain.backends.system")
      local ok, path = pcall(spec.provider == "mason" and system.external or system.find, spec)
      if not ok then
        state, message = "failed", tostring(path)
      elseif path then
        state, message = "available", "Using " .. path
      elseif spec.provider == "system" then
        state = spec.optional and "unavailable" or "missing"
        message = spec.optional and "Optional executable is unavailable; install it if needed"
          or "Install this executable with your system package manager"
      end
    end
    result[#result + 1] = {
      id = spec.provider .. ":" .. spec.name,
      provider = spec.provider,
      name = spec.name,
      optional = spec.optional == true,
      state = state,
      message = message,
    }
  end
  return result
end

function M.install(input)
  ensure_setup()
  return queue:submit(requirements(input))
end

function M.install_ids(ids)
  ensure_setup()
  assert(type(ids) == "table" and vim.islist(ids), "ids must be a list")
  local configured, selected, result = {}, {}, {}
  for _, spec in ipairs(requirements()) do
    configured[spec.provider .. ":" .. spec.name] = spec
  end
  for _, id in ipairs(ids) do
    assert(configured[id], "Unknown configured requirement: " .. tostring(id))
    if not selected[id] then
      selected[id] = true
      result[#result + 1] = configured[id]
    end
  end
  return queue:submit(result)
end

function M.status()
  ensure_setup()
  return queue:snapshot()
end

function M.retry(ids)
  ensure_setup()
  return queue:retry(ids)
end

function M.cancel(id)
  ensure_setup()
  return queue:cancel(id)
end

function M.wait(timeout)
  ensure_setup()
  assert(
    type(timeout) == "number" and timeout >= 0 and timeout < math.huge,
    "wait requires a finite timeout in milliseconds"
  )
  local finished = not queue:busy() or vim.wait(timeout, function()
    return not queue:busy()
  end, 10)
  return finished, queue:snapshot()
end

function M.log_file()
  ensure_setup()
  return options.log_file
end

function M.open()
  ensure_setup()
  require("toolchain.ui").open(false)
end

return M
