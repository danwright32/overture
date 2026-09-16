# Diagnostics

The read only tools that answer a specific question about a run, a freeze, a check or the live store. Each one reports; almost none of them gate.

A body file for `AGENTS.md`, which carries the one line form of every rule below plus a pointer
here. The index line is enough to tell you a rule APPLIES; it is not enough to apply it, because
the measurement it came from lives here. Read the entry before the rule decides anything.

## Measuring two runs going at once

- **Measuring two runs going at once: `scripts/measure-concurrent-runs.sh` (#2762).** Starts a reachability
  check and a Prep run together and counts what the machine really does, which is the session that unblocks
  the rest of #2620. It spends REAL usage, so it plans and launches nothing without `--yes`, and it is a
  Dan-at-the-machine job rather than an agent one. It refuses three ways before anything is spent: a support
  directory that is or is inside the live one, two queues that share a show (#2765 is what would make an
  overlap safe and it does not exist yet), and a check queue too small to fan out, since
  `split_queue_into_chunks` makes `min(items, OVERTURE_PREP_MAX_PARALLEL)` chunks and a three-show run is
  three claudes rather than the case in question (L101). The evidence it produces is an observed COUNT of
  concurrent processes sampled throughout, not only a wall clock, because two halves that never actually
  overlapped still produce a perfectly good duration. `docs/measure-concurrent-runs.md` is the runbook and
  says how to read what it prints.


## Asking what a freeze actually was

- **Asking what a freeze actually was: `scripts/what-froze-the-queue.sh` (#3760).** Reads
  `freeze-log.ndjson` and prints, per stall, the duration beside the number of RENDER PASSES it spanned.
  It exists because on 2026-09-10 the queue froze for 16.73s at baseline load on a build carrying every
  fix in milestone 80, and nothing could say what it was: one store change costs 350.7 ms end to end,
  measured the same day, so that freeze is forty-eight of them or it is something else entirely, and
  those call for opposite work.
  The count reaches the record the way `surface` already does, which is the part to understand before
  changing it: the MAIN THREAD stamps and the watchdog only READS, because a value the watchdog has to
  ask the main actor for is unavailable at exactly the moment a record is being written (L345). A
  surface that runs the pass and never bumps is caught by `EveryRenderPassIsCountedTests`, derived from
  the source rather than from a list, because a behaviour each call site must opt into is enforced by
  nothing (L27, L621).
  It REPORTS and judges nothing against a cost figure, deliberately: a per-pass cost written into the
  script would be a dated number that rots silently and reads as more trustworthy the older it gets
  (L316, #3487). The decisive reading needs none. A long stall spanning many passes is the render pass
  run over and over; a long stall spanning NONE is something else.
  Read its answer correctly. Three exit codes, and the third is the one that matters: `2` is UNMEASURED,
  because a record written before #3760 is installed carries no count at all, and a log that has not
  turned over must not read as a clean bill (L98, L11). `1` means a stall over a second spanned no pass,
  which is the finding that sends the next diagnosis elsewhere. `0` is attributed. Records it cannot
  judge are REPORTED as unjudged rather than folded into either verdict.
  Its judging half rides along on every push through `scripts/what-froze-the-queue.test.sh`, which builds
  its own logs rather than reading the live one.


## Recording the main thread DURING a freeze

- **Recording the main thread during a freeze: `scripts/watch-freezes.sh` (#3888).** Takes rolling stack
  samples of the live Overture and KEEPS only the ones that line up with a stall the app's own freeze log
  recorded. It is the other half of `what-froze-the-queue.sh`: that one reads the record of a stall, this
  one records what the main thread was doing while the stall was happening.
  It exists because a freeze is over before anybody can start a `sample` by hand, measured at about a
  minute on 2026-08-30 (#3419), and because the alternative left on 2026-09-13 was a macOS microstackshot
  of 22 samples, which DETECTS rather than measures (L355). A throwaway version of this caught the next
  freezes inside minutes and is what settled #3884, at up to 100% of main thread samples in
  `ScoutService.apply`. It was deleted with the session that wrote it, which is why it is here.
  How to run it: `scripts/watch-freezes.sh --minutes 60`, and then use the app. It reads the process
  table, the freeze log and stack samples; it never touches the screen, the keyboard or the mouse, so it
  is not one of the tools that drives Dan's machine and it needs no `--yes`. Kept samples land in
  `~/.overture-mac-test-diagnostics/freeze-watch/`, beside `sample-overture.sh`'s, for that script's own
  recorded reason: this evidence is read days later and the shared temp folder is cleared at boot. The
  throwaway chunks are 2 to 3.5 MB each and go to the repo's scratch instead, where a leak check can see
  them, and are deleted within seconds of being judged.
  Read its answer correctly. Exit `2` is REFUSED: it could not name exactly one running Overture, by the
  full executable path through `scripts/lib/overture-pid.sh`, so nothing was watched. Exit `3` is the app
  going away mid-watch, naming the pid it lost, with whatever it kept before that kept. Exit `0` is a
  watch that ran to its end, and **`kept 0` is a reading, not silence**: it watched, chunks were taken,
  and no stall reached the keep threshold. It says that in words because a watch that found nothing and a
  watch that never happened are different facts (L98, L11).
  The one line beside each kept sample is a SAMPLE's reading and is written to say so. It always prints
  the main thread's total sample count next to any share, because a share without its denominator is not
  a measurement (L355), and it names the DEEPEST frame carrying at least half of them rather than the
  outermost, which is near 100% by construction and says nothing. A sample with no main thread block at
  all reads `UNREADABLE` rather than a zero share: an idle app and a sample whose symbols never resolved
  produce the same empty list.
  `--since` decides which records count as new, and the default is the instant the watch starts, so a log
  holding months of history does not print months of history. Pass an earlier instant to have the records
  already in the log judged too.
  Its judging half rides along on every push through `scripts/watch-freezes.test.sh`, which drives a stub
  sampler and built logs, so every one of the outcomes above is produced rather than waited for.


## Asking what a contact check actually searched for

- **Asking what a contact check actually searched for: `scripts/what-the-check-searched.sh <show>` (#2996).**
  Takes a group name or a natural key and prints, per archived run, the show AS THE RUN WAS GIVEN IT
  beside every web call that run made. Both halves matter and the defect is only ever visible in their
  difference: #2983 was diagnosed exactly this way, by extracting one run's 22 web calls and seeing that
  not one of them named the company whose contact page publishes an address, which turned a vague "the
  check missed it" into a precise defect. It took an afternoon of hand-querying JSONL; it is now one
  command.
  A READER over evidence that already exists, never a new recording. It reads the archived queue
  (#1878, #2760) and the archived event streams (#3446), which share a run stamp.
  Three exit codes, and the third is the one that matters: `0` found, `1` the show appears in no
  archived run, `2` UNMEASURED, meaning there are no archives to look in at all. An empty support
  directory and a show nobody checked leave the same empty result, and the emptiest possible failure
  must not read as the cleanest possible answer (L98, L11).
  Read its answer correctly in one more place. A run whose streams were NOT archived says exactly that,
  rather than reporting no searches: streams have only been kept per run since #3446, so every run
  before that has none, and "no searches" there would be a claim about the check that nobody measured.
  Only routes that reach the WEB are listed; a `Read` or a network-free `Bash` is not a search and
  would pad the list this exists to make readable. And where a run covered more shows than it has
  streams, one stream carries several shows, so the calls are the whole chunk's rather than that show's
  and it says so: per item attribution is milestone 61 Phase 1.3 and does not exist yet.


## Has the producer rule's calibration fallen behind the live feed

- **Asking whether the producer rule's calibration has fallen behind the live feed:
  `scripts/check-producer-corpus-drift.sh` (#2680).** #2554 pinned the producer rule's boundary against
  the real VenueTix feed, committed as `fixtures/venuetix-supertitles/2026-08-13.json`, and
  `SuperTitleCalibrationTests` asserts the exact set of phrases the rule calls a producer. Nothing
  re-measured, so that guard would have stayed green against August's world indefinitely, which is L48
  and L56 exactly: a rule calibrated on a snapshot and then trusted as a contract.
  It fetches the feed with the venue's own Origin header (the same one `VenueTixCalendar.feedRequest`
  sends), and judges both sides with the app's OWN rule, compiled straight from
  `mac/Overture/Domain/ProducerShapedName.swift` rather than reimplemented in the script, because a
  second definition of the producer rule drifts in whichever direction flatters the person who wrote it
  (L107).
  It NEVER rewrites the fixture, on `docs/copy-inventory.md`'s rule since #1994: a new corpus is always
  a change somebody read, and a check that regenerates its own subject defends whatever it produced.
  Read its answer correctly. Three exit codes, and the third is the one that matters: `2` is UNMEASURED
  (the fetch failed, the feed did not parse, it carried events but no supertitle at all, the corpus is
  missing, or the rule would not compile), because a failed fetch and a feed that changed nothing leave
  the same empty difference (L98, L11). `1` is DRIFTED and is ADVISORY: the feed turns over every week,
  so a gate on ordinary churn has its threshold raised until it catches nothing (L93). `0` is in step.
  **Read the BOUNDARY MOVED block, not just the counts.** Arrivals and departures are ordinary; a
  supertitle the rule now calls a producer that the calibration does not carry is the thing to look at,
  because silent over-matching is the failure this area actually has. On its first real run, 2026-09-06,
  the corpus was 24 days old: 28 supertitles had arrived, 42 had gone, and 13 of the arrivals the rule
  accepts (three explicit `Produced by` credits, eight possessive self-producers and two companies).
  The names themselves are deliberately not repeated here: they are real people's, this repository is
  public, and the fixture is where that evidence already lives (L155).
  It is OPT IN and not in `scripts/test-all.sh`: it reaches the network. Its judging half rides along on
  every push through `scripts/check-producer-corpus-drift.test.sh`, which drives all three outcomes
  through the `OVERTURE_VENUETIX_FEED_FILE` seam without a single request.


## Has a fixture sized against the live store fallen behind it

- **Asking whether a fixture sized against the live store has fallen behind it:
  `scripts/check-fixture-corpus-drift.sh` (#3426).** Two cost guards sized their corpus with a number
  measured against the live store once and never moved, and by 2026-08-31 both were exercising a store
  between a fifth and a third smaller than the one that ships. Nothing reported it and nothing could: a
  cost guard sized BELOW the live store stays green the whole time, because it is exercising a smaller
  world rather than failing (L354). It fails in the direction that hides a problem.
  What it checks is DERIVED from the source rather than listed in the script (L96): any declaration
  carrying a `// LIVE-SHAPE: <dimension>` comment on the line above it joins the check automatically.
  What the script does hold is the definition of each dimension against the store, which is the one
  thing a source scan cannot supply, and a tag naming a dimension it cannot measure is REFUSED rather
  than skipped, because a silently ignored tag is a declaration nobody is checking while it reads as
  covered (L100).
  It reads the store through a WAL-inclusive copy, never the bare `.store` file, since recent writes
  live in the `-wal` beside it. Measured 2026-09-02 at 0.06 to 0.09s for the copy and the counts
  together, which is what makes it affordable on the mandatory pre-push gate rather than opt in.
  Read its answer correctly, because it has FOUR outcomes and only one of them fails the run. `1` is
  DRIFTED and is ADVISORY: the store grows every night, so a gate firing on ordinary growth has its
  threshold raised until it catches nothing (L36, L93). `2` is UNMEASURED and DOES fail: a store that is
  present and unreadable, a tag it cannot measure, or a scan that found no declarations at all, each of
  which is a failed measurement rather than a clean one (L98). `3` is a machine with no live store,
  which is the ordinary state on a clone, in CI and in an agent worktree, so it says so and passes; it
  is kept apart from `0` because a run that measured nothing must not read as one that measured and was
  happy. Widen the tolerance for one run with `OVERTURE_CORPUS_DRIFT_TOLERANCE=<percent>`.


## Where the freeze tool's busy threshold actually lands

- **Asking where the freeze tool's busy threshold actually lands: `scripts/analyse-freeze-load.sh`
  (#3464).** `scripts/freeze-measure.sh` calls a process unusually busy at 25% CPU. That number was
  CHOSEN when it was written and said so, because there was no distribution of this Mac's idle CPU to set
  it from. This is the command that reads the one Phase 0 produced, so the premise is re-runnable rather
  than a dated sentence somebody has to believe (L316, L32).
  It reads the `.processes.txt` files beside each measurement rather than the `.json` records, and that
  is the point: the tables hold every process, the records hold only what already crossed the threshold,
  and a reading taken THROUGH the threshold cannot say whether the threshold is well placed (L70).
  Three exit codes, and the third is the one that matters: `2` is UNMEASURED, because no recordings and
  recordings with nothing unusual in them leave the same empty result, and a pile of unreadable files is
  a failed read rather than a quiet machine (L98, L11). `1` is INSIDE THE BULK, meaning more than one row
  in twenty crosses the line so it is naming the ordinary case (L172). `0` is discriminating.
  **Read the per-measurement list, not just the verdict.** The percentile cannot say whether the line is
  in the right place; WHICH processes cross it can. That is how #3464's real finding surfaced: WindowServer
  crossed 25% in six of the first eleven recordings, and those six were exactly the six taken while
  Overture had a window on screen, so every genuine measurement read as contaminated by the compositor
  drawing the frames the measurement exists to time. It is on `fixtures/resting-baseline.txt` now, with
  what that exemption gives up written beside it (L324).
  It is OPT IN and not in `scripts/test-all.sh`: it reads a directory that exists only on Dan's Mac. Its
  judging half rides along on every push through `scripts/analyse-freeze-load.test.sh`, which builds its
  own recordings with a known distribution rather than reading the real ones.


## Scrolling the running app from a script

- **Scrolling the running app from a script: `scripts/scroll-wheel.sh` (#3503).** `cliclick` on this Mac
  has move, click and wait and no wheel at all, so until this the measurement scripts could not scroll
  anything: `scripts/freeze-measure.sh` samples a live process and had no way to make it scroll, which
  left #3439's decision gate able to measure a keystroke and a render pass and not the third thing it is
  specified to compare. `RealScrollInvalidationTests` could already drive a wheel event, but only into an
  `NSScrollView` its own process owns, which settles the SwiftUI mechanism question and nothing else.
  **It DRIVES DAN'S MACHINE, so it refuses without `--yes`** and says what it would do first. It is a
  Dan-at-the-machine job rather than an agent one.
  Two things it does are the two #3480 learned the hard way, and both are the reason to use it rather
  than a fresh `CGEvent` one-liner. It CONFIRMS the scroll landed, by reading the target's vertical
  scroll bar through the accessibility API before and after, because a scroll that did nothing and a
  surface that does not rebuild on scroll produce identical readings and the second is the thing being
  measured (L159). And it posts to the PROCESS by pid rather than to the session tap, so it does not
  need the app to be frontmost, which is what defeated the accessibility route before: Overture is
  `LSUIElement` and never becomes frontmost.
  It targets by EXECUTABLE PATH and refuses when the lookup finds more than one, which is this
  repository's standing rule after a Release app was quit in place of a Debug one (L70); the other
  build being up is a note naming both pids rather than a refusal.
  Read its answer correctly: three outcomes, and the third is the one that matters. `0` LANDED (or SENT,
  under `--no-confirm`, which says so rather than claiming a landing), `1` DID NOT MOVE, which is a real
  finding about the surface and is also what a list already scrolled to its end looks like, and `2`
  UNMEASURED, which is no app, two candidates, an unreadable window tree, or the refusal. UNMEASURED is
  never folded into either of the others, because a scroll that did nothing and a tree that could not be
  read call for opposite next steps (L98, L11).
  The event construction is Swift, in `mac/scripts/lib/post-scroll-wheel.swift`, compiled by `swift` on
  each run rather than built: a tool that needs building before it can be used is a tool nobody uses.
  Its judging half rides along on every push through `scripts/scroll-wheel.test.sh`, which drives every
  refusal and all three outcomes through named seams, so nothing in the suite posts a real event or
  needs an app on screen.


## Asking whether the app itself froze

- **Asking whether the app itself froze: it records that now, and says so (#3435 Phase 2e, #3442).**
  `MainThreadWatchdog` posts a sequenced ping to the main queue every 250 ms from its own Dispatch queue
  and records how late it runs. The record is written by the WATCHDOG and never by the main thread, or it
  could not be written during the freeze it records, and it lands in `freeze-log.ndjson` beside the store
  (catalogued in `docs/contracts.md`). `RootView` reads it at launch and says once, in the app's own
  voice, what the last session found.
  Four things about it are load bearing before changing it. The SURFACE is a closed enum with no
  associated values, so a case that could carry a show's name is impossible to write rather than
  forbidden: the natural spelling of "the surface on screen" is the sheet plus the row that raised it,
  which carries a `groupName`, and it would land in a durable file no repository scanner inspects (L230,
  L222). The main thread STAMPS it and the watchdog only READS it, because asking the main actor at write
  time makes the field unavailable at exactly the moment a record is being written (L345). The retention
  keeps a per-session HIGH WATER entry that is never evicted, because the single reading this exists to
  support is the worst stall of a session and a count cap discards precisely that: an evening of small
  stalls flushes the one long entry out and the eviction count cannot say the largest was among them
  (L191, L63). And a session with NO WATCHDOG says something different from a session with no freezes,
  because an empty file is both (L98, L11).
  It is on a Dispatch queue and never the cooperative pool: it blocks by design, waiting on the main
  thread, and Swift's pool is bounded and does not grow (L241).
  What it costs is MEASURED on every run rather than written down here, for this document's own standing
  reason (#2532, L32): `WatchdogCostTests` prints a `watchdog-cost:` line giving the per-ping share of one
  interval, and `anIdleAppPostsNoMoreThanOnePingPerInterval` bounds how many pings there can be. Read
  those rather than any number in prose.
  #3442's half is the load: each record carries a class (baseline, elevated, unmeasured) AND the one
  minute load average as a number, so a later reader can re-judge the line without the classification
  being the only thing kept (L316). It cannot say WHAT was busy; `scripts/freeze-measure.sh` reads the
  process table and remains what says that.



## Asking what a rotating log lost

- **Asking what a rotating log lost: `scripts/what-the-log-lost.sh` (#3789).** Reads a log and the `.1`
  beside it, prints every rotation the app recorded in either, and says whether any of them destroyed
  content. Defaults to the store backup log, which is the record of whether Dan's live store was copied
  and the one whose loss costs something; `--log` points it at any of the other seven, and `--print`
  dumps the whole retained history oldest first.
  It exists because `LogRotation.cap` keeps exactly ONE previous generation and, until #3789, said
  nothing and had no reader. It copies the live file to `.1`, deleting the `.1` the rotation before it
  wrote, then empties the live file, so every second rotation destroyed a generation; the return value
  was `@discardableResult` and all five call sites dropped it; and nothing in the app or the toolchain
  ever opened a `.1`, which made the preserved copy write-only (L46, L98, L11). The reader ships in the
  same change as the record, for the reason #3763's freeze archive shipped with its own.
  BOTH FILES, always. The rotation AFTER a loss moves that loss's note into the `.1`, so a reader of the
  live file alone would report a clean log while looking exactly like a reader of the whole history.
  Read its answer correctly. `2` is UNMEASURED: there is no log at that path, and a log never written
  and a log deleted are different facts it can tell you neither of. `1` is content GONE, or a rotation
  REFUSED, which are separate findings printed separately: a refusal destroyed nothing and means the log
  is over its cap and still growing, which is the one that needs somebody to look at why. `1` is also
  what a `.1` with no note beside it gets, because that is a rotation from before the app said anything
  and what it cost cannot be recovered. `0` is a log that has never rotated, or one whose rotations each
  kept what they moved.
  The words it greps for and the words `LogRotation.note` writes are a cross-language contract with one
  thing holding them together, `theReaderLooksForTheWordsTheAppActuallyWrites` in
  `ARotatedLogSaysWhatItLostTests`: a reworded note would otherwise leave this matching nothing and
  reporting every log clean (L58). Its own half rides along on every push through
  `scripts/what-the-log-lost.test.sh`, which builds its own logs rather than reading Dan's.


## Looking at Overture while it is frozen

- **Looking at Overture while it is frozen: `scripts/sample-overture.sh` (#3424).** Sampling is the only
  thing that has ever named an Overture freeze correctly, and reading the code first has been wrong
  twice in one week: on 2026-08-30 the source pointed at the Gmail calls in the reconcile tick and the
  sample put every one of 2,646 samples in `NSAppleScript.executeAndReturnError` (#3419), and on
  2026-08-31 two live samples settled the archive freeze in seconds. By hand it is five steps, done
  under time pressure, because the evidence disappears when the app unfreezes: about a minute, measured
  2026-08-30.
  It resolves the pid from the FULL EXECUTABLE PATH and REFUSES when two copies match, through
  `scripts/lib/overture-pid.sh`, which `scripts/freeze-measure.sh` also sources so the two cannot come
  to disagree about which Overture they mean (L263). That rule is the one the global CLAUDE.md was
  amended for, after a Cmd+W meant for a Debug build quit Dan's live app.
  Read its answer correctly, because it has THREE outcomes and the middle one is the point. `0` means
  the sample names frames of Overture's own and they are printed. `1` means the sample was taken and
  names NONE of them, which is a reading to look at rather than a pass: an app genuinely waiting in the
  run loop and a sample whose symbols could not be resolved produce the same empty list (L98, L11). `2`
  is UNMEASURED, meaning no sample exists to read at all. The full file is kept under
  `~/.overture-mac-test-diagnostics/` rather than cited where `sample` puts it, since its own default
  lands in a temp directory macOS clears at boot and this evidence is routinely read days later.
  Only the app's own frames reach the screen; everything else is in the saved file, and a screenful is
  capped with the cap and the real count named, so a truncation never reads as the whole answer.


## Asking what freezes macOS has already recorded

- **Asking what freezes macOS has already recorded: `scripts/check-overture-hangs.sh` (#3425).** macOS
  writes a `.hang` report when an app stops answering the window server, and nothing here read them.
  Measured 2026-08-31: `/Library/Logs/DiagnosticReports/` held two for Overture, both from 2026-08-30,
  one of 6.6 seconds and one of 58 SECONDS, and neither was known to anybody until they were looked for
  while diagnosing a different freeze. The 58 second one is the longest freeze on record for this app and
  it left no other trace.
  Worth having beside an in-app detector rather than instead of one: this source is FREE, the OS writes it
  whether or not our own instrumentation is running or correct, and it works BACKWARDS over what is
  already on disk, where a detector can only see forward from the day it ships.
  It reads the Overture PROCESS BLOCK, never the whole file: a hang report is a system-wide stackshot, so
  every other running process is in it, and reading across the block boundary attributes somebody else's
  stack to this app. Per report it prints when, the duration, the unresponsive line, the app PATH (so a
  Debug hang is never read as a Release one), what the main thread was blocked in, and the app's own
  frames. Each report is COPIED to `~/.overture-mac-test-diagnostics/`, because these rotate, and a copy
  already there is left alone.
  Read its answer correctly. FOUR states across three exit codes, and the third code is the one that
  matters. `1` means reports are on record. `0` means the directories it COULD READ hold none, and it
  names them, so the clean bill states its own scope rather than standing for the whole Mac. `2` is
  UNMEASURED, because a Mac that recorded no hang and a reader that cannot see the folder leave the same
  empty list (L98, L11). Present-but-unreadable and not-there-at-all get different words, since only the
  first is a permissions problem somebody can fix. A partial read still answers and names the half it
  could not see.
  It is OPT IN and not in `scripts/test-all.sh`: it reads a directory that exists only on a real Mac and
  its findings are about the past rather than about the code. Its judging half rides along on every push
  through `scripts/check-overture-hangs.test.sh`, which builds reports in the real shape rather than
  reading this machine's.


## Asking what CPU burns macOS has already recorded

- **Asking what CPU burns macOS has already recorded: `scripts/check-overture-cpu.sh` (#3541).** macOS
  writes an `Overture_*.cpu_resource.diag` when the app burns processor time past a threshold, into the
  same directories as the `.hang` reports #3425 reads, and nothing here read them. Measured 2026-09-04,
  three on this Mac against two hang reports.
  It catches a case the hang reports structurally cannot. A hang report is written when the app stops
  answering the window server; a freeze that never quite stops answering while still burning a core
  leaves no hang report and one of these. The first run of this script on Dan's Mac reproduced #3884 and
  #3886's whole evidence chain in one screen, from `RootView.runScout` down to
  `NSRegularExpression.__allocating_init`.
  A SIBLING rather than a mode of the hang reader, because it is a different file format with different
  fields. What the two share is in `scripts/lib/diagnostic-reports.sh` and written once: which
  directories could be read, how a report is found and kept, and the three-outcome vocabulary (L263).
  **Read the stack as a SAMPLE, not a profile.** It is a microstackshot: a real report here holds 22
  steps over 96 seconds with 145 samples lost, so the counts beside each frame say where the busiest
  thread USUALLY was and say nothing about what share of the time anything cost (L355). The script
  prints the steps line, the samples lost and the sampled duration beside every stack for that reason,
  and says so in its own output rather than leaving it to whoever reads it.
  Three outcomes, the same as the hang reader's: `1` reports are on record, `0` the directories it could
  read hold none and it names them, `2` UNMEASURED because not one could be read.
