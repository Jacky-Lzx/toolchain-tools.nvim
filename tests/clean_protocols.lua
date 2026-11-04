vim.opt.rtp:prepend(vim.fn.getcwd())
local tc, tools = require("toolchain"), require("toolchain.tools")
local temp = assert(vim.env.TOOLCHAIN_PROTOCOL_TMP)
local lock = temp .. "/lock.json"
local requirements = { { provider = "tool", name = "lua-language-server" }, { provider = "tool", name = "debugpy" } }
local function install(store, frozen)
  vim.env.PIP_CACHE_DIR, vim.env.UV_CACHE_DIR = temp .. "/pip-" .. store, temp .. "/uv-" .. store
  tc.setup({
    notify = false,
    log_file = temp .. "/events-" .. store .. ".jsonl",
    concurrency = 2,
    tools = { install_dir = temp .. "/" .. store, lockfile = frozen and lock or false },
    requirements = requirements,
  })
  tc.install()
  assert(tc.wait(900000), "Clean real-tool installation timed out")
  for _, task in ipairs(tc.status()) do
    assert(task.state == "installed", vim.inspect(task))
  end
end
install("initial", false)
tc.lock(lock)
install("frozen", true)
local lua, python = tools.executable("lua-language-server"), tools.path("debugpy", "python")
assert(lua and python and tools.info("lua-language-server").intact and tools.info("debugpy").intact)
assert(not package.loaded.mason and not package.loaded["nvim-treesitter"])
require("toolchain.parser_util").write_json(temp .. "/paths.json", { lua = lua, python = python })
io.stdout:write("Fresh LuaLS/debugpy installs and frozen replay passed\n")
