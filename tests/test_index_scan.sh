#!/usr/bin/env bash
# tests/test_index_scan.sh — sourced by run_tests.sh
echo "--- test_index_scan ---"
TMP=$(mktemp -d)
export CLAUDE_DIR="$TMP/claude"
export HUB_DIR_OVERRIDE="$TMP/hub"
mkdir -p "$HUB_DIR_OVERRIDE"
# Stub config: machine=mac, home=$TMP/home. Stub hub-push to a no-op.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/session-config" << EOF
#!/usr/bin/env bash
case "\$1" in
  machine) echo mac ;;
  home) echo "$TMP/home" ;;
  *) echo "" ;;
esac
EOF
cat > "$STUB/session-hub-push" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$STUB/session-hub-sync" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*
_SAVED_PATH="$PATH"
export PATH="$STUB:$PATH"
# A project transcript under the encoded dir.
PROJ="$TMP/home/projects/foo"
ENC=$(session-encode-path "$PROJ")
mkdir -p "$CLAUDE_DIR/projects/$ENC"
cat > "$CLAUDE_DIR/projects/$ENC/sid-aaa.jsonl" << EOF
{"type":"user","cwd":"$PROJ","message":{"role":"user","content":"Build the thing"}}
EOF

session-index-scan

REG="$HUB_DIR_OVERRIDE/registry.json"
PR=$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-aaa']['project_relative'])")
SUB=$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-aaa']['subject'])")
CWD=$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-aaa']['cwd'])")
assert_eq "scan sets project_relative" "projects/foo" "$PR"
assert_eq "scan sets subject" "Build the thing" "$SUB"
assert_eq "scan sets cwd" "$PROJ" "$CWD"

# Pruning: delete the jsonl, rescan -> entry gone.
rm "$CLAUDE_DIR/projects/$ENC/sid-aaa.jsonl"
session-index-scan
GONE=$(python3 -c "import json;d=json.load(open('$REG'));print('sid-aaa' in d['machines'].get('mac',{}))")
assert_eq "scan prunes purged session" "False" "$GONE"

rm -rf "$TMP"
unset CLAUDE_DIR HUB_DIR_OVERRIDE
export PATH="$_SAVED_PATH"; unset _SAVED_PATH
