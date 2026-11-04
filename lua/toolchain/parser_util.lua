local M = {}
local uv = vim.uv

function M.read(path)
  local file = assert(io.open(path, "rb"))
  local value = file:read("*a")
  file:close()
  return value
end

function M.json(path)
  local ok, value = pcall(function()
    return vim.json.decode(M.read(path))
  end)
  return ok and value or nil
end

function M.write_json(path, value)
  assert(vim.fn.writefile({ vim.json.encode(value) }, path) == 0, "Cannot write " .. path)
end

function M.hash(value)
  return vim.fn.sha256(vim.base64.encode(value))
end

function M.name(name)
  assert(type(name) == "string" and name:match("^[a-z][a-z0-9_]*$"), "Invalid parser language: " .. tostring(name))
end

function M.relative(path)
  assert(type(path) == "string" and path ~= "" and not path:find("\\"), "Invalid relative path")
  assert(not path:match("^/") and not path:match("^%a:"), "Path must be relative: " .. path)
  for part in path:gmatch("[^/]+") do
    assert(part ~= "..", "Path must stay inside its source: " .. path)
  end
  return path
end

function M.source(source)
  assert(type(source) == "table", "Missing parser/query source")
  for key in pairs(source) do
    assert(
      vim.list_contains({ "url", "revision", "location", "generate", "generate_from_json", "queries" }, key),
      "Unknown parser source field: " .. tostring(key)
    )
  end
  assert(type(source.url) == "string" and source.url ~= "" and not source.url:match("^%-"), "Invalid source URL")
  assert(
    type(source.revision) == "string" and source.revision:match("^[a-f0-9]+$") and #source.revision == 40,
    "Source revision must be a full commit SHA"
  )
  if source.location then
    M.relative(source.location)
  end
  if source.queries then
    M.relative(source.queries)
  end
  assert(source.generate == nil or type(source.generate) == "boolean", "generate must be a boolean")
  assert(
    source.generate_from_json == nil or type(source.generate_from_json) == "boolean",
    "generate_from_json must be a boolean"
  )
end

-- Await callback-based operations without depending on an upstream async library.
function M.run(fn, done)
  local thread = coroutine.create(fn)
  local function step(...)
    local ok, operation = coroutine.resume(thread, ...)
    if not ok then
      done(false, debug.traceback(thread, tostring(operation)))
    elseif coroutine.status(thread) == "dead" then
      done(true, operation)
    else
      local resumed = false
      local called, err = pcall(operation, function(...)
        if resumed then
          return
        end
        resumed = true
        local args, count = { ... }, select("#", ...)
        vim.schedule(function()
          step(unpack(args, 1, count))
        end)
      end)
      if not called and not resumed then
        done(false, tostring(err))
      end
    end
  end
  step()
end

function M.await(operation)
  return coroutine.yield(operation)
end

function M.command(cmd, opts, log)
  log("$ " .. table.concat(cmd, " "))
  local result = M.await(function(done)
    local ok, err = pcall(vim.system, cmd, vim.tbl_extend("force", { text = true, timeout = 180000 }, opts or {}), done)
    if not ok then
      done({ code = 125, stderr = tostring(err) })
    end
  end)
  if result.stdout and result.stdout ~= "" then
    log(result.stdout)
  end
  if result.stderr and result.stderr ~= "" then
    log(result.stderr)
  end
  assert(result.code == 0, cmd[1] .. " failed (exit " .. result.code .. "): " .. (result.stderr or ""))
  return result.stdout or ""
end

function M.lock(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd, err = uv.fs_open(path, "wx", 384)
  if not fd then
    local owner = M.json(path)
    if owner and type(owner.pid) == "number" and owner.pid > 0 then
      local alive, reason = uv.kill(owner.pid, 0)
      if not alive and tostring(reason):find("ESRCH", 1, true) then
        assert(uv.fs_unlink(path))
        fd, err = uv.fs_open(path, "wx", 384)
      end
    end
  end
  assert(fd, "Installation is locked by another process: " .. path .. " (" .. tostring(err) .. ")")
  assert(uv.fs_write(fd, vim.json.encode({ pid = uv.os_getpid() }), 0))
  uv.fs_close(fd)
  return function()
    uv.fs_unlink(path)
  end
end

-- Copy only regular files/directories: never follow source-controlled symlinks.
function M.copy_tree(source, target)
  vim.fn.mkdir(target, "p")
  for name, kind in vim.fs.dir(source) do
    local from, to = vim.fs.joinpath(source, name), vim.fs.joinpath(target, name)
    if kind == "directory" then
      M.copy_tree(from, to)
    elseif kind == "file" then
      assert(uv.fs_copyfile(from, to))
    else
      error("Unsupported source entry: " .. from)
    end
  end
end

function M.files(root, prefix, result)
  prefix, result = prefix or "", result or {}
  for name, kind in vim.fs.dir(root) do
    local relative = prefix .. name
    if kind == "directory" then
      M.files(vim.fs.joinpath(root, name), relative .. "/", result)
    elseif kind == "file" then
      result[relative] = M.hash(M.read(vim.fs.joinpath(root, name)))
    end
  end
  return result
end

return M
