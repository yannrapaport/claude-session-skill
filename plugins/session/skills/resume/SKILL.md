---
name: resume
description: Resume any session from the index — migrates it here if it lives on the other machine, then opens it (attach, or revive then attach).
argument-hint: "[row-number-or-id]"
allowed-tools:
  - Bash
  - Read
---

# session:resume

Resume a session from the global index: resolve the row, migrate the session
here (`session-migrate` handles the copy, the replica fallback when the other
machine sleeps, and the hub record), then open it.

## Prerequisites
- `~/.claude/session-migrate.yml` has `machine`, `home`, and `peer_<other-machine>`
  configured.
- `bin/` helpers are on `$PATH`.

## Usage
/session:resume [row-number-or-id]

The argument is normally a row number from the last `sessions` listing — `3`
resumes the third row. A full session id or a unique id prefix also works.
Omit it to pick from the list.

## Steps

### 1. Sync and resolve
```bash
session-hub-sync
THIS=$(session-config machine)
HOME_DIR=$(session-config home)
```
If no argument was given, run `sessions` and ask the user which row to resume.

Turn whatever the user gave into a full session id:
```bash
SID=$(session-resolve "<argument>") || { sessions; exit 1; }
```
`session-resolve` refuses an out-of-range row, an unknown prefix, or an
ambiguous one, and says which — show `sessions` again and stop rather than
guessing. A row number needs a prior listing in this hub; if it reports there
is none, run `sessions` first and ask the user to re-pick.

### 2. Show the latest checkpoint, if any
Checkpoints now live in the ai-brain vault (semantic) — point the user at them
rather than auto-loading: tell them they can run `/ai-brain:restore` for the
matching project if they want the work summary. Do not block resume on this.

### 3. Migrate it here
```bash
session-migrate "$SID"    # no-op (exit 0) for a session already on this machine
```
From the Bash tool there is no terminal, so `session-migrate` cannot ask its
own questions. When it needs a confirmation it stops (exit 1) and prints
« confirmation requise … » with the question — e.g. the other machine is
asleep and the copy would come from the replica (its age is shown), or the
session is running over there and would be stopped. Then:
1. Relay the question to the user in chat, with the details it printed
   (replica date and last known activity, or that the source will be stopped).
2. Only once they agree, re-run with `--yes`:
   ```bash
   session-migrate "$SID" --yes
   ```
   If they decline, stop there — nothing was copied or stopped.
Any other failure message (hub busy, directory missing here…): show it as is
and stop.

### 4. Open it
A skill cannot switch the running session. `session-open "$SID"` (attach, or
revive in its own cwd, then attach) replaces the terminal it runs in, so do
not run it from the Bash tool; once migrated, tell the user to open it from the
agent view (`cc <subject>`, or `claude agents`) or by running `session-open <id>`
in a terminal.
