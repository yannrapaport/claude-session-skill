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

# settings.json is a symlink into dotfiles on Nexus: write through it, keep the
# link, the target's mode and non-ASCII text as is.
mkdir -p "$TMP/dot"; T="$TMP/dot/settings.json"
printf '{"note": "réglé"}\n' > "$T"; chmod 640 "$T"; rm -f "$S"; ln -s "$T" "$S"
session-install-settings "$S" "$H" 0 >/dev/null
assert_eq "keeps the symlink"        "yes"   "$([ -L "$S" ] && echo yes || echo no)"
assert_eq "writes through to target" "365"   "$(python3 -c "import json;print(json.load(open('$T'))['cleanupPeriodDays'])")"
assert_eq "keeps target mode"        "640"   "$(python3 -c "import os,stat;print(oct(stat.S_IMODE(os.stat('$T').st_mode))[2:])")"
assert_eq "keeps accents unescaped"  "yes"   "$(grep -q 'réglé' "$T" && echo yes || echo no)"

# Malformed settings: refuse with a message, leave the file untouched.
rm -f "$S"; printf '{oops' > "$S"
rc=0; session-install-settings "$S" "$H" 1 >/dev/null 2>"$TMP/err" || rc=$?
assert_eq "malformed: refuses"         "1"     "$rc"
assert_eq "malformed: file untouched"  "{oops" "$(cat "$S")"
assert_eq "malformed: clear message"   "yes"   "$(grep -q 'JSON' "$TMP/err" && echo yes || echo no)"
rm -rf "$TMP"

# install.sh wires the hook from the config: only once the config is written.
I="$SCRIPT_DIR/../install.sh"
CFG_LINE=$(grep -n 'cat > "$CONFIG"' "$I" | head -1 | cut -d: -f1)
HOOK_LINE=$(grep -n 'session-install-settings' "$I" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
assert_eq "install.sh: hook wired after the config step" "yes" "$([ "$HOOK_LINE" -gt "$CFG_LINE" ] && echo yes || echo no)"

# M7: existing Zellij config without the panel keybind → explicit warning + the block to paste.
_Z=$(mktemp -d); mkdir -p "$_Z/zellij"
_zblock() { (XDG_CONFIG_HOME="$_Z" INSTALL_DIR="$SCRIPT_DIR/.." HOME="$_Z"; \
  eval "$(sed -n '/^# ── 4c\. Zellij panel/,/^PROMPTS=/p' "$I" | sed '$d')") 2>&1; }
echo 'keybinds { }' > "$_Z/zellij/config.kdl"
_o=$(_zblock)
assert_eq "install.sh: zellij config lacking the keybind → warning" "yes" \
  "$(case "$_o" in *"⚠"*"sessions-panel"*) echo yes ;; *) echo no ;; esac)"
assert_eq "install.sh: prints the bind block (Ctrl Space + Alt s)" "yes" \
  "$(printf '%s' "$_o" | grep -q 'bind "Ctrl Space" "Alt s"' && echo yes || echo no)"
cp "$SCRIPT_DIR/../zellij/config.kdl" "$_Z/zellij/config.kdl"
assert_eq "install.sh: zellij config with the keybind → no warning" "no" \
  "$(case "$(_zblock)" in *"⚠"*) echo yes ;; *) echo no ;; esac)"
rm -rf "$_Z"
