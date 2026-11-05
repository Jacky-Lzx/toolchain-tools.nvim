local t = dofile("tests/helpers.lua")
local tc = require("toolchain")
local util = require("toolchain.parser_util")
local root = vim.fs.normalize(vim.fn.stdpath("cache") .. "/parser-fixture")
local repo = root .. "/repo"
local install_dir = root .. "/installed"
vim.fn.mkdir(repo .. "/queries", "p")
vim.fn.mkdir(repo .. "/shared", "p")
local function command(args, cwd)
  local result = vim.system(args, { cwd = cwd or repo, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function commit()
  command({ "git", "add", "." })
  command({
    "git",
    "-c",
    "user.name=Toolchain Test",
    "-c",
    "user.email=test@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--quiet",
    "-m",
    "fixture",
  })
  return command({ "git", "rev-parse", "HEAD" })
end
command({ "git", "init", "--quiet", repo })
vim.fn.writefile({
  "module.exports = grammar({ name: 'toolchain_fixture', rules: {",
  "source_file: $ => repeat($.word), word: $ => /[a-z]+/ }});",
}, repo .. "/grammar.js")
command({ "tree-sitter", "generate" })
vim.fn.writefile({ "; inherits: toolchain_shared", "(word) @string" }, repo .. "/queries/highlights.scm")
vim.fn.writefile({ "(word) @constant" }, repo .. "/shared/highlights.scm")
local revision = commit()
local function options(sha)
  return {
    notify = false,
    log_file = false,
    requirements = {
      { provider = "parser", name = "toolchain_fixture" },
      { provider = "parser", name = "toolchain_shared" },
    },
    parsers = {
      install_dir = install_dir,
      cache_dir = root .. "/cache",
      query_source = { url = repo, revision = sha },
      sources = {
        toolchain_fixture = {
          parser = { url = repo, revision = sha },
          query_path = "queries",
          requires = { "toolchain_shared" },
        },
        toolchain_shared = { query_path = "shared" },
      },
    },
  }
end
local function version(language)
  local current = assert(util.json(install_dir .. "/current/" .. language .. ".json"))
  return install_dir .. "/versions/" .. language .. "/" .. current.version
end
local function install()
  tc.install()
  assert(tc.wait(30000), vim.inspect(tc.status()))
end

t.test("independent backend builds pinned Git sources and coalesces shared query dependencies", function()
  tc.setup(options(revision))
  install()
  for _, task in ipairs(tc.status()) do
    assert(task.state == "installed", vim.inspect(task))
  end
  assert(not package.loaded["nvim-treesitter"])
  local pointer = assert(util.json(install_dir .. "/current/toolchain_fixture.json"))
  assert(pointer.schema == 1 and pointer.parser == true and pointer.receipt.size > 0)
  local receipt = assert(util.json(version("toolchain_fixture") .. "/receipt.json"))
  t.eq(receipt.parser.revision, revision)
  assert(receipt.artifacts["parser/toolchain_fixture.so"])
  assert(receipt.artifacts["queries/toolchain_fixture/highlights.scm"])
  local query_text = util.read(version("toolchain_fixture") .. "/queries/toolchain_fixture/highlights.scm")
  assert(not query_text:find("inherits:", 1, true))
  assert(query_text:find("@constant", 1, true), "Shared queries must be frozen inside the consumer version")
  tc.setup(options(revision))
  local parser = vim.treesitter.get_string_parser("hello world", "toolchain_fixture")
  assert(not parser:parse()[1]:root():has_error())
  assert(vim.treesitter.query.get("toolchain_fixture", "highlights"))
end)

t.test("intact installs skip and damaged artifacts repair without switching a live runtime", function()
  install()
  t.eq(tc.status()[1].state, "skipped")
  local previous = version("toolchain_fixture")
  vim.fn.writefile({ "(invalid_fixture_node) @string" }, previous .. "/queries/toolchain_fixture/highlights.scm")
  install()
  assert(tc.status()[1].state == "installed", vim.inspect(tc.status()))
  local repaired = version("toolchain_fixture")
  assert(repaired ~= previous)
  assert(
    vim.list_contains(vim.opt.rtp:get(), previous),
    vim.inspect({ previous = previous, runtime = vim.opt.rtp:get() })
  )
  assert(not vim.list_contains(vim.opt.rtp:get(), repaired))
  tc.setup(options(revision))
  assert(
    not vim.list_contains(vim.opt.rtp:get(), repaired),
    "Reconfiguration must not switch loaded parser/query versions"
  )
end)

t.test("a query validation failure preserves the last complete language version", function()
  local previous = version("toolchain_fixture")
  vim.fn.writefile({ "(invalid_fixture_node) @string" }, repo .. "/queries/highlights.scm")
  local bad_revision = commit()
  tc.setup(options(bad_revision))
  install()
  t.eq(tc.status()[1].state, "failed")
  t.eq(version("toolchain_fixture"), previous)
  assert(tc.status()[1].message:find("failed", 1, true))
end)

t.test("unknown, cyclic and unpinned sources fail instead of silently installing nothing", function()
  local opts = options(revision)
  opts.requirements = { { provider = "parser", name = "unknown_fixture" } }
  tc.setup(opts)
  install()
  assert(tc.status()[1].message:find("Unknown independent parser", 1, true))
  opts.requirements = { { provider = "parser", name = "toolchain_fixture" } }
  opts.parsers.sources.toolchain_shared.requires = { "toolchain_fixture" }
  tc.setup(opts)
  install()
  assert(tc.status()[1].message:find("dependency cycle", 1, true))
  opts.parsers.sources.toolchain_shared.requires = nil
  opts.parsers.sources.toolchain_fixture.parser.revision = "main"
  tc.setup(opts)
  install()
  assert(tc.status()[1].message:find("full commit SHA", 1, true))
end)

t.test("language locks reject another owner and recover a dead owner's lock", function()
  local path = root .. "/lock-test.lock"
  util.write_json(path, { pid = vim.uv.os_getpid() })
  assert(not pcall(util.lock, path))
  local process = vim.system({ "sh", "-c", "exit 0" })
  local pid = process.pid
  process:wait()
  util.write_json(path, { pid = pid })
  local release = util.lock(path)
  release()
  assert(not vim.uv.fs_stat(path))
end)

t.test("spawn failures finish the task, release its lock and preserve the current version", function()
  local previous = version("toolchain_fixture")
  local opts = options(revision)
  opts.parsers.sources.toolchain_fixture.parser.generate = true
  tc.setup(opts)
  local system = vim.system
  vim.system = function(cmd, ...)
    if cmd[1] == "tree-sitter" then
      error("fixture compiler is unavailable")
    end
    return system(cmd, ...)
  end
  install()
  vim.system = system
  t.eq(tc.status()[1].state, "failed")
  t.eq(version("toolchain_fixture"), previous)
  assert(not vim.uv.fs_stat(install_dir .. "/locks/toolchain_fixture.lock"))
  tc.retry()
  assert(tc.wait(30000))
  assert(tc.status()[1].state == "installed", vim.inspect(tc.status()))
end)

t.test("shared-query updates revalidate consumers and cannot change an older bundle", function()
  local previous = version("toolchain_fixture")
  local old_text = util.read(previous .. "/queries/toolchain_fixture/highlights.scm")
  vim.fn.writefile({ "; inherits: toolchain_shared", "(word) @string" }, repo .. "/queries/highlights.scm")
  vim.fn.writefile({ "(invalid_shared_node) @constant" }, repo .. "/shared/highlights.scm")
  local bad_dependency_revision = commit()
  local opts = options(revision)
  opts.parsers.sources.toolchain_shared.query_source = { url = repo, revision = bad_dependency_revision }
  tc.setup(opts)
  install()
  t.eq(tc.status()[1].state, "failed")
  t.eq(version("toolchain_fixture"), previous)
  t.eq(util.read(previous .. "/queries/toolchain_fixture/highlights.scm"), old_text)
end)

t.done()
