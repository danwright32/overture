#!/usr/bin/env bash
set -euo pipefail

# Runs every scripts/*.test.sh and mac/scripts/**/*.test.sh fixture in the repo (#698): each covers
# a pure function extracted from its sibling script (classify_stop_reason in merge-when-green.sh,
# stale_debug_test_host_pids in run-tests-locked.sh, etc.). None of them ran automatically before
# this, so a future edit to one of those functions could silently break its fixture until the real
# script misbehaved for real (a bad CI-merge decision, a stale process left running). Wired into
# scripts/test-all.sh so these fixtures ride along with every other local pre-push check.
#
# Usage: scripts/run-shell-fixtures.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
  cat > "${scratch}/run-one.sh" <<'WRAPPER'
#!/usr/bin/env bash
scratch="$1"; pair="$2"
idx="${pair%%$'\t'*}"
fixture="${pair#*$'\t'}"
( set +e; "${fixture}" >"${scratch}/log-${idx}" 2>&1; echo "$?" > "${scratch}/status-${idx}" )
echo "finished ${fixture}"
exit 0
WRAPPER
  chmod +x "${scratch}/run-one.sh"

  # Index and path travel as one null-delimited argument (tab-split by the wrapper), because the
  # index is what ties a fixture to its log file when completion order is nobody's to predict.
  local i=0
  for fixture in "$@"; do
    printf '%d\t%s\0' "${i}" "${fixture}"
    i=$((i + 1))
  done | xargs -0 -n 1 -P "${jobs}" "${scratch}/run-one.sh" "${scratch}"

  # Every fixture has finished; now read each one's verdict, in list order.
  i=0
  for fixture in "$@"; do
    echo "==> ${fixture}"
    cat "${scratch}/log-${i}" 2>/dev/null || true
    rc="$(cat "${scratch}/status-${i}" 2>/dev/null || echo 1)"
    if [[ "${rc}" -ne 0 ]]; then
      echo "FAIL - ${fixture}"
      failures=$((failures + 1))
    else
      if ! FIXTURE_PATH_FOR_REPORT="${fixture}" unresolved_commands_are_all_declared "${scratch}/log-${i}"; then
        failures=$((failures + 1))
      fi
    fi
    echo
    i=$((i + 1))
  done
  rm -rf "${scratch}"
  return "${failures}"
}

main() {
  cd "${REPO_ROOT}"
  local fixtures=()
  while IFS= read -r -d '' f; do
    fixtures+=("${f}")
  done < <(find scripts mac/scripts -name '*.test.sh' -print0 | sort -z)

  if [[ "${#fixtures[@]}" -eq 0 ]]; then
    echo "No *.test.sh fixtures found."
    exit 0
  fi

  echo "Running ${#fixtures[@]} shell fixture(s)..."
  run_shell_fixtures "${fixtures[@]}"
}

# Allow this file to be sourced (e.g. by a test fixture) without running main, so
# run_shell_fixtures can be exercised directly. Mirrors merge-when-green.sh's convention.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
