---
name: resume
description: Resume any session from the index — migrates it here if it lives on the other machine, then opens it (attach, or revive then attach).
argument-hint: "[row-number-or-id]"
allowed-tools:
  - Bash
  - Read
---

# session:resume

Resume a session from the global index. If the transcript already lives on this
machine, resume directly. If it lives on another machine, pull it over ssh first.

## Prerequisites
- `~/.claude/session-migrate.yml` has `machine`, `home`, and `peer_<other-machine>`
  ssh targets configured.
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

### 3. Open it
A skill cannot switch the running session. Hand it to the session manager:
```bash
session-migrate "$SID"    # only if OWNER != THIS; asks before stopping a running source
session-open "$SID"       # attach (or revive in its own cwd, then attach)
```
`session-open` replaces this terminal, so from Claude Code run it through the
session layout instead: tell the user to pick the session in `sessions`
(or `cc tmux <subject>`), where the main pane opens it in place.
