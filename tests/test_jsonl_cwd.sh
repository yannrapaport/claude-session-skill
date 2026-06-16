#!/usr/bin/env bash
# tests/test_jsonl_cwd.sh — sourced by run_tests.sh
echo "--- test_jsonl_cwd ---"
TMP=$(mktemp -d)
cat > "$TMP/s.jsonl" << 'EOF'
{"type":"summary","summary":"x"}
{"type":"user","cwd":"/Users/yannrapaport/projects/foo","message":{"role":"user","content":"hi"}}
EOF
assert_eq "jsonl-cwd reads cwd" "/Users/yannrapaport/projects/foo" "$(session-jsonl-cwd "$TMP/s.jsonl")"
# empty when absent
echo '{"type":"summary"}' > "$TMP/n.jsonl"
assert_eq "jsonl-cwd empty when absent" "" "$(session-jsonl-cwd "$TMP/n.jsonl")"
# empty when file not found
assert_eq "jsonl-cwd empty when file missing" "" "$(session-jsonl-cwd /nonexistent/path.jsonl)"
# empty when no arg
assert_eq "jsonl-cwd empty when no arg" "" "$(session-jsonl-cwd)"
rm -rf "$TMP"
