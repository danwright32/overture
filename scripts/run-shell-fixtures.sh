#!/usr/bin/env bash
set -euo pipefail

# Runs every scripts/*.test.sh and mac/scripts/**/*.test.sh fixture in the repo (#698): each covers
# a pure function extracted from its sibling script (classify_stop_reason in merge-when-green.sh,
# stale_debug_test_host_pids in run-tests-locked.sh, etc.). None of them ran automatically before
# this, so a future edit to one of those functions could silently break its fixture until the real
# script misbehaved for real (a bad CI-merge decision, a stale process left running). Wired into
# scripts/test-all.sh so these fixtures ride along with every other local pre-push check.
#
# Usage: scripts/run-shell-fixtures.sh [<fixture.test.sh> ...]
#
# With no arguments it sweeps every fixture, which is what scripts/test-all.sh calls. Name one or
# more and it runs only those (#3245), which is how to prove ONE fixture through the runner's own
# rules (the temp-leak check, the unresolved-command check) without paying for the whole sweep. A
# named path that is not an existing *.test.sh is refused, never quietly swapped for the sweep.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# #2929: whether this run is still MOVING. Output does not stream here (each fixture's block is printed
# after it finishes), so without this a fixture that never returns leaves the runner silent forever.
# shellcheck source=./lib/fixture-stall-guard.sh
source "${SCRIPT_DIR}/lib/fixture-stall-guard.sh"

# The shape bash prints when a name resolves to nothing: "line 12: assert_contains: command not
# found". A fixture that hits this keeps going, its assertion silently does nothing, and it exits 0
# reporting every check passed, which is worse than no coverage because the summary calls it covered
# (#2501, L1). Matched with the leading colon so a fixture that merely QUOTES the phrase in a message
# is not condemned by it: stable-signing.test.sh prints it back when its own guard against this
# defect fires, and mac/scripts/lib/run-stall-guard.test.sh names it in a comment.
FIXTURE_UNRESOLVED_COMMAND=": command not found"

# A fixture that drives a script's missing-dependency path on purpose prints this line, naming the one
# command it expects to go missing: mac/scripts/lib/models.test.sh runs record_model with PATH pointing
# at nothing, to prove a detached run still succeeds when there is no node to stamp it with. Bash says
# the same words either way, so the declaration is what tells a rehearsed absence from a typo. It names
# a single command rather than exempting the fixture, so a mistyped assertion inside a declaring fixture
# is still caught.
FIXTURE_EXPECTS_MISSING="shell-fixture-expects-missing-command:"

# Reads one finished fixture's output and returns nonzero when it called a command bash could not
# resolve and did not declare. Prints the offending lines, and separately says so when a declaration
# never fired: a rehearsed absence that stopped happening means the degradation path is no longer being
# exercised, and the fixture would go on reading as if it were. That one is said out loud rather than
# failed, because whether the words appear at all depends on how the shell resolves a command it has
# already run once.
unresolved_commands_are_all_declared() {
  local log="$1"
  local declared=() name line undeclared=()

  while IFS= read -r line; do
    name="${line#*${FIXTURE_EXPECTS_MISSING}}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -n "${name}" ]] && declared+=("${name}")
  done < <(grep -F "${FIXTURE_EXPECTS_MISSING}" "${log}" || true)

  while IFS= read -r line; do
    # Bash prints "<source>: line N: <name>: command not found", so the name is the field before the
    # phrase. Read off the line itself rather than trusted from anywhere else.
    name="${line%"${FIXTURE_UNRESOLVED_COMMAND}"}"
    name="${name##*: }"
    local is_declared="false" d
    for d in ${declared[@]+"${declared[@]}"}; do
      [[ "${name}" == "${d}" ]] && is_declared="true"
    done
    [[ "${is_declared}" == "false" ]] && undeclared+=("${line}")
  done < <(grep -F "${FIXTURE_UNRESOLVED_COMMAND}" "${log}" || true)

  local d
  for d in ${declared[@]+"${declared[@]}"}; do
    if ! grep -qF ": ${d}${FIXTURE_UNRESOLVED_COMMAND}" "${log}"; then
      echo "NOTE - this fixture declared it would exercise a missing \"${d}\" and nothing went missing."
      echo "  Either the degradation path stopped being driven, or the declaration is stale."
    fi
  done

  if [[ "${#undeclared[@]}" -eq 0 ]]; then
    return 0
  fi
  echo "FAIL - ${FIXTURE_PATH_FOR_REPORT:-a fixture} reported success while calling a command it could not find"
  printf '  %s\n' "${undeclared[@]}"
  echo "  An assertion that does not resolve silently checks nothing, so this run proved less"
  echo "  than it claimed. Source scripts/lib/shell-assertions.sh for the shared vocabulary, or"
  echo "  print \"${FIXTURE_EXPECTS_MISSING} <name>\" if the absence is the thing being rehearsed."
  return 1
}

# #2541: did this fixture actually assert anything?
#
# `mac/scripts/run-tests-locked.sh` already refuses to call a run that executed nothing a pass (#2317).
# No other test entry point here had that rule, and three false signals appeared in one session on
# 2026-08-11 for want of it. This is the shell half.
#
# A fixture that exits 0 having printed no passing assertion is not a fixture that passed: it is what a
# fixture looks like when its body did not run. An early return, a loop over a list that came back empty,
# a guard that skipped every case. Finding zero subjects has to be its own non-success outcome, because
# the empty result arrives exactly when the work has not happened, which is when a green verdict is most
# likely to be believed (L98).
#
# Every spelling of a passing assertion this repo prints is counted: `ok - <desc>` from the shared
# vocabulary, the `ok: <desc>` a few older files use, and a bare `ok`. The word boundary is what keeps it
# honest, so a line beginning "okay" or "ok_count" is not mistaken for an assertion.
#
# Deliberately generous about the SHAPE and strict about the ABSENCE. Pinning one spelling would fail
# every fixture that uses another, which is how a guard gets edited until it is quiet (L93); the defect
# being caught is a fixture that printed nothing at all.
#
# Measured 2026-08-15 across all 61 fixtures: every one prints at least one, so this rule costs nothing
# today and only ever fires on a fixture that stopped doing its work.
fixture_asserted_something() {
  local log="$1"
  grep -qE '^[[:space:]]*ok\b' "${log}"
}

# #2850: did this fixture's own plumbing invent a failure?
#
# Every fixture declares `set -o pipefail`, and a pipeline whose CONSUMER exits early (`grep -q` stops at
# its first match, `head` at its Nth line) kills the PRODUCER with SIGPIPE. pipefail then makes the
# pipeline's status the producer's failure rather than the consumer's success, so an `if` reading it takes
# the else branch and the fixture reports an assertion failing about code that is perfectly correct.
#
# Whether it happens is a race between the producer finishing its write and the consumer exiting, so it
# depends on the size of the text and on machine load: invisible on a quiet Mac, and showing up under
# load, which is exactly when several things are running. Measured 2026-08-16 during a full
# `scripts/test-all.sh`, where `scout-tools.test.sh` reported that `scout-extract-run.sh` does not call
# `scout_extract_claude_scope "$CLAUDE"`, on the very line where it does, and passed when run alone.
#
# This is the RUNTIME half, and it reads the evidence rather than guessing: the shell prints the write
# error itself. It catches any producer and consumer pair, including ones no pattern anticipated. The
# source-side half (`fixture_sources_avoid_short_circuit_pipes`) is what fires even on the runs where the
# race happens not to open, which is most of them.
#
# It fails the fixture whatever its exit status, because the harm runs both ways: the pipeline can invent
# a failure, and on a fixture that happened to pass it means an assertion was decided by a race.
fixture_pipeline_did_not_break() {
  local log="$1"
  if grep -qE 'write error: Broken pipe|Broken pipe' "${log}"; then
    echo "FAIL - ${FIXTURE_PATH_FOR_REPORT:-a fixture} broke a pipe while asserting (#2850)"
    grep -nE 'write error: Broken pipe|Broken pipe' "${log}" | sed 's/^/    /'
    echo "  Under 'set -o pipefail' that makes the PIPELINE's status the producer's failure, not the"
    echo "  consumer's success, so an assertion reading it reports a failure that did not happen."
    echo "  Feed the consumer from a herestring instead: grep -q '...' <<< \"\${text}\"."
    return 1
  fi
  return 0
}

# The source-side half of #2850. Fires on every run rather than only on the runs where the race opens,
# which is what makes it a gate rather than a witness.
#
# Narrow twice over, because the first version was not and would have been switched off within a day
# (L93). It flags a short-circuiting consumer (`grep -q`, `grep -qF`, `grep -qE`, `head`) ONLY where the
# pipeline's STATUS IS READ, which means the condition of an `if`, `elif` or `while`. That is where the
# damage is: pipefail turns the producer's SIGPIPE into the pipeline's status and the condition flips.
#
# A pipeline inside `$(...)` whose value is assigned is deliberately left alone, and measured rather than
# assumed: eight such lines exist here (`x="$(printf ... | grep -n ... | head -1)"`), and none of them
# reads the status at all, so none can be flipped by it. A consumer that reads to the end is fine too.
fixture_sources_avoid_short_circuit_pipes() {
  local offenders
  # The needle is BUILT rather than written, so this file does not match its own rule and the scan cannot
  # condemn the line describing it (the trick #2193 established for the style gate).
  # #3275: any `-q` in grep's option cluster, not the one spelling `grep -q`. The needle was literally
  # that, so `grep -aqF` and `grep -qE` walked past it, and `grep -aqF` is what
  # `mac/scripts/lib/hosted-suite-stamp.sh` was using when it reported the screens as unverified on four
  # consecutive runs that had passed all 49 of them. A guard that catches one spelling of the thing it
  # forbids is exempt from it wherever anybody wrote another (L96).
  local q="grep[^|]*[[:space:]]-[A-Za-z]*q"
  # -H as well as -n: grep omits the filename when it is given exactly ONE file, so a scan of a single
  # fixture named a line number and no file, which is the half the reader needs.
  offenders="$(grep -HnE "^[[:space:]]*(if|elif|while)[[:space:]].*\| *(${q}|head )" "$@" 2>/dev/null || true)"
  [[ -z "${offenders}" ]] && return 0
  echo "FAIL - a script pipes into a consumer that exits early (#2850, #3275)"
  sed 's/^/    /' <<< "${offenders}"
  echo "  'grep -q' stops at its first match and 'head' at its Nth line, which closes the pipe and kills"
  echo "  the producer. Every fixture sets pipefail, so that becomes the pipeline's status and the"
  echo "  assertion reports a failure that never happened. Use a herestring: cmd <<< \"\${text}\", or"
  echo "  drop the -q and redirect to /dev/null where the file must stay POSIX (grep then reads it all)."
  return 1
}

# fixture_sources_avoid_kill_wait_on_a_fresh_job FILE...
#
# #3125: a background job must not be killed in the same breath it is started and then waited for.
#
# `run-heartbeat.test.sh` wanted a pid naming a process that had already finished, and got one by
# starting a `sleep 300`, killing it on the very next line, and waiting for it. The kill is sent so soon
# after the fork that it sometimes does not take, and the `wait` then sits for the job's whole lifetime.
#
# Measured 2026-08-22 under this runner's own plumbing: one round in roughly ten cost 306 seconds. Marks
# placed either side of those two lines read +1s before and +301s after, while every other mark in the
# fixture stayed at +1s. Every assertion still passed, so it never failed: it just cost five minutes of a
# run that is mandatory before every push, and while it sat there it was indistinguishable from a genuine
# hang (#2929 named it, correctly, and could not say whether to wait or kill).
#
# Refused at the SOURCE rather than at runtime, for #2850's reason: a runtime check can only fire on the
# runs where the race actually opened, which is one in ten, so it would be a witness rather than a gate.
#
# NARROW, so it is not switched off within a day (L93). It flags only a recorded background pid whose
# very next line or two both KILLS and WAITS FOR that same pid. Every other recorded pid in this repo is
# `stuck-tool-call.test.sh`'s shape, where real work happens in between and it is the WATCHDOG that gets
# killed rather than the stand-in; those windows are closed by the work, and none has ever stalled.
fixture_sources_avoid_kill_wait_on_a_fresh_job() {
  local offenders="" f n i var window line
  local -a lines
  # The `$!` is inside single quotes so the shell cannot expand it into this runner's own last
  # background pid, which is a live value here: `start_fixture_watch` sets one.
  local re='&[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=\$!'
  # PHYSICAL lines, which is deliberate and worth knowing: a synthetic offender written by a `printf`
  # with `\n` escapes lives on ONE line, so this cannot see it, and the fixtures that build such files to
  # test this very guard are therefore not condemned by it.
  for f in "$@"; do
    [[ -r "${f}" ]] || continue
    lines=()
    while IFS= read -r line || [[ -n "${line}" ]]; do lines+=("${line}"); done < "${f}"
    n=${#lines[@]}
    for (( i = 0; i < n; i++ )); do
      [[ "${lines[i]}" =~ $re ]] || continue
      var="${BASH_REMATCH[1]}"
      # The next two lines only. The defect is a kill that races the fork, and a kill three lines later
      # has had a command run in between, which is what closes the window.
      window="${lines[i+1]:-}"$'\n'"${lines[i+2]:-}"
      # Both words must be REAL WORDS acting on THIS pid, never bare substrings. The first version asked
      # only whether the window contained the characters, and it condemned this guard's own test, whose
      # next line calls `fixture_sources_avoid_kill_wait_on_a_fresh_job`: that identifier carries both
      # words, and a single-letter pid variable like `P` matched any capital P in the line beside it. A
      # guard that fires on the text describing it is the trap #2193 established the build-the-needle
      # trick for, and here the honest fix is to ask the sharper question rather than to hide the words.
      #
      # `[^[:alnum:]_]` before the word is what excludes an identifier: in `avoid_kill_wait_on`, `kill`
      # is preceded by an underscore, so it is part of a name rather than a command.
      [[ "${window}" =~ (^|[^[:alnum:]_])kill([[:space:]]|$).*\$\{?${var}\}? ]] || continue
      [[ "${window}" =~ (^|[^[:alnum:]_])wait([[:space:]]|$).*\$\{?${var}\}? ]] || continue
      offenders+="${f}: line $((i + 2)): ${lines[i+1]}"$'\n'
    done
  done
  [[ -z "${offenders}" ]] && return 0
  echo "FAIL - a fixture kills and waits for a background job it has only just started (#3125)"
  printf '%s' "${offenders}" | sed 's/^/    /'
  echo "  The kill can be sent before the job has finished starting, and the wait then sits for the job's"
  echo "  whole lifetime. Nothing fails, so it reads as a hang rather than as an error."
  echo "  For a pid naming a process that has already finished, let a job exit on its own instead:"
  echo "    ( exit 0 ) & P=\$!"
  echo "    wait \"\${P}\" 2>/dev/null"
  return 1
}

# fixture_temp_allowed_names <uid>: the names a fixture may leave in its private temp directory without
# being called a leak, because it did not create them. node and tsx write these caches wherever TMPDIR
# points, on any run that shells out to either.
#
# tsx names its cache after the ACCOUNT the run is under, so the name is DERIVED here rather than written
# down. A hardcoded one is correct only on the machine it was written on: on any other Mac or account the
# guard would report that cache as a leak and fail a run for a reason unrelated to the code under test,
# which is how a guard gets edited until it is quiet (#2543 is about exactly that).
#
# Named individually rather than by a wildcard, so a fixture's own leftover cannot hide behind a vague
# pattern, and so one account's cache does not excuse another's turning up.
fixture_temp_allowed_names() {
  local uid="$1"
  echo "node-compile-cache tsx-${uid}"
}

# Reads one finished fixture's private temp directory and returns nonzero when it left anything of its
# own behind. Prints what was left.
#
# WHY. A fixture that creates a temp file and never removes it leaks one per run, forever, and nothing
# notices: the files are small, they are outside the checkout, and the fixture passes. Measured
# 2026-08-13, three fixtures were doing it, and the oldest had been leaking one file per run since at
# least 2026-08-12 (53 of them) because a second `trap ... EXIT` silently REPLACED the first one that
# would have cleaned up. That is the same class as #2585, where the same habit at Xcode scale filled the
# disk and stopped the machine.
fixture_left_temp_files() {
  local dir="$1" entry left=() allowed
  for entry in $(ls -A "${dir}" 2>/dev/null); do
    local is_allowed="false"
    for allowed in $(fixture_temp_allowed_names "$(id -u)"); do
      [[ "${entry}" == "${allowed}" ]] && is_allowed="true"
    done
    [[ "${is_allowed}" == "false" ]] && left+=("${entry}")
  done

  [[ "${#left[@]}" -eq 0 ]] && return 0

  echo "FAIL - ${FIXTURE_PATH_FOR_REPORT:-a fixture} left files behind in its temp directory"
  printf '  %s\n' "${left[@]}"
  echo "  One per run, forever, outside the checkout where nobody looks. Remove them before the fixture"
  echo "  ends. If it already has a cleanup trap, check a LATER trap has not replaced it: bash keeps one"
  echo "  EXIT trap, so the second one silently wins."
  return 1
}

# Runs the given fixture scripts CONCURRENTLY (#2601) and returns the count of fixtures that exited
# nonzero OR that called a command bash could not resolve (so 0 means every fixture passed and every
# assertion in it was real). Never stops at the first failure, so one broken fixture doesn't hide
# another one behind it. Takes an explicit path list rather than globbing itself, so it's testable
# against a throwaway fixture set without touching the real repo scripts.
#
# Concurrent because the serial run cost 113s of which 78s was two fixtures, so the phase costs
# roughly the slowest fixture instead of the sum of all of them. Safe because every fixture is
# isolated by construction: each stubs its dependencies in its own mktemp PATH dir (flock included,
# so none touches the real xcodebuild lock), kills only PIDs it spawned, and no fixture runs git
# against the real repo (audited 2026-08-12, #2601). OVERTURE_FIXTURE_JOBS overrides the pool size,
# and 1 is the old serial behaviour.
#
# Each fixture's output goes to its own file and is printed as one block afterwards, in list order,
# so two fixtures' lines can never interleave and a failure always sits under its own header. The
# "finished" lines exist because of what that trades away: with output no longer streaming as it is
# produced, a silent minute would be indistinguishable from a hang without them (L110).
run_shell_fixtures() {
  local failures=0
  local fixture rc
  local scratch
  scratch="$(mktemp -d)"
  local jobs="${OVERTURE_FIXTURE_JOBS:-8}"

  # The per-fixture wrapper xargs fans out to. `set +e` around the fixture is load-bearing, not
  # tidying: without it a failing fixture would end the wrapper before the status file is written,
  # and the read-out below would score it off a missing file rather than its real exit code. The
  # wrapper itself always exits 0, because xargs would stop dispatching on 255 and treat any other
  # nonzero as its own verdict; the fixtures' verdicts live in the status files, nowhere else.
  # #2929: the wrapper records both ends of each fixture in one progress file, which is what the stall
  # guard reads. Appended with >> from eight lanes at once: each write is a single short line, which
  # POSIX keeps atomic on a file opened for append, and the guard only ever COUNTS lines and compares
  # names, so an interleaved pair would cost nothing anyway.
  cat > "${scratch}/run-one.sh" <<'WRAPPER'
#!/usr/bin/env bash
scratch="$1"; pair="$2"
idx="${pair%%$'\t'*}"
fixture="${pair#*$'\t'}"
mkdir -p "${scratch}/tmp-${idx}"
echo "started ${fixture}" >> "${scratch}/progress"
( set +e; TMPDIR="${scratch}/tmp-${idx}" OVERTURE_FIXTURE_TMPDIR_SCOPED=1 "${fixture}" >"${scratch}/log-${idx}" 2>&1; echo "$?" > "${scratch}/status-${idx}" )
echo "finished ${fixture}" >> "${scratch}/progress"
echo "finished ${fixture}"
exit 0
WRAPPER
  chmod +x "${scratch}/run-one.sh"

  # Index and path travel as one null-delimited argument (tab-split by the wrapper), because the
  # index is what ties a fixture to its log file when completion order is nobody's to predict.
  # Started before the fan-out and stopped after it, including on the way out through the trap: a
  # watcher that outlived its run would sit warning about a file nobody is writing.
  : > "${scratch}/progress"
  start_fixture_watch "${scratch}/progress"
  # The caller's own EXIT trap is put BACK when this returns (#3249). A trap set inside a function
  # belongs to the whole shell, so this line used to disarm whatever cleanup the caller had installed,
  # permanently: every call after the first ran with the caller's trap gone. That is the same defect
  # this file's own leak message warns about, one level up, and it is what leaked one directory per run
  # out of scripts/run-shell-fixtures.test.sh, which removes its scratch from an EXIT trap installed
  # before it ever calls this function. Invisible until now, because the leak landed where the check
  # below could not see it.
  #
  # Restored rather than CHAINED, which was tried first and is wrong: this function is routinely called
  # inside a `$(...)`, and a chained trap then runs the caller's cleanup when that subshell exits, which
  # deleted the caller's scratch in the middle of its own run.
  #
  # And restored ONLY at the top level, which is the same trap wearing a different hat. Inside a
  # `$(...)` nothing this function does to the trap can reach the caller anyway, so there is nothing to
  # put back; putting it back there instead ARMS the caller's cleanup on the substitution's own exit,
  # which deleted the caller's scratch mid-run exactly as chaining did. BASH_SUBSHELL is 0 only in the
  # shell that will still be running when this returns (measured on bash 3.2, this Mac's bash: 0 at the
  # top level, 1 inside both `$(...)` and `( ... )`).
  local previous_exit_trap=""
  [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] && previous_exit_trap="$(trap -p EXIT)"
  trap 'stop_fixture_watch "${FIXTURE_WATCH_PID}"' EXIT

  local i=0
  for fixture in "$@"; do
    printf '%d\t%s\0' "${i}" "${fixture}"
    i=$((i + 1))
  done | xargs -0 -n 1 -P "${jobs}" "${scratch}/run-one.sh" "${scratch}"

  stop_fixture_watch "${FIXTURE_WATCH_PID}"
  # Handed back exactly as it was found. `trap -p` prints a runnable `trap -- '<body>' EXIT`, so the
  # caller's own trap is reinstalled by running what it printed rather than by rebuilding it.
  if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
    if [[ -n "${previous_exit_trap}" ]]; then
      eval "${previous_exit_trap}"
    else
      trap - EXIT
    fi
  fi

  # Every fixture has finished; now read each one's verdict, in list order.
  i=0
  for fixture in "$@"; do
    echo "==> ${fixture}"
    cat "${scratch}/log-${i}" 2>/dev/null || true
    rc="$(cat "${scratch}/status-${i}" 2>/dev/null || echo 1)"
    if [[ "${rc}" -ne 0 ]]; then
      echo "FAIL - ${fixture}"
      # #2850: a fixture that failed may have failed because of a broken pipe rather than because
      # anything is wrong, which is the whole point of that check. Said on THIS branch as well, because
      # this is the one somebody is standing in when they need to know it. It cannot add a failure here,
      # the run is already red; it explains one.
      FIXTURE_PATH_FOR_REPORT="${fixture}" fixture_pipeline_did_not_break "${scratch}/log-${i}" || true
      failures=$((failures + 1))
    else
      # The unresolved-command check goes FIRST, and the order is load-bearing rather than arbitrary. A
      # fixture whose assertions are all typos prints no passing line either, so it trips both rules, and
      # naming the helper it could not find is the message that tells somebody what to do. Asked the other
      # way round, the specific diagnosis is hidden behind the generic one.
      if ! FIXTURE_PATH_FOR_REPORT="${fixture}" unresolved_commands_are_all_declared "${scratch}/log-${i}"; then
        failures=$((failures + 1))
      elif ! fixture_asserted_something "${scratch}/log-${i}"; then
        echo "FAIL - ${fixture} exited 0 but asserted nothing"
        echo "  No passing assertion was printed, so this fixture examined no subjects. A run that"
        echo "  found nothing to check is not a run that found everything correct: exit 0 here means"
        echo "  the body did not do what it looks like it does (an early return, an empty loop, a"
        echo "  guard that skipped every case)."
        failures=$((failures + 1))
      elif ! FIXTURE_PATH_FOR_REPORT="${fixture}" fixture_pipeline_did_not_break "${scratch}/log-${i}"; then
        failures=$((failures + 1))
      elif ! FIXTURE_PATH_FOR_REPORT="${fixture}" fixture_left_temp_files "${scratch}/tmp-${i}"; then
        failures=$((failures + 1))
      fi
    fi
    echo
    i=$((i + 1))
  done
  rm -rf "${scratch}"
  return "${failures}"
}

# Returns the fixture paths THIS run is about: the ones named on the command line, or every
# *.test.sh under scripts/ and mac/scripts/ when none were named. One path per line.
#
# WHY it exists (#3245). main() globbed both directories and ignored its arguments entirely, so
# `bash scripts/run-shell-fixtures.sh scripts/lib/test-all-phases.test.sh` ran all 81 fixtures and
# said nothing about the path it was handed. Proving ONE guard through the runner is the only way to
# get its temp-leak and unresolved-command rules, and it cost a full sweep every time; #3237 measures
# that sweep at 65.7s wall, which is the floor of the cheap lane.
#
# WHY it REFUSES rather than falling back to the sweep (L100, L98). An argument that is silently
# ignored is indistinguishable from one that was honoured: the run looks right and is about something
# else. Falling back on a bad path would be that same defect wearing the fix's name, so a path that
# matches no fixture stops the run and names itself, and ONE bad path among good ones refuses the
# whole selection rather than quietly running the rest.
#
# Named paths are resolved against the CALLER's directory and returned absolute, so this is called
# before main cds to the repo root; the default sweep is repo-relative, as it has always been.
resolve_fixture_paths() {
  local path abs
  if [[ "$#" -eq 0 ]]; then
    (cd "${REPO_ROOT}" && find scripts mac/scripts -name '*.test.sh' | sort)
    return 0
  fi

  local resolved=() missing=()
  for path in "$@"; do
    if [[ -f "${path}" && "${path}" == *.test.sh ]]; then
      abs="$(cd "$(dirname "${path}")" && pwd)/$(basename "${path}")"
      resolved+=("${abs}")
    else
      missing+=("${path}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    {
      echo "No fixture matches:"
      printf '  %s\n' "${missing[@]}"
      echo "  A named path must be an existing *.test.sh file. NOTHING was run: a path matching no"
      echo "  fixture is refused rather than falling back to the whole sweep, because a run that"
      echo "  quietly ran everything instead would look right and be about something else."
    } >&2
    return 1
  fi

  printf '%s\n' "${resolved[@]}"
}

# Every shell script this repo SHIPS, as opposed to the fixtures that test them. Derived from git so a
# script added next year is covered by a rule it never heard of, rather than by a list holding whatever
# somebody remembered (L96).
production_shell_scripts() {
  (cd "${REPO_ROOT}" && git ls-files '*.sh' | grep -v '\.test\.sh$' | sed "s|^|${REPO_ROOT}/|")
}

main() {
  # Selection happens BEFORE the cd, so a relative path resolves against wherever the person is
  # standing rather than against the repo root they may not be in.
  local listing select_status=0
  listing="$(resolve_fixture_paths "$@")" || select_status=$?
  if [[ "${select_status}" -ne 0 ]]; then
    return 2
  fi

  cd "${REPO_ROOT}"
  local fixtures=() f
  while IFS= read -r f; do
    [[ -n "${f}" ]] && fixtures+=("${f}")
  done <<< "${listing}"

  # Zero subjects examined is its own outcome and must never read as "everything passed" (L98). This
  # said "No *.test.sh fixtures found." and exited 0 until #3245: an empty sweep is what a broken
  # checkout, a bad root or a renamed suffix produces, and the emptiest possible failure must not be
  # the cleanest possible pass.
  if [[ "${#fixtures[@]}" -eq 0 ]]; then
    echo "UNMEASURED - no *.test.sh fixture was found under scripts/ or mac/scripts/." >&2
    echo "  Nothing was examined, so this run says nothing about whether the fixtures pass." >&2
    return 2
  fi

  # #2850: read the fixtures' own plumbing BEFORE running them. It costs one grep, and it fires on every
  # run rather than only on the runs where the race actually opens, which is what separates a gate from a
  # witness. The runtime half still runs per fixture below and catches shapes this pattern does not know.
  local source_status=0
  fixture_sources_avoid_short_circuit_pipes "${fixtures[@]}" || source_status=1
  # #3275: and the PRODUCTION scripts, which were exempt from this rule while running far more often
  # (`scripts/test-all.sh` on every push, `verify-and-merge-branch.sh` on every merge). The instance that
  # proves it needed doing is `mac/scripts/lib/hosted-suite-stamp.sh`, which had the defect for real and
  # is not a fixture. Same asymmetry #3258 records one field over.
  #
  # Scanned on the DEFAULT sweep only. A scoped run is about the fixtures somebody named, and reporting
  # a defect in an unrelated production script there would make a targeted run about something else,
  # which is the whole of what #3245 fixed.
  if [[ "$#" -eq 0 ]]; then
    local production=()
    while IFS= read -r p; do
      [[ -n "${p}" ]] && production+=("${p}")
    done < <(production_shell_scripts)
    if [[ "${#production[@]}" -eq 0 ]]; then
      # Zero subjects is unmeasured, never clean (L98). git ls-files answering nothing means the scan
      # was pointed at nothing, not that the repo holds no shell.
      echo "UNMEASURED - no production shell script was found to scan for short-circuiting pipes." >&2
      source_status=1
    else
      fixture_sources_avoid_short_circuit_pipes "${production[@]}" || source_status=1
    fi
  fi
  # Both run, and neither is allowed to stand for the other: each prints its own refusal naming its own
  # defect, so a run carrying both shapes reports both rather than the first one found (L11).
  fixture_sources_avoid_kill_wait_on_a_fresh_job "${fixtures[@]}" || source_status=1

  echo "Running ${#fixtures[@]} shell fixture(s)..."
  local run_status=0
  run_shell_fixtures "${fixtures[@]}" || run_status=$?
  # Both verdicts, never one standing for the other: a clean run says nothing about the plumbing, and
  # broken plumbing says nothing about the assertions (L53).
  if [[ "${source_status}" -ne 0 ]]; then
    return $((run_status + 1))
  fi
  return "${run_status}"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# run_shell_fixtures can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
