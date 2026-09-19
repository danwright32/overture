#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=./lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"

# #1902: the wrapper around the small venue report. What it must never do is let a run that measured
# nothing read as "no small rooms" (L98), and what it must always do is print the privacy warning with the
# report. Driven through its runner seam with a fake runner, never the real suite or Dan's real files (L2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/report-small-venues.sh"

FAILURES=0

# A fake runner that writes $1 as the report (or nothing when empty) and exits $2.
make_runner() {
  local body="$1" code="$2" runner
  runner="$(fixture_scratch_file)"
  cat > "${runner}" <<EOF
#!/usr/bin/env bash
if [ -n "${body}" ]; then printf '%s\nrunner args: %s\n' "${body}" "\$*" > "\${TEST_RUNNER_OVERTURE_SMALL_VENUES_OUT}"; fi
exit ${code}
EOF
  chmod +x "${runner}"
  echo "${runner}"
}

# Stand-ins for the two live files, so the fixture never reads Dan's (L2). Their contents do not matter:
# the fake runner does not read them; the script only checks the history is readable.
FAKE_SHOOTS="$(fixture_scratch_file)"
echo '{}' > "${FAKE_SHOOTS}"
FAKE_EXPORT="$(fixture_scratch_file)"

run_script() {
  local out code
  out="$(OVERTURE_SMALL_VENUES_RUNNER="$1" OVERTURE_SMALL_VENUES_SHOOTS="${2:-${FAKE_SHOOTS}}" \
    OVERTURE_SMALL_VENUES_EXPORT="${FAKE_EXPORT}" "${SCRIPT}" 2>&1)"
  code=$?
  printf '%s\nexit=%s\n' "${out}" "${code}"
}

GOOD="$(make_runner "Invented Hall  [shot here before (1 night)]" 0)"
GOOD_RUN="$(run_script "${GOOD}")"
assert_contains "a report that was written is printed" "${GOOD_RUN}" "Invented Hall  [shot here before (1 night)]"
assert_contains "with the privacy warning beside it" "${GOOD_RUN}" "never paste it into GitHub"
assert_contains "and exits 0" "${GOOD_RUN}" "exit=0"

FAILED="$(make_runner "" 65)"
FAILED_RUN="$(run_script "${FAILED}")"
assert_contains "a failed run is unmeasured, not empty" "${FAILED_RUN}" "UNMEASURED"
assert_contains "and exits 2" "${FAILED_RUN}" "exit=2"

SILENT="$(make_runner "" 0)"
SILENT_RUN="$(run_script "${SILENT}")"
assert_contains "a green run that wrote nothing is unmeasured too" "${SILENT_RUN}" "wrote no report"
assert_contains "and exits 2" "${SILENT_RUN}" "exit=2"
assert_not_contains "and never prints a report header as if it had one" "${SILENT_RUN}" "never paste it into GitHub"

# A shoot history that is not there is refused before anything runs.
MISSING_RUN="$(run_script "${GOOD}" "${FAKE_EXPORT}.not-there")"
assert_contains "a missing shoot history is unmeasured" "${MISSING_RUN}" "no readable shoot history"
assert_contains "and exits 2" "${MISSING_RUN}" "exit=2"

# The runner is asked for the one opt-in suite and nothing wider.
assert_contains "it runs only the live report suite" "${GOOD_RUN}" "-only-testing:OvertureTests/SmallVenueReportLive"

rm -f "${GOOD}" "${FAILED}" "${SILENT}" "${FAKE_SHOOTS}" "${FAKE_EXPORT}"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All report-small-venues.sh fixtures passed."
  exit 0
fi
echo "${FAILURES} report-small-venues.sh fixture(s) failed." >&2
exit 1
