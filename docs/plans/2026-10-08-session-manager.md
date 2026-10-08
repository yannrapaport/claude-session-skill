# Gestionnaire de sessions cross-machine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lister, prioriser, reprendre et migrer les sessions Claude Code entre le Mac et Nexus — y compris Mac fermé — depuis une liste fzf persistante dans tmux.

**Architecture:** On étend les scripts bash/python de `claude-session-skill` : de nouveaux exécutables dans `bin/`, chacun une responsabilité, testés par le harness `tests/run_tests.sh`. Les décisions (propriétaire, priorité, empreinte) vivent dans `meta/<id>.json` du hub git existant ; les transcripts voyagent par rsync (réplique Mac → Nexus en continu, copie directe quand la source répond). L'interface est un volet fzf qui pilote un volet principal tmux via `respawn-pane`.

**Tech Stack:** bash, python3 (stdlib), zsh (lecture de `CC_DIRS`), git, rsync (openrsync côté Mac : pas de `--mkpath`), fzf ≥ 0.50, tmux ≥ 3.2, Claude Code ≥ 2.1.291 (`claude agents --json --all`, `claude attach`, `--resume --bg`).

**Spec:** `docs/specs/2026-10-08-session-manager-design.md`

## Global Constraints

- Jamais de `rm` d'une session : seulement `mv` vers `~/.claude/session-trash/<YYYY-MM-DD>/<id>/`. Seule la purge de la corbeille (> 30 j) supprime.
- Une session = `projects/<cwd encodé>/<id>.jsonl` + `projects/<cwd encodé>/<id>/` (si présent) + `file-history/<id>/` (si présent).
- Aucune réécriture du contenu d'un JSONL.
- Une migration n'existe qu'une fois poussée dans le hub ; push en échec → rollback complet.
- `--resume <id> --bg` uniquement sur une session **inconnue** du superviseur ; sinon `claude attach <8 premiers caractères>` (sinon copie sous un nouvel id).
- Session « running » = entrée de `claude agents --json --all` avec ce `sessionId` **et** un champ `pid` ou `status` ; présente sans ces champs (state `stopped`/`done`) = « stopped ».
- Sur Nexus, `claude` n'est pas dans le PATH d'un ssh non interactif : préfixe distant `PATH=$HOME/.claude/skills/session/bin:$HOME/.local/bin:$PATH`, et clé de config optionnelle `claude_bin`.
- Pas de `rsync --mkpath` (openrsync Mac) : créer les répertoires distants par `ssh mkdir -p`.
- Messages utilisateur en français ; commentaires et noms en anglais (style du repo).
- Tout nouvel exécutable : `#!/usr/bin/env bash`, `set -euo pipefail`, en-tête de commentaire « Usage + rôle », `chmod +x`.
- Les tests sont *sourcés* dans un même shell `set -euo pipefail` : toute commande censée échouer s'écrit `rc=0; cmd || rc=$?`.

## Review Focus

1. Même id présent sur les deux machines sans `meta/` (reliquat d'anciens `/session:resume` par copie) → la migration doit refuser (« existe déjà ici ») plutôt qu'écraser. Test : Task 7.
2. Écran rabattu en plein tour : la réplique a moins de lignes que le Mac → la migration affiche le retard et exige une confirmation ; au réveil, la copie Mac plus longue est **divergente**, pas mise à la corbeille. Tests : Tasks 7 et 8.
3. Hub injoignable / push refusé pendant une migration → aucun fichier installé ne reste, `meta/` revient à l'état d'avant. Test : Task 7.
4. Session ouverte en interactif (pas en arrière-plan) sur la machine qui réconcilie ou met à la corbeille → jamais déplacée. Test : Task 8.
5. Sujet inconnu ou répertoire absent sur la cible → migration refusée avec message, rien d'installé. Tests : Tasks 3 et 7.

---

## File Structure

| Fichier | Rôle |
|---|---|
| `bin/session-meta` *(modif)* | Titre : custom-title > ai-title > premier prompt (repris de la PR #2). |
| `bin/session-metastore` *(nouveau)* | Lecture/écriture de `meta/<id>.json` dans le hub. |
| `bin/session-priority` *(nouveau)* | Pose la priorité et pousse. |
| `bin/session-subject-roots` *(nouveau)* | `nom\tracine résolue` pour chaque sujet `CC_DIRS` de cette machine. |
| `bin/session-subject-of` *(nouveau)* | Sujet + chemin relatif d'un cwd, sur cette machine. |
| `bin/session-target-cwd` *(nouveau)* | Répertoire d'arrivée d'une session venue d'ailleurs. |
| `bin/session-index-scan` *(modif)* | Enregistre `cc_subject`, `cc_rel`, `diverged` ; lance réconciliation et réplication. |
| `bin/session-agents-state` *(nouveau)* | `running` / `stopped` / `unknown` d'après le superviseur local. |
| `bin/session-open` *(nouveau)* | Primitive de reprise : attach ou revive + attach. |
| `bin/session-rows` *(nouveau)* | Lignes `id\taffichage` pour fzf (tri, périmètre, filtres, marqueurs). |
| `bin/session-tui` *(nouveau)* | Volet liste fzf persistant. |
| `bin/session-tui-act` *(nouveau)* | Actions du volet liste (ouvrir, trier, filtrer, corbeille) → volet principal. |
| `bin/session-home` *(nouveau)* | Contenu par défaut du volet principal (vue agents du sujet). |
| `bin/session-layout` *(nouveau)* | Crée/rejoint la session tmux à deux volets. |
| `bin/sessions` *(modif)* | TTY → `session-layout` ; `--plain` ou pipe → tableau actuel. |
| `bin/session-replicate` *(nouveau)* | Réplique Mac → Nexus (une session ou rattrapage + élagage). |
| `hooks/stop-replicate` *(nouveau)* | Hook `Stop` : réplique la session courante en arrière-plan. |
| `bin/session-fingerprint` *(nouveau)* | Empreinte `{size, sha256, last_uuid}` et test de préfixe. |
| `bin/session-trash` *(nouveau)* | Déplace une session locale vers la corbeille. |
| `bin/session-migrate` *(nouveau)* | Migration vers cette machine. |
| `bin/session-reconcile` *(nouveau)* | Règle les copies locales de sessions possédées ailleurs ; purge la corbeille. |
| `bin/session-diverge` *(nouveau)* | Menu de résolution d'une divergence. |
| `plugins/session/skills/resume/SKILL.md` *(modif)* | Utilise `session-migrate` + `session-open`. |
| `install.sh`, `config.yml.template`, `README.md` *(modif)* | Hook, `cleanupPeriodDays`, clés `subjects_file` / `replica_to` / `claude_bin`, doc. |
| `tests/lib_machines.sh` *(nouveau)* | Harness deux machines (homes, hub bare, stubs ssh/rsync/claude/tmux). |
| `tests/test_*.sh` *(nouveaux)* | Un fichier par exécutable. |
| `~/projects/admin/cc/subjects.zsh`, `cc.zsh`, `test.zsh` *(autre repo)* | `CC_DIRS` sorti du `.zshrc` ; `cc tmux` → `session-layout`. |
| `~/projects/admin/dotfiles/zshrc` *(autre repo)* | Source `subjects.zsh`. |

Travail sur la branche `feat/session-manager`, créée depuis `spec/session-manager`, dans un worktree hors du checkout `~/.claude/skills/session` (les jobs planifiés exécutent ce checkout).

---

### Task 1: Titres auto + métadonnées par session + priorité

**Files:**
- Modify: `bin/session-meta` (repris du commit `feat: generated titles…` de la branche `feat/bg-resume-ai-title`)
- Modify: `tests/test_meta.sh`
- Create: `bin/session-metastore`, `bin/session-priority`
- Create: `tests/lib_machines.sh`, `tests/test_metastore.sh`

**Interfaces:**
- Produces: `session-metastore get <id>` → objet JSON (`{}` si absent) ; `session-metastore set <id> <key> <json>` (valeur JSON, `null` supprime la clé) ; `session-metastore all` → `{id: meta}`. Écrit dans `$HUB_DIR/meta/`, sans commit.
- Produces: `session-priority <id> must|should|may|none` → met à jour `priority`, commit + push (échec de push toléré : le commit part au prochain push).
- Produces (tests) : `machines_setup`, `on <mac|nexus> <cmd…>`, `down <m>`, `up <m>`, `machines_teardown`, variables `MTMP`.

- [ ] **Step 1: Reprendre les titres auto de la PR #2**

```bash
git cherry-pick -n origin/feat/bg-resume-ai-title
git restore --staged --worktree README.md plugins/session/skills/resume/SKILL.md
git status --short   # attendu : M bin/session-meta, M tests/test_meta.sh
```

- [ ] **Step 2: Écrire le harness deux machines**

`tests/lib_machines.sh` :

```bash
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
```

- [ ] **Step 3: Écrire le test du store**

`tests/test_metastore.sh` :

```bash
#!/usr/bin/env bash
# tests/test_metastore.sh — sourced by run_tests.sh
echo "--- test_metastore ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup

assert_eq "metastore get absent"  "{}" "$(on mac session-metastore get s1)"
on mac session-metastore set s1 owner '"mac"'
on mac session-metastore set s1 priority '"must"'
assert_eq "metastore get key" "must" \
  "$(on mac session-metastore get s1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["priority"])')"
on mac session-metastore set s1 priority null
assert_eq "metastore null deletes" '{"owner": "mac"}' "$(on mac session-metastore get s1)"
assert_eq "metastore all" '{"s1": {"owner": "mac"}}' "$(on mac session-metastore all)"

# Priority travels through the hub to the other machine.
on mac session-priority s2 should >/dev/null
on nexus session-hub-sync >/dev/null 2>&1
assert_eq "priority reaches nexus" "should" \
  "$(on nexus session-metastore get s2 | python3 -c 'import json,sys;print(json.load(sys.stdin)["priority"])')"
on mac session-priority s2 none >/dev/null
assert_eq "priority none clears" "{}" "$(on mac session-metastore get s2)"
rc=0; on mac session-priority s2 urgent >/dev/null 2>&1 || rc=$?
assert_eq "priority rejects unknown level" "2" "$rc"

machines_teardown
```

- [ ] **Step 4: Lancer, constater l'échec**

Run: `bash tests/run_tests.sh 2>&1 | grep -E 'metastore|priority|Results'`
Expected: FAIL (`session-metastore: command not found`).

- [ ] **Step 5: Implémenter `bin/session-metastore`**

```bash
#!/usr/bin/env bash
# session-metastore — per-session decisions kept in the hub: meta/<id>.json
#   get <id>               JSON object, {} when absent
#   set <id> <key> <json>  set one key (value is JSON; null removes the key)
#   all                    {id: meta, ...}
# Only writes the working tree; callers commit + push (session-hub-push).
# These files are the decisions (owner, priority, migration fingerprint);
# registry.json stays the per-machine observation written by the scans.
set -euo pipefail
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
python3 - "$HUB_DIR/meta" "$@" << 'PYEOF'
import json, os, sys, tempfile
d, cmd, *a = sys.argv[1:]

def load(i):
    try:
        with open(os.path.join(d, i + ".json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}

if cmd == "get":
    print(json.dumps(load(a[0])))
elif cmd == "set":
    i, k, v = a
    m = load(i)
    v = json.loads(v)
    if v is None:
        m.pop(k, None)
    else:
        m[k] = v
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, i + ".json")
    if not m:
        if os.path.exists(path):
            os.remove(path)        # an empty decision file says nothing
        sys.exit(0)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(m, fh, indent=2, sort_keys=True)
    os.replace(tmp, path)
elif cmd == "all":
    out = {}
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(".json"):
                out[f[:-5]] = load(f[:-5])
    print(json.dumps(out))
else:
    sys.exit(f"session-metastore: unknown command {cmd}")
PYEOF
```

Note : `get` de s2 après `none` doit rendre `{}` — d'où la suppression du fichier vide (et `"metastore null deletes"` garde `{"owner": "mac"}` car il reste une clé).

- [ ] **Step 6: Implémenter `bin/session-priority`**

```bash
#!/usr/bin/env bash
# session-priority <session-id> must|should|may|none — set a session's
# priority (the todo convention) and push it to the hub.
# A failed push is tolerated: the commit leaves with the next scan's push.
set -euo pipefail
SID="${1:?usage: session-priority <id> must|should|may|none}"
P="${2:-}"
case "$P" in
  must|should|may) V="\"$P\"" ;;
  none)            V=null ;;
  *) echo "session-priority: niveau attendu must|should|may|none" >&2; exit 2 ;;
esac
session-hub-sync >/dev/null 2>&1 || true
session-metastore set "$SID" priority "$V"
session-hub-push "prio: ${SID:0:8} $P" >/dev/null 2>&1 || true
```

`chmod +x bin/session-metastore bin/session-priority`

- [ ] **Step 7: Lancer, constater le succès**

Run: `bash tests/run_tests.sh 2>&1 | tail -3`
Expected: `Results: N passed, 0 failed` (77 existants + PR #2 + nouveaux).

- [ ] **Step 8: Commit**

```bash
git add bin/session-meta tests/test_meta.sh bin/session-metastore bin/session-priority tests/lib_machines.sh tests/test_metastore.sh
git commit -m "feat: ai-title in the index, per-session meta store, priority"
```

---

### Task 2: Primitive de reprise (`session-open`) + skill resume

**Files:**
- Create: `bin/session-agents-state`, `bin/session-open`
- Modify: `plugins/session/skills/resume/SKILL.md` (étape 6)
- Create: `tests/test_open.sh`

**Interfaces:**
- Consumes: `tests/lib_machines.sh` (Task 1).
- Produces: `session-agents-state <session-id>` → `running` | `stopped` | `unknown`.
- Produces: `session-open <session-id>` → `exec claude attach <short>` après revive si nécessaire ; exit 1 + message si la session n'est pas sur cette machine.

- [ ] **Step 1: Écrire le test**

`tests/test_open.sh` :

```bash
#!/usr/bin/env bash
# tests/test_open.sh — sourced by run_tests.sh
echo "--- test_open ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
SID=aaaaaaaa-1111-2222-3333-444444444444
mk_session mac "$SID" "$MTMP/mac/projects/tpg/rakam" >/dev/null

assert_eq "state unknown" "unknown" "$(on mac session-agents-state "$SID")"
echo "[{\"sessionId\":\"$SID\",\"id\":\"aaaaaaaa\",\"state\":\"stopped\"}]" > "$MTMP/mac/.agents.json"
assert_eq "state stopped" "stopped" "$(on mac session-agents-state "$SID")"
echo "[{\"sessionId\":\"$SID\",\"id\":\"aaaaaaaa\",\"pid\":42,\"status\":\"idle\",\"state\":\"blocked\"}]" > "$MTMP/mac/.agents.json"
assert_eq "state running" "running" "$(on mac session-agents-state "$SID")"

# Known to the supervisor → attach only, never --resume --bg (that would fork a copy).
: > "$MTMP/claude.log"
on mac session-open "$SID"
assert_eq "known session: attach only" "mac agents --json --all
mac attach aaaaaaaa" "$(cat "$MTMP/claude.log")"

# Unknown → revive in its own cwd, then attach.
echo '[]' > "$MTMP/mac/.agents.json"; : > "$MTMP/claude.log"
on mac session-open "$SID"
assert_eq "unknown session: revive then attach" "mac agents --json --all
mac --resume $SID --bg
mac attach aaaaaaaa" "$(cat "$MTMP/claude.log")"

rc=0; on nexus session-open "$SID" 2>/dev/null || rc=$?
assert_eq "absent here: refuses" "1" "$rc"
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `bash tests/run_tests.sh 2>&1 | grep -E 'test_open|state|attach|Results'`
Expected: FAIL (`session-agents-state: command not found`).

- [ ] **Step 3: Implémenter `bin/session-agents-state`**

```bash
#!/usr/bin/env bash
# session-agents-state <session-id> — what this machine's Claude supervisor
# knows of a session:
#   running  an active process holds it (entry carries a pid or a status)
#   stopped  a background session it remembers, not running (state stopped/done)
#   unknown  never backgrounded here
set -euo pipefail
CLAUDE=$(session-config claude_bin 2>/dev/null || echo claude)
"$CLAUDE" agents --json --all 2>/dev/null | python3 -c '
import json, sys
sid = sys.argv[1]
try:
    d = json.load(sys.stdin)
except ValueError:
    print("unknown"); sys.exit()
d = d if isinstance(d, list) else d.get("sessions", [])
st = "unknown"
for s in d:
    if s.get("sessionId") != sid:
        continue
    if "pid" in s or s.get("status"):
        st = "running"; break
    st = "stopped"
print(st)' "$1"
```

- [ ] **Step 4: Implémenter `bin/session-open`**

```bash
#!/usr/bin/env bash
# session-open <session-id> — open a session that lives on this machine, in
# this terminal.
#   known to the supervisor (running or stopped) → claude attach
#   never backgrounded → revive it in its own cwd with --resume --bg, then attach
# `--resume --bg` on a session the supervisor already knows starts a COPY under
# a new id (verified 2026-10-08), hence the state check first.
set -euo pipefail
SID="${1:?usage: session-open <session-id>}"
SHORT="${SID:0:8}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE=$(session-config claude_bin 2>/dev/null || echo claude)
case "$(session-agents-state "$SID")" in
  running|stopped) exec "$CLAUDE" attach "$SHORT" ;;
esac
shopt -s nullglob
F=("$CLAUDE_DIR"/projects/*/"$SID".jsonl)
[ ${#F[@]} -gt 0 ] || { echo "session-open: $SHORT n'est pas sur cette machine" >&2; exit 1; }
CWD=$(session-jsonl-cwd "${F[0]}")
# A migrated session still records the source machine's cwd; session-migrate
# leaves the local one here (Task 7).
ALT="$CLAUDE_DIR/session-cwd-override/$SID"
[ -f "$ALT" ] && CWD=$(cat "$ALT")
[ -n "$CWD" ] && [ -d "$CWD" ] || { echo "session-open: répertoire de $SHORT introuvable ($CWD)" >&2; exit 1; }
(cd "$CWD" && "$CLAUDE" --resume "$SID" --bg >/dev/null)
exec "$CLAUDE" attach "$SHORT"
```

Le cwd vient du JSONL local, pas du registre : juste après une migration, le registre n'a pas encore été rescanné.

- [ ] **Step 5: Mettre à jour l'étape 6 du skill resume**

Dans `plugins/session/skills/resume/SKILL.md`, remplacer toute la section `### 6. Launch` (et la description en frontmatter) par :

```markdown
### 6. Open it
A skill cannot switch the running session. Hand it to the session manager:
```bash
session-migrate "$SID"    # only if OWNER != THIS; asks before stopping a running source
session-open "$SID"       # attach (or revive in its own cwd, then attach)
```
`session-open` replaces this terminal, so from Claude Code run it through the
session layout instead: tell the user to pick the session in `sessions`
(or `cc tmux <subject>`), where the main pane opens it in place.
```

Frontmatter `description:` → `Resume any session from the index — migrates it here if it lives on the other machine, then opens it (attach, or revive then attach).`

Supprimer aussi les étapes 2-4 du skill (lookup, rsync, git pull) : `session-migrate` les porte désormais (Task 7). Garder l'étape 1 (résolution du numéro de ligne) et l'étape 5 (pointeur `/ai-brain:restore`).

- [ ] **Step 6: Lancer, constater le succès**

Run: `chmod +x bin/session-agents-state bin/session-open && bash tests/run_tests.sh 2>&1 | tail -3`
Expected: `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add bin/session-agents-state bin/session-open tests/test_open.sh plugins/session/skills/resume/SKILL.md
git commit -m "feat: session-open — attach known sessions, revive unknown ones (no accidental copies)"
```

---

### Task 3: Sujets `cc` et répertoire d'arrivée

**Files:**
- Create: `bin/session-subject-roots`, `bin/session-subject-of`, `bin/session-target-cwd`
- Modify: `bin/session-index-scan` (colonnes `cc_subject`, `cc_rel`)
- Modify: `config.yml.template` (clé `subjects_file`)
- Create: `tests/test_subjects.sh`

**Interfaces:**
- Produces: `session-subject-roots` → lignes `nom\tracine-résolue` (vide si pas de fichier).
- Produces: `session-subject-of <cwd>` → `sujet\trel` (rel vide à la racine) ou rien.
- Produces: `session-target-cwd <subject> <rel> <project_relative>` → chemin existant sur cette machine, ou exit 3 + message sur stderr.
- Produces: entrées de `registry.json` enrichies de `cc_subject`, `cc_rel`.

- [ ] **Step 1: Écrire le test**

`tests/test_subjects.sh` :

```bash
#!/usr/bin/env bash
# tests/test_subjects.sh — sourced by run_tests.sh
echo "--- test_subjects ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
M="$MTMP/mac"; N="$MTMP/nexus"
# On the Mac the subject root is a symlink, like ~/ai-brain → ~/vaults/ai-brain.
mkdir -p "$M/vaults/brain/notes"; ln -s "$M/vaults/brain" "$M/brain"
mkdir -p "$N/brain/notes"
printf 'typeset -A CC_DIRS=(\n  tpg $HOME/projects/tpg\n  brain $HOME/brain\n)\n' | tee "$M/subjects.zsh" > "$N/subjects.zsh"

assert_eq "roots resolve symlinks" "$M/vaults/brain" \
  "$(on mac session-subject-roots | awk -F'\t' '$1=="brain"{print $2}')"
assert_eq "subject-of root"   "$(printf 'brain\t')"       "$(on mac session-subject-of "$M/vaults/brain")"
assert_eq "subject-of nested" "$(printf 'brain\tnotes')"  "$(on mac session-subject-of "$M/vaults/brain/notes")"
assert_eq "subject-of outside" "" "$(on mac session-subject-of "$M/elsewhere")"

assert_eq "target: same rel"  "$N/brain/notes" "$(on nexus session-target-cwd brain notes '')"
assert_eq "target: worktree falls back to root" "$N/brain" \
  "$(on nexus session-target-cwd brain .claude/worktrees/x '')"
mkdir -p "$N/misc/dir"
assert_eq "target: no subject → home + project_relative" "$N/misc/dir" \
  "$(on nexus session-target-cwd '' '' misc/dir)"
rc=0; on nexus session-target-cwd '' '' nope/dir 2>/dev/null || rc=$?
assert_eq "target: missing dir refuses" "3" "$rc"
rc=0; on nexus session-target-cwd ghost '' '' 2>/dev/null || rc=$?
assert_eq "target: unknown subject refuses" "3" "$rc"

# The scan records the subject so the other machine can place the session.
mk_session mac s-brain "$M/vaults/brain/notes" >/dev/null
on mac session-index-scan >/dev/null 2>&1
REG="$M/.claude/session-hub/registry.json"
assert_eq "scan records cc_subject" "brain" \
  "$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['s-brain']['cc_subject'])")"
assert_eq "scan records cc_rel" "notes" \
  "$(python3 -c "import json;print(json.load(open('$REG'))['machines']['mac']['s-brain']['cc_rel'])")"
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `bash tests/run_tests.sh 2>&1 | grep -E 'roots|subject-of|target|cc_|Results'`
Expected: FAIL.

- [ ] **Step 3: Implémenter `bin/session-subject-roots`**

```bash
#!/usr/bin/env bash
# session-subject-roots — "name<TAB>resolved-root" for every cc subject on this
# machine. Reads the subjects file (CC_DIRS) shared with cc and the .zshrc;
# roots are resolved (:A) because Claude Code records real paths.
set -euo pipefail
F=$(session-config subjects_file 2>/dev/null || echo "$HOME/projects/admin/cc/subjects.zsh")
[ -r "$F" ] || exit 0
zsh -fc 'source "$1"; for k v in ${(kv)CC_DIRS}; do print -r -- "$k"$'"'"'\t'"'"'"${v:A}"; done' _ "$F"
```

- [ ] **Step 4: Implémenter `bin/session-subject-of`**

```bash
#!/usr/bin/env bash
# session-subject-of <abs-cwd> — which cc subject holds this directory here.
# Prints "subject<TAB>relative-path" (empty relative path at the root), or
# nothing. The most specific root wins, like cc's own deduction.
set -euo pipefail
session-subject-roots | python3 -c '
import os, sys
cwd = os.path.realpath(sys.argv[1])
best = None
for line in sys.stdin:
    name, root = line.rstrip("\n").split("\t", 1)
    if cwd == root or cwd.startswith(root.rstrip("/") + "/"):
        if best is None or len(root) > len(best[1]):
            best = (name, root)
if best:
    rel = os.path.relpath(cwd, best[1])
    rel = "" if rel == "." else rel
    print(best[0] + "\t" + rel)
' "$1"
```

- [ ] **Step 5: Implémenter `bin/session-target-cwd`**

```bash
#!/usr/bin/env bash
# session-target-cwd <cc-subject> <rel> <project-relative>
# Where a session coming from another machine lands on this one:
#   1. subject root here + rel, when that directory exists
#   2. the subject root (rel was e.g. a worktree that only exists over there)
#   3. no subject: this home + project-relative
# Exit 3 with a message when the result does not exist here — never guess.
set -euo pipefail
SUBJ="${1:-}"; REL="${2:-}"; PREL="${3:-}"
if [ -n "$SUBJ" ]; then
  ROOT=$(session-subject-roots | awk -F'\t' -v s="$SUBJ" '$1==s{print $2}')
  [ -n "$ROOT" ] || { echo "sujet « $SUBJ » inconnu sur cette machine" >&2; exit 3; }
  if [ -n "$REL" ] && [ -d "$ROOT/$REL" ]; then echo "$ROOT/$REL"; exit 0; fi
  [ -d "$ROOT" ] && { echo "$ROOT"; exit 0; }
  echo "racine du sujet absente ici : $ROOT" >&2; exit 3
fi
T="$(session-config home)${PREL:+/$PREL}"
[ -d "$T" ] || { echo "répertoire absent ici : $T" >&2; exit 3; }
echo "$T"
```

- [ ] **Step 6: Enregistrer le sujet au scan**

Dans `bin/session-index-scan`, boucle shell, juste avant le `printf … >> "$TSV"` :

```bash
  # Where this cwd sits among the cc subjects, resolved HERE — the other
  # machine cannot resolve our symlinks (~/ai-brain → ~/vaults/ai-brain).
  subj=$(session-subject-of "$cwd" || true)
  [ -n "$subj" ] || subj=$'\t'
```

et remplacer la ligne `printf` par :

```bash
  printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$cwd" "$mtime" "$meta" "$subj" >> "$TSV"
```

Côté python, après `turns, size_kb, branch = …` :

```python
    cc_subject, cc_rel = at(parts, 9), at(parts, 10)
```

et dans le dict `new[sid]`, après `"git_branch": branch,` :

```python
        "cc_subject": cc_subject,
        "cc_rel": cc_rel,
```

- [ ] **Step 7: Config**

Dans `config.yml.template`, après `home:` :

```yaml
subjects_file: /Users/youruser/projects/admin/cc/subjects.zsh   # CC_DIRS shared with cc
```

- [ ] **Step 8: Lancer, constater le succès** — `chmod +x` des trois scripts, puis `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 9: Commit**

```bash
git add bin/session-subject-roots bin/session-subject-of bin/session-target-cwd bin/session-index-scan config.yml.template tests/test_subjects.sh
git commit -m "feat: place sessions across machines through cc subjects"
```

---

### Task 4: Lignes de la liste (`session-rows`)

**Files:**
- Create: `bin/session-rows`
- Create: `tests/test_rows.sh`

**Interfaces:**
- Consumes: `session-index-view` (existant), `session-metastore all`, `claude agents --json --all`, registre enrichi (`cc_subject`, `cc_rel`, `diverged` — ce dernier ajouté Task 8, lu ici avec défaut `false`).
- Produces: `session-rows` → lignes `id\taffichage`. État lu dans `$SESSIONS_STATE/` : `sort` (`activity`|`project`|`priority`), `scope` (`subject`|`all`), `subject` (nom), `filter` (`""`|`prio`|`mac`|`nexus`). Sans `SESSIONS_STATE` : tri activité, toutes sessions.

- [ ] **Step 1: Écrire le test**

`tests/test_rows.sh` :

```bash
#!/usr/bin/env bash
# tests/test_rows.sh — sourced by run_tests.sh
echo "--- test_rows ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
H="$MTMP/mac/.claude/session-hub"
cat > "$H/registry.json" <<'EOF'
{"version": 2, "machines": {
 "mac":   {"old": {"cwd": "/x", "project_relative": "projects/tpg/rakam", "cc_subject": "tpg", "cc_rel": "rakam",
                   "last_activity": "2026-10-01T10:00:00Z", "title": "Vieux", "turns": 3, "status": "active"},
           "new": {"cwd": "/y", "project_relative": "ai-brain", "cc_subject": "brain", "cc_rel": "",
                   "last_activity": "2026-10-08T10:00:00Z", "title": "Récent", "turns": 9, "status": "active"}},
 "nexus": {"mid": {"cwd": "/z", "project_relative": "projects/tpg", "cc_subject": "tpg", "cc_rel": "",
                   "last_activity": "2026-10-05T10:00:00Z", "title": "Milieu", "turns": 5, "status": "active",
                   "diverged": true}}}}
EOF
on mac session-metastore set old priority '"must"'
ids() { cut -f1 | tr '\n' ' '; }
export SESSIONS_STATE="$MTMP/state"; mkdir -p "$SESSIONS_STATE"

echo activity > "$SESSIONS_STATE/sort"; echo all > "$SESSIONS_STATE/scope"; : > "$SESSIONS_STATE/filter"
assert_eq "sort by activity" "new mid old " "$(on mac session-rows | ids)"
echo priority > "$SESSIONS_STATE/sort"
assert_eq "sort by priority then activity" "old new mid " "$(on mac session-rows | ids)"
echo project > "$SESSIONS_STATE/sort"
assert_eq "sort by project then activity" "new mid old " "$(on mac session-rows | ids)"
echo subject > "$SESSIONS_STATE/scope"; echo tpg > "$SESSIONS_STATE/subject"
assert_eq "scope: current subject" "mid old " "$(on mac session-rows | ids)"
echo all > "$SESSIONS_STATE/scope"; echo nexus > "$SESSIONS_STATE/filter"
assert_eq "filter: nexus" "mid " "$(on mac session-rows | ids)"
echo prio > "$SESSIONS_STATE/filter"
assert_eq "filter: prioritised" "old " "$(on mac session-rows | ids)"

: > "$SESSIONS_STATE/filter"
LINE=$(on mac session-rows | awk -F'\t' '$1=="mid"{print $2}')
case "$LINE" in *"⚠"*) r=yes ;; *) r=no ;; esac
assert_eq "diverged marker" "yes" "$r"
echo '[{"sessionId":"new","pid":1,"status":"idle"}]' > "$MTMP/mac/.agents.json"
LINE=$(on mac session-rows | awk -F'\t' '$1=="new"{print $2}')
case "$LINE" in *"●"*) r=yes ;; *) r=no ;; esac
assert_eq "running marker" "yes" "$r"
# Owner from meta wins over the observing machine.
on mac session-metastore set old owner '"nexus"'
LINE=$(on mac session-rows | awk -F'\t' '$1=="old"{print $2}')
case "$LINE" in *" n "*) r=yes ;; *) r=no ;; esac
assert_eq "owner from meta" "yes" "$r"
unset SESSIONS_STATE
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec** — `bash tests/run_tests.sh 2>&1 | grep -E 'sort|scope|filter|marker|owner|Results'` → FAIL.

- [ ] **Step 3: Implémenter `bin/session-rows`**

```bash
#!/usr/bin/env bash
# session-rows — the session list as "id<TAB>display" lines for fzf.
# State (all optional) in $SESSIONS_STATE/:
#   sort     activity | project | priority      (default activity)
#   scope    subject | all                      (default all)
#   subject  cc subject used when scope=subject
#   filter   "" | prio | mac | nexus
# Display: priority · age · owner (m/n) · subject · title · markers
#   ● running here   ⇢ replica older than the source's last activity   ⚠ diverged
set -euo pipefail
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE=$(session-config claude_bin 2>/dev/null || echo claude)
VIEW=$(mktemp); META=$(mktemp); AG=$(mktemp)
trap 'rm -f "$VIEW" "$META" "$AG"' EXIT
session-index-view > "$VIEW"
session-metastore all > "$META"
"$CLAUDE" agents --json --all > "$AG" 2>/dev/null || echo '[]' > "$AG"
python3 - "$VIEW" "$META" "$AG" "${SESSIONS_STATE:-}" "$CLAUDE_DIR" << 'PYEOF'
import json, os, signal, sys
from datetime import datetime
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
view, meta, ag, state, claude_dir = sys.argv[1:6]
rows = json.load(open(view))
meta = json.load(open(meta))
try:
    agents = json.load(open(ag))
    agents = agents if isinstance(agents, list) else agents.get("sessions", [])
except ValueError:
    agents = []
running = {a.get("sessionId") for a in agents if "pid" in a or a.get("status")}

def st(name, default=""):
    if not state:
        return default
    try:
        return open(os.path.join(state, name)).read().strip() or default
    except OSError:
        return default

sort, scope = st("sort", "activity"), st("scope", "all")
subject, filt = st("subject"), st("filter")
RANK = {"must": 0, "should": 1, "may": 2}
BADGE = {"must": "!!", "should": "! ", "may": "· "}

for r in rows:
    m = meta.get(r["id"], {})
    r["owner"] = m.get("owner") or r.get("machine", "?")
    r["priority"] = m.get("priority", "")
    r["proj"] = r.get("cc_subject") or (r.get("project_relative") or "~").split("/")[-1]
    rel = r.get("cc_rel") or ""
    if r.get("cc_subject") and rel and not rel.startswith("."):
        r["proj"] += "/" + rel.split("/")[0]

if scope == "subject" and subject:
    rows = [r for r in rows if r.get("cc_subject") == subject]
if filt == "prio":
    rows = [r for r in rows if r["priority"]]
elif filt in ("mac", "nexus"):
    rows = [r for r in rows if r["owner"] == filt]

rows.sort(key=lambda r: r.get("last_activity", ""), reverse=True)   # stable base
if sort == "project":
    rows.sort(key=lambda r: r["proj"])
elif sort == "priority":
    rows.sort(key=lambda r: RANK.get(r["priority"], 3))

def age(iso):
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return "?"
    s = (datetime.now(dt.tzinfo) - dt).total_seconds()
    for unit, n in (("j", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return f"{int(s // n)}{unit}"
    return "0m"

def replica_lag(r):
    src = os.path.join(claude_dir, "session-replica", r.get("machine", ""), r["id"], "source.json")
    try:
        rep = json.load(open(src)).get("replicated_at", "")
    except (OSError, ValueError):
        return False
    return rep < r.get("last_activity", "")

for r in rows:
    marks = ""
    if r["id"] in running:
        marks += "●"
    if r["owner"] != r.get("machine") or replica_lag(r):
        marks += "⇢"
    if r.get("diverged"):
        marks += "⚠"
    title = r.get("title") or r.get("subject") or "—"
    line = (f"{BADGE.get(r['priority'], '  ')} {age(r.get('last_activity', '')):>4} "
            f"{r['owner'][:1]} {r['proj'][:12]:<12} {title} {marks}").rstrip()
    print(f"{r['id']}\t{line}")
PYEOF
```

Remarque : `⇢` couvre aussi « la meta désigne un autre propriétaire que la machine observée » (migration pas encore rescannée).

- [ ] **Step 4: Lancer, constater le succès** — `chmod +x bin/session-rows`, `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/session-rows tests/test_rows.sh
git commit -m "feat: session-rows — sorted, scoped, filtered list lines for fzf"
```

---

### Task 5: Interface tmux + fzf

**Files:**
- Create: `bin/session-tui`, `bin/session-tui-act`, `bin/session-home`, `bin/session-layout`
- Modify: `bin/sessions` (en tête)
- Create: `tests/test_tui.sh`

**Interfaces:**
- Consumes: `session-rows` (Task 4), `session-open` (Task 2), `session-priority` (Task 1), `session-subject-roots` / `session-subject-of` (Task 3). `session-migrate`, `session-diverge`, `session-trash` arrivent Tasks 6-8 : `session-tui-act` les appelle par nom, ils n'ont pas besoin d'exister pour les tests de cette task (stub tmux : rien n'est exécuté).
- Produces: `session-layout <tmux-session> [subject]` ; `session-tui-act open|trash <id>`, `session-tui-act sort|scope`, `session-tui-act filter prio|mac|nexus` ; options tmux `@sessions_main` (fenêtre) et `@sessions_subject` (session).

- [ ] **Step 1: Écrire le test**

`tests/test_tui.sh` :

```bash
#!/usr/bin/env bash
# tests/test_tui.sh — sourced by run_tests.sh
echo "--- test_tui ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
export SESSIONS_STATE="$MTMP/state"; mkdir -p "$SESSIONS_STATE"
echo activity > "$SESSIONS_STATE/sort"; echo subject > "$SESSIONS_STATE/scope"; : > "$SESSIONS_STATE/filter"

on mac session-tui-act sort;  assert_eq "sort cycles 1" "project"  "$(cat "$SESSIONS_STATE/sort")"
on mac session-tui-act sort;  assert_eq "sort cycles 2" "priority" "$(cat "$SESSIONS_STATE/sort")"
on mac session-tui-act sort;  assert_eq "sort cycles 3" "activity" "$(cat "$SESSIONS_STATE/sort")"
on mac session-tui-act scope; assert_eq "scope toggles" "all" "$(cat "$SESSIONS_STATE/scope")"
on mac session-tui-act filter mac; assert_eq "filter on"  "mac" "$(cat "$SESSIONS_STATE/filter")"
on mac session-tui-act filter mac; assert_eq "filter off" ""    "$(cat "$SESSIONS_STATE/filter")"

# Open a local session → respawn the main pane on session-open.
SID=bbbbbbbb-1111-2222-3333-444444444444
mk_session mac "$SID" "$MTMP/mac/projects/tpg/rakam" >/dev/null
on mac session-index-scan >/dev/null 2>&1
: > "$MTMP/tmux.log"
on mac session-tui-act open "$SID"
case "$(tail -1 "$MTMP/tmux.log")" in
  "tmux respawn-pane -k -t %1 "*"session-open $SID"*) r=ok ;; *) r="$(tail -1 "$MTMP/tmux.log")" ;; esac
assert_eq "open local → respawn on session-open" "ok" "$r"

# A session owned by the other machine → migrate first.
on mac session-metastore set "$SID" owner '"nexus"'
: > "$MTMP/tmux.log"
on mac session-tui-act open "$SID"
case "$(tail -1 "$MTMP/tmux.log")" in
  *"session-migrate $SID && "*"session-open $SID"*) r=ok ;; *) r="$(tail -1 "$MTMP/tmux.log")" ;; esac
assert_eq "open remote → migrate then open" "ok" "$r"

# Layout: new tmux session with main pane + list pane on the left.
: > "$MTMP/tmux.log"
STUB_TMUX_HAS=1 on mac session-layout cc-tpg tpg
L=$(cat "$MTMP/tmux.log")
case "$L" in *"new-session -d -s cc-tpg"*"set-option -w -t cc-tpg @sessions_main %1"*"split-window -h -b -l 38 -t %1"*"session-tui"*) r=ok ;; *) r="$L" ;; esac
assert_eq "layout creates two panes" "ok" "$r"
: > "$MTMP/tmux.log"
STUB_TMUX_HAS=0 on mac session-layout cc-tpg tpg
case "$(cat "$MTMP/tmux.log")" in *new-session*) r=recreated ;; *) r=ok ;; esac
assert_eq "layout reuses existing session" "ok" "$r"
unset SESSIONS_STATE
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec** — FAIL attendu (`session-tui-act: command not found`).

- [ ] **Step 3: Implémenter `bin/session-tui-act`**

```bash
#!/usr/bin/env bash
# session-tui-act — actions bound to the session list (fzf) keys.
#   open <id>              show the session in the main pane (migrating it
#                          here first when another machine owns it)
#   trash <id>             ask, then move it to the trash, in the main pane
#   sort                   cycle activity → project → priority
#   scope                  current subject ↔ all sessions
#   filter prio|mac|nexus  toggle that filter
# The main pane is respawned, never the list: the list stays put.
set -euo pipefail
S="${SESSIONS_STATE:?SESSIONS_STATE unset — run from session-tui}"
BIN=$(cd "$(dirname "$0")" && pwd)
main() {
  local pane; pane=$(tmux show -wv @sessions_main)
  tmux respawn-pane -k -t "$pane" "env PATH='$BIN:$PATH' bash -c '$1; exec $BIN/session-home'"
}
case "${1:-}" in
  open)
    SID="$2"; THIS=$(session-config machine)
    OWNER=$(session-metastore get "$SID" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))')
    [ -n "$OWNER" ] || OWNER=$(session-registry-get "$SID" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("machine",""))')
    DIV=$(session-registry-get "$SID" | python3 -c 'import json,sys;print("1" if json.load(sys.stdin).get("diverged") else "")')
    if [ -n "$DIV" ]; then main "session-diverge $SID"
    elif [ "$OWNER" = "$THIS" ] || [ -z "$OWNER" ]; then main "session-open $SID"
    else main "session-migrate $SID && session-open $SID"
    fi ;;
  trash) main "session-trash --ask $2" ;;
  sort)
    case "$(cat "$S/sort" 2>/dev/null)" in
      activity) echo project ;; project) echo priority ;; *) echo activity ;;
    esac > "$S/sort.tmp" && mv "$S/sort.tmp" "$S/sort" ;;
  scope)
    [ "$(cat "$S/scope" 2>/dev/null)" = all ] && echo subject > "$S/scope" || echo all > "$S/scope" ;;
  filter)
    [ "$(cat "$S/filter" 2>/dev/null)" = "$2" ] && : > "$S/filter" || echo "$2" > "$S/filter" ;;
  *) echo "session-tui-act: open|trash <id> | sort | scope | filter <x>" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Implémenter `bin/session-home`**

```bash
#!/usr/bin/env bash
# session-home — what the main pane shows when no session is open: the agent
# view of the layout's subject (what `cc <subject>` shows). Loops so the pane
# never dies under the list.
set -euo pipefail
CLAUDE=$(session-config claude_bin 2>/dev/null || echo claude)
SUBJ=$(tmux show -v @sessions_subject 2>/dev/null || true)
ROOT="$HOME"
[ -n "$SUBJ" ] && ROOT=$(session-subject-roots | awk -F'\t' -v s="$SUBJ" '$1==s{print $2}')
while :; do
  "$CLAUDE" agents --cwd "${ROOT:-$HOME}" || true
  read -r -p "⏎ vue agents " _ || exit 0
done
```

- [ ] **Step 5: Implémenter `bin/session-tui`**

```bash
#!/usr/bin/env bash
# session-tui [subject] — the list pane: an fzf that stays open. Enter acts on
# the main pane through session-tui-act; the list reloads after every action.
set -euo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
export PATH="$BIN:$PATH"
SESSIONS_STATE=$(mktemp -d); export SESSIONS_STATE
trap 'rm -rf "$SESSIONS_STATE"' EXIT
echo activity > "$SESSIONS_STATE/sort"
echo "${1:-}" > "$SESSIONS_STATE/subject"
if [ -n "${1:-}" ]; then echo subject; else echo all; fi > "$SESSIONS_STATE/scope"
: > "$SESSIONS_STATE/filter"
session-hub-sync >/dev/null 2>&1 || true
R='reload(session-rows)'
A='execute-silent(session-tui-act'
session-rows | fzf --ansi --no-sort --layout=reverse --info=hidden \
  --delimiter=$'\t' --with-nth=2 \
  --header=$'⏎ ouvrir  ^s tri  ^a tout\n⌥1-3/0 prio  ^x corbeille  ^r maj' \
  --bind "enter:$A open {1})+$R" \
  --bind "ctrl-x:$A trash {1})+$R" \
  --bind "ctrl-s:$A sort)+$R" \
  --bind "ctrl-a:$A scope)+$R" \
  --bind "alt-p:$A filter prio)+$R" \
  --bind "alt-m:$A filter mac)+$R" \
  --bind "alt-n:$A filter nexus)+$R" \
  --bind "alt-1:execute-silent(session-priority {1} must)+$R" \
  --bind "alt-2:execute-silent(session-priority {1} should)+$R" \
  --bind "alt-3:execute-silent(session-priority {1} may)+$R" \
  --bind "alt-0:execute-silent(session-priority {1} none)+$R" \
  --bind "ctrl-r:execute-silent(session-hub-sync)+$R" \
  --bind "esc:clear-query" || true
```

- [ ] **Step 6: Implémenter `bin/session-layout`**

```bash
#!/usr/bin/env bash
# session-layout <tmux-session> [subject] — open (or join) the two-pane layout:
# list on the left (session-tui), main pane on the right (session-home, then
# whichever session the list opens). Inside tmux it switches, outside it attaches.
# Commands get an explicit PATH: tmux runs them without the .zshrc.
set -euo pipefail
S="${1:?usage: session-layout <tmux-session> [subject]}"; SUBJ="${2:-}"
BIN=$(cd "$(dirname "$0")" && pwd)
ENVP="env PATH='$BIN:$PATH'"
ROOT="$HOME"
[ -n "$SUBJ" ] && ROOT=$(session-subject-roots | awk -F'\t' -v s="$SUBJ" '$1==s{print $2}')
ROOT="${ROOT:-$HOME}"
if ! tmux has-session -t "=$S" 2>/dev/null; then
  tmux new-session -d -s "$S" -c "$ROOT" "$ENVP $BIN/session-home"
  tmux set-option -t "$S" @sessions_subject "$SUBJ"
  MAIN=$(tmux display -p -t "$S" '#{pane_id}')
  tmux set-option -w -t "$S" @sessions_main "$MAIN"
  tmux split-window -h -b -l 38 -t "$MAIN" -c "$ROOT" "$ENVP $BIN/session-tui '$SUBJ'"
fi
if [ -n "${TMUX:-}" ]; then tmux switch-client -t "=$S"; else exec tmux attach -t "=$S"; fi
```

Note : le stub tmux répond `%1` à `display -p…`, ce qui produit `set-option -w -t cc-tpg @sessions_main %1` attendu par le test.

- [ ] **Step 7: Brancher `sessions`**

En tête de `bin/sessions`, juste après `set -euo pipefail` :

```bash
# Interactive terminal → the two-pane layout. --plain, or a pipe (the
# /session:list skill runs us from Bash), keeps the table below.
if [ "${1:-}" = --plain ]; then
  shift
elif [ -t 1 ] && command -v tmux >/dev/null && command -v fzf >/dev/null; then
  SUBJ=$(session-subject-of "$PWD" | cut -f1 || true)
  exec session-layout "cc-${SUBJ:-sessions}" "$SUBJ"
fi
```

et remplacer la dernière ligne d'aide du tableau par :

```python
print("  Interface :  sessions   (dans un terminal)   ·   tableau : sessions --plain")
```

- [ ] **Step 8: Lancer, constater le succès** — `chmod +x` des quatre scripts, `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 9: Essai manuel sur le Mac** (pas de migration encore)

Run: `PATH="$PWD/bin:$PATH" bin/session-layout cc-try ''`
Expected: deux volets ; ⏎ sur une session locale l'ouvre à droite ; ⏎ sur une autre remplace la première, qui reste listée `●` ; ⌥1 affiche `!!`. Sortie : `tmux kill-session -t cc-try`.

- [ ] **Step 10: Commit**

```bash
git add bin/session-tui bin/session-tui-act bin/session-home bin/session-layout bin/sessions tests/test_tui.sh
git commit -m "feat: two-pane tmux layout — persistent fzf list drives the main pane"
```

---

### Task 6: Réplication Mac → Nexus

**Files:**
- Create: `bin/session-replicate`, `hooks/stop-replicate`
- Modify: `bin/session-index-scan` (rattrapage en fin de scan)
- Modify: `config.yml.template` (`replica_to`)
- Create: `tests/test_replicate.sh`

**Interfaces:**
- Consumes: `session-metastore` (Task 1), `session-subject-of` (Task 3), `session-meta`, `session-jsonl-cwd`.
- Produces: `session-replicate [<session-id>]` ; réplique `peer:~/.claude/session-replica/<this>/<id>/` = `<id>.jsonl`, `<id>/` (si présent), `file-history/` (si présent), `source.json` = `{cwd, project_relative, cc_subject, cc_rel, title, size, replicated_at}`. État local `$CLAUDE_DIR/session-replica-state.json` = `{id: mtime}`.

- [ ] **Step 1: Écrire le test**

`tests/test_replicate.sh` :

```bash
#!/usr/bin/env bash
# tests/test_replicate.sh — sourced by run_tests.sh
echo "--- test_replicate ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
SID=cccccccc-1111-2222-3333-444444444444
F=$(mk_session mac "$SID" "$MTMP/mac/projects/tpg/rakam")
mkdir -p "${F%.jsonl}/subagents" "$MTMP/mac/.claude/file-history/$SID"
echo x > "${F%.jsonl}/subagents/a.jsonl"; echo v1 > "$MTMP/mac/.claude/file-history/$SID/f@v1"
REP="$MTMP/nexus/.claude/session-replica/mac/$SID"

on mac session-replicate "$SID"
assert_eq "replica jsonl"        "yes" "$([ -f "$REP/$SID.jsonl" ] && echo yes || echo no)"
assert_eq "replica session dir"  "yes" "$([ -f "$REP/$SID/subagents/a.jsonl" ] && echo yes || echo no)"
assert_eq "replica file-history" "yes" "$([ -f "$REP/file-history/f@v1" ] && echo yes || echo no)"
assert_eq "replica source.json subject" "tpg" \
  "$(python3 -c "import json;print(json.load(open('$REP/source.json'))['cc_subject'])")"

# Nexus has no replica_to: no-op.
rc=0; on nexus session-replicate >/dev/null 2>&1 || rc=$?
assert_eq "nexus replicate is a no-op" "0" "$rc"
# Peer down: silent success, nothing breaks.
down nexus; rc=0; on mac session-replicate "$SID" || rc=$?; up nexus
assert_eq "peer down: silent" "0" "$rc"
# Headless sessions are not replicated.
H=$(mk_session mac dddddddd-0000 "$MTMP/mac/projects/tpg")
sed -i.bak 's/"entrypoint":"cli"/"entrypoint":"sdk-cli"/' "$H"; rm -f "$H.bak"
on mac session-replicate
assert_eq "headless skipped" "no" \
  "$([ -d "$MTMP/nexus/.claude/session-replica/mac/dddddddd-0000" ] && echo yes || echo no)"
# Owned elsewhere → not replicated anymore.
on mac session-metastore set "$SID" owner '"nexus"'
rm -rf "$REP"; on mac session-replicate "$SID"
assert_eq "owned by nexus: not replicated" "no" "$([ -d "$REP" ] && echo yes || echo no)"
# Prune: replica of a session gone from the Mac (and not owned by nexus) is removed.
on mac session-metastore set "$SID" owner null
on mac session-replicate "$SID"
rm -f "$F"; rm -rf "${F%.jsonl}"
on mac session-replicate
assert_eq "prune replica of vanished session" "no" "$([ -d "$REP" ] && echo yes || echo no)"
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec** — FAIL.

- [ ] **Step 3: Implémenter `bin/session-replicate`**

```bash
#!/usr/bin/env bash
# session-replicate [<session-id>] — push this machine's interactive sessions
# to the replica on `replica_to` (Mac → Nexus), so a migration can still be made
# from there while this machine sleeps.
#   <id>   that session only (the Stop hook — fast, no hub sync)
#   none   every owned interactive session changed since its last replication,
#          then prune replicas of sessions that left without migrating
# Silent no-op when replica_to is unset (Nexus) or the peer does not answer.
set -euo pipefail
TO=$(session-config replica_to 2>/dev/null) || exit 0
PEER=$(session-config "peer_$TO")
THIS=$(session-config machine)
HOME_DIR=$(session-config home)
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
STATE="$CLAUDE_DIR/session-replica-state.json"
ONE="${1:-}"
ssh -o ConnectTimeout=3 -o BatchMode=yes "$PEER" true 2>/dev/null || exit 0
[ -n "$ONE" ] || session-hub-sync >/dev/null 2>&1 || true

state_get() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$STATE" "$1"; }
state_set() { python3 -c 'import json,os,sys
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: d={}
d[sys.argv[2]]=sys.argv[3]
json.dump(d, open(p+".tmp","w")); os.replace(p+".tmp", p)' "$STATE" "$1" "$2"; }

replicate_one() {
  local f="$1" sid; sid=$(basename "$f" .jsonl)
  local ep; ep=$(session-meta "$f" | cut -f1)
  [ -z "$ep" ] || [ "$ep" = cli ] || return 0
  local owner; owner=$(session-metastore get "$sid" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))')
  [ -z "$owner" ] || [ "$owner" = "$THIS" ] || return 0
  local mt; mt=$(python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$f")
  [ -n "$ONE" ] || [ "$(state_get "$sid")" != "$mt" ] || return 0
  local dst=".claude/session-replica/$THIS/$sid"
  ssh "$PEER" "mkdir -p '$dst'"
  rsync -a "$f" "$PEER:$dst/"
  [ -d "${f%.jsonl}" ] && rsync -a "${f%.jsonl}" "$PEER:$dst/"
  [ -d "$CLAUDE_DIR/file-history/$sid" ] && { ssh "$PEER" "mkdir -p '$dst/file-history'"; rsync -a "$CLAUDE_DIR/file-history/$sid/" "$PEER:$dst/file-history/"; }
  local cwd; cwd=$(session-jsonl-cwd "$f")
  local sr; sr=$(session-subject-of "$cwd" || true)
  python3 - "$cwd" "$HOME_DIR" "$sr" "$f" "$(session-meta "$f" | cut -f2)" << 'PYEOF' | ssh "$PEER" "cat > '$dst/source.json.tmp' && mv '$dst/source.json.tmp' '$dst/source.json'"
import json, os, sys
from datetime import datetime, timezone
cwd, home, sr, f, title = sys.argv[1:6]
subj, _, rel = sr.partition("\t")
prel = "" if cwd == home.rstrip("/") else cwd[len(home.rstrip("/")) + 1:] if cwd.startswith(home.rstrip("/") + "/") else cwd
print(json.dumps({"cwd": cwd, "project_relative": prel, "cc_subject": subj, "cc_rel": rel,
                  "title": title, "size": os.path.getsize(f),
                  "replicated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))
PYEOF
  state_set "$sid" "$mt"
}

shopt -s nullglob
if [ -n "$ONE" ]; then
  for f in "$CLAUDE_DIR"/projects/*/"$ONE".jsonl; do replicate_one "$f"; done
  exit 0
fi
LOCAL=()
for f in "$CLAUDE_DIR"/projects/*/*.jsonl; do
  LOCAL+=("$(basename "$f" .jsonl)")
  replicate_one "$f" || echo "session-replicate: $(basename "$f") failed" >&2
done
# Prune: replica of a session no longer here, unless another machine took it
# over (session-migrate removes that replica itself once the migration is pushed).
for sid in $(ssh "$PEER" "ls '.claude/session-replica/$THIS' 2>/dev/null" || true); do
  case " ${LOCAL[*]:-} " in *" $sid "*) continue ;; esac
  owner=$(session-metastore get "$sid" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))')
  [ -z "$owner" ] || [ "$owner" = "$THIS" ] || continue
  ssh "$PEER" "rm -rf '.claude/session-replica/$THIS/$sid'"
done
```

(`rm -rf` ici touche une *réplique*, jamais une session : la contrainte « jamais de rm » vise les transcripts vivants.)

- [ ] **Step 4: Implémenter `hooks/stop-replicate`**

```bash
#!/usr/bin/env bash
# Claude Code Stop hook — replicate the session that just answered, detached,
# so the turn never waits on the network. Wired by install.sh where replica_to
# is configured.
BIN="$HOME/.claude/skills/session/bin"
SID=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null) || exit 0
[ -n "$SID" ] || exit 0
T=""; command -v timeout >/dev/null && T="timeout 20"
( PATH="$BIN:$PATH" $T session-replicate "$SID" >/dev/null 2>&1 & )
exit 0
```

- [ ] **Step 5: Rattrapage au scan** — en toute fin de `bin/session-index-scan`, après le `session-hub-push` :

```bash
# Catch-up replication (Mac → Nexus); no-op where replica_to is unset.
session-replicate >/dev/null 2>&1 || true
```

- [ ] **Step 6: Config** — `config.yml.template`, après les `peer_*` :

```yaml
# Mac only: keep a replica of this machine's sessions on that peer, so a
# migration can be made from there while this machine is asleep.
replica_to: nexus
```

- [ ] **Step 7: Lancer, constater le succès** — `chmod +x bin/session-replicate hooks/stop-replicate`, `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 8: Commit**

```bash
git add bin/session-replicate hooks/stop-replicate bin/session-index-scan config.yml.template tests/test_replicate.sh
git commit -m "feat: replicate Mac sessions to Nexus (Stop hook + scan catch-up)"
```

---

### Task 7: Empreinte, corbeille, migration

**Files:**
- Create: `bin/session-fingerprint`, `bin/session-trash`, `bin/session-migrate`
- Create: `tests/test_migrate.sh`

**Interfaces:**
- Consumes: Tasks 1-3, 6. `session-reconcile` (Task 8) est appelé à distance en fin de migration, en best-effort : son absence ne fait pas échouer la migration.
- Produces: `session-fingerprint <jsonl>` → `{"size","sha256","last_uuid"}` ; `session-fingerprint --prefix <jsonl> <size> <sha256>` → exit 0/1.
- Produces: `session-trash [--ask] <id>` → `~/.claude/session-trash/<date>/<id>/{<id>.jsonl,<id>/,file-history/,origin}`.
- Produces: `session-migrate <id> [--yes]` → exit 0 et session installée + `meta` poussée, ou exit ≠ 0 sans trace ; écrit `$CLAUDE_DIR/session-cwd-override/<id>` (cwd cible, lu par `session-open`).

- [ ] **Step 1: Écrire le test**

`tests/test_migrate.sh` :

```bash
#!/usr/bin/env bash
# tests/test_migrate.sh — sourced by run_tests.sh
echo "--- test_migrate ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
M="$MTMP/mac"; N="$MTMP/nexus"
mkdir -p "$N/projects/tpg/rakam"
SID=eeeeeeee-1111-2222-3333-444444444444
F=$(mk_session mac "$SID" "$M/projects/tpg/rakam" '{"type":"assistant","uuid":"u2","message":{"role":"assistant","content":"ok"}}')
mkdir -p "${F%.jsonl}/tool-results"; echo r > "${F%.jsonl}/tool-results/t1"
on mac session-index-scan >/dev/null 2>&1
NENC=$(session-encode-path "$N/projects/tpg/rakam")
owner() { on "$1" session-metastore get "$SID" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))'; }

# Fingerprint
FP=$(session-fingerprint "$F")
assert_eq "fingerprint last_uuid" "u2" "$(echo "$FP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["last_uuid"])')"
SZ=$(echo "$FP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["size"])')
SH=$(echo "$FP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha256"])')
echo '{"type":"user","uuid":"u3"}' >> "$F"
rc=0; session-fingerprint --prefix "$F" "$SZ" "$SH" || rc=$?
assert_eq "prefix matches a grown file" "0" "$rc"

# Source down, no replica → refuse, nothing installed.
down mac
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
assert_eq "down + no replica: refused" "1" "$rc"
assert_eq "down + no replica: nothing installed" "no" "$([ -f "$N/.claude/projects/$NENC/$SID.jsonl" ] && echo yes || echo no)"
up mac

# Hub push refused → rollback (Review Focus 3).
chmod -w "$MTMP/hub.git/objects"
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
chmod +w "$MTMP/hub.git/objects"
assert_eq "push refused: fails" "1" "$rc"
assert_eq "push refused: files rolled back" "no" "$([ -e "$N/.claude/projects/$NENC/$SID.jsonl" ] && echo yes || echo no)"
assert_eq "push refused: meta rolled back" "" "$(owner nexus)"

# Source reachable → copy from it, push, source copy trashed.
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
assert_eq "reachable: migrates" "0" "$rc"
assert_eq "reachable: transcript installed" "yes" "$([ -f "$N/.claude/projects/$NENC/$SID.jsonl" ] && echo yes || echo no)"
assert_eq "reachable: session dir installed" "yes" "$([ -f "$N/.claude/projects/$NENC/$SID/tool-results/t1" ] && echo yes || echo no)"
assert_eq "owner is nexus (seen from mac)" "nexus" "$(on mac session-hub-sync >/dev/null 2>&1; owner mac)"
assert_eq "cwd override written" "$N/projects/tpg/rakam" "$(cat "$N/.claude/session-cwd-override/$SID")"

# Destination already holds the id → refuse (Review Focus 1).
on nexus session-metastore set "$SID" owner '"mac"'
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
assert_eq "already here: refused" "1" "$rc"

# Target subject root missing → refuse (Review Focus 5).
G=gggggggg-1111-2222-3333-444444444444
mk_session mac "$G" "$M/projects/tpg/rakam" >/dev/null
on mac session-index-scan >/dev/null 2>&1
mv "$N/projects/tpg" "$N/projects/tpg.off"
rc=0; on nexus session-migrate "$G" --yes >/dev/null 2>&1 || rc=$?
mv "$N/projects/tpg.off" "$N/projects/tpg"
assert_eq "target missing: refused" "1" "$rc"

# Mac down → migrate from the replica, replica removed afterwards.
on mac session-replicate "$G"
down mac
rc=0; on nexus session-migrate "$G" --yes >/dev/null 2>&1 || rc=$?
up mac
assert_eq "from replica: migrates" "0" "$rc"
assert_eq "from replica: replica removed" "no" "$([ -d "$N/.claude/session-replica/mac/$G" ] && echo yes || echo no)"

# Trash
T=$(on nexus session-trash "$G" >/dev/null 2>&1; ls -d "$N"/.claude/session-trash/*/"$G" 2>/dev/null | head -1)
assert_eq "trash moves the transcript" "yes" "$([ -f "$T/$G.jsonl" ] && echo yes || echo no)"
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec** — FAIL.

- [ ] **Step 3: Implémenter `bin/session-fingerprint`**

```bash
#!/usr/bin/env bash
# session-fingerprint <jsonl>                        {"size","sha256","last_uuid"}
# session-fingerprint --prefix <jsonl> <size> <sha>  exit 0 when the file's first
#   <size> bytes hash to <sha>: the transcript grew from that exact state.
set -euo pipefail
python3 - "$@" << 'PYEOF'
import hashlib, json, os, sys
a = sys.argv[1:]

def sha(path, limit=None):
    h = hashlib.sha256()
    left = limit
    with open(path, "rb") as f:
        while left is None or left > 0:
            chunk = f.read(1 << 20 if left is None else min(1 << 20, left))
            if not chunk:
                break
            h.update(chunk)
            if left is not None:
                left -= len(chunk)
    return h.hexdigest()

if a[0] == "--prefix":
    path, size, want = a[1], int(a[2]), a[3]
    sys.exit(0 if os.path.getsize(path) >= size and sha(path, size) == want else 1)

path = a[0]
last = ""
with open(path, errors="ignore") as f:
    for line in f:
        try:
            u = json.loads(line).get("uuid")
        except ValueError:
            continue
        if u:
            last = u
print(json.dumps({"size": os.path.getsize(path), "sha256": sha(path), "last_uuid": last}))
PYEOF
```

- [ ] **Step 4: Implémenter `bin/session-trash`**

```bash
#!/usr/bin/env bash
# session-trash [--ask] <session-id> — move a local session (transcript, its
# directory, its file-history) to ~/.claude/session-trash/<date>/<id>/.
# Never deletes; session-reconcile empties trash older than 30 days.
# Refuses a session that is running here.
set -euo pipefail
ASK=""; [ "${1:-}" = --ask ] && { ASK=1; shift; }
SID="${1:?usage: session-trash [--ask] <session-id>}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
shopt -s nullglob
F=("$CLAUDE_DIR"/projects/*/"$SID".jsonl)
[ ${#F[@]} -gt 0 ] || { echo "session-trash: ${SID:0:8} absente de cette machine" >&2; exit 1; }
if [ "$(session-agents-state "$SID")" = running ]; then
  echo "session-trash: ${SID:0:8} tourne — arrête-la d'abord (claude stop ${SID:0:8})" >&2; exit 1
fi
if [ -n "$ASK" ]; then
  read -r -p "Mettre ${SID:0:8} à la corbeille ? [o/N] " a
  [ "$a" = o ] || [ "$a" = O ] || exit 0
fi
T="$CLAUDE_DIR/session-trash/$(date +%F)/$SID"
mkdir -p "$T"
dirname "${F[0]}" > "$T/origin"            # where it came from, to put it back by hand
mv "${F[0]}" "$T/"
[ -d "${F[0]%.jsonl}" ] && mv "${F[0]%.jsonl}" "$T/"
[ -d "$CLAUDE_DIR/file-history/$SID" ] && mv "$CLAUDE_DIR/file-history/$SID" "$T/file-history"
echo "→ corbeille : $T"
```

- [ ] **Step 5: Implémenter `bin/session-migrate`**

```bash
#!/usr/bin/env bash
# session-migrate <session-id> [--yes] — move a session that another machine
# owns onto this one. Run it from the destination.
#   source reachable   copy from it (stopping it first, after asking, if running)
#   source unreachable copy from the local replica, after showing its age
# Then install, record the new owner in meta/ and push. A failed push undoes
# the install: a migration only exists once the hub has it. The source copy is
# then reconciled (trashed if untouched), right away if reachable, else at its
# next scan.
set -euo pipefail
SID="${1:?usage: session-migrate <session-id> [--yes]}"; YES="${2:-}"
SHORT="${SID:0:8}"
THIS=$(session-config machine)
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
HUB_DIR="${HUB_DIR_OVERRIDE:-$HOME/.claude/session-hub}"
RPATH='PATH=$HOME/.claude/skills/session/bin:$HOME/.local/bin:$PATH'
say() { printf '%s\n' "$*" >&2; }
confirm() { [ "$YES" = --yes ] && return 0; read -r -p "$1 [o/N] " a; [ "$a" = o ] || [ "$a" = O ]; }
jget() { python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1],"") or "")' "$1"; }

session-hub-sync >/dev/null 2>&1 || { say "hub injoignable — migration impossible"; exit 1; }
OWNER=$(session-metastore get "$SID" | jget owner)
[ -n "$OWNER" ] || OWNER=$(session-registry-get "$SID" | jget machine)
[ -n "$OWNER" ] || { say "$SHORT inconnue de l'index"; exit 1; }
[ "$OWNER" != "$THIS" ] || { say "$SHORT est déjà sur $THIS"; exit 0; }
PEER=$(session-config "peer_$OWNER")
# The source machine's own registry entry (not the freshest across machines).
SRCE=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(json.dumps(d.get("machines",{}).get(sys.argv[2],{}).get(sys.argv[3],{})))' \
  "$HUB_DIR/registry.json" "$OWNER" "$SID")

# Refuse before copying anything: an older copy of this id already here
# (e.g. a pre-migration /session:resume) must be settled by hand first.
shopt -s nullglob
HERE=("$CLAUDE_DIR"/projects/*/"$SID".jsonl)
[ ${#HERE[@]} -eq 0 ] || { say "$SHORT existe déjà ici (${HERE[0]}) — mets cette copie à la corbeille d'abord"; exit 1; }
[ ! -e "$CLAUDE_DIR/file-history/$SID" ] || { say "file-history/$SID existe déjà ici"; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
REACHABLE=""
if ssh -o ConnectTimeout=3 -o BatchMode=yes "$PEER" true 2>/dev/null; then
  REACHABLE=1
  if [ "$(ssh "$PEER" "$RPATH session-agents-state $SID")" = running ]; then
    confirm "$SHORT tourne sur $OWNER. L'arrêter et la migrer ?" || exit 1
    ssh "$PEER" "$RPATH \$(session-config claude_bin 2>/dev/null || echo claude) stop $SHORT" >/dev/null
  fi
  SCWD=$(echo "$SRCE" | jget cwd)
  [ -n "$SCWD" ] || { say "$SHORT : répertoire source inconnu (scan de $OWNER pas encore passé ?)"; exit 1; }
  SENC=$(session-encode-path "$SCWD")
  rsync -a "$PEER:.claude/projects/$SENC/$SID.jsonl" "$STAGE/" || { say "copie depuis $OWNER impossible"; exit 1; }
  rsync -a "$PEER:.claude/projects/$SENC/$SID" "$STAGE/" 2>/dev/null || true
  mkdir -p "$STAGE/file-history"
  rsync -a "$PEER:.claude/file-history/$SID/" "$STAGE/file-history/" 2>/dev/null || true
  INFO="$SRCE"
else
  REP="$CLAUDE_DIR/session-replica/$OWNER/$SID"
  [ -f "$REP/$SID.jsonl" ] || { say "$OWNER injoignable et aucune réplique de $SHORT ici"; exit 1; }
  INFO=$(cat "$REP/source.json")
  say "$OWNER injoignable — réplique du $(echo "$INFO" | jget replicated_at), dernière activité connue sur $OWNER : $(echo "$SRCE" | jget last_activity)"
  confirm "Migrer depuis la réplique ?" || exit 1
  cp -R "$REP/." "$STAGE/"; rm -f "$STAGE/source.json"
fi

TCWD=$(session-target-cwd "$(echo "$INFO" | jget cc_subject)" "$(echo "$INFO" | jget cc_rel)" \
       "$(echo "$INFO" | jget project_relative)") || exit 1
DEST="$CLAUDE_DIR/projects/$(session-encode-path "$TCWD")"

mkdir -p "$DEST" "$CLAUDE_DIR/session-cwd-override"
INSTALLED=("$DEST/$SID.jsonl")
mv "$STAGE/$SID.jsonl" "$DEST/"
[ -d "$STAGE/$SID" ] && { mv "$STAGE/$SID" "$DEST/"; INSTALLED+=("$DEST/$SID"); }
if [ -n "$(ls -A "$STAGE/file-history" 2>/dev/null)" ]; then
  mkdir -p "$CLAUDE_DIR/file-history"
  mv "$STAGE/file-history" "$CLAUDE_DIR/file-history/$SID"; INSTALLED+=("$CLAUDE_DIR/file-history/$SID")
fi
rollback() { rm -rf "${INSTALLED[@]}"; say "migration annulée : $1"; exit 1; }

FP=$(session-fingerprint "$DEST/$SID.jsonl")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
session-metastore set "$SID" owner "\"$THIS\""
session-metastore set "$SID" migrated_from "\"$OWNER\""
session-metastore set "$SID" migrated_at "\"$NOW\""
session-metastore set "$SID" fingerprint "$FP"
git -C "$HUB_DIR" add -A
git -C "$HUB_DIR" commit -qm "migrate: $SHORT $OWNER → $THIS" || rollback "commit du hub impossible"
if ! git -C "$HUB_DIR" push -q origin HEAD 2>/dev/null; then
  git -C "$HUB_DIR" reset -q --hard HEAD~1
  rollback "push du hub refusé"
fi
echo "$TCWD" > "$CLAUDE_DIR/session-cwd-override/$SID"
rm -rf "$CLAUDE_DIR/session-replica/$OWNER/$SID"     # a replica, now superseded
if [ -n "$REACHABLE" ]; then
  ssh "$PEER" "$RPATH session-reconcile $SID" >/dev/null 2>&1 || say "nettoyage sur $OWNER reporté à son prochain scan"
fi
say "✓ $SHORT migrée de $OWNER vers $THIS ($TCWD)"
```

Note : le rollback « push refusé » laisse l'arbre du hub à `HEAD~1`, c'est-à-dire l'état d'avant la migration — d'où `owner` vide dans le test.

- [ ] **Step 6: Lancer, constater le succès** — `chmod +x` des trois scripts, `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`.

Si le test « push refused » est instable selon la version de git (le `chmod -w objects` doit faire échouer `receive-pack`), le remplacer par un hook `pre-receive` qui sort en 1 : `printf '#!/bin/sh\nexit 1\n' > "$MTMP/hub.git/hooks/pre-receive"; chmod +x …` puis le retirer après.

- [ ] **Step 7: Commit**

```bash
git add bin/session-fingerprint bin/session-trash bin/session-migrate tests/test_migrate.sh
git commit -m "feat: session-migrate — move a session across machines, from the replica when the source sleeps"
```

---

### Task 8: Réconciliation, divergences, corbeille

**Files:**
- Create: `bin/session-reconcile`, `bin/session-diverge`
- Modify: `bin/session-index-scan` (appel de la réconciliation + champ `diverged`)
- Create: `tests/test_reconcile.sh`

**Interfaces:**
- Consumes: `session-metastore`, `session-fingerprint`, `session-trash`, `session-agents-state`.
- Produces: `session-reconcile [<id>]` ; `$CLAUDE_DIR/session-diverged.json` = liste d'ids ; champ registre `diverged: bool`.
- Produces: `session-diverge <id>` (interactif : `g` garder les deux, `c` corbeille).

- [ ] **Step 1: Écrire le test**

`tests/test_reconcile.sh` :

```bash
#!/usr/bin/env bash
# tests/test_reconcile.sh — sourced by run_tests.sh
echo "--- test_reconcile ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
M="$MTMP/mac"
fp_of() { session-fingerprint "$1"; }
own_elsewhere() {  # <sid> <jsonl-whose-state-was-migrated>
  on mac session-metastore set "$1" owner '"nexus"'
  on mac session-metastore set "$1" fingerprint "$(fp_of "$2")"
}

# Identical to the migrated state → trash.
A=aaaa0000-1111-2222-3333-444444444444
FA=$(mk_session mac "$A" "$M/projects/tpg/rakam"); own_elsewhere "$A" "$FA"
# Grew after the migration (lid closed mid-turn) → diverged, untouched (Review Focus 2).
B=bbbb0000-1111-2222-3333-444444444444
FB=$(mk_session mac "$B" "$M/projects/tpg/rakam"); own_elsewhere "$B" "$FB"
echo '{"type":"user","uuid":"late"}' >> "$FB"
# Running here (interactive) → untouched even if identical (Review Focus 4).
C=cccc0000-1111-2222-3333-444444444444
FC=$(mk_session mac "$C" "$M/projects/tpg/rakam"); own_elsewhere "$C" "$FC"
echo "[{\"sessionId\":\"$C\",\"pid\":7,\"status\":\"busy\"}]" > "$M/.agents.json"
# Owned here → untouched.
D=dddd0000-1111-2222-3333-444444444444
FD=$(mk_session mac "$D" "$M/projects/tpg/rakam")

on mac session-reconcile >/dev/null 2>&1
assert_eq "identical → trashed"        "no"  "$([ -f "$FA" ] && echo yes || echo no)"
assert_eq "identical → in trash"       "yes" "$(ls "$M"/.claude/session-trash/*/"$A"/"$A".jsonl >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "grown → kept"               "yes" "$([ -f "$FB" ] && echo yes || echo no)"
assert_eq "grown → listed diverged"    "$B"  "$(python3 -c "import json;print(' '.join(json.load(open('$M/.claude/session-diverged.json'))))")"
assert_eq "running → kept"             "yes" "$([ -f "$FC" ] && echo yes || echo no)"
assert_eq "owned here → kept"          "yes" "$([ -f "$FD" ] && echo yes || echo no)"

# The scan carries the flag into the registry.
on mac session-index-scan >/dev/null 2>&1
assert_eq "registry diverged flag" "True" \
  "$(python3 -c "import json;print(json.load(open('$M/.claude/session-hub/registry.json'))['machines']['mac']['$B'].get('diverged'))")"

# Trash older than 30 days is emptied.
OLD="$M/.claude/session-trash/2000-01-01/zzzz"; mkdir -p "$OLD"; touch -t 200001010000 "$M/.claude/session-trash/2000-01-01"
on mac session-reconcile >/dev/null 2>&1
assert_eq "old trash purged" "no" "$([ -d "$M/.claude/session-trash/2000-01-01" ] && echo yes || echo no)"

# Divergence → keep both: forked copy appears, original goes to the trash.
echo '[]' > "$M/.agents.json"
: > "$MTMP/claude.log"
echo g | on mac session-diverge "$B" >/dev/null 2>&1
assert_eq "keep both: fork requested" "yes" "$(grep -q -- "--resume $B --fork-session --bg" "$MTMP/claude.log" && echo yes || echo no)"
assert_eq "keep both: original trashed" "no" "$([ -f "$FB" ] && echo yes || echo no)"
machines_teardown
```

- [ ] **Step 2: Lancer, constater l'échec** — FAIL.

- [ ] **Step 3: Implémenter `bin/session-reconcile`**

```bash
#!/usr/bin/env bash
# session-reconcile [<session-id>] — settle local copies of sessions that
# another machine now owns (meta.owner), after a migration:
#   running here               untouched
#   identical to fingerprint   trash (session-trash: moved, never deleted)
#   anything else              diverged: untouched, listed in session-diverged.json
# Full run (no id) also empties trash days older than 30 days.
# With an id (called over ssh right after a migration) it syncs the hub first.
set -euo pipefail
THIS=$(session-config machine)
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DIV="$CLAUDE_DIR/session-diverged.json"
ONE="${1:-}"
[ -z "$ONE" ] || session-hub-sync >/dev/null 2>&1 || true
META=$(mktemp); trap 'rm -f "$META"' EXIT
session-metastore all > "$META"
shopt -s nullglob
NEW_DIV=()
for f in "$CLAUDE_DIR"/projects/*/*.jsonl; do
  sid=$(basename "$f" .jsonl)
  [ -z "$ONE" ] || [ "$sid" = "$ONE" ] || continue
  read -r owner size sha < <(python3 -c 'import json,sys
m=json.load(open(sys.argv[1])).get(sys.argv[2],{}); fp=m.get("fingerprint",{})
print(m.get("owner","-") or "-", fp.get("size","-"), fp.get("sha256","-"))' "$META" "$sid")
  [ "$owner" != "-" ] && [ "$owner" != "$THIS" ] || continue
  [ "$(session-agents-state "$sid")" != running ] || continue
  cur=$(session-fingerprint "$f")
  if [ "$size" != "-" ] && [ "$(echo "$cur" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["size"],d["sha256"])')" = "$size $sha" ]; then
    session-trash "$sid" >/dev/null
  else
    NEW_DIV+=("$sid")
  fi
done
python3 - "$DIV" "$ONE" "${NEW_DIV[@]:-}" << 'PYEOF'
import json, os, sys
path, one, *ids = sys.argv[1:]
ids = [i for i in ids if i]
if one:                       # single-id run: update that id only
    try:
        cur = set(json.load(open(path)))
    except (OSError, ValueError):
        cur = set()
    cur.discard(one); cur.update(ids); ids = sorted(cur)
json.dump(sorted(ids), open(path + ".tmp", "w")); os.replace(path + ".tmp", path)
PYEOF
if [ -z "$ONE" ] && [ -d "$CLAUDE_DIR/session-trash" ]; then
  find "$CLAUDE_DIR/session-trash" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
fi
```

- [ ] **Step 4: Implémenter `bin/session-diverge`**

```bash
#!/usr/bin/env bash
# session-diverge <session-id> — settle a diverged local copy: the session was
# migrated away, but this copy kept going (lid closed mid-turn, or resumed by hand).
#   g  keep both: this copy carries on under a new id (--fork-session), the
#      original local file goes to the trash
#   c  put this local copy in the trash
set -euo pipefail
SID="${1:?usage: session-diverge <session-id>}"; SHORT="${SID:0:8}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CLAUDE=$(session-config claude_bin 2>/dev/null || echo claude)
OWNER=$(session-metastore get "$SID" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner","?"))')
shopt -s nullglob
F=("$CLAUDE_DIR"/projects/*/"$SID".jsonl)
[ ${#F[@]} -gt 0 ] || { echo "$SHORT n'est plus ici." >&2; exit 0; }
echo "⚠ $SHORT : cette copie a continué après sa migration vers $OWNER."
echo "  [g] garder les deux — cette copie repart sous un nouvel id"
echo "  [c] mettre cette copie à la corbeille"
read -r -p "Choix [g/c] : " c
case "$c" in
  g)
    CWD=$(session-jsonl-cwd "${F[0]}")
    OUT=$(cd "$CWD" && "$CLAUDE" --resume "$SID" --fork-session --bg)
    NEW=$(printf '%s\n' "$OUT" | sed -n 's/.*backgrounded · \([0-9a-f]\{8\}\).*/\1/p' | head -1)
    [ -n "$NEW" ] || { echo "fork impossible : $OUT" >&2; exit 1; }
    for _ in $(seq 1 20); do       # the fork writes its transcript asynchronously
      N=("$CLAUDE_DIR"/projects/*/"$NEW"*.jsonl); [ ${#N[@]} -gt 0 ] && break; sleep 0.5
    done
    [ ${#N[@]} -gt 0 ] || { echo "la copie $NEW n'apparaît pas — rien n'est déplacé" >&2; exit 1; }
    session-trash "$SID"
    echo "✓ copie locale devenue $NEW" ;;
  c) session-trash "$SID" ;;
  *) echo "rien de fait." ;;
esac
session-reconcile "$SID" >/dev/null 2>&1 || true
```

- [ ] **Step 5: Brancher dans le scan**

Dans `bin/session-index-scan`, juste après `session-hub-sync >/dev/null 2>&1 || true` :

```bash
# Settle copies of sessions migrated away before indexing what remains.
session-reconcile >/dev/null 2>&1 || true
DIVERGED="${CLAUDE_DIR}/session-diverged.json"
```

Passer `"$DIVERGED"` comme 5e argument au bloc python (`python3 - "$REGISTRY" "$MACHINE" "$HOME_DIR" "$TSV" "$DIVERGED"`), lire :

```python
registry, machine, home, tsv, div_path = sys.argv[1:6]
try:
    diverged = set(json.load(open(div_path)))
except (OSError, ValueError):
    diverged = set()
```

et ajouter dans `new[sid]` : `"diverged": sid in diverged,`.

- [ ] **Step 6: Lancer, constater le succès** — `chmod +x bin/session-reconcile bin/session-diverge`, `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add bin/session-reconcile bin/session-diverge bin/session-index-scan tests/test_reconcile.sh
git commit -m "feat: reconcile migrated-away copies — trash if identical, flag if diverged"
```

---

### Task 9: Installation, intégration `cc`, déploiement

**Files:**
- Modify: `install.sh`, `README.md`
- Modify (repo `~/projects/admin/cc`) : create `subjects.zsh`, modify `cc.zsh` (`_cc_tmux`), `test.zsh`
- Modify (repo `~/projects/admin/dotfiles`) : `zshrc`

**Interfaces:**
- Consumes: tout ce qui précède.
- Produces: hook `Stop` câblé (Mac), `cleanupPeriodDays: 365` (les deux), clés de config renseignées, fzf ≥ 0.50 sur Nexus, `cc tmux <sujet>` → `session-layout cc-<sujet> <sujet>`.

- [ ] **Step 1: `install.sh` — hook et rétention**

Ajouter avant l'enregistrement du plugin :

```bash
# ── 2c. Claude Code settings: retention + replication hook ───────────────────
python3 - "$HOME/.claude/settings.json" "$INSTALL_DIR/hooks/stop-replicate" \
  "$(grep -q '^replica_to:' "$HOME/.claude/session-migrate.yml" 2>/dev/null && echo 1 || echo 0)" << 'PYEOF'
import json, os, sys
path, hook, wants_hook = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
s = json.load(open(path)) if os.path.exists(path) else {}
# Claude Code purges transcripts after 30 days by default; the session tools
# archive, replicate and trash on their own clock.
s["cleanupPeriodDays"] = max(int(s.get("cleanupPeriodDays", 0) or 0), 365)
if wants_hook:
    stop = s.setdefault("hooks", {}).setdefault("Stop", [])
    if not any(h.get("command") == hook for e in stop for h in e.get("hooks", [])):
        stop.append({"hooks": [{"type": "command", "command": hook}]})
json.dump(s, open(path + ".tmp", "w"), indent=2); os.replace(path + ".tmp", path)
print("✓  settings: cleanupPeriodDays ≥ 365" + (", Stop hook (replication)" if wants_hook else ""))
PYEOF
```

- [ ] **Step 2: `cc` — sortir `CC_DIRS`, brancher `cc tmux`**

Dans `~/projects/admin/cc` :
1. Créer `subjects.zsh` avec le bloc `typeset -A CC_DIRS=( … )` copié tel quel depuis `~/projects/admin/dotfiles/zshrc:65-71`, précédé de `# Sujets cc — partagés par cc, le .zshrc et les outils session (session-subject-roots).`
2. Dans `cc.zsh`, au début de `_cc_tmux()` après la résolution de `d` :

```zsh
  # Layout à deux volets (liste de sessions + volet principal) quand l'outil
  # session est installé ; sinon, l'ancienne session tmux simple.
  if (( $+commands[session-layout] || $+functions[session-layout] )); then
    session-layout cc-$subject $subject
    return
  fi
```

3. Dans `test.zsh`, ajouter après les mocks :

```zsh
check "tmux délègue à session-layout quand il existe" \
  "session-layout cc-lp lp" \
  zsh -c "session-layout() { print -r -- \"session-layout \$@\" }; $(typeset -f claude tmux); typeset -A CC_DIRS=(lp $T/lp); source $ROOT/cc.zsh; cc tmux lp"
```

Run: `./test.zsh` → tous `ok`. Commit dans le repo `cc` : `cc tmux : délègue au layout à deux volets de session-layout`.

4. Dans `~/projects/admin/dotfiles/zshrc`, remplacer le bloc `typeset -A CC_DIRS=( … )` (lignes 65-71) par :

```zsh
[[ -r ~/projects/admin/cc/subjects.zsh ]] && source ~/projects/admin/cc/subjects.zsh
```

Commit dans le repo dotfiles : `zshrc : CC_DIRS vient de cc/subjects.zsh`.

- [ ] **Step 3: README**

Ajouter une section `## Session manager` après `### 6. Headless purge` : disposition tmux, touches (tableau de la spec), migration (les deux cas source joignable / réplique), corbeille et divergences, nouvelles clés de config (`subjects_file`, `replica_to`, `claude_bin`). Mettre à jour `### 3. Cross-machine resume` : renvoyer vers `session-migrate` + `session-open`.

- [ ] **Step 4: Suite complète** — `bash tests/run_tests.sh 2>&1 | tail -3` → `0 failed`. Commit : `docs+install: session manager wiring`.

- [ ] **Step 5: Déployer (avec Yann, après merge de la PR)**

Mac :
```bash
git -C ~/.claude/skills/session pull          # le hook git rafraîchit le cache du plugin
grep -q '^subjects_file:' ~/.claude/session-migrate.yml || echo 'subjects_file: /Users/yannrapaport/projects/admin/cc/subjects.zsh' >> ~/.claude/session-migrate.yml
grep -q '^replica_to:'    ~/.claude/session-migrate.yml || echo 'replica_to: nexus' >> ~/.claude/session-migrate.yml
~/.claude/skills/session/install.sh
git -C ~/projects/admin/cc pull && git -C ~/projects/admin/dotfiles pull
```
Nexus (`ssh nexus`) :
```bash
git -C ~/.claude/skills/session pull
grep -q '^subjects_file:' ~/.claude/session-migrate.yml || echo 'subjects_file: /home/yrapaport/projects/admin/cc/subjects.zsh' >> ~/.claude/session-migrate.yml
grep -q '^claude_bin:'    ~/.claude/session-migrate.yml || echo 'claude_bin: /home/yrapaport/.local/bin/claude' >> ~/.claude/session-migrate.yml
~/.claude/skills/session/install.sh
git -C ~/projects/admin/cc pull && git -C ~/projects/admin/dotfiles pull
# fzf récent, sans toucher au paquet Debian
curl -fsSL https://github.com/junegunn/fzf/releases/download/v0.65.0/fzf-0.65.0-linux_amd64.tar.gz | tar -xz -C ~/.local/bin fzf
~/.local/bin/fzf --version   # attendu ≥ 0.50
```
Vérifier que `~/.local/bin` précède `/usr/bin` dans le PATH interactif de Nexus (`which fzf`).

- [ ] **Step 6: Recette réelle** (sur une session jetable, créée pour l'occasion)

1. Mac : `cd ~/projects/tpg && claude` → une question, quitter. `sessions` → la session apparaît, ⌥1 → `!!`.
2. Mac : vérifier la réplique : `ssh nexus ls ~/.claude/session-replica/mac/` contient l'id.
3. Mac : fermer l'écran (ou `sudo ifconfig en0 down` le temps du test, puis `up`).
4. Nexus : `sessions` → ⏎ sur la session → message « réplique du … », confirmer → la session s'ouvre à droite et répond au contexte.
5. Mac réveillé : attendre le scan (≤ 15 min) ou lancer `session-index-scan` → la copie Mac est dans `~/.claude/session-trash/`.
6. Refaire 1-4 en continuant la session sur le Mac **avant** le scan → `⚠` dans la liste Mac ; ⏎ → `g` → nouvelle session listée, ancienne en corbeille.

- [ ] **Step 7: Fermer la PR #2** (remplacée) avec un commentaire pointant la PR de cette branche.
