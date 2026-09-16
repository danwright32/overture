#!/usr/bin/env bash
# #3503: every decision `scripts/scroll-wheel.sh` makes, driven without a running app and without posting
# one real event into whatever Dan has on screen.
#
# The seams are the point. A fixture that needed the app running would be a fixture nobody could run, and
# one that posted real events would be a test that drives the machine, which this repository's rules
# forbid outright (L2). `OVERTURE_SCROLL_PGREP` stands in for the process lookup and
# `OVERTURE_SCROLL_POSTER` for the poster, so the refusals, the targeting and the pass-through are all
# exercised for real while nothing leaves this shell.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "${DIR}/lib/shell-assertions.sh"
source "${DIR}/lib/scratch.sh"

WORK="$(overture_scratch_dir scroll-wheel-test)"
trap 'rm -rf "${WORK}"' EXIT

# A stand-in for pgrep. It answers from a file per query, so a test can say "the release build is running
# and the debug one is not" without any process existing.
make_pgrep() {
  local release="$1" debug="$2"
  cat > "${WORK}/pgrep" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *Applications/Overture.app*) printf '%s' '${release}' ;;
  *Build/Products/Debug*)      printf '%s' '${debug}' ;;
  *) : ;;
esac
EOF
  chmod +x "${WORK}/pgrep"
}

# A stand-in for the poster, which records what it was handed and answers with whatever this test wants.
make_poster() {
  local exit_code="$1" line="$2"
  cat > "${WORK}/poster" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${WORK}/poster-args"
echo '${line}'
exit ${exit_code}
EOF
  chmod +x "${WORK}/poster"
}

run() {
  OVERTURE_SCROLL_PGREP="${WORK}/pgrep" OVERTURE_SCROLL_POSTER="${WORK}/poster" \
    "${DIR}/scroll-wheel.sh" "$@" 2>&1
}

# --- the refusals, which are most of the value ---------------------------------------------------------

make_pgrep "" ""
make_poster 0 "LANDED"
OUT="$(run --yes)"; RC=$?
assert_contains "no app running says UNMEASURED" "${OUT}" "UNMEASURED: no release Overture is running"
assert_eq "no app running exits 2" "${RC}" "2"

# TWO copies of one build is the case this repository has already paid for: a lookup that resolves to the
# wrong Overture quit Dan's live app once. It refuses rather than picking one (L70).
make_pgrep "111
222" ""
OUT="$(run --yes)"; RC=$?
assert_contains "two copies of one build refuses" "${OUT}" "running more than once"
assert_contains "and names both pids" "${OUT}" "111 222"
assert_eq "two copies exits 2" "${RC}" "2"

# WITHOUT --yes it posts nothing, and says so in those words, because this drives the machine.
make_pgrep "555" ""
OUT="$(run)"; RC=$?
assert_contains "without --yes it refuses" "${OUT}" "DRIVES YOUR MACHINE"
assert_contains "and says nothing was posted" "${OUT}" "Nothing has been posted"
assert_eq "without --yes exits 2" "${RC}" "2"
assert_equals "and the poster was never reached" "$(cat "${WORK}/poster-args" 2>/dev/null || echo none)" "none"

# --- the targeting ------------------------------------------------------------------------------------

# The other build being up is a NOTE and not a refusal, and it names which one this scroll goes to. A
# scroll aimed at one build and observed on the other is exactly the mistake the targeting exists to
# prevent, and only the reader can see both.
make_pgrep "555" "666"
make_poster 0 "LANDED: scroll position moved 0.1000 to 0.3000 over 12 turns"
OUT="$(run --yes)"; RC=$?
assert_contains "the other build being up is reported" "${OUT}" "the other build is also running (pid 666"
assert_contains "and the target is named" "${OUT}" "goes to the release one, pid 555"
assert_contains "the landing is reported" "${OUT}" "LANDED"
assert_eq "a landed scroll exits 0" "${RC}" "0"
assert_contains "the poster was given the release pid" "$(cat "${WORK}/poster-args")" "--pid 555"

# --debug asks the OTHER query, so a Debug measurement cannot silently land on the Release app.
OUT="$(run --yes --debug)"; RC=$?
assert_contains "--debug targets the debug build" "$(cat "${WORK}/poster-args")" "--pid 666"
assert_eq "--debug with both running exits 0" "${RC}" "0"

# --- the three outcomes pass through, and stay three ----------------------------------------------------

make_pgrep "555" ""
make_poster 1 "DID NOT MOVE: the scroll position is still 0.9000 after 12 turns."
OUT="$(run --yes)"; RC=$?
assert_contains "a scroll that did not move says so" "${OUT}" "DID NOT MOVE"
assert_eq "and exits 1, not 0 and not 2" "${RC}" "1"

# UNMEASURED is its own outcome and must never be folded into either of the others: a scroll that did
# nothing and a tree that could not be read call for opposite next steps (L98, L11).
make_poster 2 "UNMEASURED: could not read a vertical scroll bar in that window tree."
OUT="$(run --yes)"; RC=$?
assert_contains "an unreadable tree says UNMEASURED" "${OUT}" "UNMEASURED"
assert_eq "and exits 2" "${RC}" "2"

# --- the arguments reach the poster ---------------------------------------------------------------------

make_poster 0 "SENT: 4 turns of -20px posted to pid 555, landing NOT checked"
OUT="$(run --yes --turns 4 --delta -20 --no-confirm)"
ARGS="$(cat "${WORK}/poster-args")"
assert_contains "the turn count is passed through" "${ARGS}" "--turns 4"
assert_contains "the delta is passed through" "${ARGS}" "--delta -20"
assert_contains "--no-confirm is passed through" "${ARGS}" "--no-confirm"
assert_contains "an unconfirmed post says SENT, not LANDED" "${OUT}" "SENT"

# --- the helper it drives, exercised for real -----------------------------------------------------------
#
# Everything above stubs the poster out, and the one thing a stubbed seam cannot tell you is whether the
# real thing works (L52). The poster's own argument parsing is the whole of it that can be exercised
# without a window on screen and without posting a real event into whatever is in front of Dan, so it
# carries a `--self-test` that asserts it, and this runs it.
#
# It replaces a bare `swiftc -parse`, which proved only that the file still compiled: a parse is not a
# test, and the same second of compiling now buys actual assertions (L1).
if command -v swift >/dev/null 2>&1; then
  # TMPDIR pointed INSIDE this fixture's own scratch, because the compiler makes a TemporaryDirectory of
  # its own and the runner's leak check is right to report one left behind (#3249, #3065).
  if TMPDIR="${WORK}" swift "${DIR}/../mac/scripts/lib/post-scroll-wheel.swift" --self-test \
       >"${WORK}/self-test.log" 2>&1; then
    assert_contains "the Swift poster's own self test passes" \
      "$(cat "${WORK}/self-test.log")" "All post-scroll-wheel.swift self-test assertions passed."
    # Not a bare exit code: a run that printed nothing and exited 0 is what a self test looks like when
    # every one of its assertions has been deleted (L98).
    assert_contains "and it really asserted something" "$(cat "${WORK}/self-test.log")" "ok - a bare --pid parses"
  else
    fail "the Swift poster's self test failed or would not build: $(head -5 "${WORK}/self-test.log")"
  fi
else
  # Not silently skipped. A machine with no Swift cannot check this, and that is a different state from
  # having checked it (L98).
  echo "note - swift is not on this machine, so the poster's own self test was NOT run"
fi

if [ "${FAILURES:-0}" -ne 0 ]; then
  echo "${FAILURES} scroll-wheel.sh assertion(s) failed."
  exit 1
fi
echo "All scroll-wheel.sh fixtures passed."
