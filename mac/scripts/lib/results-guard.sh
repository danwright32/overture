#!/usr/bin/env bash
# #856: a detached run that exits without results writes an honest failure, instead of vanishing.
#
# Three times in one evening a run did real work and produced nothing usable: it stopped to ask a
# question (#847), it hit a broken prompt (#853), and in between it left the app polling for a file that
# never came (#848). Each time the fix was to instruct the model better.
#
# Instructions are not a guarantee. A run can still exit without writing its results for a reason nobody
# has thought of yet, and when it does the work is gone and the app is left guessing. "The run vanished"
# should not be a state the app can be in.
#
# The SCRIPT knows what it asked for: it wrote the queue. So it can see what came back and speak for what
# did not, without the model's cooperation and whatever the model does. Structure, not instructions.
#
# The honest verdict is `not_read`, NOT `unreadable`. They are different failures and must never look
# alike: `unreadable` means the page is broken (a calendar drawn by JavaScript, a login wall) and the app
# says so to Dan in those words. A page nobody looked at is not a broken page, and telling him a healthy
# calendar is JavaScript-drawn would send him to fix a page that was never the problem, and teach him to
# distrust the failing section, which is where the genuinely broken source has to be visible.
#
# Either way the source's content hash is NOT stamped and its unread flag stays set, so the next scout
# reads it again rather than skipping it forever.

# corrupt_path <results>   (#911)
#
# Where a run's unreadable bytes are kept. STAMPED, because the name used to be fixed
# (`<results>.corrupt`) and both writers below used it: two bad runs in a week left only the most recent,
# with nothing anywhere saying an earlier one had been lost. #868's whole point was that these bytes are
# the only evidence of what a run really did, and the failure that is hardest to diagnose (an intermittent
# one) is exactly the failure whose evidence a fixed name destroys.
#
# Still ends in `.corrupt`, deliberately: HandoffCleanup (#821) owns anything with that suffix and prunes
# it on the same 14-day rule, so stamped copies compose with the existing sweep instead of piling up
# forever. A test asserts that suffix survives, because the day it does not, these files become immortal.
#
# Written once, and both writers call it. Two functions building the same name their own way is how they
# would drift apart, and one of them silently reverting to a fixed name is exactly this bug again.
corrupt_path() {
  local results="$1"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"

  # Two runs inside the same second are not a thing a scout does, but a retry loop is, and a collision
  # would silently destroy the evidence again. So the suffix is checked, not assumed.
  local candidate="${results}.${stamp}.corrupt"
  local n=2
  while [ -e "${candidate}" ]; do
    candidate="${results}.${stamp}-${n}.corrupt"
    n=$((n + 1))
  done
  printf '%s' "${candidate}"
}

# discard_previous_results <results>   (#1011)
#
# The results file sitting on disk when a run STARTS belongs to the PREVIOUS run. The app has already
# read it (that is what it polls for), so it is spent. Left in place it is not merely stale, it is
# indistinguishable from this run.s own output, because nothing downstream compares its age to the
# queue it is supposed to be answering.
#
# On 2026-07-16 a run wrote nothing at all. ensure_every_queued_source_reported then appended its
# not_read entries to the 4.5-hour-old file still lying there, and carried that file.s generatedAt
# across, so the app ingested a results file stamped hours before the queue it answered, carrying two
# real-looking sources the run had never been asked about. The app was left saying the model had
# rebuilt an id, which was not what happened at all: those were simply the last run.s leftovers.
#
# Deleted, not stamped aside: unlike a .corrupt file these bytes are not evidence of anything. They
# are a successfully completed run.s output that has already been consumed. Keeping copies would pile
# up under no cleanup rule (HandoffCleanup owns .corrupt, not this), for no diagnostic gain.
#
# NO APOSTROPHES in these comments: see the warning inside the node program below.
discard_previous_results() {
  local results="$1"
  [ -f "${results}" ] || return 0
  rm -f "${results}" 2>/dev/null || true
}

# quarantine_unreadable_results <results>   (#868)
#
# A results file that does not parse is not results, and leaving it in place is the quietest failure in
# the whole app. The file is FRESH, so `DetachedRunOutcome.phase` reads it as a run that produced
# results; the app then decodes it, fails, and returns in silence (`guard let ... else { return }`). No
# warning, no error, nothing. The existing "the run finished but didn't produce any results" message,
# which already carries the tail of the run log, never fires precisely BECAUSE a file is sitting there.
#
# Moving it aside restores that message: no results file means the run reads as what it actually was. The
# bytes are kept as `.corrupt`, because they are the only evidence of what the run really did.
#
# This is the guarantee prep and reply get, and it is deliberately NOT the one scout gets. Their results
# have no per-item failure worth synthesizing: an empty prep result would CLAIM the run researched a show
# and found nobody, about a show nobody ever looked at, and a fabricated reply intent would drive a
# conversation state off a decision no model made. Scout is different: its results are per-source and its
# ingest latches a content hash, so naming the sources it lost is both possible and load-bearing.
quarantine_unreadable_results() {
  local results="$1"

  [ -f "${results}" ] || return 0                    # no file: already handled on its own path
  command -v node >/dev/null 2>&1 || return 0        # no node: degrade to today's behaviour, never worse

  # #911: the destination is decided HERE, by the one function that names these files, and handed to node.
  # Node building the name for itself is how the two writers drifted into a fixed name apiece.
  local destination
  destination="$(corrupt_path "${results}")"

  node -e '
    const fs = require("fs");
    const [file, destination] = process.argv.slice(1);
    const raw = fs.readFileSync(file, "utf8");
    try {
      JSON.parse(raw);
    } catch {
      // Kept, never deleted: this is the only record of what the run produced, and the reason it failed
      // is somewhere in it. Stamped, so the NEXT bad run cannot land on top of it (#911).
      fs.renameSync(file, destination);
      console.log(`results file did not parse; moved aside to ${destination} so the run reports as empty`);
    }
  ' "${results}" "${destination}" 2>/dev/null || true
}

# ensure_every_queued_source_reported <queue> <results> <log> <exit-status>
#
# Guarantees every sourceId in the queue has a result in the results file. Never fails the run it is
# guarding: it is the last thing standing between Dan and a silent loss, and it runs on the failure path,
# when things have already gone wrong.
ensure_every_queued_source_reported() {
  local queue="$1" results="$2" log="$3" status="${4:-0}"
  local guard_status=0

  # #1011: the caller reads this to decide its own exit status. Cleared on every call so a second run
  # in one shell cannot inherit the first run.s verdict.
  RESULTS_MISSING_SOURCES=0

  [ -f "${queue}" ] || return 0                      # nothing was asked for, so nothing to guard
  command -v node >/dev/null 2>&1 || return 0        # no node: degrade to the old behaviour, never worse

  # #911: same one naming rule as the quarantine path above. Computed even when the results turn out to be
  # fine, because it is a name and not a file: nothing is written unless the bytes are actually unreadable.
  local corrupt_destination
  corrupt_destination="$(corrupt_path "${results}")"

  node -e '
    const fs = require("fs");
    const [queuePath, resultsPath, logPath, status, corruptPath] = process.argv.slice(1);

    const read = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return null; } };
    const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };

    const queue = parse(read(queuePath) ?? "");
    const queued = (queue?.items ?? []).map((i) => i.sourceId).filter(Boolean);
    if (!queued.length) process.exit(0);   // an unreadable or empty queue: the run had nothing to lose

    const rawResults = read(resultsPath);
    const parsed = rawResults === null ? null : parse(rawResults);

    // A results file we cannot parse is the WORST shape, and the quietest: the app decodes it, fails, and
    // ingests nothing while saying nothing, because a freshly written file looks like a run that produced
    // results. Keep the bytes as evidence (they are the only record of what went wrong) and speak for
    // every source, rather than leaving that silence in place.
    // #911: to a stamped path, so a second unreadable run keeps its own evidence AND the evidence of the
    // run before it, rather than overwriting the only record of what went wrong last time.
    //
    // NO APOSTROPHES ANYWHERE IN HERE. This whole program is one single-quoted bash string, and a raw
    // quote ends it: the script then fails to parse, every function in this file silently stops existing,
    // and the guards vanish. `bash -n` catches it, and this comment cost one run of it to learn.
    if (rawResults !== null && parsed === null) {
      try { fs.writeFileSync(corruptPath, rawResults); } catch {}
    }

    const existing = Array.isArray(parsed?.results) ? parsed.results : [];
    const reported = new Set(existing.map((r) => r?.sourceId).filter(Boolean));
    const missing = queued.filter((id) => !reported.has(id));
    if (!missing.length) process.exit(0);   // every source came back: leave the run.s own file untouched

    // The tail of the run log, so the reason travels WITH the failure instead of only living in a file
    // nobody opens. Capped: this lands in a note Dan reads, not in a debugger.
    const tail = (read(logPath) ?? "")
      .split("\n").filter((l) => l.trim()).slice(-6)
      .map((l) => (l.length > 200 ? l.slice(0, 200) + "…" : l))
      .join(" | ");

    const why = status === "0"
      ? "The run exited normally but produced no results for this source."
      : `The run exited with status ${status} and produced no results for this source.`;
    const note = [why, "It has NOT been read, and the next scout will try it again.",
                  tail ? `Last lines of the run log: ${tail}` : ""].filter(Boolean).join(" ");

    const out = {
      version: parsed?.version ?? 1,
      generatedAt: parsed?.generatedAt ?? new Date().toISOString(),
      // The run.s own results come first and are never rewritten: a source it genuinely read keeps
      // exactly what it said, including a verdict of its own.
      results: [...existing, ...missing.map((sourceId) => ({
        sourceId, verdict: "not_read", events: [], note,
      }))],
    };
    if (parsed?.model) out.model = parsed.model;

    try {
      fs.writeFileSync(resultsPath, JSON.stringify(out, null, 2));
      console.log(`reported ${missing.length} source(s) the run never came back with: ${missing.join(", ")}`);
      // #1011: 9 says the guard had to speak for the run. The caller turns that into a non-zero exit,
      // because a run that came back with nothing is a FAILED run however calmly claude exited.
      process.exit(9);
    } catch (e) {
      console.error(`could not write the failure results file: ${e.message}`);
    }
  ' "${queue}" "${results}" "${log}" "${status}" "${corrupt_destination}" || guard_status=$?

  # #1011: 9 is the guard reporting that sources went missing, not the guard breaking. Any OTHER
  # non-zero is this guard itself failing, and it must stay silent about that: it runs on the failure
  # path, where things have already gone wrong, and it is the last thing between Dan and a silent loss.
  if [ "${guard_status:-0}" = "9" ]; then
    RESULTS_MISSING_SOURCES=1
  fi
}
