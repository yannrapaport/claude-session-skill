---
name: list
description: List all sessions across every machine (the global cross-machine view), newest first.
allowed-tools:
  - Bash
---

# session:list

Show every Claude Code session known to the hub index — both machines, unified —
newest first. This is the tool to run after a reboot to see what to resume.

Only interactive sessions are indexed. Headless transcripts (cron jobs, SDK
subagents, scripted one-shots) are filtered out at scan time; on a machine that
runs scheduled agents they outnumber real work by an order of magnitude.

## Steps

### 1. Show the table
```bash
sessions
```

Rows are numbered. The number is the handle: `/session:resume 3` resumes the
third row. Numbering describes the most recent listing only — running
`sessions` again renumbers, so read and resume in the same breath.

Columns: relative age, machine (`*` this one, `+` also elsewhere), project,
title (the session's own title when it has one, else its opening message),
volume (turns and transcript size), git branch. A `·` before the title marks an
archived session.

### 2. Optional filters
- By project (matches the cwd-scope slug): `sessions --project <slug>`
- Active only (hide archived): `sessions --active`
- One machine: `sessions --machine <name>`

The index is auto-populated by a scheduled job on each machine; no manual
migration is needed. To force a refresh of this machine's entries first:
```bash
session-index-scan
```

### 3. If the list looks cluttered
Headless transcripts are already excluded from the index, but they still sit on
disk. To reclaim that space on this machine:
```bash
session-purge-headless          # dry run — reports what it would delete
session-purge-headless --yes    # actually delete, then rescan
```
Run it on each machine separately; it only ever touches local files.
