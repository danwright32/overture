#!/usr/bin/env bash
set -uo pipefail

# #4328 (step A1 of #4275's plan) and #4327 step 0.0: record the scout landing oracle FROM 6d3453d8, and
# freeze the real inputs it is recorded on.
#
#   scripts/landing-oracle.sh [--freeze <archive>] [--inputs <archive>] [--out <dir>]
#                             [--synthetic-to <dir>] [--commit <sha>]
#
#   (no flags)            record the synthetic arm into fixtures/landing-oracle/, one file per entry point that
#                         lands shows (#4374): synthetic-<commit>.txt (the extract ingest),
#                         synthetic-runscout-<commit>.txt (runScout's native sweep) and
#                         synthetic-leadpaste-<commit>.txt (the lead paste)
#   --freeze <archive>    first build the frozen inputs there (#4327 step 0.0), then record the real arm on
#                         them (implies --inputs <archive>). The archive must not exist yet, must sit outside
#                         every git work tree, and is left READ ONLY with a MANIFEST of content hashes
#   --inputs <archive>    record the real arm on an existing archive
#   --out <dir>           where the real arm's recordings go; outside every git work tree (required with
#                         --inputs or --freeze)
#
# WHY A WORKTREE OF ITS OWN, AND WHY AN OVERLAY (L70, L58, L731). The oracle's expected values have to come
# from 6d3453d8, the code BEFORE any landing change, or the oracle only proves new code agrees with itself.
# The dump test does not exist at 6d3453d8, so there is nothing there to run. So this creates its OWN
# detached worktree of that commit (never touching the checkout it is run from, and never checking out a
# commit or a path anywhere else), copies onto it ONLY the oracle's test files (refusing any that is not
# test code under mac/OvertureTests/, and any that 6d3453d8 already has, so the overlay can ADD and never
# REPLACE), regenerates the project there, and runs the tests through that worktree's own
# mac/scripts/run-tests-locked.sh. A run that passes and writes its recording is the proof the overlay
# compiles against the OLD app. The worktree is removed on every exit.
#
# REAL DATA STAYS ON THIS MAC. The archive and the real-arm recordings are refused inside any git work tree,
# a real-arm file's first line is the marker the push path refuses (scripts/lib/real-arm-guard.sh), and
# nothing here prints a show name, a presenter or a venue: counts and digests only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=./lib/scratch.sh
source "${SCRIPT_DIR}/lib/scratch.sh"

# The overlay, and nothing else: the oracle's own test files. Everything they use must already exist at the
# oracle commit, which is what the build in that worktree proves. ScaledCorpus.swift (#4427) builds the frozen
# 4x store and the results landed on it; overlaid so the freeze builds today's corpus, each copy with sources
# of its own, rather than the one 6d3453d8's Phase0Corpus.swift builds.
ORACLE_OVERLAY=(
  mac/OvertureTests/LandingOracle.swift
  mac/OvertureTests/LandingOracleCorpus.swift
  mac/OvertureTests/LandingOracleTests.swift
  mac/OvertureTests/ScaledCorpus.swift
)

# The synthetic tests the recording runs, one per entry point that lands shows (#4374), and the file each
# writes. LandingOracleCorpus.Path names the same three files on the Swift side; a run that leaves any one of
# them unwritten is refused by name rather than copying the two it did write.
ORACLE_SYNTHETIC_TESTS=(
  theSyntheticLandingEqualsTheOracleRecordedFromMain
  theRunScoutLandingEqualsTheOracleRecordedFromMain
  theLeadPasteLandingEqualsTheOracleRecordedFromMain
)

# oracle_synthetic_recordings <short commit>: the file names the synthetic run writes, one per line.
oracle_synthetic_recordings() {
  printf '%s\n' "synthetic-$1.txt" "synthetic-runscout-$1.txt" "synthetic-leadpaste-$1.txt"
}

# oracle_overlay_refusal <commit> <path>: why <path> may not be overlaid onto <commit>, or nothing.
oracle_overlay_refusal() {
  local commit="$1" path="$2"
  case "${path}" in
    mac/OvertureTests/*.swift) ;;
    *) echo "${path} is not test code under mac/OvertureTests/"; return 0 ;;
  esac
  case "${path}" in
    *..*) echo "${path} climbs out of mac/OvertureTests/"; return 0 ;;
  esac
  if git -C "${REPO_ROOT}" cat-file -e "${commit}:${path}" 2>/dev/null; then
    echo "${path} already exists at ${commit}, and the overlay may only ADD files"
  fi
}

# outside_every_work_tree <dir>: 0 only when git says <dir> (or its nearest existing parent) is in NO
# repository. Any other answer, including a git that fails for another reason (dubious ownership, no git at
# all) or answers "false" from inside a .git directory, is 1: a question it did not answer refuses (L42).
outside_every_work_tree() {
  local probe="$1" said
  # Absolute first, so the walk up by parameter expansion always reaches "/": a bare relative name holds no
  # slash to strip and would loop for ever. Expansion rather than dirname, so the walk cannot depend on PATH.
  case "${probe}" in /*) ;; *) probe="${PWD}/${probe}" ;; esac
  while [ ! -e "${probe}" ] && [ -n "${probe}" ] && [ "${probe}" != "/" ]; do probe="${probe%/*}"; done
  [ -n "${probe}" ] || probe="/"
  if said="$(git -C "${probe}" rev-parse --is-inside-work-tree 2>&1)"; then
    return 1
  fi
  case "${said}" in
    *"not a git repository"*) return 0 ;;
    *) return 1 ;;
  esac
}

# oracle_record_real_arm <runner> <suite> <inputs> <out> <log>: records the real arm, ONE SIZE PER RUNNER
# INVOCATION, so each lands in a test process that has run nothing else (#4397): measured, 1x reproduces
# only alone, so neither size may follow the other in one process. Returns the first non-zero runner exit.
oracle_record_real_arm() {
  local runner="$1" suite="$2" inputs="$3" out="$4" log="$5" size one status=0
  : > "${log}.all"
  for size in 1x 4x; do
    OVERTURE_TEST_STALL_END_SECONDS="${OVERTURE_TEST_STALL_END_SECONDS:-3300}" \
    TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4275_INPUTS="${inputs}" TEST_RUNNER_MEASURE_4275_OUT="${out}" \
    TEST_RUNNER_LANDING_ORACLE_MODE=record TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1 \
      "${runner}" "-only-testing:${suite}/realArmAt${size}()" 2>&1 | tee "${log}"
    one="${PIPESTATUS[0]}"
    cat "${log}" >> "${log}.all"
    [ "${one}" -eq 0 ] || [ "${status}" -ne 0 ] || status="${one}"
  done
  cp "${log}.all" "${log}"
  return "${status}"
}

main() {
  local commit="6d3453d8" freeze="" inputs="" out="" synthetic_to=""
  while [ $# -gt 0 ]; do
    # Every flag takes a value. One given without it would leave `shift 2` unable to shift and the loop
    # spinning, so it is refused by name instead.
    if [ $# -lt 2 ]; then
      echo "landing-oracle: REFUSED: $1 needs a value" >&2
      return 2
    fi
    case "$1" in
      --freeze) freeze="${2:-}"; shift 2 ;;
      --inputs) inputs="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      --synthetic-to) synthetic_to="${2:-}"; shift 2 ;;
      --commit) commit="${2:-}"; shift 2 ;;
      *) echo "landing-oracle: unknown argument $1" >&2; return 2 ;;
    esac
  done

  local full
  if ! full="$(git -C "${REPO_ROOT}" rev-parse --verify -q "${commit}^{commit}")"; then
    echo "landing-oracle: REFUSED: ${commit} is not a commit this clone has" >&2
    return 2
  fi
  local short="${full:0:8}"
  [ -n "${synthetic_to}" ] || synthetic_to="${REPO_ROOT}/fixtures/landing-oracle"
  [ -z "${freeze}" ] || inputs="${freeze}"

  if [ -n "${inputs}" ]; then
    if [ -z "${out}" ]; then
      echo "landing-oracle: REFUSED: the real arm needs --out <dir>, outside every git work tree" >&2
      return 2
    fi
    local d
    for d in "${inputs}" "${out}"; do
      if ! outside_every_work_tree "${d}"; then
        echo "landing-oracle: REFUSED: ${d} is inside a git work tree, and it would hold real data" >&2
        return 2
      fi
    done
  fi
  if [ -n "${freeze}" ] && [ -e "${freeze}" ] && [ -n "$(ls -A "${freeze}" 2>/dev/null)" ]; then
    echo "landing-oracle: REFUSED: ${freeze} already exists; an archive is written once" >&2
    return 2
  fi

  local path why
  for path in "${ORACLE_OVERLAY[@]}"; do
    why="$(oracle_overlay_refusal "${full}" "${path}")"
    if [ -n "${why}" ]; then
      echo "landing-oracle: REFUSED: ${why}" >&2
      return 2
    fi
    if [ ! -f "${REPO_ROOT}/${path}" ]; then
      echo "landing-oracle: REFUSED: ${path} is missing from ${REPO_ROOT}" >&2
      return 2
    fi
  done

  local scratch wt
  scratch="$(overture_scratch_dir landing-oracle)"
  wt="${scratch}/oracle-${short}"
  if [ -e "${wt}" ]; then
    echo "landing-oracle: REFUSED: ${wt} already exists" >&2
    return 2
  fi
  # shellcheck disable=SC2064
  trap "git -C '${REPO_ROOT}' worktree remove --force '${wt}' >/dev/null 2>&1; git -C '${REPO_ROOT}' worktree prune; rm -rf '${scratch}'" EXIT
  if ! git -C "${REPO_ROOT}" worktree add --detach -q "${wt}" "${full}"; then
    echo "landing-oracle: REFUSED: could not create a worktree of ${full}" >&2
    return 2
  fi
  for path in "${ORACLE_OVERLAY[@]}"; do
    cp "${REPO_ROOT}/${path}" "${wt}/${path}"
  done
  echo "landing-oracle: worktree of ${full} at ${wt}, overlaid with ${#ORACLE_OVERLAY[@]} test files"
  if ! (cd "${wt}/mac" && xcodegen generate --quiet); then
    echo "landing-oracle: REFUSED: xcodegen could not regenerate the project in the oracle worktree" >&2
    return 2
  fi

  local runner="${wt}/mac/scripts/run-tests-locked.sh" suite="OvertureTests/LandingOracleTests" log status
  # Each of the up to three runs below queues for the one test lock this Mac shares, and the runner's own
  # default of 1800s gave up on the first real recording while six runs were ahead of it (measured
  # 2026-09-29, NOTHING RAN). The wait is bounded, just by something sized for a queue this deep (L110).
  export OVERTURE_DIR_LOCK_TIMEOUT="${OVERTURE_DIR_LOCK_TIMEOUT:-14400}"
  log="${scratch}/run.log"

  # 1. The synthetic arm, one recording per entry point (#4374), all three in ONE runner invocation so they
  #    queue for the test lock once. Its passing run IS the proof the overlay compiles against the old app.
  local recorded="${scratch}/synthetic" name test missing=""
  mkdir -p "${recorded}"
  local only=()
  for test in "${ORACLE_SYNTHETIC_TESTS[@]}"; do only+=("-only-testing:${suite}/${test}()"); done
  TEST_RUNNER_LANDING_ORACLE_RECORD_SYNTHETIC="${recorded}" "${runner}" "${only[@]}" 2>&1 | tee "${log}"
  status="${PIPESTATUS[0]}"
  for name in $(oracle_synthetic_recordings "${short}"); do
    [ -s "${recorded}/${name}" ] || missing="${missing} ${name}"
  done
  if [ "${status}" -ne 0 ] || [ -n "${missing}" ]; then
    echo "landing-oracle: REFUSED: the overlay did not build and record at ${full} (exit ${status}; not recorded:${missing:- none})" >&2
    return 1
  fi
  echo "landing-oracle: OVERLAY COMPILED AND RAN against ${full}"
  mkdir -p "${synthetic_to}"
  for name in $(oracle_synthetic_recordings "${short}"); do
    cp "${recorded}/${name}" "${synthetic_to}/${name}"
    echo "landing-oracle: synthetic arm recorded to ${synthetic_to}/${name}"
  done

  # 2. The frozen inputs (#4327 step 0.0).
  if [ -n "${freeze}" ]; then
    mkdir -p "${freeze}"
    TEST_RUNNER_FREEZE_4275_TO="${freeze}" \
      "${runner}" "-only-testing:${suite}/freezeTheInputs()" 2>&1 | tee "${log}"
    status="${PIPESTATUS[0]}"
    if [ "${status}" -ne 0 ] || [ ! -s "${freeze}/FACTS" ] || ! grep -q "FROZE inputs" "${log}"; then
      echo "landing-oracle: REFUSED: the inputs were not frozen (exit ${status})" >&2
      return 1
    fi
    {
      echo "# #4327 step 0.0: frozen inputs for the scout landing oracle. REAL DATA: never leaves this Mac,"
      echo "# never opened in place (every run copies it afresh), read only. sha256 of every file below."
      cat "${freeze}/FACTS"
      echo "commit: ${full}"
      echo "frozen-by: scripts/landing-oracle.sh"
      (cd "${freeze}" && find . -type f ! -name MANIFEST | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
        shasum -a 256 "${f}"
      done)
    } > "${freeze}/MANIFEST"
    chmod -R a-w "${freeze}"
    echo "landing-oracle: froze $(grep -c '^[0-9a-f]\{64\}  ' "${freeze}/MANIFEST") files to ${freeze}, read only"
  fi

  # 3. The real arm on the frozen inputs, in a process running nothing else, with Swift's hash seed fixed.
  #    Measured 2026-09-30 (#4397): 1x reproduces only in its own process, and 4x varies run to run even so.
  if [ -n "${inputs}" ]; then
    mkdir -p "${out}"
    status=0
    oracle_record_real_arm "${runner}" "${suite}" "${inputs}" "${out}" "${log}" || status=$?
    local size marker
    marker="$(printf '%s%s' "OVERTURE-REAL-ARM" ": never commit")"
    for size in x1 x4; do
      if [ "$(head -n 1 "${out}/real-arm-${size}.oracle" 2>/dev/null)" != "${marker}" ]; then
        echo "landing-oracle: REFUSED: no marked real-arm recording for ${size} (exit ${status})" >&2
        return 1
      fi
    done
    [ "${status}" -eq 0 ] || { echo "landing-oracle: the real arm run failed (exit ${status})" >&2; return 1; }
    echo "landing-oracle: real arm recorded to ${out}"
    grep "landing-oracle: RECORDED real arm" "${log}" | sed 's/^.*landing-oracle: /landing-oracle: /'
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
