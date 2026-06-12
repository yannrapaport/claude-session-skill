#!/usr/bin/env bash
# tests/test_registry.sh — sourced by run_tests.sh

echo "--- test_registry ---"

TMPDIR_REG=$(mktemp -d)
export HUB_DIR_OVERRIDE="$TMPDIR_REG"

# Test set then get round-trip
session-registry-set "abc-123" "nexus" "projects/foo"
RESULT=$(session-registry-get "abc-123")

MACHINE=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['current_machine'])")
PROJECT=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['project_relative'])")

assert_eq "registry set/get machine" "nexus" "$MACHINE"
assert_eq "registry set/get project" "projects/foo" "$PROJECT"

# Test missing session returns empty object
MISSING=$(session-registry-get "does-not-exist")
assert_eq "missing session returns empty" "{}" "$MISSING"

rm -rf "$TMPDIR_REG"
unset HUB_DIR_OVERRIDE
