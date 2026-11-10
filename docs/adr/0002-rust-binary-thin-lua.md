# A Rust binary owns the data; a thin Lua layer owns the UI; they talk per call over JSON

The `codereader` Rust binary owns storage, Project identity, re-finding Anchors (Drift and Orphan detection), Trail tree operations and Note search. Lua owns everything Neovim-facing: UI, the LSP jump hooks that create Stops, and Treesitter symbol paths (Neovim already ships the parsers, so Rust needs no grammars). Lua calls `codereader <cmd> --json` once per operation, asynchronously, and checks a `schema_version` in every payload; this mirrors the author's jenkins.nvim / red.nvim plugins. Putting the data in Rust makes the Note store usable outside Neovim: a CLI now, an MCP server for agents later.

## Considered Options

- **Pure Lua**: rejected; the Note store would be locked inside Neovim.
- **Persistent `codereader serve` over JSON-RPC**: deferred; faster for frequent Stop recording but needs lifecycle management. All calls go through `lua/codereader/backend.lua` so this can be swapped in later without touching the rest.
- **In-process `mlua` cdylib**: rejected; a Rust panic takes Neovim down and the build is tied to the LuaJIT ABI.

## Consequences

- The binary and plugin live in one repo (`crates/codereader/` + `lua/`, `plugin/`) and are built with `cargo build --release` from the plugin manager, so their versions never diverge.
- Unsaved buffer text is sent from Lua to the binary so Anchors are resolved against what the Reader sees, not the stale file on disk.
