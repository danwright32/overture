#!/usr/bin/env bash
set -uo pipefail

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

TMP="$(mktemp -d)"
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

# 1. Dan's case: parked on a feature branch, newer work shipped. It moves to the shipped commit and
#    THEN installs, so what gets built is what he was told he was missing.
clone="$(make_pair parked)"
git -C "${clone}" checkout --quiet -b some-feature
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

if [ "${FAILURES}" -gt 0 ]; then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all checks passed"
