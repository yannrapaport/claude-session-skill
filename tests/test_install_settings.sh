#!/usr/bin/env bash
# tests/test_install_settings.sh — sourced by run_tests.sh
echo "--- test_install_settings ---"
TMP=$(mktemp -d); S="$TMP/settings.json"; H="/x/hooks/stop-replicate"
_get() { python3 -c "import json;s=json.load(open('$S'));print($1)"; }

session-install-settings "$S" "$H" 0 >/dev/null
assert_eq "creates file, retention 365" "365" "$(_get "s['cleanupPeriodDays']")"
assert_eq "no hook when replica_to absent" "False" "$(_get "'hooks' in s")"

echo '{"cleanupPeriodDays": 30, "theme": "dark"}' > "$S"
session-install-settings "$S" "$H" 1 >/dev/null
assert_eq "raises 30 to 365" "365" "$(_get "s['cleanupPeriodDays']")"
assert_eq "preserves other settings" "dark" "$(_get "s['theme']")"
assert_eq "adds hook" "1" "$(_get "len(s['hooks']['Stop'])")"
session-install-settings "$S" "$H" 1 >/dev/null
assert_eq "hook idempotent" "1" "$(_get "len(s['hooks']['Stop'])")"

echo '{"cleanupPeriodDays": 9999, "hooks": {"Stop": [{"hooks": [{"type":"command","command":"other"}]}]}}' > "$S"
session-install-settings "$S" "$H" 1 >/dev/null
assert_eq "does not lower retention" "9999" "$(_get "s['cleanupPeriodDays']")"
assert_eq "keeps existing hook, adds ours" "2" "$(_get "len(s['hooks']['Stop'])")"
rm -rf "$TMP"
