#!/usr/bin/env bash
# Claude Session Skill — installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yannrapaport/claude-session-skill/main/install.sh | bash
#   wget -qO- https://raw.githubusercontent.com/yannrapaport/claude-session-skill/main/install.sh | bash
#   bash install.sh            (from within the cloned repo)
#   bash install.sh --force    (overwrite existing config)

set -euo pipefail

REPO="https://github.com/yannrapaport/claude-session-skill.git"
INSTALL_DIR="$HOME/.claude/skills/session"
CONFIG="$HOME/.claude/session-migrate.yml"

# ── 1. Install / update skill files ──────────────────────────────────────────

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "↻  Updating skill files in $INSTALL_DIR..."
  git -C "$INSTALL_DIR" pull --rebase --quiet
else
  echo "↓  Cloning skill into $INSTALL_DIR..."
  git clone --quiet "$REPO" "$INSTALL_DIR"
fi

BIN_DIR="$INSTALL_DIR/bin"

# ── 2. Add bin/ to PATH ───────────────────────────────────────────────────────

PROFILE=""
for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$f" ] && { PROFILE="$f"; break; }
done

PATH_ENTRY="export PATH=\"\$HOME/.claude/skills/session/bin:\$PATH\""

if [ -n "$PROFILE" ]; then
  if grep -q "skills/session/bin" "$PROFILE" 2>/dev/null; then
    echo "✓  PATH already set in $PROFILE"
  else
    printf '\n# Claude session skill\n%s\n' "$PATH_ENTRY" >> "$PROFILE"
    echo "✓  Added session/bin to PATH in $PROFILE"
  fi
else
  echo "⚠  No shell profile found — add this manually:"
  echo "   $PATH_ENTRY"
fi

# ── 3. Create config ──────────────────────────────────────────────────────────

if [ -f "$CONFIG" ] && [ "${1:-}" != "--force" ]; then
  echo "✓  Config already exists at $CONFIG"
else
  echo ""
  echo "Configure this machine (Enter to accept defaults):"
  echo ""
  read -rp "  Hub URL (private git repo for sessions): " hub
  machine_default=$(hostname -s 2>/dev/null || echo "my-machine")
  read -rp "  Machine name [$machine_default]: " machine_input
  machine="${machine_input:-$machine_default}"
  read -rp "  Home path [$HOME]: " home_input
  home="${home_input:-$HOME}"

  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" << EOF
hub: $hub
machine: $machine
home: $home
EOF
  echo "✓  Config written to $CONFIG"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "✓  Installation complete."
echo ""
echo "Next steps:"
echo "  1. source $PROFILE   (or open a new terminal)"
echo "  2. session-config hub          # verify config reads correctly"
echo "  3. /session:migrate <target>   # from Claude Code"
