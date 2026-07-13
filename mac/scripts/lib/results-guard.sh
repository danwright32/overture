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

# ensure_every_queued_source_reported <queue> <results> <log> <exit-status>
#
# Guarantees every sourceId in the queue has a result in the results file. Never fails the run it is
# guarding: it is the last thing standing between Dan and a silent loss, and it runs on the failure path,
# when things have already gone wrong.
ensure_every_queued_source_reported() {
  local queue="$1" results="$2" log="$3" status="${4:-0}"

  [ -f "${queue}" ] || return 0                      # nothing was asked for, so nothing to guard
  command -v node >/dev/null 2>&1 || return 0        # no node: degrade to the old behaviour, never worse

  node -e '
    const fs = require("fs");
    const [queuePath, resultsPath, logPath, status] = process.argv.slice(1);

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
    if (rawResults !== null && parsed === null) {
      try { fs.writeFileSync(resultsPath + ".corrupt", rawResults); } catch {}
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
    } catch (e) {
      console.error(`could not write the failure results file: ${e.message}`);
    }
  ' "${queue}" "${results}" "${log}" "${status}" || true
}
