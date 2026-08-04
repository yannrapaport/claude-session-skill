#!/usr/bin/env bash
# tests/test_resolve.sh — sourced by run_tests.sh
echo "--- test_resolve ---"
TMP=$(mktemp -d); export HUB_DIR_OVERRIDE="$TMP"
cat > "$TMP/registry.json" << 'EOF'
{ "version": 2, "machines": {
  "mac": {
    "aaa11111": {"project_relative":"projects/foo","cwd":"/Users/y/projects/foo","last_activity":"2026-06-16T00:00:00Z","subject":"foo","status":"active"},
    "aaa22222": {"project_relative":"projects/bar","cwd":"/Users/y/projects/bar","last_activity":"2026-06-15T00:00:00Z","subject":"bar","status":"active"},
    "bbb33333": {"project_relative":"projects/baz","cwd":"/Users/y/projects/baz","last_activity":"2026-06-14T00:00:00Z","subject":"baz","status":"active"}
  }
} }
EOF

# Unique prefix resolves; ambiguity and misses are refused, not guessed at.
assert_eq "resolve unique prefix" "bbb33333" "$(session-resolve bbb)"
assert_eq "resolve full id"       "aaa11111" "$(session-resolve aaa11111)"
session-resolve aaa >/dev/null 2>&1 && AMB=ok || AMB=refused
assert_eq "resolve refuses ambiguous prefix" "refused" "$AMB"
assert_eq "resolve names the ambiguity" "1" \
  "$(session-resolve aaa 2>&1 >/dev/null | grep -c 'matches 2' || true)"
session-resolve zzz >/dev/null 2>&1 && MISS=ok || MISS=refused
assert_eq "resolve refuses unknown prefix" "refused" "$MISS"

# Numbers refer to the last listing, so they only work once one exists.
session-resolve 1 >/dev/null 2>&1 && NOLIST=ok || NOLIST=refused
assert_eq "resolve refuses number with no listing" "refused" "$NOLIST"

# Rows are newest-first, so row 1 is the most recently active session.
cat > "$TMP/last-list.json" << 'EOF'
{"generated":"2026-06-16T00:00:00Z","ids":["aaa11111","aaa22222","bbb33333"]}
EOF
assert_eq "resolve row 1" "aaa11111" "$(session-resolve 1)"
assert_eq "resolve row 3" "bbb33333" "$(session-resolve 3)"
session-resolve 4 >/dev/null 2>&1 && OOR=ok || OOR=refused
assert_eq "resolve refuses out-of-range row" "refused" "$OOR"
session-resolve 0 >/dev/null 2>&1 && ZERO=ok || ZERO=refused
assert_eq "resolve refuses row 0" "refused" "$ZERO"

# No argument at all is a usage error, not an empty success.
session-resolve >/dev/null 2>&1 && NOARG=ok || NOARG=refused
assert_eq "resolve refuses empty arg" "refused" "$NOARG"

rm -rf "$TMP"; unset HUB_DIR_OVERRIDE
