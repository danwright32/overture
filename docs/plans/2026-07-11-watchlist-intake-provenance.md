# Overture watchlist: manual lead intake, a standing list of watched sources, and per-prospect provenance (#386 / #768 / #771)
Produced by `/plan-council`: 6 independent specialist agents (architect, backend, data, product, UX, red-team), 21 agents total, rival whole options each championed and red-teamed, scored against criteria fixed BEFORE any option existed, then reality-checked against the real code over 2 correction rounds.
## Reality-check verdict: needs-fixes
The plan below is grounded but still carries the following known-wrong details. Fix these before implementing the phases they sit in.
- Phase 0b's "count the run's member rows into skipped" is not implementable against today's GroupedRun (RunGrouping.swift:17-22), which carries only row/runEndDate/partOfRelatedRun/runSourceURLs. It has no member count and no member list, and runSourceURLs is run.compactMap { $0.sourceListingURL }, which silently omits exactly the URL-less members Phase 0 exists to fix. Fix: when Phase 0 adds id: Int to RunRow, also add memberIds: [Int] to GroupedRun, and count gr.memberIds.count. Phase 0 and 0b then become one coherent change to the same struct.
- WatchedSource.id: String will fight SwiftData. PersistentModel already refines Identifiable via persistentModelID, and a stored `var id` collides with that conformance. It is also not this codebase's convention: Prospect has no id, it has @Attribute(.unique) var naturalKey (Prospect.swift:11). Rename to @Attribute(.unique) var sourceId: String, which also matches every call site the plan already writes (sourceIds, sourceId:, ScoutPagePin.url(for sourceId:)).
- Phase 3 under-budgets its own test cost. The plan carefully counts the 34 ScoutService.apply sites and 25 past-dated literals but never mentions FeedReconcileTests.swift, which has 10 FeedReconcile.reconcile call sites (lines 28, 35, 42, 50, 57, 82, 90, 98, 107, 115). Deleting scoutedHosts/isFromScoutedSource and moving to a per-source signature rewrites all of them, and :98 and :107 assert the carnegiehall.org substring behavior being deleted. Phase 3 is the largest phase in the plan, not the tidy one it reads as.

### Adjustments the check confirmed
- There is no MigrationPlan or VersionedSchema anywhere in the app (grepped: zero hits). The container is a bare Schema([...]) relying on SwiftData lightweight migration, and Prospect.swift:217-219 states the convention explicitly: "Defaulted so existing records and older results files migrate cleanly without an explicit migration plan." This supports sourceIds: [String] = [] (exact precedent: runSourceURLs: [String] = [] at :222) and a new additive entity, but it means the launch backup is the ONLY safety net, so rehearsing the Phase 2 migration against a clone of the live store is load-bearing, not ceremony. StoreSchemaGuard's expectedTable = "ZPROSPECT" is unaffected by a new ZWATCHEDSOURCE table.
- Make the empty-sourceIds case an explicit test in Phase 3. A Prep-created or non-Carnegie prospect will have sourceIds == [] and can never satisfy "at least one of its sourceIds is in the successfully-checked set", so it accrues no misses. That is exactly today's behavior for a non-carnegiehall.org URL under isFromScoutedSource, which confirms the backfill's blast radius really is just Carnegie rows.
- Phase 0 is cheaper than it reads: RunGrouping.RunRow has only 2 construction sites in the entire repo (ScoutService.swift:151 and RunGroupingTests.swift) and GroupedRun has zero in tests. Default the new field (var id: Int = 0) and the single test site still compiles; the synthesized Equatable then includes id, which is harmless because no test compares GroupedRun values.
- RunLog lives inside DetachedRunOutcome.swift:35, not its own file. RunLog.scoutExtractURL goes there, alongside prepURL (:36) and replyClassifyURL (:40).
- ProspectMutations.setOrgDoNotContact (ProspectMutations.swift:306-312) already takes context: ModelContext, so it can fetch [WatchedSource] for the new OrgDoNotContact.mark/unmark signature without changing its own signature. Worth naming the exact site rather than "the queue/detail UI".
- Minor line drift, all real but all off by a few: SkipReason is ProspectAssembler.swift:41 (plan says :36); AssembledProspect is :8-39 (plan says 7-38); RunTimeouts.scout is :21 with its "in-process run" comment at :20 (plan says :20/:19); ScoutFailure's "Couldn't reach Carnegie's calendar feed" is :16 (plan says :17); AlgoliaCalendar.windowBoundsMs is :29 (plan says :30); Outcome.warning is ScoutService.swift:30-38 (plan says :33-41).

## Scores
- **source-platform**: 8.7
- **intake-first**: 7.6
- **api-extraction**: 6.3

## Winner: Per-source platform (durable foundation)
Treat multi-source as an architectural change and pay for it once. A SourceExtractor protocol takes a Sendable snapshot struct (never the @Model, since ScoutService is @MainActor and SwiftData models are not Sendable under Swift 6) with two conformers: Algolia for Carnegie and generic HTML for everything else. ScoutService.apply, FeedReconcile and feed health all become per-source: scoutedHosts is deleted, the three global UserDefaults health keys move onto the WatchedSource row, and reconcile runs only for a source whose check both succeeded and returned a trustworthy non-empty feed. A source that was hash-skipped, budget-deferred or failed accrues nothing. A normalized content hash (script/style/nonce stripped) is treated as a correctness mechanism, not just a cost lever: if the page did not change, the extractor does not run, so an extracted title cannot drift between runs and re-key a prospect into a duplicate while the original gets marked gone. The hash is stamped only after a successful ingest, never at fetch time. The extraction contract returns a per-source page verdict (upcoming listings, all past, no dated content, unreadable) so a quiet off-season and a dead URL stop being indistinguishable, which is the failure Dan named. On the Prospect side, sourceId is a plain optional String set on insert only, never a @Relationship (a cascade delete from a source row would take every prospect it ever produced, including sent emails and live threads). Cross-source duplicates are flagged, never merged and never deleted. The Sources sheet grades Watching / Failing / Stopped at their request as words plus icons plus separate sections, so 'broken' can never read as 'they asked us to stop'. A failing source never auto-deactivates.

**Key choices**
- SourceExtractor seam with kind dispatch; Carnegie is row one and keeps its Algolia path
- Per-source apply, reconcile and health; delete scoutedHosts, move the health baseline onto the row
- Normalized content hash as correctness plus cost lever, stamped only after ingest, hit rate visible per source
- Extraction contract returns a page verdict, not just events, so healthy-zero and broken are distinguishable
- Pure SourceSchedule (lastCheckedAt, budget, staleness order); first check imports the whole upcoming season as a named reviewable batch reusing QueueView's focusedKeys
- isActive and health are separate fields: only orgRefused or removedByDan deactivate; OrgDoNotContact.mark deactivates only a source whose own orgName matches, never the one that surfaced the prospect
- Cross-source duplicates detected and linked, never auto-merged
- Still claude -p via DetachedRunner, with per-source incremental results so a run that dies at source nine keeps sources one to eight

**Cost:** Free. Same Max plan, same DetachedRunner, no API key and no new service. The spend is build time and a live-store migration, not dollars. Constraint that comes with free: the detached run only fires when the app is open, and a large first-run extraction competes with Prep for the same Max-plan rate limit.

## Rival options considered

### Intake first, insert-only watchlist (thin slice) (`intake-first`)
Ship the highest-converting funnel first and add sources behind a deliberately narrow blast radius. Phase 0 fixes the confirmed data-loss bug in ScoutService.apply (events sharing one listing URL silently collapse in prospectByURL, ScoutService.swift:161-177) with a failing test, in its own commit. Then #386 lands alone: a Cmd+N sheet where Dan pastes a blob (link, flyer text, Instagram caption), a detached claude -p run parses it, and a confirm sheet shows the show it found plus any recurring calendars behind it, all editable. The show enters through the existing EventClassifier / ProspectAssembler / upsert chain, never a hand-built insert, so blocked dates and the #769 do-not-contact suppression cannot be bypassed. Then #768/#771: WatchedSource as a new standalone @Model, Carnegie seeded as row one with kind .algolia still dispatching to CarnegieExtractor (never to the AI path, since the rendered Carnegie page shows only about three days), Prospect gains a plain optional sourceId String backfilled to Carnegie. The decisive scope cut is FeedReconcile: scoutedHosts stays exactly ["carnegiehall.org"] and non-Carnegie sources are insert-only, never disappearance-reconciled. That sidesteps the silent-cancellation landmine entirely rather than rewriting per-source health to survive it. Non-performances (film screenings, talks, galas) are gated out on an eventKind returned by the extraction contract, counted and inspectable, because without that gate twenty sources fill Dan's already-untriaged queue with junk.

**Cost:** Free. Reuses DetachedRunner and claude -p on Dan's existing Max plan. No API key, no new service, no recurring spend. The hidden cost is capability, not money: no disappearance detection on new sources, and a page that renders its calendar in JavaScript reports as loudly failing rather than being read.

### Per-source platform (durable foundation) (`source-platform`)
Treat multi-source as an architectural change and pay for it once. A SourceExtractor protocol takes a Sendable snapshot struct (never the @Model, since ScoutService is @MainActor and SwiftData models are not Sendable under Swift 6) with two conformers: Algolia for Carnegie and generic HTML for everything else. ScoutService.apply, FeedReconcile and feed health all become per-source: scoutedHosts is deleted, the three global UserDefaults health keys move onto the WatchedSource row, and reconcile runs only for a source whose check both succeeded and returned a trustworthy non-empty feed. A source that was hash-skipped, budget-deferred or failed accrues nothing. A normalized content hash (script/style/nonce stripped) is treated as a correctness mechanism, not just a cost lever: if the page did not change, the extractor does not run, so an extracted title cannot drift between runs and re-key a prospect into a duplicate while the original gets marked gone. The hash is stamped only after a successful ingest, never at fetch time. The extraction contract returns a per-source page verdict (upcoming listings, all past, no dated content, unreadable) so a quiet off-season and a dead URL stop being indistinguishable, which is the failure Dan named. On the Prospect side, sourceId is a plain optional String set on insert only, never a @Relationship (a cascade delete from a source row would take every prospect it ever produced, including sent emails and live threads). Cross-source duplicates are flagged, never merged and never deleted. The Sources sheet grades Watching / Failing / Stopped at their request as words plus icons plus separate sections, so 'broken' can never read as 'they asked us to stop'. A failing source never auto-deactivates.

**Cost:** Free. Same Max plan, same DetachedRunner, no API key and no new service. The spend is build time and a live-store migration, not dollars. Constraint that comes with free: the detached run only fires when the app is open, and a large first-run extraction competes with Prep for the same Max-plan rate limit.

### In-app API extraction (paid, unattended) (`api-extraction`)
The same per-source platform as option two, but the generic extractor calls the Anthropic API in-process instead of shelling out to claude -p. This is the only option where the daily auto-scout actually works unattended. Today every AI path in Overture is a detached claude -p run that DetachedRunner fires with /bin/sh and never waits on, so it cannot tell that the process failed to start, and ReconcileScheduler explicitly never triggers an AI path. That means with options one and two, HTML sources are only re-checked when Dan has the window open, and a bulk first run can eat the Max-plan capacity Prep needs. An in-process client keeps runScout a single awaited call with real per-source progress, makes the extractor a protocol you can stub in the Swift test suite (no fixture-only spec on the runner side), lets the scout run from launchd with the app closed, and removes two JSON contracts, a runbook, an importer and a hand-set UserDefaults script path from the surface area. Everything else is identical to option two: per-source reconcile and health, normalized hash gate, page verdict, junk gate, Sources UI, Carnegie on its Algolia path. The hash gate matters more here, not less, because it is now literally the bill.

**Cost:** Roughly $1 to $5 a month, order of magnitude, and it needs a paid Anthropic API key that does not exist today. With the hash gate only changed pages are extracted, so a typical day is a handful of sources at about 25k tokens each (well under $0.25 on Haiku) and a worst case cold day of 50 sources is a dollar or two. What the money buys over free: the daily scout actually runs when Dan is not at the machine, extraction stops competing with Prep for Max-plan capacity, the AI path becomes testable in the Swift suite instead of spec-by-fixture, and a run that fails to launch can no longer fail silently.

## Why the winner won
Winner: source-platform, with the runner-up's phasing grafted in.

The decision turns on the 30% criterion, and one verified fact settles it. Feed health today is a single number (`events.count`, ScoutService.swift:57) written into three global UserDefaults keys, and `FeedReconcile.reconcile` refuses to run at all unless `feedIsTrustworthy(currentCount:baseline:)` passes against that one baseline (FeedReconcile.swift:85). Add a second source and that singleton becomes structurally unable to distinguish "source 7's scraper died" from "source 1 had a big season". Both of Dan's named must-nots (never silently stop checking a source; a dead scraper and a quiet off-season look identical) live inside that one design flaw. Only source-platform fixes it by construction: health and reconcile move onto the WatchedSource row, `scoutedHosts` is deleted, and a source that was hash-skipped, budget-deferred or failed accrues nothing.

Intake-first's counter is to sidestep reconcile entirely by keeping new sources insert-only, which is a genuinely smart, zero-code scope cut at the flagging layer. But its red team is right, and the code confirms it: the flagging layer (`isFromScoutedSource`) and the counting layer (`feedIsTrustworthy` against the merged baseline) are two separate gates, and the plan only scopes one of them while explicitly cutting per-source health baselines for v1. That leaves an existing, shipped, carefully-tuned safety mechanism (#150/#152) being fed multi-source seasonal noise, and per the spike's own finding that off-season zero is the normal state, that noise is guaranteed. It degrades silently, with no error and no log line, which is the exact failure class the project's rules exist to prevent. It also leaves the spike's single biggest cost lever (the content hash) unspecified.

api-extraction makes the panel's single best individual observation (DetachedRunner literally sends stderr to /dev/null and cannot report that a run failed to start) and then spends it on the one thing it cannot have: it needs a paid key that does not exist, and its headline benefit, unattended AI extraction, is precisely the boundary ReconcileScheduler's own header says was deliberately walled off across four files per #237, which the option never acknowledges. Cost is first-class here and the free option scores higher on the heaviest criterion, so the paid path does not earn its bill. If Dan later wants unattended checks, that is an escalation to him with #237 reopened on purpose, not a panel decision.

Build effort played no part. Source-platform is the biggest diff of the three and I am choosing it anyway, because the alternative is migrating Dan's live store once now and again later to retrofit the architecture, spending the interval with a scout that can mark his kept, drafted, already-emailed prospects as disappeared whenever one source has a bad day, in a feature whose entire promise is that nothing he asked to watch is ever quietly dropped.

Non-negotiable additions to the winner before it ships (from the red teams, all of which I judge fixable rather than fatal):
1. Phase 0 is intake-first's prospectByURL fix, its own commit, failing test first, before any watchlist code. This feature is what fires that bug.
2. #386 manual intake ships as the FIRST slice, before any source is auto-checked. It puts the new AI extraction path in front of a human on a confirm sheet before it ever writes to the live store unattended. Best sequencing argument in the panel.
3. The scout's progress surface must be redesigned in the same work, not assumed. CLAUDE.md's rule is binding: N per-source subprocesses behind one indefinite "scouting..." spinner is a defect. Started, still-alive (per-source count, elapsed), and failed/stalled must be visibly distinct, and the marker-file guard must generalize to N sources so one hung source cannot block the rest.
4. Rehearse the SwiftData migration against a CLONE of the real store before it touches production. The launch-time backup is recovery, not prevention.
5. Measure the real hash-skip hit rate on the seven spike sites across repeated daily runs before scaling source count, and hash the extracted listing region rather than the whole page, so carousels and session tokens cannot defeat the lever.
6. A budget-deferred source must render as a distinct, visible state ("not checked today"), never as silently fine, and never as failing.

### Runner-up ideas grafted into the winner
- Phase 0: fix the confirmed prospectByURL last-write-wins collapse (ScoutService.swift:161-177) with a failing test in its own commit, BEFORE any watchlist code. Verified real: two events sharing one listing URL silently become one, and the loser is not even counted in skipped. Carnegie's unique-URL Algolia feed is the only reason it has never fired; a generic HTML listings page fires it routinely. (intake-first)
- Ship #386 manual intake as the first slice, standalone. It converts on day one with zero new sources, and it exercises the entire new AI extraction path (DetachedRunner, versioned JSON contract, fixtures) on a path where a bad parse is caught by a human on a confirm sheet instead of written into the live store overnight. Put the extractor in front of a person before letting it run unattended. (intake-first)
- Route intake through EventClassifier / ProspectAssembler / upsert, never a hand-built insert, so blocked dates and the #769 do-not-contact suppression cannot be bypassed. Makes the one unrecoverable mistake structurally impossible rather than a matter of care. (intake-first)
- Treat insert-only as the DEFAULT state for a source until it has earned a health baseline of its own: a new source never accrues misses on its first N runs. That is intake-first's blast-radius cut, kept as a per-source property instead of a global one, so it composes with per-source reconcile instead of replacing it. (intake-first)
- Keep the per-source health count strictly per-source: never let a merged multi-source events.count feed a shared baseline. Carnegie keeps its own baseline so the shipped #150/#152 self-heal machinery keeps working exactly as tuned. (from intake-first's red team, which found the counting-layer gap the panel had assumed away)
- The SourceExtractor protocol must have a stub conformer usable directly in OvertureTests, so the extraction rules (unchanged page is skipped without a call, past-dated listings filtered, a 429 marks the source failing without deactivating it, the same show from two sources dedupes through naturalKey, the budget stops the loop at N) are real Swift unit tests rather than fixture-plus-runbook specs. Achievable even with a detached claude -p real conformer. (api-extraction)
- Schema-constrain the extraction output rather than parsing it hopefully out of a results file, and make every per-source failure a typed, named error on the source row (401, 429, timeout, unreadable page) so 'a failing source keeps reporting as failing, visibly, every run' is actually implementable. (api-extraction)
- If Dan ever escalates to the paid API path: the key goes in a 0600 file via SecureFileWrite.writeOwnerOnly, NOT the Keychain. GmallCredentials.swift already explains why (ad-hoc code signing churns Keychain ACLs and prompts on every build). Also noted: prompt caching is not a real lever here (the stable prefix is under Haiku's 4096-token minimum), so the content hash is the only cost mechanism that works. (api-extraction)
- Raw-HTTP-first with a headless-render fallback triggered by the page verdict, not skipped: the spike confirmed 1 of 7 sites (Third Street Music School) renders its calendar in JS with zero event data in raw HTML, and that small-org template-site profile is close to the median new source #768 targets. (from api-extraction's red team)

---

# The plan

## What this is

Three issues, one architectural change. Today the scout's unit of work is "the feed" (singular). `ScoutService.runScout` calls `CarnegieExtractor().extract()` and folds one number, `events.count`, into three global UserDefaults keys that gate whether `FeedReconcile.reconcile` runs at all. Multi-source is not a feature bolted onto that; it changes the unit of work from "the feed" to "a source". This plan pays for that once, and ships a converting slice (manual intake) first.

Verified against the code on main (every line number below was read, not recalled):
- `mac/Overture/Integration/ScoutService.swift:42` hardcodes `CarnegieExtractor()`.
- `ScoutService.swift:57` writes one health state from `events.count`; the accessors at lines 84 to 115 persist it under `scoutLastHealthyFeedCount` / `scoutDegradedStreakCount` / `scoutLastDegradedFeedCount`.
- The upsert/dedup chain lives in `ScoutService.apply` at `ScoutService.swift:186-206` (exact `naturalKey`, then `matchByAnyRunURL`, then `matchByStableSource`), with the helpers defined at `:254` and `:267`. **Both helpers require a URL.**
- `ScoutService.swift:239` currently calls `today: QueueModel.easternToday()` for reconcile. `QueueModel` lives in the UI layer (`mac/Overture/UI/QueueView+Model.swift:342`) and is a one-line wrapper over `EasternDate.today` (`mac/Overture/Domain/EasternDate.swift:31`). Domain and Integration code must call `EasternDate.today()`; this plan fixes that call site as it touches it.
- `mac/Overture/Domain/FeedReconcile.swift:19` is `static let scoutedHosts: Set<String> = ["carnegiehall.org"]`; `reconcile` refuses to touch anything unless `feedIsTrustworthy(currentCount:baseline:)` passes against that single global baseline.
- `mac/Overture/App/OvertureApp.swift:17` is `Schema([Prospect.self, Recipient.self])`. Any new model migrates Dan's live store.
- `mac/Overture/Integration/DetachedRunner.swift:35-42` runs `'<script>' >/dev/null 2>&1 &`. It cannot report that a run failed to start.
- `mac/Overture/App/ReconcileScheduler.swift` header: it "deliberately NEVER triggers a Prep run, a reply-classify run, or a scout: every `claude -p` / AI path stays attended (window-only), per the #237 plan."
- `mac/Overture/Domain/Prospect.swift:11` is `@Attribute(.unique) var naturalKey: String`; `Prospect.swift:573` is `makeNaturalKey(groupName:performanceDate:venue:)`; `Prospect.swift:286` is `disappearedFromFeed` (`missedScoutCount >= FeedReconcile.goneThreshold`, threshold 2).
- `mac/Overture/Domain/ProspectAssembler.swift:36`: `SkipReason` is exactly `{ blocked, suppressed, unreachable }`. `decide` is **pure and clockless**. **Nothing anywhere compares `performanceDate` to today on insert.** Carnegie gets upcoming-only for free from `AlgoliaCalendar.windowBoundsMs` (`AlgoliaCalendar.swift:30`); a generic HTML source would get nothing.
- `mac/Overture/App/RootView.swift:8` already declares `@State private var scoutStartedAt: Date?` and lines 205-206 already render `LiveRunLabel(base: "Scouting", since: scoutStartedAt, timeout: RunTimeouts.scout)`. The started / still-alive elapsed counter for the scout is **already shipped (#435)**. `runScout` is at `RootView.swift:651-675`; its catch at `:669` hands everything to `ScoutFailure.presentation`, whose manual-run copy (`ScoutFailure.swift:17`) hardcodes "Couldn't reach Carnegie's calendar feed".
- `mac/scripts/reply-classify-run.sh:56` already ships `--allowedTools "Read,Write"` and its header (lines 7-8) documents its defaults key correctly as `replyClassifyRunnerScriptPath`, a plain path. `mac/scripts/prep-run.sh:63` grants `"Read,Write,WebSearch,WebFetch,Bash,Skill"` and its header (line 7-8) **misdocuments** its own key as `prepRunnerScriptURL` (a file:// URL) when `PrepQueueService.swift:157` reads `prepRunnerScriptPath` as a plain path. Copy reply-classify's header, never prep's.
- `mac/Overture/Domain/RunTimeouts.swift:20`: `static let scout: TimeInterval = 3 * 60`, commented "an in-process run".
- `mac/Overture/Domain/OrgDoNotContact.swift:33`: `static func mark(orgOf prospect: Prospect, in all: [Prospect])`. It is pure over prospects; it has no `ModelContext` and no view of any source.
- `mac/Overture/Domain/ScoutSchedule.swift:3-5` header: "the scout is read-only (no sending), so auto-running it is safe."

---

## Architecture decision that shapes everything: split fetch from extraction

"N sources means N `claude -p` subprocesses" is a defect: one hung source blocks the marker guard, and a bare spinner behind unbounded subprocesses violates the Progress and Feedback rule. The codebase already has a better shape and it dissolves the problem:

- **Fetching and hashing the LISTINGS page is native and in-process** (`URLSession`, same as `CarnegieExtractor`). This is where a 401, a 429, a timeout, a redirect and a non-HTML body become **typed, named errors on the source row**, unit-testable, no AI involved. It is also where the content hash is computed, so a listings page that did not change never reaches an extractor at all.
- **AI extraction is ONE batched detached run for the sources whose listings page actually changed**, using the exact `PrepQueueService` pattern already shipped: one queue file, one results file, one progress file, one marker, one heartbeat. Not N processes.

**The extract run reads the pinned listings HTML from disk AND is granted `WebFetch` to follow each event's own detail page.** This is not optional. Spike finding 4 (binding) says the listings page usually lacks the venue and sometimes the year, that both live on the event detail page, and that Overture needs the venue because it drives the classifier and the pitch. A run limited to `Read,Write` would return venue-less events for every HTML source, which is the same as returning nothing usable. So:

- The **listings page** is fetched natively, written to disk, hashed, and the queue points the agent at that exact file. Determinism where it matters survives: the listing SET (which events exist, which are gone) is what re-keys prospects and drives reconcile, and that set comes from the bytes we hashed.
- The **detail pages** are fetched by the agent via `WebFetch`, per event, only for the fields the listing does not carry (venue, exact date/year). A detail page is per-event enrichment, not the set. Its drift cannot silently change what the reconcile thinks the feed contains, only what an individual event says.
- `--allowedTools "Read,Write,WebFetch"`. No `Bash`, no `Skill`, no `WebSearch`: this run reads a file, fetches linked pages, writes a results file. This is well-precedented, not novel: `reply-classify-run.sh:56` already ships the tighter `"Read,Write"` grant; only `prep-run.sh` needs the wide one.

This gives a real "3 of 9 sources, 1:12 elapsed" progress surface via the shipped `PrepProgress` / `RunProgress` / `RunLiveness` machinery, and keeps the scout's riskiest new logic (fetch, hash, verdict routing, budget, per-source health, the upcoming-only guard) in Swift where the pre-push test gate can reach it.

---

## Phase 0: fix the run-identity collapse (own PR, failing test first, before any watchlist code)

`ScoutService.apply` builds `prospectByURL: [String: AssembledProspect]` (`ScoutService.swift:163-171`) keyed on `sourceListingURL`, last-write-wins. Phase 3 of `apply` then resolves every grouped run through that dictionary behind `guard let openingURL = gr.row.sourceListingURL` (`:176`). Two consequences, both real and both silent:

1. Two distinct shows sharing one listing URL collapse into one. The loser is not counted in `skipped`, so it vanishes from `found` with no signal.
2. A grouped run whose representative row has no URL (`RunGrouping.representativeRow` picks the shortest title, which may be the linkless one) fails that guard and the entire run is dropped, then re-upserted alone via the `prospectsWithoutURL` path at `:215` with its run metadata lost.

Carnegie's Algolia feed gives every event a unique URL, which is the only reason neither has ever fired. A generic HTML listings page fires both routinely.

Fix:
- Add an opaque `id: Int` to `RunGrouping.RunRow` (the prospect's index in this run's array). It takes no part in grouping or `canon`, it just survives through `GroupedRun.row`.
- In `apply`, key the lookup on `gr.row.id`, not the URL. Delete the `prospectsWithoutURL` second path and the `guard let openingURL` entirely: every grouped run now resolves, so nothing can be dropped.
- Because `id` is the prospect's index into this run's own array, the lookup cannot miss by construction. Use a non-optional array subscript rather than a dictionary, so there is no failure branch to write and no dead `assertionFailure` to test.

Tests (`mac/OvertureTests/ScoutServiceApplyTests.swift`, `RunGroupingTests.swift`), written first. Spend them on the two real cases, not on the impossible one:
- Two different acts, different venues, same `sourceListingURL` gives 2 inserted, 0 lost.
- A dated multi-night run whose shortest-titled member has no URL gives 1 upsert, `runSourceURLs` intact, `runEndDate` intact.
- Regression: an undated, URL-less prospect is still upserted exactly once.

---

## Phase 0b: the upcoming-only guard, placed at the RUN, not the event (own PR, failing test first)

The spike calls an upcoming-only filter **load-bearing** and it does not exist. `ProspectAssembler.decide` skips only `.blocked`, `.suppressed`, `.unreachable`. The spike found a page whose 11 concert dates sat under a "Previous Concerts This Season" heading, and 5 of 7 sites were displaying last season's dates while having zero upcoming shows. Without a native guard, the very first run on a new HTML source floods Dan's queue with concerts that already happened, and the only defense would be trusting the model's prompt.

**The obvious implementation is wrong and would corrupt the store.** Putting the past-skip inside `ProspectAssembler.decide` drops past nights *before* `RunGrouping.group` runs (grouping happens at `ScoutService.swift:152-159`, after the decide loop at `:135-150`). For a run that is currently underway, its opening night falls away, so the grouped run's `makeNaturalKey(groupName:performanceDate:venue:)` shifts on every subsequent scout. Today the rescue is `matchByAnyRunURL` (`:194` / `:254`, #132), which re-keys in place ONLY if a stored prospect shares one of the run's member URLs, and `matchByStableSource` (`:201` / `:267`) also requires a URL. The spike's own Bargemusic case is a month-grid whose cells may carry no per-event link, so `runSourceURLs` would be empty, the rescue never fires, the show re-inserts under a new key as a duplicate, and Dan's keep/dismiss is silently lost. Phase 0's opaque `id` does not help: it is per-run, not stable across runs.

So the guard goes at **run granularity, after grouping**, where the run's closing date is known:

- Add `case past` to `SkipReason` (the shared skip vocabulary stays in one enum).
- Add one pure, clockless helper on `ProspectAssembler`:
  `static func isPast(date: String?, runEndDate: String? = nil, today: String) -> Bool` — judged against `runEndDate ?? date`, so **a run whose last night is still ahead is never past**; a nil date is never past (dateless events are already handled downstream as undated).
- **`ProspectAssembler.decide` stays pure and clockless.** It gains no `today` parameter and never returns `.past`. This deliberately diverges from the reality-check's suggested fix (thread `today` into `decide`): doing that is exactly what orphans the in-progress run above, and it would also force a fixture rewrite on all 5 `ProspectAssembler.decide` call sites in `ProspectAssemblerTests.swift` for no gain.
- **`ScoutService.apply` gains `today: String = EasternDate.today()`**, computed **once** per run and used for both the new run-level past filter and the existing reconcile call. The reconcile call at `ScoutService.swift:239` stops calling the UI's `QueueModel.easternToday()` and reads the injected value. Do not call the clock twice in one run.
- In `apply`'s Phase 3 loop, immediately after resolving `gr`: if `ProspectAssembler.isPast(date: gr.row.performanceDate, runEndDate: gr.runEndDate, today: today)`, count the run's member rows into `skipped` and `continue`. Nothing is inserted, nothing is keyed, and the past run contributes nothing to `seenKeys`.
- The manual-intake path (Phase 1) calls the same `ProspectAssembler.isPast` on the single submitted event (no run context) before routing to `decide`, and refuses with a plain reason. One rule, one function, two call sites, both tested.

**This breaks the existing suite unless the same PR fixes the fixtures, and that is the first commit, not an afterthought.** Today is 2026-07-11. `ScoutServiceTests.swift:14-21`'s `liveEvents` are dated `2026-06-22` and `2026-06-24`, already past, so a wall-clock default would turn `#expect(outcome.inserted == 2)` (`ScoutServiceTests.swift:27`) into 0 and cascade. There are **25 past-dated `performanceDate: "2026-0[1-6]-.."` literals across six test files** (`ScoutServiceTests`, `MatchingTests`, `EventClassifierTests`, `QueueModelTests`, `PrepImporterTests`, `PrepQueueContractTests`) and **34 `ScoutService.apply` call sites across five test files** (`ScoutServiceTests` 23, `PassedShowPenaltyTests` 5, `OrgDoNotContactTests` 4, `MatchingTests` 1, `ScoutServiceSaveGuardTests` 1). Every one of those `apply` call sites gets an explicit `today:` argument pinned to the fixture's own era (a shared `TestClock.today` constant, e.g. `"2026-06-01"` for the June fixtures). **Inject, do not re-date**: re-dating fixtures into the future only rots again, and the whole point of the change is that this pipeline stage now has a clock.

Tests, written first:
- `ProspectAssemblerTests`: `isPast` returns true for a yesterday-dated single event, false for today, false for nil, false for a run whose opening night is past but whose `runEndDate` is future.
- `ScoutServiceApplyTests`: a feed of 11 wholly-past events inserts zero and counts 11 in `skipped`; a 3-night run whose first night is yesterday and whose last is next week is upserted **once**, keeps its original opening-night `naturalKey` across two consecutive `apply` calls (no re-key, no duplicate), and Dan's `.queued` status survives both.
- Ordering is deliberate and asserted: a past date that is ALSO blocked still reports `.blocked` from `decide` (the blocked check runs first and the past check never sees it).

**Known consequence, accepted:** an HTML-sourced run already underway keeps its original (now past) opening-night date, so it ages out of the queue's future-only window like any past show. That is correct behavior (a run already underway is not a lead worth pitching) and it is strictly better than the alternative, which loses Dan's decision. Carnegie is unaffected: Algolia's window (`AlgoliaCalendar.windowBoundsMs`) never returns past nights, so Carnegie's runs keep re-keying forward via `matchByAnyRunURL` exactly as they do today.

---

## Phase 1: #386 manual lead intake, standalone, and the AI extraction path in front of a human

Ships with zero new sources and zero change to the unattended auto-scout. It exercises the entire new machinery on a path where a bad parse is caught by Dan on a confirm sheet instead of written into the live store overnight.

**New: the extraction contract.**
```
SourceExtractor (protocol)  ->  ExtractedListing
```
`ExtractedListing` is a `Sendable` struct (never a `@Model`: `ScoutService` is `@MainActor` and SwiftData models are not `Sendable` under Swift 6), carrying `[ExtractedEvent]` plus a **page verdict**:
```
enum PageVerdict { case upcomingListings, allPast, noDatedContent, unreadable }
```
The verdict is what separates the spike's "quiet off-season, correct" (5 of 7 sites) from "wrong page, HTTP 200, full of 2021 dates" (`musicasacrany.com/concerts`) from "JS-only, we are blind" (Third Street). `[]` alone cannot. It is also what will later trigger the headless fallback. The verdict is a routing signal for source HEALTH; it is not the upcoming-only filter. `ProspectAssembler.isPast` (Phase 0b) is, and it runs on every run regardless of verdict.

Two conformers: `CarnegieExtractor` (Algolia, unchanged, still row one) and `AgentListingExtractor` (the detached run). Plus `StubSourceExtractor` in `OvertureTests`, so every extraction rule is a real Swift unit test.

**New files:**
- `mac/Overture/Integration/SourceExtractor.swift`
- `mac/Overture/Domain/SourceExtractQueue.swift` / `SourceExtractResults.swift` / `SourceExtractProgress.swift` (mirroring `PrepQueue.swift` / `PrepResults.swift` / `PrepProgress.swift`, versioned)
- `mac/Overture/Integration/SourceExtractService.swift` (mirroring `PrepQueueService`: atomic exclusive-create marker, queue write, `DetachedRunner.launch`, results ingest)
- `mac/Overture/Integration/ScoutPagePin.swift` (see the handoff guard below)
- `mac/scripts/scout-extract-run.sh` (mirroring `reply-classify-run.sh`: `lib/runner-setup.sh`, `lib/resolve-node.sh`, marker heartbeat, seeded progress file, `claude -p` with `--allowedTools "Read,Write,WebFetch"`)
- `docs/scout-extract-runbook.md`
- `fixtures/scout-extract-queue/`, `fixtures/scout-extract-results/` and their contract tests; new rows in `docs/contracts.md`

**The runner script needs its own UserDefaults path key.** `DetachedRunner.scriptURL(defaultsKey:)` (`DetachedRunner.swift:17`) reads a plain path string and returns nil when unset, which means "runner unavailable" and the feature silently never runs. Add `scoutExtractRunnerScriptPath` (a plain path, NOT a URL). Copy `reply-classify-run.sh`'s header format for documenting it, which is correct; do not copy `prep-run.sh`'s, whose line 8 names the wrong key in the wrong format. Give Dan an explicit hand-off step in `docs/scout-extract-runbook.md`: one numbered instruction, one copy-paste `defaults write com.danwright.overture scoutExtractRunnerScriptPath "<abs path>"` block, one `chmod +x` block. The Sources sheet must show "extract runner not configured" as a named, actionable state, never as silence.

**New timeout.** `RunTimeouts.scout` is `3 * 60` and its own comment (`RunTimeouts.swift:19`) says "an in-process run". A detached N-source extract batch that follows detail pages is not that. Add `RunTimeouts.scoutExtract` at `10 * 60` (matching `replyClassify`, the other heavy detached run) and set the script's marker heartbeat interval to touch well inside it, or a legitimate mid-batch run gets declared stalled.

**Handoff guard: the pinned pages are FLAT, not in a subdirectory.** `HandoffDirectoryGuardTests` (#321) enumerates every cross-boundary handoff URL accessor and asserts `entry.url.deletingLastPathComponent() == StoreLocation.handoffDirectory`. A file at `handoffDirectory/scout-pages/<id>.html` has parent `handoffDirectory/scout-pages` and would make that test **red**, not green. So: pin each fetched listings page at `StoreLocation.handoffDirectory/overture-scout-page-<sourceId>.html`, exposed by a static accessor `ScoutPagePin.url(for sourceId: String) -> URL`. The guard's enumeration gains, in the same PR:
- `("scout-extract-queue", SourceExtractQueueBuilder.defaultURL)`
- `("scout-extract-results", SourceExtractResultsDecoder.defaultURL)`
- `("scout-extract-progress", SourceExtractProgress.defaultURL)`
- `("scout-extract-running-marker", SourceExtractService.defaultMarkerURL)`
- `("scout-extract-run-log", RunLog.scoutExtractURL)`
- `("scout-page-pin", ScoutPagePin.url(for: "sample"))`

The guard's single assertion stays intact and no second assertion is needed. `ScoutPagePin` also owns a `pruneStale(olderThan:)` so pinned pages do not accumulate forever.

**Schema change (small, additive):** `Prospect.sourceIds: [String] = []`. This is #771. Many-to-one, not one-to-one: the existing dedup chain (`ScoutService.swift:186-206`) deliberately MERGES the same show arriving from a venue's calendar and from the presenter's own site into one `Prospect` row. A single `sourceId: String?` on a merged row can only remember one of them, and Phase 3's per-source reconcile would then see the show as absent from the other source's feed and accrue misses toward `disappearedFromFeed` on a show that is still live and that Dan may already have drafted and emailed. `[String]` has precedent in this model (`runSourceURLs` is already a stored `[String]`).

**Where `sourceIds` is threaded, named exactly:**
- `AssembledProspect` (`ProspectAssembler.swift:7-38`) gains `var sourceIds: [String] = []`, carried through `decide`'s constructed value.
- `ScoutService.make(_:key:)` (`ScoutService.swift:273`) sets it on insert.
- `ScoutService.apply(_ p:to existing:)` (`ScoutService.swift:289`) does the **set-union**: `existing.sourceIds = Array(Set(existing.sourceIds).union(p.sourceIds))`. This is the "refresh scout-owned fields" path and the only correct home for the union. It is also the function that deliberately never touches Dan-owned fields, so the union belongs there and nowhere else. A dedicated test asserts that upserting the same show from source B does not drop source A's id.

It is **never a `@Relationship`**. A `@Relationship(deleteRule: .cascade)` from a source row to its prospects would mean the one action Dan asked for (remove a permanently dead source) deletes every prospect it ever surfaced, cascading into `Recipient`, including sent emails and live reply threads.

**The intake flow:** Dan pastes a URL (or pastes raw text from a flyer or an Instagram caption) into a new sheet. The app fetches the page, writes it via `ScoutPagePin`, queues one item, launches the detached extract run, shows a live "Reading that page... 0:23" state via `RunProgress` against `RunTimeouts.scoutExtract`, then presents a **confirm sheet** with what was extracted (title, date, venue, listing URL), editable, with the classifier's verdict shown. On confirm, the event goes through **`ProspectAssembler.isPast` then `EventClassifier.classify` then `HistoryMatch.matchRelationship` then `ProspectAssembler.decide` then `ScoutService.apply`**, never a hand-built `context.insert`. That routing is load-bearing: `decide` is the only place that enforces the blocked-date skip and the #769 do-not-contact suppression, and `isPast` is the only place that enforces upcoming-only. A direct insert would be the single way this feature could make Overture email an org that asked Dan to stop. If the gate returns `.skip(.blocked)`, `.skip(.suppressed)` or `.skip(.past)`, the confirm sheet says so plainly and refuses, rather than inserting.

`sourceIds` is set to `["manual"]` on insert.

**Reconcile exemption, needed in THIS phase.** Phase 3 is what teaches `FeedReconcile` to read `sourceIds`. Until then reconcile still keys off `scoutedHosts` (`FeedReconcile.swift:19`) substring-matching the URL, so a manually-added show whose listing URL happens to contain `carnegiehall.org` would be reconciled against Carnegie's Algolia feed, be absent from it, and accrue misses toward `disappearedFromFeed`. Cheap guard, shipped in Phase 1 with its own failing test: a prospect whose `sourceIds` contains `"manual"` is exempt from reconcile entirely.

Tests: a suppressed org pasted manually is refused; a blocked date is refused; a past-dated flyer is refused with a plain reason; an `unreadable` verdict shows an actionable error, not an empty confirm sheet; a run that dies produces a `stalled` state, not an indefinite spinner; a manually-added carnegiehall.org URL accrues zero misses across two Carnegie scouts; a second source's id unions onto an existing prospect rather than replacing it.

---

## Phase 2: `WatchedSource`, and Carnegie becomes row one

**New `@Model WatchedSource`** (schema becomes `Schema([Prospect.self, Recipient.self, WatchedSource.self])` at `OvertureApp.swift:17`):
```
id: String (unique)          orgName: String
listingsURL: String?         kind: String        // "algolia" | "html"
isActive: Bool               // Dan/org owns this. False ONLY means "stopped".
inactiveReason: String?      // "orgRefusal" | "removedByDan"
healthRaw: String            // scout-owned: ok | failing | neverChecked
lastError: String?           // typed and named: http401 / http429 / timeout / redirected / notHTML / unreadable / noDatedContent
lastCheckedAt: Date?         lastSucceededAt: Date?
lastContentHash: String?     // stamped ONLY after a successful ingest
successfulCheckCount: Int    // the insert-only warmup counter
baselineFeedCount: Int       degradedStreak: Int    lastDegradedCount: Int   // the 3 UserDefaults keys, per source
pageCount: Int               // pagination hint, default 1 (html only)
addedAt: Date                notes: String?
```

**Two fields, not one.** `isActive` and `health` are separate and both are surfaced separately, because Dan named the confusion he fears: a broken source must never read as "they asked us to stop". One `isActive` bool or one status enum makes that confusion representable and every future UI change is one careless `if !isActive { grey it out }` away from it. `inactiveReason` further separates "the org refused" from "Dan removed a dead one".

**Carnegie's row has no listings URL to fetch, and Phase 4 must never try.** `AlgoliaCalendar.endpoint` (`AlgoliaCalendar.swift:13`) is a **POST search endpoint** requiring `x-algolia-application-id` and `x-algolia-api-key` headers plus a JSON body (`CarnegieExtractor.swift:29-35`). It is not a page a `SourceFetcher` GET can retrieve, hash, or diff. So, stated plainly and enforced by a test:

> **`kind == "algolia"` bypasses Phase 4 steps 1 through 4 entirely.** No `SourceFetcher` call, no content hash, no budget slot, no `ScoutPagePin`, no entry in the extract queue, no `pageCount`. It runs `CarnegieExtractor` natively and synchronously, exactly as today, then joins the pipeline at step 5 (ingest) with `sourceId = <carnegie-id>`.

Carnegie's `listingsURL` stores `https://www.carnegiehall.org/Calendar` as **display-only** (it is what Dan clicks in the Sources sheet), and `lastContentHash` / `pageCount` stay nil / 1 and unused. A test asserts `SourceFetcher` is never invoked for an `algolia` source, so the backfill cannot write a field that later code tries to fetch.

**Migration** (`mac/Overture/Domain/LaunchMigrations.swift`, which today calls three backfills in order: `RecipientBackfill.repairThreadDown`, `DraftSalutationMigration.run`, `DisciplineMigration.run`, then one `context.save()`):
- New `WatchedSourceBackfill.run(in:)`, appended to that call order, idempotent, guarded on "no Carnegie row yet": inserts Carnegie (`kind: "algolia"`, `listingsURL: "https://www.carnegiehall.org/Calendar"`), seeds its `baselineFeedCount` / `degradedStreak` / `lastDegradedCount` from the three existing UserDefaults keys (`ScoutService.swift:84-115`) so **#150/#152's tuned self-heal machinery keeps working with its own history intact**, then appends the Carnegie id to `sourceIds` on every stored prospect whose `sourceListingURL` contains `carnegiehall.org`.
- **Rehearsed against a clone of the real store before it touches production**: copy `~/Library/Application Support/default.store` (plus `-wal`/`-shm`) to a scratch path, point a Debug build at it via `StoreLocation`, launch via `mac/scripts/run-debug.sh`, verify row counts and that every prospect kept its `naturalKey`, keep/dismiss state and `Recipient` threads. The launch-time backup (`overture-store-backups/`) is recovery, not prevention.

**No phantom test failure to chase:** the existing suite builds its own container as `ModelContainer(for: Schema([Prospect.self]))` (`ScoutServiceTests.swift:10`), not the app's schema, so adding `WatchedSource.self` to `OvertureApp`'s schema will not break any existing test. Any `WatchedSource` test declares the model in its own container.

Carnegie keeps its Algolia path. Forcing it through the generic HTML extractor to "remove the special case" would trade 90 days of clean JSON for the roughly 3 days its rendered page exposes. #768 and #771 need a row and a source id, not a shared extractor.

Read-only Sources list ships here so the migration is visibly verifiable.

---

## Phase 3: per-source health and per-source reconcile (`scoutedHosts` is deleted)

This is the phase the whole plan exists for. Today, add one source and the singleton is structurally unable to tell "source 7's scraper died" from "source 1 had a big season". A healthy source's volume masks a dead one, `feedIsTrustworthy` passes, reconcile runs, and prospects Dan kept, drafted and emailed accrue misses and are marked `disappearedFromFeed` (`Prospect.swift:286`, `missedScoutCount >= 2`).

- `FeedReconcile.scoutedHosts` (`FeedReconcile.swift:19`) is **deleted**, along with its `isFromScoutedSource` host-substring check. Provenance is `Prospect.sourceIds`, not a host-string guess.
- `FeedReconcile.reconcile(...)` takes the run's **set of source ids that checked successfully** and reconciles each source against only that source's `baselineFeedCount` / `degradedStreak` / `lastDegradedCount` (now on the row). `updatedHealth` is unchanged pure logic, just called per source. **A merged multi-source `events.count` must never feed a shared baseline.**
- **The miss test is union-based, not own-source-based.** A prospect accrues a miss only if it is absent from the union of every source that checked successfully this run AND at least one of its `sourceIds` is in that successfully-checked set. Concretely: source A (a venue) and source B (a presenter) both list the same show, which dedupes to one row carrying both ids. A's calendar drops it, B still lists it: the show is present in the union, so zero misses. If only A checked this run and the show is gone from A, it still accrues nothing, because B (which also owns it) was not checked. Absence is only evidence of cancellation when every source that ever claimed the show has been asked and none of them has it.
- Reconcile counts a source **only when its check both succeeded and returned a trustworthy, non-empty feed with an `upcomingListings` verdict**. A source that was hash-skipped, budget-deferred, failed, or returned `allPast` / `noDatedContent` / `unreadable` **contributes nothing to the union and accrues nothing**. Deferred is not "fine" and is not "failing"; it is "not checked today".
- **Insert-only warmup, per source.** A source accrues no misses until `successfulCheckCount >= warmupRuns` (start at 3). A brand-new source, whose first check imports a whole season and whose second may legitimately look different, cannot mark anything gone before it has a baseline of its own.
- The `"manual"` pseudo-source is permanently exempt (it has no feed to be absent from), carrying forward Phase 1's guard.
- The three global UserDefaults keys are removed from `ScoutService` once the backfill has moved them onto Carnegie's row.

Tests (all stubbable, no network): a source that failed accrues no misses; a hash-skipped source accrues no misses; a big season on source A cannot re-baseline source B; a source inside its warmup accrues no misses; **a show carried by sources A and B, dropped by A while B still lists it, accrues zero misses**; a show carried by A and B where only A ran accrues zero misses; Carnegie's existing self-heal tests (`FeedReconcileTests`) keep passing against its own row.

---

## Phase 4: the watchlist loop, and what `runScout` returns now

`ScoutService.runScout` becomes, per active source, in priority order (oldest `lastCheckedAt` first, so a per-run budget staggers rather than starves):

0. **`kind == "algolia"` short-circuits.** Carnegie runs `CarnegieExtractor` natively and synchronously and jumps straight to step 5. Steps 1 to 4 below are the `html` path only.
1. **Native fetch** (`SourceFetcher`, `URLSession`), walking `pageCount` pages where set. Typed errors land on the row: `http401`, `http429`, `timeout`, `redirected` (the `thirdstreetmusicschool.org/events` case, which returns 200 on a different domain), `notHTML`. A failure marks the source `failing`, records `lastError`, and **never deactivates it**.
2. **Normalize and hash.** Strip `<script>`, `<style>`, nonces, and comments, then hash **the listing region** (the container the extractor reported last time, recorded per source), not the whole page, so a rotating carousel, a cookie banner with a session token, or an ad slot cannot defeat the lever. If the hash matches `lastContentHash`, **skip: no extractor call, no AI cost, and no chance of an extracted title drifting between runs and re-keying a prospect into a duplicate**. Determinism by abstention. This is the cost model, not an optimization: the spike measured roughly 25k input tokens per site per check (15k to 46k), which at 20 sources checked daily is around 500k tokens/day, nearly all of it re-reading unchanged pages.
3. **Budget.** A per-run cap (`sourceCheckBudget`, default 20) on how many changed sources enter the extraction queue. Over budget is **deferred**, a distinct visible state, `lastCheckedAt` untouched so it is first in line next run.
4. **One batched detached run** for the changed, in-budget sources. The app pins each fetched listings page via `ScoutPagePin.url(for:)`, writes `overture-scout-extract-queue.json` referencing those flat paths, and launches `scout-extract-run.sh`. The run reads each pinned file, follows each event's detail link with `WebFetch` for venue and exact date, writes `overture-scout-extract-results.json` (per source: `[ExtractedEvent]` plus a `verdict`), and heartbeats `overture-scout-extract-progress.json` after each source, so a run that dies at source nine keeps one through eight.
5. **Ingest**, per source: `apply(events:sourceId:today:...)` runs the existing classify then match then assemble then upsert chain (which now drops wholly-past runs natively, Phase 0b), then the union-based reconcile, then stamps `lastContentHash` **only after `context.save()` succeeded**. Never at fetch time. `ScoutService.apply` already carries a `saveFailed` path (#499, `ScoutService.swift:243-248`) precisely because a run can classify everything in memory and fail to persist. Stamp the hash at fetch time, hit that path, and the next run sees "unchanged" and skips, forever: a source that fetches fine, reports fine, and has silently ingested nothing since a save failure three months ago.

**Cross-source duplicates dedupe, they do not "flag and stay separate".** The existing chain (`ScoutService.swift:186-206`) already merges the same show arriving from two sources into one row; `sourceIds` accumulates both ids in `apply(_ p:to existing:)` (`:289`) so the merge is lossless and reconcile stays correct (Phase 3). A test asserts this explicitly: the same show fed from source A then source B yields one row carrying both ids. What is flagged for Dan rather than auto-resolved is the case the chain CANNOT merge (different title, different venue string, same real show), and even then nothing is deleted.

### The Outcome / warning / failure surface has to change, and this is where

Today `runScout` returns a synchronous `Outcome(found/inserted/updated/skipped/uncertain)` that `RootView.runScout` (`RootView.swift:651-675`) renders the instant it returns, `Outcome.warning` (`ScoutService.swift:33-41`) fires on any `found == 0`, and any thrown fetch error aborts the entire scout into `ScoutFailure.presentation`, whose manual-run text (`ScoutFailure.swift:17`) hardcodes "Couldn't reach Carnegie's calendar feed". None of that survives a multi-source, partly-detached run. Three concrete changes, each with a failing test first:

- **Two outcomes, not one.** `runScout` returns a **synchronous native outcome** (Carnegie's Algolia numbers, plus every source's fetch result: succeeded / hash-skipped / deferred / failed-with-named-error). The AI-extracted sources land **later**, in a **detached ingest outcome**, surfaced through the same shipped machinery Prep uses (`watchPrepRun` / `DetachedRunOutcome` / `RunLog.tail`), as its own labelled result line. Dan sees Carnegie immediately and the HTML sources when they land; he is never shown a number that silently omits half the run.
- **`runScout` stops throwing on a single source's failure.** Dan's rule is that a failing source is recorded and reported, visibly, every run, and never stops anything. A per-source fetch error is caught, typed, written to that source's row, counted into the outcome, and the loop continues. `ScoutFailure` stops being "the scout died" and becomes what it should be: how to present a failure that killed the whole run (no sources at all, store unavailable, extract runner not configured). Its Carnegie-specific copy is replaced with per-source copy that names the failing org and its error.
- **`found == 0` stops being a global warning.** Under the watchlist, zero is the NORMAL off-season answer (5 of 7 spike sites) and is also exactly what a fully hash-skipped run legitimately returns. Firing "the feed's data format may have changed" on every quiet week would train Dan to ignore the one warning that matters. The warning becomes **per source and health-aware**: it fires when a source that has a healthy baseline and whose page CHANGED returns zero upcoming events, or when its verdict is `noDatedContent` / `unreadable`. A source with an `allPast` or a clean empty `upcomingListings` verdict is reported as quiet, not as broken. Carnegie keeps its own existing behavior against its own row.

**Adding a source is propose-then-confirm, and the confirm sheet runs a REAL extraction.** Dan gives an org name or URL; the app proposes a listings URL, fetches it, and runs the actual extract path against it; the confirm sheet shows what came back, including the verdict and the page count it needed. This is the phase's only defense against the JS-only case (1 of 7 in the spike): because a failing source is never auto-deactivated and is reported every run forever, adding a calendar that is invisible to a raw fetch would mean being nagged about it daily with no fix available. The confirm sheet must therefore say "this calendar is invisible to us (its events load in the browser); adding it will report as failing every run until we build a headless fallback" **before** Dan adds it, and default to not adding. Listings URLs are recorded explicitly on the row and never re-guessed by convention per run: the spike landed on a 2021 archive doing exactly that.

**What joins the watchlist is a recurring NYC calendar, never a touring act.** A venue, a presenter, or a local self-producing ensemble qualifies. A touring artist's site is an itinerary, mostly not in NYC, and re-reading it daily pays for nothing. The proposal sheet excludes a detected touring act by default and says why; Dan can override. (This is a source-selection rule. It is NOT the presenter-over-venue rule, which governs whom to email.)

**The daily auto-scout becomes a token-spending run, and that is stated in code, not discovered.** `RootView.autoScoutIfDue` (`RootView.swift:645-649`) fires whenever the window is open and 24h have elapsed. It lives in `RootView`, so it is window-attended, and `ReconcileScheduler` still never triggers it: this does not violate #237. But `ScoutSchedule.swift:3-5`'s header currently justifies auto-running with "the scout is read-only (no sending), so auto-running it is safe", and that justification stops being true the moment the daily auto-scout can launch a `claude -p` extract batch. **Update that comment in the same PR** (CLAUDE.md's docs-in-sync rule), stating what is actually true: the scout still never sends, but it now spends tokens, and "attended" here means only that the window is open, not that Dan is watching. Worst case is the first run after Dan adds a batch of sources, when nothing is hash-skipped and every source is a full extraction. `sourceCheckBudget` is genuinely the only thing bounding it. The Sources sheet shows the hash-skip rate so the steady-state cost is visible rather than inferred.

---

## Phase 5: the progress and status surface (ships before the watchlist is on by default)

CLAUDE.md's rule is binding and this is where it applies. Note what is **already shipped** and is not new work: `RootView.swift:8` has `scoutStartedAt`, and lines 205-206 already render `LiveRunLabel(base: "Scouting", since: scoutStartedAt, timeout: RunTimeouts.scout)`. Started and still-alive, with an elapsed counter, exists (#435). The genuinely new work here is narrower:

- **Per-source detail on the live label**: "Checking sources 3 of 9... 1:12", fed by `RunProgress` / `PrepProgressDecoder`'s shipped pattern against the extract run's progress file. The base counter is reused, not rebuilt.
- **The stalled state for the DETACHED half**, with liveness fed by the extract run's marker heartbeat and judged against the new `RunTimeouts.scoutExtract` (10 minutes), not `RunTimeouts.scout` (3 minutes, correct for an in-process run and wrong for a batch that follows detail pages).
- **Carnegie completes synchronously and reports immediately** (Algolia, native), so the scout never appears to have done nothing while the extract run works.
- **Sources sheet grades**, as words plus icons plus separate sections, so "broken" can never read as "they asked us to stop":
  - **Watching** (`ok`, with last checked, last found, hash-skip rate)
  - **Failing** (`failing`, with the named error and how many runs it has been failing; reported visibly **every run**, never auto-deactivated; with an explicit "stop watching this" action so a permanently dead source has a way out that is Dan's choice, writing `isActive = false, inactiveReason = "removedByDan"`)
  - **Not checked today** (budget-deferred; visibly distinct from both of the above)
  - **Stopped at their request** (`isActive == false, inactiveReason == "orgRefusal"`)

- **DNC linkage, and it is an explicit, tested API change.** `OrgDoNotContact.mark(orgOf prospect: Prospect, in all: [Prospect])` (`OrgDoNotContact.swift:33`) is pure over prospects and has **no access to sources and no `ModelContext`**. It cannot reach out and touch a source. So its signature changes to:

  `static func mark(orgOf prospect: Prospect, in all: [Prospect], sources: [WatchedSource])`
  `static func unmark(orgOf prospect: Prospect, in all: [Prospect], sources: [WatchedSource])`

  `mark` additionally sets `isActive = false, inactiveReason = "orgRefusal"` on any source whose **own `orgName`** confidently matches the refusing org (via the existing `GroupNameMatch.isConfident`, the same bar `sameOrg` already uses), never the source that surfaced the prospect. `unmark` reactivates only sources whose `inactiveReason == "orgRefusal"` and whose name matches, so a source Dan deliberately removed as dead is never silently resurrected. **Every call site of `mark` / `unmark` is updated in the same PR** (they are in `OrgDoNotContactTests.swift` and the queue/detail UI that offers the action), passing the fetched `[WatchedSource]`.

  Keying the deactivation off `sourceIds` instead would be wrong and is explicitly rejected: if a Brooklyn choir performing at Symphony Space asks Dan to stop, and Symphony Space's calendar is what surfaced them, deactivating by `sourceIds` would blind Dan to Symphony Space's entire calendar because one act on it refused. That is Dan's own "watch a venue, but pitch the presenter" rule applied to refusals. **No second do-not-contact mechanism is built**; #769's history-record design stands untouched. See open risks: this leaves a real false-negative when a **presenter** refuses.

---

## Verification, throughout

- Every phase: failing test first, same commit. `scripts/test-all.sh` from the repo root before every push (both CI jobs).
- Mac suite via `mac/scripts/run-tests-locked.sh` (never raw `xcodebuild test`; a scoped `-only-testing:` run can print `** TEST SUCCEEDED **` with zero tests executed).
- Failure-path coverage is mandatory on everything touching fetch, retries, the detached run, and reconcile.
- `HandoffDirectoryGuardTests` updated in the same PR as any new handoff file, with the flat `overture-scout-page-<sourceId>.html` naming that keeps its single assertion intact.
- The Phase 2 migration is rehearsed against a **clone** of the live store before it ships.
- Before merging: `scripts/check-pr-ci.sh <pr>`, then `scripts/merge-when-green.sh <pr>`.
- Contract changes: fixture plus both sides' tests in the same change, and a row in `docs/contracts.md`.
- Docs in sync in the same PR: `ScoutSchedule.swift`'s "read-only, so auto-running it is safe" header, `docs/scout-runbook.md`, `docs/contracts.md`, `AGENTS.md`'s description of what the scout is.

## Overruled dissent
- The reality-check's suggested fix for the clock problem was to give `ProspectAssembler.decide` an injected `today: String` and thread it through `ScoutService.apply`. I took the injected `today` on `apply` (that part is right and necessary) but deliberately did NOT put the past rule inside `decide`. Reason: `decide` runs at ScoutService.swift:135-150, BEFORE RunGrouping.group at :152-159. A past-skip there drops the opening night of an in-progress run, which is precisely the store-corrupting bug the reality-check flagged separately (the run's natural key then shifts every scout, and matchByAnyRunURL cannot rescue a linkless month-grid source). Putting the rule at run granularity in `apply`, judged against `runEndDate ?? performanceDate`, fixes both findings with one change and keeps `decide` pure and clockless, which also keeps ProspectAssemblerTests' 5 decide call sites untouched.
- The panel's original 'N sources means N claude -p subprocesses' shape is overruled in favor of native fetch/hash plus ONE batched detached extract run. One hung source must not be able to block the marker guard or leave a bare indefinite spinner.
- Forcing Carnegie through the generic HTML extractor to 'remove the special case' is overruled. Its Algolia index exposes 90 days; its rendered page exposes about 3. #768 and #771 need Carnegie to have a ROW and a source id, not a shared extractor.
- 'Flag cross-source duplicates and keep them separate' is overruled. The existing dedup chain already merges them and must keep doing so; `sourceIds` is what makes that merge lossless.

## Ideal versus doable
The ideal version adds two things this plan defers. First, a headless-browser fallback (WKWebView, render then snapshot the DOM) for the JS-only calendar case, which was 1 of the spike's 7 sites. Without it, such a source can be added but will report as failing every single run forever, and the only mitigation shipped here is a confirm sheet that warns Dan before he adds it and defaults to not adding. That is honest but unsatisfying, and at 50 sources the case stops being rare. It is deferred because it is a self-contained additive change (a second SourceFetcher strategy behind the same typed-error surface) that needs none of this plan's structure revisited, and shipping it first would delay the part that actually unblocks the three issues. Second, a per-source lead-quality signal. The spike's finding 7 is that extraction succeeding says nothing about the lead being worth anything (Symphony Space returned 12 upcoming events that were nearly all film screenings and literary talks). The ideal version tracks qualified leads per source over time and tells Dan which sources are earning their tokens, so the watchlist can be pruned on evidence rather than on nothing. The data to do it (sourceIds on every prospect, plus tier) is deliberately in place after Phase 1, so it is a read-only reporting layer added later, not a redesign.

## Open risks
- The Phase 2 migration touches Dan's LIVE store (every prospect, contact, sent email and reply thread). Launch-time backups under overture-store-backups/ are recovery, not prevention. The mitigation is the rehearsal against a cloned store, but a rehearsal is not a proof.
- The extract run is granted WebFetch and follows arbitrary event detail pages on arbitrary org sites. The listings SET is still determined by bytes we fetched and hashed natively, so a detail page cannot change what reconcile thinks the feed contains, but a detail page CAN change what an individual event says (venue, date). A hostile or broken detail page can therefore produce a wrong venue on a prospect, which feeds the classifier and the pitch.
- Hash-skipping is the whole cost model, and a page that changes on every load (a timestamp, a rotating carousel, a session nonce) defeats it and re-extracts daily forever. Hashing the listing region rather than the whole page is the mitigation, but the listing region is itself something the extractor reports, so a source can silently fall back to hashing too much. The Sources sheet's hash-skip rate is what makes this visible rather than invisible; it is not what prevents it.
- The JS-only calendar case (1 of 7 spike sites) has no fix in this plan, only a warning. Such a source, once added, reports as failing every run forever by design (a failing source never auto-deactivates). If Dan adds several, the Failing section becomes noise and the one source that is failing for a fixable reason gets lost in it.
- The spike's recall was only really exercised on the 3 of 7 sites that had upcoming shows. Off-season sites cannot demonstrate that nothing was missed. A source that silently returns 8 of 12 upcoming events would look healthy, pass the trustworthy check, and quietly cost Dan four leads a season, and nothing in this design would catch it.
- `ScoutService.apply` now takes an injected `today`, and 34 existing test call sites across 5 files pass a pinned value. That makes the fixtures clock-independent, which is right, but it also means a future test that forgets to pass `today` silently picks up the wall clock and can go red months later for reasons unrelated to its subject. Worth a lint or a shared TestClock constant used everywhere.

## Escalated to Dan (not decided by the panel)

**An HTML-sourced multi-night run that has already STARTED (opening night past, closing night still ahead) keeps its original opening-night date, so it will sit in the queue looking past and age out. The alternative is to re-key it forward to the next remaining night each run, which requires a new URL-free fallback matcher (canonical name + venue + runEndDate) and carries a small risk of colliding with a genuine second run of the same act at the same venue. Which behavior do you want?**
- Keep the opening-night date (simpler, zero re-key risk, a run already underway is not a lead worth pitching anyway)
- Re-key forward to the next remaining night (the show stays visible while it is still running, at the cost of a new matcher)

**The per-run extract budget (`sourceCheckBudget`) is the only thing bounding the daily auto-scout's token spend. The spike measured roughly 25k input tokens per changed source. What default cap do you want, given 10 to 50 sources within a year?**
- 20 changed sources per run (about 500k input tokens worst case per day)
- 10 changed sources per run (cheaper, but a fresh batch of added sources takes several days to fully import)
- No cap, and rely on hash-skipping to keep steady-state cost near zero

**A PRESENTER asking Dan to stop currently deactivates only a source whose own orgName matches. If that presenter's shows were surfaced via a VENUE's calendar that Dan also watches, the venue keeps being watched (correct) but the presenter's own future shows will keep being surfaced there and suppressed one at a time by the #769 history record. Is that acceptable, or do you want a visible 'this org refused, here is where they still show up' report?**
- Acceptable as is (the #769 suppression already stops any email going out)
- Add a visible report of refused orgs still appearing on watched calendars

## Grounding
- Repo readable: True
- No Supabase schema exists in this project (persistence is a local SwiftData store), so the schema probe reporting unreachable is expected, not a grounding gap.

---

# Dan's decisions on the escalated questions (2026-07-11)

The panel deliberately refused to decide these three. Dan settled them after the run. They are
binding on the phases below and override anything above that contradicts them.

## 1. A multi-night run already underway: keep the opening-night date, but SAY it is still running

No re-keying forward to the next remaining night (no new matcher, no collision risk with a genuine
second run by the same act at the same venue). The show keeps its opening-night date.

But it must not simply read as "past". Dan's addition: **make it clear it is a multi-night run.** The
queue has to surface the run's end date, so a show still running reads as "runs through the 20th"
rather than looking like a lead that has already gone. `runEndDate` and `partOfRelatedRun` already
exist on the model (`RunGrouping`), so this is a display requirement, not a data one.

## 2. Extraction cost: pin the model AND strip the page, but VERIFY the strip first

The spike's ~25k input tokens per source is an artifact of sending the entire raw HTML, scripts and
styles included. The actual event content in those same pages was 558 to 5,565 characters of visible
text (roughly 150 to 1,400 tokens). Something like 90 to 95 percent of that spend is markup the model
never needed.

Two levers, both to be applied:

- **Pin extraction to a cheap fast model (Haiku).** Today `prep-run.sh:62` calls `claude -p` with no
  `--model` flag, so every detached run silently inherits the CLI default. Extraction is a mechanical
  task with a strict output schema, which is exactly the cheap-model case. Drafting is where an
  expensive model earns its keep, because voice matters there. Nothing about that distinction was
  deliberate; it was inherited.
- **Strip scripts and styles before sending the page.** Roughly 25k tokens down to 2-4k.

**The strip is UNTESTED and must be proven before it is trusted.** The spike's hardest case
(Bargemusic) prints no dates at all: the model reconstructed them from which CELL OF A TABLE each
concert sat in. That is structural information, and an over-aggressive strip would destroy exactly
the case that impressed us. Re-run that case against the stripped input and compare against the known
ground truth (6 concerts, with the trailing cells correctly dated to August, not July) BEFORE
adopting it. If the strip breaks it, keep the structure and take the Haiku saving alone.

With both levers a changed source costs roughly 2-4k tokens on a cheap model. The per-run
`sourceCheckBudget` cap stays as a backstop (default 20 changed sources), but it stops being the
load-bearing cost control it was written as.

## 3. A refused org still appearing on a watched calendar: make it visible, do not just suppress it

When a presenter asks Dan to stop, their own source comes off the list, but their shows can still
appear on a VENUE calendar he legitimately keeps watching (Carnegie). The #769 do-not-contact record
already suppresses each of those, one at a time, so no email can go out.

That protection is real but silent. Dan wants it **visible**: a report of orgs that asked him to stop
whose shows are still turning up on calendars he watches. On the one mistake that cannot be taken
back, he would rather see the suppression working than trust that it is.

---

# Dan's 4th decision, taken during Phase 4 (2026-07-12)

## The daily run watches for free. Only a scout Dan starts spends tokens.

Binding, and it overrides Phase 4 above wherever they conflict.

Dan asked the right question when Phase 4 reached the point of making the daily auto-scout a
token-spending run: he intends to run a scout by hand every Saturday, so does an automatic one
still earn its keep?

It does, but not as written. The reason to keep a daily run was never speed. On Carnegie's 90-day
window a Saturday cadence costs at most six days of lead time. The reason is the promise the whole
watchlist rests on: nothing Dan asked to watch is ever quietly dropped. A source that 404s, gets
redesigned, or starts returning nothing must be noticed in a day, not in a week, and not never
because he skipped a Saturday.

But after Phase 4 the expensive half of a scout is ONLY the AI extraction, and extraction only
happens on a page whose content actually changed. Fetching a page and hashing it is free. So the
daily run and the token spend do not have to be the same event, and splitting them gives Dan both
things he wants:

- **The daily automatic run watches, for free.** It fetches and hashes every active source, records
  health and any typed failure on the row, and flags which sources have listings we have not read
  yet. It NEVER launches a `claude -p` run. Carnegie still ingests fully on it, because Carnegie's
  extraction is native Algolia JSON and costs nothing: today's behavior is preserved exactly.
- **A scout Dan starts reads.** It does everything the daily run does, and then reads the pages whose
  hash actually changed. Cheap by construction, because an unchanged page is never sent to a model.

This also removes the risk Phase 4's own text worried about: an extract batch can no longer eat the
Max-plan capacity Prep needs while Dan is not watching, because an extract batch cannot start unless
he started it.

`sourceCheckBudget` survives as a backstop on the run Dan starts (he could add fifty sources and then
press Scout), not as the load-bearing cost control it was written as.

Consequence for `ScoutSchedule.swift`'s header ("the scout is read-only (no sending), so auto-running
it is safe"): it stays TRUE, and for a better reason than before. The automatic run is not only
non-sending, it is also non-spending.
