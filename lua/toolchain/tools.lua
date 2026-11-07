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

function M.resolve(opts)
  assert(opts == nil or type(opts) == "table", "tools must be a table")
  opts = vim.deepcopy(opts or {})
  for key in pairs(opts) do
    assert(vim.list_contains({ "install_dir", "sources", "path", "lockfile" }, key), "Unknown tools option: " .. key)
  end
  local new = vim.tbl_extend("force", {
    install_dir = vim.fn.stdpath("data") .. "/toolchain-tools/tools",
    sources = {},
    path = "append",
    lockfile = false,
  }, opts)
  assert(type(new.install_dir) == "string" and new.install_dir ~= "", "Invalid tools.install_dir")
  new.install_dir = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(new.install_dir), ":p")):gsub("/+$", "")
  assert(new.install_dir ~= "", "Tools directory cannot be the filesystem root")
  assert(type(new.sources) == "table", "tools.sources must be a package table")
  assert(new.path == "append" or new.path == "skip", "tools.path must be append or skip")
  assert(new.lockfile == false or (type(new.lockfile) == "string" and new.lockfile ~= ""), "Invalid tools.lockfile")
  if new.lockfile then
    new.lockfile = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(new.lockfile), ":p"))
  end
  return new
end

function M.reset()
  options, registry = nil, nil
end

function M.setup(opts)
  options, registry = M.resolve(opts), nil
end

local function settings()
  if not options then
    M.setup()
  end
  return options
end

function M.definition(package_name, unlocked)
  name(package_name)
  local config = settings()
  if not registry then
    registry = assert(util.json(plugin .. "/data/tools.json"), "Cannot read bundled tool registry").packages
    for key, entry in pairs(config.sources) do
      name(key)
      registry[key] = vim.deepcopy(entry)
    end
  end
  local entry = config.lockfile and not unlocked and require("toolchain.tool_lock").entry(config.lockfile, package_name)
    or vim.deepcopy(assert(registry[package_name], "Unknown independent tool: " .. package_name))
  assert(type(entry) == "table" and type(entry.kind) == "string", "Invalid tool recipe: " .. package_name)
  assert(type(entry.version) == "string" and entry.version ~= "", "Tool version must be pinned")
  if entry.overrides ~= nil then
    assert(entry.kind == "npm" and type(entry.overrides) == "table", "npm overrides must be a package table")
    for package, version in pairs(entry.overrides) do
      assert(type(package) == "string" and package:match("^[%w@_./%-]+$"), "Invalid npm override package")
      assert(
        type(version) == "string" and version:match("^%d+%.%d+%.%d+[%w.%-]*$"),
        "npm overrides require exact versions"
      )
    end
  end
  if entry.kind == "download" then
    entry.bin = require("toolchain.tool_installers").asset(entry).bin
  end
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
    return settings().install_dir .. "/versions/" .. package_name .. "/" .. pointer.version, pointer
  end
end

local function receipt(package_name, full)
  local root, pointer = active(package_name)
  if
    not full
    and pointer
    and pointer.schema == 1
    and pointer.name == package_name
    and type(pointer.bin) == "table"
    and type(pointer.resources) == "table"
    and vim.fn.isdirectory(root) == 1
    and vim.fn.filereadable(root .. "/receipt.json") == 1
  then
    return root,
      {
        schema = 1,
        name = package_name,
        version = pointer.package_version,
        bin = pointer.bin,
        resources = pointer.resources,
      }
  end
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
  local paths, remove, roots = {}, {}, {}
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
  if vim.fn.isdirectory(current) == 1 then
    local packages = {}
    for file, kind in vim.fs.dir(current) do
      if kind == "file" and file:match("%.json$") then
        packages[#packages + 1] = file:sub(1, -6)
      end
    end
    table.sort(packages)
    for _, package_name in ipairs(packages) do
      local root = receipt(package_name)
      if root then
        roots[#roots + 1] = root
        if settings().path == "append" and vim.fn.isdirectory(root .. "/bin") == 1 then
          activated_paths[#activated_paths + 1] = root .. "/bin"
        end
      end
    end
  end
  vim.list_extend(paths, activated_paths)
  vim.env.PATH = table.concat(paths, ":")
  local ok, err = require("toolchain.tool_sessions").record(settings().install_dir, roots)
  if not ok and err then
    vim.notify("Toolchain session could not be recorded: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function fingerprint(entry)
  local os = uv.os_uname()
  return util.hash("toolchain-tool-v1\n" .. os.sysname .. "\n" .. os.machine .. "\n" .. canonical(entry))
end

local function consistent(value, package_name)
  return type(value) == "table"
    and value.schema == 1
    and value.name == package_name
    and type(value.recipe) == "table"
    and type(value.bin) == "table"
    and next(value.bin) ~= nil
    and value.version == value.recipe.version
    and vim.deep_equal(value.bin, value.recipe.bin)
    and vim.deep_equal(value.resources or {}, value.recipe.resources or {})
end

local function tracked(relative)
  return not ("/" .. relative):find("/__pycache__/", 1, true) and not relative:match("%.py[co]$")
end

local function artifacts(root)
  local result = {}
  local function scan(directory, prefix)
    for file, kind in vim.fs.dir(directory) do
      local relative = prefix .. file
      local path = directory .. "/" .. file
      if kind == "directory" then
        if file ~= "__pycache__" then
          scan(path, relative .. "/")
        end
      elseif kind == "link" then
        result[relative] = { link = assert(uv.fs_readlink(path)) }
      elseif kind == "file" and relative ~= "receipt.json" and tracked(relative) then
        local stat = assert(uv.fs_stat(path))
        -- Large native libraries are hashed by a streaming host utility.
        local hash
        if stat.size > 8 * 1024 * 1024 then
          local hash_command = vim.fn.executable("sha256sum") == 1 and { "sha256sum", path }
            or { "shasum", "-a", "256", path }
          local process = vim.system(hash_command, { text = true }):wait()
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
  if not value or value.schema ~= 1 or value.fingerprint ~= desired or type(value.artifacts) ~= "table" then
    return false
  end
  local ok, actual = pcall(artifacts, root)
  local expected = {}
  for relative, value in pairs(value.artifacts or {}) do
    if tracked(relative) then
      expected[relative] = value
    end
  end
  return ok and vim.deep_equal(actual, expected)
end

local function publish(package_name, root, value)
  local directory = settings().install_dir .. "/current"
  vim.fn.mkdir(directory, "p")
  local pointer = directory .. string.format("/.%s-%d-%.0f.json", package_name, uv.os_getpid(), uv.hrtime())
  util.write_json(pointer, {
    schema = 1,
    name = package_name,
    version = vim.fs.basename(root),
    package_version = value.version,
    bin = value.bin,
    resources = value.resources or {},
  })
  local ok, err = uv.fs_rename(pointer, directory .. "/" .. package_name .. ".json")
  if not ok then
    uv.fs_unlink(pointer)
  end
  assert(ok, err)
end

local function same_location(a, b)
  return (uv.fs_realpath(a) or vim.fs.normalize(a)) == (uv.fs_realpath(b) or vim.fs.normalize(b))
end

function M.installed(package_name)
  local root, value = receipt(package_name, true)
  local valid = consistent(value, package_name)
    and (not value.root or (type(value.root) == "string" and same_location(value.root, root)))
    and intact(root, fingerprint(value.recipe))
  return { current = root, receipt = value, intact = not not valid }
end

function M.info(package_name)
  local result = M.installed(package_name)
  result.intact = result.intact
    and require("toolchain.tool_lock").matches(result.current, result.receipt, M.definition(package_name))
  return result
end

function M.lockfile()
  return settings().lockfile or (vim.fn.getcwd() .. "/toolchain-lock.json")
end

function M.export_lock(path, names)
  local entries = {}
  for _, package_name in ipairs(names) do
    local info = M.installed(package_name)
    assert(
      info.current and info.intact,
      "Install/repair " .. package_name .. " independently first, or use :ToolchainLock!"
    )
    entries[package_name] = require("toolchain.tool_lock").capture(info.current, info.receipt)
    local release = util.lock(settings().install_dir .. "/locks/" .. package_name .. ".lock")
    local ok, err = pcall(function()
      assert(active(package_name) == info.current, "Tool changed during lock export; retry")
      publish(package_name, info.current, info.receipt)
    end)
    release()
    assert(ok, err)
  end
  require("toolchain.tool_lock").write(path or M.lockfile(), entries)
  return path or M.lockfile()
end

function M.remove(package_name)
  local root = M.path(package_name)
  assert(root, "Tool is not installed: " .. tostring(package_name))
  assert(not inflight[package_name], "Tool is currently installing: " .. package_name)
  local unlock = util.lock(settings().install_dir .. "/locks/" .. name(package_name) .. ".lock")
  local ok, err = uv.fs_unlink(settings().install_dir .. "/current/" .. package_name .. ".json")
  unlock()
  assert(ok, err)
  M.activate()
  return root -- Retained for already running processes; no automatic garbage collection.
end

local function quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function wrappers(root, entry)
  vim.fn.mkdir(root .. "/bin", "p")
  local function expand(value)
    return value
      :gsub("{root}", function()
        return root
      end)
      :gsub("{instance}", function()
        return vim.fs.basename(root)
      end)
      :gsub("{state}", function()
        return vim.fn.stdpath("state") .. "/toolchain-tools/tools"
      end)
      :gsub("{cache}", function()
        return vim.fn.stdpath("cache") .. "/toolchain-tools/tools"
      end)
  end
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
      args[#args + 1] = quote(expand(argument))
    end
    local environment = {}
    for key, value in pairs(descriptor.env or {}) do
      assert(key:match("^[A-Z_][A-Z0-9_]*$"), "Invalid wrapper environment key")
      environment[#environment + 1] = key
        .. "="
        .. quote(value:gsub("{root}", function()
          return root
        end))
    end
    table.sort(environment)
    if #environment > 0 then
      table.insert(args, 1, "env " .. table.concat(environment, " "))
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
  local package_info =
    { name = spec.name, path = root, version = entry.version, resources = vim.deepcopy(entry.resources or {}) }
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
    local entry = M.definition(spec.name, spec.unlocked)
    release = util.lock(settings().install_dir .. "/locks/" .. spec.name .. ".lock")
    local desired, previous = fingerprint(entry), active(spec.name)
    local previous_receipt = previous and util.json(previous .. "/receipt.json")
    if
      consistent(previous_receipt, spec.name)
      and (not previous_receipt.root or (type(previous_receipt.root) == "string" and same_location(
        previous_receipt.root,
        previous
      )))
      and require("toolchain.tool_lock").matches(previous, previous_receipt, entry)
      and intact(previous, fingerprint(previous_receipt.recipe))
    then
      publish(spec.name, previous, previous_receipt)
      M.activate()
      return "skipped"
    end
    local token = desired:sub(1, 16) .. string.format("-%d-%.0f", uv.os_getpid(), uv.hrtime())
    -- Build at the permanent version path: Python venv shebangs cannot be relocated.
    root = settings().install_dir .. "/versions/" .. spec.name .. "/" .. token
    vim.fn.mkdir(root, "p")
    local reusable = previous_receipt and previous_receipt.fingerprint == desired and previous or nil
    local metadata = require("toolchain.tool_installers").install(entry, root, ctx.log, reusable)
    hook(spec, root, entry, ctx.log)
    require("toolchain.tool_lock").verify(root, entry)
    wrappers(root, entry)
    util.write_json(root .. "/receipt.json", {
      schema = 1,
      root = root,
      name = spec.name,
      version = entry.version,
      recipe = entry,
      fingerprint = desired,
      bin = entry.bin,
      resources = entry.resources or {},
      metadata = metadata or {},
      artifacts = artifacts(root),
    })
    publish(spec.name, root, assert(util.json(root .. "/receipt.json")))
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

function M.packages()
  return require("toolchain.tool_versions").names(settings().install_dir)
end

function M.versions(package_name)
  if package_name then
    name(package_name)
  end
  return require("toolchain.tool_versions").list(settings().install_dir, package_name, fingerprint, consistent)
end

function M.prune_plan(package_name)
  return M.versions(package_name) -- Deliberately read-only; no version files are deleted.
end

function M.rollback(package_name, id)
  name(package_name)
  assert(type(id) == "string" and id:match("^[a-f0-9]+%-%d+%-%d+$"), "Invalid managed version ID")
  assert(not inflight[package_name], "Tool is currently installing: " .. package_name)
  local root = settings().install_dir .. "/versions/" .. package_name .. "/" .. id
  local stat = uv.fs_lstat(root)
  assert(stat and stat.type == "directory", "Managed version directory does not exist")
  local release = util.lock(settings().install_dir .. "/locks/" .. package_name .. ".lock")
  local ok, err = pcall(function()
    local value = util.json(root .. "/receipt.json")
    assert(consistent(value, package_name), "Invalid or inconsistent version receipt")
    assert(
      not value.root or (type(value.root) == "string" and same_location(value.root, root)),
      "Tool versions cannot be relocated"
    )
    assert(intact(root, fingerprint(value.recipe)), "Version is damaged or incompatible with this platform")
    for _, path in pairs(value.resources or {}) do
      assert(uv.fs_stat(root .. "/" .. util.relative(path)), "Version resource is unavailable")
    end
    local prefix = quote((value.root or root) .. "/"):sub(1, -2)
    for command, descriptor in pairs(value.bin) do
      name(command)
      assert(uv.fs_stat(root .. "/" .. util.relative(descriptor.path)), "Version entrypoint is unavailable")
      assert(
        util.read(root .. "/bin/" .. command):find(prefix, 1, true),
        "Version wrapper refers to another installation"
      )
    end
    publish(package_name, root, value)
  end)
  release()
  assert(ok, err)
  M.activate()
  return root
end

return M
