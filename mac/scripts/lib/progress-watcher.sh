#!/usr/bin/env bash
# #1015: the scout-extract toolbar's "N of M" used to be seeded by the runner and then only advanced
# if the model chose to rewrite progress.json. On 2026-07-16 it did not: the run's own log said "I
# never did this," and the counter sat at 0 of 20 through a run that was doing real work, which is
# exactly the "is it alive?" ambiguity a live count exists to resolve.
#
# A count is a fact about what the script handed out and what came back. Asking the model to
# self-report it invites it to be confidently wrong about the one thing the record exists to establish,
# the same reasoning as record_model in models.sh: the script knows what it asked for and can see what
# has landed, so the script should be the one to say so, not the model.

# update_progress_from_results <queue> <results> <progress>
#
# `total` is the number of SHOWS the queue asked for (an item plus every key its `alsoAnswersFor`
# covers, which for an ungrouped queue is simply the item count); `completed` is how many of those the
# results file currently carries (capped at total, never over 100%, since a stray extra entry must
# never read as more done than was ever asked for). Called repeatedly while a run is alive (the
# runner's own heartbeat loop), so this only ever needs to reflect what is on disk RIGHT NOW; it is
# never the thing that decides whether a source counts as done, only the thing that counts.
#
# Degrades to leaving `<progress>` exactly as it was, never to zeroing it out or crashing the run, on
# any of: no node on PATH, the queue missing or unparsable (the total cannot be known), or the results
# file missing or unparsable (nothing has landed yet, or the model is mid-write). A half-written
# results file reading as "zero done" would be a worse lie than simply not updating yet.
update_progress_from_results() {
  local queue="$1" results="$2" progress="$3"
  command -v node >/dev/null 2>&1 || return 0

  node -e '
    (function main() {
      const fs = require("fs");
      const [queuePath, resultsPath, progressPath] = process.argv.slice(1);

      const read = (p) => { try { return fs.readFileSync(p, "utf8"); } catch { return null; } };
      const parse = (s) => { try { return JSON.parse(s); } catch { return null; } };

      const queue = parse(read(queuePath) ?? "");
      // #1597: SHOWS, not queue entries. A reachability check collapses the shows of one producer into
      // a single item that answers for the rest via alsoAnswersFor, so counting entries would have told
      // Dan a check he started on six shows was 4 of 4 while two were still landing. No other queue
      // carries that field, so this stays the old item count for scout-extract and for a normal Prep run.
      // NO APOSTROPHES in this comment: it lives inside a single-quoted shell string (see #853).
      const items = queue?.items ?? [];
      const total = items.reduce(
        (n, i) => n + 1 + (Array.isArray(i?.alsoAnswersFor) ? i.alsoAnswersFor.length : 0), 0);
      if (!total) return;   // the queue is missing, unparsable, or empty: nothing to derive

      const results = parse(read(resultsPath) ?? "");
      if (!Array.isArray(results?.results)) return;   // no results yet, or unreadable: leave progress as is
      // #1804: SHOWS again, on the completed side too. `total` counts an item plus everything it answers
      // for, so counting bare entries meant a run that answered a group of six with one entry sat at 1 of 6
      // for the whole run and never reached its own total. The app credits the same grouping when it
      // settles, so the live count and the settled outcome now agree instead of contradicting each other.
      // An entry for a key nothing grouped (the ordinary case) still counts as exactly one.
      // Entries written so far, exactly as before. Scout-extract and reply-classify entries are counted by
      // this line alone: neither carries alsoAnswersFor, and scout-extract does not even key by naturalKey,
      // so the credit below can never reach them.
      let completedRaw = results.results.length;
      const answered = new Map();
      for (const r of results.results) {
        if (typeof r?.naturalKey === "string") answered.set(r.naturalKey, r);
      }
      for (const i of items) {
        const lead = answered.get(i?.naturalKey);
        if (!lead || !Array.isArray(i?.alsoAnswersFor)) continue;
        // Only a lead that FOUND somebody credits its group, matching PrepGroupCredit exactly: a lead that
        // came home with nobody leaves its covered shows genuinely unanswered, and the count must say so.
        if (!Array.isArray(lead.contacts) || lead.contacts.length === 0) continue;
        for (const key of i.alsoAnswersFor) {
          // A covered show the run answered IN ITS OWN RIGHT is already in the entry count above, and must
          // not be counted twice, once on its own and once through its lead. Same "its own entry wins" rule
          // the app applies when it settles.
          if (!answered.has(key)) completedRaw += 1;
        }
      }

      const completed = Math.min(completedRaw, total);
      fs.writeFileSync(progressPath, JSON.stringify({ version: 1, total, completed }, null, 2));
    })();
  ' "${queue}" "${results}" "${progress}" 2>/dev/null || true
}
