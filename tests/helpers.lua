vim.opt.rtp:prepend(vim.fn.getcwd())
local M = { count = 0 }

function M.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    io.stderr:write("FAIL " .. name .. "\n" .. err .. "\n")
    vim.cmd("cquit 1")
  end
  M.count = M.count + 1
  print("ok " .. name)
end

function M.eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end

function M.wait(fn)
  assert(vim.wait(2000, fn, 5), "timed out")
end

function M.done()
  print("Passed " .. M.count .. " tests")
end

return M
