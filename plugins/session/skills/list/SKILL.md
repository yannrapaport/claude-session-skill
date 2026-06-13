---
name: session:list
description: List all sessions in the hub registry and their current machine location.
allowed-tools:
  - Bash
---

# session:list

List all sessions in the hub registry and their current machine location.

## Steps

### 1. Sync hub
```bash
session-hub-sync
```

### 2. Read and display registry
```bash
python3 - "$(session-config machine)" "$HOME/.claude/session-hub/registry.json" << 'PYEOF'
import json, sys, os
this_machine, registry_path = sys.argv[1], sys.argv[2]
if not os.path.exists(registry_path):
    print("Registry is empty — no sessions have been migrated yet.")
    sys.exit(0)
data = json.load(open(registry_path))
sessions = data.get("sessions", {})
if not sessions:
    print("No sessions in registry.")
    sys.exit(0)
print(f"{'Session ID':<40} {'Project':<30} {'Machine':<12} {'Date'}")
print("-" * 95)
for sid, s in sorted(sessions.items(), key=lambda x: x[1].get("migrated_at",""), reverse=True):
    marker = " ◀ here" if s.get("current_machine") == this_machine else ""
    print(f"{sid:<40} {s.get('project_relative','?'):<30} {s.get('current_machine','?'):<12} {s.get('migrated_at','?')[:10]}{marker}")
PYEOF
```
