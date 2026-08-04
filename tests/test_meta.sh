#!/usr/bin/env bash
# tests/test_meta.sh — sourced by run_tests.sh
echo "--- test_meta ---"
TMP=$(mktemp -d)

field() { session-meta "$1" | cut -f"$2"; }

# Interactive session: entrypoint cli, custom title wins over the first message,
# turns counted, branch taken from the latest line that carries one.
cat > "$TMP/i.jsonl" << 'EOF'
{"type":"user","entrypoint":"cli","gitBranch":"main","message":{"role":"user","content":"<command-name>/foo</command-name>"}}
{"type":"user","gitBranch":"main","message":{"role":"user","content":"Porter fitness sur Workbench"}}
{"type":"assistant","message":{"role":"assistant","content":"ok"}}
{"type":"user","gitBranch":"feat/x","message":{"role":"user","content":"continue"}}
{"type":"custom-title","customTitle":"fitness"}
EOF
assert_eq "meta entrypoint cli"    "cli"                          "$(field "$TMP/i.jsonl" 1)"
assert_eq "meta title from custom" "fitness"                      "$(field "$TMP/i.jsonl" 2)"
assert_eq "meta subject skips meta" "Porter fitness sur Workbench" "$(field "$TMP/i.jsonl" 3)"
assert_eq "meta counts user turns" "3"                            "$(field "$TMP/i.jsonl" 4)"
assert_eq "meta latest git branch" "feat/x"                       "$(field "$TMP/i.jsonl" 6)"

# No custom-title: the subject stands in as the title.
cat > "$TMP/n.jsonl" << 'EOF'
{"type":"user","entrypoint":"cli","message":{"role":"user","content":"Fix the login bug"}}
EOF
assert_eq "meta title falls back to subject" "Fix the login bug" "$(field "$TMP/n.jsonl" 2)"

# Headless run: entrypoint reported, and the walk stops there — so nothing
# after the entrypoint line is read (title/subject/turns stay empty).
cat > "$TMP/h.jsonl" << 'EOF'
{"type":"user","entrypoint":"sdk-cli","message":{"role":"user","content":"You extract structured data from ONE e-commerce email"}}
{"type":"user","message":{"role":"user","content":"more"}}
EOF
assert_eq "meta flags sdk-cli"     "sdk-cli" "$(field "$TMP/h.jsonl" 1)"
assert_eq "meta stops on headless" ""        "$(field "$TMP/h.jsonl" 3)"

# Block-array content is read like a plain string.
cat > "$TMP/a.jsonl" << 'EOF'
{"type":"user","entrypoint":"cli","message":{"role":"user","content":[{"type":"text","text":"Fix the login bug"}]}}
EOF
assert_eq "meta reads block content" "Fix the login bug" "$(field "$TMP/a.jsonl" 3)"

# A numeric menu answer is not a subject; the real message behind it is.
cat > "$TMP/m.jsonl" << 'EOF'
{"type":"user","entrypoint":"cli","message":{"role":"user","content":"10"}}
{"type":"user","message":{"role":"user","content":"Reprends le chantier sessions"}}
EOF
assert_eq "meta skips numeric menu answer" "Reprends le chantier sessions" "$(field "$TMP/m.jsonl" 3)"

# Missing file: a well-formed empty row, never an error.
assert_eq "meta tolerates missing file" "6" "$(session-meta "$TMP/nope.jsonl" | awk -F'\t' '{print NF}')"

# Tabs inside a subject would break the TSV contract.
printf '{"type":"user","entrypoint":"cli","message":{"role":"user","content":"a\\tb"}}\n' > "$TMP/t.jsonl"
assert_eq "meta strips tabs from fields" "6" "$(session-meta "$TMP/t.jsonl" | awk -F'\t' '{print NF}')"

# A detached checkout reports gitBranch "HEAD" — that names no branch.
cat > "$TMP/d.jsonl" << 'EOF'
{"type":"user","entrypoint":"cli","gitBranch":"HEAD","message":{"role":"user","content":"detached"}}
EOF
assert_eq "meta drops HEAD as a branch" "" "$(field "$TMP/d.jsonl" 6)"

rm -rf "$TMP"
