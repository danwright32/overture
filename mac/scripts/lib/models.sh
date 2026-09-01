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

# The reachability CHECK (#1597). Deliberately NOT the drafting model, which is what it used to inherit.
#
# Measured 2026-07-27 with scripts/eval-prep-runbook.sh against all 8 contact-rule fixtures rather than
# assumed: sonnet obeyed every rule (7/8 on the first pass, and that one failure was a formatting hiccup
# which passed on retry) at roughly half the cost per lookup, about 0.95 against 1.90. Haiku scored 4/8
# and dropped a REQUIRED PERFORMER on the stale-site fixture, which is the rule this whole feature rests
# on, so it is not a candidate at any saving.
#
# This moves only the half that FINDS a contact. The half that writes an email reaching a stranger in
# Dan's voice stays on the pinned drafting model above.
OVERTURE_MODEL_REACHABILITY="sonnet"

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

# ONE definition of "this stream finished", shared by record_web_calls and record_run_cost (#3357
# Phase 1.1, L263).
#
# They read the SAME event files and used to answer differently. record_web_calls counted a stream as
# reported if its file merely PARSED; record_run_cost required the terminal result envelope. Measured on
# a real archive (check-run-archives/20260830-205244): runCost said streams 10, streamsRecorded 9,
# recorded false, while webCalls said recorded true, overCap false, streams 10, about the same run.
# Seven shows were silently lost and the web call reading called that run complete.
#
# The ENVELOPE is the right test and parsing is not, because a stream killed part way flushes plenty of
# valid JSONL and no envelope, which is the commonest way a run dies here.
#
# It is a shell VARIABLE holding JS rather than a function, because each recorder is one node program in
# a single-quoted string, and adjacent-string concatenation ("$VAR"'...') is what lets both embed the
# same source without either learning to expand variables. No apostrophes anywhere below: the callers
# splice this beside single-quoted text.
OVERTURE_STREAM_ENVELOPE_JS='
    // The terminal result envelope of one stream, or null if it never reached one.
    const streamEnvelope = (events) => {
      try {
        const lines = require("fs").readFileSync(events, "utf8").split("\n");
        // Walk backwards: the envelope is last, and a killed run leaves a half-written line after
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
        // No event file at all. A stream that did not report, which is the honest answer.
      }
      return null;
    };
'

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
# #1721: how many times the run actually REACHED THE WEB, counted from the event stream rather than
# asked for in the prompt. The runbook states a hop cap; a rule that lives only in a prompt is a hope
# (L27), and the stream the runner has written since #1593 had no reader at all until this, so the cap
# had never once been checked.
#
# Counts every ROUTE, not just WebFetch, and that breadth is measured rather than assumed: in Dan's real
# 2026-07-28 run, chunk 3 reached the web through mcp__playwright__browser_navigate, and prep's scope
# deliberately allows Bash, so curl is a route too. A counter blind to those reports a small number for a
# run that made many calls, which is the same false comfort as no counter.
#
# The cap is PER ITEM and the allowance scales with how many shows the run covered, because a normal Prep
# run is a single unchunked stream over many shows with nothing in it marking where one show ends. Asking
# the model to announce those boundaries would be asking nicely again, so the honest unit is the run.
#
# #1835: a call the permission layer REFUSED is not a call the run made. This counter used to read
# tool_use blocks and stop there, so a refusal and a fetched page were the same number. Dan's 2026-07-30
# run recorded `browser: 1` for a navigation that never happened, and the first diagnosis of #1824 then
# read that 1 as evidence the run HAD browser access. An inflated count also makes a run read as closer
# to its allowance than it is, and the allowance is the only thing watching a hop cap that otherwise
# lives in a prompt.
#
# Refusals are counted SEPARATELY rather than dropped (`denied` / `deniedByRoute`, `partialDenied` on
# the incomplete path), because a run repeatedly asking for a tool it does not have is its own signal:
# dropping them would leave the two runs that most need telling apart, one that never needed the web and
# one that was blocked from it every time, reporting exactly the same thing.
#
# The two marks of a refusal are MEASURED, not invented. They come from the real refusals in
# `~/Library/Application Support/Overture-Debug/Overture/prep-run-events.chunk-1.jsonl` (lines 60 and 61,
# 2026-07-27) and `chunk-3.jsonl`, and both refusals carried both marks:
#
#   tool_result_meta: [{ id, non_execution_kind: "user-rejected" }]  on the user event, and
#   a tool_result reading "Claude requested permissions to use <tool>, but you haven't granted it yet."
#
# Any `non_execution_kind` counts, not only the measured "user-rejected": the field says the tool did not
# run, which is the whole question here, and a kind nobody has seen yet is still a call that reached
# nothing. That is also why the sentence Dan reads says the research never happened rather than naming a
# cause this cannot always know (L11).
#
# Deliberately NOT `is_error`. Across every prep event stream on this Mac (4 runs, 255 tool calls) 6
# results carried `is_error` and only the 2 refusals were refusals; the other 4 were calls that really
# ran and failed (a DNS miss, a curl that got a 302, two Bash exits). Counting those as refusals would
# DROP real web calls, which is the failure this counter exists to prevent.
#
#   $1 = results file, rewritten in place
#   $2 = cap per item
#   $3.. = the event stream files, one per parallel claude
record_web_calls() {
  local results="$1" cap="$2"
  shift 2
  [[ -f "${results}" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e "${OVERTURE_STREAM_ENVELOPE_JS}"'
    (function () {
    const fs = require("fs");
    const [file, capRaw, ...eventFiles] = process.argv.slice(1);
    const cap = Number(capRaw);
    let json;
    try {
      json = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch (e) {
      // Same rule as record_run_cost: an unparsable results file is the run having failed, reported on
      // its own path. Overwriting it would destroy the evidence of what went wrong.
      return;
    }

    // A Bash command that reaches the network. Deliberately a NAMED heuristic rather than a silent one:
    // it cannot be exact, so it is listed here where it can be argued with, and it errs toward counting
    // (an over-count is visible and arguable; an under-count is the failure this whole counter exists to
    // prevent).
    const bashReachesWeb = (cmd) =>
      typeof cmd === "string" && /\b(curl|wget|nc|ssh)\b|https?:\/\//.test(cmd);

    const routeOf = (name, input) => {
      if (name === "WebFetch") return "fetch";
      if (name === "WebSearch") return "search";
      // Any MCP browser tool. Matched on the shape rather than one server name, so a different browser
      // MCP on this Mac is counted too (a detached run inherits whatever plugins are installed).
      if (/^mcp__.*browser/.test(name || "")) return "browser";
      if (name === "Bash" && bashReachesWeb(input && input.command)) return "bash";
      return null;
    };

    // #1835: the two marks of a REFUSED call, both measured from real refusals rather than imagined.
    // See the block comment above this function for where they were read and why `is_error` is not one
    // of them. The apostrophe in the sentence is written as an escape because this whole program is a
    // single-quoted shell string.
    const refusalSentence = /requested permissions to use .*, but you haven\u0027t granted it yet/;
    const resultText = (block) =>
      typeof block.content === "string" ? block.content : JSON.stringify(block.content || "");

    const countIn = (events) => {
      const made = { fetch: 0, search: 0, browser: 0, bash: 0 };
      const refused = { fetch: 0, search: 0, browser: 0, bash: 0 };
      const routeById = new Map();
      const routeless = [];   // a tool_use with no id can never be tied to a result, so it counts as made
      const refusedIds = new Set();
      const lines = fs.readFileSync(events, "utf8").split("\n");
      for (const raw of lines) {
        const line = raw.trim();
        if (!line) continue;
        let parsed;
        // A killed run leaves a half-written line; skip it rather than failing the whole count.
        try { parsed = JSON.parse(line); } catch (e) { continue; }
        // The structural mark, which sits beside the message rather than inside it.
        if (Array.isArray(parsed.tool_result_meta)) {
          for (const meta of parsed.tool_result_meta) {
            if (meta && meta.id && meta.non_execution_kind) refusedIds.add(meta.id);
          }
        }
        const content = parsed && parsed.message && parsed.message.content;
        if (!Array.isArray(content)) continue;
        for (const block of content) {
          if (!block) continue;
          if (block.type === "tool_use") {
            const route = routeOf(block.name, block.input);
            if (!route) continue;
            if (block.id) routeById.set(block.id, route); else routeless.push(route);
            continue;
          }
          if (block.type === "tool_result" && block.tool_use_id &&
              refusalSentence.test(resultText(block))) {
            refusedIds.add(block.tool_use_id);
          }
        }
      }
      for (const [id, route] of routeById) {
        if (refusedIds.has(id)) refused[route] += 1; else made[route] += 1;
      }
      for (const route of routeless) made[route] += 1;
      return { made, refused };
    };

    const byRoute = { fetch: 0, search: 0, browser: 0, bash: 0 };
    const deniedByRoute = { fetch: 0, search: 0, browser: 0, bash: 0 };
    let reported = 0;
    for (const f of eventFiles) {
      let counts;
      try {
        counts = countIn(f);
      } catch (e) {
        continue;   // unreadable: no calls to add, and it did not report
      }
      // #3357 Phase 1.1: reported means it reached its terminal envelope, NOT merely that the file
      // parsed. This line used to be an unconditional `reported += 1`, which is why a run whose stream
      // was killed part way through counted as complete here while the cost reading beside it, over the
      // same files, correctly said it was not. The calls this stream DID make are still added below,
      // because a partial count is still published under the incomplete path; what changes is only
      // whether the run may call itself finished.
      if (streamEnvelope(f)) { reported += 1; }
      for (const k of Object.keys(byRoute)) {
        byRoute[k] += counts.made[k];
        deniedByRoute[k] += counts.refused[k];
      }
    }

    const total = Object.values(byRoute).reduce((a, n) => a + n, 0);
    const denied = Object.values(deniedByRoute).reduce((a, n) => a + n, 0);
    const items = Array.isArray(json.results) ? json.results.length : 0;

    // #1864: the allowance counts research TARGETS, not shows. It was a flat number per show, sized when
    // one show meant researching one party. Since #1817 an organiser-less show pursues every performer
    // the listing names, and the runbook puts NO headcount ceiling on that route, so the rooms this
    // counter was built to watch (a cabaret room booking five-handers) blow an allowance built for one.
    // The runs that trip it first are the CORRECT ones, which is how a counter stops meaning anything
    // precisely on the shows it was added for (L36).
    //
    // The evidence is the performer entries on the item itself: the runbook requires a performer on the
    // listing to be surfaced as her own contact even when nothing was found for her (at low confidence),
    // so they count the parties actually pursued rather than the ones that panned out.
    //
    // This does size the allowance from what the run REPORTED, so a run that silently drops performers
    // gets a smaller allowance and is likelier to trip the counter. That is the safe direction and it is
    // deliberate: this counter exists to over-report rather than to hide spend.
    //
    // Never zero for an item that reported nothing. An item always asked for at least one party, and a
    // floor of zero would give a run that found nobody an allowance of nothing and flag every one.
    const partiesFor = (item) => {
      const contacts = item && Array.isArray(item.contacts) ? item.contacts : [];
      const performers = contacts.filter((c) => c && c.provenance === "performer").length;
      return Math.max(1, performers);
    };
    const parties = Array.isArray(json.results)
      ? json.results.reduce((n, item) => n + partiesFor(item), 0)
      : 0;
    const allowance = cap * parties;
    const complete = eventFiles.length > 0 && reported === eventFiles.length;

    if (complete) {
      json.webCalls = {
        recorded: true, total, byRoute, denied, deniedByRoute, items, parties, capPerItem: cap,
        allowance,
        overCap: items > 0 && total > allowance,
        streams: eventFiles.length,
      };
    } else {
      // No `total` key at all on the incomplete path, so nothing downstream can read a partial count as
      // the real one by reaching for the field it always reads. `denied` follows the same rule for the
      // same reason and rides under `partialDenied`. `overCap` is published ONLY when the partial count
      // already exceeds the allowance, because that verdict can only get truer.
      json.webCalls = {
        recorded: false, byRoute, deniedByRoute, items, parties, capPerItem: cap, allowance,
        streams: eventFiles.length, streamsReported: reported,
        partialTotal: total, partialDenied: denied,
      };
      if (items > 0 && total > allowance) json.webCalls.overCap = true;
    }

    fs.writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
    })();
  ' "${results}" "${cap}" "$@"
}

record_run_cost() {
  local results="$1"
  shift
  [[ -f "${results}" ]] || return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e "${OVERTURE_STREAM_ENVELOPE_JS}"'
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

    // #3357 Phase 1.1: `streamEnvelope` is the SHARED definition, spliced in by the caller, so the
    // web call reading beside this one cannot answer differently about the same streams (L263).
    const envelopes = eventFiles.map(streamEnvelope).filter(Boolean);
    // Float addition on money: round to cents so a sum of ten streams cannot present itself as
    // 3.7500000000000004 in a figure Dan reads.
    const usd = Math.round(envelopes.reduce((a, e) => a + e.total_cost_usd, 0) * 1e6) / 1e6;
    // The longest, never the sum: the streams ran at the same time.
    const durationMs = envelopes.reduce((a, e) => Math.max(a, e.duration_ms || 0), 0);
    const complete = eventFiles.length > 0 && envelopes.length === eventFiles.length;

    // #2762: whether another run slot was alive while this one worked, as the runner latched it. Written
    // as a key only when the caller SAID, because the three states are different facts: true and false are
    // measurements, and absent means a runner that predates the flag. The app refuses to pool an absent
    // one rather than reading it as solo, which is what stops a co-run inside the update window (a new app
    // meeting the older script still in the checkout) from teaching the solo estimate.
    //
    // No apostrophes anywhere in this block: the whole program is a single-quoted shell string, and one
    // would end it.
    const said = process.env.OVERTURE_RUN_CONTENDED;
    const contention = said === "1" ? { contended: true } : said === "0" ? { contended: false } : {};

    // #3004: what KIND of run wrote this file, and which slot it ran in. Two facts, not one: a check may
    // legitimately run in the prep slot, and that is precisely the case a reader must be able to see.
    //
    // At the TOP LEVEL rather than inside runCost, because it is true of the file whether or not the cost
    // reading completed, and a fact filed under a key that can go absent is a fact that disappears exactly
    // when the run went wrong.
    //
    // Only values the reader recognises are written. A typo in the environment would otherwise become a
    // permanent refusal downstream with nothing naming its cause. Said nothing, claims nothing: the same
    // update-window rule as contention above, since an old script meeting a new app must not be read as a
    // Prep run just because that is the commoner kind.
    const kinds = ["prep", "check"];
    const kindSaid = process.env.OVERTURE_RUN_KIND;
    const slotSaid = process.env.OVERTURE_RUN_SLOT;
    if (kinds.indexOf(kindSaid) >= 0) { json.runKind = kindSaid; }
    if (kinds.indexOf(slotSaid) >= 0) { json.runSlot = slotSaid; }

    if (complete) {
      json.runCost = { recorded: true, usd, durationMs, streams: eventFiles.length, ...contention };
    } else {
      // No `usd` key at all on the incomplete path, so nothing downstream can read a partial total as
      // the real one by reaching for the field it always reads.
      json.runCost = {
        recorded: false,
        streams: eventFiles.length,
        streamsRecorded: envelopes.length,
        ...contention,
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

# #3357 Phase 1.3: which web calls each ITEM cost, derived from the run's own streams.
#
# WHAT IT IS FOR. `scripts/what-the-check-searched.sh` (#2996) can already print every web call a run
# made, and it refuses to say which SHOW a call belonged to whenever a chunk carried more than one:
# "these calls are NOT attributed to this one. Read them as the whole chunk." That refusal is honest and
# it is also the reason the tool cannot answer the question it exists for on a busy run. This is the
# derivation that lets it.
#
# HOW. The runbook tells the run to rewrite the whole results file after EACH item (#1023), so each
# `Write` names the item just finished, and the web calls since the previous `Write` are that item's.
# The newly appearing `naturalKey` in a Write is what names it: the file is cumulative, so the keys
# already seen are the items already done.
#
# THAT IS AN INSTRUCTION IN A PROMPT, NOT AN OBSERVED BEHAVIOUR (L27, L98). Measured across all seven
# surviving chunk streams on 2026-08-30: one show per chunk, exactly one `Write` per chunk, and chunk 7
# with no `Write` at all. There is no multi item chunk anywhere on disk to check the rule against,
# because the only run that had them was overwritten 45 minutes later, which is #3346's argument stated
# as a fact. So this SHIPS the derivation and its outcomes, and the per item rewrite RATE is measured on
# the first archived multi item run. Nothing may depend on the attribution being right until then.
#
# THREE OUTCOMES, never two, because a stream nobody could read and a stream with nothing in it are
# different facts and only one of them is a finding (L98, L11):
#
#   attributed     a Write boundary was found and the calls fall between boundaries
#   unattributable a stream that reported calls and named no item, or calls after the last Write
#   unmeasured     no event file, or nothing in it parsed
#
# UNATTRIBUTABLE IS REPORTED PER STREAM AND NEVER DIVIDED EVENLY ACROSS ITS ITEMS. Averaging is exactly
# what would hide a starved show inside a busy chunk, which is the thing anybody reads this to find.
#
# IT ATTRIBUTES SEARCHES AS WELL AS FETCHES. Verified on the live streams: `WebSearch` tool_use records
# carry `input.query` and sit in the same stream as `WebFetch` (one chunk held 9 searches, 6 fetches, 1
# Write). A rule reading fetches alone would answer "what did this check look at" while leaving out what
# it looked FOR, which is the half that showed #2983 had never searched the company at all.
#
# ONE DEPARTURE FROM THE PLAN TEXT, stated rather than smuggled. The plan lists "calls before the first
# boundary" as unattributable. On the only data that exists that rule attributes NOTHING: every stream
# holds one item and one Write, so every call precedes the first boundary and the tool would report 100%
# unattributable while working perfectly. Those calls are therefore attributed to the item that first
# Write names, and counted SEPARATELY as `beforeFirstWrite` so the weaker evidence stays visible and
# anybody can subtract it.
record_item_attribution() {
  local out="$1" kills="$2"
  shift 2
  command -v node >/dev/null 2>&1 || return 0
  node -e "${OVERTURE_STREAM_ENVELOPE_JS}"'
    (function () {
    const fs = require("fs");
    const [outFile, killsFile, ...eventFiles] = process.argv.slice(1);

    // Only routes that reach the WEB, matching what-the-check-searched.sh: a Read or a network-free
    // Bash is not a search, and listing it would pad the very output this exists to make readable.
    const callOf = (block) => {
      if (!block || block.type !== "tool_use") return null;
      const input = block.input || {};
      if (block.name === "WebSearch") return { route: "search", detail: String(input.query || "") };
      if (block.name === "WebFetch") return { route: "fetch", detail: String(input.url || "") };
      return null;
    };

    // The keys THIS Write names. Read out of the written text rather than parsed as JSON, because a
    // rewrite in flight is routinely truncated and a parse failure would throw the boundary away along
    // with the item it names.
    const keysIn = (text) => {
      const out = [];
      const re = /"naturalKey"\s*:\s*"((?:[^"\\]|\\.)*)"/g;
      let m;
      while ((m = re.exec(text)) !== null) out.push(m[1]);
      return out;
    };
    const writeText = (block) => {
      const input = block.input || {};
      const parts = [input.content, input.new_string, input.file_text];
      return parts.filter((p) => typeof p === "string").join("\n");
    };

    const streams = [];
    let attributed = 0, unattributable = 0, unmeasured = 0, beforeFirstWrite = 0;

    eventFiles.forEach((file, index) => {
      const chunk = index + 1;
      let text;
      try { text = fs.readFileSync(file, "utf8"); } catch (e) {
        streams.push({ chunk: chunk, outcome: "unmeasured", why: "no event file" });
        unmeasured += 1;
        return;
      }
      let parsedLines = 0;
      const items = [];
      const seen = new Set();
      let pending = [];
      let sawAWrite = false;
      let strays = [];
      for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (!line.startsWith("{")) continue;
        let event;
        // A killed run leaves a half written line. Skip it rather than failing the whole stream, which
        // is the rule record_web_calls already follows over these same files.
        try { event = JSON.parse(line); } catch (e) { continue; }
        parsedLines += 1;
        const content = event && event.message && event.message.content;
        if (!Array.isArray(content)) continue;
        for (const block of content) {
          const call = callOf(block);
          if (call) { pending.push(call); continue; }
          if (!block || block.type !== "tool_use" || block.name !== "Write") continue;
          const fresh = keysIn(writeText(block)).filter((k) => !seen.has(k));
          for (const k of fresh) seen.add(k);
          // Exactly one new key names one item. Zero (a rewrite that added nobody) or several (a run
          // that batched) cannot say which of them the calls belong to, and guessing is what would hide
          // a starved show, so the calls stay unattributed and say so.
          if (fresh.length === 1) {
            if (!sawAWrite) beforeFirstWrite += pending.length;
            items.push({ naturalKey: fresh[0], calls: pending });
          } else if (pending.length > 0) {
            strays = strays.concat(pending);
          }
          sawAWrite = true;
          pending = [];
        }
      }
      // Anything after the last Write was never named by one.
      strays = strays.concat(pending);
      if (parsedLines === 0) {
        streams.push({ chunk: chunk, outcome: "unmeasured", why: "nothing in the stream parsed" });
        unmeasured += 1;
        return;
      }
      const outcome = items.length > 0 ? "attributed" : "unattributable";
      if (outcome === "attributed") { attributed += 1; } else { unattributable += 1; }
      streams.push({
        chunk: chunk,
        outcome: outcome,
        complete: streamEnvelope(file) !== null,
        items: items,
        unattributedCalls: strays,
      });
    });

    // #3357 Phase 1.5: the watchdog kills, folded in HERE because this is where the streams are already
    // walked. `record_watchdog_kill` appends chunk and elapsed and parses nothing, so there is one
    // implementation of "which items had this chunk written", not two that can drift (L263).
    //
    // Absent is the ordinary case and says nothing; UNREADABLE is its own state and says so, because a
    // kills file that cannot be read and a run with no kills leave the same empty list, and a run
    // offered as comparison evidence must be able to tell them apart (L98, L11).
    let kills = [];
    let killsReadable = true;
    if (killsFile) {
      try {
        const raw = fs.readFileSync(killsFile, "utf8");
        for (const line of raw.split("\n")) {
          const t = line.trim();
          if (!t.startsWith("{")) continue;
          try { kills.push(JSON.parse(t)); } catch (e) { killsReadable = false; }
        }
      } catch (e) {
        // No file at all is a run nothing killed, which is the ordinary case and not a fault.
        kills = [];
      }
    }
    const itemsOf = (chunk) => {
      const s = streams.find((x) => x.chunk === chunk);
      return s && Array.isArray(s.items) ? s.items.map((i) => i.naturalKey) : [];
    };
    kills = kills.map((k) => ({
      chunk: k.chunk,
      at: k.at,
      requestInFlightSeconds: k.requestInFlightSeconds,
      // What that chunk had ALREADY written, which BOUNDS the item it died on rather than naming it.
      // Naming one would be a claim the stream does not carry.
      itemsAlreadyWritten: itemsOf(k.chunk),
    }));

    const report = {
      version: 1,
      generatedAt: new Date().toISOString(),
      // A run with any kill in it is a confound, and this is the field to read before using a run as
      // comparison evidence (#3007). Zero is a measurement; `killsReadable: false` is not.
      watchdogKills: kills,
      killsReadable: killsReadable,
      attributed: attributed,
      unattributable: unattributable,
      unmeasured: unmeasured,
      // Counted apart from the total, so the weaker evidence named in the header above stays
      // visible rather than being folded into a number that reads as fully attributed.
      beforeFirstWrite: beforeFirstWrite,
      streams: streams,
    };
    try {
      fs.writeFileSync(outFile, JSON.stringify(report, null, 2) + "\n");
    } catch (e) {
      // Evidence ABOUT a run rather than output the run itself made, so a failure to write it must
      // never turn a
      // successful run into a failed one. Reported below rather than thrown.
      console.log("prep: could not write the per item attribution sidecar (" + e.message + ").");
      return;
    }
    console.log("prep: per item attribution: " + attributed + " stream(s) attributed, " +
                unattributable + " unattributable, " + unmeasured + " unmeasured" +
                (beforeFirstWrite > 0
                  ? " (" + beforeFirstWrite + " call(s) attributed to an item with no preceding Write)"
                  : "") + ".");
    if (kills.length > 0) {
      console.log("prep: the stuck-request watchdog killed " + kills.length +
                  " chunk(s) in this run, so it is not usable as comparison evidence (#3007).");
    }
    })();
  ' "${out}" "${kills}" "$@"
}
