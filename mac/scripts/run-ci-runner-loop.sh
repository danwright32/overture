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

REPO="danwright32/overture"
GH_IDENTITY="danwright32"
RUNNER_LABEL="${OVERTURE_CI_RUNNER_LABEL:-overture-mac}"
RUNNER_DIR="${OVERTURE_CI_RUNNER_DIR:-$HOME/actions-runner-overture}"
RUNNER_NAME="$(hostname -s)-overture-ci"
RETRY_DELAY=30

log() {
  echo "$(date -u +%FT%TZ) $1"
}

cd "${RUNNER_DIR}" || { log "runner directory not found at ${RUNNER_DIR}; run register-ci-runner.sh first" >&2; exit 1; }

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
}

RUN_PID=""
stop() {
  log "received a stop signal, shutting down after the current job (if any)"
  [[ -n "${RUN_PID}" ]] && kill -TERM "${RUN_PID}" 2>/dev/null
  [[ -n "${RUN_PID}" ]] && wait "${RUN_PID}" 2>/dev/null
  exit 0
}
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
  wait "${RUN_PID}"
  RUN_EXIT=$?
  RUN_PID=""

  if [[ "${RUN_EXIT}" -ne 0 ]]; then
    log "run.sh exited with status ${RUN_EXIT}, retrying in ${RETRY_DELAY}s"
    sleep "${RETRY_DELAY}"
  else
    log "run.sh exited cleanly (job complete), starting the next cycle"
  fi
done
