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
