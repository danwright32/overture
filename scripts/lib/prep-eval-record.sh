#!/usr/bin/env bash
# The record of the last paid runbook eval that GENUINELY COMPLETED (#1867).
#
# scripts/eval-prep-runbook.sh --yes is the only thing that scores real model output against
# docs/prep-runbook.md. It spends tokens, so it is wired into no CI job and no hook, and whether it
# has been run since the drafting rules last changed rested entirely on remembering. It did not
# hold: the harness could not start at all for three days (#1862) with nobody noticing, and two
# runbook edits (#1856, #1817) reached main before anything had scored either.
#
# This file is the one definition of that record, sourced by BOTH the writer
# (scripts/eval-prep-runbook.sh) and the reader (scripts/check-prep-eval-freshness.sh), so the two
# cannot drift into writing one shape and reading another.
#
# WHAT IS RECORDED, and why it is not a timestamp comparison. The record names the runbook TEXT
# that was scored, by content hash, never the time the file was last touched. An mtime answers the
# wrong question in both directions: a fresh clone rewrites every mtime, so a real eval would read
# as older than a runbook nobody had edited, and a bare `touch` on either side would report an eval
# that never happened. Content is the thing the rules actually live in.

# The record's path. One override for both sides, so a test can point the writer and the reader at
# the same throwaway file and neither can be left reading the real one.
# $1: the repo root, used only for the default.
prep_eval_last_run_file() {
  echo "${OVERTURE_EVAL_LAST_RUN_FILE:-${1}/.overture-eval-last-run}"
}

# The fingerprint of a runbook's CONTENT. Fails (nonzero, prints nothing) when the file is absent or
# git is unavailable, so a caller that cannot fingerprint says it cannot rather than comparing
# against an empty string, which would match every other failed fingerprint.
prep_eval_runbook_fingerprint() {
  local path="$1"
  [ -f "${path}" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  git hash-object -- "${path}" 2>/dev/null
}

# One field out of a record. Nonzero when the record is absent; empty output when the field is not
# in it. The caller must treat those two as different from a value (L11).
prep_eval_record_field() {
  local file="$1" key="$2"
  [ -f "${file}" ] || return 1
  sed -n "s/^${key} \(.*\)\$/\1/p" "${file}" | head -1
}

# Write the record. Called ONLY after the last fixture of a run has been scored: a marker touched on
# the way in would make a run that died at its first AI call indistinguishable from one that
# finished, which is the whole thing this record exists to tell apart.
#
# Written to a temp file and moved into place, so a record half written by an interrupted process
# never replaces a good one (L5).
prep_eval_write_last_run() {
  local file="$1" fingerprint="$2" completed="$3" scored="$4" available="$5" passed="$6" outputs="$7"
  local tmp="${file}.writing.$$"
  {
    echo "runbook ${fingerprint}"
    echo "completed ${completed}"
    echo "scored ${scored}"
    echo "available ${available}"
    echo "passed ${passed}"
    echo "outputs ${outputs}"
  } > "${tmp}" || return 1
  mv "${tmp}" "${file}"
}
