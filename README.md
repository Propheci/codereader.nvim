# codereader.nvim

Read a large, unfamiliar (or vibe-coded) codebase without losing your place.

- **Notes**: short Markdown notes attached to a line range, a symbol, a file or the whole Project. If the code moves, the Note moves with it. If the code changes, the Note is marked **Drifted**. If the code is deleted, the Note becomes an **Orphan** and is kept until you re-attach it.
- **Trails**: a tree of the places you visited. LSP jumps (definition, references, …) add Stops automatically. If you go back and jump somewhere else, the Trail branches instead of forgetting where you were.
- **Panel**: one side window that shows everything, so you do not need to remember any commands.

Terms are defined in [`GLOSSARY.md`](GLOSSARY.md). Scope and decisions: [`docs/ROADMAP.md`](docs/ROADMAP.md), [`docs/adr/`](docs/adr).

## Install

Needs Neovim 0.11+, a Rust toolchain, and [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the pickers.

```lua
-- lazy.nvim
{
  dir = "~/work/personal/projects/codereader.nvim",
  build = "cargo build --release",
  dependencies = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("codereader").setup({
      keymaps = { prefix = "<leader>c" }, -- opt-in; omit for no global keymaps
    })
  end,
}
```

`setup()` options (with their defaults) are in [`lua/codereader/config.lua`](lua/codereader/config.lua). The most useful are `data_dir`, `in_repo` (store Notes in `<root>/.codereader/` so you can share them), `virtual_text` and `panel.position`.

## Use

Run `:CodeReader` to open the Panel. Press `?` in it for every key.

| Panel key | Action |
|---|---|
| `<CR>` | jump to the Note / Stop under the cursor, or fold a section |
| `a` / `A` / `P` | add a Note at the code cursor / File Note / Project Note |
| `e` `d` `c` `m` | edit / delete / confirm (Drifted) / move the Note to the code cursor |
| `s`, `[`, `]` | add a Stop, Trail back, Trail forward |
| `t` / `T` | pick the active Trail / start a named one |
| `/`, `o` | find any Note, pick an Orphan |

With `keymaps = { prefix = "<leader>c" }`:

| Key | Action |
|---|---|
| `<leader>cc` | toggle the Panel |
| `<leader>cn` | add a Note (visual mode: on the selection) |
| `<leader>cs` | add a Stop |
| `[t` / `]t` | Trail back / forward |

Every action is also a command (`:CodeReader <Tab>` completes them) and a `<Plug>(codereader-…)` mapping:

```
:CodeReader                         toggle the Panel
:[range]CodeReader note             add a Note (selection → range; in a function → symbol; else the line)
:CodeReader note file|project
:CodeReader show|confirm|delete     the Note under the cursor
:CodeReader move  →  :[range]CodeReader attach
:CodeReader notes [#tag]|here|orphans|drifted
:CodeReader stop|back|forward
:CodeReader trail new [name]|list|rename <name>
:CodeReader virtualtext|refresh
```

In a Note, the first line is its title. Write `#tags` anywhere (`#question`, `#bug`, `#lie`), and filter by them with `:CodeReader notes #question`.

### Outside Neovim

The `codereader` binary is a normal CLI over the same store:

```sh
codereader note list --resolve
codereader search "auth"
codereader trail list
codereader --json note list --status drifted   # the JSON the plugin reads
```

## Develop

```sh
cargo test                                              # Rust: store, re-finding, Trails, CLI contract
cargo build && nvim --headless --clean -u NONE -l tests/spec.lua   # Lua against the debug binary
```
