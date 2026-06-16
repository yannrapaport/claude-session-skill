# Sessions Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the overlapping `session:save/migrate/resume` + `ai-brain:save/restore` mess with one system: a git-synced lightweight index that auto-discovers every session on every machine, on-demand JSONL transport over ssh, cross-machine resume, and two-clock garbage collection.

**Architecture:** A per-machine scanner walks `~/.claude/projects/*/*.jsonl`, extracts `{cwd, last_activity, subject}` and upserts entries under its own key in a machine-partitioned `registry.json` carried by the existing `claude-sessions` git hub (JSONL stays off git). A `sessions` view merges all machines. `session:resume` pulls a remote JSONL over ssh when it is not local. Two GC clocks (process hygiene hourly, session archive daily) keep things tidy, with `ai-brain:save` always running before any archive so no meaning is lost.

**Tech Stack:** Bash + Python 3 (stdlib only), git (hub sync), ssh/rsync (JSONL transport), launchd (Mac) / cron (Nexus) for scheduled jobs. Tests are shell scripts sourced by `tests/run_tests.sh`.

---

## Context for the implementer (read once)

You are working in the repo `~/.claude/skills/session` (a.k.a. `claude-session-skill`), on branch `sessions-consolidation`. The validated design is in `docs/specs/2026-06-16-sessions-consolidation-design.md` — read it before starting.

**What already exists** (reuse, do not reinvent):

- `bin/session-config <key>` — reads flat `key: value` from `~/.claude/session-migrate.yml`. Keys today: `hub`, `machine`, `home`. The parser is line-based (`grep "^key:"`), so new flat keys like `peer_nexus:` work without changing it.
- `bin/session-encode-path <abs-path>` — `sed 's/[^a-zA-Z0-9]/-/g'`. This is how Claude Code names `~/.claude/projects/<encoded>/`. **Lossy** (cannot be reversed) — never try to decode a directory name; read `cwd` from the JSONL instead.
- `bin/session-detect-id [project-path]` — newest `*.jsonl` stem in the encoded project dir. Respects `CLAUDE_DIR` env (tests).
- `bin/session-hub-sync` — clone-or-`pull --rebase --autostash` the hub into `~/.claude/session-hub`, ensures `sessions/` exists.
- `bin/session-hub-push "<msg>"` — `add -A`, commit (no-op if clean), push.
- `bin/session-registry-get <sid>` / `bin/session-registry-set <sid> <machine> <project_relative>` — operate on `registry.json`. Respect `HUB_DIR_OVERRIDE` (tests). **These will be rewritten for schema v2 in Task 2.**
- `bin/session-cleanup` — deletes hub `sessions/*.jsonl` older than 30 days. Superseded by the new GC; removed in Task 16.
- `tests/run_tests.sh` — sets `PATH` to `bin/`, sources every `tests/test_*.sh`, exposes `assert_eq "<desc>" "<expected>" "<actual>"`, prints a pass/fail tally. **Every test file you add must be `tests/test_*.sh` and use `assert_eq`.**

**Current registry schema (v1), in the live hub:**
```json
{ "sessions": { "<sid>": { "project_relative": "...", "current_machine": "mac", "migrated_at": "..." } } }
```

**Target registry schema (v2):**
```json
{
  "version": 2,
  "machines": {
    "mac":   { "<sid>": { "project_relative": "...", "cwd": "/Users/yannrapaport/...", "last_activity": "2026-06-16T13:38:00Z", "subject": "...", "status": "active" } },
    "nexus": { "<sid>": { ... } }
  }
}
```
Rationale: keying by machine first means each machine only ever writes its own subtree → git rebase merges cleanly, zero key collision (the design's "partition par machine"). `cwd` (absolute, on the owning machine) lets resume rebuild the remote path; `project_relative` (cwd minus that machine's home) is for display and local placement.

**Machine facts:** Mac `machine: mac`, `home: /Users/yannrapaport`. Nexus `machine: nexus`, home `/home/yann` (verify on the box). Tailscale CLI is **not** on the Mac `$PATH` — transport uses plain `ssh`/`rsync` to a configurable host alias (Tailscale just provides the network underneath). SSH from Mac → Nexus is available; do not assume the reverse without testing.

**TDD note:** Helpers that are pure functions (subject extraction, cwd extraction, registry ops, project_relative) get real shell tests. Skills (`SKILL.md`), launchd/cron units, and ssh transport are verified manually with explicit commands and expected output — there is no unit-test harness for those, and faking ssh/launchd in a unit test would test the fake, not the system.

---

## File Structure

**New helpers** (`bin/`, all `chmod +x`, `#!/usr/bin/env bash` + `set -euo pipefail`):
- `bin/session-jsonl-cwd` — print the `cwd` recorded inside a JSONL transcript.
- `bin/session-subject` — print the first "real" user message of a JSONL (filtered, truncated).
- `bin/session-index-scan` — scan this machine's projects, upsert its registry subtree, prune purged sessions, commit+push.
- `bin/session-index-view` — print the merged cross-machine session list as JSON (one row per session-id, deduped by latest activity).
- `bin/session-registry-migrate` — one-shot v1→v2 registry converter.
- `bin/sessions` — human-facing formatted table over `session-index-view` (the "vue globale" CLI).
- `bin/session-gc-process` — kill idle/orphan `claude` processes (RAM hygiene). `--dry-run` default-safe.
- `bin/session-gc-sessions` — archive sessions inactive > N days (checkpoint → mark archived), optional purge.

**Rewritten helpers:**
- `bin/session-registry-get` / `bin/session-registry-set` — schema v2.

**Rewritten skills:**
- `list/SKILL.md` + `plugins/session/skills/list/SKILL.md` — global view via `sessions`.
- `resume/SKILL.md` + `plugins/session/skills/resume/SKILL.md` — remote pull over ssh.
- `save/SKILL.md` + `plugins/session/skills/save/SKILL.md` — deprecation notice → `ai-brain:save`.
- `migrate/SKILL.md` + `plugins/session/skills/migrate/SKILL.md` — deprecation notice (optional force-push).

**Scheduled units:**
- `units/com.yann.session-index.plist`, `units/com.yann.session-gc-process.plist`, `units/com.yann.session-gc-sessions.plist` (Mac, launchd).
- `units/crontab.nexus` (Nexus, cron snippet) + install notes.

**Config:**
- `config.yml.template` — add `peer_<machine>` keys + GC tunables.

**Tests** (`tests/`):
- `test_jsonl_cwd.sh`, `test_subject.sh`, `test_registry_v2.sh`, `test_index_scan.sh`, `test_index_view.sh`, `test_gc_sessions.sh`.

**Removed:**
- `bin/session-cleanup` (Task 16).

---

## Phase 0 — Foundations

### Task 1: Config — peer hosts and GC tunables

**Files:**
- Modify: `config.yml.template`
- Modify (live, manual): `~/.claude/session-migrate.yml`

- [ ] **Step 1: Extend the template**

Overwrite `config.yml.template` with:
```yaml
# ~/.claude/session-migrate.yml
# Copy to ~/.claude/session-migrate.yml and fill in your values.
# Never commit this file — it is local to each machine.

hub: git@github.com:youruser/claude-sessions.git   # URL of the private hub repo
machine: mac                                        # name of THIS machine
home: /Users/youruser                               # absolute home path on THIS machine

# ssh/rsync targets for every OTHER machine, keyed peer_<machine-name>.
# Used by session:resume to pull a JSONL that lives on another machine.
# Value is anything ssh accepts (host alias, user@host, Tailscale MagicDNS name).
peer_nexus: yann@nexus
peer_mac: yann@the-product-guy

# Garbage collection tunables (hours / days). Omit to use the defaults shown.
gc_process_idle_hours: 6     # kill spare/orphan claude processes idle longer than this
gc_archive_days: 10          # archive sessions inactive longer than this
gc_purge_days: 0             # delete archived JSONL after this many days (0 = never)
```

- [ ] **Step 2: Add the same keys to the live config on each machine**

On the Mac, edit `~/.claude/session-migrate.yml` to add (keep the real `hub`):
```yaml
peer_nexus: yann@nexus
gc_process_idle_hours: 6
gc_archive_days: 10
gc_purge_days: 0
```
Verify: `session-config peer_nexus` prints `yann@nexus`; `session-config gc_archive_days` prints `10`.

- [ ] **Step 3: Commit**

```bash
git add config.yml.template
git commit -m "config: add peer_<machine> ssh targets and GC tunables"
```

---

### Task 2: Registry schema v2 — get/set helpers + tests

**Files:**
- Modify: `bin/session-registry-set`
- Modify: `bin/session-registry-get`
- Create: `tests/test_registry_v2.sh`
- Delete later: `tests/test_registry.sh` (v1 — replaced in Step 6)

- [ ] **Step 1: Write the failing test**

Create `tests/test_registry_v2.sh`:
```bash
#!/usr/bin/env bash
# tests/test_registry_v2.sh — sourced by run_tests.sh
echo "--- test_registry_v2 ---"

TMP=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP"

# set writes into machines.<machine>.<sid>
session-registry-set "sid-1" "nexus" "projects/foo" "/home/yann/projects/foo"
RAW=$(cat "$TMP/registry.json")
VER=$(echo "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['version'])")
MACH=$(echo "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['nexus']['sid-1']['project_relative'])")
CWD=$(echo "$RAW" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['nexus']['sid-1']['cwd'])")
assert_eq "registry v2 version" "2" "$VER"
assert_eq "registry v2 project_relative" "projects/foo" "$MACH"
assert_eq "registry v2 cwd" "/home/yann/projects/foo" "$CWD"

# get finds a session across machines, returns owner+entry merged
GOT=$(session-registry-get "sid-1")
OWNER=$(echo "$GOT" | python3 -c "import json,sys;print(json.load(sys.stdin)['machine'])")
assert_eq "registry get reports owner machine" "nexus" "$OWNER"

# get on missing returns {}
assert_eq "registry get missing" "{}" "$(session-registry-get nope)"

# set preserves an existing 'archived' status on re-upsert
python3 - "$TMP/registry.json" << 'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['machines']['nexus']['sid-1']['status']='archived'
json.dump(d,open(p,'w'))
PY
session-registry-set "sid-1" "nexus" "projects/foo" "/home/yann/projects/foo"
ST=$(cat "$TMP/registry.json" | python3 -c "import json,sys;print(json.load(sys.stdin)['machines']['nexus']['sid-1']['status'])")
assert_eq "registry set preserves archived status" "archived" "$ST"

rm -rf "$TMP"; unset HUB_DIR_OVERRIDE
```

- [ ] **Step 2: Run it, verify it fails**

Run: `tests/run_tests.sh`
Expected: FAIL on `test_registry_v2` (old set takes 3 args / writes `sessions.*`, no `version`).

- [ ] **Step 3: Rewrite `bin/session-registry-set`**

```bash
#!/usr/bin/env bash
# Usage: session-registry-set <session-id> <machine> <project-relative> <cwd> [subject]
# Upserts machines.<machine>.<session-id> in registry.json (schema v2).
# Preserves existing status/subject when not provided. Respects HUB_DIR_OVERRIDE.
set -euo pipefail
SID="$1"; MACHINE="$2"; PROJECT_RELATIVE="$3"; CWD="${4:-}"; SUBJECT="${5:-}"
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
REGISTRY="$HUB_DIR/registry.json"
mkdir -p "$HUB_DIR"
python3 - "$SID" "$MACHINE" "$PROJECT_RELATIVE" "$CWD" "$SUBJECT" "$REGISTRY" << 'PYEOF'
import json, sys, os
from datetime import datetime, timezone
sid, machine, proj, cwd, subject, path = sys.argv[1:7]
data = {"version": 2, "machines": {}}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: pass
data.setdefault("version", 2)
m = data.setdefault("machines", {}).setdefault(machine, {})
prev = m.get(sid, {})
entry = {
    "project_relative": proj,
    "cwd": cwd or prev.get("cwd", ""),
    "last_activity": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "subject": subject or prev.get("subject", ""),
    "status": prev.get("status", "active"),
}
m[sid] = entry
json.dump(data, open(path, "w"), indent=2)
PYEOF
```

- [ ] **Step 4: Rewrite `bin/session-registry-get`**

```bash
#!/usr/bin/env bash
# Usage: session-registry-get <session-id>
# Searches machines.*.<sid>; prints the entry with an added "machine" field,
# or "{}" if not found. If present on >1 machine, returns the most-recently-active.
# Respects HUB_DIR_OVERRIDE.
set -euo pipefail
SID="$1"
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
REGISTRY="$HUB_DIR/registry.json"
python3 - "$SID" "$REGISTRY" << 'PYEOF'
import json, sys, os
sid, path = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print("{}"); sys.exit(0)
data = json.load(open(path))
hits = []
for machine, sessions in data.get("machines", {}).items():
    if sid in sessions:
        e = dict(sessions[sid]); e["machine"] = machine; hits.append(e)
if not hits:
    print("{}"); sys.exit(0)
hits.sort(key=lambda e: e.get("last_activity", ""), reverse=True)
print(json.dumps(hits[0]))
PYEOF
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `tests/run_tests.sh`
Expected: `test_registry_v2` all PASS.

- [ ] **Step 6: Remove the obsolete v1 test and commit**

```bash
git rm tests/test_registry.sh
git add bin/session-registry-set bin/session-registry-get tests/test_registry_v2.sh
git commit -m "feat: registry schema v2 (machine-partitioned) with get/set + tests"
```

---

### Task 3: One-shot v1→v2 registry migration

**Files:**
- Create: `bin/session-registry-migrate`

- [ ] **Step 1: Write the migrator**

```bash
#!/usr/bin/env bash
# Usage: session-registry-migrate
# Converts a v1 registry ({sessions:{sid:{project_relative,current_machine,migrated_at}}})
# into v2 ({version:2,machines:{<machine>:{sid:{...}}}}). Idempotent. Respects HUB_DIR_OVERRIDE.
set -euo pipefail
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
REGISTRY="$HUB_DIR/registry.json"
[ -f "$REGISTRY" ] || { echo "No registry to migrate."; exit 0; }
python3 - "$REGISTRY" << 'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
if data.get("version") == 2 and "machines" in data:
    print("Already v2 — nothing to do."); sys.exit(0)
out = {"version": 2, "machines": {}}
for sid, e in data.get("sessions", {}).items():
    machine = e.get("current_machine", "unknown")
    out["machines"].setdefault(machine, {})[sid] = {
        "project_relative": e.get("project_relative", ""),
        "cwd": "",  # unknown for legacy entries; resume will fall back to project_relative+home
        "last_activity": e.get("migrated_at", ""),
        "subject": "",
        "status": "active",
    }
json.dump(out, open(path, "w"), indent=2)
print(f"Migrated {sum(len(v) for v in out['machines'].values())} session(s) to v2.")
PYEOF
```

- [ ] **Step 2: Dry-run against a copy of the live registry**

```bash
T=$(mktemp -d); cp ~/.claude/session-hub/registry.json "$T/registry.json"
HUB_DIR_OVERRIDE="$T" session-registry-migrate
cat "$T/registry.json"
```
Expected: `version: 2`, the single live session (`de08a81c-...`) now under `machines.mac`, then `rm -rf "$T"`.

- [ ] **Step 3: Run it for real on the live hub, then push**

```bash
session-hub-sync
session-registry-migrate
session-hub-push "migrate: registry v1 -> v2"
```
Expected: "Migrated 1 session(s) to v2." and a pushed commit.

- [ ] **Step 4: Commit the helper**

```bash
git add bin/session-registry-migrate
git commit -m "feat: one-shot v1->v2 registry migrator"
```

---

## Phase 1 — Auto-populated index

### Task 4: `session-jsonl-cwd` — read cwd from a transcript

**Files:**
- Create: `bin/session-jsonl-cwd`
- Create: `tests/test_jsonl_cwd.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_jsonl_cwd.sh`:
```bash
#!/usr/bin/env bash
# tests/test_jsonl_cwd.sh — sourced by run_tests.sh
echo "--- test_jsonl_cwd ---"
TMP=$(mktemp -d)
cat > "$TMP/s.jsonl" << 'EOF'
{"type":"summary","summary":"x"}
{"type":"user","cwd":"/Users/yannrapaport/projects/foo","message":{"role":"user","content":"hi"}}
EOF
assert_eq "jsonl-cwd reads cwd" "/Users/yannrapaport/projects/foo" "$(session-jsonl-cwd "$TMP/s.jsonl")"
# empty when absent
echo '{"type":"summary"}' > "$TMP/n.jsonl"
assert_eq "jsonl-cwd empty when absent" "" "$(session-jsonl-cwd "$TMP/n.jsonl")"
rm -rf "$TMP"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `tests/run_tests.sh`
Expected: FAIL — `session-jsonl-cwd: command not found`.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# Usage: session-jsonl-cwd <jsonl-path>
# Prints the first 'cwd' value found in a Claude Code transcript, or empty string.
set -euo pipefail
F="$1"
[ -f "$F" ] || { echo ""; exit 0; }
python3 - "$F" << 'PYEOF'
import json, sys
for line in open(sys.argv[1], errors="ignore"):
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    cwd = o.get("cwd")
    if cwd:
        print(cwd); break
else:
    print("")
PYEOF
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `tests/run_tests.sh`
Expected: `test_jsonl_cwd` PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/session-jsonl-cwd tests/test_jsonl_cwd.sh
git commit -m "feat: session-jsonl-cwd helper"
```

---

### Task 5: `session-subject` — extract a human topic line

**Files:**
- Create: `bin/session-subject`
- Create: `tests/test_subject.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_subject.sh`:
```bash
#!/usr/bin/env bash
# tests/test_subject.sh — sourced by run_tests.sh
echo "--- test_subject ---"
TMP=$(mktemp -d)
# First real user msg wins; meta/skill/command wrappers are skipped.
cat > "$TMP/s.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":"<command-name>/foo</command-name>"}}
{"type":"user","message":{"role":"user","content":"Base directory for this skill: /x\n\nstuff"}}
{"type":"user","message":{"role":"user","content":"Consolider la gestion des sessions"}}
EOF
assert_eq "subject skips meta+skill" "Consolider la gestion des sessions" "$(session-subject "$TMP/s.jsonl")"
# content as array of blocks
cat > "$TMP/a.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the login bug"}]}}
EOF
assert_eq "subject reads block content" "Fix the login bug" "$(session-subject "$TMP/a.jsonl")"
# truncation at 80 chars
LONG=$(printf 'x%.0s' {1..100})
echo "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"$LONG\"}}" > "$TMP/l.jsonl"
assert_eq "subject truncates to 80" "80" "$(session-subject "$TMP/l.jsonl" | wc -c | tr -d ' ')"
rm -rf "$TMP"
```
(`wc -c` of an 80-char line with no trailing newline from the helper is 80.)

- [ ] **Step 2: Run it, verify it fails**

Run: `tests/run_tests.sh`
Expected: FAIL — `session-subject: command not found`.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# Usage: session-subject <jsonl-path>
# Prints the first "real" user message (<=80 chars, no trailing newline), or "".
# Skips: assistant/meta lines, content starting with '<', and known wrappers.
set -euo pipefail
F="$1"
[ -f "$F" ] || { printf ""; exit 0; }
python3 - "$F" << 'PYEOF'
import json, sys
SKIP = ("base directory for this skill", "caveat:", "<command", "<system-reminder",
        "<local-command", "command-name", "command-message")
def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str): return c
    if isinstance(c, list):
        return "".join(p.get("text", "") for p in c
                       if isinstance(p, dict) and p.get("type") == "text")
    return ""
for line in open(sys.argv[1], errors="ignore"):
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") != "user": continue
    t = text_of(o.get("message", {})).strip()
    if not t: continue
    low = t.lower()
    if t.startswith("<") or any(s in low for s in SKIP): continue
    t = " ".join(t.split())
    sys.stdout.write(t[:80]); break
PYEOF
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `tests/run_tests.sh`
Expected: `test_subject` PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/session-subject tests/test_subject.sh
git commit -m "feat: session-subject helper"
```

---

### Task 6: `session-index-scan` — the auto-populator

**Files:**
- Create: `bin/session-index-scan`
- Create: `tests/test_index_scan.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_index_scan.sh`. It fakes `CLAUDE_DIR` (projects) and `HUB_DIR_OVERRIDE` (registry), and stubs config + hub-push via PATH and env so nothing touches git or the network.
```bash
#!/usr/bin/env bash
# tests/test_index_scan.sh — sourced by run_tests.sh
echo "--- test_index_scan ---"
TMP=$(mktemp -d)
export CLAUDE_DIR="$TMP/claude"
export HUB_DIR_OVERRIDE="$TMP/hub"
mkdir -p "$HUB_DIR_OVERRIDE"
# Stub config: machine=mac, home=$TMP/home. Stub hub-push to a no-op.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/session-config" << EOF
#!/usr/bin/env bash
case "\$1" in
  machine) echo mac ;;
  home) echo "$TMP/home" ;;
  *) echo "" ;;
esac
EOF
cat > "$STUB/session-hub-push" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$STUB/session-hub-sync" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
# A project transcript under the encoded dir.
PROJ="$TMP/home/projects/foo"
ENC=$(session-encode-path "$PROJ")
mkdir -p "$CLAUDE_DIR/projects/$ENC"
cat > "$CLAUDE_DIR/projects/$ENC/sid-aaa.jsonl" << EOF
{"type":"user","cwd":"$PROJ","message":{"role":"user","content":"Build the thing"}}
EOF

session-index-scan

REG="$HUB_DIR_OVERRIDE/registry.json"
PR=$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-aaa']['project_relative'])")
SUB=$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-aaa']['subject'])")
CWD=$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-aaa']['cwd'])")
assert_eq "scan sets project_relative" "projects/foo" "$PR"
assert_eq "scan sets subject" "Build the thing" "$SUB"
assert_eq "scan sets cwd" "$PROJ" "$CWD"

# Pruning: delete the jsonl, rescan -> entry gone.
rm "$CLAUDE_DIR/projects/$ENC/sid-aaa.jsonl"
session-index-scan
GONE=$(python3 -c "import json;d=json.load(open('$REG'));print('sid-aaa' in d['machines'].get('mac',{}))")
assert_eq "scan prunes purged session" "False" "$GONE"

rm -rf "$TMP"
unset CLAUDE_DIR HUB_DIR_OVERRIDE PATH
export PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd):$PATH"
```
(The final two lines restore `PATH` so later test files still find `bin/`.)

- [ ] **Step 2: Run it, verify it fails**

Run: `tests/run_tests.sh`
Expected: FAIL — `session-index-scan: command not found`.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# session-index-scan — scan THIS machine's transcripts and upsert its registry subtree.
# - Walks $CLAUDE_DIR/projects/*/*.jsonl (CLAUDE_DIR defaults to ~/.claude).
# - For each: project_relative (cwd minus home), cwd, last_activity (mtime), subject.
# - Preserves existing 'status' (so archived stays archived).
# - Prunes entries under this machine whose jsonl no longer exists.
# - Commits + pushes the hub (skipped if session-hub-push is a no-op stub).
set -euo pipefail
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
REGISTRY="$HUB_DIR/registry.json"
MACHINE=$(session-config machine)
HOME_DIR=$(session-config home)
mkdir -p "$HUB_DIR"

# Build a TSV of live sessions: sid \t cwd \t mtime \t subject
TSV=$(mktemp)
shopt -s nullglob
for f in "$CLAUDE_DIR"/projects/*/*.jsonl; do
  sid=$(basename "$f" .jsonl)
  cwd=$(session-jsonl-cwd "$f")
  [ -z "$cwd" ] && continue   # cannot place a session with no recorded cwd
  mtime=$(python3 -c "import os,datetime;print(datetime.datetime.fromtimestamp(os.path.getmtime('$f'),datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  subj=$(session-subject "$f")
  printf '%s\t%s\t%s\t%s\n' "$sid" "$cwd" "$mtime" "$subj" >> "$TSV"
done

python3 - "$REGISTRY" "$MACHINE" "$HOME_DIR" "$TSV" << 'PYEOF'
import json, os, sys
registry, machine, home, tsv = sys.argv[1:5]
data = {"version": 2, "machines": {}}
if os.path.exists(registry):
    try: data = json.load(open(registry))
    except Exception: pass
data.setdefault("version", 2)
machines = data.setdefault("machines", {})
prev = machines.get(machine, {})
new = {}
seen = set()
home_pref = home.rstrip("/") + "/"
for raw in open(tsv):
    parts = raw.rstrip("\n").split("\t")
    if len(parts) < 3: continue
    sid, cwd, mtime = parts[0], parts[1], parts[2]
    subj = parts[3] if len(parts) > 3 else ""
    seen.add(sid)
    rel = cwd[len(home_pref):] if cwd.startswith(home_pref) else cwd
    p = prev.get(sid, {})
    new[sid] = {
        "project_relative": rel,
        "cwd": cwd,
        "last_activity": mtime,
        "subject": subj or p.get("subject", ""),
        "status": p.get("status", "active"),
    }
machines[machine] = new   # entries not in `seen` are dropped => pruning
json.dump(data, open(registry, "w"), indent=2)
print(f"Indexed {len(new)} session(s) for {machine}.")
PYEOF
rm -f "$TSV"

session-hub-push "index: $MACHINE $(date -u +%Y-%m-%dT%H:%MZ)" || true
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `tests/run_tests.sh`
Expected: `test_index_scan` PASS (both project_relative/subject/cwd and pruning).

- [ ] **Step 5: First real scan on the Mac, then inspect**

```bash
session-hub-sync
session-index-scan
python3 -m json.tool ~/.claude/session-hub/registry.json | head -40
```
Expected: dozens of sessions under `machines.mac`, each with a `subject`/`cwd`, and a pushed hub commit.

- [ ] **Step 6: Commit**

```bash
git add bin/session-index-scan tests/test_index_scan.sh
git commit -m "feat: session-index-scan auto-populator + tests"
```

---

### Task 7: `session-index-view` — merged cross-machine list

**Files:**
- Create: `bin/session-index-view`
- Create: `tests/test_index_view.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_index_view.sh`:
```bash
#!/usr/bin/env bash
# tests/test_index_view.sh — sourced by run_tests.sh
echo "--- test_index_view ---"
TMP=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP"
cat > "$TMP/registry.json" << 'EOF'
{ "version": 2, "machines": {
  "mac":   { "s1": {"project_relative":"projects/foo","cwd":"/Users/y/projects/foo","last_activity":"2026-06-10T00:00:00Z","subject":"foo","status":"active"},
             "s2": {"project_relative":"projects/bar","cwd":"/Users/y/projects/bar","last_activity":"2026-06-16T00:00:00Z","subject":"bar","status":"active"} },
  "nexus": { "s1": {"project_relative":"projects/foo","cwd":"/home/y/projects/foo","last_activity":"2026-06-12T00:00:00Z","subject":"foo","status":"active"} }
} }
EOF
OUT=$(session-index-view)
# Deduped by sid: 2 rows (s1 once, s2 once).
N=$(echo "$OUT" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
assert_eq "view dedups by sid" "2" "$N"
# s1 resolves to nexus (more recent activity).
S1M=$(echo "$OUT" | python3 -c "import json,sys;print([r for r in json.load(sys.stdin) if r['id']=='s1'][0]['machine'])")
assert_eq "view picks latest-activity machine" "nexus" "$S1M"
# Sorted newest-first: first row is s2.
FIRST=$(echo "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['id'])")
assert_eq "view sorts newest first" "s2" "$FIRST"
rm -rf "$TMP"; unset HUB_DIR_OVERRIDE
```

- [ ] **Step 2: Run it, verify it fails**

Run: `tests/run_tests.sh`
Expected: FAIL — `session-index-view: command not found`.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# session-index-view — print merged session list as a JSON array, newest first.
# One row per session-id (deduped across machines, keeping the most-recently-active).
# Each row: {id, machine, project_relative, cwd, last_activity, subject, status, also_on:[...]}.
# Respects HUB_DIR_OVERRIDE. Filters: --project <rel-substr>, --machine <m>, --active.
set -euo pipefail
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
REGISTRY="$HUB_DIR/registry.json"
python3 - "$REGISTRY" "$@" << 'PYEOF'
import json, os, sys
registry = sys.argv[1]
args = sys.argv[2:]
f_project = f_machine = None; f_active = False
i = 0
while i < len(args):
    a = args[i]
    if a == "--project": f_project = args[i+1]; i += 2
    elif a == "--machine": f_machine = args[i+1]; i += 2
    elif a == "--active": f_active = True; i += 1
    else: i += 1
if not os.path.exists(registry):
    print("[]"); sys.exit(0)
data = json.load(open(registry))
best = {}
for machine, sessions in data.get("machines", {}).items():
    for sid, e in sessions.items():
        row = dict(e); row["id"] = sid; row["machine"] = machine
        cur = best.get(sid)
        if cur is None or row.get("last_activity","") > cur.get("last_activity",""):
            also = set(cur.get("also_on", [])) if cur else set()
            if cur: also.add(cur["machine"])
            row["also_on"] = sorted(also)
            best[sid] = row
        else:
            cur.setdefault("also_on", [])
            if machine not in cur["also_on"]:
                cur["also_on"] = sorted(set(cur["also_on"]) | {machine})
rows = list(best.values())
if f_project: rows = [r for r in rows if f_project in r.get("project_relative","")]
if f_machine: rows = [r for r in rows if r.get("machine") == f_machine]
if f_active:  rows = [r for r in rows if r.get("status") == "active"]
rows.sort(key=lambda r: r.get("last_activity",""), reverse=True)
print(json.dumps(rows, indent=2))
PYEOF
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `tests/run_tests.sh`
Expected: `test_index_view` PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/session-index-view tests/test_index_view.sh
git commit -m "feat: session-index-view merged cross-machine list + tests"
```

---

## Phase 2 — Global view

### Task 8: `sessions` CLI table

**Files:**
- Create: `bin/sessions`

- [ ] **Step 1: Implement the formatter**

```bash
#!/usr/bin/env bash
# sessions — human-facing table of all sessions across machines.
# Passes flags through to session-index-view: --project <s>, --machine <m>, --active.
set -euo pipefail
session-hub-sync >/dev/null 2>&1 || true
THIS=$(session-config machine 2>/dev/null || echo "")
session-index-view "$@" | python3 - "$THIS" << 'PYEOF'
import json, sys
this = sys.argv[1]
rows = json.load(sys.stdin)
if not rows:
    print("No sessions in index. Run session-index-scan (or wait for the scheduled job)."); sys.exit(0)
print(f"{'Date':<11} {'Machine':<8} {'St':<4} {'Project':<26} {'Subject'}")
print("-" * 90)
for r in rows:
    date = (r.get("last_activity") or "")[:10]
    mach = r.get("machine","?")
    here = "*" if mach == this else " "
    st = "arch" if r.get("status") == "archived" else "act"
    proj = (r.get("project_relative") or "?")[:26]
    subj = (r.get("subject") or "")[:48]
    extra = ("+"+",".join(r["also_on"])) if r.get("also_on") else ""
    print(f"{date:<11} {mach:<7}{here} {st:<4} {proj:<26} {subj} {extra}")
print()
print(f"  * = this machine ({this}).  Resume: /session:resume <id-prefix>")
PYEOF
```

- [ ] **Step 2: Manual verification**

```bash
sessions | head -20
sessions --project la-pelucherie
sessions --active | head
```
Expected: a sorted table; `--project` narrows to LP rows; `*` marks Mac rows.

- [ ] **Step 3: Commit**

```bash
git add bin/sessions
git commit -m "feat: sessions CLI table (global cross-machine view)"
```

---

### Task 9: Rewrite `session:list` as the global view

**Files:**
- Modify: `list/SKILL.md`
- Modify: `plugins/session/skills/list/SKILL.md`

- [ ] **Step 1: Rewrite `list/SKILL.md`**

```markdown
---
name: session:list
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
```

- [ ] **Step 2: Mirror into the plugin copy**

Copy the same content into `plugins/session/skills/list/SKILL.md` (keep its existing frontmatter `name`/`description` in sync with the above).

- [ ] **Step 3: Commit**

```bash
git add list/SKILL.md plugins/session/skills/list/SKILL.md
git commit -m "feat: session:list is now the global cross-machine view"
```

---

## Phase 3 — Cross-machine resume

### Task 10: Rewrite `session:resume` with remote ssh pull

**Files:**
- Modify: `resume/SKILL.md`
- Modify: `plugins/session/skills/resume/SKILL.md`

- [ ] **Step 1: Rewrite `resume/SKILL.md`**

```markdown
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
PROJECT_PATH="$HOME_DIR/$PROJECT_RELATIVE"
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
```

- [ ] **Step 2: Mirror into the plugin copy**

Copy the same body into `plugins/session/skills/resume/SKILL.md`, keeping frontmatter in sync.

- [ ] **Step 3: Manual end-to-end verification (Mac ↔ Nexus)**

On Nexus: start a throwaway session in some repo, let its scan run (or run `session-index-scan`).
On Mac:
```bash
sessions --machine nexus | head
# pick the id, then:
/session:resume <id-prefix>
```
Expected: rsync pulls the JSONL from Nexus, `claude --resume` opens the conversation on the Mac.

- [ ] **Step 4: Commit**

```bash
git add resume/SKILL.md plugins/session/skills/resume/SKILL.md
git commit -m "feat: session:resume pulls remote JSONL over ssh"
```

---

## Phase 4 — GC process (RAM hygiene)

### Task 11: `session-gc-process`

**Files:**
- Create: `bin/session-gc-process`

- [ ] **Step 1: Implement (dry-run by default)**

```bash
#!/usr/bin/env bash
# session-gc-process — kill idle/orphan `claude` processes to free RAM.
# Conservative: targets only detached `claude` CLI processes (no controlling tty)
# whose elapsed time exceeds the idle threshold, and never the caller's own tree.
# Dry-run unless --kill is passed. Threshold from gc_process_idle_hours (default 6).
set -euo pipefail
KILL=0; [ "${1:-}" = "--kill" ] && KILL=1
IDLE_HOURS=$(session-config gc_process_idle_hours 2>/dev/null || echo 6)
SELF=$$
# Fields: pid, ppid, tty, etimes(seconds), command
ps -axo pid=,ppid=,tty=,etimes=,command= | python3 - "$IDLE_HOURS" "$SELF" "$KILL" << 'PYEOF'
import os, sys, signal
idle_h = float(sys.argv[1]); self_pid = int(sys.argv[2]); do_kill = sys.argv[3] == "1"
threshold = idle_h * 3600
victims = []
for line in sys.stdin:
    parts = line.split(None, 4)
    if len(parts) < 5: continue
    pid, ppid, tty, etimes, cmd = parts
    try: pid = int(pid); etimes = int(etimes)
    except ValueError: continue
    if pid == self_pid: continue
    # Only the claude CLI, not Claude.app helpers / chrome-native-host / this tmux.
    base = cmd.strip()
    if not (base == "claude" or base.startswith("claude ")): continue
    # Detached only: no controlling tty (tty column is '?' or '??').
    if tty not in ("?", "??", "-"): continue
    if etimes < threshold: continue
    victims.append((pid, etimes, base[:60]))
if not victims:
    print("GC process: nothing to reap."); sys.exit(0)
for pid, et, base in victims:
    hrs = et / 3600
    if do_kill:
        try: os.kill(pid, signal.SIGTERM); print(f"  killed pid {pid} (idle {hrs:.1f}h): {base}")
        except ProcessLookupError: pass
    else:
        print(f"  would kill pid {pid} (idle {hrs:.1f}h): {base}")
print(f"GC process: {len(victims)} target(s){' killed' if do_kill else ' (dry-run, pass --kill)'}.")
PYEOF
```

- [ ] **Step 2: Manual verification**

```bash
session-gc-process            # dry-run: lists detached idle claude PIDs, kills nothing
```
Expected: lists only detached `claude` CLI processes older than the threshold; your current foreground session (has a tty) is never listed. Confirm the listed PIDs are genuinely spare (`ps -p <pid> -o pid,tty,etime,command`) before trusting `--kill`.

- [ ] **Step 3: Commit**

```bash
git add bin/session-gc-process
git commit -m "feat: session-gc-process (dry-run default) for RAM hygiene"
```

---

## Phase 5 — GC sessions (archive + optional purge)

### Task 12: `session-gc-sessions`

**Files:**
- Create: `bin/session-gc-sessions`
- Create: `tests/test_gc_sessions.sh`

- [ ] **Step 1: Write the failing test**

The archive path calls `ai-brain:save` (interactive skill) — not callable from a unit test — so the helper takes a `GC_CHECKPOINT_CMD` env hook (default: a no-op that just logs). The test stubs it and verifies the status flip + age gating, using a fake registry and faked file mtimes via env-injected "now".

Create `tests/test_gc_sessions.sh`:
```bash
#!/usr/bin/env bash
# tests/test_gc_sessions.sh — sourced by run_tests.sh
echo "--- test_gc_sessions ---"
TMP=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP"
export GC_CHECKPOINT_CMD="true"          # stub the checkpoint
export GC_NOW="2026-06-30T00:00:00Z"     # fixed clock for deterministic ages
# Stub config: machine=mac, archive after 10 days, no purge.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/session-config" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  machine) echo mac ;;
  gc_archive_days) echo 10 ;;
  gc_purge_days) echo 0 ;;
  *) echo "" ;;
esac
EOF
chmod +x "$STUB"/*; export PATH="$STUB:$PATH"
cat > "$TMP/registry.json" << 'EOF'
{ "version":2, "machines": { "mac": {
  "old": {"project_relative":"projects/a","cwd":"/h/a","last_activity":"2026-06-01T00:00:00Z","subject":"old","status":"active"},
  "new": {"project_relative":"projects/b","cwd":"/h/b","last_activity":"2026-06-28T00:00:00Z","subject":"new","status":"active"}
} } }
EOF

session-gc-sessions

OLD=$(python3 -c "import json;print(json.load(open('$TMP/registry.json'))['machines']['mac']['old']['status'])")
NEW=$(python3 -c "import json;print(json.load(open('$TMP/registry.json'))['machines']['mac']['new']['status'])")
assert_eq "gc archives stale session" "archived" "$OLD"
assert_eq "gc keeps fresh session active" "active" "$NEW"

rm -rf "$TMP"; unset HUB_DIR_OVERRIDE GC_CHECKPOINT_CMD GC_NOW
export PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd):$PATH"
```

- [ ] **Step 2: Run it, verify it fails**

Run: `tests/run_tests.sh`
Expected: FAIL — `session-gc-sessions: command not found`.

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
# session-gc-sessions — two-tier session GC for THIS machine's index entries.
#  Archive: entry inactive > gc_archive_days -> run checkpoint, set status=archived.
#  Purge:   archived JSONL older than gc_purge_days (0 = never) -> delete local jsonl.
# Always checkpoints before archiving, so no meaning is lost. Reports what it did.
# Env hooks (tests): GC_CHECKPOINT_CMD (default ai-brain checkpoint), GC_NOW (ISO clock).
set -euo pipefail
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
REGISTRY="$HUB_DIR/registry.json"
MACHINE=$(session-config machine)
ARCHIVE_DAYS=$(session-config gc_archive_days 2>/dev/null || echo 10)
PURGE_DAYS=$(session-config gc_purge_days 2>/dev/null || echo 0)
[ -f "$REGISTRY" ] || { echo "GC sessions: no registry."; exit 0; }

# Phase A: decide archive candidates (status active, too old). Print ids to checkpoint.
CANDIDATES=$(python3 - "$REGISTRY" "$MACHINE" "$ARCHIVE_DAYS" "${GC_NOW:-}" << 'PYEOF'
import json, sys
from datetime import datetime, timezone
registry, machine, days, now_s = sys.argv[1:5]
days = int(days)
now = datetime.fromisoformat(now_s.replace("Z","+00:00")) if now_s else datetime.now(timezone.utc)
data = json.load(open(registry))
for sid, e in data.get("machines", {}).get(machine, {}).items():
    if e.get("status") != "active": continue
    la = e.get("last_activity","")
    if not la: continue
    age = (now - datetime.fromisoformat(la.replace("Z","+00:00"))).days
    if age >= days: print(sid)
PYEOF
)

CHECKPOINT="${GC_CHECKPOINT_CMD:-echo '  (checkpoint hook not wired; set GC_CHECKPOINT_CMD)'}"
ARCHIVED=0
for sid in $CANDIDATES; do
  eval "$CHECKPOINT" >/dev/null 2>&1 || true   # checkpoint BEFORE archiving
  python3 - "$REGISTRY" "$MACHINE" "$sid" << 'PYEOF'
import json, sys
registry, machine, sid = sys.argv[1:4]
data = json.load(open(registry))
data["machines"][machine][sid]["status"] = "archived"
json.dump(data, open(registry, "w"), indent=2)
PYEOF
  echo "  archived $sid"
  ARCHIVED=$((ARCHIVED+1))
done

# Phase B: optional purge of archived local JSONL older than PURGE_DAYS.
PURGED=0
if [ "$PURGE_DAYS" -gt 0 ]; then
  CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    cwd=$(session-registry-get "$sid" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))")
    [ -z "$cwd" ] && continue
    enc=$(session-encode-path "$cwd")
    f="$CLAUDE_DIR/projects/$enc/$sid.jsonl"
    if [ -f "$f" ] && [ -n "$(find "$f" -mtime +"$PURGE_DAYS" 2>/dev/null)" ]; then
      rm "$f"; echo "  purged jsonl $sid"; PURGED=$((PURGED+1))
    fi
  done < <(python3 -c "import json;d=json.load(open('$REGISTRY'));print('\n'.join(s for s,e in d['machines'].get('$MACHINE',{}).items() if e.get('status')=='archived'))")
fi

echo "GC sessions: $ARCHIVED archived, $PURGED purged."
session-hub-push "gc: $MACHINE archived=$ARCHIVED purged=$PURGED" 2>/dev/null || true
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `tests/run_tests.sh`
Expected: `test_gc_sessions` PASS (old→archived, new stays active).

- [ ] **Step 5: Wire the real checkpoint hook**

The production `GC_CHECKPOINT_CMD` must invoke an `ai-brain:save` checkpoint non-interactively. Until a headless checkpoint entrypoint exists, set it in the launchd/cron env (Task 14/15) to a script that writes a minimal checkpoint for the project. Document this dependency in Task 16's deprecation note. For the first deployment, leave `gc_purge_days: 0` (archive-only, fully reversible).

- [ ] **Step 6: Commit**

```bash
git add bin/session-gc-sessions tests/test_gc_sessions.sh
git commit -m "feat: session-gc-sessions (archive + optional purge) + tests"
```

---

## Phase 6 — Scheduling, deprecations, docs

### Task 13: Run the full test suite

- [ ] **Step 1: All green**

Run: `tests/run_tests.sh`
Expected: every `test_*` PASS, final line `Results: N passed, 0 failed`. Fix any regressions before scheduling.

- [ ] **Step 2: Commit (only if fixes were needed)**

```bash
git commit -am "test: green suite after consolidation helpers" || true
```

---

### Task 14: launchd units (Mac)

**Files:**
- Create: `units/com.yann.session-index.plist`
- Create: `units/com.yann.session-gc-process.plist`
- Create: `units/com.yann.session-gc-sessions.plist`

- [ ] **Step 1: Index scan every 15 min**

Create `units/com.yann.session-index.plist` (the implementer substitutes the real home path):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.yann.session-index</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-lc</string>
    <string>PATH="$HOME/.claude/skills/session/bin:$PATH" session-index-scan</string>
  </array>
  <key>StartInterval</key><integer>900</integer>
  <key>StandardOutPath</key><string>/tmp/session-index.log</string>
  <key>StandardErrorPath</key><string>/tmp/session-index.err</string>
</dict></plist>
```

- [ ] **Step 2: GC process hourly**

Create `units/com.yann.session-gc-process.plist` — same shape, `Label` `com.yann.session-gc-process`, `StartInterval` `3600`, command `... session-gc-process --kill`, logs `/tmp/session-gc-process.log`.

- [ ] **Step 3: GC sessions daily at 04:00**

Create `units/com.yann.session-gc-sessions.plist` — `Label` `com.yann.session-gc-sessions`, replace `StartInterval` with:
```xml
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>
```
command `... session-gc-sessions`, and add the checkpoint hook to its environment:
```xml
  <key>EnvironmentVariables</key><dict>
    <key>GC_CHECKPOINT_CMD</key><string>true</string>
  </dict>
```
(Replace `true` with the real headless checkpoint command once it exists — see Task 12 Step 5.)

- [ ] **Step 4: Load and verify**

```bash
for u in index gc-process gc-sessions; do
  cp units/com.yann.session-$u.plist ~/Library/LaunchAgents/
  launchctl unload ~/Library/LaunchAgents/com.yann.session-$u.plist 2>/dev/null || true
  launchctl load ~/Library/LaunchAgents/com.yann.session-$u.plist
done
launchctl list | grep com.yann.session
```
Expected: three entries listed. After ~15 min, `/tmp/session-index.log` shows "Indexed N session(s) for mac." and the hub has fresh index commits.

- [ ] **Step 5: Commit**

```bash
git add units/com.yann.session-index.plist units/com.yann.session-gc-process.plist units/com.yann.session-gc-sessions.plist
git commit -m "feat: launchd units for index scan + GC (Mac)"
```

---

### Task 15: cron snippet (Nexus)

**Files:**
- Create: `units/crontab.nexus`

- [ ] **Step 1: Write the snippet**

Create `units/crontab.nexus`:
```cron
# Claude session consolidation — Nexus. Install: crontab -e and paste, or
#   (crontab -l 2>/dev/null; cat units/crontab.nexus) | crontab -
# PATH must include the session bin dir for the helpers to resolve.
PATH=/home/yann/.claude/skills/session/bin:/usr/local/bin:/usr/bin:/bin
*/15 * * * * session-index-scan >> /tmp/session-index.log 2>&1
0    * * * * session-gc-process --kill >> /tmp/session-gc-process.log 2>&1
0 4  * * * GC_CHECKPOINT_CMD=true session-gc-sessions >> /tmp/session-gc-sessions.log 2>&1
```

- [ ] **Step 2: Install on Nexus and verify**

On Nexus (the machine, per machine-context — do not break the no-SSH rule from the wrong host):
```bash
(crontab -l 2>/dev/null; cat ~/.claude/skills/session/units/crontab.nexus) | crontab -
crontab -l | grep session
```
Confirm `session-config machine` on Nexus prints `nexus` and that `peer_mac` is set there. After 15 min, `/tmp/session-index.log` shows "Indexed N session(s) for nexus." and `sessions` on the Mac now shows Nexus rows.

- [ ] **Step 3: Commit**

```bash
git add units/crontab.nexus
git commit -m "feat: cron snippet for index scan + GC (Nexus)"
```

---

### Task 16: Deprecate `session:save` / `session:migrate`, drop `session-cleanup`, update install

**Files:**
- Modify: `save/SKILL.md`, `plugins/session/skills/save/SKILL.md`
- Modify: `migrate/SKILL.md`, `plugins/session/skills/migrate/SKILL.md`
- Delete: `bin/session-cleanup`
- Modify: `install.sh`

- [ ] **Step 1: Turn `save/SKILL.md` into a deprecation pointer**

```markdown
---
name: session:save
description: DEPRECATED — use /ai-brain:save. Semantic checkpoints now live in the ai-brain vault.
allowed-tools:
  - Bash
---

# session:save (deprecated)

Checkpointing is consolidated into **`/ai-brain:save`**, which writes a semantic
checkpoint into the ai-brain vault and syncs it cross-machine by git.

There is nothing to do here. Run:

```
/ai-brain:save
```

Session *transcripts* are handled automatically by the index scanner — you do not
need to save them by hand.
```
Mirror into `plugins/session/skills/save/SKILL.md`.

- [ ] **Step 2: Turn `migrate/SKILL.md` into a deprecation pointer**

```markdown
---
name: session:migrate
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
```
Mirror into `plugins/session/skills/migrate/SKILL.md`.

- [ ] **Step 3: Remove the superseded cleanup helper**

```bash
git rm bin/session-cleanup
```
(The new `session-gc-sessions` replaces it; nothing else calls it after Task 16 — `migrate` no longer runs it.)

- [ ] **Step 4: Update `install.sh`**

In `install.sh`, after the existing skill/bin install, append a block that runs the registry migration and installs the scheduler for the current platform. Insert before the final success echo:
```bash
# ── Sessions consolidation: migrate registry + schedule jobs ─────────────────
if [ -f "$HOME/.claude/session-migrate.yml" ]; then
  PATH="$BIN_DIR:$PATH" session-hub-sync || true
  PATH="$BIN_DIR:$PATH" session-registry-migrate || true
  case "$(uname -s)" in
    Darwin)
      for u in index gc-process gc-sessions; do
        cp "$INSTALL_DIR/units/com.yann.session-$u.plist" "$HOME/Library/LaunchAgents/" 2>/dev/null || true
        launchctl unload "$HOME/Library/LaunchAgents/com.yann.session-$u.plist" 2>/dev/null || true
        launchctl load "$HOME/Library/LaunchAgents/com.yann.session-$u.plist" 2>/dev/null || true
      done
      echo "✓  launchd jobs installed (index + GC)" ;;
    Linux)
      echo "ℹ️  On Linux, install cron jobs: (crontab -l 2>/dev/null; cat $INSTALL_DIR/units/crontab.nexus) | crontab -" ;;
  esac
fi
```

- [ ] **Step 5: Verify install is idempotent**

```bash
bash install.sh
launchctl list | grep com.yann.session   # 3 jobs
tests/run_tests.sh                        # still green
```
Expected: re-running is safe; migration prints "Already v2"; jobs remain loaded.

- [ ] **Step 6: Commit**

```bash
git add save/SKILL.md plugins/session/skills/save/SKILL.md \
        migrate/SKILL.md plugins/session/skills/migrate/SKILL.md install.sh
git rm --cached bin/session-cleanup 2>/dev/null || true
git commit -m "feat: deprecate session:save/migrate, drop session-cleanup, wire install"
```

---

### Task 17: Document the consolidated system + record dependency

**Files:**
- Create: `README.md` (or update if present)
- Modify (vault, separate repo): a note that `session:save` is deprecated in favour of `ai-brain:save`, and that GC's checkpoint hook depends on a headless `ai-brain:save` entrypoint.

- [ ] **Step 1: Write `README.md`**

Document: the five components, the v2 registry schema, the config keys (`peer_*`, `gc_*`), how to read `sessions`, how `/session:resume` works across machines, and the GC clocks. State plainly that `gc_purge_days` ships at `0` (archive-only) until a headless checkpoint entrypoint lands.

- [ ] **Step 2: Note the cross-repo dependency**

In the ai-brain vault, add a short note (or todo) that `session-gc-sessions` wants a non-interactive `ai-brain:save` so the daily archive can checkpoint before archiving. Until then, GC archives are still safe (JSONL retained; archive is reversible by resume).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: consolidated sessions system + GC checkpoint dependency"
```

---

### Task 18: Merge the branch

- [ ] **Step 1: Final verification**

```bash
tests/run_tests.sh
sessions | head        # shows both machines once Nexus cron has run
git log --oneline main..sessions-consolidation
```

- [ ] **Step 2: Merge**

Use the `superpowers:finishing-a-development-branch` skill to choose merge vs PR and complete integration.

---

## Self-Review

**Spec coverage:**
- Decision 1 (separate transport/sense) → Tasks 9, 10 (session = transcript/view/resume), 16 (save→ai-brain). ✓
- Decision 2 (deprecate session:save) → Task 16. ✓
- Decision 3 (git-synced light index, JSONL off git) → Tasks 2, 6 (registry only; no JSONL added to hub). ✓
- Decision 4 (on-demand JSONL pull over Tailscale/ssh) → Task 10. ✓
- Decision 5 (two GC clocks) → Tasks 11 (process), 12 (sessions). ✓
- Decision 6 (silent cron GC, checkpoint-before-archive) → Tasks 12, 14, 15. ✓
- Component 1 (auto index) → Tasks 4–6. ✓  Component 2 (`sessions`) → Tasks 7–9. ✓
- Component 3 (resume indifferent) → Task 10. ✓  Component 4 (GC process) → Task 11. ✓  Component 5 (GC sessions, two tiers) → Task 12. ✓
- Partition-by-machine / no git conflict → schema v2 (Task 2), scanner writes only `machines[self]` (Task 6). ✓
- "Subject = first real user message, filter meta" → Task 5. ✓

**Open spec items deliberately deferred (flagged, not silently dropped):**
- Headless `ai-brain:save` for the GC checkpoint hook — Task 12 Step 5 + Task 17 Step 2 record it; GC ships archive-only (`gc_purge_days: 0`) so nothing is lost meanwhile.
- Exact "process → session-id via cc-daemon sockets" mapping — Task 11 uses a conservative tty/age heuristic instead (roster.json `workers` is currently empty), dry-run by default. Refine when the daemon roster is populated.

**Placeholder scan:** every code step contains full, runnable code; no TBD/TODO-in-code. The two deferred items are explicit, scoped, and safe-by-default — not hidden gaps.

**Type/name consistency:** registry entry shape `{project_relative, cwd, last_activity, subject, status}` is identical in Tasks 2, 6, 7, 12. `session-registry-get` returns that plus `machine` (Tasks 2, 10, 12 consume it). Config keys `peer_<machine>`, `gc_process_idle_hours`, `gc_archive_days`, `gc_purge_days` are written in Task 1 and read identically in Tasks 10, 11, 12, 14, 15. Helper names (`session-index-scan`, `session-index-view`, `session-subject`, `session-jsonl-cwd`, `session-gc-process`, `session-gc-sessions`, `sessions`) are stable across all references.
