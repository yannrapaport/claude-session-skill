---
name: session:save
description: Save a checkpoint of the current work session into the project repo — travels with the code via git, available after git pull on any machine. Replaces /ai-brain:save for non-ai-brain projects.
allowed-tools:
  - Bash
  - Read
---

# session:save

Save a checkpoint of the current work session into the project repo.
The checkpoint travels with the code via git, making it available after `git pull` on any machine.

Replaces `/ai-brain:save` for non-ai-brain projects.

## Steps

### 1. Detect session ID
```bash
SESSION_ID=$(session-detect-id)
```

### 2. Get today's date
```bash
DATE=$(date +%Y-%m-%d)
```

### 3. Collect context
Gather the following from the conversation and the codebase:
- **Accomplished this session**: 2-5 bullet points summarizing what was done.
- **Active todos**: read `TODO.md` or `todos/active-todos.md` if present, list incomplete items relevant to this project.
- **Recent commits**: `git log --oneline -5`
- **Next steps / blockers**: what to do when resuming, and any known blockers.

### 4. Ensure checkpoint directory exists
```bash
mkdir -p scratchpad/checkpoints
```

### 5. Write checkpoint file

Write to `scratchpad/checkpoints/$SESSION_ID-$DATE.md` with this structure:
```markdown
# Session Checkpoint — <DATE>

## Accomplished
- ...

## Recent commits
<git log --oneline -5 output>

## Active todos
- ...

## Next steps
- ...

## Blockers
- ...
```

### 6. Commit and push
```bash
git add "scratchpad/checkpoints/$SESSION_ID-$DATE.md"
git commit -m "checkpoint: session $SESSION_ID $DATE"
git push
```
If no upstream: commit only, warn that push is skipped.

### 7. Confirm
"Checkpoint saved: scratchpad/checkpoints/$SESSION_ID-$DATE.md"
