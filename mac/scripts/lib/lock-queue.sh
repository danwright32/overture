#!/usr/bin/env bash
# Arrival order for the machine wide test lock (downbeat#524). Sourced, never run.
#
# THE SOURCE THIS MUST STAY IDENTICAL TO, IN BEHAVIOUR: Downbeat's `scripts/lock-queue.sh`, which is
# where the protocol below was written and first tested. Downbeat, Overture and Ovation all take one
# lock, `mkdir` on /tmp/xcodebuild-tests.lock, and a runner that reads the queue differently from the
# others is a runner that barges, so a change here is a change there too, and the other way round
# (L263: two same-named rules either side of a boundary drift for ever while both read as correct).
#
# WHY. `mkdir` is the ONLY thing that keeps two suites apart, and that part is unchanged. What it never
# gave was fairness: every waiter retried on its own timer and whichever retried first after a release
# won, so on 2026-09-24 a one minute Downbeat run waited 15 to 20 minutes three times while newer
# Overture runs kept taking the lock, and a Downbeat push failed on its 1800 second deadline having run
# nothing. This runner polls every second and Downbeat's every two, so Overture was the barger.
#
# THE PROTOCOL, followed exactly:
#
#   The queue is the directory "<lock dir>.queue", beside the lock, derived from the lock's own path so
#   a test pointing a runner at a throwaway lock gets a throwaway queue with it.
#
#   A waiter joins by writing one ticket file named "<arrival>.<pid>", where <arrival> is seconds since
#   the epoch with six decimals, zero padded to a fixed width so that a plain byte sort is arrival
#   order. The file holds the pid, a space, and that process's start time as `ps -o lstart=` prints it.
#   It is written under a dot name and renamed into place, so no reader ever sees half a ticket.
#
#   A waiter may try `mkdir` on the lock only while no LIVE ticket sorts before its own. A ticket is
#   dead when its pid is gone, or when the pid is alive but its start time differs, which is a crashed
#   waiter whose number was reused and would otherwise block the queue until every waiter behind it
#   timed out. Anything unreadable counts as alive, the same judgement `dir_lock_owner_is_dead` in
#   run-tests-locked.sh makes about the lock's owner. Any waiter may delete a dead ticket.
#
#   A waiter leaves the queue the moment it holds the lock, and on every exit.
#
# PRIORITY (#4244), an EXTENSION this copy has and Downbeat's and Ovation's do not yet. A run verifying a
# merge joins with the class "priority", and its ticket is named "<arrival>.priority.<pid>": the same
# arrival first, the same pid last, the same content. A reader that knows the class serves tickets in
# two lanes, priority first and each lane in arrival order, and a routine ticket that has waited
# LOCK_QUEUE_PRIORITY_BOUND_SECONDS (600) is promoted into the priority lane at its own arrival, so a
# stream of merges delays a routine run by at most the bound and never starves it. Nothing about the
# HOLDER changes: a priority waiter still tries `mkdir` only when nothing is ahead of it, and `mkdir`
# still admits one run at a time.
#
# Why a reader that does NOT know the class is never worse off than before this, measured against a
# verbatim copy of the old reader in lock-queue.test.sh: it takes the pid from after the LAST dot, so it
# reads the right pid; the content is the one it has always judged liveness by, so it never clears a live
# priority ticket as dead; and the arrival still leads the name, so its byte sort is still arrival order
# and it counts a priority ticket exactly where an ordinary one would sit. The only difference it can
# meet is a later priority waiter that does not wait for it, and then the two race on `mkdir`, as every
# runner did before the queue. The bound covers its ticket too, since the two formats are one format.
#
# Mixing is safe in both directions. A runner that knows nothing of the queue still excludes everybody
# through `mkdir`; it only competes unfairly, which is what every runner did before this.
#
# ONE DIFFERENCE IN SPELLING, NONE IN BEHAVIOUR: the external tools the judgement rests on (`ps`, `perl`,
# `sed`, `ls`, `sort`) are called by their full paths. Two fixtures here run this code under a PATH that
# is not the Mac's. run-tests-locked.test.sh puts a stub `ps` first, which answers every question with a
# launchd line, so through it every process would share one start time and a reused pid would read as
# the same waiter; `scratch_defaults_left_behind` in the runner calls `/bin/ps` for the same reason. And
# check-release-compiles.test.sh builds a PATH from a named list holding neither `sed` nor `ls`, through
# which every join would fail and every run would quietly wait unordered.

LOCK_QUEUE_DIR=""
LOCK_QUEUE_TICKET=""
LOCK_QUEUE_AHEAD=0
# Of those ahead, how many arrived AFTER this waiter and go first by class, so a runner can say so.
LOCK_QUEUE_AHEAD_LATER=0
LOCK_QUEUE_CLASS=""
# How long a routine ticket waits before it is served in plain arrival order again (#4244). A caller may
# set it before sourcing; a value that is not a whole number falls back to the default where it is read.
: "${LOCK_QUEUE_PRIORITY_BOUND_SECONDS:=600}"

# The start time of a process, or nothing when it is gone.
lock_queue_started() {
  /bin/ps -o lstart= -p "$1" 2>/dev/null | /usr/bin/sed 's/^ *//; s/ *$//' || true
}

# Joins the queue beside lock dir $1 as process $2, in class $3: nothing for a routine run, or
# "priority" for a merge verification (#4244). Anything else is refused rather than read as either, so a
# misspelling cannot jump the queue. Returns non zero when the queue cannot be written, and the caller
# then waits the old way rather than not at all.
lock_queue_join() {
  local lock_dir="$1" pid="$2" class="${3:-}" infix arrival started tmp
  LOCK_QUEUE_DIR="${lock_dir}.queue"
  LOCK_QUEUE_TICKET=""
  case "${class}" in
    "") infix="" ;;
    priority) infix=".priority" ;;
    *) return 1 ;;
  esac
  LOCK_QUEUE_CLASS="${class}"
  mkdir -p "${LOCK_QUEUE_DIR}" 2>/dev/null || return 1
  arrival="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%017.6f", time' 2>/dev/null)" || return 1
  [[ -n "${arrival}" ]] || return 1
  started="$(lock_queue_started "${pid}")"
  [[ -n "${started}" ]] || return 1
  tmp="${LOCK_QUEUE_DIR}/.joining.${pid}"
  printf '%s %s\n' "${pid}" "${started}" > "${tmp}" 2>/dev/null || return 1
  mv "${tmp}" "${LOCK_QUEUE_DIR}/${arrival}${infix}.${pid}" 2>/dev/null || { rm -f "${tmp}"; return 1; }
  LOCK_QUEUE_TICKET="${arrival}${infix}.${pid}"
}

# Whether ticket file $1 belongs to a process that is DEMONSTRABLY gone.
lock_queue_ticket_is_dead() {
  local line pid recorded now
  line="$(cat "$1" 2>/dev/null)" || return 1
  pid="${line%% *}"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  recorded="${line#* }"
  kill -0 "${pid}" 2>/dev/null || return 0
  now="$(lock_queue_started "${pid}")"
  [[ -n "${now}" ]] || return 1
  [[ "${now}" == "${recorded}" ]] && return 1
  return 0
}

# Whether ticket name $1 is served in the first lane: a priority ticket, or a routine one that arrived
# at least the bound before now ($2). With no clock ($2 empty) every ticket is in the first lane, which
# is plain arrival order, the behaviour before #4244.
lock_queue_first_lane() {
  local name="$1" now="$2" bound="${LOCK_QUEUE_PRIORITY_BOUND_SECONDS}" arrival
  [[ "${name}" =~ ^[0-9]+\.[0-9]+\.priority\.[0-9]+$ ]] && return 0
  [[ -n "${now}" ]] || return 0
  [[ "${bound}" =~ ^[0-9]+$ ]] || bound=600
  arrival="${name%%.*}"
  # A name this cannot date is left in the routine lane: it is not ours to promote.
  [[ "${arrival}" =~ ^[0-9]+$ ]] || return 1
  [[ $(( now - 10#${arrival} )) -ge "${bound}" ]]
}

# How many live tickets are ahead of this one, clearing dead ones on the way, set in LOCK_QUEUE_AHEAD,
# with LOCK_QUEUE_AHEAD_LATER of them arrivals after this one that go first by class (#4244). Not
# queued at all is 0, so a caller whose join failed behaves exactly as it did before the queue.
#
# AHEAD is: in the first lane while this ticket is not, or in the same lane and earlier. With every
# ticket routine and young that is exactly the arrival order it always was.
#
# A VARIABLE and not printed, deliberately. Printing invites `$(lock_queue_ahead)`, which runs in a
# subshell, so a rejoin below would write a ticket the caller never learns about, and the caller would
# then wait behind its own orphan until it timed out. Downbeat's own test caught exactly that.
lock_queue_ahead() {
  LOCK_QUEUE_AHEAD=0
  LOCK_QUEUE_AHEAD_LATER=0
  [[ -n "${LOCK_QUEUE_TICKET}" ]] || return 0
  local ticket seen=0 mine="${LOCK_QUEUE_TICKET##*.}" now mine_first=0 theirs_first
  now="$(/bin/date +%s 2>/dev/null)" || now=""
  [[ "${now}" =~ ^[0-9]+$ ]] || now=""
  lock_queue_first_lane "${LOCK_QUEUE_TICKET}" "${now}" && mine_first=1
  for ticket in $(/bin/ls "${LOCK_QUEUE_DIR}" 2>/dev/null | LC_ALL=C /usr/bin/sort); do
    if [[ "${ticket}" == "${LOCK_QUEUE_TICKET}" ]]; then
      seen=1
      continue
    fi
    # An older ticket carrying our own pid is a leftover of ours, and waiting behind it would be
    # waiting behind ourselves. A later one cannot be ours to wait for either.
    if [[ "${ticket##*.}" == "${mine}" ]]; then
      [[ "${seen}" -eq 1 ]] || rm -f "${LOCK_QUEUE_DIR}/${ticket}"
      continue
    fi
    theirs_first=0
    lock_queue_first_lane "${ticket}" "${now}" && theirs_first=1
    if [[ "${theirs_first}" -eq "${mine_first}" ]]; then
      # Same lane: only an earlier arrival is ahead.
      [[ "${seen}" -eq 0 ]] || continue
    elif [[ "${theirs_first}" -eq 0 ]]; then
      # A routine ticket never goes ahead of one in the first lane, whenever it arrived.
      continue
    fi
    if lock_queue_ticket_is_dead "${LOCK_QUEUE_DIR}/${ticket}"; then
      rm -f "${LOCK_QUEUE_DIR}/${ticket}"
      continue
    fi
    LOCK_QUEUE_AHEAD=$((LOCK_QUEUE_AHEAD + 1))
    [[ "${seen}" -eq 0 ]] || LOCK_QUEUE_AHEAD_LATER=$((LOCK_QUEUE_AHEAD_LATER + 1))
  done
  # Our own ticket is gone, which only happens when something emptied the queue from outside. Waiting
  # on as though still queued would wait for ever behind nobody, so rejoin at the back, in the same
  # class, and wait one more round; the next call counts from the new ticket, and a failed rejoin
  # leaves this caller unqueued.
  if [[ "${seen}" -eq 0 ]]; then
    lock_queue_join "${LOCK_QUEUE_DIR%.queue}" "${mine}" "${LOCK_QUEUE_CLASS}" || LOCK_QUEUE_TICKET=""
    LOCK_QUEUE_AHEAD=1
    LOCK_QUEUE_AHEAD_LATER=0
  fi
  return 0
}

lock_queue_leave() {
  if [[ -n "${LOCK_QUEUE_TICKET}" ]]; then
    rm -f "${LOCK_QUEUE_DIR}/${LOCK_QUEUE_TICKET}"
  fi
  LOCK_QUEUE_TICKET=""
}
