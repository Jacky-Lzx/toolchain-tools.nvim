# toolchain-tools.nvim

Explicit tool and Tree-sitter parser installation with a shared task queue.

## Features

- Inspect requirements without downloading or starting language services.
- Install independent tools and immutable parser/query bundles.
- Track versions, project locks, retries and installation logs.

## Requirements

Neovim **0.11+**. Parser builds require Git, the Tree-sitter CLI and a C compiler. Tool recipes use platform download/archive utilities and their package managers. Mason and nvim-treesitter adapters are optional.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/toolchain-tools.nvim",
  main = "toolchain",
  opts = { requirements = { { provider = "system", name = "git" } } },
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("toolchain").setup({
  requirements = { { provider = "system", name = "git" } },
})
```

## Usage

```vim
:ToolchainPlan
:ToolchainInstall
:Toolchain
```

## Documentation

- [Complete reference](doc/toolchain.txt) — `:help toolchain-tools`.
- [Workflow and integration guide](doc/guide.md).
- Diagnose availability with `:checkhealth toolchain`.

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.
