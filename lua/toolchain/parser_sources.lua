local M = {}
local util = require("toolchain.parser_util")
local inflight = {}

function M.get(source, cache, log, done)
  util.source(source)
  local key = util.hash(source.url .. "\n" .. source.revision)
  local target = vim.fs.joinpath(cache, "sources", key)
  if util.json(target .. "/.toolchain-source.json") then
    return done(target)
  end
  if inflight[target] then
    inflight[target][#inflight[target] + 1] = { done = done, log = log }
    return
  end
  inflight[target] = { { done = done, log = log } }
  local temporary = target .. "-" .. vim.uv.os_getpid() .. "-" .. vim.uv.hrtime()
  local release
  local function output(message)
    for _, waiter in ipairs(inflight[target]) do
      waiter.log(message)
    end
  end
  util.run(function()
    release = util.lock(target .. ".lock")
    if util.json(target .. "/.toolchain-source.json") then
      return target
    end
    vim.fn.mkdir(temporary, "p")
    util.command({ "git", "init", "--quiet", temporary }, nil, output)
    util.command({ "git", "-C", temporary, "remote", "add", "origin", source.url }, nil, output)
    util.command({ "git", "-C", temporary, "fetch", "--quiet", "--depth=1", "origin", source.revision }, nil, output)
    util.command({ "git", "-C", temporary, "checkout", "--quiet", "--detach", "FETCH_HEAD" }, nil, output)
    local actual = vim.trim(util.command({ "git", "-C", temporary, "rev-parse", "HEAD" }, nil, output))
    assert(actual == source.revision, "Source commit did not match the pinned revision")
    util.write_json(temporary .. "/.toolchain-source.json", { url = source.url, revision = actual })
    if vim.uv.fs_stat(target) then
      vim.fn.delete(target, "rf")
    end
    assert(vim.uv.fs_rename(temporary, target))
    return target
  end, function(ok, value)
    vim.fn.delete(temporary, "rf")
    if release then
      release()
    end
    local waiters = inflight[target]
    inflight[target] = nil
    for _, waiter in ipairs(waiters) do
      if ok then
        waiter.done(value)
      else
        waiter.done(nil, value)
      end
    end
  end)
end

return M
