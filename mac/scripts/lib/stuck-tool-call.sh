#!/bin/sh
# #3007: how long ONE tool call has been in flight, so a single stuck web request cannot hold a paid run
# for twenty minutes.
#
# WHAT WENT WRONG (measured 2026-08-20, #2762's session 2). Chunk 10 of a reachability check sat on a
# single WebFetch for the whole run. The worker was ALIVE and reporting throughout, so nothing downstream
# could tell a stuck request from slow work: the run-level stall guard reads whether RESULTS are landing,
# and a worker waiting on one page is not stalled by that definition until its whole run is. The only
# thing that ended it was PREP_STALL_LIMIT_SECONDS at 1200. The run lost its thirteenth show anyway, and
# exited 1 with `runCost.recorded: false`, so its cost and duration were unusable too.
#
# WHAT IT KEYS ON, and why not what the issue proposed. #3007 says to key on
# `tool_progress.elapsed_time_seconds`. Measured on this Mac 2026-08-21: there is not one `tool_progress`
# event in ANY events file or run archive on disk. Branching on a field arriving from outside the system
# before its presence has been measured is L506 exactly, and it would have produced a watchdog that never
# fires while reading like an active safeguard.
#
# So it keys on what every stream here demonstrably carries: each event's own `timestamp`, and the
# `tool_use` / `tool_result` blocks inside the messages. A call whose `tool_use` has no matching
# `tool_result` yet is IN FLIGHT, and its elapsed time is the clock minus its own start. That is the
# request's own elapsed time, which is what the issue asked for, taken from a field that exists.
#
# THE NUMBERS THE LIMIT COMES FROM. Every archived run on this Mac, 357 real tool calls:
#
#   WebFetch     n=128  median 2.0s   p90 3.7s   max 7.4s
#   WebSearch    n=106  median 5.2s   p90 6.4s   max 8.5s
#   everything else                              max 4.8s
#   over 60s: 0.  over 120s: 0.  over 300s: 0.
#
# So the default sits about twenty times the slowest call ever recorded here, nowhere near the dense part
# of the distribution (L172), while still ending a stuck request in minutes rather than in twenty of them.

# The longest tool call currently IN FLIGHT in an events file, in whole seconds.
#
# Prints -1 for "cannot tell", never 0, and the difference is the point: no node, no file, or an
# unreadable stream are not the same as a healthy worker, and folding them together is how a watchdog
# reports health for a run it never looked at (L98).
stuck_tool_call_seconds() {
  _events="$1"
  _now="$2"
  [ -f "$_events" ] || { echo "-1"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "-1"; return 0; }
  node -e '
    // Wrapped in an IIFE for `record_web_calls`'"'"'s reason: `node -e` runs at top level, where a bare
    // `return` is a SyntaxError, and the early exits below are what keep "cannot tell" separate from 0.
    (function () {
    const fs = require("fs");
    const [file, nowRaw] = process.argv.slice(1);
    const now = Number(nowRaw) * 1000;
    let text;
    try { text = fs.readFileSync(file, "utf8"); } catch (e) { console.log("-1"); return; }
    // Started but not returned. A partial last line is normal: the stream is being appended to while
    // this reads it, so an unparsable line is skipped rather than treated as a broken file.
    const open = new Map();
    let parsed = 0;
    for (const line of text.split("\n")) {
      if (!line.startsWith("{")) continue;
      let e;
      try { e = JSON.parse(line); } catch (err) { continue; }
      parsed += 1;
      const at = Date.parse(e.timestamp ?? "");
      const blocks = (e.message && e.message.content) || [];
      if (!Array.isArray(blocks)) continue;
      for (const b of blocks) {
        if (!b || typeof b !== "object") continue;
        if (b.type === "tool_use" && Number.isFinite(at)) open.set(b.id, at);
        if (b.type === "tool_result") open.delete(b.tool_use_id);
      }
    }
    // A stream with nothing parsable in it is not a stream with nothing happening in it.
    if (parsed === 0) { console.log("-1"); return; }
    let longest = 0;
    for (const startedAt of open.values()) {
      const elapsed = Math.floor((now - startedAt) / 1000);
      if (elapsed > longest) longest = elapsed;
    }
    console.log(String(longest));
    })();
  ' "$_events" "$_now" 2>/dev/null || echo "-1"
}

# How long one request may hold a chunk. Twenty times the slowest tool call ever recorded on this Mac
# (8.5s, over 357 of them), so a legitimately slow page has enormous headroom, and about seven times
# faster than the run-level stop that used to be the only thing that ended one.
STUCK_TOOL_CALL_LIMIT="${OVERTURE_STUCK_TOOL_CALL_LIMIT_SECONDS:-180}"
STUCK_TOOL_CALL_POLL="${OVERTURE_STUCK_TOOL_CALL_POLL_SECONDS:-15}"

# #3357 Phase 1.5: RECORD a kill as well as saying it.
#
# The notice above is a durable control whose only trace was a terminal window that closes (L148), and a
# killed chunk is a confound in every later comparison between runs: its items settle as unfinished
# rather than as negatives, so a run offered as evidence has to be able to report zero kills or be
# discarded. Nothing else on disk says a kill happened at all.
#
# ONE LINE OF JSON PER KILL, appended, with NO parsing of the stream here. The item a chunk died on is
# derivable from what that chunk had already written, and `record_item_attribution` in `models.sh`
# already walks every stream and computes exactly that. A second walk here would be one question with
# two implementations, free to drift, which is the defect #3443 removed one file over (L263). This
# records WHEN and WHICH CHUNK; the attribution pass folds in WHICH ITEMS after the run.
#
# Append-only text rather than a rewritten document, deliberately: this runs beside a paid run that is
# already going wrong, several chunks can be killed, and a read-modify-write whose read fails would
# erase the earlier kills at exactly the moment they matter (L105).
record_watchdog_kill() {
  [ -n "${SLOT_WATCHDOG_KILLS:-}" ] || return 0
  printf '{"chunk":%s,"requestInFlightSeconds":%s,"at":"%s"}\n' \
    "$1" "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${SLOT_WATCHDOG_KILLS}" 2>/dev/null || true
}

# stuck_watchdog_run <chunk-count> <chunk-pids>: watch each chunk's own event stream and kill the ONE
# chunk whose current tool call has been in flight past the limit.
#
# The pids arrive in the order the chunks were launched, which is how a stuck STREAM is matched to a
# process to stop. Nothing here is fatal: a chunk that has already exited, a stream that cannot be read,
# and a kill that finds nothing are all ordinary, and this runs beside a paid run where killing the wrong
# thing costs real money.
#
# "Cannot tell" is said ONCE and then left alone. It is not silence (a watchdog reporting nothing is
# indistinguishable from one that is working, L98) and it is not a repeated warning either, which is how
# a real one gets scrolled past (L36).
stuck_watchdog_run() {
  _count="$1"
  _pids="$2"
  _unreadable_said=0
  while :; do
    sleep "$STUCK_TOOL_CALL_POLL"
    _now="$(date +%s)"
    _k=1
    for _pid in $_pids; do
      [ "$_k" -le "$_count" ] || break
      # A chunk that has already finished is not stuck, and its pid may since belong to something else.
      if kill -0 "$_pid" 2>/dev/null; then
        _elapsed="$(stuck_tool_call_seconds "$(slot_chunk_events "$_k")" "$_now")"
        # L50: never let a parsed value reach a comparison. `[ "$x" -ge n ]` on a non-numeric or EMPTY
        # value is not false, it is an error, and this whole loop runs under the runner's `set -e`, so
        # one unexpected byte on stdout would kill the watchdog silently and leave a run with no per
        # request cap at all while everything looked fine. Anything that is not a number is folded to
        # "cannot tell", which is the fail-safe side here: it declines to kill.
        case "$_elapsed" in
          ''|*[!0-9-]*|-|*-*-*) _elapsed="-1" ;;
        esac
        if [ "$_elapsed" = "-1" ]; then
          if [ "$_unreadable_said" = "0" ]; then
            echo "prep: could not read chunk $_k's event stream, so no request in it is being timed."
            _unreadable_said=1
          fi
        elif [ "$_elapsed" -ge "$STUCK_TOOL_CALL_LIMIT" ]; then
          echo "prep: STOPPING CHUNK $_k. One request has been in flight for ${_elapsed}s (limit ${STUCK_TOOL_CALL_LIMIT}s), which is far past anything this Mac has recorded, so it is not coming back. The other chunks are untouched and will finish."
          record_watchdog_kill "$_k" "$_elapsed"
          kill "$_pid" 2>/dev/null || true
        fi
      fi
      _k=$((_k + 1))
    done
  done
}
