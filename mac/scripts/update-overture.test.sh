#!/usr/bin/env bash
set -uo pipefail

# The shared assertion vocabulary: pass, fail, assert_contains, assert_not_contains,
# assert_equals, assert_eq, assert_empty (#2501). A definition later in this file replaces
# the shared one, so nothing below changes meaning by sourcing this.
# shellcheck source=../../scripts/lib/shell-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shell-assertions.sh"

# What the panel's Update button actually runs (2026-08-04).
#
# Pressing Update means "get me the code that has shipped", which is a different job from running the
# installer by hand, which means "build what is here". This is the first half of that difference: bring
# the checkout up to what has shipped, and only then hand over to the installer.
#
# The claim that matters most is the negative one. When the checkout cannot be brought up safely, the
# install must NOT run. Building anyway is exactly the loop Dan hit: the installer rebuilt a commit that
# was already behind, recorded it as installed, and the panel correctly said "behind" again forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "  $2"
  FAILURES=$((FAILURES + 1))
}

TMP="$(fixture_scratch_dir)"
trap 'rm -rf "${TMP}"' EXIT

# Records that the install ran, so a test can prove it did NOT on the refusing paths.
INSTALL_LOG="${TMP}/installed.log"
INSTALLER="${TMP}/fake-install.sh"
cat >"${INSTALLER}" <<EOF
#!/usr/bin/env bash
printf 'installed %s\n' "\$*" >> "${INSTALL_LOG}"
EOF
chmod +x "${INSTALLER}"

make_pair() {
  local name="$1"
  local remote="${TMP}/${name}-remote" clone="${TMP}/${name}"
  rm -rf "${remote}" "${clone}"
  git init --quiet --bare -b main "${remote}"
  git clone --quiet "${remote}" "${clone}" 2>/dev/null
  git -C "${clone}" config user.email t@example.com
  git -C "${clone}" config user.name Test
  mkdir -p "${clone}/mac/scripts"
  echo one > "${clone}/file.txt"
  git -C "${clone}" add -A
  git -C "${clone}" commit --quiet -m first
  git -C "${clone}" push --quiet -u origin main 2>/dev/null
  echo "${clone}"
}

ship_another() {
  local clone="$1" work="${TMP}/shipper-$$"
  rm -rf "${work}"
  git clone --quiet "$(git -C "${clone}" remote get-url origin)" "${work}" 2>/dev/null
  git -C "${work}" config user.email t@example.com
  git -C "${work}" config user.name Test
  echo two > "${work}/file.txt"
  git -C "${work}" add -A
  git -C "${work}" commit --quiet -m second
  git -C "${work}" push --quiet origin main 2>/dev/null
  rm -rf "${work}"
}

# 1. The ordinary case: on main, behind what shipped. It brings the code up and THEN installs, so what
#    gets built is what Dan was told he was missing.
#
#    This used to be Dan's parked-on-a-branch case. Since #2923 that one refuses instead (case 1a
#    below): moving a working checkout off a branch redirected a live session's suite run, its next
#    commit and its next push, none of it visible until days later.
clone="$(make_pair behind)"
ship_another "${clone}"
: > "${INSTALL_LOG}"
out="$(OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${INSTALLER}" \
       "${SCRIPT_DIR}/update-overture.sh" 2>&1)"
status=$?
head="$(git -C "${clone}" rev-parse HEAD)"
remote_head="$(git -C "${clone}" rev-parse origin/main)"
if [ "${status}" -eq 0 ] && [ "${head}" = "${remote_head}" ] && [ -s "${INSTALL_LOG}" ]; then
  pass "it brings the checkout up to what shipped and then installs"
else
  fail "it brings the checkout up to what shipped and then installs" \
    "status=${status} installed=$(cat "${INSTALL_LOG}") out=${out}"
fi

# 2. It hands the installer the flag that surfaces the app again afterwards, or the update ends with
#    Overture never coming back and nothing saying why.
case "$(cat "${INSTALL_LOG}")" in
  *--launch*) pass "and asks the installer to bring Overture back" ;;
  *) fail "and asks the installer to bring Overture back" "got: $(cat "${INSTALL_LOG}")" ;;
esac

# 1a. #2923: a clean checkout standing on a feature branch. Nothing moves, nothing installs, and the
#     branch it left alone is named. Committed and clean is not evidence that nobody is working here:
#     the incident's branch had been committed one command earlier.
clone="$(make_pair parked)"
git -C "${clone}" checkout --quiet -b some-feature
ship_another "${clone}"
before="$(git -C "${clone}" rev-parse HEAD)"
: > "${INSTALL_LOG}"
out="$(OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${INSTALLER}" \
       "${SCRIPT_DIR}/update-overture.sh" 2>&1)"
status=$?
branch="$(git -C "${clone}" rev-parse --abbrev-ref HEAD)"
head="$(git -C "${clone}" rev-parse HEAD)"
if [ "${status}" -ne 0 ] && [ "${branch}" = "some-feature" ] && [ "${head}" = "${before}" ] \
   && [ ! -s "${INSTALL_LOG}" ]; then
  pass "a checkout standing on a feature branch is neither moved nor built"
else
  fail "a checkout standing on a feature branch is neither moved nor built" \
    "status=${status} branch=${branch} installed=$(cat "${INSTALL_LOG}") out=${out}"
fi
case "${out}" in
  *some-feature*) pass "and the run names the branch it refused to move off" ;;
  *) fail "and the run names the branch it refused to move off" "got: ${out}" ;;
esac

# 3. THE ONE THAT MATTERS: work in progress means no install at all. Building anyway is the loop.
clone="$(make_pair busy)"
git -C "${clone}" checkout --quiet -b in-flight
echo "half a change" >> "${clone}/file.txt"
ship_another "${clone}"
: > "${INSTALL_LOG}"
out="$(OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${INSTALLER}" \
       "${SCRIPT_DIR}/update-overture.sh" 2>&1)"
status=$?
if [ "${status}" -ne 0 ] && [ ! -s "${INSTALL_LOG}" ]; then
  pass "a checkout it cannot bring up to date is never built and never installed"
else
  fail "a checkout it cannot bring up to date is never built and never installed" \
    "status=${status} installed=$(cat "${INSTALL_LOG}")"
fi
case "${out}" in
  *"did not update"*) pass "and says plainly that it did not update" ;;
  *) fail "and says plainly that it did not update" "got: ${out}" ;;
esac

# 4. Already current still installs: pressing Update on a copy that is merely a rebuild behind must
#    still give Dan a fresh app, not a silent no-op that looks like nothing happened.
clone="$(make_pair current)"
: > "${INSTALL_LOG}"
out="$(OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${INSTALLER}" \
       "${SCRIPT_DIR}/update-overture.sh" 2>&1)"
status=$?
if [ "${status}" -eq 0 ] && [ -s "${INSTALL_LOG}" ]; then
  pass "a checkout already on the shipped commit still installs"
else
  fail "a checkout already on the shipped commit still installs" "status=${status} out=${out}"
fi

# #2188: the run has to report its outcome back to the app, or a refusal is indistinguishable from an
# update that happened. Dan pressed Update on 2026-08-06, the run refused because another session had
# work in progress, and Overture never found out: it had already dismissed its own panel on the press,
# so the app went quiet for the rest of the launch about a copy that was still out of date.
#
# The record is written into a directory the test owns. It must never be Dan's Application Support
# folder (L2), which is why the path is injectable at all.
DATA_DIR="${TMP}/data"
RESULT="${DATA_DIR}/update-result.json"

# 5. A refusal leaves a record naming the press it belongs to and the reason, in the same words the
#    Terminal window prints, because two copies of that sentence would drift.
clone="$(make_pair reporting)"
git -C "${clone}" checkout --quiet -b in-flight
echo "half a change" >> "${clone}/file.txt"
ship_another "${clone}"
rm -rf "${DATA_DIR}"; : > "${INSTALL_LOG}"
OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${INSTALLER}" \
  OVERTURE_DATA_DIR="${DATA_DIR}" OVERTURE_UPDATE_PRESS="press-abc" \
  "${SCRIPT_DIR}/update-overture.sh" >/dev/null 2>&1
if [ -f "${RESULT}" ]; then
  pass "a refused update writes a record of what happened"
else
  fail "a refused update writes a record of what happened" "no file at ${RESULT}"
fi
case "$(cat "${RESULT}" 2>/dev/null)" in
  *'"press":"press-abc"'*) pass "and names the press it belongs to" ;;
  *) fail "and names the press it belongs to" "got: $(cat "${RESULT}" 2>/dev/null)" ;;
esac
case "$(cat "${RESULT}" 2>/dev/null)" in
  *'"outcome":"failed"'*) pass "and says it failed rather than leaving the running state behind" ;;
  *) fail "and says it failed rather than leaving the running state behind" "got: $(cat "${RESULT}" 2>/dev/null)" ;;
esac
case "$(cat "${RESULT}" 2>/dev/null)" in
  *"unsaved work in progress"*) pass "and carries the reason the Terminal window printed" ;;
  *) fail "and carries the reason the Terminal window printed" "got: $(cat "${RESULT}" 2>/dev/null)" ;;
esac

# 6. And it is written BEFORE the outcome is known, so a run that dies where nothing can catch it (the
#    machine sleeps, Terminal is closed mid build) is still distinguishable from one that never started.
#    Proved from inside the install step, which is the one moment the answer is still "running".
RUNNING_PROBE="${TMP}/running-probe.log"
PROBE_INSTALLER="${TMP}/probe-install.sh"
cat >"${PROBE_INSTALLER}" <<EOF
#!/usr/bin/env bash
cat "${RESULT}" > "${RUNNING_PROBE}" 2>/dev/null
printf 'installed %s\n' "\$*" >> "${INSTALL_LOG}"
EOF
chmod +x "${PROBE_INSTALLER}"
clone="$(make_pair running)"
rm -rf "${DATA_DIR}"; : > "${INSTALL_LOG}"; : > "${RUNNING_PROBE}"
OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${PROBE_INSTALLER}" \
  OVERTURE_DATA_DIR="${DATA_DIR}" OVERTURE_UPDATE_PRESS="press-run" \
  "${SCRIPT_DIR}/update-overture.sh" >/dev/null 2>&1
case "$(cat "${RUNNING_PROBE}" 2>/dev/null)" in
  *'"outcome":"running"'*) pass "a run in progress says so while it is still going" ;;
  *) fail "a run in progress says so while it is still going" "got: $(cat "${RUNNING_PROBE}" 2>/dev/null)" ;;
esac

# 7. A finished install leaves nothing behind, so the next press can never read the last one's outcome.
if [ ! -f "${RESULT}" ]; then
  pass "a successful update clears its record"
else
  fail "a successful update clears its record" "still there: $(cat "${RESULT}")"
fi

# 8. The install failing is its own failure, not a success. Without this the record says "running"
#    forever and the app waits on a run that is already dead.
FAILING_INSTALLER="${TMP}/failing-install.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "${FAILING_INSTALLER}"
chmod +x "${FAILING_INSTALLER}"
clone="$(make_pair buildfail)"
rm -rf "${DATA_DIR}"
OVERTURE_REPO_ROOT="${clone}" OVERTURE_INSTALL_CMD="${FAILING_INSTALLER}" \
  OVERTURE_DATA_DIR="${DATA_DIR}" OVERTURE_UPDATE_PRESS="press-boom" \
  "${SCRIPT_DIR}/update-overture.sh" >/dev/null 2>&1
status=$?
case "$(cat "${RESULT}" 2>/dev/null)" in
  *'"outcome":"failed"'*) pass "an install that fails is recorded as a failure" ;;
  *) fail "an install that fails is recorded as a failure" "status=${status} got: $(cat "${RESULT}" 2>/dev/null)" ;;
esac

# 9. The committed fixtures still match what the writer produces. The app decodes those same two files
#    (UpdateAttemptTests), so this is the join: a key renamed here without regenerating them breaks this
#    check rather than silently leaving the app reading every real record as absent. The `at` field is
#    excluded because it is different on every run by design.
FIXTURES="${SCRIPT_DIR}/../../fixtures/update-result"
strip_at() { sed -e 's/,"at":"[^"]*"//' "$1"; }
rm -rf "${DATA_DIR}"
( set +u
  # shellcheck source=lib/update-result.sh
  . "${SCRIPT_DIR}/lib/update-result.sh"
  OVERTURE_DATA_DIR="${DATA_DIR}" OVERTURE_UPDATE_PRESS="press-fixture" \
    overture_update_write_result failed "There is unsaved work in progress in the code folder, and updating would disturb it. Ask Claude to finish or put aside that work, then press Update again." )
if [ "$(strip_at "${RESULT}")" = "$(strip_at "${FIXTURES}/refused.json")" ]; then
  pass "the refused fixture the app decodes is what the writer still writes"
else
  fail "the refused fixture the app decodes is what the writer still writes" \
    "wrote:     $(strip_at "${RESULT}")
 committed: $(strip_at "${FIXTURES}/refused.json")"
fi

rm -rf "${DATA_DIR}"
( set +u
  # shellcheck source=lib/update-result.sh
  . "${SCRIPT_DIR}/lib/update-result.sh"
  OVERTURE_DATA_DIR="${DATA_DIR}" OVERTURE_UPDATE_PRESS="press-fixture" overture_update_record_running )
if [ "$(strip_at "${RESULT}")" = "$(strip_at "${FIXTURES}/running.json")" ]; then
  pass "the running fixture the app decodes is what the writer still writes"
else
  fail "the running fixture the app decodes is what the writer still writes" \
    "wrote:     $(strip_at "${RESULT}")
 committed: $(strip_at "${FIXTURES}/running.json")"
fi

# 10. #1711: an update run whose environment carries no HOME. update-overture.sh declares
#     `set -euo pipefail`, so the bare ${HOME} that used to sit inside overture_update_result_path
#     killed the whole update the first time the record was written, with the shell's own
#     "HOME: unbound variable" and nothing else. Recording the outcome is bookkeeping for the app; it
#     must never be what stops the update, and its absence must say so rather than pass as written.
out="$(env -u HOME -u OVERTURE_DATA_DIR bash -c '
  set -euo pipefail
  . "'"${SCRIPT_DIR}"'/lib/update-result.sh"
  overture_update_record_running
  echo survived' 2>&1)"
case "${out}" in
  *"unbound variable"*) fail "no HOME: the outcome record refuses in its own words, not the shell's" "got: ${out}" ;;
  *) pass "no HOME: the outcome record refuses in its own words, not the shell's" ;;
esac
case "${out}" in
  *"neither OVERTURE_DATA_DIR nor HOME is set"*) pass "no HOME: says why the outcome could not be recorded" ;;
  *) fail "no HOME: says why the outcome could not be recorded" "got: ${out}" ;;
esac
case "${out}" in
  *survived*) pass "no HOME: the update itself carries on rather than dying on its bookkeeping" ;;
  *) fail "no HOME: the update itself carries on rather than dying on its bookkeeping" "got: ${out}" ;;
esac

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all checks passed"
