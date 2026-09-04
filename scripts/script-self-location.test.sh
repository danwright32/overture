#!/usr/bin/env bash
set -uo pipefail

# #3481: a script that changes its own working directory must capture its OWN location BEFORE the cd.
#
# `$0` (and `BASH_SOURCE[0]` for a top level script) is the path the script was INVOKED by, which is
# usually relative. Re-deriving a directory from it after a `cd` resolves against the new working
# directory, so the same expression works for one invocation and silently misses for another (L372).
#
# Hit for real on 2026-09-02. `mac/build-install.sh` cds into `mac/` on line 10 and sourced
# `"$(dirname "$0")/scripts/lib/build-provenance.sh"` on line 131. Invoked the way AGENTS.md documents,
# `mac/build-install.sh` from the repo root, that resolved to `mac/mac/scripts/lib/...` and missed. The
# install SUCCEEDED and only the provenance record was skipped, so the app ran fine and a later readout
# was wrong, which is the worst shape for this.
#
# It was not one instance. Four sibling scripts had it too, each capturing `SCRIPT_DIR` from
# `BASH_SOURCE[0]` one line AFTER cding to the repo root, which happens to resolve when they are run
# from the repo root and does not when they are run from inside `scripts/`. Measured 2026-09-04:
# `cd scripts && ./check-fixture-corpus-drift.sh` reported
# `/…/lib/scratch.sh: No such file or directory` and then `UNMEASURED`.
#
# So the guard is over the CLASS rather than the one file (L30), and it is derived from the tree rather
# than a list somebody remembers to update (L96).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"
FAILURES=0

cd "${REPO_ROOT}" || exit 1

# This file has to NAME the forbidden spellings in order to search for them, so it would match itself
# (L245). Exempt by name, and only this one.
SELF="scripts/script-self-location.test.sh"

offenders=""
scanned=0
for f in $(git ls-files '*.sh'); do
  [ "${f}" = "${SELF}" ] && continue
  scanned=$((scanned + 1))
  cd_line=$(grep -n '^[[:space:]]*cd ' "${f}" | head -1 | cut -d: -f1)
  [ -z "${cd_line}" ] && continue
  later=$(grep -n 'dirname "\$0"\|dirname \$0\|dirname "\${BASH_SOURCE\[0\]}"' "${f}" \
    | awk -F: -v c="${cd_line}" '$1 > c { print $1 }' | tr '\n' ' ')
  [ -n "${later}" ] && offenders="${offenders}${f} (cd on line ${cd_line}, re-derived on ${later})
"
done

assert_equals "every script that cds captures its own location first" "" "${offenders}"

# UNMEASURED is its own outcome: a scan that read no scripts and a tree with no offenders leave the
# same empty result, and the emptiest possible failure must not read as the cleanest pass (L98).
if [ "${scanned}" -lt 20 ]; then
  fail "the scan read only ${scanned} scripts, so it measured nothing"
else
  pass "scanned ${scanned} scripts"
fi

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all script-self-location checks passed"
