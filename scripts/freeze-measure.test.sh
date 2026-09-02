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

# The window count is a seam like every other collaborator that touches the machine: left real, each
# case below would ask System Events about whatever Overture happens to be running, which is the live
# app (L2, L284).
make_windows() {
  local out="${WORK}/windows-$1"
  printf '%s\n' "$2" > "${out}.txt"
  cat > "${out}" <<STUB
#!/bin/sh
cat "${out}.txt"
STUB
  chmod +x "${out}"
  printf '%s' "${out}"
}
WINDOW_OPEN="$(make_windows open '1')"
WINDOW_NONE="$(make_windows none '0')"
WINDOWS_UNREADABLE="${WORK}/windows-broken"
cat > "${WINDOWS_UNREADABLE}" <<'STUB'
#!/bin/sh
echo "System Events got an error: osascript is not allowed assistive access." >&2
exit 1
STUB
chmod +x "${WINDOWS_UNREADABLE}"

ONE_APP="$(make_pgrep one '901')"
TWO_APPS="$(make_pgrep two '901' '902')"
NO_APP="$(make_pgrep none)"

run_measure() {
  local out="$1"; shift
  OVERTURE_MEASURE_OUT="${out}" \
  OVERTURE_MEASURE_SAMPLE="${SAMPLER}" \
  OVERTURE_MEASURE_SECONDS=1 \
  OVERTURE_MEASURE_BASELINE_FILE="${BASELINE_FILE}" \
  OVERTURE_MEASURE_WINDOWS="${OVERTURE_MEASURE_WINDOWS:-${WINDOW_OPEN}}" \
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

# --- 2c. a burst that begins AND ends INSIDE the sample window is caught (#3463) -------------------
#
# 2b covers load that arrives and is still there at the end, which the two end reads can see. This is the
# case they structurally cannot: measured 2026-09-01 while building the script, a reading at 20:16 showed
# ffmpeg at 394.1% and four Python processes at ~45% each, and by 20:17 all five had exited. Bursts here
# last a minute or two and a default sample is 10 seconds, so a burst can sit wholly inside one. Read only
# at the two ends, that measurement reports BASELINE while several cores were busy for its whole duration,
# which is the failure that reads as a clean result (L98).
#
# Both sides of this case wait on a CONDITION rather than on a clock, so it costs no fixed time and does
# not assert about what else this Mac is running (L290, L224): the ps stub counts its own calls, and the
# sampler stub exits as soon as the script has polled twice.
printf '0' > "${WORK}/burst-calls"
PS_BURST="${WORK}/ps-burst"
cat > "${PS_BURST}" <<STUB
#!/bin/sh
n=\$(cat "${WORK}/burst-calls")
printf '%s' \$((n + 1)) > "${WORK}/burst-calls"
printf '%%CPU   PID COMM\n'
printf '  0.4   901 /Applications/Overture.app/Contents/MacOS/Overture\n'
# Every edge of the burst window is settled by a CONDITION rather than by a clock, because both of the
# earlier versions of this case were races and each failed differently. Keying the burst on the CALL
# INDEX passed against the UNPOLLED script, since with no polls the after-read inherited the index the
# first poll would have had, and the case reported a defect that was really the stub answering its own
# question (L70). Letting the sampler close the window on its own count then lost to the poll that should
# have observed it, about one run in three (L290, L134).
#
# So: any read after the first WAITS for the sampler to have opened the window, bounded, and stops
# waiting the moment the sampler says it has finished, which is what keeps the unpolled case fast AND
# still failing.
if [ "\$n" -ge 1 ]; then
  j=0
  while [ "\$j" -lt 300 ]; do
    if [ -e "${WORK}/burst-active" ] || [ -e "${WORK}/sampler-done" ]; then break; fi
    j=\$((j + 1))
    sleep 0.01
  done
fi
if [ -e "${WORK}/burst-active" ]; then
  printf '394.1 55479 ffmpeg\n'
fi
# The window closes only AFTER a poll has seen it, and this line is what closes it.
if [ "\$n" -ge 2 ]; then
  : > "${WORK}/burst-over"
fi
STUB
chmod +x "${PS_BURST}"

# Bounded, so a script that never polls fails this case rather than hanging it (L110).
SAMPLER_SLOW="${WORK}/sample-slow"
cat > "${SAMPLER_SLOW}" <<STUB
#!/bin/sh
pid="\$1"; shift
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -file) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
: > "${WORK}/burst-active"
i=0
while [ "\$i" -lt 400 ]; do
  if [ -e "${WORK}/burst-over" ]; then break; fi
  i=\$((i + 1))
  sleep 0.02
done
rm -f "${WORK}/burst-active"
: > "${WORK}/sampler-done"
printf 'Analysis of sampling Overture (pid %s)\n' "\$pid" > "\$out"
STUB
chmod +x "${SAMPLER_SLOW}"

OUT2C="${WORK}/out2c"
RESULT="$(OVERTURE_MEASURE_PS="${PS_BURST}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  OVERTURE_MEASURE_OUT="${OUT2C}" OVERTURE_MEASURE_SAMPLE="${SAMPLER_SLOW}" \
  OVERTURE_MEASURE_SECONDS=1 OVERTURE_MEASURE_POLL_SECONDS=0.05 \
  OVERTURE_MEASURE_BASELINE_FILE="${BASELINE_FILE}" \
  OVERTURE_MEASURE_WINDOWS="${WINDOW_OPEN}" \
  "${SCRIPT}" --label A 2>&1)"
STATUS=$?
assert_equals "a burst wholly inside the sample window exits 1" 1 "${STATUS}"
assert_contains "it names the process that was busy only mid-sample" "${RESULT}" "ffmpeg"
assert_not_contains "a burst inside the window never reads as BASELINE" "${RESULT}" "BASELINE"

# The polling is the cost this case adds, so the record states how many reads it took rather than leaving
# the price of the fix unmeasured (L353).
RECORD2C="$(find "${OUT2C}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
POLLS="$(sed -n 's/.*"process_polls": \([0-9]*\).*/\1/p' "${RECORD2C}" 2>/dev/null)"
if [ -n "${POLLS}" ] && [ "${POLLS}" -ge 1 ]; then
  pass "the record says how many times it read the process table during the sample"
else
  fail "the record says how many times it read the process table during the sample" "got '${POLLS}'"
fi

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
  OVERTURE_MEASURE_WINDOWS="${WINDOW_OPEN}" \
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
  OVERTURE_MEASURE_WINDOWS="${WINDOW_OPEN}" \
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

# --- 10. a reading taken with NO window open is its own outcome, never a pass (#3477) --------------
#
# Overture is a MenuBarExtra app and routinely sits with no window at all. Measured 2026-09-02: osascript
# reported zero windows for the running app (pid 9747), and a three second sample taken in that state
# recorded an app drawing nothing. That reading comes back looking EXCELLENT and is indistinguishable from
# a genuinely fast one, which is the emptiest possible measurement reading as the cleanest possible result
# (L98). Phase 0 compares Measurement A against B, so a windowless reading on either side silently answers
# a different question.
OUT10="${WORK}/out10"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  OVERTURE_MEASURE_WINDOWS="${WINDOW_NONE}" run_measure "${OUT10}" --label A)"
STATUS=$?
assert_equals "a windowless reading does not exit 0" 1 "${STATUS}"
assert_contains "it says the app was drawing nothing" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "no window"
assert_contains "it names the remedy that changes the state the reader is stuck in" \
  "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "take it again"
# The two facts stay in two fields, so a quiet machine is still reported as one (L53): what the MACHINE
# was doing and what the APP was doing are independent, and folding either into the other loses a reading
# somebody may want.
assert_contains "the load verdict is still reported on its own terms" \
  "$(cat "$(find "${OUT10}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)" 2>/dev/null)" '"load": "baseline"' 

RECORD10="$(find "${OUT10}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
assert_contains "the record carries the window verdict as its own field" "$(cat "${RECORD10}" 2>/dev/null)" '"windows": "none"'

# --- 11. a window count that could not be READ is not "no window", and not "open" ------------------
#
# Three outcomes, on the load verdict's own pattern: could-not-tell is never folded into either of the
# two it sits between (L11, L98). Its remedy differs too, which is what makes it a separate outcome
# rather than a separate sentence (L260): one is answered by opening the window Dan freezes in, the
# other by granting the automation access osascript was refused.
OUT11="${WORK}/out11"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  OVERTURE_MEASURE_WINDOWS="${WINDOWS_UNREADABLE}" run_measure "${OUT11}" --label A)"
STATUS=$?
assert_equals "an unreadable window count does not exit 0" 1 "${STATUS}"
assert_contains "it says the window count could not be read" \
  "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "could not"
assert_not_contains "it does not claim the app had no window" \
  "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "no window"

RECORD11="$(find "${OUT11}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
assert_contains "the record keeps could-not-tell apart from none" \
  "$(cat "${RECORD11}" 2>/dev/null)" '"windows": "unknown"'

# --- 12. a window open at both ends, at baseline load, is the reading that passes ------------------
#
# The positive control for cases 10 and 11: without it, a script that exited 1 on every run would satisfy
# both of them (L159).
OUT12="${WORK}/out12"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  OVERTURE_MEASURE_WINDOWS="${WINDOW_OPEN}" run_measure "${OUT12}" --label A)"
STATUS=$?
assert_equals "a window open at baseline load exits 0" 0 "${STATUS}"
RECORD12="$(find "${OUT12}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
assert_contains "the record says a window was open" "$(cat "${RECORD12}" 2>/dev/null)" '"windows": "open"'

# --- 13. the record a CONTAMINATED reading writes can actually be read back (#3483) ----------------
#
# The half that had never been asserted, and it failed in the direction that reads as fine. Measured
# 2026-09-02 over the 10 records in ~/.overture-mac-test-diagnostics: 8 could not be parsed and 2 could,
# and the 2 that could were exactly the 2 whose elevated list was EMPTY. So a reader that skips what it
# cannot parse keeps every clean reading and silently drops every contaminated one, which is precisely
# the population #3442 forbids dropping.
#
# Asserted by PARSING it with a real parser rather than by matching text in it, because the assertion
# above ("the record carries the load verdict") is satisfied by a file no parser can read: a guard must
# use the reader's own predicate, not a looser one (L150).
parses_as_json() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
}

OUT13="${WORK}/out13"
RESULT="$(OVERTURE_MEASURE_PS="${ELEVATED_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT13}" --label A)"
RECORD13="$(find "${OUT13}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
if parses_as_json "${RECORD13}"; then
  pass "an ELEVATED record parses as JSON"
else
  fail "an ELEVATED record parses as JSON" "$(python3 -c 'import json,sys
try:
    json.load(open(sys.argv[1]))
except Exception as e:
    print(e)' "${RECORD13}" 2>&1)"
fi

# The elevated names really are IN it, so a writer that fixed the parse by emitting an empty array would
# not satisfy this (L98). Two entries, so the separator between them is exercised at all: with one entry
# a trailing separator and a correct one are the same file.
# One of them carries a double quote and a backslash in its name, which is what the escaping in the
# writer exists for. Without it those characters end the JSON string early and the record is unreadable
# for a second, independent reason, so the parse assertion below covers the escaping as well as the
# separator.
TWO_BUSY_PS="$(make_ps twobusy \
  '349.5   676 /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic' \
  '142.0   767 corespotlightd' \
  '111.0   768 odd"name\\with-marks' \
  ' 99.4  1393 cloud-drive-daemon' \
  '  0.4   901 /Applications/Overture.app/Contents/MacOS/Overture')"
OUT13B="${WORK}/out13b"
RESULT="$(OVERTURE_MEASURE_PS="${TWO_BUSY_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT13B}" --label A)"
RECORD13B="$(find "${OUT13B}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
COUNT13B="$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1])).get("elevated_processes", [])))
except Exception:
    print("unreadable")' "${RECORD13B}" 2>&1)"
assert_equals "a record naming three busy processes parses and holds all three" "3" "${COUNT13B}"

# And the BASELINE case keeps its own assertion, or a writer emitting nothing at all satisfies the above.
OUT13C="${WORK}/out13c"
RESULT="$(OVERTURE_MEASURE_PS="${BASELINE_PS}" OVERTURE_MEASURE_PGREP="${ONE_APP}" \
  run_measure "${OUT13C}" --label A)"
RECORD13C="$(find "${OUT13C}" -name 'freeze-measure-*.json' 2>/dev/null | head -1)"
if parses_as_json "${RECORD13C}"; then
  pass "a BASELINE record parses as JSON too"
else
  fail "a BASELINE record parses as JSON too" "it did not parse"
fi

if [ "${FAILURES}" -eq 0 ]; then
  echo "All freeze-measure.sh fixtures passed."
else
  echo "${FAILURES} freeze-measure.sh assertion(s) failed."
  exit 1
fi
