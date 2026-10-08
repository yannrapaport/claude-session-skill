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
machines_teardown
