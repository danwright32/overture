#!/usr/bin/env bash
# #804: which model each detached run uses, in ONE place.
#
# Every runner used to invoke `claude -p` with no --model flag, so it silently inherited whatever the
# Claude Code CLI default happened to be on Dan's machine that day.
#
# For the mechanical runs that was only money. For DRAFTING it was his voice: those are the words that
# reach a stranger. A CLI upgrade, a settings change or a new default tier could have altered how every
# email he sends sounds, with no code change, no commit and no warning, and nothing recorded which model
# wrote a draft, so he would have found out by noticing his emails reading differently.
#
# One file, because a model choice that is right in two scripts and wrong in the third is the same bug
# wearing a disguise.

# Drafting. Dan's call (2026-07-12): the TIER is pinned, not the exact version, so he picks up each new
# Opus as it ships. He accepted that his voice can shift with a new model in exchange for the
# improvement, and that trade is only reasonable because the model used is now RECORDED below: he can
# tell what wrote a draft rather than merely sensing that something changed.
OVERTURE_MODEL_DRAFTING="opus"

# The extraction run. It was assumed to be the cheap-fast-model case: a strict output schema, no
# judgment, just read a page for its listings. That assumption was wrong, and haiku rode on it.
#
# Dan's call (2026-07-17), after the first real watchlist scouts. On a 19-source queue, haiku read only
# the first ~6 pinned pages, then wrote "no_dated_content" for the remaining 13 WITHOUT opening them
# (confirmed from the run transcript: 6 Reads, 0 for the rest). It also made ZERO WebFetch calls the
# entire run, so it never followed an event to its own detail page for the venue, and venue-less events
# are rejected before ingest (ScoutExtractResults.swift). So even the pages it did read produced almost
# nothing usable. Reading a whole queue and following each event's link is not mechanical; it needs a
# model with the stamina to actually do it.
#
# Cost is bounded and Dan-controlled: the extraction run fires ONLY on a scout he starts. The daily
# automatic scout watches (fetch, hash, health) and spends nothing (ScoutService.swift:192), so this
# tier costs usage only on his manual scouts, never on autopilot. Chosen as the cheapest experiment
# before building queue-batching machinery: if sonnet reads the whole queue and follows detail links,
# batching is unnecessary. Measure a real run's transcript before concluding it worked.
OVERTURE_MODEL_EXTRACTION="sonnet"

# The reply run. Its NAME says classify, and for a while that is all this file heard: it sat with the
# mechanical runs above, on the cheap tier. But it also DRAFTS the reply, in Dan's voice, to somebody who
# has already written back to him. That is a warmer lead than any cold pitch, and a cold pitch gets Opus.
#
# So it is pinned to the DRAFTING tier, and pinned by REFERENCE, not by repeating the word "opus": the two
# already drifted apart once while both looked deliberate, and a copy of a value is exactly how that
# happens. Where Dan takes drafting, his replies go too.
#
# Dan's call (2026-07-13), knowing it costs more per reply: the classification is one word per item, while
# the drafting reads the runbook, invokes his brand-voice skill, and writes the email. Splitting the run
# in two would have paid a second full context load to keep the cheap half cheap, and saved almost nothing.
OVERTURE_MODEL_REPLY_CLASSIFY="${OVERTURE_MODEL_DRAFTING}"

# Records the model a run actually used, into that run's own results file.
#
# The SCRIPT records it, not the model, and that is the point: asking a model to write down which model
# it is invites it to be confidently wrong about the one fact the record exists to establish. The script
# passed --model, so the script knows.
#
# Silent on a run that produced no results file: that is already reported loudly elsewhere (the app
# treats a finished-but-empty run as a named failure), and a second complaint from here would just be
# noise on a path that is already handled.
record_model() {
  local results="$1" model="$2"
  [[ -f "${results}" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e '
    const fs = require("fs");
    const [file, model] = process.argv.slice(1);
    try {
      const json = JSON.parse(fs.readFileSync(file, "utf8"));
      json.model = model;
      fs.writeFileSync(file, JSON.stringify(json, null, 2));
    } catch (e) {
      // A results file we cannot parse is the run having failed, which is reported on its own path.
      // Losing the model stamp is not worth turning that into a second, more confusing failure.
    }
  ' "${results}" "${model}" || true
}

# #1593 (milestone 32 Phase 0.1): stamp what the run COST, from the final `result` envelope claude emits
# under --output-format stream-json. Dan asked to measure a real run before deciding how many nights he
# can select at once, and there is nowhere else that number exists.
#
# The failure path is the point. A run that died, was cancelled, or was killed mid-write leaves no result
# envelope, and a silent 0.00 there would read as "that was free" and get used to size a 66-show batch.
# So a reading that could not be taken is written as `recorded: false` with NO usd figure at all, and the
# app says "cost not recorded" rather than showing a number nobody measured.
# #1597: takes ONE OR MORE event files, because a chunked run is up to 10 concurrent claudes and each
# emits its own stream. The total is their sum; the duration is the LONGEST, since they overlap.
#
# A run where any stream reported nothing is `recorded: false` with no `usd` at all, and its partial
# figure is carried under `partialUsd` instead. That distinction is load-bearing rather than pedantic:
# the batch ceiling is sized from this number, so a partial total presented as the real one would let
# through several times the spend Dan agreed to, and it would look perfectly plausible.
record_run_cost() {
  local results="$1"
  shift
  [[ -f "${results}" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e '
    (function () {
    const fs = require("fs");
    const [file, ...eventFiles] = process.argv.slice(1);
    let json;
    try {
      json = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      // Same rule as record_model: an unparsable results file is the run having failed, reported on its
      // own path. Overwriting it would destroy the evidence of what went wrong.
      return;
    }
    const envelopeIn = (events) => {
      try {
        const lines = fs.readFileSync(events, "utf8").split("\n");
        // Walk backwards: the result envelope is last, and a killed run leaves a half-written line after
        // whatever it had already flushed.
        for (let i = lines.length - 1; i >= 0; i--) {
          const line = lines[i].trim();
          if (!line) continue;
          let parsed;
          try { parsed = JSON.parse(line); } catch (e) { continue; }
          if (parsed && parsed.type === "result" && typeof parsed.total_cost_usd === "number") {
            return parsed;
          }
        }
      } catch (e) {
        // No event file at all. Counts as a stream that did not report, which is the honest answer.
      }
      return null;
    };

    const envelopes = eventFiles.map(envelopeIn).filter(Boolean);
    // Float addition on money: round to cents so a sum of ten streams cannot present itself as
    // 3.7500000000000004 in a figure Dan reads.
    const usd = Math.round(envelopes.reduce((a, e) => a + e.total_cost_usd, 0) * 1e6) / 1e6;
    // The longest, never the sum: the streams ran at the same time.
    const durationMs = envelopes.reduce((a, e) => Math.max(a, e.duration_ms || 0), 0);
    const complete = eventFiles.length > 0 && envelopes.length === eventFiles.length;

    if (complete) {
      json.runCost = { recorded: true, usd, durationMs, streams: eventFiles.length };
    } else {
      // No `usd` key at all on the incomplete path, so nothing downstream can read a partial total as
      // the real one by reaching for the field it always reads.
      json.runCost = {
        recorded: false,
        streams: eventFiles.length,
        streamsRecorded: envelopes.length,
      };
      if (envelopes.length > 0) {
        json.runCost.partialUsd = usd;
        json.runCost.partialDurationMs = durationMs;
      }
    }
    fs.writeFileSync(file, JSON.stringify(json, null, 2));
    })();
  ' "${results}" "$@" || true
}

# #1593 (milestone 32 Phase 0.1): the other half of the cost reading. Asking claude for
# --output-format stream-json is what makes the cost knowable, and it also makes its stdout raw JSON.
# The run log is the only human trace of a run that takes minutes, so the raw stream is captured to its
# own file for parsing while a readable trickle keeps reaching the log.
#
# Deliberately no per-line JSON parser: a line that is NOT valid JSON is passed through verbatim, because
# a claude that failed prints a plain error and that error is the single most important thing the log can
# carry. A parser that only understood events would swallow it.
tee_run_events() {
  local events="$1" line type
  : > "${events}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" >> "${events}"
    if [[ "${line}" == \{* ]]; then
      if [[ "${line}" =~ \"type\"[[:space:]]*:[[:space:]]*\"([a-z_]+)\" ]]; then
        type="${BASH_REMATCH[1]}"
      else
        type="event"
      fi
      printf '  ... %s\n' "${type}"
    else
      printf '%s\n' "${line}"
    fi
  done
}
