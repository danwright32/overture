# Diagnostic and check scripts

Each entry names a script, says what question it answers, and says how to read its answer.
Every one of these is opt in unless its entry says it rides along in `scripts/test-all.sh`.
Read the whole entry before acting on what one of these prints: several have three or four
outcomes, and the one that matters is usually UNMEASURED rather than pass or fail.

Split out of `AGENTS.md` in #3640, which was over the character limit for a file loaded
into every session. The text below is unchanged: these are dated measurements, and
rewriting one destroys the record. `AGENTS.md` names each rule and points here.

- **Asking whether the suite cares what year it is: `scripts/check-fixtures-do-not-age.sh` (#2669).** A
  fixture pinned to a literal date and read against the live clock silently changes which state it stands
  for as real time passes it: written as a show two months out, it becomes a show in the past, and the test
  goes on asserting about a case nobody chose. That bit four times in one session while building #2645, and
  one of those tests had spent months asserting that a show 27 days in the past should still be chased.
  The check shifts every dated fixture in `mac/` forward three years, runs the Swift suite, restores the
  tree, and compares the tests that changed verdict against `fixtures/year-sensitive-tests.txt`, which it
  writes itself with `--record`.
  It is OPT IN and not in `scripts/test-all.sh`, because it costs a second full suite run. Run it after
  adding dated fixtures, and periodically.
  Read its answer correctly, which is the part to understand before using it. It does NOT demand that
  nothing is year-sensitive: 39 tests are, measured 2026-08-14, almost all for good reasons (a weekday
  name, an Eastern calendar day, business-day arithmetic, a comparison against a checked-in fixture the
  shift cannot move). Demanding zero would be a gate nobody could go green on. What it asserts is that the
  SET has not changed, and the set grows on its own: a fixture dated ahead of today is unaffected by the
  shift, and the day real time walks past it the same shift starts changing its state, so it joins the set
  and the check names it. **A new entrant is not a defect, it is a test to look at**, which is the whole of
  what #2669 asked for. Either it still asserts what it meant to, and you re-record, or real time walked it
  into a different case.
  **Since #2994 it also sees a date written as a NUMBER, and it reports the tests it cannot shift at all.**
  `Date(timeIntervalSince1970: 1_754_400_000)` is a date, and the string shifter could not see one, which
  is why #2986 (a pinned clock compared against live data that moves every day) was invisible to the tool
  built for exactly that. Only values landing inside the same 1980..2100 window move, so the `0`, `1` and
  `9_999` used as arbitrary instants are left alone, and the shift is CALENDAR arithmetic rather than a
  fixed number of seconds so an epoch literal and a dated string in the same test land on the same day.
  Separately it PRINTS, before the run, every test that reads the LIVE store while pinning a clock. Those
  cannot be shifted at all (their data comes from the real store, which no rewrite of `mac/` touches), so
  a list for a person to read is the honest answer rather than a gate. It names the TEST, or the SUITE
  when the clock is a property beside the tests, never just the file.

  Two approaches were measured and rejected before this one, and both are worth knowing because they look
  reasonable. The issue's own proposal, a source-text guard flagging a file that pairs a literal
  `performanceDate` with a bare `Date()`, matches 70 of 783 test files, so it would fire on the common case
  and be switched off in a day (L93). Shifting only the already-past `performanceDate` literals produced 35
  failures that were almost all its own doing, because a fixture date is often one half of a
  literal-to-literal pair and moving one end breaks it for a reason unrelated to the clock. Shifting the
  whole repo including the app's own source was worse again (69), because it moves constants that are not
  fixtures at all.

- **Asking whether a far-future fixture still asserts anything: `scripts/check-far-future-fixtures.sh`
  (#2366).** A fixture dated `2099-09-19` was written to mean "always upcoming". Once #2359 gave the
  queue a triage window it also came to mean "always OUTSIDE the window", so an assertion about triage on
  that show went on passing while covering nothing. Measured 2026-08-09, 55 tests used that one date,
  across at least twelve files, and nobody could tell which still asserted anything.
  It is the MIRROR of `check-fixtures-do-not-age.sh` and shares its machinery through
  `scripts/lib/fixture-date-shift.sh`: that one moves fixtures FORWARD and asks which tests read the
  relationship between a stored date and the clock, this one pulls the far ones BACK and asks which were
  relying on being outside every window. Both directions are findings: a test that goes RED was asserting
  something true only of a far show, one that goes GREEN could never have fired at all, which is the
  #2366 defect exactly.
  **Read the limit of the instrument before reading its findings, because two of its three runs while
  being built reported nothing but its own artefacts.** The shift is by whole YEARS, measured against the
  clock the FILE ITSELF pins (`private let now = Date(timeIntervalSince1970: ...)`) rather than against
  the year the run happens in, because a test judging from a pinned 2027 is asking about a show 72 years
  ahead of THAT and pulling it back to today puts it behind its own clock. It moves dated strings and
  epoch literals TOGETHER, for the reason `shift_dates` records: `WentByRetirementOnTheTickTests` pins
  its opening night as a string and its clock as a number, and moving one end produced three failures
  that were the check's own doing (L130). Even so, whole years cannot control the distance, so a show can
  land a few days from its clock rather than a few months, and a test that breaks for THAT reason is the
  instrument rather than a finding. `fixtures/far-future-sensitive-tests.txt` records the ones already
  read, with a reason each, so the report is only ever what nobody has looked at.
  **What the first full sweep found, 2026-08-23: nothing.** No test anywhere goes GREEN when its far
  show is pulled near, which is the defect this exists for. The two that go RED are a deliberate
  absurdly-long-range test and one whose show has to be ahead at all. It is OPT IN and not in
  `scripts/test-all.sh`: it runs the whole Swift suite twice.

- **Asking whether the suite cleans up after itself: `scripts/check-temp-dir-leaks.sh` (#3065).** The
  Mac suite created scratch directories under the per-user temp folder and never removed them, and macOS
  clears that folder only at boot. Measured on this Mac 2026-08-22, on an uptime of 8 days: 952
  `debug-seed-test`, 560 `census`, 336 `prep-results`, 224 `prep-reply-cancel`, 224 `performer-failure`,
  112 each of `scout-snapshot`, `scout-extract-cancel` and `overture-test`, and 56 each of
  `venue-identity`, `no-repo`, `debug-seed-missing` and `debug-seed-gmail-missing`. Every count is a
  multiple of 56, the number of suite runs, so the leak was about 52 directories per run, and this repo
  amplifies the rate by running its suite from worktrees, many copies against one shared folder.
  The fix is `mac/TestSupport/TemporarySandboxes.swift`, not a review: hold one as a property of a
  `final class` suite and Swift Testing's per-test instance release makes its `deinit` real teardown that
  no call site can forget. **Counting call sites will not find this defect**, which is worth knowing
  before trying. Downbeat had it too and had 96 `createDirectory` calls against 95 `defer` cleanups,
  which reads as balanced, while leaking 52 per run, because one private helper called by many tests
  multiplies a single missing teardown. Overture has 166 such call sites across 136 files.
  It is OPT IN and deliberately NOT in `scripts/test-all.sh`, for the same reason as
  `check-fixtures-do-not-age.sh`: it runs the whole Mac suite to take its before and after. Its JUDGING
  half rides along on every push through `scripts/check-temp-dir-leaks.test.sh`, which drives the
  `--before/--after/--log-file` seam without paying for a run.
  Read its answer correctly. It has THREE exit codes, not two, and the third is the one that matters: a
  suite that cleans up perfectly and a suite that NEVER RAN leave the same empty before-and-after
  difference, so judging on that difference alone reports the emptiest possible failure as the cleanest
  possible pass (L98). Proof that tests ran comes from the run's own output, and 2 means unmeasured. The
  prefixes it judges by are DERIVED from the test sources in four forms (`make(named:)`,
  `reserve(named:)`, `inSandboxNamed:` and the not-yet-converted `appendingPathComponent` plus UUID
  shape), because reading only the last would stop covering a suite at the exact moment that suite was
  fixed (L96), and deriving none is reported as unmeasured rather than clean.
  It found a real leak the moment it was first run, after every site #3065 named had been converted: six
  `prep-results` files from `PrepResultsConsumedOnceTests`, which nothing in the issue mentioned. That is
  the check working rather than the conversion having been careless.

- **Asking whether test data names a real person: `scripts/check-test-identity-provenance.sh` (#3110,
  #3131, #3140).** `TestDataEmailDomainGuardTests` judges an address by its DOMAIN, so anything on a reserved
  TLD passes. That closes the deliverability half and leaves the identity half open, because
  `arealpersonsname.example` is reserved and still names a real person in a PUBLIC repository. #2839's
  scrub replaced only the domain, so a scrubbed person routinely survived as the LOCAL PART of the very
  address that replaced them.
  What it runs on is EVIDENCE, not a pattern, and the evidence was measured before it was built: a name
  whose first appearance in this repository is a privacy SCRUB commit was minted by that scrub and is
  invented, and one whose first appearance is an ordinary FEATURE commit was written by somebody with a
  real page open. Measured 2026-08-22, `git log -S<name> --reverse` separated all eighteen names #2834
  scrubbed from `Corin Hale` and `Nora Calder`, which were about to be scrubbed by mistake.
  **#3110 named two other candidate answers and both were rejected, which is worth knowing before
  reaching for either again.** Checking a domain label against the display names in the same test file
  does not discriminate at all: an INVENTED personal-name domain appears as a display name in its own
  test exactly as reliably as a real one, so the rule fires identically on the correct fix and gets
  switched off within a day (L93). A periodic AI review over the corpus was rejected once the cheaper
  answer above turned out to exist, and because a judgement nothing records is one the next sweep makes
  again from scratch.
  It REPORTS and does not refuse, deliberately. Plenty of feature-introduced names are perfectly
  invented, so a gate on "introduced by a feature commit" would fire on the common case. What it
  produces is the list of identities NOBODY HAS LOOKED AT YET, each carrying its introducing commit.
  Read its answer correctly. Three exit codes, and the third is the one that matters: `2` is UNMEASURED,
  because an extraction that found nothing and a tree with nothing to find leave the same empty result
  and the emptiest possible failure must not read as the cleanest possible pass (L98). `1` means there
  is something to triage, `0` that everything present is recorded.
  Its baseline, `fixtures/test-identity-provenance.txt`, GROWS, which is the opposite of
  `fixtures/test-data-email-domains.txt` beside it. That one is a ratchet over a defect being paid off
  and may only shrink; this one is a triage log over identities somebody has read, and new invented
  identities legitimately arrive with new tests. `--record` prints what it is about to add for that
  reason: recording without reading the list is how a count driven to zero stops being a measurement
  (L182).
  **Since #3140 it reads a URL as well as an address**, which is the route neither privacy guard could
  see. `TestDataEmailDomainGuardTests` judges an ADDRESS by its domain and this script reads the
  identities inside a reserved-domain one; a URL was invisible to both, and a contact route in the live
  store is a form on somebody's own site far more often than it is an address.
  `PressContactFormGuardTests` says so in its own comment (its list is "every other form in the live
  store, which must all stay usable"), so the data is a verbatim extract of Dan's real prospect contact
  routes in a PUBLIC repository. Measured 2026-08-22: 201 distinct hosts, 102 on registrable domains,
  and at least eight shaped like one private individual's own name.
  Two details are the mirror of the address half rather than a copy of it, and both matter. A reserved
  TLD is SKIPPED here and KEPT there, because a host on one cannot be anybody's real site while a
  reserved-domain address is exactly where a half-finished scrub leaves a person's name as the local
  part. And it emits EVERY label but the TLD rather than guessing the registrable one, because
  `wraymoorhall.co.uk` puts the name two labels from the end and `pellingborne.org` puts it one: it
  over-reports `tickets` and `co`, which the baseline absorbs once, rather than picking wrong and hiding
  somebody. What it does NOT do is judge whether a label looks like a person's name, which #3110 measured
  and rejected: the provenance lookup discriminates and the spelling does not.
  Both extractions feed ONE `sort` at the end of the function, because the caller compares with `comm`,
  and two locally sorted lists concatenated are not a sorted list: `comm` answers nonsense rather than
  failing on that.

  Two things it does that look like over-engineering and are not, both caught by its own fixture. The
  token is kept VERBATIM apart from lowercasing, punctuation included, because `git log -S` searches for
  a literal string and a normalised `margueriteeddowes` is in no commit anywhere, so the lookup answers
  "no commit found" in wording that reads as a shrug. And the lookup is NOT scoped to the scanned roots,
  even though scoping is faster, because a pathspec does not follow a rename and a fixture moved under a
  root later has its MOVE reported as its origin, which is wrong in the direction that matters.
  It is OPT IN and deliberately not in `scripts/test-all.sh`: it runs one `git log -S` over the whole
  history per identity. Its judging half rides along on every push through
  `scripts/check-test-identity-provenance.test.sh`, which drives it against a throwaway git repository
  with real commits rather than a stub of `git log` (L52).

- **Asking how much of the Swift suite runs on the main actor: `scripts/check-main-actor-share.sh`
  (#3386).** The main actor is one serial executor, so under `-parallel-testing-enabled YES` two
  `@MainActor` suites in one process cannot overlap however they are written: they queue, and a test
  that awaits anything waits for everything ahead of it. Past its `.timeLimit` it is KILLED, which
  truncates the whole run (#3266). Before this nobody could say how big that queue was.
  It REPORTS and does not refuse, and rides along in `scripts/test-all.sh` as an advisory. Most
  main-actor suites here are main-actor for a real reason: of the 462 files carrying the attribute when
  this was written, 300 touch SwiftData, whose containers are main-actor bound, so a gate would fire on
  the ordinary case and be switched off within a day (L93). What #3386 removed was the other kind, the
  suites that carried it and did not need it: strip the attribute, build, and put it back wherever the
  build says it was load bearing.
  **Two things about that method are worth knowing before repeating it.** A normal build reports
  isolation errors one BATCH at a time, so the loop finds one or two files per round and takes an hour;
  `SWIFT_COMPILATION_MODE=wholemodule` passed through the wrapper reported 37 of them in a single build,
  which is not exhaustive on its own but turns a dozen rounds into two. And the compiler is NOT a
  sufficient guard: `ScrollPassthroughWebViewTests` compiled perfectly without its attribute and then
  crashed the test process part way through a full run, which the short-run gate caught and correctly
  refused to call a pass. A suite touching AppKit or WebKit keeps its isolation whatever the compiler
  says, because the breakage there is at run time.
  Read its answer correctly. Three exit codes, and the third is the one that matters: `2` is UNMEASURED,
  because a tree where no suite could be read and a tree with no main-actor suites leave the same empty
  result (L98). The unit is the SUITE rather than the file, since one file can declare several, and a
  `@MainActor` on a nested helper inside a suite is not counted, because it isolates the helper rather
  than the tests.
  The record is `.overture-main-actor-share` beside the repo, gitignored and per machine, on
  `.overture-hosted-suite-seen`'s precedent: a tracked file rewritten by every run is git noise on every
  branch and a conflict on every merge.

- **Asking which test harnesses hold state for the whole process: `scripts/check-test-shared-state.sh`
  (#3270).** A stored `static var` in a test target is one variable per process, so two tests running at
  once share it. That is the defect standing between this repo and parallel testing: every remaining
  piece of it is a test that fails once in four runs rather than reliably, which is the shape that trains
  people to re-run until green.
  Four of them were found in #3234 by running the suite in parallel and reading which tests went red,
  over four rounds. That costs a full run per round and only finds the ones that happened to collide that
  time. A fifth (`StubURLProtocol` in `CarnegieExtractorTests`, #3269) was found afterwards by hand, by
  listing the mutable statics, which took seconds. This is that listing, kept, so a new one arrives as a
  line in a report rather than as an intermittent failure months later.
  It REPORTS and does not refuse, and it rides along in `scripts/test-all.sh` as an advisory. A new
  stored static is not automatically a defect (it may be covered by a lock, or unable to collide), so a
  gate would fire on the ordinary case and be switched off within a day (L93). It rides along rather than
  sitting behind a command nobody types, which is what #2773 cost: the tool shipped, nothing ran it, and
  17 entries had accumulated by the time anybody looked. It is one grep.
  Read its answer correctly. Three exit codes, and the third is the one that matters: `2` is UNMEASURED,
  because a tree with no Swift read and a tree with no shared state in it leave the same empty result,
  and only exit 2 fails the run (L98, L11). What it judges as a subject is a STORED mutable static; a
  COMPUTED one derives its value on every read and holds nothing, and computed is by far the commoner
  shape in these targets (a `liveStoreURL`, a source root, a lazily built fixture), so counting those
  would fire on the ordinary case. Prose is not a declaration either: three files in the tree explain in
  a comment why they are NOT a `static var`, and a reader that counted those would report the code that
  fixed this defect as an instance of it. The one stored shape that LOOKS computed, a closure initialiser
  (`static var x: T = { ... }()`), is treated as stored, which is what it is.
  Its baseline, `fixtures/test-shared-state.txt`, GROWS, like `fixtures/test-identity-provenance.txt` and
  unlike `fixtures/test-data-email-domains.txt`: it is a triage log over declarations somebody has read,
  not a ratchet, and new harnesses legitimately arrive with new tests. Each line carries the REASON, which
  is the point of the file: which named lock accounts for it. `--record` preserves a reason already
  written and marks a new entry `NOT YET EXPLAINED`, and prints what it is adding, because recording
  without reading is how a count driven to zero stops being a measurement (L182).
  **The reason is prose, so a second guard checks it is still true.** `SharedStateWiringTests` asserts
  that every suite MENTIONING one of the stubs carries that stub's trait, derived from the files rather
  than from a list, so a suite that loses its lock in a refactor is red rather than intermittently red
  months later. `.serialized` is deliberately not accepted as the answer: it orders a suite's own tests
  and the interference comes from OTHER suites, which is why `SourceFetcherTests` carried `.serialized`
  and still failed.

- **Before implementing a decision Dan has REVERSED, list the tests that assert the old one:
  `scripts/find-tests-naming.sh <symbol> [<symbol> ...]` (#3163).** It prints every test in either Swift
  test target that names any of the symbols, attributed to the `@Test func` that encloses the mention, or
  to the SUITE when the mention sits in a helper or a comment outside any test, which it labels rather
  than folds in.
  Why the test rather than the file, which is all `grep -rl` gives: 14 files name `isAwaitingNudge` here,
  and the unit somebody has to decide about is each test inside them. A test asserting a decision that has
  since been reversed is not stale coverage, it is the guard DEFENDING the rejected behaviour, so it is
  deleted rather than adjusted (L252).
  It exists because that went wrong on 2026-08-23 with #2968. Dan reversed the rule so a show dismissed
  after being emailed owes no nudge; two tests asserted the opposite, in two files, both written the same
  day. One was found by reading and replaced, the other was MISSED and surfaced only by a full suite run
  twenty minutes later.
  A TOOL, never a gate, and #3163 says why: most tests naming a symbol are legitimately untouched by a
  reversal, so anything that refused would fire on the common case. Three exit codes, and the third is the
  one to read: `1` means NO test names any of the symbols, which is usually a symbol spelled differently
  in the tests than in the app, and a reversal implemented against an empty list is one nothing was
  checked for (L98). A COMMENT naming the rule is reported exactly like an assertion, because a comment
  asserting the old rule misleads the next reader just as much.

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
