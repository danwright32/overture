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

# --- merge verification goes first (#4244) -----------------------------------------------------------
#
# A run verifying a merge joins as a PRIORITY waiter and goes ahead of routine runs that arrived before
# it. It never goes ahead of the HOLDER: `mkdir` is still the only exclusion, and the runner tries it
# only once this says nothing is ahead, which is the runner fixture's half.

# Now, in whole seconds, and a ticket name for an arrival that many seconds ago, as a hand written ticket
# needs one. The arrival is the only thing the anti starvation bound reads.
now_seconds() { /bin/date +%s; }
ticket_at() { printf '%010d.000000%s.%s' "$(( $(now_seconds) - $1 ))" "$2" "$3"; }
# Writes a ticket by hand for live process $1, arrived $2 seconds ago, with name infix $3 ("" or
# ".priority"), in the format every repository writes, and prints its name.
hand_ticket() {
  local name
  name="$(ticket_at "$2" "$3" "$1")"
  mkdir -p "${LOCK}.queue"
  printf '%s %s\n' "$1" "$(/bin/ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//')" > "${LOCK}.queue/${name}"
  echo "${name}"
}

# THE PRE-#4244 READER, copied from Downbeat's `scripts/lock-queue.sh` as it stood on 2026-09-27 (and
# Ovation's, which is the same), renamed so it can sit beside the new one. Its one change is the rejoin
# on a lost ticket, left out because no case here loses one. It is what a Downbeat or Ovation run still
# does, so every compatibility claim below is made against it rather than against a description of it.
old_reader_ahead() {
  LOCK_QUEUE_AHEAD=0
  [ -n "$LOCK_QUEUE_TICKET" ] || return 0
  local ticket seen=0 mine="${LOCK_QUEUE_TICKET##*.}"
  for ticket in $(ls "$LOCK_QUEUE_DIR" 2>/dev/null | LC_ALL=C sort); do
    if [ "$ticket" = "$LOCK_QUEUE_TICKET" ]; then
      seen=1
      break
    fi
    if [ "${ticket##*.}" = "$mine" ] || lock_queue_ticket_is_dead "$LOCK_QUEUE_DIR/$ticket"; then
      rm -f "$LOCK_QUEUE_DIR/$ticket"
      continue
    fi
    LOCK_QUEUE_AHEAD=$((LOCK_QUEUE_AHEAD + 1))
  done
  if [ "$seen" -eq 0 ]; then
    LOCK_QUEUE_TICKET=""
    LOCK_QUEUE_AHEAD=1
  fi
}
old_ahead_of() {
  LOCK_QUEUE_DIR="${LOCK}.queue"
  LOCK_QUEUE_TICKET="$1"
  old_reader_ahead
  echo "${LOCK_QUEUE_AHEAD}"
}

join_priority_as() {
  lock_queue_join "${LOCK}" "$1" priority || { echo "JOIN-FAILED"; return; }
  echo "${LOCK_QUEUE_TICKET}"
}

waiter; OA="${WAITER_PID}"
waiter; OB="${WAITER_PID}"
waiter; PM="${WAITER_PID}"
TOA="$(join_as "${OA}")"; TOB="$(join_as "${OB}")"; TPM="$(join_priority_as "${PM}")"

assert_equals "a priority ticket is named arrival, .priority, pid" "yes" \
  "$([[ "${TPM}" =~ ^[0-9]+\.[0-9]+\.priority\.${PM}$ ]] && echo yes || echo no)"
assert_equals "and holds exactly what an ordinary ticket holds, so an old reader judges it alive" \
  "${PM} $(/bin/ps -o lstart= -p "${PM}" | sed 's/^ *//; s/ *$//')" "$(cat "${LOCK}.queue/${TPM}" 2>/dev/null)"
assert_equals "an ordinary join is still named arrival, pid" "yes" \
  "$([[ "${TOA}" =~ ^[0-9]+\.[0-9]+\.${OA}$ ]] && echo yes || echo no)"

assert_equals "a merge verification arriving after two routine runs has nobody ahead" "0" "$(ahead_of "${TPM}")"
assert_equals "the first routine run now waits for it" "1" "$(ahead_of "${TOA}")"
assert_equals "and the second waits for it and the first" "2" "$(ahead_of "${TOB}")"

# The old reader, over the SAME queue: it reads the priority ticket as an ordinary one in arrival order.
assert_equals "an old reader at the front still sees nobody ahead, as today" "0" "$(old_ahead_of "${TOA}")"
assert_equals "an old reader second still sees one ahead, as today" "1" "$(old_ahead_of "${TOB}")"
assert_equals "an old reader counts the priority waiter as an ordinary later arrival, not dead" "there" \
  "$(gone_or_there "${LOCK}.queue/${TPM}")"
rm -rf "${LOCK}.queue"

# Arriving BEFORE an old reader, a priority ticket is simply an earlier ticket to it.
waiter; PE="${WAITER_PID}"
waiter; OL="${WAITER_PID}"
TPE="$(join_priority_as "${PE}")"; TOL="$(join_as "${OL}")"
assert_equals "an old reader behind an earlier priority ticket counts it once" "1" "$(old_ahead_of "${TOL}")"
assert_equals "and so does a new one" "1" "$(ahead_of "${TOL}")"
assert_equals "and the priority ticket survives both readings" "there" "$(gone_or_there "${LOCK}.queue/${TPE}")"
rm -rf "${LOCK}.queue"

# Two merge verifications go in the order they arrived.
waiter; P1="${WAITER_PID}"
waiter; P2="${WAITER_PID}"
waiter; O3="${WAITER_PID}"
TO3="$(join_as "${O3}")"; TP1="$(join_priority_as "${P1}")"; TP2="$(join_priority_as "${P2}")"
assert_equals "the earlier merge verification is first" "0" "$(ahead_of "${TP1}")"
assert_equals "the later one waits for the earlier one only" "1" "$(ahead_of "${TP2}")"
assert_equals "the routine run waits for both" "2" "$(ahead_of "${TO3}")"
rm -rf "${LOCK}.queue"

# A dead priority waiter is skipped and cleared like a dead ordinary one, from EITHER side of the reader's
# own ticket, since a priority ticket counts from behind it.
waiter; OD="${WAITER_PID}"
sleep 120 & PDOOMED=$!
TOD="$(join_as "${OD}")"
TPD="$(join_priority_as "${PDOOMED}")"
kill "${PDOOMED}"; wait "${PDOOMED}" 2>/dev/null
assert_equals "a dead merge verification does not hold up a routine run" "0" "$(ahead_of "${TOD}")"
assert_equals "and its ticket is cleared" "gone" "$(gone_or_there "${LOCK}.queue/${TPD}")"
rm -rf "${LOCK}.queue"

# THE ANTI STARVATION BOUND. A routine run that has waited LOCK_QUEUE_PRIORITY_BOUND_SECONDS (600 by
# default) is served in plain arrival order again, ahead of every merge verification that arrived after
# it, so a stream of merges can delay a routine run by at most the bound and never starve it. Written by
# hand as an old reader would write it, since an old reader's ticket is exactly the one this protects.
assert_equals "the bound is ten minutes unless set" "600" "${LOCK_QUEUE_PRIORITY_BOUND_SECONDS:-unset}"
waiter; OLD_ENOUGH="${WAITER_PID}"
waiter; NOT_YET="${WAITER_PID}"
waiter; PB="${WAITER_PID}"
TOLD="$(hand_ticket "${OLD_ENOUGH}" 605 "")"
TNOT="$(hand_ticket "${NOT_YET}" 595 "")"
TPB="$(join_priority_as "${PB}")"
assert_equals "a merge verification waits for a routine run past the bound, and only that one" "1" \
  "$(ahead_of "${TPB}")"
assert_equals "the routine run past the bound has nobody ahead" "0" "$(ahead_of "${TOLD}")"
assert_equals "the one short of the bound waits for it and the merge verification" "2" "$(ahead_of "${TNOT}")"
rm -rf "${LOCK}.queue"

# The bound is read at each reading rather than fixed, so the same queue reads differently under a
# different bound, which is what proves the number is the one being consulted.
waiter; OSHORT="${WAITER_PID}"
waiter; PSHORT="${WAITER_PID}"
TOSHORT="$(hand_ticket "${OSHORT}" 30 "")"
TPSHORT="$(join_priority_as "${PSHORT}")"
assert_equals "under the default bound a routine run 30s old waits for a merge verification" "1" \
  "$(ahead_of "${TOSHORT}")"
LOCK_QUEUE_PRIORITY_BOUND_SECONDS=20
assert_equals "under a 20s bound the same run has waited long enough" "0" "$(ahead_of "${TOSHORT}")"
assert_equals "and the merge verification waits for it" "1" "$(ahead_of "${TPSHORT}")"
LOCK_QUEUE_PRIORITY_BOUND_SECONDS=600
rm -rf "${LOCK}.queue"

# A priority waiter past the bound is still a priority waiter: two of them keep arrival order.
waiter; PA1="${WAITER_PID}"
waiter; PA2="${WAITER_PID}"
TPA1="$(hand_ticket "${PA1}" 900 ".priority")"
TPA2="$(join_priority_as "${PA2}")"
assert_equals "an old merge verification is ahead of a new one" "1" "$(ahead_of "${TPA2}")"
assert_equals "and has nobody ahead" "0" "$(ahead_of "${TPA1}")"
rm -rf "${LOCK}.queue"

# Nothing but the literal word joins as priority, so a typo cannot quietly jump the queue.
waiter; TYPO="${WAITER_PID}"
assert_equals "an unknown class is refused" "refused" \
  "$(lock_queue_join "${LOCK}" "${TYPO}" urgent && echo joined || echo refused)"
assert_equals "and writes no ticket" "0" "$(ls "${LOCK}.queue" 2>/dev/null | wc -l | tr -d ' ')"
LOCK_QUEUE_TICKET=""
rm -rf "${LOCK}.queue"

# The sleepers go before the verdict, so the runner's leak check finds nothing of ours left running.
ALL_SLEEPERS=("${SLEEPERS[@]}")
end_sleepers
assert_pids_gone "every waiter this fixture started is gone" "${ALL_SLEEPERS[@]}"

if [[ "${FAILURES:-0}" -ne 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all lock-queue checks passed"
