---
name: list
description: List all sessions across every machine (the global cross-machine view), newest first.
allowed-tools:
  - Bash
---

# session:list

Show every Claude Code session known to the hub index — both machines, unified —
newest first. This is the tool to run after a reboot to see what to resume.

## Steps

### 1. Show the table
```bash
sessions
```

### 2. Optional filters
- By project (matches the cwd-scope slug): `sessions --project <slug>`
- Active only (hide archived): `sessions --active`
- One machine: `sessions --machine <name>`

The index is auto-populated by a scheduled job on each machine; no manual
migration is needed. To force a refresh of this machine's entries first:
```bash
session-index-scan
```
