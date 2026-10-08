#!/usr/bin/env bash
# tests/test_cross_machine.sh — sourced by run_tests.sh
# Whole flows across both machines: where a migrated session lives, who acts
# on a diverged copy, hub races, replica clean-up.
echo "--- test_cross_machine ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
M="$MTMP/mac"; N="$MTMP/nexus"
MENC=$(session-encode-path "$M/projects/tpg/rakam")
NENC=$(session-encode-path "$N/projects/tpg/rakam")
reg() {  # <on-machine> <registry-machine> <sid> <key>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(d["machines"].get(sys.argv[2],{}).get(sys.argv[3],{}).get(sys.argv[4],"-"))' \
    "$MTMP/$1/.claude/session-hub/registry.json" "$2" "$3" "$4"
}
yn() { "$@" && echo yes || echo no; }

# ── C1: the destination places a migrated session where it landed ───────────
R=a1a1a1a1-1111-2222-3333-444444444444
mk_session mac "$R" "$M/projects/tpg/rakam" '{"type":"assistant","uuid":"r2"}' >/dev/null
on mac session-index-scan >/dev/null 2>&1
rc=0; on nexus session-migrate "$R" --yes >/dev/null 2>&1 || rc=$?
assert_eq "C1: mac → nexus migrates" "0" "$rc"
assert_eq "C1: session-cwd reads the override" "$N/projects/tpg/rakam" \
  "$(on nexus session-cwd "$N/.claude/projects/$NENC/$R.jsonl")"
assert_eq "C1: session-cwd without override = transcript cwd" "$M/projects/tpg/rakam" \
  "$(on mac session-cwd "$(mk_session mac b1b1b1b1-0000-0000-0000-000000000000 "$M/projects/tpg/rakam")")"
rm -f "$M/.claude/projects/$MENC/b1b1b1b1-0000-0000-0000-000000000000.jsonl"
on nexus session-index-scan >/dev/null 2>&1
on mac session-index-scan >/dev/null 2>&1          # mac's copy is gone: its entry too
on nexus session-hub-sync >/dev/null 2>&1
assert_eq "C1: nexus scan: cwd"              "$N/projects/tpg/rakam" "$(reg nexus nexus "$R" cwd)"
assert_eq "C1: nexus scan: project_relative" "projects/tpg/rakam"    "$(reg nexus nexus "$R" project_relative)"
assert_eq "C1: nexus scan: cc_subject"       "tpg"                   "$(reg nexus nexus "$R" cc_subject)"
assert_eq "C1: nexus scan: cc_rel"           "rakam"                 "$(reg nexus nexus "$R" cc_rel)"
assert_eq "C1: mac entry pruned"             "-"                     "$(reg nexus mac "$R" cwd)"
mkdir -p "$MTMP/st"; echo subject > "$MTMP/st/scope"; echo tpg > "$MTMP/st/subject"
assert_eq "C1: listed under its subject" "1" \
  "$(on nexus env SESSIONS_STATE="$MTMP/st" session-rows | grep -c "^$R" || true)"
# Round trip: back to the Mac, into its original directory.
rc=0; out=$(on mac session-migrate "$R" --yes 2>&1) || rc=$?
assert_eq "C1: nexus → mac migrates back" "0" "$rc"
[ "$rc" = 0 ] || echo "$out"
assert_eq "C1: lands in the Mac's original directory" "yes" "$(yn test -f "$M/.claude/projects/$MENC/$R.jsonl")"
assert_eq "C1: mac override = original cwd" "$M/projects/tpg/rakam" "$(cat "$M/.claude/session-cwd-override/$R" 2>/dev/null)"
assert_eq "C1: nexus copy settled" "no" "$(yn test -f "$N/.claude/projects/$NENC/$R.jsonl")"

machines_teardown
