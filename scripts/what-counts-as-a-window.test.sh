#!/usr/bin/env bash
set -uo pipefail

# #3788: the JUDGING half of scripts/what-counts-as-a-window.sh, driven against built readings rather than
# against real AppKit, so every outcome can be PRODUCED rather than waited for.
#
# The outcome that matters most is UNMEASURED. A probe that will not build and a probe that built and found
# AppKit changed both leave this script with nothing reassuring to say, and folding them together would
# make the emptiest possible failure read as the cleanest possible answer (L98, L11). The real script is
# the one case this cannot drive, because it needs a GUI session; it is run by hand and its reading is
# quoted in WindowCensus.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shell-assertions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="${SCRIPT_DIR}/what-counts-as-a-window.sh"
FAILURES=0

WORK="$(fixture_scratch_dir)"
MAIN_SHELL_PID="${BASHPID:-$$}"
trap '[ "${BASHPID:-$$}" = "${MAIN_SHELL_PID}" ] && rm -rf "${WORK}"' EXIT

# The reader, lifted out of the real script by taking the text between its own markers, so this fixture
# cannot drift from what ships. Derived rather than copied: a second copy of the rule would agree with
# itself for ever while the shipped one changed (L41).
sed -n "/^python3 - /,\$p" "${REAL}" | sed '1d;$d' > "${WORK}/reader.py"
# UNMEASURED is its own outcome here too. A lift that matched nothing leaves an empty file, every case
# below then reports the same Python error, and a fixture asserting only on exit codes would read that as
# the script refusing correctly (L98, L100).
assert_contains "the reader really was lifted out of the real script" \
  "$(cat "${WORK}/reader.py")" "canBecomeMain"

judge() { python3 "${WORK}/reader.py" "$1" 2>&1; }

win() { printf '  %s window visible=%s canBecomeMain=%s titled=%s\n' "$1" "$2" "$3" "$4"; }

# 1. What real AppKit does today: the status item is not a content window, an ordinary window is.
{
  echo "before count=0"
  echo "menubar count=1"; win menubar true false false
  echo "content count=2"; win content true false false; win content true true true
} > "${WORK}/good.txt"
out="$(judge "${WORK}/good.txt")"; status=$?
assert_equals "today's AppKit is the measured case" "0" "${status}"
assert_contains "and it says the predicate is still filtering on something true" "${out}" "still true"

# 2. The status item starts satisfying the predicate. This is the defect the whole issue is about coming
#    back, and it must be its own outcome rather than a pass.
{
  echo "before count=0"
  echo "menubar count=1"; win menubar true true true
  echo "content count=2"; win content true true true; win content true true true
} > "${WORK}/item-counts.txt"
out="$(judge "${WORK}/item-counts.txt")"; status=$?
assert_equals "a menu bar item that satisfies the predicate is a finding, not a pass" "1" "${status}"
assert_contains "and it names the consequence rather than only the fact" "${out}" "never report"

# 3. The OTHER direction, which a check on the status item alone would pass: an ordinary window stops
#    satisfying the predicate, so the census would report nobody looking while Dan is reading the queue.
#    That is worse than the defect it replaced, and it has to be caught by the same run (L159, L178).
{
  echo "before count=0"
  echo "menubar count=1"; win menubar true false false
  echo "content count=2"; win content true false false; win content true false true
} > "${WORK}/content-lost.txt"
out="$(judge "${WORK}/content-lost.txt")"; status=$?
assert_equals "an ordinary window that stops counting is a finding" "1" "${status}"
assert_contains "and it says which way round it is wrong" "${out}" "worse than the defect"

# 4. A reading this reader does not understand is UNMEASURED, never a verdict.
printf 'the probe fell over\n' > "${WORK}/garbage.txt"
out="$(judge "${WORK}/garbage.txt")"; status=$?
assert_equals "an unreadable reading is UNMEASURED rather than either verdict" "2" "${status}"
assert_contains "and it says so" "${out}" "UNMEASURED"

# 5. A status item that adds no window, or more than one, leaves nothing attributable. UNMEASURED rather
#    than a verdict, because which window is which is exactly what the reading could no longer say.
{
  echo "before count=0"
  echo "menubar count=0"
  echo "content count=1"; win content true true true
} > "${WORK}/no-item.txt"
out="$(judge "${WORK}/no-item.txt")"; status=$?
assert_equals "a status item that added no window is UNMEASURED" "2" "${status}"

# 6. The real script refuses honestly when it cannot build. Driven by putting an xcrun on PATH that fails,
#    because a claim that something cannot be measured has to come from attempting it (L460).
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/xcrun" <<'SH'
#!/bin/sh
echo "error: no toolchain here" >&2
exit 70
SH
chmod +x "${WORK}/bin/xcrun"
out="$(PATH="${WORK}/bin:${PATH}" "${REAL}" 2>&1)"; status=$?
assert_equals "a probe that will not build is UNMEASURED, not a verdict" "2" "${status}"
assert_contains "and it names the reason rather than reporting no findings" "${out}" "did not build"

if [ "${FAILURES}" -eq 0 ]; then
  echo "what-counts-as-a-window.test.sh: all passed"
else
  echo "what-counts-as-a-window.test.sh: ${FAILURES} failure(s)"
  exit 1
fi
