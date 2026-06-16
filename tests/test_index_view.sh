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
