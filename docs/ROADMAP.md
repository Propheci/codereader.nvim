# Roadmap

## v1

**Notes**
- Four Anchor kinds: Range, Symbol, File, Project.
- Anchor kind comes from context: visual selection → Range; normal mode inside a function/class → Symbol (else Range on current line); separate commands for File and Project Notes.
- A Note is Markdown; its first line is the title. Edited in a floating Markdown buffer; `:w` or closing saves.
- Shown in the buffer as a sign + dim virtual text of the title; keymap opens the full Note in a float; command toggles virtual text.
- Drift: Anchors are re-found after code moves. If the anchored text changed, the Note is shown as Drifted (different sign colour) until confirmed or edited.
- Unfindable Anchors make the Note an Orphan, listed in an Orphans view where it can be re-attached, turned into a File Note, or deleted. Notes are never silently lost.
- Symbol Anchors use Treesitter container paths (e.g. `UserService > login`), falling back to LSP document symbols.
- Notes may anchor to code outside the Project (e.g. `node_modules`, stdlib); they belong to the current Project and use an absolute path.

**Trails**
- Named Trails, one active at a time; an unnamed Trail is created automatically. All Trails are saved.
- Stops are added on LSP jumps (definition, references, implementation, type definition) and by a manual command.
- Going back and jumping elsewhere creates a branch; a Trail is a tree.
- Back/forward commands move along the active Trail (at a branch, the most recently visited child). Trail side view jumps to any Stop.
- Stops outside the Project are recorded.
- Notes and Trails are independent; the Trail view shows Notes at or near each Stop.

**Trails (cont.)**
- A Stop is re-found like a Range Anchor (line + snapshot); unfindable Stops show as "lost" in the Trail section, not in Orphans.
- Each Neovim instance has its own active Trail; the binary locks every file write.

**Panel (home screen)**
- `:CodeReader` with no subcommand toggles the Panel; subcommands remain for scripting and keymaps.
- One Neogit-style buffer with collapsible sections (`<Tab>`): Header (Project, active Trail, Drifted/Orphan counts), Trail tree, Notes here (current file), Needs attention (Drifted + Orphans), key-hint footer.
- File Notes appear at the top of "Notes here" and as a sign on line 1 of the file. Project Notes have their own "Project Notes" section below the Header, collapsed by default.
- Trail section: per Stop, the symbol path (or `file:line`), the shortened code line, `●` if a Note is at or near it, a current-Stop marker; branches as an indented tree.
- Right vertical split by default (position/width/float configurable); stays open and follows the current file and new Stops.
- Panel actions that need a code location use the cursor of the last code window.
- Panel keys are buffer-local defaults; `?` opens a help float listing every action.
- UI built on a copy of the jenkins.nvim `ui/` framework (component, renderer, buffer, spinner) in `lua/codereader/ui/`.

**Keymaps**
- No global keymaps by default. Opt-in `setup{ keymaps = { prefix = "<leader>c" } }` installs: `<prefix>c` Panel, `<prefix>n` add Note (normal + visual), `<prefix>s` add Stop, `[t` / `]t` Trail back/forward.

**Finding Notes**
- Telescope picker of all Notes in the Project (full-text search) and of Notes in the current file.
- Picker actions: `<CR>` jump, `<C-e>` edit, `<C-d>` delete (confirm), `<C-y>` confirm a Drifted Note; preview shows the Note above the anchored code.
- Free `#tags` in Note text; the picker filters by tag.
- Orphans picker → select Note → go to new code → `:CodeReader attach`. `attach` also moves any Note.

**Platform**
- Rust binary `codereader` (storage, Project identity, Anchor re-finding, Trail tree, search) + thin Lua UI, per-call JSON. See ADR 0002.
- The binary is also a usable CLI (`codereader notes`, `codereader search`, `codereader trail show`, …).
- Telescope picker behind a small adapter (snacks/fzf-lua addable later).
- Neovim 0.11+.
- No default keymaps: `:CodeReader <subcommand>` with completion, `<Plug>` mappings, suggested keymaps in the README. Lua module `require("codereader")`.
- Project = git root path, else cwd; overridable by config.
- Storage outside the repo by default (one Markdown file per Note, JSON per Trail), config option to move into the repo. See ADR 0001.
- Tests: `cargo test` + headless `tests/spec.lua` against the real debug binary, fake binary for schema-version refusal.
- No AI integration.

## Later

- **Progress marks**: mark a function or file as "understood", "confusing", "dead code", and so on. Show how much of the Project the Reader has covered.
- **Tours**: an ordered list of code locations that the Reader makes by hand to explain one flow (for example "how a request gets to the DB").
- **MCP server** (`codereader mcp`): lets Claude or another agent read the Reader's Notes and Trails while working on the same codebase.
- **AI assist**: an LLM writes a draft Note that the Reader then edits.
- **Persistent backend** (`codereader serve`, JSON-RPC over stdio) if per-call latency becomes a problem.
- **More picker backends**: snacks.picker, fzf-lua.
- **Question Notes**: a typed `#question` with open/answered state, if `#question` tags become common.
- **UI screenshot tests** (mini.test) if the UI starts to regress.
