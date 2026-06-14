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
PLUGIN_CACHE="$HOME/.claude/plugins/cache/claude-session-skill/session/1.0.0"
PLUGIN_MARKETPLACE="$HOME/.claude/plugins/marketplaces/claude-session-skill"

# ── 1. Install / update skill files ──────────────────────────────────────────

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "↻  Updating skill files in $INSTALL_DIR..."
  git -C "$INSTALL_DIR" pull --rebase --quiet
else
  echo "↓  Cloning skill into $INSTALL_DIR..."
  git clone --quiet "$REPO" "$INSTALL_DIR"
fi

BIN_DIR="$INSTALL_DIR/bin"

# ── 2b. Register as Claude Code plugin ───────────────────────────────────────

rm -rf "$PLUGIN_CACHE"
mkdir -p "$PLUGIN_CACHE"
cp -r "$INSTALL_DIR/plugins/session/." "$PLUGIN_CACHE/"
ln -sfn "$INSTALL_DIR" "$PLUGIN_MARKETPLACE"
echo "✓  Plugin files copied to cache"

PLUGINS_DIR="$HOME/.claude/plugins"
NOW=$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")

python3 - "$PLUGINS_DIR" "$NOW" << 'PYEOF'
import json, sys, os
plugins_dir, now = sys.argv[1], sys.argv[2]

km_path = os.path.join(plugins_dir, "known_marketplaces.json")
km = json.load(open(km_path)) if os.path.exists(km_path) else {}
km["claude-session-skill"] = {
    "source": {"source": "github", "repo": "yannrapaport/claude-session-skill"},
    "installLocation": os.path.join(os.path.expanduser("~"), ".claude/plugins/marketplaces/claude-session-skill"),
    "lastUpdated": now
}
json.dump(km, open(km_path, "w"), indent=2)

ip_path = os.path.join(plugins_dir, "installed_plugins.json")
ip = json.load(open(ip_path)) if os.path.exists(ip_path) else {"version": 2, "plugins": {}}
cache_path = os.path.join(os.path.expanduser("~"), ".claude/plugins/cache/claude-session-skill/session/1.0.0")
ip.setdefault("plugins", {})["session@claude-session-skill"] = [{
    "scope": "user", "installPath": cache_path,
    "version": "1.0.0", "installedAt": now, "lastUpdated": now
}]
json.dump(ip, open(ip_path, "w"), indent=2)
print("✓  Registered Claude Code plugin (session@claude-session-skill)")
PYEOF

# Enable the plugin via the native CLI (robust across settings.json variants)
if claude plugin enable session@claude-session-skill >/dev/null 2>&1; then
  echo "✓  Plugin enabled (session@claude-session-skill)"
else
  echo "⚠  Could not auto-enable. Run manually:  claude plugin enable session@claude-session-skill"
fi

# ── 3. Add bin/ to PATH ───────────────────────────────────────────────────────

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

# ── 4. Create config ──────────────────────────────────────────────────────────

NEED_CONFIG_EDIT=false

if [ -f "$CONFIG" ] && [ "${1:-}" != "--force" ]; then
  echo "✓  Config already exists at $CONFIG"
else
  machine_default=$(hostname -s 2>/dev/null || echo "my-machine")

  if [ -t 0 ]; then
    # Interactive terminal — prompt for values
    echo ""
    echo "Configure this machine (Enter to accept defaults):"
    echo ""
    read -rp "  Hub URL (private git repo for sessions): " hub
    read -rp "  Machine name [$machine_default]: " machine_input
    machine="${machine_input:-$machine_default}"
    read -rp "  Home path [$HOME]: " home_input
    home="${home_input:-$HOME}"
  else
    # Non-interactive (curl | bash) — write placeholders, ask user to edit
    hub="EDIT_ME"
    machine="$machine_default"
    home="$HOME"
    NEED_CONFIG_EDIT=true
  fi

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
if [ "$NEED_CONFIG_EDIT" = true ]; then
  echo "  2. Edit $CONFIG — set your hub URL:"
  echo "       hub: https://github.com/your-user/claude-sessions.git"
  echo "       machine: $(hostname -s 2>/dev/null || echo "my-machine")"
else
  echo "  2. session-config hub          # verify config reads correctly"
fi
echo "  3. /session:migrate <target>   # from Claude Code"
