local Queue = {}
Queue.__index = Queue

local terminal = { installed = true, skipped = true, failed = true, cancelled = true }

function Queue.new(opts)
  return setmetatable({
    limit = opts.concurrency,
    max_log_lines = opts.max_log_lines,
    execute = opts.execute,
    on_change = opts.on_change or function() end,
    tasks = {},
    order = {},
    pending = {},
    active = 0,
  }, Queue)
end

function Queue:snapshot()
  local result = {}
  for _, id in ipairs(self.order) do
    local task = self.tasks[id]
    result[#result + 1] = {
      id = id,
      provider = task.spec.provider,
      name = task.spec.name,
      state = task.state,
      attempt = task.attempt,
      message = task.message,
      logs = vim.deepcopy(task.logs),
    }
  end
  return result
end

function Queue:changed(task, message)
  local ok, err = pcall(self.on_change, {
    id = task.id,
    state = task.state,
    attempt = task.attempt,
    message = tostring(message or task.message or ""),
  })
  if not ok then
    vim.schedule(function()
      vim.notify("toolchain observer failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

function Queue:log(task, message)
  if terminal[task.state] then
    return
  end
  -- Keep bounded chunks as well as a bounded count (installer output can be large).
  local text = tostring(message):sub(1, 8192)
  task.logs[#task.logs + 1] = text
  if #task.logs > self.max_log_lines then
    table.remove(task.logs, 1)
  end
  self:changed(task, text)
end

function Queue:schedule()
  if self.scheduled then
    return
  end
  self.scheduled = true
  vim.schedule(function()
    self.scheduled = false
    self:pump()
  end)
end

function Queue:submit(specs)
  -- Validate the entire submission before modifying the queue.
  for _, spec in ipairs(specs) do
    local id = spec.provider .. ":" .. spec.name
    local previous = self.tasks[id]
    assert(
      not previous or terminal[previous.state] or vim.deep_equal(previous.spec, spec),
      "conflicting active requirement: " .. id
    )
  end
  local ids = {}
  for _, spec in ipairs(specs) do
    local id = spec.provider .. ":" .. spec.name
    ids[#ids + 1] = id
    local previous = self.tasks[id]
    if not previous or terminal[previous.state] then
      local task = {
        id = id,
        spec = vim.deepcopy(spec),
        state = "queued",
        attempt = previous and previous.attempt + 1 or 1,
        message = "Waiting for an installation slot",
        logs = {},
      }
      if not previous then
        self.order[#self.order + 1] = id
      end
      self.tasks[id] = task
      self.pending[#self.pending + 1] = task
      self:changed(task)
    end
  end
  self:schedule()
  return ids
end

function Queue:pump()
  while self.active < self.limit and #self.pending > 0 do
    local task = table.remove(self.pending, 1)
    if task.state == "queued" then
      self.active = self.active + 1
      task.state, task.message = "running", "Checking and installing"
      self:changed(task)
      local finished = false
      local function done(state, message)
        if finished then
          return
        end
        finished = true
        vim.schedule(function()
          if state ~= "installed" and state ~= "skipped" and state ~= "failed" then
            state, message = "failed", "Backend returned an invalid result"
          end
          task.state, task.message = state, tostring(message or state)
          self.active = self.active - 1
          self:changed(task)
          self:schedule()
        end)
      end
      local ok, err = pcall(self.execute, task.spec, {
        done = done,
        log = function(message)
          vim.schedule(function()
            self:log(task, message)
          end)
        end,
      })
      if not ok then
        done("failed", tostring(err))
      end
    end
  end
end

function Queue:busy()
  if self.active > 0 then
    return true
  end
  for _, task in ipairs(self.pending) do
    if task.state == "queued" then
      return true
    end
  end
  return false
end

function Queue:cancel(id)
  local task = self.tasks[id]
  if not task then
    return false, "Unknown task: " .. tostring(id)
  elseif task.state ~= "queued" then
    return false, "Only queued tasks can be cancelled; running installers keep their slot until completion"
  end
  task.state, task.message = "cancelled", "Cancelled before installation started"
  self:changed(task)
  return true
end

function Queue:retry(ids)
  local specs = {}
  if ids then
    for _, id in ipairs(ids) do
      local task = self.tasks[id]
      assert(task and (task.state == "failed" or task.state == "cancelled"), "task is not retryable: " .. id)
      specs[#specs + 1] = task.spec
    end
  else
    for _, id in ipairs(self.order) do
      local task = self.tasks[id]
      if task.state == "failed" or task.state == "cancelled" then
        specs[#specs + 1] = task.spec
      end
    end
  end
  return self:submit(specs)
end

return Queue
