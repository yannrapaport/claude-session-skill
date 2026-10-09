#!/usr/bin/env bash
# tests/test_panel_launcher.sh — sourced by run_tests.sh: session-panel toggle + dock, against the zellij stub.
echo "--- test_panel_launcher ---"
if ! command -v uv >/dev/null; then
  assert_eq "launcher (skipped: uv absent)" "ok" "ok"
else
  _L=$(mktemp -d); mkdir "$_L/bin"
  cp "$SCRIPT_DIR/panel/zellij-stub" "$_L/bin/zellij"; chmod +x "$_L/bin/zellij"
  echo '[]' > "$_L/tabs.json"
  _launch() {   # _launch <panes-json> → runs session-panel; sets rc, log in $_L/log
    echo "$1" > "$_L/panes.json"; : > "$_L/log"
    rc=0
    PATH="$_L/bin:$PATH" ZELLIJ=0 ZELLIJ_PANE_ID=5 ZELLIJ_SESSION_NAME=cc-tpg CLAUDE_DIR="$_L/claude" \
      ZJ_LOG="$_L/log" ZJ_PANES="$_L/panes.json" ZJ_TABS="$_L/tabs.json" SESSION_PANEL_DRY_RUN=1 \
      uv run --quiet --script "$SCRIPT_DIR/../bin/session-panel" "${@:2}" </dev/null >"$_L/out" 2>&1 || rc=$?
  }
  _launch '[{"id":3,"title":"sessions-panel","is_plugin":false,"is_floating":true},{"id":5,"title":"sessions-panel","is_plugin":false,"is_floating":true}]'
  assert_eq "launcher toggle-off: exit 0" "0" "$rc"
  assert_eq "launcher toggle-off: closes the other panel" "yes" "$(grep -q 'close-pane --pane-id terminal_3' "$_L/log" && echo yes || echo no)"
  assert_eq "launcher toggle-off: no dock" "no" "$(grep -q change-floating-pane-coordinates "$_L/log" && echo yes || echo no)"
  assert_eq "launcher toggle-off: not closing itself" "no" "$(grep -q 'terminal_5' "$_L/log" && echo yes || echo no)"
  _launch '[{"id":5,"title":"sessions-panel","is_plugin":false,"is_floating":true}]'
  assert_eq "launcher dock: exit 0" "0" "$rc"
  assert_eq "launcher dock: docks itself" "yes" "$(grep -q 'change-floating-pane-coordinates --pane-id terminal_5 -x 0 -y 0 --width 36 --height 100%' "$_L/log" && echo yes || echo no)"
  _launch '[{"id":3,"title":"sessions-panel","is_plugin":false,"is_floating":true}]' --docked
  assert_eq "launcher --docked: closes old panel then docks" "yes yes" \
    "$(grep -q 'close-pane --pane-id terminal_3' "$_L/log" && echo -n yes || echo -n no) $(grep -q 'terminal_5 -x 0' "$_L/log" && echo yes || echo no)"
  rm -rf "$_L"
fi
