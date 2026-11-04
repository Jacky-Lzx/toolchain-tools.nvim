local M = {}

local providers = { mason = true, treesitter = true, system = true }
local fields = {
  provider = true,
  name = true,
  executable = true,
  resolve = true,
  post_install = true,
  post_install_async = true,
  optional = true,
}

function M.normalize(requirements)
  assert(type(requirements) == "table" and vim.islist(requirements), "requirements must be a list")
  local result, seen = {}, {}
  for i, entry in ipairs(requirements) do
    assert(type(entry) == "table", "requirement " .. i .. " must be a table")
    for key in pairs(entry) do
      assert(fields[key], "unknown requirement field: " .. tostring(key))
    end
    assert(providers[entry.provider], "unknown provider: " .. tostring(entry.provider))
    assert(entry.optional == nil or type(entry.optional) == "boolean", "optional must be a boolean")
    assert(entry.optional == nil or entry.provider == "system", "optional is only supported for system requirements")
    assert(type(entry.name) == "string" and entry.name:match("^[%w_][%w_.+-]*$"), "invalid requirement name")
    assert(
      entry.executable == nil or (type(entry.executable) == "string" and entry.executable ~= ""),
      "invalid executable"
    )
    assert(entry.resolve == nil or type(entry.resolve) == "function", "resolve must be a function")
    assert(entry.post_install == nil or type(entry.post_install) == "function", "post_install must be a function")
    assert(
      entry.post_install_async == nil or type(entry.post_install_async) == "function",
      "post_install_async must be a function"
    )
    assert(not (entry.post_install and entry.post_install_async), "choose post_install or post_install_async, not both")
    assert(
      not (entry.post_install or entry.post_install_async) or entry.provider == "mason",
      "post_install hooks are only supported for Mason packages"
    )
    assert(
      entry.provider ~= "treesitter" or not (entry.executable or entry.resolve),
      "Tree-sitter requirements cannot use executable resolvers"
    )
    local id = entry.provider .. ":" .. entry.name
    assert(not seen[id] or vim.deep_equal(seen[id], entry), "conflicting declarations for " .. id)
    if not seen[id] then
      seen[id] = entry
      result[#result + 1] = vim.deepcopy(entry)
    end
  end
  return result
end

function M.options(opts)
  opts = opts or {}
  assert(type(opts) == "table", "options must be a table")
  local allowed = { requirements = true, concurrency = true, max_log_lines = true, log_file = true, notify = true }
  for key in pairs(opts) do
    assert(allowed[key], "unknown option: " .. tostring(key))
  end
  local result = vim.tbl_extend("force", {
    requirements = {},
    concurrency = 2,
    max_log_lines = 200,
    log_file = vim.fs.joinpath(vim.fn.stdpath("state"), "toolchain-tools.log"),
    notify = true,
  }, opts)
  for _, key in ipairs({ "concurrency", "max_log_lines" }) do
    assert(
      type(result[key]) == "number" and result[key] >= 1 and result[key] % 1 == 0,
      key .. " must be a positive integer"
    )
  end
  assert(type(result.notify) == "boolean", "notify must be a boolean")
  assert(result.log_file == false or (type(result.log_file) == "string" and result.log_file ~= ""), "invalid log_file")
  if type(result.requirements) ~= "function" then
    result.requirements = M.normalize(result.requirements)
  end
  return result
end

return M
