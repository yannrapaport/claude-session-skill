#!/usr/bin/env bash
# tests/test_gc_sessions.sh — sourced by run_tests.sh
echo "--- test_gc_sessions ---"
TMP=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP"
export GC_CHECKPOINT_CMD="true"          # stub the checkpoint
export GC_NOW="2026-06-30T00:00:00Z"     # fixed clock for deterministic ages
# Stub config: machine=mac, archive after 10 days, no purge.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/session-config" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  machine) echo mac ;;
  gc_archive_days) echo 10 ;;
  gc_purge_days) echo 0 ;;
  *) echo "" ;;
esac
EOF
cat > "$STUB/session-hub-push" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*; export PATH="$STUB:$PATH"
cat > "$TMP/registry.json" << 'EOF'
{ "version":2, "machines": { "mac": {
  "old": {"project_relative":"projects/a","cwd":"/h/a","last_activity":"2026-06-01T00:00:00Z","subject":"old","status":"active"},
  "new": {"project_relative":"projects/b","cwd":"/h/b","last_activity":"2026-06-28T00:00:00Z","subject":"new","status":"active"}
} } }
EOF

session-gc-sessions

OLD=$(python3 -c "import json;print(json.load(open('$TMP/registry.json'))['machines']['mac']['old']['status'])")
NEW=$(python3 -c "import json;print(json.load(open('$TMP/registry.json'))['machines']['mac']['new']['status'])")
assert_eq "gc archives stale session" "archived" "$OLD"
assert_eq "gc keeps fresh session active" "active" "$NEW"

rm -rf "$TMP"; unset HUB_DIR_OVERRIDE GC_CHECKPOINT_CMD GC_NOW
export PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd):$PATH"
