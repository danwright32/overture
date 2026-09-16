#!/usr/bin/env bash
# Fixture for scripts/sample-overture.sh (#3424).
#
# Every collaborator that touches this Mac is a named seam and every one of them is set here, so nothing
# in this file resolves, samples or reads a real process (L2). The subject is a tool for use while the
# live app is frozen, and a fixture that reached the real machine would assert about whatever happened
# to be running when somebody ran it (L224).
#
# The sampler stub honours the REAL /usr/bin/sample interface:
#
#   sample <pid | partial-process-name> [duration [samplingInterval]] [options...] [-file <filename>]
#
# and REFUSES anything else, which is deliberate rather than defensive. scripts/freeze-measure.test.sh
# records what happens without that refusal: its first version invented a
# `sample <pid> <seconds> <outfile>` signature, production was built to match the invention, and the
# real tool would have read the third positional as a sampling interval in milliseconds and written
# nowhere near the path the record named, with every assertion green (L52).
set -uo pipefail
# #3481/L372: captured BEFORE the cd. `$0` and `BASH_SOURCE[0]` are the path the script was INVOKED
# by, so re-deriving a directory from either after a cd resolves against the NEW working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"

FAILURES=0
SCRIPT="$(pwd)/scripts/sample-overture.sh"

WORK="$(fixture_scratch_dir)"
trap 'rm -rf "${WORK}"' EXIT

# --- stubs ----------------------------------------------------------------------------------------
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

# A sampler that writes ${BODY_FILE}'s contents to whatever -file names, and records its own argv so a
# case can assert the real interface was used.
make_sampler() {
  local name="$1" body="$2" status="${3:-0}"
  local out="${WORK}/sample-${name}"
  cat > "${out}" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "${WORK}/sampler-argv-${name}.txt"
pid="\$1"; shift
seconds="\$1"
file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -file) file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "\${file}" ]; then
  echo "stub: no -file given; the real sample writes to its own default path" >&2
  exit 64
fi
printf '%s\n' "\${pid} \${seconds}" > "${WORK}/sampler-positional-${name}.txt"
cat "${body}" > "\${file}"
exit ${status}
STUB
  chmod +x "${out}"
  printf '%s' "${out}"
}

# A realistic sample: a call graph whose Overture frames sit among frames from system libraries.
FROZEN_BODY="${WORK}/frozen-sample.txt"
cat > "${FROZEN_BODY}" <<'BODY'
Analysis of sampling Overture (pid 4242) every 1 millisecond
Process:         Overture [4242]
Path:            /Applications/Overture.app/Contents/MacOS/Overture

Call graph:
    2646 Thread_998877   DispatchQueue_1: com.apple.main-thread  (serial)
      2646 start_wqthread  (in libsystem_pthread.dylib) + 15
        2646 -[NSApplication run]  (in AppKit) + 464
          2646 OvertureApp.syncOmniFocus()  (in Overture) + 210
            2646 OmniFocusSyncRunner.run()  (in Overture) + 88
              2646 -[NSAppleScript executeAndReturnError:]  (in Foundation) + 132
                2646 mach_msg2_trap  (in libsystem_kernel.dylib) + 8

Binary Images:
       0x102a00000 -        0x103bfffff +Overture (1.0)
BODY

# A sample of an app that was not doing anything of its own: no Overture frame anywhere.
IDLE_BODY="${WORK}/idle-sample.txt"
cat > "${IDLE_BODY}" <<'BODY'
Analysis of sampling Overture (pid 4242) every 1 millisecond

Call graph:
    2646 Thread_998877   DispatchQueue_1: com.apple.main-thread  (serial)
      2646 start_wqthread  (in libsystem_pthread.dylib) + 15
        2646 __CFRunLoopServiceMachPort  (in CoreFoundation) + 319
BODY

EMPTY_BODY="${WORK}/empty-sample.txt"
: > "${EMPTY_BODY}"

run_script() {
  OVERTURE_SAMPLE_PGREP="$1" \
  OVERTURE_SAMPLE_CMD="$2" \
  OVERTURE_SAMPLE_OUT="$3" \
  "${SCRIPT}" "${@:4}" 2>&1
}

# --- 1. the ordinary case: one running copy, frames printed, full file kept -------------------------
OUT_ONE="${WORK}/out-one"
PGREP_ONE="$(make_pgrep one 4242)"
SAMPLER_ONE="$(make_sampler one "${FROZEN_BODY}")"
RESULT="$(run_script "${PGREP_ONE}" "${SAMPLER_ONE}" "${OUT_ONE}" --seconds 3)"
STATUS=$?
assert_equals "a sample naming Overture frames exits 0" "0" "${STATUS}"
assert_contains "it prints the app's own frame" "${RESULT}" "OmniFocusSyncRunner.run()"
assert_contains "and the frame above it" "${RESULT}" "OvertureApp.syncOmniFocus()"
assert_not_contains "it does not print frames from outside the app" "${RESULT}" "mach_msg2_trap"
assert_contains "it names where the full sample was saved" "${RESULT}" "${OUT_ONE}"

SAVED="$(ls "${OUT_ONE}" 2>/dev/null | head -1)"
if [[ -n "${SAVED}" ]]; then
  pass "the full sample is written under the diagnostics directory"
  assert_contains "and it is the WHOLE sample, not the filtered frames" \
    "$(cat "${OUT_ONE}/${SAVED}")" "mach_msg2_trap"
else
  fail "the full sample is written under the diagnostics directory" "no file under ${OUT_ONE}"
fi

# The real interface, not an invented one: the pid and duration are positional and the path arrives
# through -file. A stub that accepted a third positional would let production write nowhere (L52).
assert_contains "the sampler is given -file, never a third positional path" \
  "$(cat "${WORK}/sampler-argv-one.txt" 2>/dev/null)" "-file"
assert_equals "the pid and the duration are the positional arguments" \
  "4242 3" "$(cat "${WORK}/sampler-positional-one.txt" 2>/dev/null | tr -d '\n')"

# --- 2. nothing running is UNMEASURED, and says which refusal it is ---------------------------------
PGREP_NONE="$(make_pgrep none)"
RESULT="$(run_script "${PGREP_NONE}" "${SAMPLER_ONE}" "${WORK}/out-none")"
STATUS=$?
assert_equals "no running copy is UNMEASURED" "2" "${STATUS}"
assert_contains "it says UNMEASURED" "${RESULT}" "UNMEASURED"
assert_contains "in its own words" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "not running"
assert_not_contains "and is not reported as the two-copies refusal" \
  "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "two copies"

# --- 3. two copies REFUSE rather than picking one --------------------------------------------------
# CLAUDE.md's rule, minted from a Cmd+W that quit Dan's live app: two builds of Overture can run at
# once, both are called Overture, and a lookup that quietly picks one is worse than no answer (L521).
PGREP_TWO="$(make_pgrep two 4242 5353)"
RESULT="$(run_script "${PGREP_TWO}" "${SAMPLER_ONE}" "${WORK}/out-two")"
STATUS=$?
assert_equals "two running copies are UNMEASURED" "2" "${STATUS}"
assert_contains "it says two copies" "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "two copies"
assert_contains "and names the first pid" "${RESULT}" "4242"
assert_contains "and names the second, so neither is silently chosen" "${RESULT}" "5353"

# --- 4. a sampler that failed measured nothing -----------------------------------------------------
SAMPLER_FAILS="$(make_sampler fails "${FROZEN_BODY}" 3)"
RESULT="$(run_script "${PGREP_ONE}" "${SAMPLER_FAILS}" "${WORK}/out-failed")"
STATUS=$?
assert_equals "a failed sample is UNMEASURED, never a quiet reading" "2" "${STATUS}"
assert_contains "and says so" "${RESULT}" "UNMEASURED"

# --- 5. a sample carrying no Overture frame is its own outcome -------------------------------------
# The trap this closes: an app sitting in the run loop and a sample whose symbols could not be read
# both produce zero matching lines, and neither is the tool working (L98, L11). It is not folded into
# the success above, and it is not folded into UNMEASURED either, because the sample itself is real
# and is worth keeping.
OUT_IDLE="${WORK}/out-idle"
SAMPLER_IDLE="$(make_sampler idle "${IDLE_BODY}")"
RESULT="$(run_script "${PGREP_ONE}" "${SAMPLER_IDLE}" "${OUT_IDLE}")"
STATUS=$?
assert_equals "a sample naming no Overture frame does not read as a clean pass" "1" "${STATUS}"
assert_contains "it says the sample names none of the app's own frames" \
  "$(printf '%s' "${RESULT}" | tr 'A-Z' 'a-z')" "no frames of overture's own"
if [[ -n "$(ls "${OUT_IDLE}" 2>/dev/null)" ]]; then
  pass "the sample is kept even though it named no frames"
else
  fail "the sample is kept even though it named no frames" "nothing under ${OUT_IDLE}"
fi

# --- 6. an empty sample file measured nothing ------------------------------------------------------
SAMPLER_EMPTY="$(make_sampler empty "${EMPTY_BODY}")"
RESULT="$(run_script "${PGREP_ONE}" "${SAMPLER_EMPTY}" "${WORK}/out-empty")"
STATUS=$?
assert_equals "a sampler that wrote nothing is UNMEASURED" "2" "${STATUS}"
assert_contains "and says so rather than reporting no frames" "${RESULT}" "UNMEASURED"

# --- 7. an unknown argument refuses rather than being ignored --------------------------------------
# A silently ignored argument is indistinguishable from an honoured one (#3245).
RESULT="$(run_script "${PGREP_ONE}" "${SAMPLER_ONE}" "${WORK}/out-arg" --nonsense)"
STATUS=$?
assert_equals "an unknown argument is UNMEASURED" "2" "${STATUS}"
assert_contains "and names the argument it refused" "${RESULT}" "--nonsense"

# --- 8. the pid resolution is the SHARED one, not a second copy ------------------------------------
# Two readings of one mechanism eventually disagree, and the one that disagrees quietly is the one
# holding a guard open (L263). The rule this shares with freeze-measure.sh is the one CLAUDE.md was
# amended for, so it lives in scripts/lib/overture-pid.sh and both source it.
assert_contains "sample-overture.sh resolves its pid through the shared library" \
  "$(cat scripts/sample-overture.sh)" "lib/overture-pid.sh"
assert_contains "and so does freeze-measure.sh, so the two cannot drift" \
  "$(cat scripts/freeze-measure.sh)" "lib/overture-pid.sh"
assert_equals "neither script keeps its own pgrep against the executable path" \
  "0" "$(grep -c 'pgrep -f' scripts/sample-overture.sh scripts/freeze-measure.sh | awk -F: '{ s += $2 } END { print s + 0 }')"

if [[ "${FAILURES}" -eq 0 ]]; then
  echo "All sample-overture.sh fixtures passed."
else
  echo "${FAILURES} sample-overture.sh fixture(s) failed."
  exit 1
fi
