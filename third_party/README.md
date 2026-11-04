The parser metadata in `data/parsers.json` is adapted from nvim-treesitter at
commit `29212d826054bb2948fa9d3a99eca9bf6a050eb2`, under the Apache License 2.0
(see `nvim-treesitter-LICENSE`). It covers the configured language profiles,
previously installed fallback languages and their shared-query dependencies.
KDL and Python tags were resolved to commit SHAs. `data/filetypes.json` preserves
the alias data from that same commit. The runtime supplies compatible `kind-eq?`
and `any-kind-eq?` semantics while preserving existing predicate providers.

Queries are downloaded as data from that exact upstream commit. The independent
installer does not execute or require nvim-treesitter's Lua modules. Each grammar
and query repository retains its own license in the source cache.

The normalized tool recipes in `data/tools.json` are adapted from
[mason-org/mason-registry](https://github.com/mason-org/mason-registry), release
`2026-11-04-mean-kite`, under Apache License 2.0 (see `mason-registry-LICENSE`).
The compiled registry SHA-256 is recorded in the data file. `scripts/import-tools.py`
reimports only the explicitly supported package names from a supplied registry
snapshot; it is not called at runtime. Floating Vue extras and Lombok downloads
are pinned explicitly. Each installed tool retains its upstream package license.
