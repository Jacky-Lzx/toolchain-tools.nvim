# toolchain-tools.nvim

One installation queue for independent tools and Tree-sitter parsers, optional Mason packages, and checks for
tools supplied by Nix or your system package manager.

Inspect requirements, install explicitly, and follow every task in the same
window. Existing tools take priority; installation failures remain visible and
can be retried. Nothing is downloaded during setup, planning, or health checks.
The installation queue loads on the first queue operation; setup, planning, and
empty status/wait checks leave it unloaded. Installed tool PATH entries, immutable
parser/query paths, and tool session leases are still activated synchronously.

Requires Neovim 0.11+. The independent `parser` backend needs Git, the Tree-sitter
CLI, and a C compiler on macOS/Linux. Independent tools use host download/archive
utilities and the package managers needed by their recipes. The optional `mason` backend needs
[Mason v2](https://github.com/mason-org/mason.nvim). An optional legacy `treesitter`
adapter still supports [nvim-treesitter main](https://github.com/nvim-treesitter/nvim-treesitter)
(not its old `master` API). This plugin manages
installation; highlighting, folding, indentation, LSP configuration, and language
selection stay with Neovim and your configuration.

## Quick start

For a local checkout with lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/toolchain-tools.nvim"),
  main = "toolchain",
  lazy = false, -- activate committed parser/query versions before opening files
  opts = {
    concurrency = 2,
    requirements = {
      { provider = "parser", name = "lua" },
      { provider = "parser", name = "markdown" },
      { provider = "tool", name = "lua-language-server", executable = "lua-language-server" },
      { provider = "tool", name = "stylua", executable = "stylua" },
      { provider = "system", name = "git" },
      { provider = "system", name = "html_beautify", optional = true },
    },
  },
}
```

If these dependencies already have plugin specs, keep their existing setup there.
Mason must have completed `setup()` before its backend runs. nvim-treesitter's
default installation directory works without setup; configure a custom directory
with its own `setup()`. This plugin never changes either compatibility backend's settings or PATH. The independent `parser` provider does not require nvim-treesitter. Backend
build hooks or other plugins may still perform their own installs;
only work submitted through toolchain-tools belongs to this queue.

Run `:ToolchainPlan` to inspect requirements, then `:ToolchainInstall` to install
them. `:Toolchain` opens the live task window.

## Independent tool backend

The `tool` provider installs into its own versioned store without Mason APIs.
The bundled registry covers the 37 packages declared by the current language
profiles. Recipes can also be supplied through `tools.sources`. Supported installers
are pinned release downloads (tar/zip/gzip/raw), isolated npm prefixes, Python
virtual environments, Cargo Git tags, and pinned npm source builds. The initial
platforms are macOS and Linux on x86-64/ARM64, subject to upstream asset availability.
For example, the current clangd release requires a system package on Linux ARM64.

New npm/Python installations record their resolved dependency versions. Without a
project lock, initial resolutions can select new transitive versions. A project
lock freezes the complete recipes, verified release digests, npm/Python dependency
locks and resolved Cargo commit for each recorded platform. See below.

Recipes can be supplied through `tools.sources`. Setup appends existing managed binary directories to PATH (`tools.path = "skip"`
disables this) and records their use in a session lease. It never downloads or
creates an installation; existing stores may receive session metadata. System/Nix executables retain priority.

`:ToolchainInstall` also updates an installation to the currently pinned recipe.
To change versions, update the recipe first; it never silently selects latest.
`:ToolchainUninstall tool:<package>` removes its activation pointer and PATH entry,
retaining version files for already running processes. Restart clients after
installing a new tool version. External package managers and their global installs
are never modified. The Mermaid recipe keeps its browser cache within its version.
Python uses an available versioned Python 3 executable and optionally uv for pip operations.
Installations build at their final version path so Python virtual environments
remain valid, and publish an atomic current-version pointer only after validation.
Failed installations retain the previous version. Old versions are kept for running
processes. Explicit installs verify artifacts and repair changed or missing files. Python
bytecode caches are excluded; LuaLS logs/generated metadata and JDTLS OSGi
configuration caches live outside their version directories.

`require("toolchain.tools").executable(package, command)` resolves a managed binary;
`.path(package, resource)` resolves declared resources, and `.info(package)` reports
the current root, receipt and integrity. Post-install hooks for `tool` receive a
neutral `{ name, path, version, resources }` record before publication. Intact
installations skip their hooks; changing a recipe creates a new version.

## Project tool locks

```lua
require("toolchain").setup({
  tools = { lockfile = "/path/to/config/toolchain-lock.json" },
  requirements = {
    { provider = "tool", name = "stylua", executable = "stylua" },
    { provider = "tool", name = "debugpy" },
  },
})
```

- `:ToolchainLock! [file]` explicitly resolves configured tool recipes, installing
  managed copies even when system tools exist, then atomically writes the lock.
- `:ToolchainLock [file]` exports already installed, intact managed versions;
  it fails if any configured tool lacks a verified installation.
- Ordinary `:ToolchainInstall` reads `tools.lockfile` without rewriting it. A
  missing platform/package entry fails before its installer resolves anything.
  Source overrides and bundled registry changes take effect only on explicit
  lock updates. Set `tools.lockfile = false` to use unlocked recipes.

Commit the lock with your configuration. Locks contain no installation roots or
Python environment paths. Each platform has a separate entry; generating a lock
on another platform preserves existing platform entries. Python installs require
an available interpreter with the recorded major/minor version. Host runtimes,
system/Nix tools and custom build commands remain external prerequisites.
System tools still take priority during ordinary installation; locks govern the
managed fallback. Custom post-install hooks must remain deterministic.

New stores and repairs use `npm ci`, the frozen Python requirements, exact release
checksums, and Cargo `--rev` with a full commit SHA. Frozen dependency verification
happens before publication. Failed resolution, checksum verification or export
retains the previous current version and lock file. Startup/planning never write
or resolve a lock. Export merges are serialized across processes.

Lua APIs: `require("toolchain").lock(path, update)` (update defaults to false),
`.lock_status()` (`resolving`, `writing`, `written` or `failed`), and `.wait()` for
queued resolution/export completion. `User ToolchainLockWritten` fires only after
an atomic write. `unlocked = true` is an explicit tool-only requirement override
used by lock updates. A lock snapshot covers independent `tool` requirements;
parser Git/query pins continue to come from the parser registry.

## Tool versions and rollback

- `:ToolchainVersions [tool:name]` lists immutable version IDs and current,
  protected, retired or incomplete state.
- `:ToolchainRollback tool:name <version-id>` verifies the receipt, platform,
  artifact hashes and entrypoints before atomically selecting that version.
  Use the immutable ID shown in the list. Failed validation retains the current
  pointer. The project lock is unchanged; subsequent installation follows it.
- `:ToolchainPrune [tool:name]` opens a **read-only preview**. It never deletes
  version files. Current versions, recorded live editor sessions, active writers
  and uncertain session records are excluded from cleanup candidates.

Session records accumulate every version activated by the editor, so upgrades,
rollback and uninstall cannot mark a version still used by that editor as a
candidate. A normal exit releases its records; dead owners no longer protect
retired versions. These records cover editor sessions using this implementation;
external programs and older editor sessions are not tracked. Version files are
always retained. Restart existing language/debug clients to use a newly selected
version. Reports close with `q` and preserve the source buffer.

`require("toolchain.tools").packages()` lists installed package names.
`.versions(name)` and `.prune_plan(name)` return the
same records (`id`, `version`, `current`, `recorded`, `compatible`, `protected`,
`reasons`, `candidate`, `root`). `.rollback(name, id)` performs verified selection.
Listing does not imply artifact integrity; rollback always validates the target.
Version paths are permanent, including Python virtual environments. Current
pointer descriptors keep startup/resource lookup independent of large manifests;
legacy pointers are upgraded during explicit installation or lock export.

## Independent parser installation

`provider = "parser"` downloads pinned Git commits, builds with `tree-sitter build`,
and installs matching queries. It never requires nvim-treesitter Lua modules.
The bundled registry covers the current language profiles and their query
dependencies and previously installed fallback languages (48 definitions); see
[source attribution](third_party/README.md).
Queries remain pinned data from the upstream nvim-treesitter repository. This
stage replaces installation, while reusing its maintained query collection.

```lua
require("toolchain").setup({
  requirements = { { provider = "parser", name = "latex" } },
  parsers = {
    -- Defaults below; neither directory is created until installation.
    install_dir = vim.fn.stdpath("data") .. "/toolchain-tools/parsers",
    cache_dir = vim.fn.stdpath("cache") .. "/toolchain-tools/parsers",
    sources = {
      latex = {
        parser = {
          url = "https://github.com/your-org/tree-sitter-latex",
          revision = "<full 40-character commit SHA>",
          generate = true,
        },
      },
    },
  },
})
```

Language definitions accept `parser = { url, revision, location?, generate?,
generate_from_json?, queries? }`, `query_path` (relative to the query source),
`query_source = { url, revision }`, and `requires = { "shared_language" }`.
`generate_from_json` defaults to true when generation is requested; use false
for grammars that must generate from grammar.js. `parser.queries` selects queries
from the grammar repository instead of the separate query source. A definition
without `parser` installs shared queries only. New definitions can be supplied in
`parsers.sources`; overrides replace individual definition fields. Local Git
repository paths are supported as URLs for offline builds. Revisions must be
complete commit SHAs, including when replacing a tag or branch-based configuration.

Dependencies are installed before their consumer and concurrent requests share
work. Inherited query text is frozen inside the consumer's version so later
shared-query updates cannot change an older parser's query bundle. Shared-query-only
directories are build inputs and are not added to runtimepath. An isolated child
Neovim validates the library ABI and queries, including
inherited queries, before the completed version becomes current. Receipts record
source revisions, ABI, architecture-dependent fingerprints and file hashes. Repeating
an installation skips intact artifacts and repairs missing or changed files.
Changing the pinned sources rebuilds the relevant artifacts on explicit installation.

Each complete version has its own immutable runtime directory. A single renamed
JSON pointer selects the next version; failed builds retain the previous pointer.
Activation pointers carry the parser flag and receipt size/mtime, so startup can
mount unchanged versions without decoding each full receipt. Old pointers,
malformed metadata, and changed receipts fall back to reading the receipt.
`:ToolchainRefreshParsers` (or `require("toolchain.parsers").refresh_activation()`)
explicitly refreshes existing pointers under per-language locks. It changes no
selected versions or version contents. New installations write this metadata
automatically. Setup does not refresh pointers; installation and `info()` retain
full artifact validation.

Setup activates current versions once per language in the session. Installation
does not switch versions underneath a loaded parser: **restart Neovim after an
installation to use its new parser/query versions**. Old versions are retained
so other running sessions keep their files; no automatic cleanup is performed.
Per-language/source locks reject concurrent writers from another process, and
dead owners can be recovered on retry. Build stdout/stderr goes to task logs.

Inspect an installed language with
`require("toolchain.parsers").info("latex")` (current/session roots, receipt, and
artifact integrity). Existing parsers in `site/parser` are never overwritten.
Setup also registers default filetype aliases and the `kind-eq?`/
`any-kind-eq?` query predicates. Existing predicate providers and custom language
associations are preserved. Explicit overrides use `parsers.filetypes = {
tex = "my_latex" }`; `parsers.filetypes = false` skips default alias registration.
An isolated build validator uses the same compatibility runtime.

Before removing an older runtime provider, independently install any additional
languages you still use. Existing `site/queries` symlinks may point into its
checkout even when it is absent from runtimepath; do not rely on those links as
evidence that the migration is complete. Managed query bundles are regular files
with their own receipts. `nvim-treesitter-textobjects` remains a separate plugin.
The `treesitter` provider remains available as an explicit compatibility adapter.

## Commands and task window

| Command | Action |
| --- | --- |
| `:Toolchain` | Show tasks from this Neovim session |
| `:ToolchainPlan` | Show configured requirements and local executable availability |
| `:ToolchainInstall [provider:name ...]` | Install all configured requirements or selected IDs |
| `:ToolchainLock[!] [file]` | Export installed tools; `!` explicitly resolves managed recipes first |
| `:ToolchainVersions [tool:name]` | List immutable tool versions and protection state |
| `:ToolchainRollback tool:name version-id` | Verify and activate an existing tool version |
| `:ToolchainPrune [tool:name]` | Preview cleanup candidates without deleting files |
| `:ToolchainUninstall tool:name` | Deactivate an independent tool; retain its version files |
| `:ToolchainRetry [provider:name ...]` | Retry failed, unavailable, or cancelled tasks using their original declaration |
| `:ToolchainCancel provider:name` | Cancel a task that is still queued |
| `:ToolchainLog` | Open a read-only snapshot of the persistent JSON-lines log |
| `:checkhealth toolchain` | Check declarations and backend availability without installing |

In the window: `i` installs all configured requirements, `r` retries the selected
task, `c` cancels it if queued, `Enter` toggles details, and `q`/`Esc` closes the
window. Closing the window does not stop installation.

Task states are `queued`, `running`, `installed`, `skipped`, `unavailable`,
`failed`, and `cancelled`. `unavailable` means an optional system executable is
absent, and does not trigger a failure notification. Repeated submissions of an
identical active requirement share its task. Submitting it again after completion
rechecks availability. Conflicting
declarations for the same ID are rejected before anything is queued.

The plan deliberately reports backend-managed requirements as `check`, not
`missing`: it does not load Mason/nvim-treesitter or consult their registries.
`available` means an executable was found locally; it does not certify its version.

## Requirements and language profiles

A requirement has `provider` and `name`, with optional fields:

| Field | Meaning |
| --- | --- |
| `executable` | Command/path to check before a managed-tool install, or for a system requirement |
| `resolve` | Function returning an existing executable path, or `nil`/`false`; falls back to `executable` |
| `post_install` | Synchronous managed-tool hook; Mason compatibility receives its package object |
| `post_install_async` | Managed-tool hook receiving `(package, done, log)`; calls `done()` on success or `done(error)` on failure |
| `optional` | System-only boolean, default `false`; missing optional executables finish as `unavailable` |

System requirements default their executable to `name`; managed requirements do
not, since registry package names and executable names can differ. Resolver
errors fail the individual task. Keep resolvers read-only: planning and health
checks also call them. Optional declarations change only how an absent system
tool is reported: resolver errors and malformed declarations still fail. Plans
show `unavailable` and health reports it as information. Explicit retries recheck
these tools, so they can become `skipped` after you install them externally.
System requirements never install packages themselves. This option does not
suppress tool/Mason/parser download, compilation, or post-install failures.

Mason binaries already on PATH are recognized as Mason-managed, including
symlinks under its configured install root. Their package checks and hooks still
run. Hooks run after installation and for already-installed Mason packages; they
do not run when a system/Nix executable satisfies the requirement. Write hooks
so they are safe to run again. A hook error fails the task without removing its
installed package.

Use exactly one hook field. An asynchronous hook retains the task's queue slot
until `done` is called, including for an already-installed Mason package. Errors
thrown while starting either hook fail the task; asynchronous process failures
must be passed to `done(error)`. Repeated completion callbacks are ignored.

```lua
{
  provider = "mason",
  name = "vue-language-server",
  post_install_async = function(package, done, log)
    -- The language-specific helper must call done after its repair process exits,
    -- or immediately if no repair is needed. It may use log(output) for child output.
    require("my_vue_repair").run(package:get_install_path(), done, log)
  end,
}
```

A callback-based repair helper can forward a process result like this:

```lua
vim.system(command, { cwd = directory, text = true }, function(result)
  log(result.stdout or "")
  log(result.stderr or "")
  if result.code == 0 then
    done()
  else
    done("repair process exited with status " .. result.code)
  end
end)
```

Existing functions that start asynchronous work and return immediately must be
adapted to call this callback, including the current Vue TypeScript repair helper.
Leaving them in `post_install` still has synchronous semantics. Hooks have no
implicit timeout: forgetting `done` keeps the task running. `wait(timeout)` can
return control without marking a still-running process complete or freeing its slot.

Pass a function as `requirements` to reuse your existing language declarations.
It is evaluated when planning or installing, rather than during setup. For the
existing `languages.current()` records:

```lua
require("toolchain").setup({
  requirements = function()
    local language = require("languages").current()
    local requirements = {}
    for _, name in ipairs(language.parsers) do
      requirements[#requirements + 1] = { provider = "parser", name = name }
    end
    for _, tool in ipairs(language.tools) do
      requirements[#requirements + 1] = {
        provider = tool.package and "tool" or "system",
        name = tool.package or tool.executable,
        executable = tool.executable,
        resolve = tool.resolve,
        post_install = tool.post_install,
        post_install_async = tool.post_install_async,
        optional = tool.optional,
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
During adaptation, mark optional system dependencies explicitly, for example
`html_beautify`; language/profile selection and optional-feature policy remain
in your configuration. The existing language schema/helper functions must also
be adapted before storing async hooks or optional flags in those declarations.

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
tc.install_ids({ "tool:stylua" })
local tasks = tc.status() -- independent snapshots, including logs and attempt numbers
local finished, final_tasks = tc.wait(300000)
tc.retry() -- failed, unavailable, cancelled; or tc.retry({ "tool:stylua" })
local cancelled, reason = tc.cancel("tool:stylua")
tc.open()
```

`install()` is asynchronous. `wait(timeout_ms)` reports whether the queue has
finished, including failed/cancelled/unavailable tasks; it does not imply success. A timeout
does not stop installers. To bootstrap in a script, inspect the final states:

```lua
tc.install()
local finished, tasks = tc.wait(300000)
assert(finished, "Installation timed out")
for _, task in ipairs(tasks) do
  assert(task.state == "installed" or task.state == "skipped"
    or task.state == "unavailable", task.id .. ": " .. task.message)
end
```

`setup()` replaces options and session task history, and is rejected while work
is queued/running. Requiring the module alone registers nothing. Setup registers
commands, but does not start installers or register buffer highlighting hooks.

Each task transition/output chunk emits `User ToolchainUpdated` with
`event.data = { id, state, attempt, optional, message }`. UI integrations can read
`tc.status()`; consuming the event does not require the built-in window.

## Installation boundaries

- Concurrency limits submitted tasks. A backend may create child processes or
  queue internally. The legacy `treesitter` adapter passes `max_jobs = 1` for
  each task, including its implicit parser dependencies.
- Running tasks cannot be cancelled safely across all installers in this version.
  They retain their slot until the backend completes; use queued cancellation.
- Mason installations already running outside this queue produce a retryable
  failure rather than starting another installer.
- The independent parser backend verifies pinned sources, compiled parsers and
  query artifacts before activation. The optional legacy `treesitter` adapter
  verifies upstream completion; its upstream backend owns compatibility.
- Persistent logs contain lifecycle events, independent tool/parser build output
  and optional Mason stdout/stderr. The legacy `treesitter` adapter's build
  details remain in `:TSLog`.
- Memory logs are bounded per task. The persistent log is append-only; rotate or
  remove it yourself when needed. Session tasks are not resumed after a restart.
- Managed parser updates follow explicit pinned-source changes and integrity checks.
  Package updates use explicit recipe/lock changes. Version cleanup remains a read-only
  preview; automatic deletion is not implemented.

## Validation

```sh
sh tests/run.sh
stylua --check lua scripts tests
sh tests/run.sh --tools   # offline npm/Python registries; needs Node/npm and Python venv
python3 tests/clean_protocols.py # downloads LuaLS/debugpy, frozen replay, real LSP/DAP
sh tests/run.sh --parsers # offline real Git/build/rollback tests; needs tree-sitter CLI

# Real upstream APIs and installation in disposable XDG directories; no downloads.
TOOLCHAIN_MASON_ROOT=/absolute/path/to/mason.nvim \
TOOLCHAIN_TREESITTER_ROOT=/absolute/path/to/nvim-treesitter \
  sh tests/run.sh --integration
```

The default suite exercises queue lifecycle/failure handling, API behavior,
backend contracts, multi-process version protection, and real PTY task-window
and version-management workflows. It needs Neovim and
Python 3 on a Unix host. Integration additionally needs actual upstream
checkouts, `tree-sitter`, a C compiler, and the grammar generator's requirements.
It installs a local Mason package, compiles and loads a local parser, and checks
that repeated installations skip both. All installation data is temporary.

For opt-in acceptance against an already installed tool store (including native
DAP launches and Mermaid browser rendering), run:

```sh
python3 tests/installed_tools.py --store /path/to/nvim/toolchain-tools/tools \
  --java-home /path/to/jdk21-or-newer
```

This test needs the 16 migrated tools, a C compiler and their host runtimes. It
uses temporary source/workspace files and does not install or update packages.

CI runs core tests on Linux (Neovim 0.11.5, stable, nightly) and macOS (stable).
Both platforms also install from empty stores and dependency caches: local npm
and Python registries verify frozen dependencies, repair and explicit updates;
real LuaLS/debugpy downloads verify frozen replay and LSP/DAP startup. These tests
load neither Mason nor nvim-treesitter. Cold tests require Node/npm, Python 3
with `venv`/pip, archive utilities and network access for the real downloads.
Global npm install settings are overridden per command; private registry settings
remain usable. Lock files do not install host runtimes or provide every upstream
binary on every architecture.

To reproduce Linux acceptance locally with an existing Docker engine:

```sh
docker build -f tests/linux/Dockerfile -t toolchain-tools-test tests/linux
docker run --rm --cpus=2 --memory=1g --pids-limit=256 --network none \
  -v "$PWD:/workspace:ro" toolchain-tools-test
docker run --rm --cpus=2 --memory=1g --pids-limit=256 \
  -v "$PWD:/workspace:ro" toolchain-tools-test python3 tests/clean_protocols.py
```

The checkout is mounted read-only. All tool stores and caches are disposable;
the offline suite uses loopback fixture registries with external networking disabled.

## Command ownership

Commands belong to the plugin; choose global entry keys and short aliases in
your configuration. Registration reports same-name conflicts without replacing
user commands. Reconfiguration refreshes only commands still owned by this
plugin, and cleanup preserves subsequent user replacements.
