vim.opt.rtp:prepend(vim.fn.getcwd())
local tc, tools = require("toolchain"), require("toolchain.tools")
local temp = assert(vim.env.TOOLCHAIN_CLEAN_TMP)
local lock = temp .. "/toolchain-lock.json"
local sources = {
  ["npm-fixture"] = {
    kind = "npm",
    version = "1.0.0",
    package = "offline-node-tool",
    bin = { ["offline-node-tool"] = { path = "node_modules/.bin/offline-node-tool" } },
  },
  ["python-fixture"] = {
    kind = "pypi",
    version = "1.0.0",
    package = "offline-python-tool",
    bin = { ["offline-python-tool"] = { path = "venv/bin/offline-python-tool" } },
  },
}
local function setup(store, frozen)
  vim.env.npm_config_cache = temp .. "/npm-cache-" .. store
  vim.env.PIP_CACHE_DIR, vim.env.UV_CACHE_DIR = temp .. "/pip-cache-" .. store, temp .. "/uv-cache-" .. store
  tc.setup({
    notify = false,
    log_file = temp .. "/events-" .. store .. ".jsonl",
    concurrency = 2,
    tools = { install_dir = temp .. "/" .. store, sources = sources, lockfile = frozen and lock or false },
    requirements = { { provider = "tool", name = "npm-fixture" }, { provider = "tool", name = "python-fixture" } },
  })
end
local function install(expected)
  tc.install()
  assert(tc.wait(120000), "Clean dependency installation timed out")
  for _, task in ipairs(tc.status()) do
    assert(task.state == "installed", vim.inspect(task))
  end
  for name, command in pairs({ ["npm-fixture"] = "offline-node-tool", ["python-fixture"] = "offline-python-tool" }) do
    local result = vim.system({ assert(tools.executable(name, command)) }, { text = true }):wait()
    assert(result.code == 0 and result.stdout == expected .. "\n", vim.inspect(result))
    assert(tools.info(name).intact, name)
  end
end
setup("first")
install("1.0.0")
tc.lock(lock)
local before = table.concat(vim.fn.readfile(lock), "\n")
vim.fn.writefile({ "updated" }, temp .. "/registry-updated")
for file in vim.fs.dir(temp .. "/updates") do
  assert(vim.uv.fs_copyfile(temp .. "/updates/" .. file, temp .. "/wheels/" .. file))
end
setup("cold-frozen", true)
install("1.0.0")
assert(table.concat(vim.fn.readfile(lock), "\n") == before, "Frozen installation must not rewrite the lock")
for name, command in pairs({ ["npm-fixture"] = "offline-node-tool", ["python-fixture"] = "offline-python-tool" }) do
  assert(vim.uv.fs_unlink(tools.executable(name, command)))
end
install("1.0.0")
setup("new-resolution")
install("2.0.0")
tc.lock(lock, true)
assert(tc.wait(120000) and tc.lock_status().state == "written", vim.inspect(tc.lock_status()))
setup("cold-updated", true)
install("2.0.0")
assert(vim.fn.isdirectory(temp .. "/unrelated-global") == 0, "Host npm global prefixes must remain untouched")
assert(not package.loaded.mason and not package.loaded["mason-registry"] and not package.loaded["nvim-treesitter"])
io.stdout:write(
  "Clean npm/Python installation: cold caches, pinned transitives, repair and explicit lock update passed\n"
)
