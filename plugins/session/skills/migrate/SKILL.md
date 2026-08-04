---
name: migrate
description: DEPRECATED — migration is automatic. The index discovers sessions on every machine; use /session:resume to pull one on demand.
argument-hint: ""
allowed-tools:
  - Bash
---

# session:migrate (deprecated)

Manual migration is no longer needed. Each machine's scanner publishes its
sessions to the shared index, and **`/session:resume <id>`** pulls a remote
transcript over ssh on demand.

To force-publish this machine's index immediately (optional):
```bash
session-index-scan
```
Then resume anywhere with `/session:resume <id-prefix>`.
