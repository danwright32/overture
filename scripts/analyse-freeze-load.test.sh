#!/usr/bin/env bash
# Fixture for scripts/analyse-freeze-load.sh (#3464).
#
# The script's whole subject is a pile of recorded process tables, so every case here builds its own
# throwaway pile with a KNOWN distribution rather than reading the real one: a fixture reading
# ~/.overture-mac-test-diagnostics would assert about whatever measurements happened to have been taken
# (L2, L224). The two collaborators that reach outside are the recordings directory and the baseline
# list, and both are set in every case below.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "$(dirname "$0")/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/analyse-freeze-load.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

BASELINE_FILE="${WORK}/resting-baseline.txt"
cat > "${BASELINE_FILE}" <<'BASE'
# measured: 2026-09-01
cloud-drive-daemon
bztransmit
BASE

# A real process table on this Mac holds around 2,100 rows, nearly all of them at rest. Every table
# below is padded to that SHAPE rather than written as the three interesting lines, because the reading
# this script produces is a distribution: on a three row table any percentile is noise, and a rule tuned
# against one would be measuring the fixture rather than the machine (L354, L101).
QUIET_ROWS=()
for _i in $(seq 1 300); do
  QUIET_ROWS+=("  0.1 $((2000 + _i)) somethingquiet${_i}")
done

# Writes a .processes.txt in the shape freeze-measure.sh writes: a before block and an after block.
write_table() {
  local dir="$1" label="$2"; shift 2
  mkdir -p "${dir}"
  {
    echo "=== before the sample ==="
    printf '%%CPU   PID COMM\n'
    printf '%s\n' "$@"
    echo
    echo "=== after the sample ==="
    printf '%%CPU   PID COMM\n'
    printf '%s\n' "$@"
  } > "${dir}/freeze-measure-${label}-20260902-120000.processes.txt"
}

run_analyse() {
  local dir="$1"; shift
  OVERTURE_MEASURE_OUT="${dir}" \
  OVERTURE_MEASURE_BASELINE_FILE="${BASELINE_FILE}" \
  "${SCRIPT}" "$@" 2>&1
}

# --- 1. nothing recorded is UNMEASURED, never a clean bill of health -------------------------------
#
# An empty pile and a pile in which nothing was ever unusual leave the same empty result, and the
# emptiest possible failure must not read as the cleanest possible pass (L98, L11).
EMPTY="${WORK}/empty"
mkdir -p "${EMPTY}"
RESULT="$(run_analyse "${EMPTY}")"
STATUS=$?
assert_equals "no recorded tables exits 2" 2 "${STATUS}"
assert_contains "no recorded tables says UNMEASURED" "${RESULT}" "UNMEASURED"

# --- 2. tables present but nothing readable in them is ALSO unmeasured -----------------------------
#
# A directory of files that parse to zero rows is not a quiet machine, it is a failed read.
JUNK="${WORK}/junk"
mkdir -p "${JUNK}"
printf 'this file holds no process table at all\n' \
  > "${JUNK}/freeze-measure-A-20260902-120000.processes.txt"
RESULT="$(run_analyse "${JUNK}")"
STATUS=$?
assert_equals "unreadable tables exit 2" 2 "${STATUS}"
assert_contains "unreadable tables say UNMEASURED" "${RESULT}" "UNMEASURED"

# --- 3. a threshold in the TAIL of the real distribution passes ------------------------------------
#
# The distribution here is deliberately the shape the real one has: almost everything at rest, a thin
# tail. A threshold above the bulk is doing its job and must not be reported as a finding.
TAIL="${WORK}/tail"
write_table "${TAIL}" A "${QUIET_ROWS[@]}" '349.5   676 Adobe Lightroom Classic' \
  ' 99.4  1393 cloud-drive-daemon' '  0.4   901 /Applications/Overture.app/Contents/MacOS/Overture'
RESULT="$(OVERTURE_MEASURE_BUSY_CPU=25.0 run_analyse "${TAIL}")"
STATUS=$?
assert_equals "a threshold in the tail exits 0" 0 "${STATUS}"
assert_contains "it says where the threshold lands" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "percentile"

# --- 4. a threshold sitting INSIDE the bulk is a finding, not a pass -------------------------------
#
# L172: a threshold in the dense middle turns the count it produces into noise, because a small uniform
# shift carries dozens of rows across at once and reads as a regression.
RESULT="$(OVERTURE_MEASURE_BUSY_CPU=0.05 run_analyse "${TAIL}")"
STATUS=$?
assert_equals "a threshold inside the bulk exits 1" 1 "${STATUS}"
assert_contains "it says the threshold is inside the bulk" \
  "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "bulk"

# --- 5. the always-present set is excluded, and so is Overture itself ------------------------------
#
# Both for the reasons freeze-measure.sh states: the daemons are this Mac at rest, and Overture is the
# SUBJECT of the measurement rather than contamination of it. A distribution counting either would be
# describing something else.
BASEONLY="${WORK}/baseonly"
write_table "${BASEONLY}" A "${QUIET_ROWS[@]}" ' 99.4  1393 cloud-drive-daemon' \
  ' 84.0 15143 bztransmit' \
  '287.0   901 /Applications/Overture.app/Contents/MacOS/Overture'
RESULT="$(OVERTURE_MEASURE_BUSY_CPU=25.0 run_analyse "${BASEONLY}")"
STATUS=$?
assert_equals "a table holding only baseline and Overture exits 0" 0 "${STATUS}"
assert_not_contains "the always-present daemons are not in the distribution" "${RESULT}" "bztransmit"
assert_not_contains "Overture's own CPU is not in the distribution" "${RESULT}" "MacOS/Overture"

# --- 6. it names what sits just above the threshold, per measurement -------------------------------
#
# The reading this exists to support is not the percentile, it is WHICH processes are crossing the line,
# because that is what says whether the line is in the right place or the list is missing a name. This
# is how the compositor was found sitting above the threshold in every reading taken while the app was
# drawing.
NAMED="${WORK}/named"
write_table "${NAMED}" archive-typing "${QUIET_ROWS[@]}" \
  ' 48.6   427 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer' \
  '142.0   767 corespotlightd'
RESULT="$(OVERTURE_MEASURE_BUSY_CPU=25.0 run_analyse "${NAMED}")"
STATUS=$?
assert_equals "a measurement with real load exits 0 when the threshold is well placed" 0 "${STATUS}"
assert_contains "it names the measurement" "${RESULT}" "archive-typing"
assert_contains "it names what crossed the threshold" "${RESULT}" "WindowServer"
assert_contains "it names the other one too" "${RESULT}" "corespotlightd"

# --- 7. a missing baseline list is UNMEASURED, not an empty exclusion set ---------------------------
#
# With no list every ordinary daemon enters the distribution and the percentiles describe a machine
# nobody is running, which is the same defect as having no list, arriving silently (L98).
RESULT="$(OVERTURE_MEASURE_OUT="${TAIL}" OVERTURE_MEASURE_BASELINE_FILE="${WORK}/no-such.txt" \
  "${SCRIPT}" 2>&1)"
STATUS=$?
assert_equals "a missing baseline list exits 2" 2 "${STATUS}"
assert_contains "it says which list is missing" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "baseline"

if [ "${FAILURES}" -eq 0 ]; then
  echo "All analyse-freeze-load.sh fixtures passed."
else
  echo "${FAILURES} analyse-freeze-load.sh assertion(s) failed."
  exit 1
fi
