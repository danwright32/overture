#!/usr/bin/env bash
# #2188: telling Overture how the update went.
#
# The Update button opens a Terminal window and forgets it. There is no channel back, so on 2026-08-06
# the run refused (another session had work in progress in the checkout), printed its reason into that
# window, and the app never found out: it had dismissed its own out of date panel on the press, so
# Overture went silent for the rest of the launch about a copy that was still behind. A failure rendered
# as nothing (L12), on the one surface built to make being behind impossible to miss.
#
# So the run leaves a record where the app already reads, beside `installed-build.json` and
# `shipped-commit.json`, and the app watches for the outcome of the press it made. Three states, because
# they are three different things to whoever is looking at them: running, failed with a reason, and gone
# (which is success, and is the ordinary case).
#
# `press` is the id of the button press that started this run. It is what stops a stale record being read
# as the current press's outcome, which would report yesterday's refusal over today's working update.

# Where the record goes. Overridable so the tests write into a directory they own rather than Dan's
# Application Support folder (L2), the same seam `OVERTURE_REPO_ROOT` gives the rest of the update path.
#
# #1711: HOME through a guard rather than directly. update-overture.sh declares `set -euo pipefail`, so
# the bare ${HOME} that used to sit here killed the entire update the first time the record was written,
# with the shell's "HOME: unbound variable" and nothing about updating at all. Returns 1 when there is no
# folder to name, which is a different answer from naming a wrong one: "/Library/Application Support" is
# a system folder nobody meant, and a record written there is one the app will never read.
overture_update_result_path() {
  local dir="${OVERTURE_DATA_DIR:-}"
  if [[ -z "${dir}" ]]; then
    [[ -n "${HOME:-}" ]] || return 1
    dir="${HOME}/Library/Application Support/Overture"
  fi
  printf '%s\n' "${dir}/update-result.json"
}

# Minimal JSON string escaping. The reasons are plain sentences today, and this is here so that a reason
# which one day carries a quote or a path with a backslash cannot write a file the app then fails to
# decode, which would land as "no record at all" and be reported as a run that never started.
overture_update_json_escape() {
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Atomic, like every other record in this folder: written to a temp file in the same directory and
# renamed over the target, so a reader can never catch a half written file and decide from it.
overture_update_write_result() {
  local outcome="${1:-}" reason="${2:-}" path tmp dir
  # #1711: recording how the update went is bookkeeping for the app, so it must never be the thing that
  # stops the update. It says why it recorded nothing rather than passing as written (L12), and hands
  # the run back so the install itself carries on.
  path="$(overture_update_result_path)" || {
    echo "Cannot record how this update went: neither OVERTURE_DATA_DIR nor HOME is set, so there is nowhere Overture reads. The update itself carries on, but Overture will not be told the outcome." >&2
    return 0
  }
  dir="$(dirname "${path}")"
  mkdir -p "${dir}" 2>/dev/null || return 0
  tmp="$(mktemp "${dir}/.update-result.XXXXXX" 2>/dev/null)" || return 0
  printf '{"version":1,"press":"%s","outcome":"%s","reason":"%s","at":"%s"}\n' \
    "$(overture_update_json_escape "${OVERTURE_UPDATE_PRESS:-}")" \
    "${outcome}" \
    "$(overture_update_json_escape "${reason}")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "${tmp}" 2>/dev/null || { rm -f "${tmp}"; return 0; }
  mv -f "${tmp}" "${path}" 2>/dev/null || rm -f "${tmp}"
  return 0
}

# Written before anything is decided, so a run that dies where nothing can catch it (the machine sleeps,
# the window is closed mid build) still says it got as far as starting. Without this, dead and
# never-started are the same absence, and the app would have to guess which it was.
overture_update_record_running() { overture_update_write_result running ""; }

# The reason is passed in rather than composed here: it is the sentence the Terminal window already
# printed, so what Dan reads in the app cannot drift from what the run actually said.
overture_update_record_failed() { overture_update_write_result failed "${1:-}"; }

# Success removes the record rather than recording a success. There is nothing to tell him: the app is
# about to be replaced and relaunched, and its new `installed-build.json` is the report. Leaving a record
# behind would only be something for the next press to misread.
overture_update_clear_result() { rm -f "$(overture_update_result_path)" 2>/dev/null || true; }

# Every function above returns 0 deliberately, including on its own failures. Reporting is not the job:
# a full disk or an unwritable folder must not turn an update that would have worked into a refusal.
# The app's own read has the other half of this, since a record it cannot decode reads as absent.
