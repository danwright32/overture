#!/usr/bin/env bash
set -euo pipefail

# One time (idempotent, safe to re-run) install of an ephemeral self-hosted GitHub Actions
# runner for this repo, scoped to danwright32/overture only (not org-wide). Part of #478
# (milestone 12), Phase 2 (#504). See docs/ci-runner-setup.md for the full picture.
#
# This script only prepares things: it verifies access, downloads and verifies the runner
# distribution, and installs + bootstraps a LaunchAgent. It does not itself mint a
# registration token or start listening for a job. An --ephemeral runner deregisters and
# exits after exactly one job, so the ongoing mint-token/configure/run cycle is the
# LaunchAgent's job (run-ci-runner-loop.sh), forever, starting with its first RunAtLoad.
#
# Run manually by a human with danwright32 admin access to danwright32/overture. This mints
# no credentials itself, but it downloads a real binary and starts a real persistent
# background process on this Mac (the LaunchAgent). Do not run this as a test.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPO="danwright32/overture"
GH_IDENTITY="danwright32"
RUNNER_LABEL="overture-mac"

# Kept outside the repo checkout entirely so the downloaded runner binary and its per-job
# work/diagnostic output never risk being committed.
RUNNER_DIR="${OVERTURE_CI_RUNNER_DIR:-$HOME/actions-runner-overture}"

AGENT_LABEL="com.danwright.overture.ci-runner"
AGENT_SRC="${REPO_ROOT}/mac/launchd/${AGENT_LABEL}.plist"
AGENT_DEST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
GUI_DOMAIN="gui/$(id -u)"
LOOP_SCRIPT="${REPO_ROOT}/mac/scripts/run-ci-runner-loop.sh"
LOG_DIR="${HOME}/Library/Logs/OvertureCIRunner"

command -v gh >/dev/null || { echo "gh CLI not found; install it (brew install gh) and run: gh auth login" >&2; exit 1; }

gh_as_danwright32() {
  GH_TOKEN="$(gh auth token -u "${GH_IDENTITY}")" gh "$@"
}

echo "==> Verifying ${GH_IDENTITY} has admin access to ${REPO}"
IS_ADMIN="$(gh_as_danwright32 api "repos/${REPO}" --jq .permissions.admin)"
if [[ "${IS_ADMIN}" != "true" ]]; then
  echo "Error: ${GH_IDENTITY} does not have admin access to ${REPO} (permissions.admin=${IS_ADMIN})." >&2
  echo "Registration tokens and runner downloads both require repo admin access." >&2
  exit 1
fi

echo "==> Ensuring the macOS arm64 runner distribution is present at ${RUNNER_DIR}"
mkdir -p "${RUNNER_DIR}"
chmod 700 "${RUNNER_DIR}"
if [[ -x "${RUNNER_DIR}/config.sh" ]]; then
  echo "    Already present, skipping download."
else
  # Repo scoped download endpoint returns the current macOS arm64 asset plus its sha256
  # checksum, so this never hardcodes a runner version that goes stale. Matching on the
  # filename (rather than the os/architecture fields) avoids depending on exact enum casing.
  DOWNLOAD_INFO="$(gh_as_danwright32 api "repos/${REPO}/actions/runners/downloads" \
    --jq '[.[] | select(.filename | test("osx-arm64"))][0] | [.download_url, .filename, .sha256_checksum] | @tsv')"
  IFS=$'\t' read -r DOWNLOAD_URL RUNNER_FILENAME RUNNER_SHA256 <<< "${DOWNLOAD_INFO}"

  if [[ -z "${DOWNLOAD_URL}" || "${DOWNLOAD_URL}" == "null" ]]; then
    echo "Error: no osx-arm64 runner asset found in repos/${REPO}/actions/runners/downloads." >&2
    exit 1
  fi
  if [[ -z "${RUNNER_SHA256}" || "${RUNNER_SHA256}" == "null" ]]; then
    echo "Error: GitHub did not return a sha256 checksum for ${RUNNER_FILENAME}; refusing to install unverified." >&2
    exit 1
  fi

  echo "    Downloading ${RUNNER_FILENAME}"
  curl -f -L -o "${RUNNER_DIR}/${RUNNER_FILENAME}" "${DOWNLOAD_URL}"

  echo "    Verifying checksum"
  echo "${RUNNER_SHA256}  ${RUNNER_DIR}/${RUNNER_FILENAME}" | shasum -a 256 -c -

  echo "    Extracting to ${RUNNER_DIR}"
  tar xzf "${RUNNER_DIR}/${RUNNER_FILENAME}" -C "${RUNNER_DIR}"
  rm -f "${RUNNER_DIR}/${RUNNER_FILENAME}"
fi

echo "==> Installing the runner loop script and LaunchAgent"
chmod +x "${LOOP_SCRIPT}"
mkdir -p "${HOME}/Library/LaunchAgents"
# Owner-only log directory, same rationale as com.danwright.overture's (#279): launchd opens
# StandardOutPath at spawn, before any script code runs, so it must exist now.
mkdir -p "${LOG_DIR}"
chmod 700 "${LOG_DIR}"

echo "==> Stopping any existing ${AGENT_LABEL} agent"
launchctl bootout "${GUI_DOMAIN}/${AGENT_LABEL}" 2>/dev/null || true

# A prior run that was interrupted before its ephemeral job completed can leave a runner
# still registered on GitHub's side. Clear it so the loop script's first config.sh doesn't
# collide with a stale registration under the same name (idempotent re-run).
if [[ -f "${RUNNER_DIR}/.runner" ]]; then
  echo "==> Removing a prior runner registration"
  REMOVE_TOKEN="$(gh_as_danwright32 api -X POST "repos/${REPO}/actions/runners/remove-token" --jq .token)"
  (cd "${RUNNER_DIR}" && ./config.sh remove --token "${REMOVE_TOKEN}") \
    || echo "    (remove reported an error; ${RUNNER_DIR}/.runner may need manual cleanup)"
fi

# launchd does NOT expand ~, so bake the absolute paths this install resolved into the
# installed plist copy.
sed \
  -e "s|__CI_RUNNER_LOOP_SCRIPT__|${LOOP_SCRIPT}|g" \
  -e "s|__CI_RUNNER_LOG_DIR__|${LOG_DIR}|g" \
  -e "s|__CI_RUNNER_DIR__|${RUNNER_DIR}|g" \
  "${AGENT_SRC}" > "${AGENT_DEST}"

launchctl bootstrap "${GUI_DOMAIN}" "${AGENT_DEST}" \
  || echo "    (agent bootstrap reported an error; inspect with: launchctl print ${GUI_DOMAIN}/${AGENT_LABEL})"

echo "==> Installed: ${AGENT_DEST}"
echo "    The loop script now mints a fresh registration token, configures an ephemeral"
echo "    runner (label: ${RUNNER_LABEL}), and runs one job at a time, repeating forever."
echo "    Logs: ${LOG_DIR}/ci-runner-agent.out.log"
echo "    Inspect: launchctl print ${GUI_DOMAIN}/${AGENT_LABEL}"
echo "    Tear down: see docs/ci-runner-setup.md"
