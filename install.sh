#!/usr/bin/env bash
# install.sh — set up the session skill
# Usage: bash install.sh [--force]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SKILL_DIR/bin"
CONFIG="$HOME/.claude/session-migrate.yml"
PROFILE=""

# Detect shell profile
if [ -f "$HOME/.zshrc" ]; then
  PROFILE="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
  PROFILE="$HOME/.bashrc"
else
  echo "Warning: no .zshrc or .bashrc found — add this to your shell profile manually:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

# Add to PATH
if [ -n "$PROFILE" ]; then
  if grep -q "skills/session/bin" "$PROFILE"; then
    echo "✓ PATH already set in $PROFILE"
  else
    echo "" >> "$PROFILE"
    echo "# Claude session skill" >> "$PROFILE"
    echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$PROFILE"
    echo "✓ Added $BIN_DIR to PATH in $PROFILE"
    echo "  Run: source $PROFILE"
  fi
fi

# Create config if missing
if [ -f "$CONFIG" ] && [ "${1:-}" != "--force" ]; then
  echo "✓ Config already exists at $CONFIG"
else
  echo ""
  echo "Creating $CONFIG..."
  echo "Answer the following (press Enter to accept defaults):"
  echo ""

  read -rp "  Hub URL (git repo for sessions): " hub
  read -rp "  Machine name (e.g. mac, nexus):  " machine
  home_default="$HOME"
  read -rp "  Home path [$home_default]: " home_input
  home="${home_input:-$home_default}"

  cat > "$CONFIG" << EOF
hub: $hub
machine: $machine
home: $home
EOF
  echo "✓ Config written to $CONFIG"
fi

echo ""
echo "Installation complete."
echo "Verify with: session-config hub"
