local t = dofile("tests/helpers.lua")
local before_require = #vim.api.nvim_get_autocmds({})
local runtime = require("toolchain.runtime")
assert(#vim.api.nvim_get_autocmds({}) == before_require, "Requiring runtime must be inert")

t.test("requiring runtime is inert and setup supplies parser aliases without upstream modules", function()
  assert(not package.loaded["nvim-treesitter"])
  vim.treesitter.query.list_predicates()
  vim.treesitter.language.get_lang("lua")
  local before = #vim.api.nvim_get_autocmds({})
  runtime.setup()
  for filetype, language in pairs({
    tex = "latex",
    bib = "bibtex",
    sh = "bash",
    javascriptreact = "javascript",
    typescriptreact = "tsx",
    verilog = "systemverilog",
  }) do
    t.eq(vim.treesitter.language.get_lang(filetype), language)
  end
  t.eq(#vim.api.nvim_get_autocmds({}), before)
  assert(not package.loaded["nvim-treesitter"])
end)

t.test("explicit user mappings survive defaults and can be overridden deliberately", function()
  vim.treesitter.language.register("custom_tex", "tex")
  runtime.setup()
  t.eq(vim.treesitter.language.get_lang("tex"), "custom_tex")
  runtime.setup({ filetypes = { tex = "latex" } })
  t.eq(vim.treesitter.language.get_lang("tex"), "latex")
  runtime.setup({ filetypes = false })
  t.eq(vim.treesitter.language.get_lang("tex"), "latex")
  assert(not pcall(runtime.setup, { filetypes = { tex = true } }))
end)

t.test("kind predicates and their native negations evaluate real syntax trees", function()
  runtime.setup()
  local source = "local one = 1\nlocal two = 2"
  local tree = vim.treesitter.get_string_parser(source, "lua"):parse()[1]
  for _, predicate in ipairs({ "kind-eq?", "any-kind-eq?", "not-kind-eq?", "not-any-kind-eq?" }) do
    local query = vim.treesitter.query.parse("lua", "((_) @item (#" .. predicate .. ' @item "identifier"))')
    local count = 0
    for _, node in query:iter_captures(tree:root(), source, 0, -1) do
      count = count + 1
      t.eq(node:type() == "identifier", not predicate:match("^not%-"))
    end
    assert(count > 0)
  end
end)

t.test("quantified predicates preserve all/any and absent-capture semantics", function()
  local add, list = vim.treesitter.query.add_predicate, vim.treesitter.query.list_predicates
  local handlers = {}
  vim.treesitter.query.list_predicates = function()
    return {}
  end
  vim.treesitter.query.add_predicate = function(name, fn)
    handlers[name] = fn
  end
  runtime.setup({ filetypes = false })
  vim.treesitter.query.add_predicate, vim.treesitter.query.list_predicates = add, list
  local function node(kind)
    return {
      type = function()
        return kind
      end,
    }
  end
  local match = { [1] = { node("identifier"), node("number") } }
  local predicate = { "kind-eq?", 1, "identifier" }
  assert(not handlers["kind-eq?"](match, nil, nil, predicate))
  assert(handlers["any-kind-eq?"](match, nil, nil, predicate))
  predicate[4] = "number"
  assert(handlers["kind-eq?"](match, nil, nil, predicate))
  assert(handlers["kind-eq?"]({}, nil, nil, predicate))
  assert(handlers["any-kind-eq?"]({ [1] = {} }, nil, nil, predicate))
end)

t.test("repeated setup leaves existing predicate providers installed", function()
  local add, calls = vim.treesitter.query.add_predicate, 0
  vim.treesitter.query.add_predicate = function(...)
    calls = calls + 1
    return add(...)
  end
  runtime.setup()
  runtime.setup()
  vim.treesitter.query.add_predicate = add
  t.eq(calls, 0)
end)

t.test("invalid runtime options do not replace the previous parser store", function()
  local tc = require("toolchain")
  local util = require("toolchain.parser_util")
  local directory = vim.fs.normalize(vim.fn.stdpath("state") .. "/runtime-options")
  vim.fn.mkdir(directory .. "/current", "p")
  util.write_json(directory .. "/current/lua.json", { version = "abcd-1-2" })
  tc.setup({ log_file = false, parsers = { install_dir = directory } })
  assert(not pcall(tc.setup, { parsers = { install_dir = directory .. "-invalid", filetypes = { tex = true } } }))
  t.eq(require("toolchain.parsers").info("lua").current, directory .. "/versions/lua/abcd-1-2")
end)

t.done()
