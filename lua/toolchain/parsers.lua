local M = {}
local util = require("toolchain.parser_util")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local options, registry
local inflight = {}
local activated = {}

function M.resolve(opts)
  assert(opts == nil or type(opts) == "table", "parsers must be a table")
  opts = vim.deepcopy(opts or {})
  for key in pairs(opts) do
    assert(
      vim.list_contains({ "install_dir", "cache_dir", "sources", "query_source", "filetypes" }, key),
      "Unknown parsers option: " .. key
    )
  end
  local configured = vim.tbl_extend("force", {
    install_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "toolchain-tools", "parsers"),
    cache_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "toolchain-tools", "parsers"),
    sources = {},
  }, opts)
  for _, key in ipairs({ "install_dir", "cache_dir" }) do
    assert(type(configured[key]) == "string" and configured[key] ~= "", "Invalid parsers." .. key)
    configured[key] = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(configured[key]), ":p")):gsub("/+$", "")
    assert(configured[key] ~= "", "Parser directories cannot be the filesystem root")
  end
  assert(type(configured.sources) == "table", "parsers.sources must be a language table")
  require("toolchain.runtime").validate({ filetypes = configured.filetypes })
  return configured
end

function M.reset()
  options, registry = nil, nil
end

function M.setup(opts)
  local configured = M.resolve(opts)
  require("toolchain.runtime").setup({ filetypes = configured.filetypes })
  options = configured
  registry = nil
end

local function settings()
  if not options then
    M.setup()
  end
  return options
end

local function definitions()
  if not registry then
    registry = assert(util.json(plugin_root .. "/data/parsers.json"), "Cannot read bundled parser registry")
    registry.query_source = settings().query_source or registry.query_source
    for name, definition in pairs(settings().sources) do
      util.name(name)
      assert(type(definition) == "table", "Invalid parser definition: " .. name)
      registry.sources[name] = vim.tbl_extend("force", registry.sources[name] or {}, vim.deepcopy(definition))
    end
  end
  return registry
end

local function definition(name, visiting)
  util.name(name)
  local entry = assert(definitions().sources[name], "Unknown independent parser: " .. name)
  for key in pairs(entry) do
    assert(
      vim.list_contains({ "parser", "requires", "query_source", "query_path" }, key),
      "Unknown parser definition field: " .. tostring(key)
    )
  end
  assert(
    entry.requires == nil or (type(entry.requires) == "table" and vim.islist(entry.requires)),
    "requires must be a language list"
  )
  visiting = visiting or {}
  assert(not visiting[name], "Parser dependency cycle: " .. name)
  visiting[name] = true
  if entry.parser then
    util.source(entry.parser)
  end
  util.source(entry.query_source or definitions().query_source)
  util.relative(entry.query_path or ("runtime/queries/" .. name))
  for _, dep in ipairs(entry.requires or {}) do
    definition(dep, visiting)
  end
  visiting[name] = nil
  return entry
end

local function active(name)
  local current = util.json(vim.fs.joinpath(settings().install_dir, "current", name .. ".json"))
  if
    type(current) ~= "table"
    or type(current.version) ~= "string"
    or not current.version:match("^[a-f0-9]+%-%d+%-%d+$")
  then
    return
  end
  return vim.fs.joinpath(settings().install_dir, "versions", name, current.version), current
end

local function receipt_stamp(stat)
  return stat and { size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec } or nil
end

local function activation_pointer(name, version, path, receipt)
  assert(receipt and receipt.schema == 1 and receipt.language == name, "Invalid parser receipt: " .. name)
  return {
    schema = 1,
    version = version,
    language = name,
    parser = not not receipt.parser,
    receipt = assert(receipt_stamp(vim.uv.fs_stat(path .. "/receipt.json")), "Missing parser receipt: " .. name),
  }
end

local function activation_receipt(name, path, pointer)
  if not path then
    return
  end
  if
    pointer.schema == 1
    and pointer.language == name
    and type(pointer.parser) == "boolean"
    and type(pointer.receipt) == "table"
  then
    local stamp = receipt_stamp(vim.uv.fs_stat(path .. "/receipt.json"))
    local cached = pointer.receipt
    if stamp and stamp.size == cached.size and stamp.sec == cached.sec and stamp.nsec == cached.nsec then
      return pointer
    end
  end
  -- Old pointers and changed receipts retain the original JSON validation path.
  return util.json(path .. "/receipt.json")
end

-- Explicit metadata migration only. Setup remains read-only apart from tool
-- session leases; selected versions and version contents are never changed.
function M.refresh_activation()
  local directory = settings().install_dir .. "/current"
  local result = { updated = 0, unchanged = 0 }
  if vim.fn.isdirectory(directory) == 0 then
    return result
  end
  for file, kind in vim.fs.dir(directory) do
    local name = kind == "file" and file:match("^([a-z][a-z0-9_]*)%.json$")
    if name then
      local release = util.lock(settings().install_dir .. "/locks/" .. name .. ".lock")
      local temporary = directory .. "/" .. file .. "." .. vim.uv.os_getpid() .. ".tmp"
      local ok, changed = pcall(function()
        local path, previous = active(name)
        assert(path, "Invalid parser pointer: " .. name)
        local before = receipt_stamp(vim.uv.fs_stat(path .. "/receipt.json"))
        local receipt = util.json(path .. "/receipt.json")
        local pointer = activation_pointer(name, previous.version, path, receipt)
        assert(vim.deep_equal(before, pointer.receipt), "Parser receipt changed; retry: " .. name)
        if vim.deep_equal(previous, pointer) then
          return false
        end
        assert(vim.deep_equal(previous, util.json(directory .. "/" .. file)), "Parser pointer changed; retry: " .. name)
        util.write_json(temporary, pointer)
        assert(vim.uv.fs_rename(temporary, directory .. "/" .. file))
        return true
      end)
      vim.uv.fs_unlink(temporary)
      release()
      assert(ok, changed)
      local field = changed and "updated" or "unchanged"
      result[field] = result[field] + 1
    end
  end
  return result
end

local function fingerprint(name)
  local entry = definition(name)
  local pieces = {
    "toolchain-parser-v1",
    name,
    tostring(vim.treesitter.language_version),
    vim.uv.os_uname().sysname,
    vim.uv.os_uname().machine,
  }
  if entry.parser then
    for _, key in ipairs({ "url", "revision", "location", "generate", "generate_from_json", "queries" }) do
      pieces[#pieces + 1] = tostring(entry.parser[key])
    end
  end
  local queries = entry.query_source or definitions().query_source
  vim.list_extend(pieces, { queries.url, queries.revision, entry.query_path or ("runtime/queries/" .. name) })
  for _, dep in ipairs(entry.requires or {}) do
    pieces[#pieces + 1] = dep .. ":" .. fingerprint(dep)
  end
  return util.hash(table.concat(pieces, "\n"))
end

local function intact(path, desired)
  local receipt = path and util.json(path .. "/receipt.json")
  if not receipt or receipt.schema ~= 1 or receipt.fingerprint ~= desired or type(receipt.artifacts) ~= "table" then
    return false
  end
  local actual = util.files(path)
  actual["receipt.json"] = nil
  return vim.deep_equal(actual, receipt.artifacts)
end

-- Pin runtimepath to immutable versions, so installing cannot change queries
-- beneath parsers already loaded by this or another Neovim session.
function M.activate()
  local directory = vim.fs.joinpath(settings().install_dir, "current")
  if vim.fn.isdirectory(directory) == 0 then
    return
  end
  local paths = {}
  for name, kind in vim.fs.dir(directory) do
    local lang = name:match("^([a-z][a-z0-9_]*)%.json$")
    if kind == "file" and lang and not activated[lang] then
      local path, pointer = active(lang)
      local receipt = activation_receipt(lang, path, pointer)
      if receipt and receipt.parser and receipt.language == lang and vim.fn.isdirectory(path) == 1 then
        paths[#paths + 1] = path
        activated[lang] = path
      end
    end
  end
  if #paths == 0 then
    return
  end
  table.sort(paths)
  local present, additions = {}, {}
  -- Enumerating expanded runtime paths stats/globs every installed parser root.
  -- Literal option entries need only splitting; retain native expansion for patterns.
  local runtime = vim.o.runtimepath
  local expanded = runtime:find("[$~*?%[]") ~= nil
  local existing = expanded and vim.api.nvim_list_runtime_paths() or vim.fn.split(runtime, [[\\\@<!,]])
  for _, path in ipairs(existing) do
    present[expanded and path or path:gsub("\\,", ",")] = true
  end
  for _, path in ipairs(paths) do
    if not present[path] then
      additions[#additions + 1] = path:gsub(",", "\\,")
      present[path] = true
    end
  end
  -- Preserve sorted precedence and existing entries with one option update.
  -- Repeated prepends rebuild the entire runtime path for each installed parser.
  if #additions > 0 then
    local current = vim.o.runtimepath
    vim.o.runtimepath = table.concat(additions, ",") .. (current ~= "" and "," .. current or "")
  end
end

-- Freeze inherited query text inside the consumer's version. Shared-query
-- updates must not change the queries used by an older parser version.
local function flatten_queries(stage, name, dependencies)
  local directory = stage .. "/queries/" .. name
  for filename, kind in vim.fs.dir(directory) do
    if kind == "file" and filename:match("%.scm$") then
      local chunks, body, seen = {}, {}, {}
      for _, line in ipairs(vim.split(util.read(directory .. "/" .. filename), "\n", { plain = true })) do
        local inherited = line:match("^%s*;+%s*inherits:%s*(.*)$")
        if inherited then
          for item in inherited:gmatch("[^,%s]+") do
            local optional = item:match("^%((.-)%)$")
            local language = optional or item
            util.name(language)
            local source = dependencies[language]
            assert(source or optional, "Undeclared query dependency: " .. language)
            if source and not seen[language] then
              seen[language] = true
              local query = source .. "/queries/" .. language .. "/" .. filename
              if vim.fn.filereadable(query) == 1 then
                chunks[#chunks + 1] = util.read(query)
              end
            end
          end
        else
          body[#body + 1] = line
        end
      end
      chunks[#chunks + 1] = table.concat(body, "\n")
      assert(
        vim.fn.writefile(vim.split(table.concat(chunks, "\n"), "\n", { plain = true }), directory .. "/" .. filename)
          == 0
      )
    end
  end
end

local ensure
ensure = function(name, ctx, done)
  if inflight[name] then
    inflight[name][#inflight[name] + 1] = { ctx = ctx, done = done }
    return
  end
  inflight[name] = { { ctx = ctx, done = done } }
  local token = string.format("%d-%.0f", vim.uv.os_getpid(), vim.uv.hrtime())
  local work = vim.fs.joinpath(settings().cache_dir, "work", token)
  local stage = vim.fs.joinpath(settings().install_dir, "versions", name, ".build-" .. token)
  local release
  local function log(message)
    for _, waiter in ipairs(inflight[name]) do
      waiter.ctx.log("[" .. name .. "] " .. message)
    end
  end
  local function source(spec)
    local path, err = util.await(function(callback)
      require("toolchain.parser_sources").get(spec, settings().cache_dir, log, callback)
    end)
    assert(path, err)
    return path
  end
  util.run(function()
    local entry = definition(name)
    for _, dep in ipairs(entry.requires or {}) do
      local ok, err = util.await(function(callback)
        ensure(dep, ctx, callback)
      end)
      assert(ok, "Dependency " .. dep .. " failed: " .. tostring(err))
    end
    release = util.lock(vim.fs.joinpath(settings().install_dir, "locks", name .. ".lock"))
    local desired = fingerprint(name)
    if intact(active(name), desired) then
      return "skipped"
    end
    vim.fn.mkdir(stage, "p")
    vim.fn.mkdir(work, "p")
    if entry.parser then
      local cached = source(entry.parser)
      local checkout = work .. "/grammar"
      util.command({ "git", "clone", "--quiet", "--shared", cached, checkout }, nil, log)
      local grammar = entry.parser.location and vim.fs.joinpath(checkout, entry.parser.location) or checkout
      if entry.parser.generate then
        local command = { "tree-sitter", "generate", "--abi", tostring(vim.treesitter.language_version) }
        if entry.parser.generate_from_json ~= false then
          command[#command + 1] = "src/grammar.json"
        end
        util.command(command, { cwd = grammar }, log)
      end
      vim.fn.mkdir(stage .. "/parser", "p")
      util.command({ "tree-sitter", "build", "-o", stage .. "/parser/" .. name .. ".so" }, { cwd = grammar }, log)
      if entry.parser.queries then
        local query_path = vim.fs.joinpath(checkout, entry.parser.queries)
        assert(vim.fn.isdirectory(query_path) == 1, "Missing grammar queries: " .. query_path)
        util.copy_tree(query_path, stage .. "/queries/" .. name)
      end
    end
    if not (entry.parser and entry.parser.queries) then
      local query_root = source(entry.query_source or definitions().query_source)
      local query_path = vim.fs.joinpath(query_root, entry.query_path or ("runtime/queries/" .. name))
      assert(vim.fn.isdirectory(query_path) == 1, "Missing pinned queries: " .. query_path)
      util.copy_tree(query_path, stage .. "/queries/" .. name)
    end
    do
      local dependency_paths, dependency_roots, visited = {}, {}, {}
      local function collect(language)
        for _, dep in ipairs(definition(language).requires or {}) do
          if not visited[dep] then
            visited[dep] = true
            dependency_paths[#dependency_paths + 1] = assert(active(dep))
            dependency_roots[dep] = assert(active(dep))
            collect(dep)
          end
        end
      end
      collect(name)
      flatten_queries(stage, name, dependency_roots)
      if entry.parser then
        util.command({
          vim.v.progpath,
          "--headless",
          "-n",
          "-u",
          "NONE",
          "-i",
          "NONE",
          "--noplugin",
          "-l",
          plugin_root .. "/scripts/validate-parser.lua",
          stage,
          name,
          vim.json.encode(dependency_paths),
        }, nil, log)
      end
    end
    local receipt = {
      schema = 1,
      language = name,
      fingerprint = desired,
      parser = entry.parser,
      query_source = entry.query_source or definitions().query_source,
      abi = vim.treesitter.language_version,
      artifacts = util.files(stage),
    }
    util.write_json(stage .. "/receipt.json", receipt)
    local version = desired:sub(1, 16) .. "-" .. token
    local destination = vim.fs.joinpath(settings().install_dir, "versions", name, version)
    assert(vim.uv.fs_rename(stage, destination))
    local current_dir = vim.fs.joinpath(settings().install_dir, "current")
    vim.fn.mkdir(current_dir, "p")
    local pointer = vim.fs.joinpath(current_dir, name .. ".json")
    util.write_json(pointer .. "." .. token, activation_pointer(name, version, destination, receipt))
    assert(vim.uv.fs_rename(pointer .. "." .. token, pointer))
    return "installed"
  end, function(ok, value)
    vim.fn.delete(work, "rf")
    vim.fn.delete(stage, "rf")
    if release then
      release()
    end
    local waiters = inflight[name]
    inflight[name] = nil
    for _, waiter in ipairs(waiters) do
      waiter.done(ok, value)
    end
  end)
end

function M.install(spec, ctx)
  definition(spec.name)
  ensure(spec.name, ctx, function(ok, result)
    if ok then
      ctx.done(
        result,
        result == "skipped" and "Pinned parser/query artifacts are intact"
          or "Installed and validated parser/queries; restart Neovim to activate"
      )
    else
      ctx.done("failed", tostring(result))
    end
  end)
end

function M.info(name)
  definition(name)
  local path = active(name)
  return {
    language = name,
    current = path,
    session = activated[name],
    intact = intact(path, fingerprint(name)),
    receipt = path and util.json(path .. "/receipt.json") or nil,
  }
end

return M
