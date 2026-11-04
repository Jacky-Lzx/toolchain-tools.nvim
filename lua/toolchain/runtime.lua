-- Query/alias compatibility for installed parser assets; attribution is in third_party/README.md.
local M = {}
local util = require("toolchain.parser_util")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local applied, owned_predicates = {}, {}

local function kind_matches(match, predicate, any)
  local nodes = match[predicate[2]]
  if not nodes or #nodes == 0 then
    return true
  end
  local kinds = {}
  for i = 3, #predicate do
    kinds[predicate[i]] = true
  end
  for _, node in ipairs(nodes) do
    local matches = kinds[node:type()] == true
    if matches and any then
      return true
    end
    if not matches and not any then
      return false
    end
  end
  return not any
end

function M.setup(opts)
  opts = opts or {}
  assert(
    opts.filetypes == nil or opts.filetypes == false or type(opts.filetypes) == "table",
    "filetypes must be a map or false"
  )
  local overrides = opts.filetypes or {}
  for filetype, language in pairs(overrides) do
    assert(type(filetype) == "string" and filetype ~= "", "Invalid parser filetype")
    util.name(language)
  end
  if opts.filetypes ~= false then
    local aliases = assert(util.json(root .. "/data/filetypes.json"), "Cannot read parser filetype aliases").filetypes
    for filetype, language in pairs(aliases) do
      local current = vim.treesitter.language.get_lang(filetype)
      local default = filetype:match("^[^.]+")
      if current == nil or current == default or current == language or current == applied[filetype] then
        vim.treesitter.language.register(language, filetype)
        applied[filetype] = language
      end
    end
    for filetype, language in pairs(overrides) do
      vim.treesitter.language.register(language, filetype)
      applied[filetype] = language
    end
  end

  local existing = vim.treesitter.query.list_predicates()
  for name, any in pairs({ ["kind-eq?"] = false, ["any-kind-eq?"] = true }) do
    if not vim.list_contains(existing, name) then
      vim.treesitter.query.add_predicate(name, function(match, _, _, predicate)
        return kind_matches(match, predicate, any)
      end)
      owned_predicates[name] = true
    end
  end
end

function M.status()
  return { filetypes = vim.deepcopy(applied), predicates = vim.deepcopy(owned_predicates) }
end

return M
