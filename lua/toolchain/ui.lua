local M = {}
local view

local function dimensions()
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(22, vim.o.lines - vim.o.cmdheight - 4))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
  }
end

local function render(entries)
  if not view or not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  local toolchain = require("toolchain")
  entries = entries or (view.plan and toolchain.plan() or toolchain.status())
  local lines = {
    view.plan and "Configured requirements (local checks only)" or "Installation tasks",
    "i install configured | r retry selected | c cancel queued | Enter details | q close",
    "",
  }
  view.rows = {}
  if view.detail then
    for _, entry in ipairs(entries) do
      if entry.id == view.detail then
        lines[#lines + 1] = entry.id .. "  [" .. entry.state .. "]"
        lines[#lines + 1] = entry.message or ""
        for _, chunk in ipairs(entry.logs or {}) do
          vim.list_extend(lines, vim.split(chunk:gsub("\r", ""), "\n", { plain = true }))
        end
        break
      end
    end
  else
    for _, entry in ipairs(entries) do
      lines[#lines + 1] =
        string.format("%-10s %s%s", entry.state, entry.id, entry.attempt and "  #" .. entry.attempt or "")
      view.rows[#lines] = entry.id
    end
  end
  if #lines == 3 then
    lines[#lines + 1] = "No tasks. Use :ToolchainPlan to inspect requirements or i to install."
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
end

function M.open(plan)
  -- Resolve before opening a window, so an invalid dynamic declaration cannot
  -- leave an empty floating window behind.
  local entries = plan and require("toolchain").plan() or require("toolchain").status()
  if view and vim.api.nvim_win_is_valid(view.win) then
    view.plan, view.detail = plan, nil
    vim.api.nvim_set_current_win(view.win)
    render(entries)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "toolchain"
  local win = vim.api.nvim_open_win(
    buf,
    true,
    vim.tbl_extend("force", dimensions(), {
      style = "minimal",
      border = "rounded",
      title = " Toolchain ",
    })
  )
  vim.wo[win].wrap = false
  view = { buf = buf, win = win, plan = plan, rows = {} }
  local group = vim.api.nvim_create_augroup("ToolchainView" .. buf, { clear = true })
  local function refresh()
    if view and view.buf == buf then
      local ok, err = pcall(render)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "toolchain-tools" })
      end
    end
  end
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ToolchainUpdated",
    callback = function()
      if view and view.buf == buf and not view.scheduled then
        view.scheduled = true
        vim.schedule(function()
          if view and view.buf == buf then
            view.scheduled = false
            refresh()
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, dimensions())
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      if view and view.buf == buf then
        view = nil
      end
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  local function map(key, fn)
    vim.keymap.set("n", key, function()
      local ok, err = pcall(fn)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "toolchain-tools" })
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
  local function selected()
    return view.detail or view.rows[vim.api.nvim_win_get_cursor(win)[1]]
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    map(key, function()
      vim.api.nvim_win_close(win, true)
    end)
  end
  map("i", function()
    require("toolchain").install()
    view.plan, view.detail = false, nil
    refresh()
  end)
  map("r", function()
    assert(not view.plan, "Install the plan before retrying tasks")
    local id = selected()
    assert(id, "Select a task first")
    require("toolchain").retry({ id })
  end)
  map("c", function()
    assert(not view.plan, "The plan contains no queued tasks")
    local id = selected()
    assert(id, "Select a task first")
    local ok, err = require("toolchain").cancel(id)
    assert(ok, err)
  end)
  map("<CR>", function()
    view.detail = not view.detail and selected() or nil
    refresh()
  end)
  render(entries)
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
end

return M
