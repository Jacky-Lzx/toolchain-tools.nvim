The parser metadata in `data/parsers.json` is adapted from nvim-treesitter at
commit `29212d826054bb2948fa9d3a99eca9bf6a050eb2`, under the Apache License 2.0
(see `nvim-treesitter-LICENSE`). It covers the configured language profiles and
their shared-query dependencies. KDL and Python tags were resolved to commit SHAs.

Queries are downloaded as data from that exact upstream commit. The independent
installer does not execute or require nvim-treesitter's Lua modules. Each grammar
and query repository retains its own license in the source cache.
