local t = dofile("tests/helpers.lua")
local toolchain = require("toolchain")

t.test("health inspects declarations without loading or installing backends", function()
  toolchain.setup({
    notify = false,
    log_file = false,
    requirements = {
      { provider = "system", name = "missing-fixture-123" },
      { provider = "mason", name = "fixture" },
      { provider = "treesitter", name = "lua" },
    },
  })
  local messages, original = {}, {}
  for _, name in ipairs({ "start", "ok", "warn", "error", "info" }) do
    original[name] = vim.health[name]
    vim.health[name] = function(message)
      messages[#messages + 1] = name .. ": " .. message
    end
  end
  require("toolchain.health").check()
  for name, fn in pairs(original) do
    vim.health[name] = fn
  end
  assert(table.concat(messages, "\n"):find("missing-fixture-123", 1, true))
  assert(not package.loaded.mason and not package.loaded["nvim-treesitter"])
  t.eq(#toolchain.status(), 0)
end)

t.test("Vim help tags compile and command references resolve", function()
  local root = vim.fn.stdpath("cache") .. "/help-fixture"
  vim.fn.mkdir(root .. "/doc", "p")
  vim.fn.writefile(vim.fn.readfile("doc/toolchain.txt"), root .. "/doc/toolchain.txt")
  vim.cmd("helptags " .. vim.fn.fnameescape(root .. "/doc"))
  vim.opt.rtp:append(root)
  vim.cmd("help toolchain-api")
  assert(vim.api.nvim_buf_get_name(0):match("toolchain.txt$"))
  vim.cmd("close")
end)

t.done()
