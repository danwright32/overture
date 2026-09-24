#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains, assert_equals,
# assert_eq, assert_empty (#2501). Haystack second, needle third.
# shellcheck source=../../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/shell-assertions.sh"

# The arrival order queue beside the machine wide test lock (downbeat#524), ported from Downbeat's
# `scripts/lock-queue.sh` and tested case for case against Downbeat's `scripts/test-lock-queue.sh`, so the
# two copies are held to the same behaviour.
#
# Each case holds REAL processes (a `sleep`) as the waiters, because the queue's whole judgement is about
# whether a process is alive and is still the same process, and a stubbed liveness check would test the
# stub. Every lock here is a throwaway one; nothing reads or writes /tmp/xcodebuild-tests.lock (L2).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lock-queue.sh
source "${HERE}/lock-queue.sh"

WORK="$(fixture_scratch_dir)"
SLEEPERS=()
end_sleepers() {
  local pid
  for pid in "${SLEEPERS[@]+"${SLEEPERS[@]}"}"; do
    kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null
  done
  SLEEPERS=()
}
trap 'end_sleepers; rm -rf "${WORK}"' EXIT
# A SPACE in the path: the queue directory is derived from the lock's path, and an unquoted expansion
# anywhere in the derivation would split it.
LOCK="${WORK}/shared lock/xcodebuild-tests.lock"
mkdir -p "${WORK}/shared lock"

# A live waiter: a process that stays alive until this file ends. In WAITER_PID, not printed, so the
# sleeper is this shell's own child and can be waited for at the end.
waiter() {
  sleep 120 &
  WAITER_PID=$!
  SLEEPERS+=("${WAITER_PID}")
}

# Joins as process $1 and prints the ticket.
join_as() {
  lock_queue_join "${LOCK}" "$1" || { echo "JOIN-FAILED"; return; }
  echo "${LOCK_QUEUE_TICKET}"
}

ahead_of() {
  LOCK_QUEUE_DIR="${LOCK}.queue"
  LOCK_QUEUE_TICKET="$1"
  lock_queue_ahead
  echo "${LOCK_QUEUE_AHEAD}"
}

gone_or_there() { [[ -e "$1" ]] && echo there || echo gone; }

# --- arrival order -----------------------------------------------------------------------------------

waiter; A="${WAITER_PID}"
waiter; B="${WAITER_PID}"
waiter; C="${WAITER_PID}"
TA="$(join_as "${A}")"; TB="$(join_as "${B}")"; TC="$(join_as "${C}")"

assert_equals "the first to arrive has nobody ahead" "0" "$(ahead_of "${TA}")"
assert_equals "the second has one ahead" "1" "$(ahead_of "${TB}")"
assert_equals "the third has two ahead" "2" "$(ahead_of "${TC}")"

# The ticket names alone must sort into arrival order, since that is all a reader in another repository
# has to go on.
ORDER="$(ls "${LOCK}.queue" | LC_ALL=C sort | tr '\n' ' ')"
assert_equals "tickets sort in arrival order" "${TA} ${TB} ${TC} " "${ORDER}"

# The file content is the other half of the protocol every repository reads: the pid, a space, and the
# process start time exactly as `ps -o lstart=` prints it.
assert_equals "a ticket holds its pid and that process's start time" \
  "${A} $(/bin/ps -o lstart= -p "${A}" | sed 's/^ *//; s/ *$//')" "$(cat "${LOCK}.queue/${TA}")"

# The first leaving moves everybody up.
LOCK_QUEUE_DIR="${LOCK}.queue"; LOCK_QUEUE_TICKET="${TA}"; lock_queue_leave
assert_equals "leaving removes the ticket" "gone" "$(gone_or_there "${LOCK}.queue/${TA}")"
assert_equals "after the first leaves, the second is next" "0" "$(ahead_of "${TB}")"
assert_equals "and the third has one ahead" "1" "$(ahead_of "${TC}")"
rm -rf "${LOCK}.queue"

# --- dead waiters ------------------------------------------------------------------------------------

# A waiter that died without leaving must not hold up the queue for ever.
waiter; LIVE="${WAITER_PID}"
sleep 120 & DOOMED=$!
TD="$(join_as "${DOOMED}")"
TL="$(join_as "${LIVE}")"
kill "${DOOMED}"; wait "${DOOMED}" 2>/dev/null
assert_equals "a dead waiter ahead does not count" "0" "$(ahead_of "${TL}")"
assert_equals "and its ticket is cleared" "gone" "$(gone_or_there "${LOCK}.queue/${TD}")"
rm -rf "${LOCK}.queue"

# A crashed waiter whose pid now belongs to something else. Its ticket records a start time the live
# process does not have, so it is dead all the same.
waiter; REUSED="${WAITER_PID}"
waiter; BEHIND="${WAITER_PID}"
TR="$(join_as "${REUSED}")"
TBH="$(join_as "${BEHIND}")"
printf '%s %s\n' "${REUSED}" "Thu Jan  1 00:00:00 1970" > "${LOCK}.queue/${TR}"
assert_equals "a reused pid does not count as the waiter" "0" "$(ahead_of "${TBH}")"
rm -rf "${LOCK}.queue"

# But a ticket that cannot be read is alive, as an unreadable lock owner is: the only thing that writes
# one is a waiter mid join.
waiter; LATE="${WAITER_PID}"
TLATE="$(join_as "${LATE}")"
: > "${LOCK}.queue/00000000000.000001.1"
assert_equals "an unreadable ticket ahead still counts" "1" "$(ahead_of "${TLATE}")"
rm -rf "${LOCK}.queue"

# An older ticket of our OWN, left by an earlier join of this process, never counts: waiting behind it
# would be waiting behind ourselves.
waiter; SELF="${WAITER_PID}"
LOCK_QUEUE_TICKET=""; lock_queue_join "${LOCK}" "${SELF}"; STALE_SELF="${LOCK_QUEUE_TICKET}"
lock_queue_join "${LOCK}" "${SELF}"
lock_queue_ahead
assert_equals "our own older ticket does not count" "0" "${LOCK_QUEUE_AHEAD}"
assert_equals "and it is cleared" "gone" "$(gone_or_there "${LOCK}.queue/${STALE_SELF}")"
lock_queue_leave
rm -rf "${LOCK}.queue"

# --- the edges ---------------------------------------------------------------------------------------

# Our own ticket vanishing (somebody emptied the queue) rejoins rather than waiting behind nobody for
# ever, and asks for one more round.
waiter; LOST="${WAITER_PID}"
LOCK_QUEUE_TICKET=""; lock_queue_join "${LOCK}" "${LOST}"
OLD_TICKET="${LOCK_QUEUE_TICKET}"
rm -f "${LOCK}.queue/${OLD_TICKET}"
lock_queue_ahead
assert_equals "a lost ticket waits one more round" "1" "${LOCK_QUEUE_AHEAD}"
assert_equals "and is back in the queue, once" "1" "$(ls "${LOCK}.queue" | wc -l | tr -d ' ')"
lock_queue_ahead
assert_equals "and next round is at the front" "0" "${LOCK_QUEUE_AHEAD}"
lock_queue_leave
rm -rf "${LOCK}.queue"

# A caller whose join failed is not queued, and waits exactly as before the queue.
LOCK_QUEUE_TICKET=""
lock_queue_ahead
assert_equals "unqueued has nobody ahead" "0" "${LOCK_QUEUE_AHEAD}"
assert_equals "joining a queue that cannot be written fails" "refused" \
  "$(lock_queue_join "/nonexistent-root-$$/lock" "$$" && echo joined || echo refused)"
LOCK_QUEUE_TICKET=""

# A process that is gone cannot join, since it has no start time to record.
assert_equals "a dead pid cannot join" "refused" \
  "$(lock_queue_join "${LOCK}" 999999 && echo joined || echo refused)"

# The sleepers go before the verdict, so the runner's leak check finds nothing of ours left running.
ALL_SLEEPERS=("${SLEEPERS[@]}")
end_sleepers
assert_pids_gone "every waiter this fixture started is gone" "${ALL_SLEEPERS[@]}"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all lock-queue checks passed"
