#!/usr/bin/env bash
# tests/test_replicate.sh — sourced by run_tests.sh
echo "--- test_replicate ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
SID=cccccccc-1111-2222-3333-444444444444
F=$(mk_session mac "$SID" "$MTMP/mac/projects/tpg/rakam")
mkdir -p "${F%.jsonl}/subagents" "$MTMP/mac/.claude/file-history/$SID"
echo x > "${F%.jsonl}/subagents/a.jsonl"; echo v1 > "$MTMP/mac/.claude/file-history/$SID/f@v1"
REP="$MTMP/nexus/.claude/session-replica/mac/$SID"

on mac session-replicate "$SID"
assert_eq "replica jsonl"        "yes" "$([ -f "$REP/$SID.jsonl" ] && echo yes || echo no)"
assert_eq "replica session dir"  "yes" "$([ -f "$REP/$SID/subagents/a.jsonl" ] && echo yes || echo no)"
assert_eq "replica file-history" "yes" "$([ -f "$REP/file-history/f@v1" ] && echo yes || echo no)"
assert_eq "replica source.json subject" "tpg" \
  "$(python3 -c "import json;print(json.load(open('$REP/source.json'))['cc_subject'])")"

# Nexus has no replica_to: no-op.
rc=0; on nexus session-replicate >/dev/null 2>&1 || rc=$?
assert_eq "nexus replicate is a no-op" "0" "$rc"
# Peer down: silent success, nothing breaks.
down nexus; rc=0; on mac session-replicate "$SID" || rc=$?; up nexus
assert_eq "peer down: silent" "0" "$rc"
# Headless sessions are not replicated.
H=$(mk_session mac dddddddd-0000 "$MTMP/mac/projects/tpg")
sed -i.bak 's/"entrypoint":"cli"/"entrypoint":"sdk-cli"/' "$H"; rm -f "$H.bak"
on mac session-replicate
assert_eq "headless skipped" "no" \
  "$([ -d "$MTMP/nexus/.claude/session-replica/mac/dddddddd-0000" ] && echo yes || echo no)"
# Owned elsewhere → not replicated anymore.
on mac session-metastore set "$SID" owner '"nexus"'
rm -rf "$REP"; on mac session-replicate "$SID"
assert_eq "owned by nexus: not replicated" "no" "$([ -d "$REP" ] && echo yes || echo no)"
# Prune: replica of a session gone from the Mac (and not owned by nexus) is removed.
on mac session-metastore set "$SID" owner null
on mac session-replicate "$SID"
rm -f "$F"; rm -rf "${F%.jsonl}"
on mac session-replicate
assert_eq "prune replica of vanished session" "no" "$([ -d "$REP" ] && echo yes || echo no)"

# Stop hook: returns fast, always 0, replica shows up detached.
mk_session mac "$SID" "$MTMP/mac/projects/tpg/rakam" >/dev/null
rm -rf "$REP"
HOOK="$SCRIPT_DIR/../hooks/stop-replicate"
SECONDS=0; rc=0
printf '{"session_id":"%s"}' "$SID" | on mac env SESSION_BIN="$SCRIPT_DIR/../bin" bash "$HOOK" || rc=$?
assert_eq "hook exits 0" "0" "$rc"
assert_eq "hook returns quickly" "yes" "$([ "$SECONDS" -lt 3 ] && echo yes || echo no)"
for _ in $(seq 50); do [ -f "$REP/source.json" ] && break; sleep 0.1; done
assert_eq "hook replicates detached" "yes" "$([ -f "$REP/source.json" ] && echo yes || echo no)"
rc=0; printf 'garbage' | on mac env SESSION_BIN="$SCRIPT_DIR/../bin" bash "$HOOK" || rc=$?
assert_eq "hook: bad stdin still exits 0" "0" "$rc"

# A failed copy records no state; a later run replicates.
SID2=eeeeeeee-1111-2222-3333-444444444444
mk_session mac "$SID2" "$MTMP/mac/projects/tpg/rakam" >/dev/null
touch "$MTMP/fail.rsync"; on mac session-replicate >/dev/null 2>&1 || true; rm -f "$MTMP/fail.rsync"
assert_eq "failed copy: no state entry" "" \
  "$(python3 -c "import json;print(json.load(open('$MTMP/mac/.claude/session-replica-state.json')).get('$SID2',''))")"
on mac session-replicate >/dev/null 2>&1
assert_eq "retry replicates" "yes" "$([ -f "$MTMP/nexus/.claude/session-replica/mac/$SID2/source.json" ] && echo yes || echo no)"

# Prune guards: no local projects/ -> nothing pruned; odd names untouched.
mkdir -p "$MTMP/nexus/.claude/session-replica/mac/..x" "$MTMP/nexus/.claude/session-replica/mac/a b"
mv "$MTMP/mac/.claude/projects" "$MTMP/mac/.claude/projects.away"
on mac session-replicate >/dev/null 2>&1 || true
assert_eq "no projects/: no prune" "yes" "$([ -d "$MTMP/nexus/.claude/session-replica/mac/$SID2" ] && echo yes || echo no)"
mv "$MTMP/mac/.claude/projects.away" "$MTMP/mac/.claude/projects"
on mac session-replicate >/dev/null 2>&1 || true
assert_eq "odd name '..x' untouched" "yes" "$([ -d "$MTMP/nexus/.claude/session-replica/mac/..x" ] && echo yes || echo no)"
assert_eq "odd name 'a b' untouched" "yes" "$([ -d "$MTMP/nexus/.claude/session-replica/mac/a b" ] && echo yes || echo no)"
machines_teardown
