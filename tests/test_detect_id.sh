#!/usr/bin/env bash
# tests/test_detect_id.sh — sourced by run_tests.sh

echo "--- test_detect_id ---"

# Setup: create a temp project dir with fake JSONL files
TMPDIR_TEST=$(mktemp -d)
FAKE_HOME="$TMPDIR_TEST/home/testuser"
FAKE_PROJECT="$FAKE_HOME/projects/myapp"
ENCODED=$(session-encode-path "$FAKE_PROJECT")
FAKE_CLAUDE_DIR="$TMPDIR_TEST/.claude/projects/$ENCODED"
mkdir -p "$FAKE_CLAUDE_DIR"

# Create two JSONL files; the newer one should be detected
touch "$FAKE_CLAUDE_DIR/old-session-id.jsonl"
sleep 0.1
touch "$FAKE_CLAUDE_DIR/new-session-id.jsonl"

assert_eq "detects most recent session" \
  "new-session-id" \
  "$(CLAUDE_DIR="$TMPDIR_TEST/.claude" session-detect-id "$FAKE_PROJECT")"

rm -rf "$TMPDIR_TEST"
