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
owner_of() { on "$1" session-metastore get "$2" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))'; }
owner() { owner_of "$1" "$SID"; }

# Fingerprint
FP=$(session-fingerprint "$F")
assert_eq "fingerprint last_uuid" "u2" "$(echo "$FP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["last_uuid"])')"
SZ=$(echo "$FP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["size"])')
SH=$(echo "$FP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha256"])')
echo '{"type":"user","uuid":"u3"}' >> "$F"
rc=0; session-fingerprint --prefix "$F" "$SZ" "$SH" || rc=$?
assert_eq "prefix matches a grown file" "0" "$rc"

# Source down, no replica → refuse, nothing installed.
# (The scan above already replicated it to nexus: drop that replica.)
rm -rf "$N/.claude/session-replica/mac/$SID"
down mac
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
assert_eq "down + no replica: refused" "1" "$rc"
assert_eq "down + no replica: nothing installed" "no" "$([ -f "$N/.claude/projects/$NENC/$SID.jsonl" ] && echo yes || echo no)"
up mac

# An unrelated, uncommitted hub edit must survive migrations (pushed or not).
OH="$N/.claude/session-hub"
mkdir -p "$OH/meta"; echo '{"owner": "mac"}' > "$OH/meta/other.json"
git -C "$OH" add meta/other.json; git -C "$OH" commit -qm other; git -C "$OH" push -q origin HEAD
echo '{"owner": "local edit"}' > "$OH/meta/other.json"

# Hub push refused → rollback (Review Focus 3).
chmod -w "$MTMP/hub.git/objects"
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
chmod +w "$MTMP/hub.git/objects"
assert_eq "push refused: fails" "1" "$rc"
assert_eq "push refused: files rolled back" "no" "$([ -e "$N/.claude/projects/$NENC/$SID.jsonl" ] && echo yes || echo no)"
assert_eq "push refused: meta rolled back" "" "$(owner nexus)"
assert_eq "push refused: dest project dir removed" "no" "$([ -d "$N/.claude/projects/$NENC" ] && echo yes || echo no)"
assert_eq "push refused: unrelated hub edit kept" " M meta/other.json" "$(git -C "$OH" status --porcelain -- meta/other.json)"
assert_eq "push refused: local commit undone" "$(git -C "$MTMP/hub.git" rev-parse main)" "$(git -C "$OH" rev-parse HEAD)"

# Source reachable → copy from it, push, source copy trashed.
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
assert_eq "reachable: migrates" "0" "$rc"
assert_eq "reachable: transcript installed" "yes" "$([ -f "$N/.claude/projects/$NENC/$SID.jsonl" ] && echo yes || echo no)"
assert_eq "reachable: session dir installed" "yes" "$([ -f "$N/.claude/projects/$NENC/$SID/tool-results/t1" ] && echo yes || echo no)"
assert_eq "owner is nexus (seen from mac)" "nexus" "$(on mac session-hub-sync >/dev/null 2>&1; owner mac)"
assert_eq "cwd override written" "$N/projects/tpg/rakam" "$(cat "$N/.claude/session-cwd-override/$SID")"
assert_eq "migrated: unrelated hub edit still uncommitted" " M meta/other.json" "$(git -C "$OH" status --porcelain -- meta/other.json)"
assert_eq "migrated: unrelated hub edit not pushed" '{"owner": "mac"}' "$(git -C "$MTMP/hub.git" show main:meta/other.json)"

# Destination already holds the id → refuse (Review Focus 1).
on nexus session-metastore set "$SID" owner '"mac"'
rc=0; on nexus session-migrate "$SID" --yes >/dev/null 2>&1 || rc=$?
assert_eq "already here: refused" "1" "$rc"

# Target subject root missing → refuse (Review Focus 5).
G=abababab-1111-2222-3333-444444444444
mk_session mac "$G" "$M/projects/tpg/rakam" >/dev/null
on mac session-index-scan >/dev/null 2>&1
mv "$N/projects/tpg" "$N/projects/tpg.off"
rc=0; on nexus session-migrate "$G" --yes >/dev/null 2>&1 || rc=$?
mv "$N/projects/tpg.off" "$N/projects/tpg"
assert_eq "target missing: refused" "1" "$rc"

# Source supervisor unreadable → refuse (fail closed), nothing installed.
echo garbage > "$M/.agents.json"
rc=0; on nexus session-migrate "$G" --yes >/dev/null 2>&1 || rc=$?
echo '[]' > "$M/.agents.json"
assert_eq "source state unreadable: refused" "1" "$rc"
assert_eq "source state unreadable: nothing installed" "no" "$([ -f "$N/.claude/projects/$NENC/$G.jsonl" ] && echo yes || echo no)"

# Invalid id → refused before any path is built.
rc=0; on nexus session-migrate "../x" --yes >/dev/null 2>&1 || rc=$?
assert_eq "invalid id: refused" "1" "$rc"

# Source still running after `claude stop` → refused, nothing installed.
echo "[{\"sessionId\": \"$G\", \"pid\": 4242}]" > "$M/.agents.json"
rc=0; on nexus env SESSION_STOP_WAIT=1 session-migrate "$G" --yes >/dev/null 2>&1 || rc=$?
echo '[]' > "$M/.agents.json"
assert_eq "source won't stop: refused" "1" "$rc"
assert_eq "source won't stop: stop was asked" "yes" "$(grep -q "^mac stop ${G:0:8}" "$MTMP/claude.log" && echo yes || echo no)"
assert_eq "source won't stop: nothing installed" "no" "$([ -f "$N/.claude/projects/$NENC/$G.jsonl" ] && echo yes || echo no)"

# Copy of an optional part fails → refused, nothing installed, meta unchanged.
H=cdcdcdcd-1111-2222-3333-444444444444
HF=$(mk_session mac "$H" "$M/projects/tpg/rakam")
mkdir -p "${HF%.jsonl}/tool-results"; echo r > "${HF%.jsonl}/tool-results/t1"
mkdir -p "$M/.claude/file-history/$H"; echo v1 > "$M/.claude/file-history/$H/f@v1"
on mac session-index-scan >/dev/null 2>&1
printf '%s' "$H/" > "$MTMP/fail.rsync.match"
rc=0; on nexus session-migrate "$H" --yes >/dev/null 2>&1 || rc=$?
printf '%s' "file-history" > "$MTMP/fail.rsync.match"
rc2=0; on nexus session-migrate "$H" --yes >/dev/null 2>&1 || rc2=$?
rm -f "$MTMP/fail.rsync.match"
assert_eq "dir copy fails: refused" "1" "$rc"
assert_eq "file-history copy fails: refused" "1" "$rc2"
assert_eq "part copy fails: nothing installed" "no" "$([ -e "$N/.claude/projects/$NENC/$H.jsonl" ] || [ -e "$N/.claude/file-history/$H" ] && echo yes || echo no)"
assert_eq "part copy fails: meta unchanged" "" "$(owner_of nexus "$H")"
rc=0; on nexus session-migrate "$H" --yes >/dev/null 2>&1 || rc=$?
assert_eq "all parts: migrates" "0" "$rc"
assert_eq "all parts: file-history installed" "v1" "$(cat "$N/.claude/file-history/$H/f@v1" 2>/dev/null)"

# Target can't land here + source running → refused before stopping anything.
K=dededede-1111-2222-3333-444444444444
KF=$(mk_session mac "$K" "$M/projects/tpg/rakam")
mkdir -p "${KF%.jsonl}/tool-results"; echo r > "${KF%.jsonl}/tool-results/t1"
on mac session-index-scan >/dev/null 2>&1
echo "[{\"sessionId\": \"$K\", \"pid\": 4242}]" > "$M/.agents.json"
mv "$N/projects/tpg" "$N/projects/tpg.off"
rc=0; on nexus env SESSION_STOP_WAIT=1 session-migrate "$K" --yes >/dev/null 2>&1 || rc=$?
mv "$N/projects/tpg.off" "$N/projects/tpg"
echo '[]' > "$M/.agents.json"
assert_eq "target missing + running: refused" "1" "$rc"
assert_eq "target missing + running: source not stopped" "no" "$(grep -q "^mac stop ${K:0:8}" "$MTMP/claude.log" && echo yes || echo no)"

# Orphan <id>/ dir at the destination → refused, orphan untouched.
mkdir -p "$N/.claude/projects/$NENC/$K"; echo mine > "$N/.claude/projects/$NENC/$K/keep"
rc=0; on nexus session-migrate "$K" --yes >/dev/null 2>&1 || rc=$?
assert_eq "orphan dir here: refused" "1" "$rc"
assert_eq "orphan dir here: untouched" "mine" "$(cat "$N/.claude/projects/$NENC/$K/keep" 2>/dev/null)"
rm -r "$N/.claude/projects/$NENC/$K"

# A failure between install and push rolls everything back, meta included.
mkdir -p "$OH/meta"; echo '{"priority": "high"}' > "$OH/meta/$K.json"
git -C "$OH" add "meta/$K.json"; git -C "$OH" commit -qm "prio K" -- "meta/$K.json"; git -C "$OH" push -q origin HEAD
K0=$(cat "$OH/meta/$K.json")
mkdir -p "$MTMP/fpfail"; printf '#!/bin/sh\nexit 1\n' > "$MTMP/fpfail/session-fingerprint"
cat > "$MTMP/fpfail/session-metastore.wrap" <<EOF2
#!/usr/bin/env bash
[ "\$1 \${3:-}" = "set fingerprint" ] && exit 1
exec "$SCRIPT_DIR/../bin/session-metastore" "\$@"
EOF2
mkdir -p "$MTMP/msfail"; mv "$MTMP/fpfail/session-metastore.wrap" "$MTMP/msfail/session-metastore"
chmod +x "$MTMP/fpfail/session-fingerprint" "$MTMP/msfail/session-metastore"
for d in fpfail msfail; do
  rc=0; on nexus env PATH="$MTMP/$d:$PATH" session-migrate "$K" --yes >/dev/null 2>&1 || rc=$?
  assert_eq "$d: refused" "1" "$rc"
  assert_eq "$d: nothing installed" "no" "$([ -e "$N/.claude/projects/$NENC/$K.jsonl" ] || [ -e "$N/.claude/projects/$NENC/$K" ] && echo yes || echo no)"
  assert_eq "$d: meta file unchanged" "$K0" "$(cat "$OH/meta/$K.json")"
  assert_eq "$d: meta not staged or modified" "" "$(git -C "$OH" status --porcelain -- "meta/$K.json")"
done

# Hub lock held by another writer → migrate and hub-push wait, then refuse.
mkdir "$OH/.lock"
SECONDS=0
rc=0; on nexus env SESSION_LOCK_WAIT=1 session-migrate "$K" --yes >/dev/null 2>&1 || rc=$?
assert_eq "hub locked: migrate refused" "1" "$rc"
assert_eq "hub locked: migrate bounded wait" "yes" "$([ "$SECONDS" -le 6 ] && echo yes || echo no)"
assert_eq "hub locked: nothing installed" "no" "$([ -e "$N/.claude/projects/$NENC/$K.jsonl" ] && echo yes || echo no)"
assert_eq "hub locked: other's lock kept" "yes" "$([ -d "$OH/.lock" ] && echo yes || echo no)"
echo '{"x": 1}' > "$OH/meta/zz.json"
H0=$(git -C "$OH" rev-parse HEAD)
rc=0; on nexus env SESSION_LOCK_WAIT=1 session-hub-push "zz" >/dev/null 2>&1 || rc=$?
assert_eq "hub locked: hub-push refused" "1" "$rc"
assert_eq "hub locked: hub-push committed nothing" "$H0" "$(git -C "$OH" rev-parse HEAD)"
touch -t 202001010000 "$OH/.lock"           # holder died long ago
rc=0; on nexus env SESSION_LOCK_WAIT=1 session-hub-push "zz" >/dev/null 2>&1 || rc=$?
assert_eq "stale lock: taken over" "0" "$rc"
assert_eq "stale lock: released after push" "no" "$([ -e "$OH/.lock" ] && echo yes || echo no)"
assert_eq "lock never tracked" "" "$(git -C "$OH" ls-files | grep -F .lock || true)"

# Push reports a failure but reached the hub → the migration stands.
REALGIT=$(command -v git)
mkdir -p "$MTMP/gitfail"
cat > "$MTMP/gitfail/git" <<EOF2
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = push ] && { "$REALGIT" "\$@"; exit 1; }; done
exec "$REALGIT" "\$@"
EOF2
chmod +x "$MTMP/gitfail/git"
rc=0; on nexus env PATH="$MTMP/gitfail:$PATH" session-migrate "$K" --yes >/dev/null 2>&1 || rc=$?
assert_eq "push landed despite error: migrates" "0" "$rc"
assert_eq "push landed despite error: installed" "yes" "$([ -f "$N/.claude/projects/$NENC/$K/tool-results/t1" ] && echo yes || echo no)"
assert_eq "push landed despite error: owner on hub" "nexus" "$(git -C "$MTMP/hub.git" show "main:meta/$K.json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))')"

# Lock ownership: a foreign token can't release it; its contents are never staged.
TOK=$(on nexus session-hub-lock acquire)
assert_eq "lock: token printed" "yes" "$([ -n "$TOK" ] && echo yes || echo no)"
on nexus session-hub-lock release "pid=0 host=elsewhere rnd=1"
assert_eq "lock: foreign token leaves it" "yes" "$([ -d "$OH/.lock" ] && echo yes || echo no)"
assert_eq "lock: contents never in git status" "" "$(git -C "$OH" status --porcelain --untracked-files=all | grep -F .lock || true)"
# Held lock: sync skips its pull (exit 0), priority refuses and writes nothing.
on mac session-priority "$SID" must >/dev/null 2>&1
H0=$(git -C "$OH" rev-parse HEAD)
rc=0; on nexus env SESSION_LOCK_WAIT=1 session-hub-sync >/dev/null 2>&1 || rc=$?
assert_eq "lock: sync exits 0" "0" "$rc"
assert_eq "lock: sync skipped the pull" "$H0" "$(git -C "$OH" rev-parse HEAD)"
rc=0; on nexus env SESSION_LOCK_WAIT=1 session-priority "$K" may >/dev/null 2>&1 || rc=$?
assert_eq "lock: priority refused" "1" "$rc"
assert_eq "lock: priority wrote nothing" "" "$(git -C "$OH" status --porcelain -- "meta/$K.json")"
on nexus session-hub-lock release "$TOK"
assert_eq "lock: owner releases it" "no" "$([ -e "$OH/.lock" ] && echo yes || echo no)"
on nexus session-hub-sync >/dev/null 2>&1
assert_eq "lock: sync pulls once free" "must" "$(on nexus session-metastore get "$SID" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("priority",""))')"
rc=0; on nexus session-priority "$K" may >/dev/null 2>&1 || rc=$?
assert_eq "priority: set under the lock" "may" "$(git -C "$MTMP/hub.git" show "main:meta/$K.json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("priority",""))')"

# Push error and the check fails too → nothing undone, warning, exit 0; the
# next hub-push sends the commit.
P=efefefef-1111-2222-3333-444444444444
mk_session mac "$P" "$M/projects/tpg/rakam" >/dev/null
on mac session-index-scan >/dev/null 2>&1
mkdir -p "$MTMP/gitblind"
cat > "$MTMP/gitblind/git" <<EOF2
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in push|fetch) exit 1 ;; esac; done
exec "$REALGIT" "\$@"
EOF2
chmod +x "$MTMP/gitblind/git"
out=$(on nexus env PATH="$MTMP/gitblind:$PATH" session-migrate "$P" --yes 2>&1) && rc=0 || rc=$?
assert_eq "unverifiable push: exit 0" "0" "$rc"
assert_eq "unverifiable push: warns" "yes" "$(grep -q "non vérifiable" <<<"$out" && echo yes || echo no)"
assert_eq "unverifiable push: installed" "yes" "$([ -f "$N/.claude/projects/$NENC/$P.jsonl" ] && echo yes || echo no)"
assert_eq "unverifiable push: local commit kept" "yes" "$(git -C "$OH" log -1 --format=%s | grep -q "migrate: ${P:0:8}" && echo yes || echo no)"
assert_eq "unverifiable push: not on hub yet" "no" "$(git -C "$MTMP/hub.git" cat-file -e "main:meta/$P.json" 2>/dev/null && echo yes || echo no)"
on nexus session-hub-push "later" >/dev/null 2>&1
assert_eq "unverifiable push: next push confirms" "nexus" "$(git -C "$MTMP/hub.git" show "main:meta/$P.json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("owner",""))')"

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
# Same id trashed again the same day → a second entry, the first intact.
G1=$(cat "$T/$G.jsonl")
mk_session nexus "$G" "$N/projects/tpg/rakam" '{"type":"user","uuid":"second"}' >/dev/null
on nexus session-trash "$G" >/dev/null 2>&1
assert_eq "trash twice: two entries" "2" "$(ls -d "$N"/.claude/session-trash/*/"$G"* | wc -l | tr -d ' ')"
assert_eq "trash twice: first intact" "$G1" "$(cat "$T/$G.jsonl")"
assert_eq "trash twice: second kept" "yes" "$(grep -lq '"second"' "$N"/.claude/session-trash/*/"$G".*/"$G.jsonl" && echo yes || echo no)"
machines_teardown
