---
name: session:resume
description: Resume a migrated Claude Code session on this machine — hub pull, JSONL install, git pull, checkpoint display, then claude --resume.
argument-hint: "[session-id]"
allowed-tools:
  - Bash
  - Read
---

# session:resume

Resume a migrated Claude Code session on this machine. Handles hub pull, JSONL install, git pull, checkpoint display, and launching `claude --resume`.

## Prerequisites
- `~/.claude/session-migrate.yml` configured on this machine.
- Helper scripts in `~/.claude/skills/session/bin/` are in `$PATH`.

## Usage
/session:resume [session-id]

If `session-id` is omitted, the skill lists available sessions and asks the user to choose.

## Steps

### 1. Read config
```bash
THIS_MACHINE=$(session-config machine)
HOME_DIR=$(session-config home)
```

### 2. Sync hub
```bash
session-hub-sync
```

### 3. Resolve session ID
If the user provided a session-id as argument, use it directly.

If not, list sessions available on this machine:
```bash
python3 - "$THIS_MACHINE" "$HOME/.claude/session-hub/registry.json" << 'PYEOF'
import json, sys, os
machine, registry_path = sys.argv[1], sys.argv[2]
if not os.path.exists(registry_path):
    print("No sessions found in hub registry.")
    sys.exit(0)
data = json.load(open(registry_path))
sessions = [(sid, s) for sid, s in data.get("sessions", {}).items()
            if s.get("current_machine") == machine]
if not sessions:
    print(f"No sessions registered for machine '{machine}'.")
    sys.exit(0)
for sid, s in sessions:
    print(f"  {sid[:8]}...  {s['project_relative']}  (migrated {s['migrated_at'][:10]})")
PYEOF
```
Ask the user which session to resume (they can provide the full ID or the first 8 characters).

### 4. Get session info from registry
```bash
INFO=$(session-registry-get "<session-id>")
PROJECT_RELATIVE=$(echo "$INFO" | python3 -c "import json,sys; print(json.load(sys.stdin)['project_relative'])")
PROJECT_PATH="$HOME_DIR/$PROJECT_RELATIVE"
```

### 5. Pull project repo
```bash
git -C "$PROJECT_PATH" pull
```
If this fails, warn and continue: "git pull failed — the project may be out of date."

### 6. Install JSONL locally
```bash
ENCODED=$(session-encode-path "$PROJECT_PATH")
mkdir -p "$HOME/.claude/projects/$ENCODED"
cp "$HOME/.claude/session-hub/sessions/<session-id>.jsonl" \
   "$HOME/.claude/projects/$ENCODED/<session-id>.jsonl"
```

### 7. Check for checkpoint
```bash
CHECKPOINT=$(ls "$PROJECT_PATH/scratchpad/checkpoints/<session-id>"-*.md 2>/dev/null | sort | tail -1)
```
If a checkpoint exists, display its full contents so the user has context before the session resumes. Say: "Found checkpoint — displaying before resuming:"

### 8. Update registry to reflect this machine
```bash
session-registry-set "<session-id>" "$THIS_MACHINE" "$PROJECT_RELATIVE"
session-hub-push "resume: <session-id> on $THIS_MACHINE"
```

### 9. Launch session
```bash
cd "$PROJECT_PATH"
claude --resume <session-id>
```
