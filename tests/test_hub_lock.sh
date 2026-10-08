#!/usr/bin/env bash
# tests/test_hub_lock.sh — sourced by run_tests.sh. session-hub-lock in isolation.
echo "--- test_hub_lock ---"
LTMP=$(mktemp -d "${TMPDIR:-/tmp}/hublock.XXXXXX")
LH="$LTMP/hub"; LL="$LH/.lock"; LT="$LL.takeover"
mkdir -p "$LH"; git -C "$LH" init -q
export HUB_DIR_OVERRIDE="$LH"
# ago <path> <minutes>: set the mtime <minutes> in the past (BSD or GNU date).
ago() { local ts; ts=$(date -v-"$2"M +%Y%m%d%H%M 2>/dev/null || date -d "$2 minutes ago" +%Y%m%d%H%M); touch -t "$ts" "$1"; }
# stale_lock <token>: a .lock whose holder died 20 min ago.
stale_lock() { rm -rf "$LL"; mkdir "$LL"; printf '%s\n' "$1" > "$LL/owner"; ago "$LL" 20; }
subdirs() { find "$LL" -mindepth 1 -type d 2>/dev/null; }

# (1) Fresh lock is never stolen: a fresh one replaces the stale one right after
# the staleness decision → the taker stays busy and times out.
stale_lock "dead holder"
rc=0; SESSION_LOCK_WAIT=1 SESSION_LOCK_TEST_SWAP="fresh holder" session-hub-lock acquire >/dev/null 2>&1 || rc=$?
assert_eq "swap: taker refused" "1" "$rc"
assert_eq "swap: fresh lock keeps its token" "fresh holder" "$(cat "$LL/owner")"
assert_eq "swap: no takeover mutex left" "no" "$([ -e "$LT" ] && echo yes || echo no)"
assert_eq "swap: nothing nested in .lock" "" "$(subdirs)"
assert_eq "swap: no renamed leftovers" "" "$(ls -d "$LH"/.lock.* 2>/dev/null || true)"

# (2) Lock re-created by a third party during the takeover: not nested, not stolen.
stale_lock "dead holder"
rc=0; SESSION_LOCK_WAIT=1 SESSION_LOCK_TEST_RECREATE="newcomer" session-hub-lock acquire >/dev/null 2>&1 || rc=$?
assert_eq "recreate: taker refused" "1" "$rc"
assert_eq "recreate: newcomer keeps its token" "newcomer" "$(cat "$LL/owner")"
assert_eq "recreate: nothing nested in .lock" "" "$(subdirs)"
assert_eq "recreate: no takeover mutex left" "no" "$([ -e "$LT" ] && echo yes || echo no)"
assert_eq "recreate: no renamed leftovers" "" "$(ls -d "$LH"/.lock.* 2>/dev/null || true)"

# (3) Two concurrent takers of one stale lock → exactly one wins, the owner is the winner's.
stale_lock "dead holder"
for n in a b; do
  ( rc=0; tok=$(SESSION_LOCK_WAIT=3 session-hub-lock acquire 2>/dev/null) || rc=$?
    printf '%s\n' "$rc" > "$LTMP/rc.$n"; printf '%s\n' "$tok" > "$LTMP/tok.$n" ) &
done
wait
WINS=0; WTOK=""
for n in a b; do [ "$(cat "$LTMP/rc.$n")" = 0 ] && { WINS=$((WINS + 1)); WTOK=$(cat "$LTMP/tok.$n"); }; done
assert_eq "race: exactly one taker wins" "1" "$WINS"
assert_eq "race: owner token is the winner's" "$WTOK" "$(cat "$LL/owner")"
assert_eq "race: nothing nested in .lock" "" "$(subdirs)"
assert_eq "race: no takeover mutex left" "no" "$([ -e "$LT" ] && echo yes || echo no)"
session-hub-lock release "$WTOK"
assert_eq "race: winner releases" "no" "$([ -e "$LL" ] && echo yes || echo no)"

# (4) Abandoned .lock.takeover (older than 2 min) is cleared; acquisition succeeds.
stale_lock "dead holder"; mkdir "$LT"; ago "$LT" 5
rc=0; TOK=$(SESSION_LOCK_WAIT=2 session-hub-lock acquire 2>/dev/null) || rc=$?
assert_eq "abandoned takeover: acquired" "0" "$rc"
assert_eq "abandoned takeover: owner is ours" "$TOK" "$(cat "$LL/owner")"
assert_eq "abandoned takeover: mutex cleared" "no" "$([ -e "$LT" ] && echo yes || echo no)"
session-hub-lock release "$TOK"
# A live takeover (fresh .lock.takeover) is respected: the taker waits, then times out.
stale_lock "dead holder"; mkdir "$LT"
rc=0; SESSION_LOCK_WAIT=1 session-hub-lock acquire >/dev/null 2>&1 || rc=$?
assert_eq "live takeover: taker refused" "1" "$rc"
assert_eq "live takeover: stale lock untouched" "dead holder" "$(cat "$LL/owner")"
assert_eq "live takeover: mutex kept" "yes" "$([ -d "$LT" ] && echo yes || echo no)"
assert_eq "takeover mutex never in git status" "" "$(git -C "$LH" status --porcelain --untracked-files=all | grep -F .lock || true)"
rmdir "$LT"; rm -r "$LL"

# (5) Release with a foreign token leaves the lock; the owner's token frees it.
TOK=$(session-hub-lock acquire)
session-hub-lock release "pid=0 host=elsewhere rnd=1"
assert_eq "release: foreign token leaves the lock" "$TOK" "$(cat "$LL/owner")"
session-hub-lock release "$TOK"
assert_eq "release: owner token frees it" "no" "$([ -e "$LL" ] && echo yes || echo no)"

unset HUB_DIR_OVERRIDE
rm -rf "$LTMP"
