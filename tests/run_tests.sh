#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../bin"
export PATH="$BIN_DIR:$PATH"

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"; ((PASS++))
  else
    echo "  FAIL: $desc"
    echo "        expected: '$expected'"
    echo "        actual:   '$actual'"
    ((FAIL++))
  fi
}

echo "=== session skill tests ==="
for f in "$SCRIPT_DIR"/test_*.sh; do
  [ -f "$f" ] && source "$f"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
