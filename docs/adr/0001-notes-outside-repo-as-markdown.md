# Notes live outside the repo by default, as one Markdown file per Note

Notes are personal and often blunt about the code ("this is a mess"), so by default they are stored outside the Project (under Neovim's data directory, one folder per Project) where they can never be committed by accident; a config option moves them into the repo for sharing. Each Note is its own Markdown file with the Anchor in frontmatter, so Notes stay readable and greppable outside Neovim (for example in Obsidian). Trails are tree-shaped data and are stored as JSON instead.

## Considered Options

- **In-repo `.codereader/` by default**: rejected; too easy to commit private notes.
- **One JSON file per Project for everything**: rejected; Notes become unreadable outside the plugin.
- **SQLite**: rejected; adds a dependency for no v1 benefit.
