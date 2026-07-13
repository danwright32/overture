#!/usr/bin/env bash
set -uo pipefail

# Launched by the com.danwright.overture.ci-runner LaunchAgent at login. Part of #478
# (milestone 12), Phase 2 (#504). See docs/ci-runner-setup.md.
#
# An --ephemeral runner deregisters itself and run.sh exits after exactly one job (GitHub's
# own documented behavior), so this loops forever: mint a fresh registration token, wipe the
# previous job's local runner state, configure, run one job, repeat. Deliberately no `set -e`
# here: a single failed iteration (network blip, an expired token) should be logged and
# retried, not take the whole agent down.
#
# #881: that "run.sh exits after one job" assumption is load-bearing, and on 2026-07-13 it broke.
# The runner PROCESS was alive and its log's last line said "Listening for Jobs", while GitHub
# listed ZERO runners: it was holding a session GitHub no longer recognised, so it would never be
# assigned a job and run.sh would never exit. This loop blocked on `wait` forever. swift-tests sat
# queued, nothing could merge, and the only cure was restarting the LaunchAgent by hand. A live
# process is NOT evidence of a live runner; the only authority is whether GitHub still lists it.
#
# So the wait is now supervised. While run.sh is listening, this asks GitHub whether the runner is
# actually registered, and if it has genuinely vanished it kills the dead listener and starts a
# fresh cycle. A failed API call is NOT evidence of absence: killing a healthy runner mid-build
# because GitHub was briefly unreachable would be a worse bug than the one being fixed.

REPO="danwright32/overture"
GH_IDENTITY="danwright32"
RUNNER_LABEL="${OVERTURE_CI_RUNNER_LABEL:-overture-mac}"
RUNNER_DIR="${OVERTURE_CI_RUNNER_DIR:-$HOME/actions-runner-overture}"
RUNNER_NAME="$(hostname -s)-overture-ci"
RETRY_DELAY=30

# #881. How often to ask GitHub whether the runner still exists, and how many CONSECUTIVE "it is
# gone" answers it takes to act. Never one: an ephemeral runner is legitimately absent for a moment
# between finishing its job (GitHub deregisters it) and run.sh exiting, and a single unlucky probe
# in that window must not read as a zombie.
LIVENESS_INTERVAL="${OVERTURE_CI_LIVENESS_INTERVAL:-60}"
LIVENESS_STRIKES="${OVERTURE_CI_LIVENESS_STRIKES:-3}"

log() {
  echo "$(date -u +%FT%TZ) $1"
}

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
}

# What GitHub says about THIS runner, right now. Three states, deliberately, because two would be a
# lie: "the API did not answer" is not the same fact as "the runner is gone", and conflating them is
# exactly how a network blip would kill a healthy runner mid-build.
#
#   registered - GitHub lists it (idle OR mid-job; busy is still alive and must never be killed)
#   absent     - GitHub answered, and this runner is not in the list. The zombie case.
#   unknown    - the API call itself failed. Evidence of nothing.
runner_state() {
  local out
  if ! out="$(gh_as_danwright32 api "repos/${REPO}/actions/runners" \
      --jq '.runners[] | [.name, .status, .busy] | @tsv' 2>/dev/null)"; then
    echo "unknown"
    return 0
  fi
  if printf '%s\n' "${out}" | grep -q "^${RUNNER_NAME}$(printf '\t')"; then
    echo "registered"
  else
    echo "absent"
  fi
}

# The strike counter. Only a definite "it is gone" advances it; a definite "it is here" clears it;
# an unknown HOLDS, so a blip neither kills a healthy runner nor lets a real zombie off the hook.
next_strikes() {
  local state="$1" strikes="$2"
  case "${state}" in
    registered) echo 0 ;;
    absent)     echo $((strikes + 1)) ;;
    *)          echo "${strikes}" ;;
  esac
}

is_zombie() {
  local strikes="$1" threshold="$2"
  (( strikes >= threshold ))
}

# Wait for run.sh, but never forever. Returns 0 if it exited on its own (the normal path: one job
# done), 1 if it was killed as a zombie.
supervise_run() {
  local pid="$1" strikes=0 state
  while kill -0 "${pid}" 2>/dev/null; do
    sleep "${LIVENESS_INTERVAL}"
    kill -0 "${pid}" 2>/dev/null || break     # it finished while we slept: the normal path

    state="$(runner_state)"
    strikes="$(next_strikes "${state}" "${strikes}")"

    if is_zombie "${strikes}" "${LIVENESS_STRIKES}"; then
      # Loud on purpose. A CI runner that stopped picking up jobs was previously visible to nobody.
      log "ALERT: ${RUNNER_NAME} is running but GitHub has not listed it for ${strikes} consecutive checks."
      log "ALERT: it is listening on a dead session and will never be given a job. Killing it and starting a fresh cycle."
      kill -TERM "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 1
    fi
  done
  wait "${pid}" 2>/dev/null
  return 0
}

RUN_PID=""
stop() {
  log "received a stop signal, shutting down after the current job (if any)"
  [[ -n "${RUN_PID}" ]] && kill -TERM "${RUN_PID}" 2>/dev/null
  [[ -n "${RUN_PID}" ]] && wait "${RUN_PID}" 2>/dev/null
  exit 0
}

main() {
  cd "${RUNNER_DIR}" || { log "runner directory not found at ${RUNNER_DIR}; run register-ci-runner.sh first" >&2; exit 1; }
  trap stop TERM INT

  while true; do
    log "minting a fresh registration token for ${REPO}"
    TOKEN="$(gh_as_danwright32 api -X POST "repos/${REPO}/actions/runners/registration-token" --jq .token)"
    if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
      log "failed to mint a registration token, retrying in ${RETRY_DELAY}s"
      sleep "${RETRY_DELAY}"
      continue
    fi

    # GitHub deregisters an ephemeral runner on its side once the job completes, but that
    # leaves local state (credentials and job workspace) behind; wipe it before reconfiguring,
    # per GitHub's own guidance for automating ephemeral runners.
    rm -f .runner .credentials .credentials_rsaparams
    rm -rf _work

    if ! ./config.sh --url "https://github.com/${REPO}" --token "${TOKEN}" \
        --name "${RUNNER_NAME}" --labels "${RUNNER_LABEL}" --work _work \
        --unattended --ephemeral --replace; then
      log "config.sh failed, retrying in ${RETRY_DELAY}s"
      sleep "${RETRY_DELAY}"
      continue
    fi

    log "listening for one job as ${RUNNER_NAME} (label: ${RUNNER_LABEL})"
    ./run.sh &
    RUN_PID=$!
    supervise_run "${RUN_PID}"
    RUN_EXIT=$?
    RUN_PID=""

    if [[ "${RUN_EXIT}" -ne 0 ]]; then
      log "starting a fresh cycle in ${RETRY_DELAY}s"
      sleep "${RETRY_DELAY}"
    else
      log "run.sh exited cleanly (job complete), starting the next cycle"
    fi
  done
}

# #881: allow this file to be sourced (by run-ci-runner-loop.test.sh) without starting the loop, so
# the liveness logic can be exercised directly against stubbed gh responses. Mirrors check-pr-ci.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
