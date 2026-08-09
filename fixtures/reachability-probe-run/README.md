# Reachability check marker fixtures (#1813)

`reachability-probe-run.json` is the side marker a reachability check writes when it launches, and the
completion path reads to decide whether the run that just finished was a check or a Prep run. Both sides
are the app (`PrepQueueService.startReachabilityProbe` writes it, `settleReachabilityProbe` reads and
clears it, and `mac/scripts/prep-run.sh` reads its mere presence to decide the run is chunked and runs on
the cheaper model), so there is no second language here to disagree about the shape.

There is a second point in TIME, though, and that is what these fixtures are for. A check runs detached
for twenty minutes or more, and #1809 added a field to this file's shape while that was true, so a marker
written by one build is read by whatever build is installed when the run comes home. Reading it wrongly is
expensive in both directions: a check read as a Prep run drafts over shows Dan never kept, and a Prep run
read as a check ingests probe-safely and discards every draft it wrote, which is exactly what #1809 cost.

- `launched.json`: what the writer emits at launch, and byte for byte the shape EVERY marker had before
  #1809. `settleAttempts` is not merely null here, it is absent, which is the case that matters:
  Swift's synthesized decoding does not apply a property's default value, so a non-optional
  `settleAttempts` would fail to read this file, and the run it would fail on is the paid one the field
  was added to protect.
- `settle-retried.json`: the current shape, as `settleReachabilityProbe` rewrites it after a stamp save
  that would not commit. Its count is one short of `maxSettleAttempts`, so it is the last marker before
  the settle gives up and says so.

Both were PRODUCED BY THE WRITER rather than typed out (L48, the convention `fixtures/update-result/`
already follows), and their contents are measured rather than invented:

- The natural keys are three real ones, read from the live prep queue at
  `~/Library/Application Support/Overture/overture-prep-queue.json` on 2026-08-09 (a queue generated
  2026-08-07). The marker's keys come from exactly that file's items, so this is the real key shape.
- `startedAt` is that same queue's own `generatedAt` stamp, which is not a coincidence: the launch path
  formats one `ISO8601DateFormatter().string(from: now)` and puts it in both places.

No real `reachability-probe-run.json` existed anywhere on the Mac to copy, in the Release handoff folder,
the Debug one, or any backup. That is the file working as designed rather than an oversight: it is written
on launch and deleted on settle, so one only exists while a check is in flight or has been left orphaned.

The trailing newline on each file is for a clean diff and is not what the encoder emits, which is why
`ReachabilityProbeMarkerContractTests` compares parsed JSON rather than bytes. The other reason it compares
parsed JSON is `keys`: it is a `Set`, and Swift's set iteration order is not stable between processes, so
the array's order in these files is arbitrary and a byte comparison would fail at random. A reader that
depended on that order would be wrong, which the fixtures also demonstrate by carrying it unsorted.

`ReachabilityProbeMarkerContractTests` reads both files through `ReachabilityProbeMarker.read`, the same
call the app makes, and fails if what the writer emits today no longer matches what is committed here. To
regenerate after a deliberate shape change, write the two markers through `ReachabilityProbeMarker.write`
and commit the result alongside the reason it changed.
