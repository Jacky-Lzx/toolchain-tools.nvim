local M = {}
local util = require("toolchain.parser_util")
local uv = vim.uv

function M.target()
  local os = uv.os_uname()
  local system = ({ Darwin = "darwin", Linux = "linux" })[os.sysname]
  local machine = ({ arm64 = "arm64", aarch64 = "arm64", x86_64 = "x64", amd64 = "x64" })[os.machine]
  assert(system and machine, "Unsupported tool platform: " .. os.sysname .. "/" .. os.machine)
  return system .. "_" .. machine, system, vim.fn.glob("/lib/ld-musl-*.so.1") ~= "" and "musl" or "gnu"
end

function M.asset(entry)
  local target, system, libc = M.target()
  return assert(
    entry.assets[target .. "_" .. libc] or entry.assets[target] or entry.assets[system],
    "No " .. target .. " tool artifact is provided for this version; use a system package"
  )
end

local function run(command, root, log, extra)
  return util.command(command, vim.tbl_extend("force", { cwd = root, timeout = 900000 }, extra or {}), log)
end

local function digest(path, root, log)
  local command = vim.fn.executable("sha256sum") == 1 and { "sha256sum", path } or { "shasum", "-a", "256", path }
  return assert(run(command, root, log):match("^([a-f0-9]+)"))
end

local function download(entry, root, log)
  local asset, metadata = M.asset(entry), { downloads = {} }
  vim.fn.mkdir(root .. "/.downloads", "p")
  vim.fn.mkdir(root .. "/payload", "p")
  for i, file in ipairs(asset.files) do
    util.relative(file.name)
    assert(
      file.url:match("^https://") or file.url:match("^file://"),
      "Tool downloads require HTTPS or a local file URL"
    )
    local path = root .. "/.downloads/" .. i .. "-" .. file.name
    run({
      "curl",
      "--fail",
      "--location",
      "--retry",
      "2",
      "--connect-timeout",
      "20",
      "--max-time",
      "600",
      "--output",
      path,
      "--",
      file.url,
    }, root, log)
    local hash = digest(path, root, log)
    local expected = entry._lock and entry._lock.downloads and entry._lock.downloads[file.url] or file.sha256
    assert(not expected or expected == hash, "Downloaded tool checksum does not match the recipe/lock")
    metadata.downloads[#metadata.downloads + 1] = { url = file.url, sha256 = hash }
    local target = root .. "/payload"
    if file.destination and file.destination ~= "" then
      target = target .. "/" .. util.relative(file.destination)
    end
    vim.fn.mkdir(target, "p")
    if file.archive == "zip" or file.archive == "tar" then
      local listing = run(
        file.archive == "zip" and { "unzip", "-Z1", path } or { "tar", "-tf", path },
        root,
        function() end
      )
      for line in listing:gmatch("[^\r\n]+") do
        util.relative(line)
      end
      run(
        file.archive == "zip" and { "unzip", "-q", path, "-d", target } or { "tar", "-xf", path, "-C", target },
        root,
        log
      )
    elseif file.archive == "gzip" then
      run({ "gzip", "-d", path }, root, log)
      assert(uv.fs_copyfile(path:sub(1, -4), target .. "/" .. file.name:sub(1, -4)))
    else
      assert(file.archive == "file", "Unsupported archive format: " .. tostring(file.archive))
      assert(uv.fs_copyfile(path, target .. "/" .. file.name))
    end
  end
  if asset.config then
    assert(uv.fs_symlink(util.relative(asset.config), root .. "/payload/config"))
  end
  vim.fn.delete(root .. "/.downloads", "rf")
  return metadata
end

local function previous_lock(previous, filename)
  local receipt = previous and util.json(previous .. "/receipt.json")
  local expected = receipt and receipt.metadata and receipt.metadata.locks and receipt.metadata.locks[filename]
  if expected then
    local ok, text = pcall(util.read, previous .. "/" .. filename)
    if ok and util.hash(text) == expected then
      return text
    end
  end
end

local function npm(entry, root, log, previous)
  local dependencies = { [entry.package] = entry.version }
  for _, extra in ipairs(entry.extras or {}) do
    local package, version = extra:match("^(.+)@([^@]+)$")
    assert(package and version and version ~= "latest", "Extra npm packages must have a pinned version")
    dependencies[package] = version
  end
  util.write_json(
    root .. "/package.json",
    { name = "toolchain-managed-tool", version = "1.0.0", private = true, dependencies = dependencies }
  )
  local old = require("toolchain.tool_lock").file(entry, "package-lock.json")
    or previous_lock(previous, "package-lock.json")
  if old then
    assert(vim.fn.writefile(vim.split(old, "\n", { plain = true }), root .. "/package-lock.json") == 0)
  end
  local env = entry.package == "@mermaid-js/mermaid-cli" and { PUPPETEER_CACHE_DIR = root .. "/browser" } or nil
  -- npm compares --prefix to the real cwd; alias paths can produce non-portable locks.
  run({
    "npm",
    old and "ci" or "install",
    "--prefix",
    assert(vim.uv.fs_realpath(root)),
    "--global=false",
    "--omit=dev",
    "--no-audit",
    "--no-fund",
    "--no-progress",
  }, root, log, { env = env })
  return { locks = { ["package-lock.json"] = util.hash(util.read(root .. "/package-lock.json")) } }
end

local function pypi(entry, root, log, previous)
  local python
  local required = entry._lock and entry._lock.python
  local candidates = { "python3.14", "python3.13", "python3.12", "python3.11", "python3.10", "python3" }
  if required then
    table.insert(candidates, 1, "python" .. required)
  end
  for _, executable in ipairs(candidates) do
    local found = vim.fn.exepath(executable)
    if found ~= "" then
      local version = required
        and run(
          { found, "-c", "import sys; print(str(sys.version_info.major) + '.' + str(sys.version_info.minor))" },
          root,
          log
        ):gsub("%s+$", "")
      if not required or version == required then
        python = found
        break
      end
    end
  end
  assert(
    python,
    required and ("Locked Python " .. required .. " with venv support is required")
      or "Python 3 with venv support is required"
  )
  run({ python, "-m", "venv", root .. "/venv" }, root, log)
  local uv_available = vim.fn.executable("uv") == 1
  local command = uv_available and { "uv", "pip", "install", "--python", root .. "/venv/bin/python", "--no-progress" }
    or { root .. "/venv/bin/python", "-m", "pip", "install", "--disable-pip-version-check", "--no-input" }
  local old = require("toolchain.tool_lock").file(entry, "requirements.lock")
    or previous_lock(previous, "requirements.lock")
  if old then
    assert(vim.fn.writefile(vim.split(old, "\n", { plain = true }), root .. "/requirements.lock") == 0)
    vim.list_extend(command, { "-r", root .. "/requirements.lock" })
  else
    command[#command + 1] = entry.package .. "==" .. entry.version
  end
  run(command, root, log)
  local freeze = run(
    uv_available and { "uv", "pip", "freeze", "--python", root .. "/venv/bin/python" }
      or { root .. "/venv/bin/python", "-m", "pip", "freeze", "--disable-pip-version-check" },
    root,
    log
  )
  assert(vim.fn.writefile(vim.split(freeze, "\n", { plain = true }), root .. "/requirements.lock") == 0)
  return { locks = { ["requirements.lock"] = util.hash(util.read(root .. "/requirements.lock")) }, python = python }
end

local function npm_build(entry, root, log)
  assert(entry.revision:match("^[a-f0-9]+$") and #entry.revision == 40, "Build source must use a full commit SHA")
  assert(entry.repository:match("^https://"), "Build repository must use HTTPS")
  vim.fn.mkdir(root .. "/payload", "p")
  local path = root .. "/payload"
  run({ "git", "init", "--quiet" }, path, log)
  run({ "git", "remote", "add", "origin", entry.repository }, path, log)
  run({ "git", "fetch", "--depth=1", "origin", entry.revision }, path, log)
  run({ "git", "checkout", "--quiet", "--detach", "FETCH_HEAD" }, path, log)
  local frozen = require("toolchain.tool_lock").file(entry, "payload/package-lock.json")
  if frozen then
    assert(vim.fn.writefile(vim.split(frozen, "\n", { plain = true }), path .. "/package-lock.json") == 0)
  end
  run({
    "npm",
    vim.fn.filereadable(path .. "/package-lock.json") == 1 and "ci" or "install",
    "--prefix",
    assert(vim.uv.fs_realpath(path)),
    "--global=false",
    "--no-audit",
    "--no-fund",
    "--no-progress",
  }, path, log)
  run({ "npm", "--prefix", assert(vim.uv.fs_realpath(path)), "--global=false", "run", "package" }, path, log)
  vim.fn.delete(path .. "/.git", "rf")
  return {
    revision = entry.revision,
    locks = { ["payload/package-lock.json"] = util.hash(util.read(path .. "/package-lock.json")) },
  }
end

function M.install(entry, root, log, previous)
  if entry.kind == "download" then
    return download(entry, root, log)
  end
  if entry.kind == "npm" then
    return npm(entry, root, log, previous)
  end
  if entry.kind == "pypi" then
    return pypi(entry, root, log, previous)
  end
  if entry.kind == "npm-build" then
    return npm_build(entry, root, log)
  end
  if entry.kind == "cargo" then
    assert(entry.repository:match("^https://"), "Cargo repository must use HTTPS")
    local revision = entry._lock and entry._lock.revision
    if not revision then
      local refs = run(
        { "git", "ls-remote", entry.repository, "refs/tags/" .. entry.version, "refs/tags/" .. entry.version .. "^{}" },
        root,
        log
      )
      for line in refs:gmatch("[^\r\n]+") do
        local sha, ref = line:match("^([a-f0-9]+)%s+(.+)$")
        if sha and (not revision or ref:sub(-3) == "^{}") then
          revision = sha
        end
      end
    end
    assert(revision and #revision == 40, "Cannot resolve the pinned Cargo source revision")
    run({
      "cargo",
      "install",
      "--git",
      entry.repository,
      "--rev",
      revision,
      "--locked",
      "--root",
      root .. "/payload",
      entry.package,
    }, root, log)
    return { source = entry.repository, tag = entry.version, revision = revision }
  end
  assert(entry.kind == "commands", "Unsupported tool installer: " .. entry.kind)
  for _, command in ipairs(entry.commands) do
    local args = vim.tbl_map(function(arg)
      return arg:gsub("{root}", function()
        return root
      end)
    end, command)
    run(args, root, log)
  end
end

return M
