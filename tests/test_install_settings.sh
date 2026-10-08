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

# install.sh wires the hook from the config: only once the config is written.
I="$SCRIPT_DIR/../install.sh"
CFG_LINE=$(grep -n 'cat > "$CONFIG"' "$I" | head -1 | cut -d: -f1)
HOOK_LINE=$(grep -n 'session-install-settings' "$I" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
assert_eq "install.sh: hook wired after the config step" "yes" "$([ "$HOOK_LINE" -gt "$CFG_LINE" ] && echo yes || echo no)"
