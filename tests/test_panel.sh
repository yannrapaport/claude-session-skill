#!/usr/bin/env bash
# tests/test_panel.sh — sourced by run_tests.sh: runs the Python panel tests.
echo "--- test_panel ---"
rc=0
( cd "$SCRIPT_DIR/.." && uv run --quiet --with 'textual>=8,<9' --with pytest --with pytest-asyncio \
    pytest -q tests/panel ) || rc=$?
assert_eq "panel pytest" "0" "$rc"
