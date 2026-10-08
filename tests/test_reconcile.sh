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

# Divergence → keep both. The fork writes no transcript before its first prompt:
# the link is recorded, the original waits, and the user lands in the fork.
FORK=f0f0f0f0-0000-0000-0000-000000000000
forks_json() { python3 -c "import json;print(json.load(open('$M/.claude/session-forks.json')))" 2>/dev/null || echo none; }
: > "$MTMP/claude.log"
echo g | on mac session-diverge "$B" >/dev/null 2>&1
assert_eq "keep both: fork requested"  "yes" "$(grep -q -- "--resume $B --fork-session --bg" "$MTMP/claude.log" && echo yes || echo no)"
assert_eq "keep both: link recorded"   "{'$B': '$FORK'}" "$(forks_json)"
assert_eq "keep both: original kept"   "yes" "$([ -f "$FB" ] && echo yes || echo no)"
assert_eq "keep both: attached to fork" "mac attach f0f0f0f0" "$(tail -1 "$MTMP/claude.log")"
# Fork not saved yet (still known to the supervisor) → reconcile leaves the
# original alone, still diverged.
on mac session-reconcile >/dev/null 2>&1
assert_eq "fork pending: original kept"     "yes" "$([ -f "$FB" ] && echo yes || echo no)"
assert_eq "fork pending: still diverged"    "$B"  "$(diverged_list)"
assert_eq "fork pending: link kept"         "{'$B': '$FORK'}" "$(forks_json)"
# The fork's first prompt writes its transcript → original trashed, link dropped.
echo '{"type":"user","uuid":"f1"}' > "$(dirname "$FB")/$FORK.jsonl"
on mac session-reconcile >/dev/null 2>&1
assert_eq "fork saved: original trashed"    "yes" "$(in_trash "$B")"
assert_eq "fork saved: link dropped"        "{}"  "$(forks_json)"
assert_eq "fork saved: flag cleared"        ""    "$(diverged_list)"
assert_eq "fork saved: fork kept"           "yes" "$([ -f "$(dirname "$FB")/$FORK.jsonl" ] && echo yes || echo no)"

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

# Keep both, but no new session shows up in the supervisor → nothing written.
H=88880000-1111-2222-3333-444444444444
FH=$(mk_session mac "$H" "$M/projects/tpg/rakam"); own_elsewhere "$H" "$FH"; echo '{"uuid":"late"}' >> "$FH"
touch "$MTMP/nofork"; : > "$MTMP/claude.log"
rc=0; echo g | SESSION_FORK_WAIT=1 on mac session-diverge "$H" >/dev/null 2>&1 || rc=$?
rm -f "$MTMP/nofork"
assert_eq "keep both, no fork: fails"         "1"   "$rc"
assert_eq "keep both, no fork: original kept" "yes" "$([ -f "$FH" ] && echo yes || echo no)"
assert_eq "keep both, no fork: no link"       "{}"  "$(forks_json)"
assert_eq "keep both, no fork: no attach"     "no"  "$(grep -q attach "$MTMP/claude.log" && echo yes || echo no)"

# Keep both while another session starts elsewhere → the same-cwd one is the fork.
P=44440000-1111-2222-3333-444444444444
FP=$(mk_session mac "$P" "$M/projects/tpg/rakam"); own_elsewhere "$P" "$FP"; echo '{"uuid":"late"}' >> "$FP"
mkdir -p "$M/projects/tpg/other"; echo "$M/projects/tpg/other" > "$MTMP/extra.agent"
rm -f "$(dirname "$FP")/$FORK.jsonl"; echo '[]' > "$M/.agents.json"; : > "$MTMP/claude.log"
echo g | on mac session-diverge "$P" >/dev/null 2>&1
assert_eq "fork by cwd: same-cwd one linked" "{'$P': '$FORK'}" "$(forks_json)"
assert_eq "fork by cwd: attached to it"      "mac attach f0f0f0f0" "$(tail -1 "$MTMP/claude.log")"
# That fork dies unsaved (gone from the supervisor, no transcript) → link dropped,
# the original stays, still diverged.
echo '[]' > "$M/.agents.json"
on mac session-reconcile >/dev/null 2>&1
assert_eq "dead fork: link dropped"      "{}"  "$(forks_json)"
assert_eq "dead fork: original kept"     "yes" "$([ -f "$FP" ] && echo yes || echo no)"
assert_eq "dead fork: still diverged"    "yes" "$(diverged_list | tr ' ' '\n' | grep -qx "$P" && echo yes || echo no)"
# Supervisor unreadable → a pending link is kept.
echo "{\"$P\": \"$FORK\"}" > "$M/.claude/session-forks.json"; echo garbage > "$M/.agents.json"
on mac session-reconcile >/dev/null 2>&1 || true
assert_eq "supervisor error: link kept"  "{'$P': '$FORK'}" "$(forks_json)"
echo '{}' > "$M/.claude/session-forks.json"

# Two new sessions elsewhere, none in this cwd → no guess, nothing written.
printf '%s\n' "$M/projects/tpg/other" "$M" > "$MTMP/extra.agent"
touch "$MTMP/nofork"; echo '[]' > "$M/.agents.json"; : > "$MTMP/claude.log"
rc=0; echo g | SESSION_FORK_WAIT=1 on mac session-diverge "$P" >/dev/null 2>&1 || rc=$?
rm -f "$MTMP/nofork" "$MTMP/extra.agent"; echo '[]' > "$M/.agents.json"
assert_eq "fork ambiguous: fails"         "1"   "$rc"
assert_eq "fork ambiguous: no link"       "{}"  "$(forks_json)"
assert_eq "fork ambiguous: no attach"     "no"  "$(grep -q attach "$MTMP/claude.log" && echo yes || echo no)"
assert_eq "fork ambiguous: original kept" "yes" "$([ -f "$FP" ] && echo yes || echo no)"

# Supervisor, several ids in one read.
echo "[{\"sessionId\":\"$C\",\"pid\":7},{\"sessionId\":\"$D\",\"state\":\"stopped\"}]" > "$M/.agents.json"
assert_eq "agents-state multi-id" "$C running|$D stopped|$E unknown" \
  "$(on mac session-agents-state "$C" "$D" "$E" | paste -sd'|' -)"
assert_eq "agents-state single id unchanged" "running" "$(on mac session-agents-state "$C")"
echo garbage > "$M/.agents.json"
rc=0; out=$(on mac session-agents-state "$C" "$D" 2>/dev/null) || rc=$?
assert_eq "agents-state multi-id error" "1 error" "$rc $out"
echo '[]' > "$M/.agents.json"

# Same id under two project dirs → diverged, neither copy trashed.
I=77770000-1111-2222-3333-444444444444
FI=$(mk_session mac "$I" "$M/projects/tpg/rakam"); own_elsewhere "$I" "$FI"
mkdir -p "$M/projects/tpg/other"; FI2=$(mk_session mac "$I" "$M/projects/tpg/other")
on mac session-reconcile >/dev/null 2>&1
assert_eq "duplicate id → both kept"   "yes yes" "$([ -f "$FI" ] && echo yes || echo no) $([ -f "$FI2" ] && echo yes || echo no)"
assert_eq "duplicate id → diverged"    "yes" "$(diverged_list | tr ' ' '\n' | grep -qx "$I" && echo yes || echo no)"

# A malformed meta entry is skipped, the rest is still settled.
J=66660000-1111-2222-3333-444444444444
FJ=$(mk_session mac "$J" "$M/projects/tpg/rakam"); own_elsewhere "$J" "$FJ"
K=55550000-1111-2222-3333-444444444444
FK=$(mk_session mac "$K" "$M/projects/tpg/rakam")
echo '[]' > "$M/.claude/session-hub/meta/$K.json"
rc=0; on mac session-reconcile >/dev/null 2>&1 || rc=$?
assert_eq "malformed meta → run ok"      "0"   "$rc"
assert_eq "malformed meta → kept"        "yes" "$([ -f "$FK" ] && echo yes || echo no)"
assert_eq "malformed meta → others done" "no"  "$([ -f "$FJ" ] && echo yes || echo no)"
machines_teardown
