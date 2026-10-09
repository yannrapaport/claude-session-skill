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
  _launch '[{"id":3,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":0},{"id":5,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":0}]'
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
  # I2: panel open in another tab → Ctrl+Space here moves it here (close there, dock here), not a toggle-off
  _launch '[{"id":3,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":0},{"id":5,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":1}]'
  assert_eq "launcher other tab: exit 0" "0" "$rc"
  assert_eq "launcher other tab: closes the panel there and docks here" "yes yes" \
    "$(grep -q 'close-pane --pane-id terminal_3' "$_L/log" && echo -n yes || echo -n no) $(grep -q 'terminal_5 -x 0' "$_L/log" && echo yes || echo no)"
  # I6: --docked while the old panel is already closing → close failure ignored, still docks
  ZJ_FAIL=close-pane _launch '[{"id":3,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":0}]' --docked
  assert_eq "launcher --docked close race: exit 0" "0" "$rc"
  assert_eq "launcher --docked close race: still docks" "yes" "$(grep -q 'terminal_5 -x 0' "$_L/log" && echo yes || echo no)"
  # I5: refresh interval from SESSION_PANEL_REFRESH (default 30, bad value → 30)
  SESSION_PANEL_REFRESH=90 _launch '[{"id":5,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":0}]'
  assert_eq "launcher refresh: env honoured" "yes" "$(grep -q 'refresh=90' "$_L/out" && echo yes || echo no)"
  SESSION_PANEL_REFRESH=abc _launch '[{"id":5,"title":"sessions-panel","is_plugin":false,"is_floating":true,"tab_id":0}]'
  assert_eq "launcher refresh: bad value → 30" "yes" "$(grep -q 'refresh=30' "$_L/out" && echo yes || echo no)"
  rm -rf "$_L"
fi

# error path: no Zellij session → French message, non-zero exit, no traceback (stdin at EOF)
_E=$(mktemp -d); mkdir "$_E/bin"; cp "$SCRIPT_DIR/panel/zellij-stub" "$_E/bin/zellij"; chmod +x "$_E/bin/zellij"
if command -v uv >/dev/null; then
  rc=0; _o=$(env -u ZELLIJ -u ZELLIJ_SESSION_NAME PATH="$_E/bin:$PATH" ZJ_LOG="$_E/log" \
    uv run --quiet --script "$SCRIPT_DIR/../bin/session-panel" </dev/null 2>&1) || rc=$?
  assert_eq "launcher error path: non-zero exit" "1" "$rc"
  assert_eq "launcher error path: French message, no traceback" "yes" \
    "$(case "$_o" in *Traceback*) echo no ;; *"Hors d'une session Zellij"*) echo yes ;; *) echo no ;; esac)"
fi
rm -rf "$_E"

# sessions: refuses to nest inside Zellij (needs a tty: script(1), flags differ per OS)
if command -v script >/dev/null; then
  case "$(uname -s)" in
    Darwin) _o=$(ZELLIJ=0 script -q /dev/null sessions 2>&1 </dev/null || true) ;;
    *)      _o=$(ZELLIJ=0 script -qc sessions /dev/null 2>&1 </dev/null || true) ;;
  esac
  case "$_o" in *"Déjà dans Zellij"*) _r=ok ;; *) _r="$_o" ;; esac
  assert_eq "sessions: refuses to nest in Zellij" "ok" "$_r"
else
  assert_eq "sessions nesting (skipped: script absent)" "ok" "ok"
fi
