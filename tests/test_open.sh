#!/usr/bin/env bash
# tests/test_open.sh — sourced by run_tests.sh
echo "--- test_open ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
SID=aaaaaaaa-1111-2222-3333-444444444444
mk_session mac "$SID" "$MTMP/mac/projects/tpg/rakam" >/dev/null

assert_eq "state unknown" "unknown" "$(on mac session-agents-state "$SID")"
echo "[{\"sessionId\":\"$SID\",\"id\":\"aaaaaaaa\",\"state\":\"stopped\"}]" > "$MTMP/mac/.agents.json"
assert_eq "state stopped" "stopped" "$(on mac session-agents-state "$SID")"
echo "[{\"sessionId\":\"$SID\",\"id\":\"aaaaaaaa\",\"pid\":42,\"status\":\"idle\",\"state\":\"blocked\"}]" > "$MTMP/mac/.agents.json"
assert_eq "state running" "running" "$(on mac session-agents-state "$SID")"

# Known to the supervisor → attach only, never --resume --bg (that would fork a copy).
: > "$MTMP/claude.log"
on mac session-open "$SID"
assert_eq "known session: attach only" "mac agents --json --all
mac attach aaaaaaaa" "$(cat "$MTMP/claude.log")"

# Unknown → revive in its own cwd, then attach.
echo '[]' > "$MTMP/mac/.agents.json"; : > "$MTMP/claude.log"
on mac session-open "$SID"
assert_eq "unknown session: revive then attach" "mac agents --json --all
mac --resume $SID --bg
mac attach aaaaaaaa" "$(cat "$MTMP/claude.log")"

rc=0; on nexus session-open "$SID" 2>/dev/null || rc=$?
assert_eq "absent here: refuses" "1" "$rc"
machines_teardown
