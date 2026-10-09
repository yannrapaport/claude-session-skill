#!/usr/bin/env bash
# tests/test_rows.sh — sourced by run_tests.sh
echo "--- test_rows ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
H="$MTMP/mac/.claude/session-hub"
cat > "$H/registry.json" <<'JSON'
{"version": 2, "machines": {
 "mac":   {"0dd": {"cwd": "/x", "project_relative": "projects/tpg/rakam", "cc_subject": "tpg", "cc_rel": "rakam",
                   "last_activity": "2026-10-01T10:00:00Z", "title": "Vieux", "turns": 3, "status": "active"},
           "mid": {"cwd": "/z", "project_relative": "projects/tpg", "cc_subject": "tpg", "cc_rel": "",
                   "last_activity": "2026-10-04T10:00:00Z", "title": "Milieu", "turns": 5, "status": "active",
                   "diverged": true},
           "new": {"cwd": "/y", "project_relative": "ai-brain", "cc_subject": "brain", "cc_rel": "",
                   "last_activity": "2026-10-08T10:00:00Z", "title": "Récent", "turns": 9, "status": "active"}},
 "nexus": {"mid": {"cwd": "/z", "project_relative": "projects/tpg", "cc_subject": "tpg", "cc_rel": "",
                   "last_activity": "2026-10-05T10:00:00Z", "title": "Milieu", "turns": 5, "status": "active",
                   "diverged": true}}}}
JSON
on mac session-metastore set 0dd priority '"must"'
ids() { cut -f1 | tr '\n' ' '; }
export SESSIONS_STATE="$MTMP/state"; mkdir -p "$SESSIONS_STATE"

echo activity > "$SESSIONS_STATE/sort"; echo all > "$SESSIONS_STATE/scope"; : > "$SESSIONS_STATE/filter"
assert_eq "sort by activity" "new mid 0dd " "$(on mac session-rows | ids)"
echo priority > "$SESSIONS_STATE/sort"
assert_eq "sort by priority then activity" "0dd new mid " "$(on mac session-rows | ids)"
echo project > "$SESSIONS_STATE/sort"
assert_eq "sort by project then activity" "new mid 0dd " "$(on mac session-rows | ids)"
echo subject > "$SESSIONS_STATE/scope"; echo tpg > "$SESSIONS_STATE/subject"
assert_eq "scope: current subject" "mid 0dd " "$(on mac session-rows | ids)"
echo all > "$SESSIONS_STATE/scope"; echo nexus > "$SESSIONS_STATE/filter"
assert_eq "filter: nexus" "mid " "$(on mac session-rows | ids)"
echo prio > "$SESSIONS_STATE/filter"
assert_eq "filter: prioritised" "0dd " "$(on mac session-rows | ids)"

# --json: same rows/order as the text output, typed fields.
echo activity > "$SESSIONS_STATE/sort"; : > "$SESSIONS_STATE/filter"
JSON_OUT=$(on mac session-rows --json)
assert_eq "json: exact keys" "['age', 'diverged', 'id', 'lag', 'last_activity', 'machine', 'owner', 'priority', 'proj', 'running', 'subject', 'title']" \
  "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d[0]))')"
assert_eq "json: booleans" "True" \
  "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(all(isinstance(r[k], bool) for r in d for k in ("running","lag","diverged")))')"
assert_eq "json: same order as text" "$(on mac session-rows | ids)" \
  "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; print("".join(r["id"]+" " for r in json.load(sys.stdin)))')"
assert_eq "json: diverged flag" "True" \
  "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; print({r["id"]:r["diverged"] for r in json.load(sys.stdin)}["mid"])')"
echo prio > "$SESSIONS_STATE/filter"
assert_eq "json: honours filter" "0dd " \
  "$(on mac session-rows --json | python3 -c 'import json,sys; print("".join(r["id"]+" " for r in json.load(sys.stdin)))')"

# Character-based slicing (cut -c is byte-based in a C locale).
cols() { python3 -c 'import sys; print(sys.argv[1][int(sys.argv[2])-1:int(sys.argv[3])])' "$1" "$2" "$3"; }
marks_of() { cols "$1" 10 12; }
: > "$SESSIONS_STATE/filter"
LINE=$(on mac session-rows | awk -F'\t' '$1=="mid"{print $2}')
case "$(cols "$LINE" 10 12)" in *"⚠"*) r=yes ;; *) r=no ;; esac
assert_eq "diverged marker" "yes" "$r"
echo '[{"sessionId":"new","pid":1,"status":"idle"}]' > "$MTMP/mac/.agents.json"
LINE=$(on mac session-rows | awk -F'\t' '$1=="new"{print $2}')
case "$(cols "$LINE" 10 12)" in *"●"*) r=yes ;; *) r=no ;; esac
assert_eq "running marker" "yes" "$r"
# Markers sit at fixed cols 10-12 (after badge, age, owner initial).
LINE=$(on mac session-rows | awk -F'\t' '$1=="new"{print $2}')
assert_eq "no replica, owner==machine: no ⇢" "no" "$(case "$(marks_of "$LINE")" in *⇢*) echo yes;; *) echo no;; esac)"
R="$MTMP/mac/.claude/session-replica/mac/new"; mkdir -p "$R"
echo '{"replicated_at": "2026-10-01T00:00:00Z"}' > "$R/source.json"
LINE=$(on mac session-rows | awk -F'\t' '$1=="new"{print $2}')
assert_eq "older replica: ⇢" "yes" "$(case "$(marks_of "$LINE")" in *⇢*) echo yes;; *) echo no;; esac)"
echo '{"replicated_at": "2026-10-09T00:00:00+00:00"}' > "$R/source.json"
LINE=$(on mac session-rows | awk -F'\t' '$1=="new"{print $2}')
assert_eq "newer replica: no ⇢" "no" "$(case "$(marks_of "$LINE")" in *⇢*) echo yes;; *) echo no;; esac)"
python3 - "$H/registry.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["machines"]["mac"]["ws"] = {"cwd": "/w", "project_relative": "w", "cc_subject": "", "cc_rel": "",
    "last_activity": "2026-10-02T10:00:00Z", "title": "a\tb\nc", "turns": 1, "status": "active"}
json.dump(d, open(p, "w"))
PYEOF
# Title with TAB/newline stays on one line with exactly one TAB.
N=$(on mac session-rows | grep -c '^ws'$'\t' || true)
T=$(on mac session-rows | grep '^ws'$'\t' | tr -cd '\t' | wc -c | tr -d ' ')
assert_eq "sanitized title: one line" "1" "$N"
assert_eq "sanitized title: one TAB" "1" "$T"
# Owner from meta wins over the observing machine (owner initial = col 9).
on mac session-metastore set 0dd owner '"nexus"'
LINE=$(on mac session-rows | awk -F'\t' '$1=="0dd"{print $2}')
assert_eq "owner from meta" "n" "$(cols "$LINE" 9 9)"
unset SESSIONS_STATE
machines_teardown
