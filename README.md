# toolchain-tools.nvim

One installation queue for Tree-sitter parsers, Mason packages, and checks for
tools supplied by Nix or your system package manager.

Inspect requirements, install explicitly, and follow every task in the same
window. Existing tools take priority; installation failures remain visible and
can be retried. Nothing is downloaded during setup, planning, or health checks.

Requires Neovim 0.11+. The optional backends have their own requirements:
[Mason v2](https://github.com/mason-org/mason.nvim) and
[nvim-treesitter main](https://github.com/nvim-treesitter/nvim-treesitter).
The legacy nvim-treesitter `master` API is unsupported. This plugin manages
installation; highlighting, folding, indentation, LSP configuration, and language
selection stay with Neovim and your configuration.

## Quick start

For a local checkout with lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/toolchain-tools.nvim"),
  main = "toolchain",
  dependencies = {
    { "mason-org/mason.nvim", opts = { PATH = "append" } },
    { "nvim-treesitter/nvim-treesitter", branch = "main", lazy = false },
  },
  opts = {
    concurrency = 2,
    requirements = {
      { provider = "treesitter", name = "lua" },
      { provider = "treesitter", name = "markdown" },
      { provider = "mason", name = "lua-language-server", executable = "lua-language-server" },
      { provider = "mason", name = "stylua", executable = "stylua" },
      { provider = "system", name = "git" },
    },
  },
}
```

If these dependencies already have plugin specs, keep their existing setup there.
Mason must have completed `setup()` before its backend runs. nvim-treesitter's
default installation directory works without setup; configure a custom directory
with its own `setup()`. This plugin never changes either backend's settings or
PATH. Backend build hooks or other plugins may still perform their own installs;
only work submitted through toolchain-tools belongs to this queue.

Run `:ToolchainPlan` to inspect requirements, then `:ToolchainInstall` to install
them. `:Toolchain` opens the live task window.

## Commands and task window

| Command | Action |
| --- | --- |
| `:Toolchain` | Show tasks from this Neovim session |
| `:ToolchainPlan` | Show configured requirements and local executable availability |
| `:ToolchainInstall [provider:name ...]` | Install all configured requirements or selected IDs |
| `:ToolchainRetry [provider:name ...]` | Retry failed/cancelled tasks, using their original declaration |
| `:ToolchainCancel provider:name` | Cancel a task that is still queued |
| `:ToolchainLog` | Open a read-only snapshot of the persistent JSON-lines log |
| `:checkhealth toolchain` | Check declarations and backend availability without installing |

In the window: `i` installs all configured requirements, `r` retries the selected
task, `c` cancels it if queued, `Enter` toggles details, and `q`/`Esc` closes the
window. Closing the window does not stop installation.

Task states are `queued`, `running`, `installed`, `skipped`, `failed`, and
`cancelled`. Repeated submissions of an identical active requirement share its
task. Submitting it again after completion rechecks availability. Conflicting
declarations for the same ID are rejected before anything is queued.

The plan deliberately reports backend-managed requirements as `check`, not
`missing`: it does not load Mason/nvim-treesitter or consult their registries.
`available` means an executable was found locally; it does not certify its version.

## Requirements and language profiles

A requirement has `provider` and `name`, with optional fields:

| Field | Meaning |
| --- | --- |
| `executable` | Command/path to check before a Mason install, or for a system requirement |
| `resolve` | Function returning an existing executable path, or `nil`/`false`; falls back to `executable` |
| `post_install` | Synchronous Mason-only hook receiving the package object |

System requirements default their executable to `name`; Mason requirements do
not, since registry package names and executable names can differ. Resolver
errors fail the individual task. Keep resolvers read-only: planning and health
checks also call them.

Mason binaries already on PATH are recognized as Mason-managed, including
symlinks under its configured install root. Their package checks and hooks still
run. Hooks run after installation and for already-installed Mason packages; they
do not run when a system/Nix executable satisfies the requirement. Write hooks
so they are safe to run again. A hook error fails the task without removing its
installed package.

Pass a function as `requirements` to reuse your existing language declarations.
It is evaluated when planning or installing, rather than during setup. For the
existing `languages.current()` records:

```lua
require("toolchain").setup({
  requirements = function()
    local language = require("languages").current()
    local requirements = {}
    for _, name in ipairs(language.parsers) do
      requirements[#requirements + 1] = { provider = "treesitter", name = name }
    end
    for _, tool in ipairs(language.tools) do
      requirements[#requirements + 1] = {
        provider = tool.mason and "mason" or "system",
        name = tool.mason or tool.executable,
        executable = tool.executable,
        resolve = tool.resolve,
        post_install = tool.post_install,
      }
    end
    return requirements
  end,
})
```

The plugin itself never imports `languages` or owns language/profile selection.
Any extra parsers previously added outside the language records, such as `regex`,
should be added to this returned list too. Once you adopt this integration, a
configuration command such as `ConfigToolsInstall` can call
`require("toolchain").install()` instead of invoking separate installers.

## Lua API and configuration

```lua
require("toolchain").setup({
  requirements = {}, -- list or function returning a list
  concurrency = 2,
  max_log_lines = 200, -- retained output chunks per task, each capped at 8 KiB
  log_file = vim.fn.stdpath("state") .. "/toolchain-tools.log", -- false disables persistence
  notify = true, -- notify on task failures
})

local tc = require("toolchain")
local plan = tc.plan() -- or tc.plan(requirements)
local ids = tc.install() -- or tc.install(requirements)
tc.install_ids({ "mason:stylua" })
local tasks = tc.status() -- independent snapshots, including logs and attempt numbers
local finished, final_tasks = tc.wait(300000)
tc.retry() -- or tc.retry({ "mason:stylua" })
local cancelled, reason = tc.cancel("mason:stylua")
tc.open()
```

`install()` is asynchronous. `wait(timeout_ms)` reports whether the queue has
finished, including failed/cancelled tasks; it does not imply success. A timeout
does not stop installers. To bootstrap in a script, inspect the final states:

```lua
tc.install()
local finished, tasks = tc.wait(300000)
assert(finished, "Installation timed out")
for _, task in ipairs(tasks) do
  assert(task.state == "installed" or task.state == "skipped", task.id .. ": " .. task.message)
end
```

`setup()` replaces options and session task history, and is rejected while work
is queued/running. Requiring the module alone registers nothing. Setup registers
commands, but does not start installers or register buffer highlighting hooks.

Each task transition/output chunk emits `User ToolchainUpdated` with
`event.data = { id, state, attempt, message }`. UI integrations can read
`tc.status()`; consuming the event does not require the built-in window.

## Installation boundaries

- Concurrency limits submitted tasks. A backend may create child processes or
  queue internally. Tree-sitter receives `max_jobs = 1` for each parser task,
  including its implicit parser dependencies.
- Running tasks cannot be cancelled safely across both backends in this version.
  They retain their slot until the backend completes; use queued cancellation.
- Mason installations already running outside this queue produce a retryable
  failure rather than starting another installer.
- The Tree-sitter backend checks actual parser installation, observes both task
  errors and boolean failure results, and verifies the parser appears afterward.
  Its upstream backend retains ownership of parser/query compatibility.
- Persistent logs contain lifecycle events and Mason stdout/stderr. Detailed
  Tree-sitter build output remains available through upstream `:TSLog`.
- Memory logs are bounded per task. The persistent log is append-only; rotate or
  remove it yourself when needed. Session tasks are not resumed after a restart.
- This first version installs missing dependencies. Updates, uninstallation,
  version lockfiles, and a replacement parser compiler are future work.

## Validation

```sh
sh tests/run.sh
stylua --check lua tests

# Real upstream APIs and installation in disposable XDG directories; no downloads.
TOOLCHAIN_MASON_ROOT=/absolute/path/to/mason.nvim \
TOOLCHAIN_TREESITTER_ROOT=/absolute/path/to/nvim-treesitter \
  sh tests/run.sh --integration
```

The default suite exercises queue lifecycle/failure handling, API behavior,
backend contracts, and a real PTY task-window workflow. It needs Neovim and
Python 3 on a Unix host. Integration additionally needs actual upstream
checkouts, `tree-sitter`, a C compiler, and the grammar generator's requirements.
It installs a local Mason package, compiles and loads a local parser, and checks
that repeated installations skip both. All installation data is temporary.
