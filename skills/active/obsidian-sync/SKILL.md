---
name: obsidian-sync
description: Read from and write to the ArryBarry Obsidian vault via REST API
---

# Obsidian Sync

This skill connects to the ArryBarry Obsidian vault via the Local REST API.

## Usage

### Read a note
```bash
./skills/active/obsidian-sync/sync.sh get "path/to/note.md"
```

### Write/update a note
```bash
./skills/active/obsidian-sync/sync.sh put "path/to/note.md" "content here"
```

### Write from a file
```bash
./skills/active/obsidian-sync/sync.sh put-file "path/to/note.md" "/local/file.md"
```

### List a folder
```bash
./skills/active/obsidian-sync/sync.sh list "folder-name/"
```

## Environment Variables
- `OBSIDIAN_HOST` — Vault REST API URL (e.g. http://100.110.124.29:27123)
- `OBSIDIAN_API_KEY` — Bearer token for authentication

## Vault Structure
- `05-Agent-Outputs/` — Where agent-generated content goes
- `04-Agent-Knowledge/` — Read-only context for agents (SOUL.md, ArryBarry-Context.md)
- `03-Resources/` — Reference material

## When to Use
- After completing a research task → write findings to `05-Agent-Outputs/Research/`
- After generating content → write draft to `05-Agent-Outputs/Content-Drafts/`
- When needing business context → read from `04-Agent-Knowledge/`
