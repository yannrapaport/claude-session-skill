#!/usr/bin/env bash
# tests/test_rows.sh — sourced by run_tests.sh
echo "--- test_rows ---"
source "$SCRIPT_DIR/lib_machines.sh"
machines_setup
H="$MTMP/mac/.claude/session-hub"
cat > "$H/registry.json" <<'JSON'
{"version": 2, "machines": {
 "mac":   {"old": {"cwd": "/x", "project_relative": "projects/tpg/rakam", "cc_subject": "tpg", "cc_rel": "rakam",
                   "last_activity": "2026-10-01T10:00:00Z", "title": "Vieux", "turns": 3, "status": "active"},
           "new": {"cwd": "/y", "project_relative": "ai-brain", "cc_subject": "brain", "cc_rel": "",
                   "last_activity": "2026-10-08T10:00:00Z", "title": "Récent", "turns": 9, "status": "active"}},
 "nexus": {"mid": {"cwd": "/z", "project_relative": "projects/tpg", "cc_subject": "tpg", "cc_rel": "",
                   "last_activity": "2026-10-05T10:00:00Z", "title": "Milieu", "turns": 5, "status": "active",
                   "diverged": true}}}}
JSON
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
