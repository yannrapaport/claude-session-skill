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

# --- Phase B: purge (own fixture) ---
TMP2=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP2"; export CLAUDE_DIR="$TMP2/claude"
export GC_NOW="2026-06-30T00:00:00Z"; export GC_CHECKPOINT_CMD="true"
STUB2="$TMP2/stub"; mkdir -p "$STUB2"
cat > "$STUB2/session-config" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  machine) echo mac ;;
  gc_archive_days) echo 10 ;;
  gc_purge_days) echo 1 ;;
  *) echo "" ;;
esac
EOF
cat > "$STUB2/session-hub-push" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB2"/*; export PATH="$STUB2:$PATH"
PA="$CLAUDE_DIR/p_old"; EA=$(session-encode-path "$PA"); mkdir -p "$CLAUDE_DIR/projects/$EA"
touch -t 202606010000 "$CLAUDE_DIR/projects/$EA/old.jsonl"        # old mtime -> purged
PB="$CLAUDE_DIR/p_new"; EB=$(session-encode-path "$PB"); mkdir -p "$CLAUDE_DIR/projects/$EB"
touch "$CLAUDE_DIR/projects/$EB/fresh.jsonl"                       # new mtime -> kept
cat > "$TMP2/registry.json" << EOF
{ "version":2, "machines": { "mac": {
  "old":   {"project_relative":"p_old","cwd":"$PA","last_activity":"2026-06-01T00:00:00Z","subject":"o","status":"archived"},
  "fresh": {"project_relative":"p_new","cwd":"$PB","last_activity":"2026-06-29T00:00:00Z","subject":"f","status":"archived"}
} } }
EOF
session-gc-sessions >/dev/null
[ -f "$CLAUDE_DIR/projects/$EA/old.jsonl" ] && OLDF=present || OLDF=gone
[ -f "$CLAUDE_DIR/projects/$EB/fresh.jsonl" ] && NEWF=present || NEWF=gone
assert_eq "gc purges old archived jsonl" "gone" "$OLDF"
assert_eq "gc keeps fresh archived jsonl" "present" "$NEWF"
rm -rf "$TMP2"; unset CLAUDE_DIR

export PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd):$PATH"
