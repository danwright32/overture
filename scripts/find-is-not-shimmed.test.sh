#!/usr/bin/env bash
set -uo pipefail

# #2860/#2959: `find` inside a Claude Code session is shadowed by a shell function running `bfs`, which
# refuses the relative timestamp form both BSD and GNU find accept (`-newermt "-60 minutes"` answers
# `Invalid timestamp`). The worry those issues record is that a script in this repo would therefore
# behave differently depending on who ran it, with no sign either way.
#
# MEASURED 2026-09-04, and the premise does not hold for scripts. The shim is a shell FUNCTION and is
# not exported, so it reaches commands typed into the session shell and does NOT reach a script run as
# a subprocess. In the same session, on the same machine:
#
#   inline in the session shell:   command -v find -> find (the function), relative timestamp REFUSED
#   from a #!/usr/bin/env bash script:  /usr/bin/find, relative timestamp ACCEPTED
#
# So no script needed changing, and a rule making every script spell `/usr/bin/find` would have been
# noise protecting against nothing. What is genuinely exposed is an ad-hoc `find` typed into a session
# (by an agent, or by Dan with the `!` prefix), which is not something a repo convention can reach.
#
# This fixture exists because that is a PREMISE about the environment, not a fact about this code, and a
# premise recorded as a dated sentence is one nobody re-measures (L316, L336). It re-measures it on every
# push. If the harness ever exports the shim, this goes red and names what changed, instead of a script
# quietly answering the keep direction for every input, which is how #2842's liveness probe would have
# silently stopped reclaiming anything while looking exactly like a working guard (L100).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/shell-assertions.sh
. "${SCRIPT_DIR}/lib/shell-assertions.sh"
FAILURES=0

probe_dir="$(fixture_scratch_dir)"
[ -n "${probe_dir}" ] || { echo "FAIL - could not make a scratch directory"; exit 1; }
trap 'rm -rf "${probe_dir}"' EXIT

cat > "${probe_dir}/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
echo "resolved=$(command -v find)"
if find . -maxdepth 0 -newermt "-60 minutes" >/dev/null 2>&1; then
  echo "relative=accepted"
else
  echo "relative=refused"
fi
PROBE
chmod +x "${probe_dir}/probe.sh"

real="$(cd "${probe_dir}" && ./probe.sh)"
assert_contains "a script subprocess resolves find to a real binary, not the session's shim" \
  "${real}" "resolved=/usr/bin/find"
assert_contains "and that find accepts the relative timestamp form both BSD and GNU accept" \
  "${real}" "relative=accepted"

# The positive control. Without it this fixture cannot tell "the shim is absent" from "the probe never
# measured anything", and an assertion that has never been seen to fail is protecting nothing (L1, L171).
# A stand-in that refuses the relative form exactly as bfs does, put on PATH the way an exported shim
# would reach a subprocess.
mkdir -p "${probe_dir}/shim"
cat > "${probe_dir}/shim/find" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "${arg}" = "-newermt" ]; then
    echo "Invalid timestamp" >&2
    exit 1
  fi
done
exec /usr/bin/find "$@"
SHIM
chmod +x "${probe_dir}/shim/find"

shimmed="$(cd "${probe_dir}" && PATH="${probe_dir}/shim:${PATH}" ./probe.sh)"
assert_contains "the probe SEES a shim when there is one to see" \
  "${shimmed}" "relative=refused"
assert_not_contains "and reports the shim's own path rather than the real one" \
  "${shimmed}" "resolved=/usr/bin/find"

if [ "${FAILURES}" -ne 0 ]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "all find-is-not-shimmed checks passed"
