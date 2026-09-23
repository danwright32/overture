#!/usr/bin/env bash
set -uo pipefail

# #3888: record the main thread DURING a freeze, and keep only what lines up with a logged stall.
#
# WHY IT EXISTS. `scripts/what-froze-the-queue.sh` reads the app's own record of a stall: that one
# happened, how long it was, and how many render passes it spanned. None of that says what the main
# thread was DOING, and a stall is over before anybody can start a `sample` by hand: about a minute,
# measured 2026-08-30 on #3419. On 2026-09-13 the only reading of the scout freezes was a macOS
# microstackshot of 22 samples, which detects rather than measures (L355). A throwaway script built in
# that session caught the next ones inside minutes and settled #3884 (up to 100% of main thread samples
# in `ScoutService.apply`), then was deleted with the session that wrote it. This is that script, with
# its seams named so every one of its outcomes can be produced in a fixture rather than waited for.
#
# HOW TO READ ITS ANSWER. Four outcomes, and the quiet one is the one to be careful with:
#
#   0  the watch ran to its end. It says how many samples it kept, and `kept 0` is a real reading:
#      it watched, and no stall reached the keep threshold. That is NOT the same fact as not having
#      watched, which is why it is said in words rather than left as silence (L98, L11).
#   2  REFUSED. It could not name exactly one running Overture, or could not write where it was told.
#      Nothing was watched.
#   3  the app went away mid-watch, naming the pid it lost. Whatever it kept before that is kept.
#
# WHAT A KEPT SAMPLE CAN AND CANNOT SAY. It is a SAMPLE: it shows the SHAPE of the stack, and it
# measures cost only once the sample count is read (L355). The one line reading printed beside each
# kept chunk therefore always prints the main thread's total sample count next to the share, and says
# UNREADABLE rather than a share when it cannot find a main thread block at all. A zero share and a
# sample whose symbols never resolved look identical, and folding them together would make the emptiest
# possible reading the most reassuring one.
#
# WHAT IT TOUCHES. It reads the process table, the app's freeze log, and takes stack samples. It never
# touches the screen, the keyboard or the mouse, so it does not fall under the rule about driving Dan's
# machine. It does not need `--yes` for that reason.

# #3481/L372: captured BEFORE any cd, because `$0` and `BASH_SOURCE[0]` are the path this was INVOKED
# by and re-deriving a directory from either afterwards resolves against the new working directory.
WATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/overture-pid.sh
. "${WATCH_DIR}/lib/overture-pid.sh"
# shellcheck source=./lib/scratch.sh
. "${WATCH_DIR}/lib/scratch.sh"

PGREP_CMD=""
SAMPLE_CMD="${OVERTURE_WATCH_SAMPLE_CMD:-/usr/bin/sample}"
LOG="${HOME}/Library/Application Support/Overture/freeze-log.ndjson"
# The kept samples land beside `sample-overture.sh`'s, and NOT in the scratch directory, for the reason
# that script already records: this evidence is routinely read days later, and the shared temp folder is
# cleared at boot. The throwaway chunks, which are 2 to 3.5 MB each and are deleted within seconds, DO
# go to scratch, which is what #3888 asked for and what keeps them where a leak check can see them.
OUT_DIR="${HOME}/.overture-mac-test-diagnostics/freeze-watch"
MINUTES=60
CHUNK_SECONDS=10
INTERVAL_MS=2
MAX_CHUNKS=""
# A stall at least this long is worth a stack sample. From the scratch version, where it separated the
# freezes worth reading from the sub-second churn around them.
KEEP_SECONDS=3
# Every new record is reported. The watchdog's own floor is what bounds the noise here (#3752 put it at
# 100 ms), so a second threshold in this script would be a filter nobody asked for sitting in front of
# the evidence.
REPORT_SECONDS=0
# The watchdog writes a record when the stall ENDS (`MainThreadWatchdog.swift`, `at: ran`), so the stall
# itself occupies roughly `at - seconds` to `at`. The padding either side covers the gap between the
# stall ending and the record being written, and a chunk that only clips the edge of the freeze.
WINDOW_PAD_SECONDS=12
# Which records count as new. The default is the instant the watch starts, so a log holding months of
# history does not print months of history the moment this runs. It is an ARGUMENT because the other
# setting is genuinely wanted: a person who has just watched the app freeze wants the record that is
# already in the log judged too, and a fixture needs to be able to produce a stall without waiting for
# the app to have one.
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) MINUTES="${2:-}"; shift 2 ;;
    --chunks) MAX_CHUNKS="${2:-}"; shift 2 ;;
    --chunk-seconds) CHUNK_SECONDS="${2:-}"; shift 2 ;;
    --interval-ms) INTERVAL_MS="${2:-}"; shift 2 ;;
    --keep-seconds) KEEP_SECONDS="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --log) LOG="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --pgrep) PGREP_CMD="${2:-}"; shift 2 ;;
    --sample-cmd) SAMPLE_CMD="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: $(basename "$0") [--minutes N] [--chunks N] [--chunk-seconds N] [--interval-ms N]"
      echo "                        [--keep-seconds N] [--out DIR] [--log PATH] [--since ISO8601]"
      echo "  Rolling stack samples of the live Overture, kept only where the app's own freeze log"
      echo "  records a stall of at least --keep-seconds. Reads the process and the log; never touches"
      echo "  the screen, keyboard or mouse."
      echo "  0  the watch ran to its end, and says how many samples it kept"
      echo "  2  REFUSED: not exactly one Overture, or nowhere to write"
      echo "  3  the app went away mid-watch"
      exit 0 ;;
    *)
      # Refused rather than ignored: an argument silently dropped is indistinguishable from one that
      # was honoured (#3245).
      echo "REFUSED: unknown argument '$1'."
      echo "         Run with --help for what it takes."
      exit 2 ;;
  esac
done

APP_PID="$(overture_resolve_pid "${PGREP_CMD}")"
if [ $? -ne 0 ]; then
  echo "REFUSED: ${APP_PID}"
  echo "         Nothing was watched and nothing was sampled."
  exit 2
fi

if ! mkdir -p "${OUT_DIR}" 2>/dev/null; then
  echo "REFUSED: could not create ${OUT_DIR}, so there is nowhere to keep a sample."
  exit 2
fi
WORKING="$(overture_scratch_dir overture-freeze-watch)"
trap 'rm -rf "${WORKING}"' EXIT

if [ ! -f "${LOG}" ]; then
  echo "FREEZE LOG ABSENT at ${LOG}."
  echo "  The watch runs anyway, because the app may write its first record while it is running, but"
  echo "  until one appears nothing can qualify a chunk and every one of them is thrown away."
fi

if [ -n "${SINCE}" ]; then
  printf '%s' "${SINCE}" > "${WORKING}/seen-until.txt"
  echo "JUDGING records after ${SINCE}, rather than only those written from now on."
else
  date -u +%Y-%m-%dT%H:%M:%SZ > "${WORKING}/seen-until.txt"
fi
echo "WATCHING Overture pid ${APP_PID} in ${CHUNK_SECONDS}s chunks at ${INTERVAL_MS}ms, keeping what"
echo "  overlaps a stall of ${KEEP_SECONDS}s or more. Output ${OUT_DIR}."

END=$(( $(date +%s) + MINUTES * 60 ))
CHUNKS_TAKEN=0
while :; do
  [ "$(date +%s)" -lt "${END}" ] || break
  if [ -n "${MAX_CHUNKS}" ] && [ "${CHUNKS_TAKEN}" -ge "${MAX_CHUNKS}" ]; then break; fi
  if ! kill -0 "${APP_PID}" 2>/dev/null; then
    echo "WATCH ENDED: Overture pid ${APP_PID} is gone (quit or crashed)."
    echo "  Samples kept before that: $(ls "${OUT_DIR}"/KEPT-* 2>/dev/null | grep -c . )."
    exit 3
  fi
  START=$(date +%s)
  CHUNK="${WORKING}/chunk-${START}.txt"
  # The real interface, checked against /usr/bin/sample itself:
  #   sample <pid> [duration [samplingInterval]] [options...] [-file <filename>]
  # The output path is NOT positional: passed as one, the real tool reads it as the sampling interval.
  if ! "${SAMPLE_CMD}" "${APP_PID}" "${CHUNK_SECONDS}" "${INTERVAL_MS}" -mayDie -file "${CHUNK}" \
      >/dev/null 2>"${WORKING}/sample-err.txt"; then
    echo "SAMPLE FAILED for the chunk starting $(date -r "${START}" +%H:%M:%S): $(tail -1 "${WORKING}/sample-err.txt" 2>/dev/null)"
  fi
  CHUNKS_TAKEN=$(( CHUNKS_TAKEN + 1 ))

  python3 - "${LOG}" "${WORKING}" "${OUT_DIR}" "${CHUNK_SECONDS}" "${KEEP_SECONDS}" \
      "${REPORT_SECONDS}" "${WINDOW_PAD_SECONDS}" <<'PY'
import glob, json, os, shutil, sys, time
from datetime import datetime

log, working, out, chunk_seconds, keep, report, pad = sys.argv[1:8]
chunk_seconds, keep, report, pad = float(chunk_seconds), float(keep), float(report), float(pad)
state = os.path.join(working, "seen-until.txt")

# A frame carrying at least this share of the main thread's samples is worth naming. The DEEPEST such
# frame is the one reported: every frame above it carries at least as much by construction, so the
# outermost one is always near 100% and says nothing (L355).
HOT_SHARE = 0.5


def epoch(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


# #4103: is this line the MAIN THREAD's own block header?
#
# TWO SPELLINGS, because macOS writes two and both are live on this Mac. `sample` labels the block
# `com.apple.main-thread` only while the thread sat on the main dispatch queue for the WHOLE sample.
# A freeze is exactly the case where it did not, so on 2026-09-21 every sample this tool kept (four of
# them, covering 0.93s and 3.31s stalls) was reported `UNREADABLE, no main thread block in this
# sample` while the block was there all along, labelled:
#
#     4008 Thread_50084685: Main Thread   DispatchQueue_<multiple>
#
# Counted across the samples still on disk: that shape appears 484 times and `com.apple.main-thread`
# not once. The old spelling is KEPT rather than replaced, because the samples an older macOS wrote
# are still here and are the only record of the freezes they cover; swapping one for the other would
# move the blindness to the archive instead (L26, L255).
#
# ANCHORED TO THE HEADER SHAPE, and that is the half a looser match gets wrong. Frame lines carry the
# same `<count> <label>` shape as a header, and real samples hold frames named `renderOnMainThread`,
# `withMainThreadRender` and `__NSOPERATION_IS_INVOKING_MAIN__`. A matcher that took one of those
# would report a frame's own sample count as the whole main thread's, which reads as a measurement
# rather than as a tool that could not find the thread (L11). Only a header begins `Thread_`.
def is_main_thread_header(label):
    if not label.startswith("Thread_"):
        return False
    return "com.apple.main-thread" in label or "Main Thread" in label


def read_one_line(path):
    """What this sample says about the main thread, in one line, or why it cannot say (L98)."""
    try:
        with open(path) as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        return f"UNREADABLE, {type(exc).__name__} opening the file"

    header_indent = None
    total = None
    best = None
    for line in lines:
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        parts = stripped.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        count, label = int(parts[0]), parts[1]
        if header_indent is None:
            if is_main_thread_header(label):
                header_indent, total = indent, count
            continue
        if indent <= header_indent:
            break
        if total and "(in Overture)" in label and count >= HOT_SHARE * total:
            frame = label.split("  (in Overture)")[0].strip()
            if best is None or indent > best[0]:
                best = (indent, frame, count)

    if total is None:
        return "UNREADABLE, no main thread block in this sample"
    if best is None:
        return (f"{total} main thread samples, and no frame of Overture's own carries "
                f"{int(HOT_SHARE * 100)}% of them")
    _, frame, count = best
    return (f"{total} main thread samples, deepest frame over {int(HOT_SHARE * 100)}% is "
            f"{frame} at {count} ({100 * count / total:.0f}%)")


seen = open(state).read().strip()
windows = []
try:
    with open(log) as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
except FileNotFoundError:
    rows = []
except ValueError as exc:
    print(f"FREEZE LOG UNREADABLE: {type(exc).__name__}: {exc}", flush=True)
    rows = []

new = [r for r in rows if str(r.get("at", "")) > seen]
for r in new:
    seconds = r.get("seconds", 0)
    if seconds >= report:
        local = datetime.fromtimestamp(epoch(r["at"])).strftime("%H:%M:%S")
        cost = r.get("passSeconds")
        print("STALL {} {:.2f}s on {} passes={} passSeconds={} load={}".format(
            local, seconds, r.get("surface"), r.get("passes"),
            "?" if cost is None else round(cost, 2),
            round(r.get("loadAverage") or 0, 1)), flush=True)
    if seconds >= keep:
        at = epoch(r["at"])
        windows.append((at - seconds - pad, at + pad, seconds))
if new:
    open(state, "w").write(max(str(r.get("at", "")) for r in new))

for path in sorted(glob.glob(os.path.join(working, "chunk-*.txt"))):
    start = int(os.path.basename(path)[6:-4])
    covered = [s for a, b, s in windows if start < b and start + chunk_seconds > a]
    if not covered:
        continue
    kept = os.path.join(out, "KEPT-" + os.path.basename(path))
    shutil.move(path, kept)
    print(f"KEPT {os.path.basename(kept)} covering a {max(covered):.2f}s stall", flush=True)
    print(f"  reading: {read_one_line(kept)}", flush=True)

# The newest few chunks are kept unjudged: a stall's record lands only once the stall has ENDED, so a
# chunk taken during one is judged by a record that does not exist yet. Deleting on age rather than on
# position, because the position of the newest chunk says nothing about how long ago it was taken.
for path in sorted(glob.glob(os.path.join(working, "chunk-*.txt")))[:-3]:
    if time.time() - int(os.path.basename(path)[6:-4]) > 90:
        os.remove(path)
PY
done

KEPT_COUNT="$(ls "${OUT_DIR}"/KEPT-* 2>/dev/null | grep -c . )"
echo "WATCH FINISHED after ${CHUNKS_TAKEN} chunk(s); kept ${KEPT_COUNT} sample(s) in ${OUT_DIR}."
if [ "${KEPT_COUNT}" -eq 0 ]; then
  echo "  kept 0 means it watched and no stall reached ${KEEP_SECONDS}s, which is a reading."
  echo "  It is not the same as having measured nothing: the chunks were taken and thrown away."
fi
exit 0
