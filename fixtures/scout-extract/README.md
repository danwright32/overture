# scout-extract fixtures

The app's round trip with the scout-extract run (#799), the path that reads an arbitrary org's
listings page. See `docs/contracts.md` and `docs/scout-extract-runbook.md`.

The run is a Claude Code workflow, not Swift, so it has no automated test of its own. **These
fixtures are its spec.** `ScoutExtractContractTests.swift` pins the app's side of both files.

## The two rules that matter

**`sourceId` is opaque.** The run echoes it back verbatim and must never rebuild it. A reconstructed
id matches nothing on the way home, so the work vanishes with no error anywhere. This is the same rule
`fixtures/prep-queue/` carries, and for the same reason.

**The verdict is not decoration.** An empty `events` list means three different things, and the
fixtures deliberately carry two of them:

- `chelsea-symphony` returns **no events with `verdict: "all_past"`**. Its page is full of concerts.
  Every one of them has already happened (they sit under a "Previous Concerts This Season" heading)
  and the new season is not posted yet. The source is HEALTHY and the correct answer is nothing. In
  July, this was the state of 5 of the 7 real sites the #770 spike tested.
- `bargemusic` returns **two events with `verdict: "upcoming_listings"`**. A working source with
  real shows.

The other two verdicts are the failure cases: `no_dated_content` (the page carries no dated listings
at all, usually because it is the wrong page: guessing a URL by convention landed the spike on a 2021
archived concert, HTTP 200) and `unreadable` (the calendar is drawn by JavaScript, so the bytes hold
no event data and no model can help).

Without the verdict, a quiet source and a dead one are indistinguishable, which is the one failure Dan
said must never happen.

## The fifth verdict, and its second writer (#856)

`not_read` is the only verdict the RUN never writes. `scout-extract-run.sh` writes it, about the run,
after the run has ended, for any queued `sourceId` that did not come back (see
`mac/scripts/lib/results-guard.sh`). So the results file has two writers: the model for what it read,
and the script for what the run lost. The runbook deliberately never mentions `not_read`, because the
model is in no position to make that claim about itself.

It exists because instructions are not a guarantee. Three times in one evening a run did real work and
produced nothing: it stopped to ask a question (#847), it hit a broken prompt (#853), and it left the
app polling for a file that never came (#848). "The run vanished" must not be a state the app can be
in, so the script speaks for what the model did not.

**It is not `unreadable`, and that distinction is the whole point.** `unreadable` means the page itself
is broken, and the app says so to Dan in those exact words ("that calendar is drawn by JavaScript"). A
page nobody opened is not a broken page. Reusing `unreadable` here would send him to fix a calendar
that was never the problem, and teach him to distrust the failing list, which is exactly where the one
genuinely broken source has to be visible. Both are failures in the sense that matters (the content
hash is NOT stamped and the unread flag stays set, so the next scout reads the page again), but they
say different things because they ARE different things.

`results-not-read-v1.json` is that file: one source the run read, one it never reached.

## Shape

`queue-v1.json`: what the app writes. The run does NOT fetch the page. The app fetches it, writes it
to disk and hashes it, and `pagePath` points at that exact file, so the listing SET (which drives
re-keying and reconcile) comes from bytes the app hashed. The run MAY follow each event's own detail
page for the venue and exact date, which a listings page usually does not carry (#770 spike, finding
4); that is per-event enrichment, never the set.

`results-v1.json`: what the run writes back. `venue` is expected, not optional in spirit: Overture
needs it, because it drives the classifier and the pitch itself.

`progress-v1.json`: seeded by the script, updated by the run, so the scout can show "3 of 9" instead
of a bare spinner.
