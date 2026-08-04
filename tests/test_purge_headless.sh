#!/usr/bin/env bash
# tests/test_purge_headless.sh — sourced by run_tests.sh
echo "--- test_purge_headless ---"
TMP=$(mktemp -d)
export CLAUDE_DIR="$TMP/claude"
D="$CLAUDE_DIR/projects/-x"
mkdir -p "$D"
# Stub the rescan the purge triggers: it needs config + a hub we don't have here.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/session-index-scan"
chmod +x "$STUB"/*
_SAVED_PATH="$PATH"; export PATH="$STUB:$PATH"

echo '{"type":"user","entrypoint":"cli","message":{"role":"user","content":"real work"}}'  > "$D/keep.jsonl"
echo '{"type":"user","entrypoint":"sdk-cli","message":{"role":"user","content":"cron"}}'   > "$D/bot.jsonl"
echo '{"type":"user","message":{"role":"user","content":"no entrypoint recorded"}}'        > "$D/old.jsonl"

# Dry run reports the headless one and deletes nothing.
OUT=$(session-purge-headless)
assert_eq "purge dry-run counts headless" "1" "$(echo "$OUT" | grep -c 'Would purge 1 ')"
assert_eq "purge dry-run keeps headless file" "true" "$([ -f "$D/bot.jsonl" ] && echo true)"

# --yes removes only the headless transcript.
session-purge-headless --yes > /dev/null
assert_eq "purge removes headless"        "gone" "$([ -f "$D/bot.jsonl" ]  || echo gone)"
assert_eq "purge keeps interactive"       "true" "$([ -f "$D/keep.jsonl" ] && echo true)"
assert_eq "purge keeps entrypoint-less"   "true" "$([ -f "$D/old.jsonl" ]  && echo true)"

rm -rf "$TMP"; unset CLAUDE_DIR
export PATH="$_SAVED_PATH"; unset _SAVED_PATH
