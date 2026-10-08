# tests/lib_machines.sh — two fake machines for cross-machine tests.
# Sourced by the tests that need it (no test_ prefix: run_tests.sh skips it).
#   machines_setup          $MTMP with mac/ and nexus/ homes, a bare hub, stubs
#   on <machine> <cmd...>   run cmd as that machine (HOME, config, hub, claude dir)
#   down <m> / up <m>       make ssh/rsync to <m> fail / succeed
#   machines_teardown
REAL_RSYNC=$(command -v rsync)
export REAL_RSYNC

machines_setup() {
  # Resolved: macOS mktemp lives under /var → /private/var, and the tools
  # compare real paths.
  MTMP=$(cd "$(mktemp -d)" && pwd -P); export MTMP
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q --bare "$MTMP/hub.git"
  git -C "$MTMP/hub.git" symbolic-ref HEAD refs/heads/main
  local seed="$MTMP/seed"
  git init -q "$seed"; git -C "$seed" checkout -q -b main
  echo '{"version": 2, "machines": {}}' > "$seed/registry.json"
  git -C "$seed" add -A; git -C "$seed" commit -qm seed
  git -C "$seed" push -q "$MTMP/hub.git" main
  local m o h
  for m in mac nexus; do
    h="$MTMP/$m"; o=$([ "$m" = mac ] && echo nexus || echo mac)
    mkdir -p "$h/.claude/projects" "$h/projects/tpg/rakam"
    printf 'typeset -A CC_DIRS=(\n  tpg $HOME/projects/tpg\n)\n' > "$h/subjects.zsh"
    cat > "$h/.claude/session-migrate.yml" <<EOF
hub: $MTMP/hub.git
machine: $m
home: $h
peer_$o: $o
subjects_file: $h/subjects.zsh
EOF
    echo '[]' > "$h/.agents.json"
  done
  echo "replica_to: nexus" >> "$MTMP/mac/.claude/session-migrate.yml"
  mkdir -p "$MTMP/stub"

  cat > "$MTMP/stub/ssh" <<'EOF'
#!/usr/bin/env bash
# ssh stub: [-o x]... [-q|-T] <peer> [cmd...] — runs cmd as <peer> under $MTMP.
while :; do case "${1:-}" in -o) shift 2 ;; -q|-T) shift ;; *) break ;; esac; done
peer="$1"; shift
[ -e "$MTMP/down.$peer" ] && { echo "ssh: connect to host $peer: Operation timed out" >&2; exit 255; }
[ $# -eq 0 ] && exit 0
cd "$MTMP/$peer" && exec env -u CLAUDE_DIR -u HUB_DIR_OVERRIDE -u CONFIG HOME="$MTMP/$peer" bash -c "$*"
EOF

  cat > "$MTMP/stub/rsync" <<'EOF'
#!/usr/bin/env bash
# rsync stub: "<peer>:<path>" → $MTMP/<peer>/<path> (relative paths from that home).
args=()
for a in "$@"; do
  case "$a" in
    mac:*|nexus:*)
      p="${a%%:*}"
      [ -e "$MTMP/down.$p" ] && { echo "rsync: connection to $p failed" >&2; exit 255; }
      r="${a#*:}"; case "$r" in /*) ;; *) r="$MTMP/$p/$r" ;; esac
      args+=("$r") ;;
    *) args+=("$a") ;;
  esac
done
exec "$REAL_RSYNC" "${args[@]}"
EOF

  cat > "$MTMP/stub/claude" <<'EOF'
#!/usr/bin/env bash
# claude stub: logs "<machine> <argv>" to $MTMP/claude.log.
# agents → $HOME/.agents.json. --resume --fork-session --bg → creates a fork file.
m=$(basename "$HOME")
echo "$m $*" >> "$MTMP/claude.log"
case "$1" in
  agents) cat "$HOME/.agents.json" ;;
  --resume)
    if [[ " $* " == *" --fork-session "* ]]; then
      enc=$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')
      mkdir -p "$HOME/.claude/projects/$enc"
      echo '{"type":"user","entrypoint":"cli","message":{"role":"user","content":"fork"}}' \
        > "$HOME/.claude/projects/$enc/f0f0f0f0-0000-0000-0000-000000000000.jsonl"
      echo "backgrounded · f0f0f0f0 (idle — send a prompt to start)"
    else
      echo "backgrounded · ${2:0:8} (idle — send a prompt to start)"
    fi ;;
esac
exit 0
EOF

  cat > "$MTMP/stub/tmux" <<'EOF'
#!/usr/bin/env bash
# tmux stub: logs argv to $MTMP/tmux.log; answers the two options the tools read.
echo "tmux $*" >> "$MTMP/tmux.log"
case "$*" in
  "show -wv @sessions_main") echo "%1" ;;
  "show -v @sessions_subject") echo "${STUB_SUBJECT:-tpg}" ;;
  has-session*) exit "${STUB_TMUX_HAS:-1}" ;;
  "display -p"*) echo "%1" ;;
esac
exit 0
EOF
  chmod +x "$MTMP/stub/"*
  export PATH="$MTMP/stub:$PATH"
  on mac session-hub-sync >/dev/null 2>&1 || true
  on nexus session-hub-sync >/dev/null 2>&1 || true
}

on() {
  local m="$1"; shift
  ( export HOME="$MTMP/$m"; unset CLAUDE_DIR HUB_DIR_OVERRIDE CONFIG; cd "$HOME"; "$@" )
}
down() { touch "$MTMP/down.$1"; }
up()   { rm -f "$MTMP/down.$1"; }
machines_teardown() { rm -rf "$MTMP"; }

# mk_session <machine> <id> <abs-cwd> [extra jsonl lines...] — a local interactive session.
mk_session() {
  local m="$1" sid="$2" cwd="$3"; shift 3
  local enc; enc=$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')
  local d="$MTMP/$m/.claude/projects/$enc"
  mkdir -p "$d" "$cwd"
  printf '{"type":"user","entrypoint":"cli","uuid":"u1","cwd":"%s","message":{"role":"user","content":"Hello %s"}}\n' "$cwd" "$sid" > "$d/$sid.jsonl"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$d/$sid.jsonl"; done
  echo "$d/$sid.jsonl"
}
