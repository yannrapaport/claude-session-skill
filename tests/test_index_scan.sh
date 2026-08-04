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

# Rich fields land in the entry alongside the subject.
cat > "$CLAUDE_DIR/projects/$ENC/sid-rich.jsonl" << EOF
{"type":"user","entrypoint":"cli","gitBranch":"feat/x","cwd":"$PROJ","message":{"role":"user","content":"Build the thing"}}
{"type":"user","cwd":"$PROJ","message":{"role":"user","content":"keep going"}}
{"type":"custom-title","customTitle":"the thing"}
EOF
session-index-scan
rich() { python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['sid-rich']['$1'])"; }
assert_eq "scan sets title"      "the thing" "$(rich title)"
assert_eq "scan counts turns"    "2"         "$(rich turns)"
assert_eq "scan sets git_branch" "feat/x"    "$(rich git_branch)"
# A branch that goes away must clear, not linger from the previous scan.
cat > "$CLAUDE_DIR/projects/$ENC/sid-rich.jsonl" << EOF
{"type":"user","entrypoint":"cli","gitBranch":"HEAD","cwd":"$PROJ","message":{"role":"user","content":"Build the thing"}}
EOF
session-index-scan
assert_eq "scan clears a stale branch" "" "$(rich git_branch)"
rm "$CLAUDE_DIR/projects/$ENC/sid-rich.jsonl"

# Headless transcripts are machine traffic — never indexed.
cat > "$CLAUDE_DIR/projects/$ENC/sid-bot.jsonl" << EOF
{"type":"user","entrypoint":"sdk-cli","cwd":"$PROJ","message":{"role":"user","content":"You extract structured data"}}
EOF
session-index-scan
BOT=$(python3 -c "import json;print('sid-bot' in json.load(open('$REG'))['machines']['mac'])")
assert_eq "scan skips headless transcript" "False" "$BOT"
# ...and the interactive one next to it still is.
KEPT=$(python3 -c "import json;print('sid-aaa' in json.load(open('$REG'))['machines']['mac'])")
assert_eq "scan keeps interactive alongside headless" "True" "$KEPT"
rm "$CLAUDE_DIR/projects/$ENC/sid-bot.jsonl"

# Pruning: delete the jsonl, rescan -> entry gone.
rm "$CLAUDE_DIR/projects/$ENC/sid-aaa.jsonl"
session-index-scan
GONE=$(python3 -c "import json;d=json.load(open('$REG'));print('sid-aaa' in d['machines'].get('mac',{}))")
assert_eq "scan prunes purged session" "False" "$GONE"

# Home-dir session (cwd == home) relativizes to "".
HENC=$(session-encode-path "$TMP/home")
mkdir -p "$CLAUDE_DIR/projects/$HENC"
cat > "$CLAUDE_DIR/projects/$HENC/sid-home.jsonl" << EOF
{"type":"user","cwd":"$TMP/home","message":{"role":"user","content":"home session"}}
EOF
session-index-scan
HREL=$(python3 -c "import json;print(repr(json.load(open('$REG'))['machines']['mac']['sid-home']['project_relative']))")
assert_eq "scan relativizes home-dir cwd to empty" "''" "$HREL"

rm -rf "$TMP"
unset CLAUDE_DIR HUB_DIR_OVERRIDE
export PATH="$_SAVED_PATH"; unset _SAVED_PATH
