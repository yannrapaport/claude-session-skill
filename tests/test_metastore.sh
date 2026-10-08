#!/usr/bin/env bash
# tests/test_metastore.sh — sourced by run_tests.sh
echo "--- test_metastore ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup

assert_eq "metastore get absent"  "{}" "$(on mac session-metastore get a1)"
on mac session-metastore set a1 owner '"mac"'
on mac session-metastore set a1 priority '"must"'
assert_eq "metastore get key" "must" \
  "$(on mac session-metastore get a1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["priority"])')"
on mac session-metastore set a1 priority null
assert_eq "metastore null deletes" '{"owner": "mac"}' "$(on mac session-metastore get a1)"
assert_eq "metastore all" '{"a1": {"owner": "mac"}}' "$(on mac session-metastore all)"

# Priority travels through the hub to the other machine.
on mac session-priority a2 should >/dev/null
on nexus session-hub-sync >/dev/null 2>&1
assert_eq "priority reaches nexus" "should" \
  "$(on nexus session-metastore get a2 | python3 -c 'import json,sys;print(json.load(sys.stdin)["priority"])')"
on mac session-priority a2 none >/dev/null
assert_eq "priority none clears" "{}" "$(on mac session-metastore get a2)"
rc=0; on mac session-priority a2 urgent >/dev/null 2>&1 || rc=$?
assert_eq "priority rejects unknown level" "2" "$rc"

machines_teardown
