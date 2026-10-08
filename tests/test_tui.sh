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
case "$L" in *"new-session -d -s cc-tpg"*"set-option -w -t cc-tpg @sessions_main %1"*"split-window -h -b -l 38 -P -F #{pane_id} -t %1"*"session-tui"*) r=ok ;; *) r="$L" ;; esac
assert_eq "layout creates two panes" "ok" "$r"
: > "$MTMP/tmux.log"
STUB_TMUX_HAS=0 on mac session-layout cc-tpg tpg
case "$(cat "$MTMP/tmux.log")" in *new-session*) r=recreated ;; *) r=ok ;; esac
assert_eq "layout reuses existing session" "ok" "$r"
case "$L" in *"set-option -p -t %1 remain-on-exit on"*) r=ok ;; *) r=missing ;; esac
assert_eq "layout: main pane remain-on-exit" "ok" "$r"
case "$L" in *"@sessions_list %2"*) r=ok ;; *) r=missing ;; esac
assert_eq "layout: list pane id stored" "ok" "$r"
: > "$MTMP/tmux.log"
STUB_TMUX_HAS=0 STUB_LIST_GONE=1 on mac session-layout cc-tpg tpg
case "$(cat "$MTMP/tmux.log")" in *"split-window -h -b -l 38"*) r=ok ;; *) r=no-split ;; esac
assert_eq "layout repairs a missing list pane" "ok" "$r"
: > "$MTMP/tmux.log"
STUB_TMUX_HAS=0 STUB_LIST_OPT= on mac session-layout cc-tpg tpg
case "$(cat "$MTMP/tmux.log")" in *"split-window"*) r=ok ;; *) r=no-split ;; esac
assert_eq "layout repairs an unrecorded list pane" "ok" "$r"
: > "$MTMP/tmux.log"
STUB_TMUX_HAS=0 on mac session-layout cc-tpg tpg
case "$(cat "$MTMP/tmux.log")" in *split-window*) r=split ;; *) r=ok ;; esac
assert_eq "layout leaves a healthy list pane alone" "ok" "$r"

# Failures stay visible; the respawn carries the subject.
: > "$MTMP/tmux.log"
on mac session-tui-act open "$SID"
case "$(tail -1 "$MTMP/tmux.log")" in *"échec"*"pour revenir"*"session-home"*tpg*) r=ok ;; *) r="$(tail -1 "$MTMP/tmux.log")" ;; esac
assert_eq "respawn chain shows failures and passes subject" "ok" "$r"
unset SESSIONS_STATE
machines_teardown
