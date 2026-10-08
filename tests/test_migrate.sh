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
