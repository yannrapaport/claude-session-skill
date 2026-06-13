---
name: session:migrate
description: Migrate the current Claude Code session to another machine via the session hub — pushes JSONL + updates registry.
argument-hint: "<target-machine>"
allowed-tools:
  - Bash
  - Read
---

# session:migrate

Migrate the current Claude Code session to another machine via the session hub.

## Prerequisites
- `~/.claude/session-migrate.yml` exists with `hub`, `machine`, and `home` configured.
- Helper scripts in `~/.claude/skills/session/bin/` are in `$PATH`, or call them with full path.
- The working directory is the project you want to migrate.

## Usage
/session:migrate <target-machine>

`<target-machine>` must match the `machine` value configured on the target (e.g. "nexus", "mac").

## Steps

Run each command in sequence. Stop and report any error — do not continue past a failure.

### 1. Read config
```bash
THIS_MACHINE=$(session-config machine)
HOME_DIR=$(session-config home)
```

### 2. Detect current session ID
```bash
SESSION_ID=$(session-detect-id)
```
If this fails: "No active session found for the current directory. Make sure you are running inside your project directory."

### 3. Validate target argument
The user must provide a target machine name as the argument to this skill (e.g. `/session:migrate nexus`). If no argument was provided, ask: "Which machine do you want to migrate to?"

### 4. Check git status
```bash
git status --porcelain
```
If output is non-empty: "Uncommitted changes detected — commit or stash them first, then retry."

### 5. Push project repo
```bash
git push
```
If no upstream is configured, warn and continue: "No remote configured for this repo. Make sure the project is accessible on the target machine."

### 6. Sync hub
```bash
session-hub-sync
```

### 7. Copy JSONL to hub
```bash
ENCODED=$(session-encode-path "$(pwd)")
cp "$HOME/.claude/projects/$ENCODED/$SESSION_ID.jsonl" \
   "$HOME/.claude/session-hub/sessions/$SESSION_ID.jsonl"
```

### 8. Update registry
```bash
PROJECT_RELATIVE=$(pwd | sed "s|$HOME_DIR/||")
session-registry-set "$SESSION_ID" "<target-machine>" "$PROJECT_RELATIVE"
```
Replace `<target-machine>` with the argument the user provided.

### 9. Clean up old sessions
```bash
session-cleanup
```

### 10. Commit and push hub
```bash
session-hub-push "migrate: $SESSION_ID → <target-machine>"
```

### 11. Print resume instructions

Display:
```
✓ Session migrated to <target-machine>
  Session ID: <SESSION_ID>
  Project:    <PROJECT_RELATIVE>

Resume with:
  cd <project-path-on-target> && /session:resume <SESSION_ID>
```

Where `<project-path-on-target>` is the target machine's home directory + project_relative (inform the user they need to know their home path on the target, or configure it in `session-migrate.yml`).
