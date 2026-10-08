#!/usr/bin/env bash
# tests/test_reconcile.sh — sourced by run_tests.sh
echo "--- test_reconcile ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
M="$MTMP/mac"
fp_of() { session-fingerprint "$1"; }
own_elsewhere() {  # <sid> <jsonl-whose-state-was-migrated>
  on mac session-metastore set "$1" owner '"nexus"'
  on mac session-metastore set "$1" fingerprint "$(fp_of "$2")"
}
diverged_list() { python3 -c "import json;print(' '.join(json.load(open('$M/.claude/session-diverged.json'))))"; }
# Trash entries are <id> or <id>.<HHMMSS>.<pid> (same id trashed twice a day).
in_trash() { ls "$M"/.claude/session-trash/*/"$1"*/"$1".jsonl >/dev/null 2>&1 && echo yes || echo no; }

# Identical to the migrated state → trash.
A=aaaa0000-1111-2222-3333-444444444444
FA=$(mk_session mac "$A" "$M/projects/tpg/rakam"); own_elsewhere "$A" "$FA"
# Grew after the migration (lid closed mid-turn) → diverged, untouched (Review Focus 2).
B=bbbb0000-1111-2222-3333-444444444444
FB=$(mk_session mac "$B" "$M/projects/tpg/rakam"); own_elsewhere "$B" "$FB"
echo '{"type":"user","uuid":"late"}' >> "$FB"
# Running here (interactive) → untouched even if identical (Review Focus 4).
C=cccc0000-1111-2222-3333-444444444444
FC=$(mk_session mac "$C" "$M/projects/tpg/rakam"); own_elsewhere "$C" "$FC"
echo "[{\"sessionId\":\"$C\",\"pid\":7,\"status\":\"busy\"}]" > "$M/.agents.json"
# Owned here → untouched.
D=dddd0000-1111-2222-3333-444444444444
FD=$(mk_session mac "$D" "$M/projects/tpg/rakam")

on mac session-reconcile >/dev/null 2>&1
assert_eq "identical → trashed"        "no"  "$([ -f "$FA" ] && echo yes || echo no)"
assert_eq "identical → in trash"       "yes" "$(in_trash "$A")"
assert_eq "grown → kept"               "yes" "$([ -f "$FB" ] && echo yes || echo no)"
assert_eq "grown → listed diverged"    "$B"  "$(diverged_list)"
assert_eq "running → kept"             "yes" "$([ -f "$FC" ] && echo yes || echo no)"
assert_eq "owned here → kept"          "yes" "$([ -f "$FD" ] && echo yes || echo no)"

# The scan carries the flag into the registry.
on mac session-index-scan >/dev/null 2>&1
assert_eq "registry diverged flag" "True" \
  "$(python3 -c "import json;print(json.load(open('$M/.claude/session-hub/registry.json'))['machines']['mac']['$B'].get('diverged'))")"
assert_eq "registry not diverged" "False" \
  "$(python3 -c "import json;print(json.load(open('$M/.claude/session-hub/registry.json'))['machines']['mac']['$D'].get('diverged'))")"

# Trash older than 30 days is emptied — only YYYY-MM-DD day directories.
OLD="$M/.claude/session-trash/2000-01-01/zzzz"; mkdir -p "$OLD"; touch -t 200001010000 "$M/.claude/session-trash/2000-01-01"
ODD="$M/.claude/session-trash/keep-me"; mkdir -p "$ODD"; touch -t 200001010000 "$ODD"
on mac session-reconcile >/dev/null 2>&1
assert_eq "old trash purged" "no" "$([ -d "$M/.claude/session-trash/2000-01-01" ] && echo yes || echo no)"
assert_eq "non-date trash entry kept" "yes" "$([ -d "$ODD" ] && echo yes || echo no)"
assert_eq "recent trash kept" "yes" "$(in_trash "$A")"

# Invalid id: refused before any path is built.
rc=0; on mac session-reconcile '../x' >/dev/null 2>&1 || rc=$?
assert_eq "reconcile rejects invalid id" "1" "$rc"
rc=0; echo c | on mac session-diverge '../x' >/dev/null 2>&1 || rc=$?
assert_eq "diverge rejects invalid id" "1" "$rc"

# Unreadable supervisor → fail closed: nothing trashed, previous flags kept.
E=eeee0000-1111-2222-3333-444444444444
FE=$(mk_session mac "$E" "$M/projects/tpg/rakam"); own_elsewhere "$E" "$FE"
echo garbage > "$M/.agents.json"
on mac session-reconcile >/dev/null 2>&1 || true
assert_eq "supervisor error → identical kept" "yes" "$([ -f "$FE" ] && echo yes || echo no)"
assert_eq "supervisor error → flags kept"     "$B" "$(diverged_list)"

# Single-id run: settles that id only.
echo '[]' > "$M/.agents.json"
on mac session-reconcile "$E" >/dev/null 2>&1
assert_eq "single id → trashed"     "no"  "$([ -f "$FE" ] && echo yes || echo no)"
assert_eq "single id → others kept" "yes" "$([ -f "$FC" ] && echo yes || echo no)"
assert_eq "single id → flags kept"  "$B"  "$(diverged_list)"

# Divergence → keep both: forked copy appears, original goes to the trash.
: > "$MTMP/claude.log"
echo g | on mac session-diverge "$B" >/dev/null 2>&1
assert_eq "keep both: fork requested" "yes" "$(grep -q -- "--resume $B --fork-session --bg" "$MTMP/claude.log" && echo yes || echo no)"
assert_eq "keep both: original trashed" "no" "$([ -f "$FB" ] && echo yes || echo no)"
assert_eq "keep both: fork present" "yes" "$([ -f "$(dirname "$FB")/f0f0f0f0-0000-0000-0000-000000000000.jsonl" ] && echo yes || echo no)"
assert_eq "keep both: flag cleared" "" "$(diverged_list)"

# Divergence → trash, refused while running.
G=99990000-1111-2222-3333-444444444444
FG=$(mk_session mac "$G" "$M/projects/tpg/rakam"); own_elsewhere "$G" "$FG"; echo '{"uuid":"late"}' >> "$FG"
echo "[{\"sessionId\":\"$G\",\"pid\":7}]" > "$M/.agents.json"
: > "$MTMP/claude.log"
rc=0; echo g | on mac session-diverge "$G" >/dev/null 2>&1 || rc=$?
assert_eq "diverge running: refused"   "1"   "$rc"
assert_eq "diverge running: no fork"   "no"  "$(grep -q -- "--fork-session" "$MTMP/claude.log" && echo yes || echo no)"
assert_eq "diverge running: kept"      "yes" "$([ -f "$FG" ] && echo yes || echo no)"
echo '[]' > "$M/.agents.json"
echo c | on mac session-diverge "$G" >/dev/null 2>&1
assert_eq "diverge c: trashed"         "yes" "$(in_trash "$G")"
machines_teardown
