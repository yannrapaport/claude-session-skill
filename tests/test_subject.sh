#!/usr/bin/env bash
# tests/test_subject.sh — sourced by run_tests.sh
echo "--- test_subject ---"
TMP=$(mktemp -d)
# First real user msg wins; meta/skill/command wrappers are skipped.
cat > "$TMP/s.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":"<command-name>/foo</command-name>"}}
{"type":"user","message":{"role":"user","content":"Base directory for this skill: /x\n\nstuff"}}
{"type":"user","message":{"role":"user","content":"Consolider la gestion des sessions"}}
EOF
assert_eq "subject skips meta+skill" "Consolider la gestion des sessions" "$(session-subject "$TMP/s.jsonl")"
# content as array of blocks
cat > "$TMP/a.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the login bug"}]}}
EOF
assert_eq "subject reads block content" "Fix the login bug" "$(session-subject "$TMP/a.jsonl")"
# truncation at 80 chars
LONG=$(printf 'x%.0s' {1..100})
echo "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"$LONG\"}}" > "$TMP/l.jsonl"
assert_eq "subject truncates to 80" "80" "$(session-subject "$TMP/l.jsonl" | wc -c | tr -d ' ')"
# Skips a bare-number menu answer, falls through to the real message.
cat > "$TMP/m.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":"10"}}
{"type":"user","message":{"role":"user","content":"Reprends le chantier sessions"}}
EOF
assert_eq "subject skips numeric menu answer" "Reprends le chantier sessions" "$(session-subject "$TMP/m.jsonl")"
# Skips an ai-brain:restore checkpoint-filename selection.
cat > "$TMP/c.jsonl" << 'EOF'
{"type":"user","message":{"role":"user","content":"2026-06-10-0102-refonte-offre-cloud-pricing"}}
{"type":"user","message":{"role":"user","content":"Continue la refonte pricing"}}
EOF
assert_eq "subject skips checkpoint-name answer" "Continue la refonte pricing" "$(session-subject "$TMP/c.jsonl")"
rm -rf "$TMP"
