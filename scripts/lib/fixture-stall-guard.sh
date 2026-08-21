#!/usr/bin/env bash
# Whether the shell fixture run is actually MOVING (#2929).
#
# `run-shell-fixtures.sh` fans out to eight lanes and prints each fixture's output as one block AFTER it
# finishes, so nothing streams while a fixture is working. A fixture that never returns therefore leaves
# the runner silent forever, and a silent runner is indistinguishable from one still working (L110, L98).
#
# Measured 2026-08-17: `mac/scripts/lib/run-heartbeat.test.sh` hung inside a run, was still alive after
# roughly 8 minutes holding up the whole parallel run, and had to be killed by hand. It passes in seconds
# on its own, so the hang is a flake; the runner having no way to SAY so is the defect.
#
# WHAT IS REUSED AND WHAT IS NOT. The Swift suite solved this in #2577
# (`mac/scripts/lib/test-progress-watch.sh`), and its RULES are sourced from there rather than restated:
# `notice_due` (when a repeating message is due again) and `humanize_seconds`. Its WORDS are not reused,
# because they are about xcodebuild and the shared lock, and a message may only claim what its check
# measured (L11). This runner has no lock and no build phase: nothing here is ever queued behind another
# run, so a silence means a stall from the first tick, with no exempt phase to reason about.
#
# It WARNS, it does not kill, for the same reason #2577 gives: the limit is a guess until it has been
# observed on real runs, and a wrong kill throws away a whole run's work and reports as a failure nobody
# caused. What warning gets wrong is that somebody still has to act on it.

FIXTURE_STALL_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../mac/scripts/lib/test-progress-watch.sh
source "${FIXTURE_STALL_GUARD_DIR}/../../mac/scripts/lib/test-progress-watch.sh"

FIXTURE_STALL_LIMIT_SECONDS="${OVERTURE_FIXTURE_STALL_LIMIT_SECONDS:-120}"
FIXTURE_STALL_CHECK_SECONDS="${OVERTURE_FIXTURE_STALL_CHECK_SECONDS:-15}"
FIXTURE_WATCH_PREFIX="run-shell-fixtures.sh:"

# Progress is a fixture STARTING or FINISHING, counted off the runner's own progress file.
#
# Both, not just finishing, and that is the difference between a guard that fires at the right moment and
# one that waits for the whole run. With eight lanes something starts or finishes constantly until the
# work runs out, so a silence this long means every live lane is stuck, which is exactly the state worth
# naming. Counting only finishes would let seven fast lanes mask one hung fixture for as long as work
# remained.
FIXTURE_PROGRESS_PATTERN='^(started|finished) '

fixture_progress_count() {
  local file="$1" count
  [[ -r "${file}" ]] || { echo 0; return 0; }
  count="$(grep -acE "${FIXTURE_PROGRESS_PATTERN}" "${file}" 2>/dev/null)" || true
  [[ "${count}" =~ ^[0-9]+$ ]] || count=0
  echo "${count}"
}

fixture_stall_warning() {
  local stalled="$1" progress="$2" running="$3"
  echo "NO FIXTURE HAS STARTED OR FINISHED FOR $(humanize_seconds "${stalled}"). ${progress} came before that, and none since.
Every lane still running is stuck on the same fixture it was on then. Nothing here waits for a lock, so
a silence this long is a hang rather than a queue, and a fixture that hangs cannot fail by itself.
Still running: ${running:-unknown}"
}

fixture_progress_resumed_notice() {
  local stalled="$1"
  echo "Fixtures started moving again after $(humanize_seconds "${stalled}") of silence.
The warning above it was a false alarm. If that keeps happening, raise the limit it fired at
(OVERTURE_FIXTURE_STALL_LIMIT_SECONDS) rather than learn to ignore the warning."
}

# Which fixtures are still going: everything that started and has not finished. Named in the warning
# because the name is the only part anybody can act on, and the runner knows it (L80).
fixture_still_running() {
  local file="$1"
  [[ -r "${file}" ]] || { echo ""; return 0; }
  local started finished
  started="$(grep -a '^started ' "${file}" 2>/dev/null | sed 's/^started //' | sort)"
  finished="$(grep -a '^finished ' "${file}" 2>/dev/null | sed 's/^finished //' | sort)"
  comm -23 <(printf '%s\n' "${started}") <(printf '%s\n' "${finished}") | tr '\n' ' ' | sed 's/ $//'
}

fixture_watch_loop() {
  local progress_file="$1" limit="$2" interval="$3"
  local stalled=0 warnings=0 last_count=0 count

  [[ "${interval}" =~ ^[0-9]+$ ]] && [[ "${interval}" -gt 0 ]] || return 0

  while true; do
    # No handle on the caller's stdout or stderr, for #2577's measured reason: a caller capturing the
    # run's output waits for every writer of that pipe to close, and an orphaned sleep holds it open
    # after the run is over.
    sleep "${interval}" >/dev/null 2>&1
    count="$(fixture_progress_count "${progress_file}")"

    if [[ "${count}" -gt "${last_count}" ]]; then
      if [[ "${warnings}" -gt 0 ]]; then
        printf '\n%s %s\n' "${FIXTURE_WATCH_PREFIX}" "$(fixture_progress_resumed_notice "${stalled}")" >&2
      fi
      last_count="${count}"
      stalled=0
      warnings=0
      continue
    fi

    stalled=$(( stalled + interval ))
    if notice_due "${stalled}" "${limit}" "${warnings}"; then
      warnings=$(( warnings + 1 ))
      printf '\n%s %s\n' "${FIXTURE_WATCH_PREFIX}" \
        "$(fixture_stall_warning "${stalled}" "${count} progress lines" "$(fixture_still_running "${progress_file}")")" >&2
    fi
  done
}

FIXTURE_WATCH_PID=""
start_fixture_watch() {
  local progress_file="$1"
  fixture_watch_loop "${progress_file}" \
    "${FIXTURE_STALL_LIMIT_SECONDS}" "${FIXTURE_STALL_CHECK_SECONDS}" &
  FIXTURE_WATCH_PID=$!
}

# Safe to call twice and safe to call on a PID that never existed. The children are read BEFORE the
# parent dies, because killing the loop does not take its sleep with it and once the parent is gone
# there is nothing left to ask `pgrep -P` (#2577 measured a `sleep 30` outliving its run).
stop_fixture_watch() {
  local pid="${1:-}" children=""
  [[ -n "${pid}" ]] || return 0
  children="$(pgrep -P "${pid}" 2>/dev/null || true)"
  kill "${pid}" 2>/dev/null || true
  # shellcheck disable=SC2086
  [[ -n "${children}" ]] && kill ${children} 2>/dev/null
  wait "${pid}" 2>/dev/null || true
  FIXTURE_WATCH_PID=""
  return 0
}
