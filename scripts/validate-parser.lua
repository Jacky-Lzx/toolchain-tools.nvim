local root, language = arg[1], arg[2]
local plugin_root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.rtp:prepend(plugin_root)
require("toolchain.runtime").setup()
local paths = { root }
vim.list_extend(paths, vim.json.decode(arg[3] or "[]"))
paths[#paths + 1] = vim.env.VIMRUNTIME
vim.opt.rtp = paths
local library = root .. "/parser/" .. language .. ".so"
vim.treesitter.language.add(language, { path = library })
vim.treesitter.get_string_parser("", language):parse()
local queries = root .. "/queries/" .. language
if vim.fn.isdirectory(queries) == 1 then
  for name, kind in vim.fs.dir(queries) do
    if kind == "file" and name:match("%.scm$") then
      local file = assert(io.open(queries .. "/" .. name))
      local text = file:read("*a")
      file:close()
      vim.treesitter.query.parse(language, text)
      assert(vim.treesitter.query.get(language, name:sub(1, -5)), "Missing query: " .. name)
    end
  end
end
print("Validated parser ABI and queries: " .. language)
