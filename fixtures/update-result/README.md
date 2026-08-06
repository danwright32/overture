# update-result fixtures (#2188)

`update-result.json` is how a run of `mac/scripts/update-overture.sh` tells the app how the update went.
Its writer is shell (`mac/scripts/lib/update-result.sh`) and its reader is Swift (`UpdateAttempt.record`),
with no run in between, so nothing but a shared sample can catch the two disagreeing about the shape.

Both files here were PRODUCED BY THE WRITER rather than typed out, which is the point (L48, L52): a
hand-written sample can only ever confirm the assumption of whoever wrote it, and a key renamed on the
shell side would leave a Swift decode test passing against a shape that no longer exists. The app would
then read every real record as absent, and report every refusal as a run that never started.

- `refused.json`: the case Dan met on 2026-08-06, work in progress in the checkout.
- `running.json`: written before the run decides anything, which is what makes "nothing at all" mean the
  run never started rather than that it died.

Both are checked from both sides: `UpdateAttemptTests` decodes them and asserts what the app makes of
them, and `mac/scripts/update-overture.test.sh` regenerates them through the writer and fails if what it
produces no longer matches what is committed here (the `at` timestamp excepted, being the one field that
is different every time by design).

To regenerate after a deliberate change, run `mac/scripts/update-overture.test.sh`, which prints what it
got, and commit the new files alongside the reason they changed.
