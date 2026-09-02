#!/usr/bin/env bash
# Fixture for scripts/freeze-measure.sh (#3434 Phase 0, with #3442).
#
# What it drives, and why through seams rather than the real machine: the script's whole subject is the
# state of THIS Mac, so a fixture reading the real process table would assert about whatever happened to
# be running when somebody ran it (L2, L224). Every collaborator that touches the machine is a named
# seam, and each is set here, so nothing in this file samples, greps or reads a real process.
#
# THE RULE THIS ENCODES, because the obvious one is wrong. Phase 0 as written calls a machine quiet when
# no xcodebuild, xctest or agent worktree is running. Measured 2026-09-01 on this Mac: none of the three
# was running and load averages read 13.01 / 28.35 / 28.97, with Synology's cloud-drive-daemon at 99.4%
# and Backblaze's bztransmit at 84.0%. Dan's correction the same day is what settles the design: those
# two are ALWAYS running here, and Lightroom is something he uses rather than something to ban. So a
# check refusing on either refuses every measurement he will ever take, which is the gate that fires on
# the ordinary case and is switched off within a day (L93, L36).
#
# What the script therefore judges is not quiet against busy. It is BASELINE (only the always-present
# set is busy) against ELEVATED (something else is), against UNKNOWN (the table could not be read), and
# an ELEVATED run still writes its record, because an observation nobody can re-examine is worse than
# one carrying its own caveat (#3442).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "$(dirname "$0")/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/freeze-measure.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# --- the stubs every case shares -----------------------------------------------------------------
make_ps() {
  local out="${WORK}/ps-$1"; shift
  { printf '%%CPU   PID COMM\n'; printf '%s\n' "$@"; } > "${out}.txt"
  cat > "${out}" <<STUB
#!/bin/sh
cat "${out}.txt"
STUB
  chmod +x "${out}"
  printf '%s' "${out}"
}

make_pgrep() {
  local out="${WORK}/pgrep-$1"; shift
  printf '%s\n' "$@" > "${out}.txt"
  cat > "${out}" <<STUB
#!/bin/sh
cat "${out}.txt"
STUB
  chmod +x "${out}"
  printf '%s' "${out}"
}

# The stub honours the REAL `/usr/bin/sample` interface, checked against the tool itself on 2026-09-01:
#
#   sample <pid | partial-process-name> [duration [samplingInterval]] [options...] [-file <filename>]
#
# It is written this way deliberately. The first version of this fixture invented a
# `sample <pid> <seconds> <outfile>` signature, and the script was built to match the invention: the
# real tool reads a third positional argument as the sampling INTERVAL IN MILLISECONDS, so production
# would have sampled with a nonsense interval and written nowhere near the path the record names, while
# every assertion here stayed green. A stub you wrote can only ever confirm your own assumption about
# the interface (L52), so this one refuses anything but the real shape.
SAMPLER="${WORK}/sample"
cat > "${SAMPLER}" <<'STUB'
#!/bin/sh
pid="$1"; shift
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -file) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "${out}" ]; then
  echo "sample: no -file given, so this run would have written to a default path" >&2
  exit 1
fi
printf 'Analysis of sampling Overture (pid %s)\n' "${pid}" > "${out}"
STUB
chmod +x "${SAMPLER}"

BAD_SAMPLER="${WORK}/sample-fails"
cat > "${BAD_SAMPLER}" <<'STUB'
#!/bin/sh
echo "sample: could not attach" >&2
exit 1
STUB
chmod +x "${BAD_SAMPLER}"

# The always-present set, as a file carrying its own measurement date. Derived from the Mac at rest and
# recorded, never hardcoded in the script: a different Mac, or this one after Dan changes what he runs,
# would otherwise read as permanently ELEVATED and the tool would be useless there (L96, L153).
BASELINE_FILE="${WORK}/resting-baseline.txt"
cat > "${BASELINE_FILE}" <<'BASE'
# measured: 2026-09-01
cloud-drive-daemon
bztransmit
BASE

# Overture idle, only the always-present daemons busy. This is Dan's ordinary working machine.
BASELINE_PS="$(make_ps baseline \
  ' 99.4  1393 /Users/x/Library/Application Support/SynologyDrive/SynologyDrive.app/Contents/MacOS/cloud-drive-daemon' \
  ' 84.0 15143 /Library/Backblaze.bzpkg/bztransmit' \
  '  0.4   901 /Applications/Overture.app/Contents/MacOS/Overture')"

# The same, plus Lightroom mid-import. Not banned: named, so the record says why it is not comparable.
ELEVATED_PS="$(make_ps elevated \
  '349.5   676 /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic' \
  ' 99.4  1393 cloud-drive-daemon' \
  ' 84.0 15143 /Library/Backblaze.bzpkg/bztransmit' \
  '  0.4   901 /Applications/Overture.app/Contents/MacOS/Overture')"

ONE_APP="$(make_pgrep one '901')"
TWO_APPS="$(make_pgrep two '901' '902')"
NO_APP="$(make_pgrep none)"

run_measure() {
  local out="$1"; shift
  OVERTURE_MEASURE_OUT="${out}" \
  OVERTURE_MEASURE_SAMPLE="${SAMPLER}" \
  OVERTURE_MEASURE_SECONDS=1 \
  OVERTURE_MEASURE_BASELINE_FILE="${BASELINE_FILE}" \
  "${SCRIPT}" "$@" 2>&1
}

# --- 1. the always-present daemons are the BASELINE, not a refusal --------------------------------
#
# The case Dan's correction is about. Synology at 99% and Backblaze at 84% is this Mac at rest, so a
# measurement taken beside them is the representative one and must pass.
OUT1="${WORK}/out1"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT1}" --label A)"
STATUS=$?
assert_equals "the always-present daemons busy still exits 0" 0 "${STATUS}"
assert_contains "it reports BASELINE" "${RESULT}" "BASELINE"
assert_not_contains "the always-present set is never called elevated" "${RESULT}" "ELEVATED"

# --- 2. something NOT on the list is ELEVATED, named, and still recorded --------------------------
OUT2="${WORK}/out2"
RESULT="$(OVERTURE_MEASURE_PS="${ELEVATED_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT2}" --label A)"
STATUS=$?
assert_equals "an unusual heavy process exits 1" 1 "${STATUS}"
assert_contains "it reports ELEVATED" "${RESULT}" "ELEVATED"
assert_contains "it names what was unusual" "${RESULT}" "Lightroom"
assert_not_contains "it does not accuse the always-present daemons" "${RESULT}" "bztransmit"

RECORD="$(find "${OUT2}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
assert_contains "an elevated run still writes its record" "${RECORD}" "freeze-measure"
assert_contains "the record carries the load verdict" "$(cat "${RECORD}" 2>/dev/null)" "elevated"

# The sample artifact actually EXISTS at the path the record names. This is the assertion that would
# have caught the invented signature above: a record naming a file nobody wrote is a measurement that
# reads as taken and is not there (L3).
SAMPLE_PATH="$(sed -n 's/.*"sample": "\(.*\)",/\1/p' "${RECORD}" 2>/dev/null)"
assert_contains "the record names a sample artifact" "${SAMPLE_PATH}" "freeze-measure"
if [ -s "${SAMPLE_PATH}" ]; then
  pass "the sample artifact exists where the record says it does"
else
  fail "the sample artifact exists where the record says it does" "no file at '${SAMPLE_PATH}'"
fi

# --- 2b. load that ARRIVES DURING the sample is caught, not missed --------------------------------
#
# Measured 2026-09-01, and it is why this exists. A reading taken at 20:05 showed Lightroom, Synology and
# Backblaze. A reading at 20:16, eleven minutes later, additionally showed ffmpeg at 394% and four Python
# processes at ~45% each, and by 20:17 every one of those had exited. Load on this Mac arrives and leaves
# inside a two minute window, so a process table read ONCE before the sample says nothing about what ran
# DURING it, which is the only window the measurement is about (L239).
PS_CHANGES="${WORK}/ps-changes"
printf '0' > "${WORK}/ps-calls"
cat > "${PS_CHANGES}" <<STUB
#!/bin/sh
n=\$(cat "${WORK}/ps-calls")
printf '%s' \$((n + 1)) > "${WORK}/ps-calls"
printf '%%CPU   PID COMM\n'
printf '  0.4   901 /Applications/Overture.app/Contents/MacOS/Overture\n'
if [ "\$n" -ge 1 ]; then
  printf '394.1 55479 ffmpeg\n'
fi
STUB
chmod +x "${PS_CHANGES}"

OUT2B="${WORK}/out2b"
RESULT="$(OVERTURE_MEASURE_PS="${PS_CHANGES}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT2B}" --label A)"
STATUS=$?
assert_equals "load arriving during the sample exits 1" 1 "${STATUS}"
assert_contains "it names the process that arrived" "${RESULT}" "ffmpeg"
assert_contains "it says the load arrived mid-run" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "during"

# --- 3. the app's own CPU never counts as load ----------------------------------------------------
#
# Overture is the SUBJECT of the measurement, so Overture being busy is the thing being measured. A rule
# counting it would report every real freeze as an invalid reading.
BUSY_APP_PS="$(make_ps busyapp \
  '287.0   901 /Applications/Overture.app/Contents/MacOS/Overture' \
  ' 99.4  1393 cloud-drive-daemon')"
OUT3="${WORK}/out3"
RESULT="$(OVERTURE_MEASURE_PS="${BUSY_APP_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT3}" --label A)"
STATUS=$?
assert_equals "a busy Overture at baseline still exits 0" 0 "${STATUS}"

# --- 4. could-not-tell is its own outcome, never "at baseline" -------------------------------------
UNREADABLE="${WORK}/ps-broken"
cat > "${UNREADABLE}" <<'STUB'
#!/bin/sh
echo "ps: cannot read" >&2
exit 1
STUB
chmod +x "${UNREADABLE}"
OUT4="${WORK}/out4"
RESULT="$(OVERTURE_MEASURE_PS="${UNREADABLE}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT4}" --label A)"
STATUS=$?
assert_equals "an unreadable process table exits 2" 2 "${STATUS}"
assert_contains "an unreadable process table says UNMEASURED" "${RESULT}" "UNMEASURED"
assert_not_contains "could-not-tell never reads as baseline" "${RESULT}" "BASELINE"

# --- 5. a missing baseline file is UNMEASURED, never an empty list ---------------------------------
#
# An empty always-present list would make every ordinary run ELEVATED, which is the same defect as
# banning the daemons outright, arriving silently instead (L98).
OUT5="${WORK}/out5"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  OVERTURE_MEASURE_OUT="${OUT5}" OVERTURE_MEASURE_SAMPLE="${SAMPLER}" OVERTURE_MEASURE_SECONDS=1 \
  OVERTURE_MEASURE_BASELINE_FILE="${WORK}/no-such-baseline.txt" \
  "${SCRIPT}" --label A 2>&1)"
STATUS=$?
assert_equals "a missing baseline file exits 2" 2 "${STATUS}"
assert_contains "it says the baseline is what is missing" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "baseline"

# --- 6. two builds running is its own refusal, naming both -----------------------------------------
#
# CLAUDE.md's rule, minted from a Cmd+W that quit the live app: two copies of Overture can run at once
# and neither name nor bundle id tells them apart, so measuring one silently measures a build nobody
# chose.
OUT6="${WORK}/out6"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${TWO_APPS}" \
  run_measure "${OUT6}" --label A)"
STATUS=$?
assert_equals "two running builds exit 2" 2 "${STATUS}"
assert_contains "the refusal names both pids" "${RESULT}" "901"
assert_contains "the refusal names the second pid" "${RESULT}" "902"

# --- 7. no app running is a DIFFERENT refusal ------------------------------------------------------
OUT7="${WORK}/out7"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${NO_APP}" \
  run_measure "${OUT7}" --label A)"
STATUS=$?
assert_equals "no running build exits 2" 2 "${STATUS}"
assert_contains "no running build says so in its own words" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "not running"
assert_not_contains "it is not reported as the two-copies refusal" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "two copies"

# --- 8. a failed sample is UNMEASURED, never a baseline pass ---------------------------------------
OUT8="${WORK}/out8"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  OVERTURE_MEASURE_OUT="${OUT8}" OVERTURE_MEASURE_SAMPLE="${BAD_SAMPLER}" OVERTURE_MEASURE_SECONDS=1 \
  OVERTURE_MEASURE_BASELINE_FILE="${BASELINE_FILE}" \
  "${SCRIPT}" --label A 2>&1)"
STATUS=$?
assert_equals "a failed sample exits 2" 2 "${STATUS}"
assert_contains "a failed sample says UNMEASURED" "${RESULT}" "UNMEASURED"

# --- 9. a label is required -------------------------------------------------------------------------
OUT9="${WORK}/out9"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT9}")"
STATUS=$?
assert_equals "a missing label exits 2" 2 "${STATUS}"
assert_contains "a missing label says which argument" "${RESULT}" "--label"

if [ "${FAILURES}" -eq 0 ]; then
  echo "All freeze-measure.sh fixtures passed."
else
  echo "${FAILURES} freeze-measure.sh assertion(s) failed."
  exit 1
fi
