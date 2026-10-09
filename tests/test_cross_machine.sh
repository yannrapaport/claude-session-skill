#!/usr/bin/env bash
# tests/test_cross_machine.sh — sourced by run_tests.sh
# Whole flows across both machines: where a migrated session lives, who acts
# on a diverged copy, hub races, replica clean-up.
echo "--- test_cross_machine ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
M="$MTMP/mac"; N="$MTMP/nexus"
MENC=$(session-encode-path "$M/projects/tpg/rakam")
NENC=$(session-encode-path "$N/projects/tpg/rakam")
reg() {  # <on-machine> <registry-machine> <sid> <key>
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(d["machines"].get(sys.argv[2],{}).get(sys.argv[3],{}).get(sys.argv[4],"-"))' \
    "$MTMP/$1/.claude/session-hub/registry.json" "$2" "$3" "$4"
}
yn() { "$@" && echo yes || echo no; }

# ── C1: the destination places a migrated session where it landed ───────────
R=a1a1a1a1-1111-2222-3333-444444444444
mk_session mac "$R" "$M/projects/tpg/rakam" '{"type":"assistant","uuid":"r2"}' >/dev/null
on mac session-index-scan >/dev/null 2>&1
rc=0; on nexus session-migrate "$R" --yes >/dev/null 2>&1 || rc=$?
assert_eq "C1: mac → nexus migrates" "0" "$rc"
assert_eq "C1: session-cwd reads the override" "$N/projects/tpg/rakam" \
  "$(on nexus session-cwd "$N/.claude/projects/$NENC/$R.jsonl")"
assert_eq "C1: session-cwd without override = transcript cwd" "$M/projects/tpg/rakam" \
  "$(on mac session-cwd "$(mk_session mac b1b1b1b1-0000-0000-0000-000000000000 "$M/projects/tpg/rakam")")"
rm -f "$M/.claude/projects/$MENC/b1b1b1b1-0000-0000-0000-000000000000.jsonl"
on nexus session-index-scan >/dev/null 2>&1
on mac session-index-scan >/dev/null 2>&1          # mac's copy is gone: its entry too
on nexus session-hub-sync >/dev/null 2>&1
assert_eq "C1: nexus scan: cwd"              "$N/projects/tpg/rakam" "$(reg nexus nexus "$R" cwd)"
assert_eq "C1: nexus scan: project_relative" "projects/tpg/rakam"    "$(reg nexus nexus "$R" project_relative)"
assert_eq "C1: nexus scan: cc_subject"       "tpg"                   "$(reg nexus nexus "$R" cc_subject)"
assert_eq "C1: nexus scan: cc_rel"           "rakam"                 "$(reg nexus nexus "$R" cc_rel)"
assert_eq "C1: mac entry pruned"             "-"                     "$(reg nexus mac "$R" cwd)"
mkdir -p "$MTMP/st"; echo subject > "$MTMP/st/scope"; echo tpg > "$MTMP/st/subject"
assert_eq "C1: listed under its subject" "1" \
  "$(on nexus env SESSIONS_STATE="$MTMP/st" session-rows | grep -c "^$R" || true)"
# Round trip: back to the Mac, into its original directory.
rc=0; out=$(on mac session-migrate "$R" --yes 2>&1) || rc=$?
assert_eq "C1: nexus → mac migrates back" "0" "$rc"
[ "$rc" = 0 ] || echo "$out"
assert_eq "C1: lands in the Mac's original directory" "yes" "$(yn test -f "$M/.claude/projects/$MENC/$R.jsonl")"
assert_eq "C1: mac override = original cwd" "$M/projects/tpg/rakam" "$(cat "$M/.claude/session-cwd-override/$R" 2>/dev/null)"
assert_eq "C1: nexus copy settled" "no" "$(yn test -f "$N/.claude/projects/$NENC/$R.jsonl")"

# ── C2: a diverged copy elsewhere never routes the owner's copy ──────────────
X=c2c2c2c2-1111-2222-3333-444444444444
FX=$(mk_session nexus "$X" "$N/projects/tpg/rakam")
on nexus session-metastore set "$X" owner '"nexus"'
python3 - "$N/.claude/session-hub/registry.json" "$X" <<'PY'
import json, sys
p, x = sys.argv[1:]
d = json.load(open(p))
d["machines"].setdefault("mac", {})[x] = {"cwd": "/m", "last_activity": "2099-01-01T00:00:00Z", "diverged": True}
d["machines"].setdefault("nexus", {})[x] = {"cwd": "/n", "last_activity": "2026-01-01T00:00:00Z", "diverged": False}
json.dump(d, open(p, "w"))
PY
assert_eq "C2: registry-get --machine" "nexus False" \
  "$(on nexus session-registry-get --machine nexus "$X" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["machine"],d["diverged"])')"
assert_eq "C2: registry-get --machine absent" "{}" "$(on nexus session-registry-get --machine elsewhere "$X")"
# The panel's rows carry THIS machine's divergence, not the merged row's.
cp "$N/.claude/session-hub/registry.json" "$M/.claude/session-hub/registry.json"
_div() { on "$1" session-rows --json | python3 -c 'import json,sys;print([r["diverged"] for r in json.load(sys.stdin) if r["id"]==sys.argv[1]])' "$X"; }
_cmd() { PYTHONPATH="$SCRIPT_DIR/.." python3 -c '
import sys
from pathlib import Path
from panel.model import Session
from panel.actions import Actions
a = Actions(None, sys.argv[1], Path("/tmp"))
print(a.command_for(Session(sys.argv[2], "nexus", "", "", "", "", "", "", "", False, False, sys.argv[3] == "True")))' "$1" "$X" "$2"; }
assert_eq "C2: rows --json on the owner: not diverged" "[False]" "$(_div nexus)"
assert_eq "C2: owner opens its own copy" "['session-open', '$X']" "$(_cmd nexus "$(_div nexus | tr -d '[]')")"
assert_eq "C2: rows --json on mac: diverged" "[True]" "$(_div mac)"
assert_eq "C2: mac's diverged copy → diverge menu" "['session-diverge', '$X']" "$(_cmd mac True)"
git -C "$M/.claude/session-hub" checkout -q -- registry.json 2>/dev/null || true
git -C "$N/.claude/session-hub" checkout -q -- registry.json   # drop the hand-made entries
rc=0; echo c | on nexus session-diverge "$X" >/dev/null 2>&1 || rc=$?
assert_eq "C2: diverge refused on the owner" "1" "$rc"
assert_eq "C2: owner's copy untouched" "yes" "$(yn test -f "$FX")"
FORK=f2f2f2f2-1111-2222-3333-444444444444
mk_session nexus "$FORK" "$N/projects/tpg/rakam" >/dev/null
echo "{\"$X\": \"$FORK\"}" > "$N/.claude/session-forks.json"
on nexus session-reconcile >/dev/null 2>&1
assert_eq "C2: link to a locally owned original never trashes it" "yes" "$(yn test -f "$FX")"

# ── I1: another machine pushes between migrate's sync and its push ───────────
S1=d1d1d1d1-1111-2222-3333-444444444444
mk_session mac "$S1" "$M/projects/tpg/rakam" >/dev/null
on mac session-index-scan >/dev/null 2>&1
REALGIT=$(command -v git)
mkdir -p "$MTMP/gitrace"
cat > "$MTMP/gitrace/git" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" push "* ]] && [ ! -e "$MTMP/raced" ]; then
  touch "$MTMP/raced"
  ( cd "$M/.claude/session-hub" && echo x > race.txt && "$REALGIT" add race.txt \
    && "$REALGIT" commit -qm race && "$REALGIT" push -q origin HEAD ) >/dev/null 2>&1
fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$MTMP/gitrace/git"
rc=0; on nexus env PATH="$MTMP/gitrace:$PATH" session-migrate "$S1" --yes >/dev/null 2>&1 || rc=$?
assert_eq "I1: race happened" "yes" "$(yn test -e "$MTMP/raced")"
assert_eq "I1: migration succeeds despite the race" "0" "$rc"
assert_eq "I1: owner on hub" "nexus" \
  "$(git -C "$MTMP/hub.git" show "main:meta/$S1.json" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))' 2>/dev/null)"
assert_eq "I1: other machine's commit kept" "x" "$(git -C "$MTMP/hub.git" show main:race.txt 2>/dev/null)"
# The race touched this very session's meta → rebase conflict → clean rollback.
S2=d2d2d2d2-1111-2222-3333-444444444444
mk_session mac "$S2" "$M/projects/tpg/rakam" >/dev/null
on mac session-index-scan >/dev/null 2>&1
sed -e "s|race.txt|meta/$S2.json|g" -e "s|echo x >|echo '{\"priority\": \"must\"}' >|" \
    -e "s|$MTMP/raced|$MTMP/raced2|g" "$MTMP/gitrace/git" > "$MTMP/gitrace/git.2"
mkdir -p "$MTMP/gitrace2"; mv "$MTMP/gitrace/git.2" "$MTMP/gitrace2/git"; chmod +x "$MTMP/gitrace2/git"
rc=0; on nexus env PATH="$MTMP/gitrace2:$PATH" session-migrate "$S2" --yes >/dev/null 2>&1 || rc=$?
assert_eq "I1 conflict: race happened" "yes" "$(yn test -e "$MTMP/raced2")"
assert_eq "I1 conflict: refused" "1" "$rc"
assert_eq "I1 conflict: nothing installed" "no" "$(yn test -e "$N/.claude/projects/$NENC/$S2.jsonl")"
assert_eq "I1 conflict: no rebase left over" "no" "$(yn test -d "$N/.claude/session-hub/.git/rebase-merge" -o -d "$N/.claude/session-hub/.git/rebase-apply")"
assert_eq "I1 conflict: hub keeps the other machine's meta" "must" \
  "$(git -C "$MTMP/hub.git" show "main:meta/$S2.json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("priority",""))')"
assert_eq "I1 conflict: local meta not owned by nexus" "" \
  "$(on nexus session-metastore get "$S2" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))')"
assert_eq "I1 conflict: hub clone clean" "" "$(git -C "$N/.claude/session-hub" status --porcelain -- "meta/$S2.json")"

# ── I4: a confirmation outside a terminal says why and how ───────────────────
# ── I2: a replica the Stop hook recreates after a from-replica migration ─────
G=e2e2e2e2-1111-2222-3333-444444444444
GF=$(mk_session mac "$G" "$M/projects/tpg/rakam")
touch -t 202001010000 "$GF"
on mac session-index-scan >/dev/null 2>&1
on mac session-replicate "$G"
down mac
rc=0; out=$(on nexus session-migrate "$G" </dev/null 2>&1) || rc=$?
assert_eq "I4: no tty: refused" "1" "$rc"
assert_eq "I4: no tty: says how to proceed" "yes" "$(yn grep -q -- "--yes" <<<"$out")"
rc=0; on nexus session-migrate "$G" --yes >/dev/null 2>&1 || rc=$?
up mac
assert_eq "I2: from replica: migrates" "0" "$rc"
assert_eq "M2: replica install keeps the mtime" "$(python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$GF")" \
  "$(python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$N/.claude/projects/$NENC/$G.jsonl")"
on mac session-replicate "$G"                    # Stop hook: mac's hub clone is stale
assert_eq "I2: replica recreated by the hook" "yes" "$(yn test -f "$N/.claude/session-replica/mac/$G/$G.jsonl")"
on mac session-replicate
assert_eq "I2: full replicate removes it (nexus owns it)" "no" "$(yn test -d "$N/.claude/session-replica/mac/$G")"

# ── I3: a fail-closed reconcile is visible in the scan's output ──────────────
Z=f3f3f3f3-1111-2222-3333-444444444444
ZF=$(mk_session mac "$Z" "$M/projects/tpg/rakam")
on mac session-metastore set "$Z" owner '"nexus"'
on mac session-metastore set "$Z" fingerprint "$(session-fingerprint "$ZF")"
on mac session-hub-push "z" >/dev/null 2>&1
echo garbage > "$M/.agents.json"
err=$(on mac session-index-scan 2>&1 >/dev/null || true)
echo '[]' > "$M/.agents.json"
assert_eq "I3: reconcile failure reaches the scan's stderr" "yes" "$(yn grep -q illisible <<<"$err")"

# ── M1: ids are validated before any path is built ───────────────────────────
rc=0; on mac session-open "../x" >/dev/null 2>&1 || rc=$?
assert_eq "M1: open rejects a bad id" "1" "$rc"
rc=0; on mac session-priority "../x" must >/dev/null 2>&1 || rc=$?
assert_eq "M1: priority rejects a bad id" "1" "$rc"
assert_eq "M1: priority wrote nothing" "no" "$(yn test -e "$M/.claude/session-hub/x.json")"
rc=0; on mac session-metastore set "../evil" owner '"x"' >/dev/null 2>&1 || rc=$?
assert_eq "M1: metastore set rejects a bad id" "1 no" "$rc $(yn test -e "$M/.claude/session-hub/evil.json")"
rc=0; on mac session-metastore get "a/b" >/dev/null 2>&1 || rc=$?
assert_eq "M1: metastore get rejects a bad id" "1" "$rc"

# ── M2: equal activity → the owner's copy is the row shown ───────────────────
T=a2a2a2a2-1111-2222-3333-444444444444
VH=$(mktemp -d); mkdir -p "$VH/meta"
cat > "$VH/registry.json" <<EOF
{"version": 2, "machines": {
  "mac":   {"$T": {"last_activity": "2026-10-08T10:00:00Z", "cwd": "/m"}},
  "nexus": {"$T": {"last_activity": "2026-10-08T10:00:00Z", "cwd": "/n"}}}}
EOF
row() { HUB_DIR_OVERRIDE="$VH" session-index-view | python3 -c 'import json,sys;r=json.load(sys.stdin)[0];print(r["machine"],",".join(r["also_on"]))'; }
echo '{"owner": "nexus"}' > "$VH/meta/$T.json"
assert_eq "M2: tie → owner nexus shown" "nexus mac" "$(row)"
echo '{"owner": "mac"}' > "$VH/meta/$T.json"
assert_eq "M2: tie → owner mac shown" "mac nexus" "$(row)"
rm -rf "$VH"
machines_teardown
