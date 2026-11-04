local M = {}
local util = require("toolchain.parser_util")

local function encode(value, depth)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  local list = vim.islist(value)
  local keys = vim.tbl_keys(value)
  table.sort(keys, function(a, b)
    return list and a < b or not list and tostring(a) < tostring(b)
  end)
  if #keys == 0 then
    return list and "[]" or "{}"
  end
  local parts, indent = {}, string.rep("  ", depth + 1)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = indent .. (list and "" or vim.json.encode(key) .. ": ") .. encode(value[key], depth + 1)
  end
  return (list and "[" or "{")
    .. "\n"
    .. table.concat(parts, ",\n")
    .. "\n"
    .. string.rep("  ", depth)
    .. (list and "]" or "}")
end

function M.target()
  local target, system, libc = require("toolchain.tool_installers").target()
  return target .. (system == "linux" and "_" .. libc or "")
end

function M.read(path, required)
  if vim.fn.filereadable(path) == 0 then
    assert(not required, "Toolchain lock is missing: " .. path .. "; run :ToolchainLock! explicitly")
    return { schema = 1, targets = vim.empty_dict() }
  end
  local value = util.json(path)
  assert(
    type(value) == "table" and value.schema == 1 and type(value.targets) == "table",
    "Invalid toolchain lock: " .. path
  )
  for target, record in pairs(value.targets) do
    assert(
      type(target) == "string" and type(record) == "table" and type(record.packages) == "table",
      "Invalid platform record in toolchain lock"
    )
  end
  return value
end

function M.entry(path, name)
  local lock = M.read(path, true)
  local target = lock.targets[M.target()]
  local entry = target and target.packages and target.packages[name]
  assert(
    type(entry) == "table" and type(entry.recipe) == "table",
    "No locked " .. name .. " for " .. M.target() .. "; run :ToolchainLock! explicitly"
  )
  local result = vim.deepcopy(entry.recipe)
  result._lock = vim.deepcopy(entry)
  result._lock.recipe = nil
  for path, dependency in pairs(result._lock.files or {}) do
    util.relative(path)
    assert(
      type(dependency) == "table" and (dependency.kind == "npm" or dependency.kind == "pip"),
      "Invalid locked dependency file"
    )
    assert(type(dependency.value) == "table", "Invalid locked dependencies")
  end
  for url, hash in pairs(result._lock.downloads or {}) do
    assert(
      type(url) == "string" and type(hash) == "string" and hash:match("^[a-f0-9]+$") and #hash == 64,
      "Invalid locked download digest"
    )
  end
  local kind = result.kind
  local needed = kind == "npm" and "package-lock.json"
    or kind == "pypi" and "requirements.lock"
    or kind == "npm-build" and "payload/package-lock.json"
  assert(not needed or (result._lock.files or {})[needed], "Missing locked dependencies: " .. tostring(needed))
  if kind == "pypi" then
    assert(
      type(result._lock.python) == "string" and result._lock.python:match("^%d+%.%d+$"),
      "Missing locked Python minor version"
    )
  elseif kind == "cargo" then
    assert(
      type(result._lock.revision) == "string"
        and result._lock.revision:match("^[a-f0-9]+$")
        and #result._lock.revision == 40,
      "Missing locked Cargo commit"
    )
  elseif kind == "download" then
    for _, file in ipairs(require("toolchain.tool_installers").asset(result).files) do
      assert(
        result._lock.downloads and result._lock.downloads[file.url],
        "Missing locked download digest: " .. file.url
      )
    end
  end
  return result
end

function M.pip_lines(text)
  local lines = {}
  for line in text:gmatch("[^\r\n]+") do
    assert(
      not line:match("^%-") and not line:find("file://", 1, true),
      "Python locks cannot contain editable or local file dependencies"
    )
    lines[#lines + 1] = line
  end
  table.sort(lines)
  return lines
end

local function dependencies(root, recipe, metadata)
  local paths, files = {}, vim.empty_dict()
  for path in pairs(metadata.locks or {}) do
    paths[path] = true
  end
  if recipe.kind == "npm" then
    paths["package-lock.json"] = true
  end
  if recipe.kind == "pypi" then
    paths["requirements.lock"] = true
  end
  if recipe.kind == "npm-build" then
    paths["payload/package-lock.json"] = true
  end
  for path in pairs(paths) do
    util.relative(path)
    local text = util.read(root .. "/" .. path)
    if path:match("package%-lock%.json$") then
      files[path] = { kind = "npm", value = vim.json.decode(text) }
    else
      files[path] = { kind = "pip", value = M.pip_lines(text) }
    end
  end
  return files
end

function M.capture(root, receipt)
  local recipe = vim.deepcopy(receipt.recipe)
  recipe._lock = nil
  local metadata = receipt.metadata or {}
  local result = { recipe = recipe, files = dependencies(root, recipe, metadata), downloads = vim.empty_dict() }
  for _, file in ipairs(metadata.downloads or {}) do
    result.downloads[file.url] = file.sha256
  end
  if recipe.kind == "download" then
    for _, file in ipairs(require("toolchain.tool_installers").asset(recipe).files) do
      assert(result.downloads[file.url], "Missing verified download receipt: " .. file.url)
    end
  end
  if recipe.kind == "pypi" then
    result.python =
      assert(util.read(root .. "/venv/pyvenv.cfg"):match("version%s*=%s*(%d+%.%d+)"), "Missing Python runtime version")
  end
  if recipe.kind == "cargo" then
    local revision = metadata.revision
    if not revision then
      local crates = util.json(root .. "/payload/.crates2.json")
      for source in pairs(crates and crates.installs or {}) do
        revision = revision or source:match("#([a-f0-9]+)%)$")
      end
    end
    assert(revision and #revision == 40, "Cargo receipt lacks a resolved commit SHA")
    result.revision = revision
  end
  if recipe.kind == "npm-build" then
    result.revision = recipe.revision
  end
  return result
end

function M.matches(root, receipt, entry)
  if not entry._lock then
    return vim.deep_equal(receipt.recipe, entry)
  end
  local ok, value = pcall(M.capture, root, receipt)
  if not ok then
    return false
  end
  local expected = vim.deepcopy(entry)
  expected._lock = nil
  return vim.deep_equal(value.recipe, expected)
    and vim.deep_equal(value.files, entry._lock.files or {})
    and vim.deep_equal(value.downloads, entry._lock.downloads or {})
    and value.python == entry._lock.python
    and value.revision == entry._lock.revision
end

function M.file(entry, path)
  local value = entry._lock and entry._lock.files and entry._lock.files[path]
  if not value then
    return
  end
  if value.kind == "npm" then
    return encode(value.value, 0) .. "\n"
  end
  return table.concat(value.value, "\n") .. "\n"
end

function M.verify(root, entry)
  if not entry._lock then
    return
  end
  local value = dependencies(root, entry, { locks = entry._lock.files })
  assert(
    vim.deep_equal(value, entry._lock.files),
    "Resolved dependencies differ from the toolchain lock; previous installation retained"
  )
end

function M.write(path, entries)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local unlock = util.lock(path .. ".write-lock")
  local temporary = path .. string.format(".%d-%.0f.tmp", vim.uv.os_getpid(), vim.uv.hrtime())
  local ok, err = pcall(function()
    local value = M.read(path, false)
    local target = M.target()
    value.targets[target] = value.targets[target] or { packages = vim.empty_dict() }
    for name, entry in pairs(entries) do
      value.targets[target].packages[name] = entry
    end
    assert(vim.fn.writefile(vim.split(encode(value, 0), "\n", { plain = true }), temporary) == 0)
    assert(vim.uv.fs_rename(temporary, path))
  end)
  if not ok then
    vim.fn.delete(temporary)
  end
  unlock()
  assert(ok, err)
end

return M
