local M = {}

function M.find(spec)
  local path = spec.resolve and spec.resolve() or nil
  assert(path == nil or path == false or type(path) == "string", "resolve must return an executable path or nil")
  if path and path ~= "" and vim.fn.executable(path) == 1 then
    return vim.fn.exepath(path)
  end
  local executable = spec.executable or (spec.provider == "system" and spec.name)
  if executable and vim.fn.executable(executable) == 1 then
    return vim.fn.exepath(executable)
  end
end

function M.install(spec, ctx)
  local path = M.find(spec)
  if path then
    ctx.done("skipped", "Using " .. path)
  elseif spec.optional then
    ctx.done("unavailable", "Optional system executable is unavailable: " .. (spec.executable or spec.name))
  else
    ctx.done("failed", "Required system executable is unavailable: " .. (spec.executable or spec.name))
  end
end

function M.external(spec)
  local path = M.find(spec)
  if not path then
    return
  end
  -- Mason adds its bin directory to PATH. Those executables still need Mason's
  -- package check and post_install hook, rather than being classified as system tools.
  local settings = package.loaded["mason.settings"]
  local root = settings and settings.current.install_root_dir or vim.fs.joinpath(vim.fn.stdpath("data"), "mason")
  local normalized_root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local normalized_path = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  if vim.fn.has("win32") == 1 then
    normalized_root, normalized_path = normalized_root:lower(), normalized_path:lower()
  end
  if not vim.startswith(normalized_path, normalized_root .. "/") and not require("toolchain.tools").owns(path) then
    return path
  end
end

return M
