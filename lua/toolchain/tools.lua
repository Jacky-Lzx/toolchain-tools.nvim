local M = {}
local util = require("toolchain.parser_util")
local uv = vim.uv
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local options, registry
local inflight, activated_paths = {}, {}

local function name(value)
  assert(type(value) == "string" and value:match("^[%w_][%w_.+-]*$"), "Invalid tool name: " .. tostring(value))
  return value
end

local function canonical(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  local keys, parts = vim.tbl_keys(value), {}
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = vim.json.encode(key) .. ":" .. canonical(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.setup(opts)
  opts = opts or {}
  for key in pairs(opts) do
    assert(vim.list_contains({ "install_dir", "sources", "path" }, key), "Unknown tools option: " .. key)
  end
  local new = vim.tbl_extend("force", {
    install_dir = vim.fn.stdpath("data") .. "/toolchain-tools/tools",
    sources = {},
    path = "append",
  }, opts)
  assert(type(new.install_dir) == "string" and new.install_dir ~= "", "Invalid tools.install_dir")
  new.install_dir = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(new.install_dir), ":p")):gsub("/+$", "")
  assert(new.install_dir ~= "", "Tools directory cannot be the filesystem root")
  assert(type(new.sources) == "table", "tools.sources must be a package table")
  assert(new.path == "append" or new.path == "skip", "tools.path must be append or skip")
  options, registry = new, nil
end

local function settings()
  if not options then
    M.setup()
  end
  return options
end

function M.definition(package_name)
  name(package_name)
  if not registry then
    registry = assert(util.json(plugin .. "/data/tools.json"), "Cannot read bundled tool registry").packages
    for key, entry in pairs(settings().sources) do
      name(key)
      registry[key] = vim.deepcopy(entry)
    end
  end
  local entry = assert(registry[package_name], "Unknown independent tool: " .. package_name)
  assert(type(entry) == "table" and type(entry.kind) == "string", "Invalid tool recipe: " .. package_name)
  assert(type(entry.version) == "string" and entry.version ~= "", "Tool version must be pinned")
  assert(type(entry.bin) == "table" and next(entry.bin), "Tool recipe needs bin entries")
  for command, target in pairs(entry.bin) do
    name(command)
    assert(type(target) == "table", "Tool binary descriptor must be a table")
    util.relative(target.path)
    assert(target.interpreter == nil or type(target.interpreter) == "string", "Invalid interpreter")
    assert(target.args == nil or vim.islist(target.args), "Invalid binary arguments")
  end
  for key, path in pairs(entry.resources or {}) do
    name(key)
    util.relative(path)
  end
  return vim.deepcopy(entry)
end

local function active(package_name)
  name(package_name)
  local pointer = util.json(settings().install_dir .. "/current/" .. package_name .. ".json")
  if pointer and type(pointer.version) == "string" and pointer.version:match("^[a-f0-9]+%-%d+%-%d+$") then
    return settings().install_dir .. "/versions/" .. package_name .. "/" .. pointer.version
  end
end

local function receipt(package_name)
  local root = active(package_name)
  local value = root and util.json(root .. "/receipt.json")
  if value and value.schema == 1 and value.name == package_name and type(value.bin) == "table" then
    return root, value
  end
end

function M.path(package_name, resource)
  local root, value = receipt(package_name)
  if not root then
    return
  end
  if not resource then
    return root
  end
  local path = value.resources and value.resources[resource]
  return path and uv.fs_stat(root .. "/" .. path) and root .. "/" .. path or nil
end

function M.executable(package_name, command)
  local root, value = receipt(package_name)
  command = command or package_name
  if root and value.bin[command] and vim.fn.executable(root .. "/bin/" .. name(command)) == 1 then
    return root .. "/bin/" .. command
  end
end

function M.owns(path)
  local root = settings().install_dir
  for _, directory in ipairs({ root, vim.fn.stdpath("data") .. "/mason" }) do
    directory = vim.fs.normalize(uv.fs_realpath(directory) or directory)
    local real = vim.fs.normalize(uv.fs_realpath(path) or path)
    if vim.startswith(real, directory .. "/") then
      return true
    end
  end
  return false
end

-- Activate only installed directories. Setup and resolution never create files.
function M.activate()
  local paths, remove = {}, {}
  for _, path in ipairs(activated_paths) do
    remove[path] = true
  end
  for _, path in ipairs(vim.split(vim.env.PATH or "", ":", { plain = true })) do
    if not remove[path] then
      paths[#paths + 1] = path
    end
  end
  activated_paths = {}
  local current = settings().install_dir .. "/current"
  if settings().path == "append" and vim.fn.isdirectory(current) == 1 then
    local packages = {}
    for file, kind in vim.fs.dir(current) do
      if kind == "file" and file:match("%.json$") then
        packages[#packages + 1] = file:sub(1, -6)
      end
    end
    table.sort(packages)
    for _, package_name in ipairs(packages) do
      local root = receipt(package_name)
      if root and vim.fn.isdirectory(root .. "/bin") == 1 then
        activated_paths[#activated_paths + 1] = root .. "/bin"
      end
    end
  end
  vim.list_extend(paths, activated_paths)
  vim.env.PATH = table.concat(paths, ":")
end

local function fingerprint(entry)
  local os = uv.os_uname()
  return util.hash("toolchain-tool-v1\n" .. os.sysname .. "\n" .. os.machine .. "\n" .. canonical(entry))
end

local function artifacts(root)
  local result = {}
  local function scan(directory, prefix)
    for file, kind in vim.fs.dir(directory) do
      local relative = prefix .. file
      local path = directory .. "/" .. file
      if kind == "directory" then
        scan(path, relative .. "/")
      elseif kind == "link" then
        result[relative] = { link = assert(uv.fs_readlink(path)) }
      elseif kind == "file" and relative ~= "receipt.json" then
        local stat = assert(uv.fs_stat(path))
        -- Large native libraries are hashed by a streaming host utility.
        local hash
        if stat.size > 8 * 1024 * 1024 then
          local process = vim.system({ "shasum", "-a", "256", path }, { text = true }):wait()
          assert(process.code == 0, process.stderr)
          hash = process.stdout:match("^([a-f0-9]+)")
        else
          hash = util.hash(util.read(path))
        end
        result[relative] = { hash = hash, mode = stat.mode }
      else
        assert(kind == "file", "Unsupported tool artifact: " .. path)
      end
    end
  end
  scan(root, "")
  return result
end

local function intact(root, desired)
  local value = root and util.json(root .. "/receipt.json")
  if not value or value.schema ~= 1 or value.fingerprint ~= desired then
    return false
  end
  local ok, actual = pcall(artifacts, root)
  return ok and vim.deep_equal(actual, value.artifacts)
end

function M.info(package_name)
  local root, value = receipt(package_name)
  return { current = root, receipt = value, intact = intact(root, fingerprint(M.definition(package_name))) }
end

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function wrappers(root, entry)
  vim.fn.mkdir(root .. "/bin", "p")
  for command, descriptor in pairs(entry.bin) do
    local path = root .. "/" .. descriptor.path
    assert(uv.fs_stat(path), "Missing tool entrypoint: " .. path)
    local args = {}
    if descriptor.interpreter then
      local interpreter = descriptor.interpreter == "python" and (root .. "/venv/bin/python")
        or vim.fn.exepath(descriptor.interpreter)
      assert(
        interpreter ~= "" and vim.fn.executable(interpreter) == 1,
        "Missing interpreter: " .. descriptor.interpreter
      )
      args[#args + 1] = quote(interpreter)
    else
      assert(uv.fs_chmod(path, 493))
    end
    if descriptor.module then
      vim.list_extend(args, { "-m", quote(descriptor.module) })
    else
      args[#args + 1] = quote(path)
    end
    for _, argument in ipairs(descriptor.args or {}) do
      args[#args + 1] = quote(argument)
    end
    local wrapper = root .. "/bin/" .. command
    assert(path ~= wrapper, "Tool entrypoints must be outside the wrapper bin directory")
    assert(vim.fn.writefile({ "#!/bin/sh", "exec " .. table.concat(args, " ") .. ' "$@"' }, wrapper) == 0)
    assert(uv.fs_chmod(wrapper, 493))
  end
  for key, path in pairs(entry.resources or {}) do
    assert(uv.fs_stat(root .. "/" .. path), "Missing tool resource: " .. key)
  end
end

local function hook(spec, root, entry, log)
  if not (spec.post_install or spec.post_install_async) then
    return
  end
  local package_info = { name = spec.name, path = root, version = entry.version, resources = entry.resources or {} }
  if spec.post_install_async then
    local err = util.await(function(done)
      spec.post_install_async(package_info, done, log)
    end)
    assert(err == nil, "post_install failed: " .. tostring(err))
  else
    spec.post_install(package_info)
  end
end

function M.install(spec, ctx)
  assert(not inflight[spec.name], "Tool is already installing: " .. spec.name)
  inflight[spec.name] = true
  local root, release, published
  util.run(function()
    assert(vim.fn.has("win32") == 0, "Independent tools currently support macOS and Linux")
    local entry = M.definition(spec.name)
    release = util.lock(settings().install_dir .. "/locks/" .. spec.name .. ".lock")
    local desired, previous = fingerprint(entry), active(spec.name)
    if intact(previous, desired) then
      M.activate()
      return "skipped"
    end
    local token = desired:sub(1, 16) .. string.format("-%d-%.0f", uv.os_getpid(), uv.hrtime())
    -- Build at the permanent version path: Python venv shebangs cannot be relocated.
    root = settings().install_dir .. "/versions/" .. spec.name .. "/" .. token
    vim.fn.mkdir(root, "p")
    local metadata = require("toolchain.tool_installers").install(entry, root, ctx.log, previous)
    hook(spec, root, entry, ctx.log)
    wrappers(root, entry)
    util.write_json(root .. "/receipt.json", {
      schema = 1,
      name = spec.name,
      version = entry.version,
      recipe = entry,
      fingerprint = desired,
      bin = entry.bin,
      resources = entry.resources or {},
      metadata = metadata or {},
      artifacts = artifacts(root),
    })
    local directory = settings().install_dir .. "/current"
    vim.fn.mkdir(directory, "p")
    local pointer = directory .. "/." .. spec.name .. "-" .. token .. ".json"
    util.write_json(pointer, { version = token })
    assert(uv.fs_rename(pointer, directory .. "/" .. spec.name .. ".json"))
    published = true
    M.activate()
    return "installed"
  end, function(ok, result)
    if release then
      release()
    end
    if root and not published then
      vim.fn.delete(root, "rf")
    end
    inflight[spec.name] = nil
    ctx.done(
      ok and result or "failed",
      ok and (result == "installed" and "Installed independently" or "Managed artifacts are intact") or tostring(result)
    )
  end)
end

return M
