---
name: session:resume
description: Resume any session from the index on this machine — pulls the JSONL over ssh if it lives on another machine, then claude --resume.
argument-hint: "[session-id-or-prefix]"
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
/session:resume [session-id-or-prefix]

Omit the argument to pick from the list.

## Steps

### 1. Sync and resolve
```bash
session-hub-sync
THIS=$(session-config machine)
HOME_DIR=$(session-config home)
```
If no argument was given, run `sessions` and ask the user which id to resume
(full id or unique prefix). Expand a prefix to a full id with:
```bash
SID=$(session-index-view | python3 -c "import json,sys; \
  rows=json.load(sys.stdin); p='<prefix>'; \
  m=[r['id'] for r in rows if r['id'].startswith(p)]; \
  print(m[0] if len(m)==1 else '')")
```
If `$SID` is empty, the prefix was ambiguous or unknown — show `sessions` and stop.

### 2. Look up the session
```bash
INFO=$(session-registry-get "$SID")
[ "$INFO" = "{}" ] && { echo "Unknown session id."; exit 1; }
OWNER=$(echo "$INFO" | python3 -c "import json,sys;print(json.load(sys.stdin)['machine'])")
PROJECT_RELATIVE=$(echo "$INFO" | python3 -c "import json,sys;print(json.load(sys.stdin)['project_relative'])")
REMOTE_CWD=$(echo "$INFO" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))")
# Build this machine's project path. If we own the session, its cwd IS local — use it directly.
if [ "$OWNER" = "$THIS" ] && [ -n "$REMOTE_CWD" ]; then
  PROJECT_PATH="$REMOTE_CWD"
elif [ -z "$PROJECT_RELATIVE" ]; then
  PROJECT_PATH="$HOME_DIR"
else
  PROJECT_PATH="$HOME_DIR/$PROJECT_RELATIVE"
fi
LOCAL_ENCODED=$(session-encode-path "$PROJECT_PATH")
LOCAL_JSONL="$HOME/.claude/projects/$LOCAL_ENCODED/$SID.jsonl"
```

### 3. Ensure the JSONL is local
If `$LOCAL_JSONL` already exists, skip to step 4. Otherwise pull it from the owner:
```bash
PEER=$(session-config "peer_$OWNER")
# Remote path: encode the owner's absolute cwd; fall back to project_relative if cwd is blank (legacy).
if [ -n "$REMOTE_CWD" ]; then
  REMOTE_ENCODED=$(session-encode-path "$REMOTE_CWD")
else
  REMOTE_ENCODED=$(ssh "$PEER" "ls -d .claude/projects/*$PROJECT_RELATIVE* 2>/dev/null | head -1 | xargs basename")
fi
mkdir -p "$HOME/.claude/projects/$LOCAL_ENCODED"
rsync -az "$PEER:.claude/projects/$REMOTE_ENCODED/$SID.jsonl" "$LOCAL_JSONL"
```
If rsync fails: "Could not reach $OWNER ($PEER). It must be up and on the network to resume a session that lives there." Then stop.

### 4. Pull the project repo
```bash
git -C "$PROJECT_PATH" pull --ff-only 2>&1 | tail -1 || echo "git pull skipped/failed — project may be stale."
```

### 5. Show the latest checkpoint, if any
Checkpoints now live in the ai-brain vault (semantic) — point the user at them
rather than auto-loading: tell them they can run `/ai-brain:restore` for the
matching project if they want the work summary. Do not block resume on this.

### 6. Launch
```bash
cd "$PROJECT_PATH"
claude --resume "$SID"
```
The next scheduled index scan on this machine will record the session locally;
no manual registry update is needed.
