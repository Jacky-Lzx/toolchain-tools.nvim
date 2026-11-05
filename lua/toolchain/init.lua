local M = {}
local config = require("toolchain.config")
local options, queue, lock_operation, lock_finish
local log_error_reported = false

local function changed(event)
  if lock_finish then
    lock_finish()
  end
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
  if (spec.provider == "mason" or spec.provider == "tool") and not spec.unlocked then
    local path = require("toolchain.backends.system").external(spec)
    if path then
      return ctx.done("skipped", "Using existing executable: " .. path)
    end
  end
  return require("toolchain.backends." .. spec.provider).install(spec, ctx)
end

local function ensure_setup()
  if not options then
    M.setup()
  end
end

function M.setup(opts)
  assert(not queue or not queue:busy(), "Cannot reconfigure toolchain-tools while tasks are queued or running")
  assert(
    not lock_operation or (lock_operation.state ~= "resolving" and lock_operation.state ~= "writing"),
    "Cannot reconfigure while a lock operation is active"
  )
  local new_options = config.options(opts)
  require("toolchain.parsers").setup(new_options.parsers)
  require("toolchain.tools").setup(new_options.tools)
  options = new_options
  require("toolchain.parsers").activate()
  require("toolchain.tools").activate()
  log_error_reported = false
  queue = nil
  require("toolchain.commands").setup()
end

-- Installation scheduling is irrelevant until an operation needs a queue.
-- Parser/query mounting, tool PATH and session protection remain synchronous.
local function ensure_queue()
  ensure_setup()
  if not queue then
    queue = require("toolchain.queue").new({
      concurrency = options.concurrency,
      max_log_lines = options.max_log_lines,
      execute = execute,
      on_change = changed,
    })
  end
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
    if spec.provider ~= "treesitter" and spec.provider ~= "parser" and not spec.unlocked then
      local system = require("toolchain.backends.system")
      local ok, path =
        pcall((spec.provider == "mason" or spec.provider == "tool") and system.external or system.find, spec)
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
  ensure_queue()
  return queue:submit(requirements(input))
end

function M.install_ids(ids)
  ensure_queue()
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

function M.lock(path, update)
  ensure_queue()
  local specs, names = {}, {}
  for _, spec in ipairs(requirements()) do
    if spec.provider == "tool" then
      names[#names + 1] = spec.name
      local forced = vim.deepcopy(spec)
      forced.unlocked = true
      specs[#specs + 1] = forced
    end
  end
  assert(#names > 0, "No independent tools are configured")
  assert(not queue:busy(), "Wait for current installations before writing the lock")
  path = path or require("toolchain.tools").lockfile()
  path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
  local function write()
    local result = require("toolchain.tools").export_lock(path, names)
    lock_operation = { state = "written", path = result }
    local observed, problem = pcall(
      vim.api.nvim_exec_autocmds,
      "User",
      { pattern = "ToolchainLockWritten", modeline = false, data = { path = result } }
    )
    if not observed and options.notify then
      vim.notify("Lock observer failed: " .. tostring(problem), vim.log.levels.WARN)
    end
    if options.notify then
      vim.notify("Wrote toolchain lock: " .. result, vim.log.levels.INFO)
    end
    return result
  end
  if not update then
    lock_operation = { state = "writing", path = path }
    local ok, result = pcall(write)
    if not ok then
      lock_operation = { state = "failed", path = path, error = tostring(result) }
    end
    assert(ok, result)
    return result
  end
  assert(not queue:busy(), "Wait for current installations before updating the lock")
  lock_operation = { state = "resolving", path = path }
  local ids, finished
  local function finish()
    if finished or not ids or queue:busy() then
      return
    end
    finished, lock_finish = true, nil
    for _, task in ipairs(queue:snapshot()) do
      if vim.list_contains(ids, task.id) and task.state ~= "installed" and task.state ~= "skipped" then
        lock_operation = { state = "failed", path = path, error = task.id .. ": " .. task.message }
        if options.notify then
          vim.notify("Toolchain lock retained: " .. lock_operation.error, vim.log.levels.ERROR)
        end
        return
      end
    end
    lock_operation.state = "writing"
    local ok, err = pcall(write)
    if not ok then
      lock_operation = { state = "failed", path = path, error = tostring(err) }
      if options.notify then
        vim.notify(tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  lock_finish = finish
  local ok, result = pcall(queue.submit, queue, specs)
  if not ok then
    lock_finish = nil
    lock_operation = { state = "failed", path = path, error = tostring(result) }
    error(result)
  end
  ids = result
  vim.schedule(finish)
  return ids
end

function M.lock_status()
  return vim.deepcopy(lock_operation)
end

function M.status()
  ensure_setup()
  return queue and queue:snapshot() or {}
end

function M.retry(ids)
  ensure_queue()
  return queue:retry(ids)
end

function M.cancel(id)
  ensure_queue()
  return queue:cancel(id)
end

function M.wait(timeout)
  ensure_setup()
  assert(
    type(timeout) == "number" and timeout >= 0 and timeout < math.huge,
    "wait requires a finite timeout in milliseconds"
  )
  local function idle()
    return (not queue or not queue:busy())
      and not (lock_operation and (lock_operation.state == "resolving" or lock_operation.state == "writing"))
  end
  local finished = idle() or vim.wait(timeout, idle, 10)
  return finished, queue and queue:snapshot() or {}
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
