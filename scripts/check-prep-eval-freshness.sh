#!/usr/bin/env bash
set -euo pipefail

# WARNS when docs/prep-runbook.md has changed since the paid eval last completed (#1867).
#
# The runbook is a prompt, not code. Two layers guard it, and only one of them is free: every
# `pnpm test` asserts the guarded rules are still present in its text, but the only thing that
# scores REAL model output against those rules is `scripts/eval-prep-runbook.sh --yes`. That one
# spends tokens, so it is deliberately wired into no CI job and no hook, and remembering to run it
# was the entire mechanism. It did not hold: the harness could not start at all from 2026-07-28 to
# 2026-07-31 (#1862) and nobody noticed, because nobody ran it, and two runbook edits (#1856,
# #1817) shipped before it had scored either.
#
# IT MUST NEVER BLOCK. A gate here would either be routinely overridden or would spend Dan's tokens
# on its own, and neither is what an unrun eval deserves. So every verdict exits 0 and the only
# nonzero exit is a broken invocation (no runbook at the path given).
#
# It rides along in scripts/test-all.sh, next to check-brand-voice-drift.sh, whose shape it follows:
# a local check that skips cleanly and says so on a machine that cannot perform the comparison at
# all, rather than reporting a false alarm there.
#
# Usage: scripts/check-prep-eval-freshness.sh [runbook-path]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The record's shape, path and fingerprint, shared with the writer so the two cannot drift.
# shellcheck source=./lib/prep-eval-record.sh
. "${SCRIPT_DIR}/lib/prep-eval-record.sh"

# The verdict, given the CURRENT runbook's fingerprint ($1) and the record file ($2). Prints what a
# person reads and returns which of the four states it found:
#   0  fresh      an eval completed against this exact runbook text
#   1  stale      the runbook has changed since the last completed eval
#   2  never run  no eval has ever completed here
#   3  unreadable a record exists but cannot say what was scored, or when
#
# Never-run and stale are deliberately separate states with separate words. They call for the same
# command but they are not the same fact, and a check that reports "stale" at a machine that has
# never run the eval is telling somebody their last run has aged when there was no last run (L10,
# L11). Pure: takes a fingerprint and a path, so the fixture drives it against throwaway records.
prep_eval_freshness() {
  local current="$1" record="$2"
  local recorded completed scored available passed covered covered_passed

  if [ ! -f "${record}" ]; then
    echo "NEVER RUN: no completed run of the paid eval is recorded here (${record})."
    echo "Nothing on this machine has ever scored real model output against the drafting rules."
    return 2
  fi

  recorded="$(prep_eval_record_field "${record}" runbook || true)"
  completed="$(prep_eval_record_field "${record}" completed || true)"
  if [ -z "${recorded}" ] || [ -z "${completed}" ]; then
    echo "UNREADABLE: the record at ${record} does not say which runbook was scored, or when."
    echo "That is not the same as no run: something wrote this file and it cannot be trusted to"
    echo "answer for any runbook, so delete it and run the eval again."
    return 3
  fi

  if [ "${recorded}" != "${current}" ]; then
    echo "STALE: docs/prep-runbook.md has CHANGED since the paid eval last completed (${completed})."
    echo "No real model output has been scored against the drafting rules as they now stand."
    return 1
  fi

  scored="$(prep_eval_record_field "${record}" scored || true)"
  available="$(prep_eval_record_field "${record}" available || true)"
  passed="$(prep_eval_record_field "${record}" passed || true)"

  # #2581: COVERAGE against these rules is the cumulative set, which is not the same as what the last
  # run happened to re-score. A `--yes --failed` recheck of one fixture used to overwrite the record of a
  # full pass, so this check then under-reported what had been verified, which is the wrong direction for
  # a harness whose whole job is saying what has been checked.
  #
  # A record written before those fields existed carries none of them. That is a real absence rather than
  # a writer's omission, so it falls back to this run's own numbers, which is exactly how such a record
  # read before, and under-reports rather than claiming coverage nobody measured.
  covered="$(prep_eval_record_field "${record}" covered || true)"
  covered_passed="$(prep_eval_record_field "${record}" coveredPassed || true)"
  if [ -z "${covered}" ]; then
    covered="${scored}"
    covered_passed="${passed}"
  fi

  if [ -n "${covered}" ] && [ -n "${available}" ]; then
    echo "OK: the paid eval last completed ${completed} against this exact docs/prep-runbook.md (${covered} of ${available} fixtures scored)."
  else
    echo "OK: the paid eval last completed ${completed} against this exact docs/prep-runbook.md."
  fi

  # Where the two differ, BOTH are said. The cumulative number alone would present verdicts taken days
  # ago as though the last run produced them, and the last run's number alone is the under-report this
  # issue was filed about (L11).
  if [ -n "${covered}" ] && [ -n "${scored}" ] && [ "${scored}" -lt "${covered}" ] 2>/dev/null; then
    echo "That last run re-scored ${scored} of them; the rest are verdicts carried forward from earlier runs against this same runbook text."
  fi

  # A run may be fresh and still have claimed less than a reader would assume. Both of these are
  # things the record measured, so saying them costs nothing and leaving them out would let a
  # one-fixture spot check, or a run that failed, read as a whole suite passing (L11).
  if [ -n "${covered}" ] && [ -n "${available}" ] && [ "${covered}" -lt "${available}" ] 2>/dev/null; then
    echo "That run was TARGETED at ${covered} of ${available} fixtures; the rest have not been scored against these rules."
  fi
  if [ -n "${covered}" ] && [ -n "${covered_passed}" ] && [ "${covered_passed}" -lt "${covered}" ] 2>/dev/null; then
    echo "It also left $(( covered - covered_passed )) fixture(s) FAILING. Recheck just those with: scripts/eval-prep-runbook.sh --yes --failed"
  fi
  return 0
}

how_to_run_it() {
  echo
  echo "Run it by hand before shipping a docs/prep-runbook.md edit. It makes one real AI call per"
  echo "fixture and spends tokens, which is why nothing runs it for you:"
  echo "  scripts/eval-prep-runbook.sh --yes"
  echo "This is a warning, not a gate: it does not block the push."
}

main() {
  local runbook="${1:-${REPO_ROOT}/docs/prep-runbook.md}"
  local record current status

  if [ ! -f "${runbook}" ]; then
    echo "ERROR: runbook not found at ${runbook}" >&2
    exit 2
  fi

  # The eval runs the runbook through the `claude` CLI. A machine without it (CI, a clone on another
  # Mac) could never have run the eval and can never be told to, so warning there would be a
  # permanent false alarm, which is how a warning becomes something people scroll past (L36).
  if ! command -v claude >/dev/null 2>&1; then
    echo "SKIPPED: the 'claude' CLI is not on PATH, so the paid eval cannot run on this machine; its freshness cannot be judged here."
    exit 0
  fi

  if ! current="$(prep_eval_runbook_fingerprint "${runbook}")" || [ -z "${current}" ]; then
    echo "SKIPPED: could not fingerprint ${runbook} (git is needed to read its contents), so freshness cannot be judged."
    exit 0
  fi

  record="$(prep_eval_last_run_file "${REPO_ROOT}")"

  set +e
  prep_eval_freshness "${current}" "${record}"
  status=$?
  set -e

  [ "${status}" -eq 0 ] || how_to_run_it
  exit 0
}

# Sourceable without running, so the fixture can drive prep_eval_freshness directly. Mirrors the
# convention in check-brand-voice-drift.sh and merge-when-green.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
