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
# --project substring filter: projects/foo matches s1 only (s2 is projects/bar).
NP=$(session-index-view --project projects/foo | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
assert_eq "view --project filter" "1" "$NP"
# --machine mac filter: after dedup, s1.machine=nexus, s2.machine=mac → 1 row.
NM=$(session-index-view --machine mac | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
assert_eq "view --machine filter" "1" "$NM"
# --active filter: both s1 and s2 have status=active → 2 rows.
NA=$(session-index-view --active | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
assert_eq "view --active filter" "2" "$NA"
# 3 machines: dedups to one row; most-recent wins; also_on lists the other two.
cat > "$TMP/registry.json" << 'EOF'
{ "version": 2, "machines": {
  "mac":   { "x": {"project_relative":"p","cwd":"/m/p","last_activity":"2026-01-01T00:00:00Z","subject":"s","status":"active"} },
  "nexus": { "x": {"project_relative":"p","cwd":"/n/p","last_activity":"2026-03-01T00:00:00Z","subject":"s","status":"active"} },
  "pi":    { "x": {"project_relative":"p","cwd":"/p/p","last_activity":"2026-02-01T00:00:00Z","subject":"s","status":"active"} }
} }
EOF
OUT3=$(session-index-view)
N3=$(echo "$OUT3" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")
assert_eq "view 3-machine dedups to one row" "1" "$N3"
M3=$(echo "$OUT3" | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['machine'])")
assert_eq "view 3-machine picks most recent" "nexus" "$M3"
ALSO3=$(echo "$OUT3" | python3 -c "import json,sys;print(','.join(json.load(sys.stdin)[0]['also_on']))")
assert_eq "view 3-machine also_on lists others" "mac,pi" "$ALSO3"
rm -rf "$TMP"; unset HUB_DIR_OVERRIDE
