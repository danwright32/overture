#!/usr/bin/env bash
# #4295: `scripts/mutate.sh --batch <file> [test-scope ...]`, several mutations proved under ONE hold of
# the shared test lock.
#
# WHY. Each single mutation runs its own mac/scripts/run-tests-locked.sh, which queues for the machine wide
# directory lock (/tmp/xcodebuild-tests.lock, shared with Downbeat and Ovation) once per mutation. Measured
# 2026-09-27: an agent proving five or six guards per PR spent most of four hours or more in that queue, six
# deep and 10 to 30 minutes a wait, for a few minutes of builds. Dan chose this over running tests in
# parallel (2026-09-27, in chat), so the LOCK ITSELF is unchanged: the batch takes it exactly as a run
# does, through the runner's own take_dir_lock, and the only difference is that it enters the queue once.
#
# HOW. Every entry is run by mutate.sh's own single form, as a child, so each gets the same verdict
# vocabulary, refusals and kept log a single run gives, from the same code (L263). In three phases:
#
#   1. Every entry is CHECKED before the queue: applied, aimed and restored with nothing run
#      (OVERTURE_MUTATE_PREFLIGHT_ONLY). A malformed entry is found in seconds rather than after the wait,
#      and is recorded with its refusal while the others go on. A batch with nothing left never queues.
#   2. The lock is taken ONCE, and only for the Swift runner: a custom OVERTURE_MUTATE_RUNNER (the shell
#      fixtures, vitest) never touches it, so a fixture proof cannot block Downbeat's tests for nothing.
#   3. Each ready entry runs in turn, told through OVERTURE_TEST_LOCK_HELD_BY that this process holds the
#      lock for it. run-tests-locked.sh believes that only when the lock's own owner line names this pid
#      AND this pid is its ancestor, so an unrelated process exporting the variable cannot use it. Each
#      inner run still takes its own flock and still has its own stall guard, which can end it as before.
#
# RESTORED BEFORE THE NEXT. After every entry the target file and its repository's status must be exactly
# what they were before it. If not, the batch STOPS there, leaves the tree for a person, and names an
# untouched copy of the file: carrying on would run later entries against a tree nobody meant to test.
#
# INTERRUPTED. Ctrl-C or TERM ends the entry in flight (its whole process group, so the runner's own
# signal handling ends its xcodebuild), puts the file back from the batch's own copy if the entry did not,
# releases the lock and prints the summary. The lock goes on every exit path, through the EXIT trap.
#
# Exit status: 0 every entry CAUGHT; 1 at least one SURVIVED and the rest CAUGHT; 2 at least one entry has
# no result (a refusal); 3 the batch stopped because a restore failed; 130 or 143 interrupted.

MUTATE_BATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runner's own lock functions, not a copy of them: take_dir_lock, release_dir_lock and the process
# group helpers. Sourcing defines them without running the runner, as check-release-compiles.sh does.
# shellcheck source=../../mac/scripts/run-tests-locked.sh
source "${MUTATE_BATCH_LIB_DIR}/../../mac/scripts/run-tests-locked.sh"
# #4568: the bare scope rule, named here rather than left to arrive through the runner's own sourcing.
# shellcheck source=../../mac/scripts/lib/test-scope-shape.sh
source "${MUTATE_BATCH_LIB_DIR}/../../mac/scripts/lib/test-scope-shape.sh"
set +e

BATCH_LABELS=()
BATCH_FILES=()
BATCH_ARGS=()
BATCH_VERDICTS=()
BATCH_LOGS=()
BATCH_BACKUP_DIR=""
BATCH_CHILD_PID=""
BATCH_CURRENT=""
BATCH_LOCK_PHASE="not-started"
BATCH_SUMMARY_PRINTED=""
BATCH_STOP_REASON=""

mutate_batch_usage() {
  cat <<'USAGE'
usage: scripts/mutate.sh --batch <batch-file> [test-scope ...]

Proves several mutations under ONE hold of the shared test lock. Every entry is checked before the queue,
then run in turn by the single form, restored, and verified restored before the next one starts.

The batch file holds one entry per block, blocks separated by a blank line, lines starting with # ignored.
Each line is a key, a colon and ONE space, then the value exactly as written:

  label: <text>          optional, names the entry in the summary
  file: <path>           required, the file to break, resolved from where you run the command
  perl: <expression>     required, exactly what the single form takes as its perl expression
  at: <text>             optional, repeatable, the single form's --at
  at-regex: <re>         optional, repeatable, the single form's --at-regex
  breaks-the-build       optional, on a line of its own, the single form's --breaks-the-build

The test scope is shared by every entry and given on the command line, after the batch file.
USAGE
}

mutate_batch_refuse() {
  echo "MALFORMED BATCH - $1"
  echo "  Nothing was mutated and nothing was run. The whole batch is refused, because an entry read"
  echo "  differently from how it was written would be judged as a mutation nobody asked for."
  exit 2
}

# Parse state for the entry being read.
BATCH_ENTRY_START=""
BATCH_ENTRY_LABEL=""
BATCH_ENTRY_FILE=""
BATCH_ENTRY_PERL=""
BATCH_ENTRY_FLAGS=""
BATCH_ENTRY_SEEN=""

mutate_batch_reset_entry() {
  BATCH_ENTRY_START=""
  BATCH_ENTRY_LABEL=""
  BATCH_ENTRY_FILE=""
  BATCH_ENTRY_PERL=""
  BATCH_ENTRY_FLAGS=""
  BATCH_ENTRY_SEEN=""
}

mutate_batch_end_entry() {
  [[ -n "${BATCH_ENTRY_SEEN}" ]] || return 0
  [[ -n "${BATCH_ENTRY_FILE}" ]] \
    || mutate_batch_refuse "the entry starting at line ${BATCH_ENTRY_START} has no file: line."
  [[ -n "${BATCH_ENTRY_PERL}" ]] \
    || mutate_batch_refuse "the entry starting at line ${BATCH_ENTRY_START} has no perl: line."
  [[ -f "${BATCH_ENTRY_FILE}" ]] \
    || mutate_batch_refuse "the entry starting at line ${BATCH_ENTRY_START} names ${BATCH_ENTRY_FILE}, and there is no file there."
  BATCH_LABELS+=("${BATCH_ENTRY_LABEL:-${BATCH_ENTRY_FILE##*/} ${BATCH_ENTRY_PERL}}")
  BATCH_FILES+=("${BATCH_ENTRY_FILE}")
  # One argument per line: the format is line based, so no value can hold a newline.
  BATCH_ARGS+=("${BATCH_ENTRY_FLAGS}${BATCH_ENTRY_FILE}"$'\n'"${BATCH_ENTRY_PERL}")
  BATCH_VERDICTS+=("NOT RUN")
  BATCH_LOGS+=("")
  mutate_batch_reset_entry
}

# One value after "<key>: ", refusing an empty one, since an empty aim or path is never what was meant.
mutate_batch_value() {
  local line_no="$1" line="$2" key="$3" value
  value="${line#"${key}: "}"
  [[ -n "${value}" ]] || mutate_batch_refuse "line ${line_no} gives ${key} an empty value."
  printf '%s' "${value}"
}

mutate_batch_parse() {
  local batch_file="$1" line line_no=0 value
  mutate_batch_reset_entry
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$(( line_no + 1 ))
    if [[ -z "${line//[[:space:]]/}" ]]; then
      mutate_batch_end_entry
      continue
    fi
    [[ "${line}" == \#* ]] && continue
    [[ -n "${BATCH_ENTRY_SEEN}" ]] || BATCH_ENTRY_START="${line_no}"
    BATCH_ENTRY_SEEN="yes"
    case "${line}" in
      "breaks-the-build")
        BATCH_ENTRY_FLAGS="${BATCH_ENTRY_FLAGS}--breaks-the-build"$'\n'
        ;;
      "label: "*)
        [[ -z "${BATCH_ENTRY_LABEL}" ]] || mutate_batch_refuse "line ${line_no} is a second label: in one entry."
        BATCH_ENTRY_LABEL="$(mutate_batch_value "${line_no}" "${line}" label)" || exit 2
        ;;
      "file: "*)
        [[ -z "${BATCH_ENTRY_FILE}" ]] || mutate_batch_refuse "line ${line_no} is a second file: in one entry. Each entry breaks one file."
        BATCH_ENTRY_FILE="$(mutate_batch_value "${line_no}" "${line}" file)" || exit 2
        ;;
      "perl: "*)
        [[ -z "${BATCH_ENTRY_PERL}" ]] || mutate_batch_refuse "line ${line_no} is a second perl: in one entry. Each entry is one mutation."
        BATCH_ENTRY_PERL="$(mutate_batch_value "${line_no}" "${line}" perl)" || exit 2
        ;;
      "at: "*)
        value="$(mutate_batch_value "${line_no}" "${line}" at)" || exit 2
        BATCH_ENTRY_FLAGS="${BATCH_ENTRY_FLAGS}--at"$'\n'"${value}"$'\n'
        ;;
      "at-regex: "*)
        value="$(mutate_batch_value "${line_no}" "${line}" at-regex)" || exit 2
        BATCH_ENTRY_FLAGS="${BATCH_ENTRY_FLAGS}--at-regex"$'\n'"${value}"$'\n'
        ;;
      *)
        mutate_batch_refuse "line ${line_no} is not a line this format has: ${line}
  The keys are label, file, perl, at and at-regex (each followed by a colon and one space), and
  breaks-the-build on a line of its own. The test scope goes on the command line, after the file."
        ;;
    esac
  done < "${batch_file}"
  mutate_batch_end_entry
}

# What must be identical before and after an entry: the file's bytes, and when it is in a repository, that
# repository's status and unstaged diff. So a run that wrote anywhere else in the tree stops the batch too.
mutate_batch_tree_state() {
  local target="$1" dir
  dir="$(cd "$(dirname "${target}")" 2>/dev/null && pwd)"
  cksum < "${target}" 2>&1
  if [[ -n "${dir}" ]] && git -C "${dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${dir}" status --porcelain=v1 --untracked-files=all 2>&1
    git -C "${dir}" diff --no-ext-diff 2>&1 | cksum
  fi
}

# The verdict the single form printed: its last line that opens with capitals and " - ", which is the
# shape of every outcome it has (CAUGHT - ..., LANDED ELSEWHERE - ...). Read by shape rather than from a
# list, so an outcome added to the single form later is carried through rather than lost (L41). Indented
# lines never count, which is how the run log's own tail is printed.
mutate_batch_verdict_of() {
  local transcript="$1" status="$2" verdict
  verdict="$(grep -E '^[A-Z][A-Z ]*[A-Z] - ' "${transcript}" 2>/dev/null | tail -n 1 | sed 's/ - .*//')"
  # The two results must arrive with the exit status the single form gives them, or the reading is off.
  case "${verdict}:${status}" in
    CAUGHT:0|SURVIVED:1|READY:0) echo "${verdict}" ;;
    CAUGHT:*|SURVIVED:*|READY:*|:*) echo "NO VERDICT (exit ${status}${verdict:+, printed ${verdict}})" ;;
    *) echo "${verdict}" ;;
  esac
}

mutate_batch_print_summary() {
  local index verdict
  [[ -z "${BATCH_SUMMARY_PRINTED}" ]] || return 0
  BATCH_SUMMARY_PRINTED="yes"
  echo
  echo "batch summary, ${#BATCH_LABELS[@]} entr$([[ ${#BATCH_LABELS[@]} -eq 1 ]] && echo y || echo ies):"
  for (( index = 0; index < ${#BATCH_LABELS[@]}; index++ )); do
    verdict="${BATCH_VERDICTS[index]}"
    # Checked and ready but never reached, because the batch stopped first.
    [[ "${verdict}" == "READY" ]] && verdict="NOT RUN"
    printf '  %s  %s  %s\n' "$(( index + 1 ))" "${verdict}" "${BATCH_LABELS[index]}"
    if [[ -n "${BATCH_LOGS[index]}" ]]; then
      echo "      log: ${BATCH_LOGS[index]}"
    fi
  done
  [[ -n "${BATCH_STOP_REASON}" ]] && echo "  ${BATCH_STOP_REASON}"
  return 0
}

# Ends the entry in flight: its whole process group, so the single form AND the runner beneath it see the
# signal, and the runner's own handler ends its xcodebuild and releases its file lock. Bounded, then KILL,
# because a wait with no deadline can only hang (L110).
mutate_batch_end_child() {
  local pid="${BATCH_CHILD_PID}" waited=0
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || return 0
  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null
    while kill -0 "${pid}" 2>/dev/null && [[ "${waited}" -lt 300 ]]; do
      sleep 0.1
      waited=$(( waited + 1 ))
    done
    kill -KILL -- "-${pid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null
  BATCH_CHILD_PID=""
  return 0
}

mutate_batch_on_exit() {
  mutate_batch_end_child
  release_dir_lock
  if [[ "${BATCH_LOCK_PHASE}" == "waiting" ]]; then
    BATCH_STOP_REASON="The batch stopped while waiting for the shared test lock, so no entry reached the runner."
  fi
  [[ ${#BATCH_LABELS[@]} -gt 0 ]] && mutate_batch_print_summary
  [[ -n "${BATCH_BACKUP_DIR}" ]] && rm -rf "${BATCH_BACKUP_DIR}"
  return 0
}

mutate_batch_on_signal() {
  local code="$1" index="${BATCH_CURRENT}" target backup
  trap '' INT TERM
  mutate_batch_end_child
  if [[ -n "${index}" ]]; then
    target="${BATCH_FILES[index]}"
    backup="${BATCH_BACKUP_DIR}/entry-${index}"
    BATCH_VERDICTS[index]="INTERRUPTED"
    if [[ -f "${backup}" ]] && ! cmp -s "${backup}" "${target}"; then
      if cp "${backup}" "${target}" 2>/dev/null; then
        echo "batch: entry $(( index + 1 )) left ${target} changed, so the batch put it back from its own copy."
      else
        echo "batch: entry $(( index + 1 )) left ${target} changed and it could NOT be put back. It is as the run left it."
        keep_untouched_copy "${index}"
      fi
    fi
  fi
  BATCH_STOP_REASON="Interrupted: the entry in flight was ended, the shared lock released, and nothing after it ran."
  exit "${code}"
}

keep_untouched_copy() {
  local index="$1" dir kept
  dir="${OVERTURE_MUTATE_LOG_DIR:-/tmp/overture-mutate-runs}"
  mkdir -p "${dir}" 2>/dev/null
  kept="$(mktemp "${dir}/untouched-${BATCH_FILES[index]##*/}.XXXXXX" 2>/dev/null)" \
    && cp "${BATCH_BACKUP_DIR}/entry-${index}" "${kept}" 2>/dev/null \
    && echo "  untouched copy: ${kept}"
}

# The single form, as a job in a process group of its own, output to a file of the batch's.
mutate_batch_child() {
  local out="$1"; shift
  trap - EXIT INT TERM
  exec "$@" > "${out}" 2>&1 < /dev/null
}

mutate_batch_transcript_path() {
  local dir="${OVERTURE_MUTATE_LOG_DIR:-/tmp/overture-mutate-runs}"
  mkdir -p "${dir}" 2>/dev/null || return 1
  mktemp "${dir}/$(date +%Y%m%d-%H%M%S)-mutate.batch-$1.XXXXXX" 2>/dev/null
}

# mutate_batch_main <path to mutate.sh> <batch file> [test-scope ...]
mutate_batch_main() {
  local mutate_script="$1"; shift
  local batch_file="${1:-}"
  local index args arg transcript status verdict before after started ready=0 took_lock=""
  local results_caught=0 results_survived=0 no_result=0

  if [[ -z "${batch_file}" || "${batch_file}" == -* ]]; then
    mutate_batch_usage
    exit 2
  fi
  shift
  if [[ ! -f "${batch_file}" ]]; then
    echo "mutate: no batch file at ${batch_file}"
    exit 2
  fi
  if [[ -n "${OVERTURE_MUTATE_LOG:-}" ]]; then
    echo "MALFORMED BATCH - OVERTURE_MUTATE_LOG is set, so every entry would write the same log and each"
    echo "  would overwrite the one before. Unset it: every entry then gets a log of its own and the summary"
    echo "  names each one."
    exit 2
  fi

  # #4568: a scope written without its `-only-testing:` prefix. Measured 2026-10-07: one passed bare here ran
  # the whole pure suite for 16 minutes on the shared lock. The single form refuses it too, but the scope is
  # SHARED by every entry, so it is refused once, here, before an entry is read, checked or queued for,
  # rather than once per entry in the check below. Same rule and same words as the single form.
  local bare_scope
  if [[ -z "${OVERTURE_MUTATE_RUNNER:-}" ]] && bare_scope="$(bare_test_scope "$@")"; then
    echo "BARE SCOPE - ${bare_scope} was passed as a test scope without its -only-testing: prefix."
    echo
    echo "  Write it as:"
    echo "  $(bare_test_scope_corrected "${bare_scope}")"
    echo
    echo "  Nothing was mutated, no entry was checked, and the shared test lock was not queued for. Handed to"
    echo "  the Swift runner bare, xcodebuild reads it as a build action it does not know and fails, the runner"
    echo "  reads that as a crash, and it then runs the WHOLE pure suite, about 24 minutes, holding that lock."
    exit 2
  fi

  mutate_batch_parse "${batch_file}"
  if [[ ${#BATCH_LABELS[@]} -eq 0 ]]; then
    echo "EMPTY BATCH - ${batch_file} holds no entry, so nothing was mutated and nothing was run."
    echo "  Refused rather than reported: zero mutations proved is not a batch that passed (L98)."
    exit 2
  fi

  BATCH_BACKUP_DIR="$(overture_scratch_dir mutate-batch)"
  trap 'mutate_batch_on_exit' EXIT
  trap 'mutate_batch_on_signal 130' INT
  trap 'mutate_batch_on_signal 143' TERM

  # --- 1. every entry checked before the queue ---------------------------------------------------------
  echo "batch: checking ${#BATCH_LABELS[@]} entries before queueing for anything"
  for (( index = 0; index < ${#BATCH_LABELS[@]}; index++ )); do
    args=()
    while IFS= read -r arg; do args+=("${arg}"); done <<< "${BATCH_ARGS[index]}"
    transcript="$(overture_scratch_file mutate-batch-check)"
    before="$(mutate_batch_tree_state "${BATCH_FILES[index]}")"
    OVERTURE_MUTATE_PREFLIGHT_ONLY=1 "${mutate_script}" "${args[@]}" "$@" > "${transcript}" 2>&1 < /dev/null
    status=$?
    after="$(mutate_batch_tree_state "${BATCH_FILES[index]}")"
    verdict="$(mutate_batch_verdict_of "${transcript}" "${status}")"
    if [[ "${before}" != "${after}" ]]; then
      cat "${transcript}"
      rm -f "${transcript}"
      BATCH_VERDICTS[index]="RESTORE FAILED"
      BATCH_STOP_REASON="STOPPED: checking entry $(( index + 1 )) left the tree changed, so nothing was run. It is left as it is for a person."
      echo "RESTORE FAILED - checking entry $(( index + 1 )) left ${BATCH_FILES[index]} or its repository changed."
      exit 3
    fi
    if [[ "${verdict}" == "READY" ]]; then
      BATCH_VERDICTS[index]="READY"
      ready=$(( ready + 1 ))
    else
      echo
      echo "batch: entry $(( index + 1 )) (${BATCH_LABELS[index]}) is refused, and the others go on:"
      cat "${transcript}"
      BATCH_VERDICTS[index]="${verdict}"
      no_result=$(( no_result + 1 ))
    fi
    rm -f "${transcript}"
  done

  if [[ "${ready}" -eq 0 ]]; then
    BATCH_STOP_REASON="Every entry was refused, so there was nothing to run and no shared lock was taken."
    exit 2
  fi

  # --- 2. the lock, once, and only for the Swift runner --------------------------------------------------
  if [[ -z "${OVERTURE_MUTATE_RUNNER:-}" ]]; then
    BATCH_LOCK_PHASE="waiting"
    echo "batch: ${ready} entr$([[ ${ready} -eq 1 ]] && echo y || echo ies) ready, queueing ONCE for the shared test lock ${DIR_LOCK}"
    take_dir_lock
    BATCH_LOCK_PHASE="held"
    # Took it ourselves, or are running under an ancestor's hold (a batch inside a batch), which
    # take_dir_lock has just verified and which every child inherits unchanged.
    if [[ -n "${DIR_LOCK_HELD}" ]]; then
      took_lock="yes"
      export OVERTURE_TEST_LOCK_HELD_BY="$$"
    fi
    echo "batch: holding ${DIR_LOCK} for the whole batch$([[ -z "${took_lock}" ]] && echo ", under the hold of PID ${OVERTURE_TEST_LOCK_HELD_BY}")."
  else
    echo "batch: the runner is ${OVERTURE_MUTATE_RUNNER}, not the Swift suite, so the batch takes no shared test lock."
  fi

  # --- 3. each ready entry in turn, restored and verified before the next ---------------------------------
  for (( index = 0; index < ${#BATCH_LABELS[@]}; index++ )); do
    [[ "${BATCH_VERDICTS[index]}" == "READY" ]] || continue
    args=()
    while IFS= read -r arg; do args+=("${arg}"); done <<< "${BATCH_ARGS[index]}"
    transcript="$(mutate_batch_transcript_path "$(( index + 1 ))")" || transcript="$(overture_scratch_file mutate-batch-run)"
    cp "${BATCH_FILES[index]}" "${BATCH_BACKUP_DIR}/entry-${index}"
    before="$(mutate_batch_tree_state "${BATCH_FILES[index]}")"
    started="${SECONDS}"
    BATCH_VERDICTS[index]="RUNNING"
    echo
    echo "batch: entry $(( index + 1 )) of ${#BATCH_LABELS[@]} (${BATCH_LABELS[index]}) started at $(date +%H:%M:%S)."
    echo "  Its output is going to ${transcript}, printed here when it ends."
    BATCH_CURRENT="${index}"
    start_own_group_job mutate_batch_child "${transcript}" "${mutate_script}" "${args[@]}" "$@"
    BATCH_CHILD_PID="${OWN_GROUP_JOB_PID}"
    status=0
    wait "${BATCH_CHILD_PID}" || status=$?
    BATCH_CHILD_PID=""
    BATCH_CURRENT=""
    cat "${transcript}"
    verdict="$(mutate_batch_verdict_of "${transcript}" "${status}")"
    BATCH_VERDICTS[index]="${verdict}"
    BATCH_LOGS[index]="$(sed -n 's/^  full log: //p' "${transcript}" | tail -n 1)"
    echo "batch: entry $(( index + 1 )) finished after $(( SECONDS - started ))s: ${verdict}."
    case "${verdict}" in
      CAUGHT) results_caught=$(( results_caught + 1 )) ;;
      SURVIVED) results_survived=$(( results_survived + 1 )) ;;
      *) no_result=$(( no_result + 1 )) ;;
    esac

    after="$(mutate_batch_tree_state "${BATCH_FILES[index]}")"
    if [[ "${before}" != "${after}" ]]; then
      BATCH_VERDICTS[index]="${verdict}, then RESTORE FAILED"
      echo
      echo "RESTORE FAILED - after entry $(( index + 1 )), ${BATCH_FILES[index]} or its repository is not as it was."
      echo "  The batch stops HERE and leaves the tree exactly as it is, for a person: every later entry would"
      echo "  otherwise be judged against a tree nobody meant to test. What differs from the file as it was:"
      diff "${BATCH_BACKUP_DIR}/entry-${index}" "${BATCH_FILES[index]}" 2>&1 | head -n 40 | sed 's/^/    /'
      keep_untouched_copy "${index}"
      BATCH_STOP_REASON="STOPPED after entry $(( index + 1 )): the tree was not restored, so nothing after it ran."
      exit 3
    fi
    rm -f "${BATCH_BACKUP_DIR}/entry-${index}"
  done

  [[ -n "${took_lock}" ]] && release_dir_lock
  if [[ "${no_result}" -gt 0 ]]; then
    exit 2
  fi
  if [[ "${results_survived}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}
