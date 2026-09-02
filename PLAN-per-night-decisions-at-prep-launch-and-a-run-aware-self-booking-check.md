# Per-night decisions at Prep launch, and a run-aware self-booking check

> Planned with /plan-council on 2026-08-30. 23 agents. The framing was locked in conversation with Dan the same day; the eight decisions it treats as constraints are quoted in the brief.

## READ THIS FIRST: the plan is NOT clean

The correction loop is bounded at two rounds and both were spent, so the plan below is returned carrying its remaining problems rather than with them fixed.

- Reality check verdict: **needs-fixes**, 9 claims still broken, 33 confirmed.
- Lessons audit verdict: **violations**, 9 violations, against 354 lessons read.
- Preflight: repo readable True, hosted schema False (correct, this project has no hosted database).

## The plan

## What this is, in plain terms

Overture treats a multi-night run as one card filed under its opening night. Dan judged that opening night at Scout and nothing else. Everything downstream then behaves as though he had judged the whole run: the drafter is told to pitch the span, and the internal double-booking warning only ever looks at the opening night. On a 23-night run that means offering a stranger 22 nights nobody ever decided about, with no warning if any of them collide with something Dan already promised.

This plan does two things. It makes the internal double-booking check read every night a run is being pitched for (the external-calendar half already does), and it makes the per-night judgement a stored decision, so "nobody has looked at this night" becomes a state the app can see and act on rather than an absence indistinguishable from "keep it".

---

## Two rules that govern how this document may be read and written

### 1. Re-measure every number on the day it is written

Every number below was re-taken on **2026-08-30** against a consistent `sqlite3 .backup` clone of `~/Library/Application Support/Overture/Overture.store`, holding **1,141 prospects**. An earlier draft quoted 1,023 and eight of its figures had already moved by the time it was checked.

So: **any number going into a source comment, a test's reason string, or a PR body is re-measured on the day it is written, and carries its date, its population and the query or function that produced it.** A count with no population named is not a measurement, it is an impression (L316, L61, L107, `measured-counts-in-docs-go-stale`).

### 2. This repository is PUBLIC. Identities never enter the artifacts (L155, L222)

`AGENTS.md` records that `gh repo view --json visibility` answers PUBLIC (checked 2026-08-29). This repo already carries two guards built from exactly this incident: `TestDataEmailDomainGuardTests`, and `scripts/check-test-identity-provenance.sh` whose baseline `fixtures/test-identity-provenance.txt` exists because #2834's scrub left real people in test data. The `sqlite3` clone this plan is measured from is Dan's live prospect roster: real show titles, real venues, real people's rooms.

**Therefore, as a deliverable and not an intention:**

- Rows are named by **primary key and status only**, with the measurement date. Never by show title, never by venue, in this plan, in the issue, in a PR body, in a commit message, or in a test's reason string.
- **Every new fixture carries an invented group name and an invented venue.** Fixtures are named by their **shape**, never by the show that motivated them: "a two-night run sharing its closing night with a sent pitch", "a sixteen-date weekly series with dark nights between", "a run whose weekend night carries a matinee time".
- After the fixtures land in each of Phase 1 and Phase 3, run `scripts/check-test-identity-provenance.sh`, **read its report rather than recording blind** (L182), and state in the PR body that it was run and what it said.

The counts and the distributions carry the whole argument. The identities carry nothing the argument needs.

---

## Facts measured before planning (clone of 2026-08-30, 1,141 prospects)

These correct the brief, and each correction changes the work.

| Claim in the brief | Measured |
| --- | --- |
| pk 433 is `drafted` | **`contacted`**, `ZSENTAT` = 809802204.05 (Core Data epoch), which is 2026-08-30. The pitch naming both nights has already gone to a stranger. |
| "Six other rows on 2026-10-29" | **Wrong by three, and the misses are the interesting class.** See "the exposure set is derived" below. |
| Contract bump is v7 to v8 | **`PrepQueueBuilder.version = 13`** (`mac/Overture/Domain/PrepQueue.swift:234`); `docs/contracts.md:30` lists 1 through 13; `docs/prep-runbook.md:23` states `` `PrepQueue` version `13` `` in prose, pinned in both directions by `src/lib/prepQueueSpec.test.ts`. The bump is **v13 to v14**. |
| Premise went stale at #1174 | It went stale at **#1523**, which introduced `runNights` and made `BlockedCalendar.conflict` run-aware while leaving `SelfBookingConflict` untouched. #1219's exact-date choice was correct given what existed then. |
| Only one corrupt `naturalKey` row | **Two.** Rows whose `naturalKey` does not contain `|performanceDate|`: **pk 361** (key names 2026-09-26, `performanceDate` 2026-12-12) and **pk 914** (key names 2026-08-30, `performanceDate` 2026-08-31). Both `dismissed`, and **both carry `droppedRunNights`**, which is the signature. |

### The exposure set is DERIVED, never hand-written

The brief listed six rows on 2026-10-29 by title. Written by hand, that list **reproduces the exact defect this feature fixes**: it reads opening nights only. Derived over `runNights`, the answer is different.

Query (decode `ZRUNNIGHTS`, a keyed-archive plist, then select rows where any night equals a night pk 433's sent pitch named):

- **Opening-night holders of 2026-10-29, all `new`: 605, 727, 819, 821, 955, 1055, and 1325.** Seven, not six. pk 1325 is absent from both the brief and every earlier draft.
- **Later-night holders of 2026-10-29 that are live, both `new`: 353 and 505.** These two are precisely the class the whole plan is about, and an opening-night query cannot see them.
- pk 410 also holds it as a later night and is `dismissed`, so it is out of scope.

**The live exposure set is nine rows: 353, 505, 605, 727, 819, 821, 955, 1055, 1325 (2026-08-30).** Every later reference to "the exposure set" means that derived query, not that list of numbers.

### Population

- **125** rows carry more than one distinct stored night; **96** are live (`new`/`queued`/`drafted`/`approved`).
  - **Histogram over all 125** (nights: rows): 2:60, 3:12, 4:12, 5:4, 6:5, 7:2, 8:1, 9:3, 10:6, 11:1, 12:7, 13:2, 16:2, 18:1, 20:5, **22:1**, 23:1.
  - **Histogram over the live 96**: 2:45, 3:8, 4:9, 5:2, 6:4, 7:2, 8:1, 9:3, 10:5, 11:1, 12:6, 13:2, 16:2, 18:1, 20:4, 23:1. There is **no live 22-night row**.
  - The two are different distributions and are quoted separately for that reason. Anyone sizing the picker's worst case for live work reads the second. The longest live run is 23 nights.
- **15** rows hold duplicate entries in `runNights`.
- **22** rows carry a span (`runEndDate` differing from `performanceDate`) with an **empty** `runNights` (they predate #1523). **12 live**, not the 24 or 25 earlier drafts claimed. **Four of the 22 also carry `conflictOpen`**: a per-night picker cannot help those at all, because there is no night list to pick from.
- **9** rows have ever written a `droppedRunNights` entry: 361, 386, 425, 435, 619, 914, 923, 999, 1010. **4 are still `new`** (386, 425, 435, 619).
- **20** rows have `sentAt` set. Exactly one (pk 433) is multi-night. Status store-wide: `new` 732, `dismissed` 389, `contacted` 20, and **zero** in `queued`, `drafted` or `approved`.
- **81** rows carry `conflictOpen = 1`: 70 `dismissed`, 10 `new`, 1 `contacted`. **13 are multi-night.**
  - Of those 13, **ten are blocked on a night that is not their opening night** (306, 312, 526, 714, 748, 795, 898, 910, 911, 914) and every one is `dismissed`; **three are blocked on their OPENING night** (180, 666, 713), of which only pk 180 is live. The number is **ten, not twelve**, and the split matters because it is what makes decision 6's stated population empty.
- **`conflictClearedKey` is set on zero rows today.** That is **not** evidence the waiver has never been used: `Prospect.setScoutConflict(nil)` nils `conflictClearedKey` whenever a clash goes away, and `clearConflict()` copies `conflictKey`, which is nil when there is none. A present-tense zero is consistent with the waiver having been used many times. Nothing in this plan may lean on "never used".

### Code facts that shape the design (each verified in the file named)

- `SelfBookingConflict.Show` is single-date end to end: `date: String?`, `startTimes: [String]`. `sameNight`, `conflicts`, `workable` and `gapMinutes` all assume one date per side.
- The stale premise lives in `mac/Overture/Domain/SelfBookingConflict.swift`, **lines 35 to 36**: "Exact date match only (#1219 decision 3): multi-night runs are separate per-date rows, so a shared night still collides without expanding runEndDate spans."
- `QueueModel.groupByDate` is `mac/Overture/UI/QueueView+Model.swift:1946`, keying every date header on `performanceDate`.
- `selfBookingShow` builds the value at `QueueView+Model.swift:2369`, and passes `engagementKey: i.groupName` at **:2372**. **`engagementKey` is documented as "shared production id (EngagementLink)" and is not one**: it is a raw unnormalised display name. Measured 2026-08-30: **53 all-row pairs share a night carrying an identical raw `groupName`**, but **zero of those pairs involve a row that passes `selfBookingIsCommitment`**, so the exemption silences **nothing** today. It is dormant, one Keep away from load-bearing, and it rests on an exact display-name match a scout rename silently breaks. `EngagementLink` already uses `GroupNameMatch.normalize` for exactly this comparison.
- `selfBookingConflicts(for:among:)` (`QueueView+Model.swift:2378`) maps the **rendered set** it is handed (`data.items`), not all 1,141 store rows. Every performance statement below is scoped to the rendered set for that reason.
- **Keep already clears the card-wide conflict.** `mac/Overture/UI/ProspectMutations.swift:656` is `if status == .queued { model.clearConflict() }`, with the #1583 comment "Keep IS Dan's acceptance of a date clash".
- **`PrepQueue.needsPrep` (`PrepQueue.swift:270-278`) does NOT strictly require `.queued`.** It refuses on `hasUnclearedConflict` (`:275`), then admits `.queued && !hasDraft`, and then admits a **reprep** path over `.queued`, `.drafted` **or** `.approved`. So "nothing is preppable today without a Keep" is true only because the store holds **zero** rows in `queued`, `drafted` or `approved` (2026-08-30). It is a fact about the current store, not about the predicate, and it is stated that way wherever it is relied on.
- `Prospect.hasUnclearedConflict` (`Prospect.swift:1004`) is exactly `conflictOpen`, and `Recipient.isSendablePending` (`Recipient.swift:677`) reads `prospect?.hasUnclearedConflict != true`. **The prep gate and the send gate are one column.**
- `BlockedCalendar.conflict(performanceDate:runEndDate:nights:)` (`BlockedCalendar.swift:259`) takes a nights array and is run-aware, but returns **one** `Day?`, the earliest blocked night. `decidingDay` is `private`. A per-night blocked SET needs a new member on that type, not a call to `conflict`.
- `ScoutService` lives at **`mac/Overture/Integration/ScoutService.swift`**. `ScoutService.blockedCalendar(export:context:)` is reachable from a view at `DaysOffView.swift:23`, and the export it is handed comes from `DownbeatBridge.loadedExport()`, which decodes the Downbeat export from disk. (That is an inference from the call, not a quotation from the comment beside it; the comment says the calendar is built fresh on each render from the export.)
- `EventDateInDraft.finding` is `mac/Overture/Domain/EventDateInDraft.swift:44`, and builds its acceptable set at **:48** with `EasternDate.days(from:through:)`, a span walk. Same defect class, second instance. Deliberately advisory (Dan, quoted in its own header: "warn only ... make it clear why it's warning me").
- `EasternDate.days` (`EasternDate.swift:59`) caps at `maxRangeDays = 366` (`:57`) and returns `[start]` when the end is unparseable or earlier than the start.
- `RunNightDrop.dropNight` (`RunNightDrop.swift:188` and `:195`) re-keys the row in place and **records no `NaturalKeyRemap` entry**. `NaturalKeyRemap.record` has exactly one caller, `NaturalKeyVenueMigration.swift:153`.
- `dropNight`'s own comment (`RunNightDrop.swift:182-186`) asserts "the night being dropped is always the run's first remaining night. There is no way to reach a middle night from either control", precisely the invariant this feature breaks.
- **`dropNight` has TWO callers in `ProspectMutations`, not one**: `dismissAll` (the bulk path) at **`ProspectMutations.swift:712`**, and `dismissForReason` (the card menu path) at **`ProspectMutations.swift:817`**. Both are derived from `grep -rn 'dropNight' mac/Overture --include='*.swift'`, and that command goes in the PR body so the next reader re-derives rather than trusts. Any invariant pinned on one is free on the other.
- `ProspectFieldClassificationTests.swift:77` classifies `droppedRunNights` in **`notARecord`**. The file has **three** buckets: `notARecord` (`:42`), the `hasRecordBeyondADismissal` rule itself, and `danDecisionsTheRuleCannotSee` (`:200`).
- `PrepSelectionSheet`'s header comment (`:7`, `:13`) states its contract: the selection is "PER-RUN and transient: nothing persists", over "a value-type snapshot ... so the sheet never holds a SwiftData model across the run". Its body puts rows in `CappedScrollView(maxHeight: 360)` (`PrepSelectionSheet.swift:53`).
- `PrepQueueService` is at `mac/Overture/Integration/PrepQueueService.swift`. It sends `performanceDate` (`:69`) and `runEndDate` (`:71`) and nothing else about the run's dates, and computes `openingNightPassed` from those two at `:97`.

---

## Decision 6, corrected, and escalated

The brief's premise was that `hasUnclearedConflict` freezes a partly booked run out of Prep, so "the picker would never open for exactly the card that most needs it". Measured, **the live population for that premise is empty**: Keep clears the flag on the way in, all ten non-opening-night blocks are on dismissed rows, and the one live multi-night `conflictOpen` row (pk 180) is blocked on its **opening** night.

The defensible version, and the one this plan builds on:

> **Keep (#1583) accepts the whole run's clash card-wide, before anybody has looked at which night it is on. The picker is where that blanket acceptance gets itemised.**

That is what `acceptedNightConflicts` is for in Phase 3.7, and it is why the gate change in Phase 3.8 is about *prep eligibility* rather than about unfreezing a population that turns out to be dead. **Dan chose decision 6 on a premise that has moved, so it is escalated rather than quietly redesigned around.**

---

## Phase 0: the live exposure, today

pk 433 is sent, naming 2026-09-04 and 2026-10-29. Nine live rows share one of those nights and would draw no warning if kept.

**This phase sets no hand-held suppression, and an earlier version of it did.** A sentence said once in a working session, plus an issue comment, with a lift that depends on somebody remembering to say so, is a suppression living only in prose (L27) with no expiry and nowhere visible (L523), placed on the one surface Dan is not looking at while the queue, the surface that persists, says nothing (L126). It would also read exactly like a healthy system.

So Phase 0 is cut to what it can honestly do:

1. **State the exposure plainly with its end condition named**: the nine rows draw no self-booking warning until Phase 1 merges. That is why Phase 1 ships **alone and first**. The exposure ends when Phase 1 merges; nothing else lifts it.
2. **Record the exposure set in the issue as PRIMARY KEYS ONLY, with the derivation and its date**: `353, 505, 605, 727, 819, 821, 955, 1055, 1325` (2026-08-30), plus the query that produced them (decode `ZRUNNIGHTS`, match any night against pk 433's stored nights, exclude `dismissed`). No titles, no venues (L155). Paste the query, not the answer, so it can be re-run.
3. **Frame the moment of exposure correctly: it is the KEEP, not the pitch.** `needsPrep` refuses on an uncleared conflict and then requires `.queued`, or a reprep over `.queued`/`.drafted`/`.approved`. The store holds zero rows in any of those three states today, so nothing can be prepped until Dan presses Keep. That single press both accepts any clash card-wide and makes the row preppable. If a durable marker is wanted before Phase 1 lands, it belongs on those rows, not in a chat message.
4. **No repair of pk 361 or pk 914 here.** Phase 1 writes nothing, so it cannot make them worse. The repair rides Phase 2, dry-run on a store copy first (`dry-run-destructive-migration-on-store-copy`).

Deliverable: a dated comment on the issue carrying keys and a query. No code, no PR, no control that depends on being remembered.

---

## Phase 1: the self-booking check reads every kept night (ships first, alone, no schema change)

This is the whole of the reported harm and needs no storage.

### 1.1 Reshape the pure domain type

`SelfBookingConflict.Show` becomes night-plural on both axes at once:

- `date: String?` becomes `nights: [String]`, deduplicated and sorted by the caller (15 rows need the dedupe).
- `startTimes: [String]` becomes `timesByNight: [String: [String]]`. This is the one place expansion can produce a wrong **reassurance** rather than a wrong warning: without it, a Saturday matinee's eight-hour gap could quiet a Tuesday clash through `workableGapMinutes`. `minutes(_:)`'s all-or-nothing rule is unchanged, applied per night.
- `sameNight` returns `[Overlap]` where `Overlap = (night: String, other: Show)`, not `[Show]`. The colliding night must come back, because every copy sentence downstream renders under a header keyed to the opening night and would otherwise make a claim the check never measured (L263; #1501 already solved the same problem on the calendar half).
- `gapMinutes(between:and:on night:)` reads each side's times for that night only.

**Say what `engagementKey` actually is, in the field's own comment and in the PR body**, because the documented meaning and the shipped meaning disagree today and expansion makes the gap matter. Decide deliberately and state the choice: **move the exemption to `GroupNameMatch.normalize`**, which `EngagementLink` already uses for this exact comparison, rather than keeping a raw display-name match a scout rename silently breaks. Measured 2026-08-30, this changes nothing today (zero committed pairs are exempt under either spelling), so it is a free correction now and an expensive one later.

Add the guard expansion makes newly dangerous: **a run card whose per-night sibling was renamed by the scout must not clash with itself.** Fixture: two rows sharing nights, one a commitment, invented names differing only by the normalisation (punctuation or case); assert no clash. Mutate the normalisation back to raw equality and see it go red.

### 1.2 The fallback asymmetry, written beside the code

An empty `nights` list falls back to **`performanceDate` alone**, on both sides, never to `BlockedCalendar`'s span walk. Copying the span walk here would manufacture clashes on the dark nights of a weekly series.

The comment states the measured number and its date: **22 rows carry a span and no recorded nights (2026-08-30), 12 of them live, and 4 of the 22 also carry an open conflict, so a per-night picker cannot help them at all.** Those four get the fallback sentence spelled out: Overture does not know which nights the run plays, so the card keeps whole-run behaviour and picks its nights up on the next scout.

`BlockedCalendar`'s own fallback stays as it is, and its own comment already says why: for those rows the span is genuinely all that is known, and clearing a real clash on no evidence is the one direction that loses safety.

### 1.3 Which nights count as a commitment

- A row with `sentAt`, or a live draft or approved status, contributes its **kept nights** (Phase 1 interim: all stored nights minus recorded drops; Phase 2 narrows this to nights Dan explicitly said to pitch).
- A **booked** row contributes **its opening night only**. `Prospect.isBooked` is a row flag naming no night; expanding a booked run across its span would assert Dan is shooting nights nothing recorded. The Downbeat calendar keeps ownership of booked work.
- `selfBookingIsCommitment` (`QueueView+Model.swift:2343`) is otherwise unchanged.

### 1.4 Calibrate the firing rate against the SHIPPED state, and name the population beside every figure

The brief's "20 to 21 marked nights" was measured with the expensive path switched off: it counts only the commitment side, under today's opening-night-only rule, at a moment when Dan has pitched exactly one multi-night run (L102). The change expands **both** sides, and decision 1 records him saying there is no real reason not to keep every night, so the commitment set grows to full run length as soon as the feature is used.

**Three simulations, each labelled with the population it counts (2026-08-30, whole store, engagement-key exemption applied, before `workable`'s gap quieting, which can only reduce the counts):**

| Figure | Population counted | Today | Expanded, same roster |
| --- | --- | --- | --- |
| Distinct marked nights | commitment nights | 16 | 17 |
| Rows carrying a clash marker | **live non-committed rows** (`new`/`queued`/`drafted`/`approved` that are not themselves commitments) | **9** | **21** |
| Rows carrying a clash marker | **all non-dismissed rows** | **17** | **29** |

The 9/21 pair and the 17/29 pair differ by exactly the **eight already-committed `contacted` rows that flag each other** (405, 430, 438, 458, 468, 478, 891, 894). Both are reported, so a reader cannot mistake the smaller for the whole problem. Neither is quoted without its population.

**And the figure that actually matters, which the two above cannot show.** The population that produces commitments once this feature is USED is the 96 live multi-night rows, each of which becomes a full-run commitment the moment Dan pitches it. Simulated by promoting live multi-night runs to full-run commitments (mean over 20 random draws, all non-dismissed rows carrying a marker):

| Live multi-night runs pitched full-run | Rows carrying a marker |
| --- | --- |
| 0 (today) | 17 |
| 5 | about 218 |
| 10 | about 304 |
| 20 | about 438 |
| 96 (all of them) | about 678 of 752 |

The mechanism is arithmetic, not an artefact: 752 non-dismissed rows sit on 222 distinct nights, a mean of 5.4 rows per night, and a 20-night commitment marks 20 of them at once. **Five full-run pitches take the warning from a rare signal to roughly a third of the queue.** That is L172 (a threshold sitting in the dense middle of the real distribution) and L36 (an alert that cries wolf) arriving together, and it is a consequence of decisions 1 and 8 held jointly, not of any implementation choice here. **It is escalated to Dan rather than designed around**, because which shows to pitch, and what counts as spoken-for, are his calls.

Two honest limits on that sweep, both stated wherever it is quoted: it draws runs uniformly from the pool including the longest ones, which is not how Dan pitches (one, maybe two shows a night, and decision 7 collapses a 20-night run to a single "pitch the whole run" press); and it is a ceiling taken over a hypothetical roster nobody will ever hold at once.

**All of these simulations were written beside the code, in Python over the store, and are therefore NOT admissible as the final figure** (L107: overture#2035/#2517 is exactly a funnel counted by a query beside the app, off by fifteen against the shipped rule, green through CI and a merge). **Before Phase 1 merges, re-derive them through the code's own predicates**: build `SelfBookingConflict.Show` values from the live store exactly as `QueueModel.selfBookingShow` does, run `sameNight` / `conflicts` / `workable`, and report the distribution that comes out. Quote **that** number, name the function that produced it, and name the population it was measured over. Decision 8's tiering becomes a rule with a measured cut line **before** Phase 1 merges, not after.

### 1.5 Do not turn a fix into a regression

`selfBookingConflicts` maps the whole **rendered set** into `Show` values **per row rendered**, and QueueView calls it per item. Multiplying that by up to 23 nights without an index is a measurable regression on the surface Dan lives in (`data-scale-exposes-latent-ui-bugs`, and overture#2417 is this repo already paying for it). Build a `[night: [Show]]` index **once per render pass** in `QueueModel`, hand it to the per-row calls, and add a test asserting the index is built once for N rows rather than N times (assert on a counted builder closure, never on a timing, per L224/L290).

### 1.6 Copy

Reuse `ConflictScope`: a clash on the card's own header night says what it says today; a clash on a later night of the run **names the night**. Regenerate `docs/copy-inventory.md`, `docs/outbound-copy.md` and `docs/copy-surfaces.md` and cold-read the diff in **every branch**, including one clash, several clashes, later-night, and the branch that renders when there is no clash at all (#1547).

### 1.7 Fixtures pin BOTH ends of every date relationship (L130)

Every fixture in this feature is a relationship between a stored date and a clock: whether a night is a commitment, whether a run's opening has passed while later nights remain, whether a blocked day is ahead. **Pinning only the fixture lets real time walk the pair into a different state, and the test then passes while asserting about a case nobody chose.** `AGENTS.md` documents this at length: four fixtures were bitten this way in one session while building #2645, and one test had spent months asserting a show 27 days in the past should still be chased.

So, as a stated step and not an intention:

1. **Every new fixture supplies its own clock.** No new test reads the live clock to judge a stored date.
2. **Run `scripts/check-fixtures-do-not-age.sh`** after the fixtures land. It shifts every dated fixture three years, runs the Swift suite, and names the tests that changed verdict.
3. **Read the new entrants rather than recording blind** (L182). For each: either it still asserts what it meant to, and `fixtures/year-sensitive-tests.txt` is re-recorded with a reason per entry, or real time walked it into a different case and the fixture is fixed.
4. Say in the PR body which tests the shift moved and why each is legitimate.

### 1.8 Guards, each seen to fail

`scripts/mutate.sh` with `--at` **first** and a literal aim; record the exact failure text in the PR body. Fixtures are named by shape and carry invented names (L155).

| Guard | Mutation | Expected |
| --- | --- | --- |
| A later night of a run collides | Revert `sameNight` to compare opening nights only | Red, naming the two-night-run-sharing-its-closing-night fixture |
| Empty nights does not span-walk | Replace the `performanceDate` fallback with `EasternDate.days(from:through:)` | Red on the weekly-series-with-dark-nights fixture |
| Per-night times, not the card's | Make `gapMinutes` read `timesByNight.values.flatMap` | Red on the weekend-matinee fixture |
| Booked contributes opening only | Expand a booked row to its nights | Red on the booked-run fixture |
| Dedupe on read | Remove the dedupe | Red on the repeated-night fixture |
| Rename does not self-clash | Revert the exemption to raw `groupName` equality | Red on the renamed-sibling fixture |
| Index built once | Move index construction inside the per-row loop | Red on the counted-builder test |

A `SURVIVED` is not accepted until mutate.sh's needle report confirms the text is gone from the file **and** the scope report confirms a suite that actually names the file ran (the `SCOPE MISSED THE FILE` and needle-still-present readings).

### 1.9 Sibling enumeration, DERIVED (L96, L30, AGENTS.md rule 3)

A hand-written sibling list only ever checks what somebody remembered. **The list is produced by two commands, and both go in the PR body so the next reader re-runs them:**

```
grep -rln 'runEndDate' mac/Overture --include='*.swift'          # 24 files, 2026-08-30
grep -rn  'EasternDate.runLastNight' mac/Overture --include='*.swift'   # 9 call sites, 2026-08-30
```

Each file gets one of three answers: covered by this change, correct as-is because it genuinely wants the whole run, or filed with an issue number. Four are the same defect class and **none was named in any earlier draft**:

- **`mac/Overture/Domain/BookingMatch.swift:39`** matches a Downbeat booking against `runEndDate ?? perfDate`. Once "the nights this run is pitched for" is a decided subset, a booking landing on a night Dan skipped matches a pitch that never named it. **Needs a stated answer, not a scope-out**: a match on a skipped night is wrong in the direction that reaches a stranger.
- **`mac/Overture/Domain/FollowUp.swift:162`** derives the run's last night through `EasternDate.runLastNight`, so a nudge can be owed against a night he never pitched. **Same: stated answer, not a scope-out.**
- **`mac/Overture/Domain/OutreachFunnel.swift:83`** counts a run as live by its whole span. Filed with a number if not covered here.
- **`mac/Overture/Domain/BulkDismiss.swift:52`** judges by the run's last night. Filed with a number if not covered here.

Also in this enumeration: `EventDateInDraft`'s span walk (closed in Phase 4.3, filed with a number in this body), and `BlockedCalendar.conflict` collapsing a run to one `Day?` (closed in Phase 3.2). The history correction goes in this body: the premise went stale at **#1523**.

**Exit criterion**: `scripts/test-all.sh` green locally; `scripts/check-fixtures-do-not-age.sh` read and re-recorded; `scripts/check-test-identity-provenance.sh` run and its report quoted; PR body carries all four enumerations using the literal words **writer**, **reader**, **sibling** and **seen**; merged through `scripts/verify-and-merge-branch.sh`. The Phase 0 exposure ends here, by the merge, not by anybody announcing it.

---

## Phase 2: the record

### 2.1 The shape, and why the affirmative gets its own column

Three states are needed, and the third is the point: a night in `runNights` with no entry is **unjudged**, which is neither pitch nor skip.

- **`droppedRunNights` is unchanged**: same name, same three-field `night|reason|epoch` format, same meaning ("a night subtracted from this run"). The picker's skip writes it through the existing `dropNight` path, so decision 1 holds: **an untick is a real #2691 drop through the existing machinery, not a parallel mechanism.**
- **A new stored property `pitchedRunNights: [String]`**, entries `night|epoch`, records nights Dan explicitly said to pitch. It has to be a separate column for two independent reasons, both load-bearing:
  1. **A pitch subtracts nothing**, so it has no business in a list named for what was dropped. Putting it there would give one word two units (L118) inside the one structure every reader of the run's nights walks.
  2. **Rollback safety (L267).** Extending `droppedRunNights` to a fourth field would mean an older build, whose `DroppedNight(stored:)` returns nil on an unparseable entry and whose `restoreNights` does `droppedRunNights = kept.map(\.stored)`, **permanently destroys** every four-field entry the next time Dan pressed undo (L105). Carrying raw unparseable entries forward cannot reach that harm: it would ship in the **new** build, which parses four fields perfectly, while the destruction is done by the **old** build that is already installed and will never carry the fix (L173). Keeping `droppedRunNights` strictly three-field means an old build's rewrite of it is lossless, and an old build cannot touch `pitchedRunNights` at all.

**Say plainly in the PR body and in `pitchedRunNights`'s own comment** what a first write costs: an older build reading the migrated store will not see the pitch decisions and will treat every unjudged-or-pitched night as simply present. That is a degradation, not data loss, and it is the honest statement rather than a rollback promise the code cannot keep. `mac/build-install.sh` builds whatever is checked out and the freshness panel's Update installs whatever main carries, so running a prior build against this store is a real workflow.

### 2.2 Blocked and unmeasured nights are DERIVED, and their members are RECORDED (L507)

A night blocked by the Downbeat calendar or by a day off is **not written into Dan's reason vocabulary**. It is recomputed per launch and excluded from what the drafter is given.

That half is right and does not change: writing an app-made skip into `droppedRunNights` with one of Dan's four reasons would put a judgement nobody made into the same field, the same vocabulary and the same #16 funnel as the decisions he made himself, which is exactly what `RunNightDrop`'s own comment guards against on the release path ("Dan's reason goes on HIS night and on no other"). Deriving it also has the right behaviour when the booking goes away: the night comes back, with nothing to un-write (L192).

**What that leaves, and what this plan adds.** Blocked and unmeasured nights would otherwise be a category defined as a **remainder** (`runNights` minus pitched minus skipped), computed from a calendar that changes and recorded nowhere. The count always reconciles, which is what hides it, and the subtraction cannot be run backwards once the booking is cancelled or the export is replaced. So the question #16 will eventually ask, *which nights of this run went unpitched because Dan was already shooting*, could never be answered.

**Therefore: record the members at the moment they are computed**, in a store that is plainly not a decision of Dan's. A per-launch record naming the run's key, the nights excluded, and **which deciding day excluded each** (the `BlockedCalendar.Day` the picker already resolves in order to name the clashing shoot in its copy). Nothing about Dan's vocabulary changes, `droppedRunNights` stays his alone, and the bucket becomes enumerable rather than a subtraction.

Five per-night states, then, and every one is distinguishable:

| State | Where it lives | Who wrote it |
| --- | --- | --- |
| **pitch** | `pitchedRunNights` | Dan |
| **skip** | `droppedRunNights`, with his reason | Dan |
| **blocked** | derived per launch; **members recorded in the per-launch exclusion record** | the app |
| **unmeasured** | derived: the export could not be read; **also recorded, with that as the deciding reason** | the app |
| **unjudged** | in `runNights`, in neither list | nobody |

**#16's reporting counts only the `droppedRunNights` entries as Dan's per-night dismissals.** The exclusion record is read separately and is **never** counted as a dismissal. Both statements go in the PR body's reader enumeration, naming which surface reads the exclusion record.

### 2.3 The invariant nothing states and nothing tests

**A per-night drop must NOT stamp `status`, `dismissedAt` or `showOutcomeRaw` on the ROW.** Today that holds only as a side effect of where the code sits: `dropNight` returns `.moved` / `.wholeShow` / `.fullyCovered` and the caller decides whether to call `markDismissed`. Nothing names the rule and nothing tests it (L281), and Phase 3 adds a brand new caller, which is exactly the first change that can remove it silently.

State it in the PR body's reader enumeration and pin it **on both existing call sites plus the new one**, derived from `grep -rn 'dropNight' mac/Overture --include='*.swift'`:

- `ProspectMutations.swift:712` (`dismissAll`, the bulk path)
- `ProspectMutations.swift:817` (`dismissForReason`, the card menu path)
- the new batch caller from Phase 3.6

Per call site: after a skip of later nights, the row's `status`, `dismissedAt` and `showOutcomeRaw` are unchanged and the show still appears in the queue. **Mutate each path to call `markDismissed` and confirm the test goes red.** Pinning one and leaving the other free is the sibling-enumeration failure AGENTS.md's own rule exists to catch.

Then the **three** outcomes are told apart by tests rather than by which caller was written first:

- `.moved`: no status write. (Above.)
- `.fullyCovered`: closing the row **is** correct, the reason is `.duplicate` and never Dan's. Its own test.
- `.wholeShow`: `dropNight` returns this when nothing remains, and the caller dismisses the whole show. Its own test, driven **through the new batch caller** as well, because that is the path Phase 3.3's bulk control reaches (see L180 in Phase 3.3).

### 2.4 What reads the record

- `DroppedNight.keeping` subtracts only `droppedRunNights`, unchanged.
- **One accessor** on `Prospect`, exposing `pitchedNights`, `skippedNights`, `unjudgedNights` and `pitchedNightsNoLongerInTheFeed`, read by the picker, the self-booking check, the prep gate, the handoff and the draft check, so those five can never disagree (L16).
- **`pitchedNights` INTERSECTS with `runNights` at the read (L200).** `runNights` is rebuilt from the venue's feed on every scout, so a night the venue cancels leaves `runNights` while its pitch entry stays behind. Without the intersection the drafter is handed a date the run no longer plays. `DroppedNight.keeping` already carries this exact lesson for its `.duplicate` release, re-checked at read time because an exclusion granted on the grounds that another record covers it must re-check that record; `pitchedRunNights` is the mirror and gets the same treatment.
  - The **raw entries stay stored**: they are Dan's decisions, and a night can come back to the feed.
  - The accessor's **fourth answer**, `pitchedNightsNoLongerInTheFeed`, makes the difference reportable rather than silently dropped (L11).
  - Guard, seen to fail: a row whose pitched night has left `runNights` hands the drafter a payload that does not name it, and the fourth answer names it instead.
- Phase 1's commitment nights narrow from "stored minus dropped" to "pitched", with **unjudged nights not counted as a commitment**. This is a deliberate reversal of Phase 1's interim rule and is stated as one in the PR body: an unjudged night is not something Dan promised anybody.

### 2.5 Stamp what a pitch actually named, at the moment it becomes true (L318, L37)

An earlier draft made this a permanent read-side default: "no pitch entries means every recorded night is treated as pitched, for any row with `sentAt`". **That is a default read at USE time over a value the system rewrites underneath it.** `runNights` is rebuilt from the feed on every scout, so the next scout can add a night the venue announced *after* the email went, and the rule would then assert that the already-sent pitch named it. The system would report a night as pitched that no email ever mentioned, and would change its answer silently on every scout run. #16's funnel reads these records.

So:

1. **Write time, not read time.** When a prep run's draft is **approved or sent**, write the nights that pitch actually named into `pitchedRunNights` on that row, **from the same `pitchNights` value the handoff carried in Phase 4.1**, so the two cannot disagree and the fact is captured at the moment it becomes true.
2. **The historical default is a ONE-TIME backfill, written once**, for rows sent before this ships (20 rows today, one of them multi-night). It is written against a store copy first (Phase 2.7's dry-run precedent), then applied, then never re-evaluated.
3. **The accessor's comment says which rows carry a stamp and which were backfilled**, so the two are never confused by a later reader.
4. Guard, seen to fail: a sent row whose feed gains a night after the send still reports its pitched nights as the nights it was stamped with, not the nights the feed now lists.

Nothing is invented onto a row nobody decided. A recorded decision nobody made sits exactly where a real one would (L249), which is why the backfill is bounded to rows that predate the feature and says so in its own record.

### 2.6 Fix the merge classification, in the correct bucket

`droppedRunNights` and the new `pitchedRunNights` are **decisions of Dan's that the survivor rule cannot see**, so they move into **`ProspectFieldClassificationTests.danDecisionsTheRuleCannotSee`** (`:200`), not into `hasRecordBeyondADismissal`.

That distinction is not a detail. `hasRecordBeyondADismissal` asks "did this row reach the OUTSIDE WORLD", which is false for a night decision, and its other job is deciding a **deferral**: teaching it to answer yes here would reintroduce #1780's deadlock and make every dropped-night row an undeletable duplicate. The file's own comment (`ProspectFieldClassificationTests.swift:195-199`) says exactly this.

Since #3124 that bucket carries a hard obligation: `everyDecisionOfDansIsCarriedOntoTheSurvivor` fails unless `NaturalKeyVenueMigration.carryDansDecisions` (`:195`) also names the field. **So the same change adds carry rules for both fields**, on the precedent already in that function (Dan's call, 2026-08-22: keep one card and carry both decisions onto it):

- **`droppedRunNights`**: **union** the members' entries, deduplicated by night, freshest epoch winning a duplicate night. A skip is a statement about a night, so two members each holding a different night both survive; two members holding the same night with different reasons keep the later one, the same tie-break the rename rule already uses.
- **`pitchedRunNights`**: same union, same tie-break.
- **Where a night appears in one member's skips and another's pitches**, the freshest epoch wins and the loser is dropped rather than kept in both lists, because a night that is both pitched and skipped is not a state any reader can render.

The measurement goes in the reason string with its date and its keys only: **4 of the 9 rows holding drops are `new` (2026-08-30: 386, 425, 435, 619), so `hasOutreachHistory` does not protect them and the launch merge can delete Dan's per-night decisions today.** This is a sibling of the defect that started the work and belongs in the enumeration.

### 2.7 The `naturalKey` writer, and both corrupt rows

The corruption is **not** a generic `ScoutService.apply` write. It is the #2691 branch in `mac/Overture/Integration/ScoutService.swift`:

- `:1618-1620` reassigns `existing.performanceDate = DroppedNight.keeping(...).min()` when the feed still lists a dropped opening night, with **no `naturalKey` write beside it**.
- `:1622-1624`, the `else`, has the same hole.
- `:1281` (`match.naturalKey = key`) only covers the URL and series match arms and never reaches these two.

**Fix: route both branches through one helper that writes `performanceDate` and `naturalKey` together**, so the pair cannot drift, rather than adding a second assignment beside each.

Add a store-wide invariant test **keyed on rows carrying drops**, since that is where the defect lives, printing its **corpus count** and carrying a real third **UNMEASURED** state on the `ReplyInvariantsLiveStoreTests` precedent, so a suite that measured nothing cannot read as a clean bill of health (L98, L11).

Repair **both pk 361 and pk 914** (both `dismissed`, so cheap), dry-run against a store copy first, and only with Dan's explicit go-ahead, since it rewrites the identity of two of his cards.

### 2.8 A re-key records itself

`RunNightDrop.dropNight` re-keys in place and records **no** `NaturalKeyRemap` entry; `NaturalKeyRemap.record` has exactly one caller today (`NaturalKeyVenueMigration.swift:153`). Phase 3 turns a two-control-per-card operation into a batch across many runs in one press, so whatever this loses today it will lose at a much higher rate.

**Enumerate every store of `naturalKey`, derived from the code rather than by hand** (`grep -rl 'naturalKey\|showKey' mac/Overture --include='*.swift'`, 54 files on 2026-08-30), with the command in the PR body, and state per holder: migrated, safe because regenerated, or covered by a filed issue number. Two are already known and neither is optional:

- **`ContactRefusal`** keys struck addresses on `showKey`, which is `p.naturalKey` (`mac/Overture/Integration/PrepQueueService.swift:51`). A strike recorded against the old key **silently un-strikes** when the row re-keys, which is L92 in this exact repo (overture#2392/#2421). Cover it or file it in this PR body.
- **`AppleScriptOmniFocusClient`** completes tasks by matching a note containing the natural key (`completionMatchClause`), which is L166's own incident here.

Then make `dropNight` (and Phase 3.6's `dropNights`) **record the rename** through `NaturalKeyRemap.record`, exactly as the launch migration does (L15).

### 2.9 Correct the comment that teaches the old model

`RunNightDrop.swift:182-186` asserts that "the night being dropped is always the run's first remaining night. There is no way to reach a middle night from either control". That stops being true here. **Correct it in the same change and use it as a `mutate.sh` target**: leaving it standing recruits the next reader into the old model (L263), and a comment asserting a reversed rule misleads exactly as much as an assertion (L252).

Before implementing, run `scripts/find-tests-naming.sh dropNight droppedRunNights isAboutOneNight` and read every test it names, per #3163: a test asserting the old single-night invariant is the guard defending the rejected behaviour, and it is **deleted** rather than adjusted.

---

## Phase 3: the picker, inside `PrepSelectionSheet`

### 3.1 Where it lives

A `DisclosureGroup` per multi-night run **inside** the existing sheet, not a sheet over a sheet. The sheet already stages a `Set<String>` in view state, already takes `allItems` for clash detection, already has a confirm-then-commit gate, and already writes nothing on Cancel. Putting the night decisions in the same staged structure makes "two runs in one batch prep" unrepresentable rather than handled.

The sheet's header comment (`PrepSelectionSheet.swift:7`) says the selection is "PER-RUN and transient: nothing persists". That stops being true and the comment changes in the same diff.

### 3.2 The blocked set is built ONCE, outside the sheet

**Reading `conflictKey` is not enough, and `conflictOpen` is the wrong input entirely.** Because Keep clears the flag, `hasUnclearedConflict` is false for essentially every card that reaches this sheet, so a picker shading blocked nights off that flag would show none. And a row stores exactly **one** blocked night: `Prospect.conflictScope` derives from a single `conflictKey`, and the badge reports the earliest blocked night of the run. On a 23-night run the app knows about at most one blocked night, so a default of "every later night that is not blocked" would offer 22 nights **because nothing measured them**, a night that is genuinely booked indistinguishable from one that is genuinely free, in a control whose whole job is to stop Dan offering a stranger a night he cannot work. That is L42 from one side and L98/L11 from the other.

So:

1. **Add a per-night member to `BlockedCalendar`** answering, for a list of nights, which are blocked and by which `Day` (`decidingDay` is `private` today and `conflict` collapses to the earliest at `BlockedCalendar.swift:259-263`). This is the third instance of the run-awareness gap named in Phase 1.9, closed here. Its answer is also what feeds Phase 2.2's exclusion record.
2. **Build the blocked calendar exactly once per launch, on the path that OPENS the sheet**, via `ScoutService.blockedCalendar(export:context:)`, and hand the sheet the derived per-night set as part of its value-type snapshot. That call takes the Downbeat export from `DownbeatBridge.loadedExport()`, which decodes it from disk. A decode inside the sheet's `init`, or inside a `DisclosureGroup` body SwiftUI re-evaluates, is L91 and L62; overture#2417 is this repo already paying for it, and Dan named the lag before anyone looked at the cause.
3. **Test it with a counted builder closure: one build per launch regardless of how many runs the batch holds.** Mutate the build into the per-run body and see it go red, the same shape Phase 1.5 commits to for the night index.
4. **A night the app could not measure gets its own state**, distinct from pitch and from skip, and is **not** silently offered as a keep. If the export cannot be read at all, the sheet says so and refuses to default-tick anything, on the same evidence rule `DroppedNight.keeping` already uses for `.unreadable`.

### 3.3 What it offers, and how it reconciles with decision 4

Decision 4 states the default over **all** nights (the opening night plus every later unblocked night). The sheet must also not re-ask about nights Dan already decided last week. Those are not in conflict, but the copy has to say so, or a run he half-decided reads as a run with fewer nights than it has:

- **Already-decided nights are shown in their decided state, not hidden**, with the count named in the run's own header ("3 of 12 nights already decided"). A control reopens them; it does not nag.
- **Unjudged nights default per decision 4**: pitch, unless the measured blocked set says otherwise. **That default is COMMITTED as a write on Run, not left as a view-state tick** (see 3.4).
- **A blocked night starts SKIPPED with the clashing shoot named**, and Dan can overtly pitch it anyway (decision 5). See 3.7 for what that press writes: it is two fields in one operation, never one.
- **Vocabulary (L118): the per-night control says "Pitch this night" / "Skip this night", never "Keep".** "Keep" already names one unit in this product: Dan's card-level decision at Scout, which is what accepts a calendar clash (#1583) and what `QueueItem.isKept` carries. Giving the same word a second unit at a second scale is exactly the shape where each sentence is correct alone and the contradiction exists only in the reading, and it would reach both the copy-inventory cold read and #16's reporting. The chosen word is checked against **every** other place the product uses it during the cold read, not only against the new sentences.
- **A run with an empty `runNights` and a span** (22 rows, 12 live, 2026-08-30) says plainly that Overture does not know which nights it plays and falls back to whole-run behaviour. It never fabricates a night list from the span.
- **Bulk controls per run**, because 23 rows is not a decision surface. A 20-plus night run opens **collapsed** on "Pitch the whole run" (decision 7); pressing that is an overt decision and writes `pitchedRunNights` for every unblocked, measured night. Blocked and unmeasured nights are excluded from it and are not written to Dan's lists, per Phase 2.2.

**"Skip every night" has a stated consequence, derived from the run in front of him (L180).** An earlier draft named this control and never said what it does. Read against the code it rides on, `RunNightDrop.dropNight` returns `.wholeShow` when nothing remains, and the caller then dismisses the whole show. So as written the control silently closes the card, which is the one outcome Phase 2.3's invariant says a per-night drop must not produce, from a control whose wording is entirely about nights.

The decision, and it is stated in the copy rather than implied: **skipping the last remaining night of a run IS a card dismissal, and the control says so before it acts**, in a sentence derived from the run it is about (naming the run and the reason it will record), not a fixed warning shown on every press. The alternative, refusing the last night from this control and pointing at the card-level Dismiss, is the escalated variant if Dan prefers the picker never to close a card. Either way the sentence is derived from state, never asserted (L180), and the `.wholeShow` path from the batch caller gets its own test alongside the `.fullyCovered` one Phase 2.3 already commits to.

### 3.4 The default is a WRITE, and the payload rule is exhaustive (L113)

Phase 2.2 defines a five-value vocabulary. An earlier draft then defined the drafter payload's treatment of two of them and left three silent, and **both readings of that silence are defects**:

- If an unjudged night is IN `pitchNights`, decision 8 is broken and the feature ships the exact defect it was built to fix: a night nobody decided about offered to a stranger.
- If it is NOT, then a Dan who opens the picker, agrees with every default and presses Run pitches only the nights he touched, which on a collapsed 20-night run is none.

So:

1. **Pressing Run COMMITS a `pitchedRunNights` entry for every night the picker showed as defaulted-to-pitch.** The decision he agreed to by not changing it is recorded in the store, so decision 2's "overt" reading is honoured by the record rather than by the screen. After Run, the run has no unjudged nights left.
2. **The payload rule is an exhaustive switch over the five states, in the shared accessor**, not a filter scattered across call sites. Precedent already in this repo: `RunNightDrop.classified` / `everyMenuReasonIsClassified`.
3. **Completeness test**: a per-night state added later that nothing maps into or out of `pitchNights` fails the suite.
4. **Assert explicitly that an UNMEASURED night is never in `pitchNights`**, and that a **blocked** night is in it only where an `acceptedNightConflicts` entry exists for it (3.7).

### 3.5 Walk the app, because none of this is visible from a test

`scripts/test-all.sh` cannot answer any of what follows, and this repo's own memory records it twice (`walking-the-app-finds-what-tests-cannot`, `ui-and-scroll-fixes-need-live-release-build`). Twenty-three night rows inside `CappedScrollView(maxHeight: 360)` (`PrepSelectionSheet.swift:53`) is L76 (a clipping region must show its content continues) and L189 (a pinned surface over a scrolling region can make the last item unreachable) at once.

**Explicit step, not an intention:** run `mac/scripts/run-debug.sh`, open the picker on a real multi-night run in the **Debug** store, and check the collapsed 20-plus case, the expanded two-night case, a blocked-night row, an unmeasured-night row, the empty-`runNights` fallback, the "skip every night" consequence sentence, and the scroll behaviour at Dan's actual window size. Screenshot each. Put what was seen in the PR body. Screenshots are checked for identities before they go anywhere near a public artifact (L155, L222).

### 3.6 The ordering discipline: per-RUN boundaries, a batch reservation, and a re-check at the write

`PrepSelectionSheet.Row.id` is `p.naturalKey`, `selected` is a set of those keys, and skipping an opening night **moves `naturalKey`**. Three separate hazards, and each gets its own answer.

**(a) The batch is blind to itself.** Settling every availability lookup against the store before any write is correct against the store and blind to the batch: two runs in one press can both read the same candidate opening as `.free`, both write, and SwiftData **merges the two rows into one taking fields from each with no error raised**, which is what `RunNightDrop`'s own comment records as measured on 2026-08-15 (8 of 98 multi-night runs land on a key another card already holds). So a **reservation set** is carried through the batch: each run's availability walk treats a key already claimed by an earlier run in the same batch as `.taken`, not `.free`. L145 is this feature's own ancestor, overture#2754.

**(b) A pre-pass is a judgement formed before the write (L157).** An atomic operation guarantees only its own span, and this design **widens** the window: `dropNight` today settles its lookups moments before its own write for one card, while a batch pre-pass stretches that window across every night of every run in the press. Anything writing a prospect in that window (a scout import folding a new card onto a candidate opening, a second window, a restore) invalidates a judgement the batch is about to act on, and the cost is not an error but the silent merge above.

So: **re-check each candidate key inside the same critical section as its write, immediately before writing it, in addition to the batch-wide pre-pass**, and refuse **that one run** when the re-check disagrees with the pre-pass. Prove it the way L157 asks: stage a fixture where the store gains a card on a candidate opening BETWEEN the pre-pass and the write, through the injected `lookup:` seam `RunNightDrop.dropNight` already exposes, and see the write refuse rather than merge. A pre-pass alone can only ever prove the store was clear a moment ago.

**(c) The failure boundary is the RUN, not the batch (L73, L54, L47, L11).** An earlier draft failed the whole batch closed on any collision or any `.cannotCheck`. The runs in one Prep launch are independent of each other: one run's key colliding with another's, or one row the store could not read, says nothing about the other eight. As written, one unreadable row refuses a healthy launch, the reliability of every run's prep depends on every other run's worst case, and nothing is recorded on the runs that were fine, so a re-press cannot tell an untried run from one that failed.

So: **settle and write each run's night decisions atomically on its own**, launch Prep for every run that committed, and report the ones that did not with their own distinct reasons, never one refusal covering all of them:

- a key taken in the store
- a key reserved by another run in this same batch
- a `.cannotCheck` (the store could not answer), naming the night
- a failed save on that run

Each is a different message. A run that committed is launched; a run that did not is named with its own cause and its state is unchanged. If Dan genuinely wants all-or-nothing, that is his call and it is in escalatedDecisions with the cost named, not a default that blocks a healthy launch.

**The order, per run:**

1. Batch-wide pre-pass over every candidate key, carrying the reservation set (a) and refusing an in-batch collision for the run that loses it.
2. For each run in turn: re-check its candidate keys (b), then commit and `save()`. A failed save aborts **that run** and says so; it does not launch that run over its pre-picker state.
3. Record every rename through `NaturalKeyRemap.record` (Phase 2.8), and re-read every `naturalKey` from the store.
4. Compute self-booking clashes over the **pitched** nights, using the re-read keys.
5. Build the queue from the runs that committed, and show the per-run refusals beside it.

### 3.7 The waiver: `acceptedNightConflicts`, and the code path that WRITES it

`conflictKey`, `conflictClearedKey` and `conflictOpen` are one column each, and that vocabulary structurally cannot say "I accept this night but not that one". Add **one** new stored field, `acceptedNightConflicts`, shaped `night|deciding-day-key` on the `DroppedNight` self-describing precedent, so a clash that changes under Dan re-blocks that night (the #718 rule `conflictClearedKey` already implements at card level).

**The writer is named in the same change, and it writes both fields in one operation (L46, L90, L109).** An earlier draft described this field's shape and its re-block semantics and never named a writer. The consequence would not have been a dormant field, it would have been a **dead control**: decision 5 lets Dan overtly pitch a blocked night, and if that press wrote `pitchedRunNights` and nothing wrote `acceptedNightConflicts`, the send gate's predicate ("a pitched night that is blocked and unwaived") stays true, `Recipient.isSendablePending` stays false, and the draft can never be sent, on precisely the night he overtly chose. That is L109 exactly, and L42 pointed the wrong way: failing closed there refuses the decision rather than protecting it.

So:

- **The picker's "pitch this blocked night anyway" action writes BOTH the `pitchedRunNights` entry AND an `acceptedNightConflicts` entry carrying that night's deciding-day key, in one operation**, so the two cannot be written apart.
- **Tests, seen to fail**: a run with one blocked night Dan overtly pitched is **sendable**; and it becomes **unsendable again** when the deciding day changes. **Mutate out the `acceptedNightConflicts` write and confirm the sendability test goes red.**
- **Do not claim the card-level waiver has never been used.** `conflictClearedKey` reads zero on every row today, but `setScoutConflict(nil)` nils it whenever a clash goes away, so a present-tense zero measures nothing about history. What can be said is what the code's own #1583 comment says: the separate Clear control was superseded by Keep, because Keep is where the acceptance actually happens.

### 3.8 Two gates, not one column (this is the security-shaped change)

**The prep gate and the send gate are the same stored column today**, and relaxing it for prep silently relaxes the send. `Recipient.isSendablePending` (`Recipient.swift:677`) reads `prospect?.hasUnclearedConflict != true`, `hasUnclearedConflict` **is** `conflictOpen` (`Prospect.swift:1004`), and `conflictOpen`'s own comment (`Prospect.swift:707`) states the dual role, as does #901's. On a run where Downbeat books one pitched night while another pitched night is free, a single narrowed writer would make `conflictOpen` false, `isSendablePending` true, and **an approved draft naming the booked night would send with no gate anywhere**. That is L53 exactly, and CLAUDE.md's rule about never shipping a weakened protective control without explicit sign-off applies to the send half specifically.

So:

- **`conflictOpen` keeps its current meaning for the SEND path**: any pitched night is blocked and unwaived, where "unwaived" reads `acceptedNightConflicts` (3.7). This is what #901 built it for and it is not weakened.
- **A separate stored value governs PREP eligibility**: "no pitched night is workable". `needsPrepPredicate` reads that one, since a `#Predicate` cannot call a Swift function and this is why the flag is stored at all.
- Both are written in one place (`ConflictSweep` / `setScoutConflict` / `clearConflict` / `restoreConflictClearance`), both named in the PR body's writer and reader enumeration, and `StageNavigation`'s `.prepBlocked` complement (`StageNavigation.swift:243`) moves onto the prep value so `.prep` and `.prepBlocked` stay exact complements (L45).
- **Test: a run with one booked pitched night and one free pitched night is preppable AND not sendable.** Mutate the send gate to read the prep value and see it go red.
- `PrepQueueEligibilityParityTests` pins the plain-Swift function and the `#Predicate` never drifting; both sides move together or the suite goes red.

### 3.9 Guards

- Undo of a multi-night drop restores every night in one press and puts the key back.
- A save failure aborts **that run**, with the exact message, leaving its store state unchanged, while other runs still launch. Mutation: make the save always succeed in the fixture and assert the abort test goes red.
- A `.cannotCheck`, a store-taken key, and an in-batch reservation collision are **three different messages** on **three different runs** (L11), and none of them refuses the other runs.
- The pre-pass/write race: a card arriving on a candidate opening between the two refuses that run rather than merging (L157).
- A run with every pitched night blocked is `conflictOpen`; a run with one pitched night free is not; and the prep value and the send value disagree in exactly that case, on purpose, with both directions tested.
- The row-stamp invariant of Phase 2.3, driven through the new batch caller **and** through both existing callers.
- Phase 1.7's fixture discipline applies again here: every new dated fixture pins its own clock, and `scripts/check-fixtures-do-not-age.sh` is run and its new entrants read before this merges.

---

## Phase 4: the handoff, the runbook, and the draft check

### 4.1 `PrepQueue` v13 to v14

Add `pitchNights: [String]?` to `PrepQueueItem`: the nights this pitch may name, produced by the exhaustive switch of Phase 3.4 and intersected with `runNights` per Phase 2.4. Absent means the file predates the field; empty means the app looked and knows none (the `houses` precedent's absent-versus-empty rule, stated in the field's own comment).

**Decide what happens to `runEndDate` at v14, explicitly, and say so in the field's comment.** Adding `pitchNights` while leaving `performanceDate` and `runEndDate` in place means the payload still *demonstrates* the span the prompt is now banning, and the demonstration outweighs the instruction (L270). Worse, `openingNightPassed` is **computed from `performanceDate` and `runEndDate`** (`mac/Overture/Integration/PrepQueueService.swift:97`), so the span is not merely present, it is load-bearing in a second field the drafter reads.

The decision: **when `pitchNights` is present it is the only date set the drafter may use.** `runEndDate` is dropped from those items, and **`openingNightPassed` is recomputed from `pitchNights`** (pitched nights already in the past), which is what Phase 4.2's own rule about two checks not sharing one fact requires anyway (L53). `performanceDate` stays, because every non-date consumer of the item keys on it, and the runbook states plainly which field wins.

**Deterministic boundary check, seen to fail: a v14 item carrying `pitchNights` carries no span the drafter could prefer.**

Artefacts, all of them:

- `PrepQueueBuilder.version` 13 to 14 (`mac/Overture/Domain/PrepQueue.swift:234`)
- **`fixtures/prep-queue/v14.json`**, beside v1 to v13
- **`docs/contracts.md:30`**: append `14` to the version list
- **`docs/prep-runbook.md:23`**: the prose `` `PrepQueue` version `13` `` to `14`, plus the field list in that Input spec
- `PrepQueueContractTests.swift`
- `src/lib/prepQueueSpec.test.ts` pins the Swift number against the runbook prose in both directions, so a mismatch is caught by `pnpm test` before a push

### 4.2 The runbook edit is three files, two of them untracked and authoritative

1. `docs/prep-runbook.md`, the "**Run dates (#1122)**" paragraph at **line 1045**
2. `~/.claude/skills/dan-wright-brand-voice/SKILL.md` (line 73 carries the run-date sentence)
3. `~/.claude/skills/dan-wright-brand-voice/references/email-and-alt-text.md` (line 10)

The skill always wins. **`scripts/check-brand-voice-drift.sh` does NOT guard this rule today, and an earlier draft of this plan claimed it did.** Its `BRAND_VOICE_ANCHORS` list (`scripts/check-brand-voice-drift.sh:37`) holds credentials, marquee venues, the portfolio domain, opener shapes, the closes and the rate facts; `BRAND_VOICE_SKILL_FACTS` holds four numeric value patterns. **Nothing in either list matches the run-date paragraph**, so editing the runbook and forgetting the skill produces no warning at all. (Verified 2026-08-30: the shared phrase "your run at BAM, March 10 to 14" is present in all three files and in neither anchor list.)

So: **add a `BRAND_VOICE_ANCHORS` entry for the new run-date rule in the same PR as the runbook edit**, choosing a phrase from the NEW wording that will be present in all three files after the edit, and confirm it is unique in each. The anchor must come from the replacement text, not from the text being removed. Without that entry, Phase 4.2 has no guard at all.

Also add a `RUNBOOK_RULES` entry with a unique phrase, so the rule is guarded rather than hoped for (L27); `prepRunbookRules.test.ts` already runs a per-rule removal loop, so the L1 proof costs one array entry.

The runbook's new paragraph states: **the item's `pitchNights` are the only dates that may be named. Never a span, never a date not on that list.** And it states the `openingNightPassed` rule in terms of `pitchNights`, since that field is now computed from them.

### 4.3 `EventDateInDraft`

The acceptable set becomes the **pitched nights**, not `EasternDate.days(from:through:)` (`mac/Overture/Domain/EventDateInDraft.swift:48`). This is the sibling defect named in Phase 1.9 and it closes here.

**Three behaviour changes, not one, and each wants a test**, because `EasternDate.days` has two edge behaviours beyond the dark-night one that disappear with it:

1. Dark nights of a run no longer count as acceptable (the intended fix).
2. `EasternDate.days` **caps at `maxRangeDays = 366`** (`EasternDate.swift:57`), so a run longer than a year silently truncated its acceptable set; a pitched-night list does not.
3. `EasternDate.days` returns **`[start]`** when the end date is unparseable or earlier than the start (`EasternDate.swift:61`), so a scraped nonsense `runEndDate` used to collapse the acceptable set to the opening night; a pitched-night list has its own answer for an empty list, which must be stated (refuse to lint rather than accept everything, per L98).

Behaviour stays **advisory** by default: Dan's rule is in the file's own header and in memory (`dan-dislikes-anything-he-cannot-override`). Any move to blocking is escalated, not taken here.

For a large pitched-night run the label helper needs a stated rule for what it prints when the sentence cannot enumerate 20 dates. Proposed: the check accepts a draft naming **any** pitched night, and the warning's own sentence names the first three plus "and N others", never a span, because a span is exactly the claim that stops being true once one interior night is skipped.

### 4.4 The eval

A runbook edit means `scripts/eval-prep-runbook.sh --yes` should be run before shipping; `scripts/check-prep-eval-freshness.sh` will warn on every `test-all.sh` until it is. It spends a real AI run, which on the Max plan is **time, not dollars** (`dan-rejects-dollar-estimates-on-a-max-plan`). Whether to run it is escalated.

---

## Phase 5: sweep and correct the record

1. **Correct #1986's body**, which claims self-booking "already works per night". It does not, and this work is the disproof. Do it in the same change that disproves it.
2. **Correct `SelfBookingConflict.swift:35-36`**, which states the stale premise. That comment is a `mutate.sh` target that writes its own L1 proof.
3. **Correct `RunNightDrop.swift:182-186`** (Phase 2.9) and delete any test that asserts the reversed invariant, found through `scripts/find-tests-naming.sh`.
4. **File the upstream duplicate-night fold defect separately** (15 rows, 2026-08-30). Phase 1 dedupes at every read; the fold that writes duplicates is a different bug with a different owner.
5. **File the per-night vanished-from-feed REPORT** as its own issue. The live half is **not** deferred with it: Phase 2.4 intersects `pitchedNights` with `runNights` at the read, so a night that left the feed can never reach `pitchNights`, the commitment set or the prep gate. What the filed issue covers is the surface that shows Dan `pitchedNightsNoLongerInTheFeed` for a row already sent, as a report and not a gate.
6. **Answer or file each of the four `runEndDate` siblings from Phase 1.9** (`BookingMatch.swift:39`, `FollowUp.swift:162`, `OutreachFunnel.swift:83`, `BulkDismiss.swift:52`), with the derivation command in the PR body so the list is re-runnable rather than remembered.
7. **Sweep the other repos** for the same class per L195: a single stored value standing in for a multi-valued fact.

---

## Cross-cutting engineering rules this plan commits to

- **Identities never leave the store.** Rows are named by primary key and status. Fixtures carry invented names and are titled by shape. `scripts/check-test-identity-provenance.sh` runs after each fixture batch, its report is read and quoted (L155, L222, L182).
- **Fail loud, and per run.** Every refusal in the picker path (`.cannotCheck`, an in-batch reservation collision, a store-taken key, a failed save, an unreadable Downbeat export) has its own message naming its own cause, applies to **one run**, and never folds into another or into the batch (L11, L73). No catch block returns an empty night list.
- **Assume it runs twice.** The drop batch settles every lookup with a reservation set, **re-checks each key inside its own critical section immediately before the write** (L157), and is atomic per run. A re-press after a partial failure finds each run in a state that says what happened to it. Undo is one entry per press.
- **Who may call it, whose data.** This is a local single-user SwiftData app with no routes and no tenants, so the equivalent statement is ownership: the scout owns `conflictKey` and `runNights`; **Dan owns `droppedRunNights`, `pitchedRunNights`, `conflictClearedKey` and `acceptedNightConflicts`, and no scout path may write or clear any of them.** A test asserts `ScoutService` names none of the Dan-owned fields, derived from the source rather than from a hand-written list (L96).
- **Two independent checks never share one status column.** Prep eligibility and send eligibility get separate values (Phase 3.8), and a test holds them apart in the one case where they must disagree.
- **Nothing the app inferred is presented as something Dan recorded**, and nothing the app excluded is left unrecorded. Blocked and unmeasured nights stay out of Dan's reason vocabulary AND have their members written to a per-launch exclusion record, which #16 reads separately and never counts as a dismissal (L192, L507).
- **A fact about the past is stamped when it becomes true.** `pitchedRunNights` is written at approve/send from the same value the handoff carried; the historical default is a bounded one-time backfill, not a rule re-evaluated forever against a rebuilt list (L318, L37).
- **A record about another record re-checks it at read.** `pitchedNights` intersects with `runNights`, with a fourth answer naming what fell out (L200, L11).
- **Every new value has a writer named in the same change.** `acceptedNightConflicts` is written by the same press that writes its pitch entry, in one operation (L46, L90, L109).
- **Every vocabulary has an exhaustive mapping and a completeness test.** The five per-night states map into `pitchNights` through one switch, and a sixth state added later fails the suite (L113).
- **Every fixture pins both ends of its date relationship**, and `scripts/check-fixtures-do-not-age.sh` is run, read and re-recorded in both Phase 1 and Phase 3 (L130).
- **Keep the good state.** No destructive step runs before its replacement is verified: the key re-read and the remap record happen after the save, and the pk 361 / pk 914 repairs run on a copy first.
- **Every guard seen to fail**, through `scripts/mutate.sh` with `--at` first and a literal aim, with the exact failure text quoted in the PR body and confirmation of the revert. A `SURVIVED` is read together with its needle report and its scope report.
- **Walk the app.** Phase 3.5 is a step, not an aspiration; its screenshots go in the PR body, checked for identities first.
- **Local `scripts/test-all.sh` before every push**, since CI does not run the Swift suite. Merge through `scripts/verify-and-merge-branch.sh` (or the batch script) so the branch is judged against current main.
- **Copy discipline**: regenerate `docs/copy-inventory.md`, `docs/outbound-copy.md` and `docs/copy-surfaces.md`, and cold-read all three diffs, reading each conditional in every branch including the empty one.
- **Every quoted number carries its date, its population and the query or function that produced it**, and every sibling list is derived by a command that goes in the PR body.


## Rival options and scores

### Clash First, Picker Filed (`clash-first`)
Ship only the half that is bleeding: make the self-booking check read every night on both sides of the comparison, and repair the natural-key corruption the per-night drop mechanism has already caused, before anything makes that mechanism common. No picker, no new stored field, no contract bump, no runbook or brand-voice edit. The bet is that the reported defect (Oct 29 invisible to the double-booking check while a pitch offering that night has already gone out) is a pure read-side fix over data the store already holds, and that the per-night decision screen is a separate feature that should not be blocked behind it. It also buys the panel's most alarming finding time to be settled: Z_PK 361 already carries a naturalKey dated to a night Dan dropped, one corruption in the nine rows that have ever used the drop path, and the picker would take that path to 84 live multi-night rows carrying up to 23 nights each.

Key choices: Phase 0 before anything else: ScoutService.apply must move naturalKey with performanceDate through the same three-answer keyAvailability read dropNight uses, refusing on taken or unreadable; add a live-store invariant test (no row's key date outside its runNights) with a printed corpus count and a real UNMEASURED state; repair Z_PK 361 dry-run on a store copy first.; SelfBookingConflict.Show carries nights plus a per-night times map sourced from the stored nightStartTimes, and results carry the colliding night, so gapMinutes can never lend one night's curtain to a different night.; Reuse ConflictScope for the copy rather than reinventing it: every SelfBookingCopy sentence says 'on this date' under a header that is the opening night, which becomes a claim the check never measured the moment nights expand. This is #1501 already solved on the calendar half.; Fallback asymmetry written down beside the code: empty runNights falls back to performanceDate alone on BOTH sides, never BlockedCalendar's span walk, which would manufacture clashes on the dark nights of a sixteen-Tuesday series.; Only in-progress pitches expand on the other side. Prospect.isBooked is a row flag naming no night, so a booked run still contributes its opening night alone and the Downbeat calendar half keeps ownership of booked work.; Index the queue by night once per render pass; selfBookingConflicts already filters all 1,023 rows per row rendered and night expansion multiplies that by up to 23.; Dedupe runNights at every read (17 rows hold duplicates, Z_PK 353 lists each of 10 dates twice) and file the upstream fold defect separately.; Correct the two stale premises in the same change: SelfBookingConflict.swift's own comment and issue #1986's body.; The eight decisions become a filed milestone with the panel's measured corrections attached (contract is at v13, String Theory is contacted and sent, keeps are inferred from absence), not code.

Cost: Free and the cheapest of the three. No new services, no new stored field, no SwiftData migration, no contract version, no runbook edit, so no token-spending eval run and no copy-inventory cold read beyond the reworded clash sentences.

### Drops Only, Picker Now (`drops-only`)
Build the picker exactly as the eight decisions read, on the storage that already exists. A kept night is derived (in runNights, not in droppedRunNights) and is never stored; the only new field is a per-night acceptance list, because an overt Keep of a blocked night has nowhere else to live and four live runs already carry two or more blocked nights, which one conflictClearedKey provably cannot represent. The picker is an inline disclosure section per run inside the existing Prep selection sheet, staged in view state and committed once on the Prep press. The bet is that Dan's decision 1 is right as literally written and that recording keeps is over-engineering he can live without: the picker simply re-opens on the next prep for a run whose nights he already judged.

Key choices: One new stored field only: acceptedNightConflicts, defaulting to empty, entries shaped 'night|deciding-day-key' on the DroppedNight self-describing precedent, so a clash that changes under him re-blocks that night rather than staying silently accepted.; Kept nights are derived through one accessor read by the picker, the gate, the handoff payload, the self-booking check and the draft lint. No parallel chosen-nights array.; The picker is a DisclosureGroup section per multi-night run inside PrepSelectionSheet, not a sheet over a sheet, so two runs in one batch prep is unrepresentable rather than handled. Cancel writes nothing.; A single atomic dropNights that settles every key-availability lookup before the first write, with the existing dropNight expressed in terms of it. A loop of single drops mints transient natural keys, can half-apply on cannotCheck, and files 22 undo entries for one press.; Ordering at launch is fixed and enforced: commit and save the night decisions, re-read every prospect's current naturalKey, then compute self-booking clashes over kept nights, then build the queue. A failed save aborts the launch rather than launching over the pre-picker state.; Decision 6 is implemented by narrowing conflictOpen's WRITER to 'every kept night is blocked', not by deleting the flag. That keeps Recipient.isSendablePending (the only hold on sending an approved draft after Downbeat books the night) and keeps the prepBlocked pill the exact complement it is documented to be.; Contract goes v13 to v14, not v7 to v8. The kept-nights field is absent or non-empty, never an empty array, and the runbook states what absent means. src/lib/prepQueueSpec.ts forces the runbook to move with it.; The runbook edit is three files: docs/prep-runbook.md plus both untracked brand-voice skill files, which state the span rule twice and always win, plus a new RUNBOOK_RULES entry pinning the instruction, since nothing guards that paragraph today.; Backfill is explicitly nothing, stated in the PR body: no drops recorded means every recorded night kept, which makes all 20 contacted rows correct by construction and touches no already-sent pitch.; Accepted limitation, named rather than discovered: a Keep leaves no trace, so the picker re-asks every prep and a night the feed adds later is silently kept and marked spoken-for though nobody judged it.

Cost: Free in dollars. Real costs are time: one token-spending scripts/eval-prep-runbook.sh run (never run on this Mac, so a first run rather than a re-run) plus two new prep-eval run fixtures, one lightweight SwiftData migration, and a cold read of three regenerated copy documents across every branch the picker can render.

### Night Decisions of Record (`night-decisions`)
Make the judgement itself the stored thing. The existing droppedRunNights column becomes a night-decision list carrying a verdict (kept or dismissed with its reason) alongside the reason and stamp it already holds, so unjudged becomes a real third state instead of the absence the whole feature exists to make visible. That single change fixes what neither of the other options can: a night the feed adds after the picker ran is unjudged rather than silently kept, a run Dan has decided stops re-asking on every prep, and Overture can honestly say which nights it claimed when a feed later drops one. On top of it goes the atomicity, the ordering, the narrowed gate and the contract bump, plus the two guards that make the runbook instruction real rather than hoped for. The bet is that this feature is the moment Overture starts asserting to strangers which nights Dan wants, so the assertion needs a record, a detector, and a deterministic hold on the outbound draft.

Key choices: Extend droppedRunNights in place into a night-decision list ('night|verdict|reason|epoch'), keeping the self-describing shape and its tolerant parse. No second column, no parallel list.; Kept is NOT a ShowOutcome case. That enum is terminal by construction and every reader treats a value as the show being over, so the keep verdict lives outside it.; Unjudged drives the interaction: the picker offers only nights nobody has answered, a feed-added night arrives unjudged, and DroppedNight.keeping subtracts only the dismissed ones so the scout fold is unchanged.; A per-night vanished-from-feed signal for a night Dan kept and already pitched. Today runNights just shrinks and disappearedFromFeed is row-level, which was harmless only while Overture claimed nothing.; Decision 8 is tiered rather than absolute: a booked night marks a date hard, a merely drafted or sent night on a later run night notes rather than warns. Measured, drafting one 20-night run otherwise takes live rows facing a warning from 1 to 174 of 614, median 33 across all 84 live multi-night runs, which is how a warning gets clicked through.; EventDateInDraft's acceptable set moves from a span walk to the kept nights, and a body naming a dismissed night HOLDS the send, in the class of the missing-subject hold rather than the advisory class. A rule enforced only in the prompt is not enforced.; Everything structural from the middle option: atomic dropNights, commit then re-read keys then check clashes then build, conflictOpen narrowed rather than deleted, contract v14 with absent-never-empty, runbook plus both untracked skill files plus a RUNBOOK_RULES guard, prep-eval fixtures covering both directions (named nights present and span wording absent, and a whole run still reading as a run).; Phase 0 identical to the cheap option: the ScoutService re-key fix, the live-store invariant test with an UNMEASURED state, and the Z_PK 361 repair, because this option puts the most traffic through that path.; The backfill rule for the 20 contacted rows is written down as a rule (all recorded nights, minus drops) rather than migrated onto rows whose emails have already gone out.

Cost: Free in dollars, and the largest time cost of the three. Same token-spending eval run and copy-document cold read as the middle option, plus a stored-shape change to a column that already has nine live rows written in the old form, a per-night feed-loss detector, and the draft-lint hold, each needing its own guard seen to fail.

**night-decisions: 8.4** C1 Correctness/honesty (30): 8. The only option that makes 'unjudged' a real third state, which is exactly the criterion's 'keep unmeasured distinct from clean'. I verified its safety argument holds in the code: DroppedNight.init?(stored:) guards parts.count == 3 and its own comment says an unreadable drop returns the night, the safe direction, so a four-field entry met by an older build restores rather than misreads. It does not fabricate nights for the empty-runNights rows (falls back and says so), keeps Kept out of ShowOutcome (correct: that enum is terminal by construction and RunNightDropTests.everyMenuReasonIsClassified would demand a scope), tiers decision 8 against a measured distribution rather than shipping a warning that fires on a median of 33 of 614 rows (L36, L172), replaces a prompt-only rule with a deterministic EventDateInDraft hold (L27), and carries the same Phase 0 as the cheap option. I confirmed that Phase 0 defect is real and not theoretical: ScoutService.swift:1619 and :1623 assign existing.performanceDate and never re-key existing.naturalKey (L15, L145). Docked 2 for the gap its red team names, which I verified: conflictKey/conflictClearedKey/conflictOpen are one column each with three writers and hasUnclearedConflict reading one boolean, so decisions 5 and 6 need a per-night home for 'blocked night waived' that this option's key choices do not name (it says 'everything structural from the middle option', which is not the same as naming it). Also docked for the per-night vanished-from-feed detector and the lint hold being the thinnest-supported new machinery here, though it owns both risks explicitly.
C2 Consolidation (25): 8.5. Extends droppedRunNights in place rather than adding a second list beside an array the scout rebuilds every run, which is the drift shape L15/L41 and the repo's own consolidate-from-the-start rule both point at. One derived notion of 'nights in play' read by the picker, the gate, the handoff, the self-booking check, the blocked-calendar walk and the draft lint. It is also the only option that surfaces the live contradiction between ProspectFieldClassificationTests classifying droppedRunNights as notARecord and Prospect.swift's own comment saying it must be stored, which matters because a duplicate merge deletes what only the loser knew.
C3 Fidelity to the eight decisions (20): 9. Implements all eight and does the thing the criterion explicitly rewards: names decision 8's tiering and the draft-lint hold as escalations rather than absorbing them into the design.
C4 Nightly loop (15): 8.5. Best of the two picker options. Only unjudged nights are offered, so a run Dan has decided stops re-asking on every prep; single-night shows see nothing; a 23-night run is judged once. The tier keeps the warning from firing on the dense middle, which is what actually protects the loop.
C5 Cost (10): 8. Free, no new services, no recurring spend. Same single token-spending eval run as the middle option (both edit the runbook), so it is not more expensive to run, only more expensive to build, and build effort is explicitly not a criterion.

**clash-first: 7.1** C1 Correctness/honesty (30): 7. Everything it does, it does right, and its grounding checked out under my own reads: the stale comment is still in SelfBookingConflict.swift, the ScoutService re-key omission is real at lines 1619/1623, and BlockedCalendar's empty-nights span-walk fallback is exactly as described, which makes its 'do not copy that fallback here' call correct and non-obvious (15 live rows have a span and no nights, and a sixteen-Tuesday series would manufacture clashes on dark nights). Per-night times so gapMinutes cannot lend one night's curtain to another is the sharpest single catch in the whole panel. But criterion 1 is about what gets STORED saying what happened, and this option stores nothing new at all: after it ships, Overture still cannot say which nights it claimed. Its own red team lands a real inverse defect too, citing L36: enforcing every stored runNight as a commitment before any surface exists to correct which nights a pitch actually named flips a false negative into a possible false positive as the other 84 multi-night rows age into commitment status.
C2 Consolidation (25): 8.5. Highest of the three on pure mechanism count. Reuses ConflictScope rather than reinventing it (L263), adds no field, no migration, no second list, and prices the render-pass cost nobody else did.
C3 Fidelity (20): 4. Implements none of the eight. It escalates them honestly as a filed milestone with corrections attached rather than reversing or absorbing any, which is the right way to fall short, but falling short of the central ask is still the largest fidelity gap here.
C4 Nightly loop (15): 7. No picker means no clicks, but also no benefit: the 22 unjudged nights of a 23-night run keep going to strangers. Noise cost measured and bounded today (20 marked nights to 21).
C5 Cost (10): 10. Cheapest. No contract bump, no runbook edit, so no eval run and no copy-document cold read.
Its red team's primary objection is the most operationally important finding in the whole panel and I am carrying it into the winner rather than against this option: String Theory is contacted with sentAt today, so the exposure is live and six new rows share 2026-10-29 with nothing warning.

**drops-only: 7** C1 Correctness/honesty (30): 5.5. Strong on structure and I confirmed its two best factual catches: PrepQueue.swift:234 really is version 13, so v13 to v14 is right where the brief said v7 to v8, and RunNightDrop's restoreNights is already plural for exactly the reason its dropNights argument gives. The ordering hazard it names is real and would bite silently, since dropping an opening night moves naturalKey and the sheet's selection is a Set of those keys. But its own stated accepted limitation is precisely what criterion 1 is scored on: a Keep leaves no trace, so a night the feed adds after the picker ran is silently kept and marked spoken-for though nobody judged it, and Overture then asserts a night to a stranger that nobody ever decided about. That is the defect the feature exists to remove, shipped as a design property. It also omits Phase 0 while being the option that takes the drop path from nine rows to routine traffic, which repeats a recorded mistake class (L15, L145) and does nothing to prevent it, and the writer that produced the one corrupt row is verifiably still open in ScoutService. Its red team's first objection stands on code I checked: BlockedCalendar is only ever built from the scout's own data, and conflictKey is one column, so decision 5's 'name the clashing shoot for each blocked night' has no stored fact behind it for the second blocked night.
C2 Consolidation (25): 8. Derived kept nights through one accessor read by five consumers, no parallel array, dropNight expressed in terms of an atomic dropNights, one new field forced by a type signature rather than chosen. Docked because half the deliverable, the night-list versus night-list comparison, appears in none of its nine key choices, so the SelfBookingConflict.Show reshape and its copy layer are unenumerated work.
C3 Fidelity (20): 8. Implements all eight as literally written and reverses none. Docked because decision 5 is not implementable on the storage it proposes.
C4 Nightly loop (15): 6.5. The picker's placement as a DisclosureGroup inside the existing PrepSelectionSheet is the best UI call in the panel and makes two runs in one batch unrepresentable rather than handled. But re-asking every prep for every multi-night run, forever, is a permanent tax on the loop Dan runs one or two times a night.
C5 Cost (10): 8. Free, one eval run, one migration, one cold read.


### Why the winner won
Night Decisions of Record wins on the two heaviest criteria at once, and it survives its red team.

Criterion 1 is 30 points of "does what gets stored say what actually happened", and only this option answers it. The other two both leave absence meaning two different things: Dan kept the night, or nobody ever looked. Drops Only says so out loud as an accepted limitation, which is honest but is still shipping the exact ambiguity the feature was commissioned to remove; Clash First stores nothing at all. Making the judgement itself the stored thing is what lets a feed-added night arrive unjudged rather than silently kept, lets a decided run stop re-asking, and lets Overture say which nights it claimed. That is L11 and L98 applied where they matter most, on the one surface that asserts to a stranger under Dan's name.

It is also the option that reuses rather than parallels. Extending droppedRunNights in place inherits DroppedNight's tolerant parse (I verified the parser refuses a four-field entry and returns the night, which is the safe direction) and inherits the scout re-fold subtraction for free. A second column would have been a list to keep in step with an array the feed rebuilds every run, which is the exact drift L15 and L41 record and the repo's own consolidate-from-the-start rule forbids.

On fidelity it implements all eight decisions and does the thing criterion 3 asks for explicitly: it names its two extensions (the tiered decision 8, the deterministic draft hold) as escalations rather than absorbing them. And on the nightly loop it is faster than its picker rival, because only unjudged nights are offered and the tier keeps the new warning out of the dense middle where a median of 33 of 614 rows would face one.

Cost does not force the cheap option. All three are free; the winner adds no recurring spend over Drops Only, since both edit the runbook and therefore both pay the same single eval run. The difference between them is build effort, which Dan's standing rule says is not a criterion.

The red-team objection I weighted heaviest, and verified myself, does not kill it: conflictKey, conflictClearedKey and conflictOpen are one column each with three writers and six gate call sites reading one boolean, so decisions 5 and 6 need a named per-night home for "this blocked night was waived". That gap is real, it is the same class as the defect that started this work, and it applies to Drops Only too (which at least names acceptedNightConflicts). It is a scope item to add before building, not a reason to prefer a weaker option, so I am grafting the middle option's acceptedNightConflicts field in as the answer and requiring the PR body's sibling enumeration to cover the conflict columns.

Two things from Clash First's red team change the sequencing rather than the choice, and both must be honoured. First, String Theory is contacted with sentAt stamped today, not drafted: the pitch naming both nights has gone, and six new rows share 2026-10-29 with no warning firing. So the clash fix plus Phase 0 ships as phase 1, ahead of the picker, and Dan gets told the same day not to keep anything on 2026-10-29 until it lands. Second, the premise went stale at #1523, not #1174, and #1523 is the PR that built runNights and made BlockedCalendar run-aware while leaving its sibling untouched; the PR body must say that, because AGENTS.md's rule 3 is the mechanism that should have caught it.

### Runner up ideas grafted in
1. Ship Clash First's phase 1 FIRST inside the winner, and treat it as time-critical rather than as backlog: Z_PK 433 String Theory is `contacted` with sentAt stamped 2026-08-30, so the two-night promise is already out and six `new` rows share 2026-10-29 with no warning. Give Dan a same-day heads-up (do not keep anything on 2026-10-29 until the fix lands) rather than letting the repair wait behind the picker.
2. Carry a per-night times MAP, not the card's startTimes, and return the colliding NIGHT in the result. This is the one place night expansion can produce a wrong reassurance instead of a wrong warning: without it a Saturday matinee's eight-hour gap can quiet a Tuesday clash through workableGapMinutes.
3. Write the fallback asymmetry down beside the code: empty runNights falls back to performanceDate ALONE on both sides of the self-booking check, never to BlockedCalendar's span walk. I confirmed BlockedCalendar.conflict falls back to EasternDate.days(from:through:) on empty nights; copying that here would manufacture clashes on the dark nights of a sixteen-Tuesday series across the 15 to 25 live rows that have a span and no nights.
4. Reuse ConflictScope for the clash copy rather than reinventing it (#1501 already solved this on the calendar half). Every SelfBookingCopy sentence says 'on this date' under a header keyed to the opening night, which becomes a claim the check never measured the instant nights expand (L263).
5. Booked runs contribute their OPENING NIGHT only. Prospect.isBooked is a row flag naming no night, so expanding a booked run across its span would assert Dan is shooting nights nothing recorded; the Downbeat calendar half keeps ownership of booked work.
6. Dedupe runNights at every read (17 live rows hold duplicates; Z_PK 353 lists each of 10 dates twice, Z_PK 300 has 3 duplicated of 13) and file the upstream fold defect separately. Without it the picker renders a night twice and the comparison multiplies.
7. Index the queue by night once per render pass. selfBookingConflicts already maps all 1,023 rows per row rendered; multiplying that by up to 23 nights without an index turns a fix into a regression.
8. Adopt Drops Only's acceptedNightConflicts field as the named home for a per-night 'blocked but kept anyway' waiver, shaped `night|deciding-day-key` on the DroppedNight precedent so a clash that changes under Dan re-blocks that night. This closes the winner's one real gap: conflictClearedKey is a single String? and BlockedCalendar.conflict returns one Day?, so the existing vocabulary structurally cannot say 'I accept Sep 4 but not Oct 29' for the four live runs with two or more blocked nights.
9. Put the picker inside PrepSelectionSheet as a DisclosureGroup per run, not a sheet over a sheet. The sheet already stages a Set of keys in view state, already takes allItems for clash detection, already has a confirm-then-commit gate, and already writes nothing on Cancel. This makes 'two runs in one batch prep' unrepresentable rather than handled.
10. Take the atomic dropNights and the launch ordering discipline verbatim: settle every key-availability lookup before the first write (a loop of single drops mints transient keys, can half-apply on cannotCheck, and files 22 undo entries for one press), then commit and save, then re-read every naturalKey, then compute clashes, then build the queue, with a failed save aborting the launch. Note restoreNights is ALREADY plural for exactly this reason, so the drop side is the asymmetry.
11. Narrow conflictOpen's WRITER to 'every kept night is blocked' rather than deleting the flag. It is stored because the rule overran the #Predicate type-checker inline, needsPrepPredicate reads that one column, StageNavigation documents .prepBlocked as the exact complement of .prep (L45), and Recipient.isSendablePending is the only remaining hold on sending an approved draft after Downbeat books the night.
12. Treat the runbook edit as THREE files, two of them untracked and authoritative: docs/prep-runbook.md plus ~/.claude/skills/dan-wright-brand-voice/SKILL.md and references/email-and-alt-text.md, which state the span rule twice and always win. Add a RUNBOOK_RULES entry so the paragraph is guarded, since prepRunbookRules.test.ts already runs a per-rule removal loop and gives the L1 proof for one array entry.
13. State the backfill as a RULE in the PR body rather than a migration: no drops recorded means every recorded night kept, which makes all 20 contacted rows correct by construction and touches no already-sent pitch.
14. Correct the history in the PR body: the premise went stale at #1523 (which introduced runNights and made BlockedCalendar run-aware while leaving SelfBookingConflict alone), not at #1174. #1219's exact-date choice was correct given what existed then. That is the AGENTS.md rule-3 'class not instance' miss, and #1986's body plus SelfBookingConflict.swift's own comment both need correcting in the same change.

## Ideal versus doable
The ideal version would settle the firing-rate question before writing any code, rather than escalating it. The measured sweep (2026-08-30, whole store) says that promoting just five live multi-night runs to full-run commitments takes the number of non-dismissed rows carrying a self-booking marker from 17 to roughly 218, and promoting all 96 takes it to about 678 of 752. That is the warning saturating, and it follows from decisions 1 and 8 held jointly, not from anything in this implementation. The ideal plan would arrive with a measured cut line already agreed (a tier, a proximity rule, or a narrower definition of what a kept night marks) so decision 8 ships as a rule rather than an intention. It is deferred because which shows count as spoken-for is Dan's call and not an engineering one, and because the sweep is a ceiling drawn uniformly from a pool including 20-night runs, which is not how he pitches (one, maybe two shows a night). Phase 1.4 therefore commits to re-deriving the figures through the code's own predicates before Phase 1 merges, which is the earliest honest moment to put a cut line in front of him.

The ideal version would also close all four newly-derived runEndDate siblings (BookingMatch, FollowUp, OutreachFunnel, BulkDismiss) inside this work rather than answering two and filing two. A booking that matches a night Dan skipped and a nudge computed from a night he never pitched are both wrong in the direction that reaches a stranger, and both become reachable the moment pitched nights are a decided subset. They are split out because each has its own semantics (causal validity for a booking, business-day arithmetic for a nudge) and folding them into a PR that already changes a contract version, a gate column and the drafter's instructions would make the whole thing unreviewable. The plan's compromise is that each gets a stated answer in the PR body with an issue number, derived by a command rather than by memory.

Finally, the ideal version would move the whole per-night vocabulary into a single self-describing structure rather than two stored arrays plus a derived pair. That is refused deliberately, not deferred: L267's rollback argument means the affirmative record cannot share droppedRunNights' format while an older build that destroys unparseable entries is still installable.

## Decisions escalated to Dan

1. **Measured on the live store (2026-08-30): promoting just five live multi-night runs to full-run commitments takes the self-booking warning from 17 non-dismissed rows to roughly 218, and all 96 takes it to about 678 of 752. Decisions 1 (keep every night) and 8 (kept nights mark the date as spoken-for) produce that jointly. How should the warning be scoped so it stays a signal?**
   1. Keep decisions 1 and 8 as chosen and accept that most of the queue will carry a marker once a handful of runs are pitched. Simplest, honest, and the warning stops carrying information.
   1. Narrow what MARKS a night: only nights on a pitch already SENT (or approved) mark the date, not nights merely kept in the picker. Keeps decision 1 intact for the drafter and shrinks the commitment set to what has actually left the building.
   1. Tier the warning with a measured cut line derived in Phase 1.4 through the code's own predicates: a full warning on the card's own header night, a quieter note on a later night of a run, and no marker at all past some measured density.
   1. Keep decision 8 but exempt a run's own later nights from marking against OTHER runs, so a long run cannot blanket the calendar. Narrowest change, and it leaves the reported defect (pk 433's Oct 29) fixed.

2. **Decision 6 was chosen on a premise that has since been measured as empty: of the 13 multi-night rows carrying an open conflict, ten are blocked on a later night and every one is dismissed, and the single live one is blocked on its OPENING night. Keep already clears the flag on the way in, so the picker would not have been frozen out. Does decision 6 still stand on the corrected reasoning (Keep accepts the whole run's clash card-wide before anyone has looked at which night, and the picker is where that gets itemised)?**
   1. Yes, keep decision 6 on the corrected reasoning. Per-night decisions replace the card-wide freeze and a partly booked run becomes preppable.
   1. Keep the card-wide freeze for now and ship only the self-booking half (Phase 1) plus the picker, leaving prep eligibility exactly as it is. Smallest change to a protective gate.
   1. Keep decision 6 but hold the two-gate split (Phase 3.8) back to its own PR with its own sign-off, since it touches the send gate.

3. **In the picker, 'Skip every night' on a run reaches RunNightDrop's .wholeShow outcome, which dismisses the card. What should the control do?**
   1. Skipping the last remaining night IS a card dismissal, and the control says so first in a sentence naming the run and the reason it will record. One mechanism, consistent with decision 1.
   1. The last remaining night cannot be skipped from this control; the sheet says why and points at the card-level Dismiss. The picker never closes a card.
   1. Remove the bulk skip entirely and keep only 'Pitch every night', since a run Dan does not want is dismissed at the card, not night by night.

4. **If one run in a Prep launch cannot commit its night decisions (an unreadable row, a key another card already holds, an in-batch collision), what happens to the rest of the launch?**
   1. Launch every run that committed and report the ones that did not, each with its own distinct reason. A healthy run is never blocked by an unrelated one (this plan's default).
   1. All or nothing: any refusal cancels the whole launch. Simplest to reason about, and one unreadable row costs the whole press.

5. **The runbook edit means scripts/eval-prep-runbook.sh --yes should be run before shipping Phase 4. It spends a real AI run (time on the Max plan, not dollars) and check-prep-eval-freshness.sh will warn on every test-all.sh until it is.**
   1. Run the eval before Phase 4 ships, as the runbook's own rule asks.
   1. Ship Phase 4 and run the eval afterwards, accepting the freshness warning on every local run until then.
   1. Split the runbook edit into its own PR so the eval gates only that change.


## Open risks
1. The firing-rate sweep in Phase 1.4 was computed in Python beside the code, not through the app's own predicates, and L107 records this repo shipping a funnel counted that way that was off by fifteen against the shipped rule. The plan requires re-derivation through SelfBookingConflict.sameNight / conflicts / workable before Phase 1 merges, but until that is done, every figure in the table (9/21, 17/29, and the 5-to-96-run sweep) is a claim about a Python reimplementation of the rule, not about the rule.
2. runNights is decoded from a keyed-archive plist by a helper written for this measurement session. Rows whose blob did not decode were treated as having no nights, which reads identically to a genuinely empty runNights. Nothing measured how many rows fell into that branch, so the 125/96 population and the 22 empty-span rows could each be off by whatever that count is. The invariant test in Phase 2.7 must print its corpus and carry an UNMEASURED state for exactly this reason, and the same rule should be applied to any store measurement quoted afterwards.
3. acceptedNightConflicts re-blocks a night when its deciding day changes, mirroring #718's conflictClearedKey rule at card level. That rule has never been observed working on live data: conflictClearedKey is nil on all 1,141 rows, and setScoutConflict(nil) nils it whenever a clash goes away, so a present-tense zero is consistent with the mechanism having worked many times or never. The per-night version inherits an untested parent.
4. Phase 3.7's writer pairs the pitch entry and the waiver entry in one operation, which closes the dead-control failure. It does not close the reverse: a waiver whose deciding day is later removed from the Downbeat export (a cancelled shoot, a replaced export) leaves an acceptedNightConflicts entry standing over a day that no longer exists. Phase 2.4's intersection rule covers pitchedRunNights against runNights but nothing states the equivalent for acceptedNightConflicts against the blocked calendar.
5. The per-launch exclusion record added for L507 is a new store whose only reader today is #16, which does not exist yet. It is the shape AGENTS.md's second PR enumeration exists to catch (a field written and never read looks alive to any is-this-used check). The plan names #16 as its reader, which is a promise about future work rather than a shipped consumer, and that should be stated as such in the PR body rather than presented as coverage.
6. The two-gate split in Phase 3.8 leaves prep eligibility and send eligibility as two stored values that must be written together in ConflictSweep / setScoutConflict / clearConflict / restoreConflictClearance. Four writers, two values, and the parity test named (PrepQueueEligibilityParityTests) pins the plain-Swift function against the #Predicate, not the two values against each other. A writer that updates one and forgets the other is not covered by anything the plan names.
7. Phase 3.6's per-run failure boundary means a Prep launch can now partially succeed. Nothing in the plan says what the queue file and the prep runner do when some runs launched and others did not, or how a re-press distinguishes a run that was never attempted from one that refused. L47 is quoted for the recording obligation but no mechanism is named.
8. pk 433's pitch has already gone naming both nights. Phase 2.5's one-time backfill stamps its recorded nights as pitched, which is correct today. If the venue's feed adds a night to that run before the backfill runs, the backfill stamps a night the email never named, and after that the stamp is authoritative and unrecoverable. The backfill should be run from a snapshot taken at the same moment it is applied, which the plan implies through the dry-run-on-a-copy step but does not state.

## Reality check: claims still broken
1. QueueItem DOES NOT CARRY runNights OR droppedRunNights, and Phase 1 cannot be written without adding both. The QueueItem struct (mac/Overture/UI/QueueView+Model.swift, fields around :230-250) carries runEndDate, performanceStartTimes, startTimesVary, nightStartTimes and conflictBlockedDate, but no night list; its builder at ~:2805 passes none. selfBookingShow reads only QueueItem, so `nights: [String]` has no source until runNights and droppedRunNights are plumbed onto QueueItem and its builder. The plan cites this exact file at four other line numbers and never names this, so Phase 1 is understated by a struct change plus a builder change plus whatever pins them.
2. RunNightDrop.Outcome has FIVE cases, not the three or four the plan enumerates: .wholeShow, .alreadyDropped, .moved, .fullyCovered, .cannotCheck. `.alreadyDropped` is given no answer anywhere in the plan, and it is precisely what the new batch caller hits when a night is re-skipped or when one night reaches dropNight twice in a press. Phase 2.3 says "the three outcomes are told apart by tests" and Phase 3.9 covers .cannotCheck; nothing covers .alreadyDropped, which by L11 needs its own message rather than folding into a neighbour.
3. droppedRunNights is on TEN rows, not nine, and FIVE are `new`, not four. Measured on my own clone today: 361, 386, 425, 435, 619, 914, 923, 999, 1010 and pk 1309 (new). Phase 2.6's reason string quotes the four-of-nine figure, so it would ship a wrong measurement into a test's own justification.
4. Status counts have moved: new 725, dismissed 396, contacted 20 (plan says 732 / 389 / 20). Total 1,141 and the zero-in-queued/drafted/approved claim both still hold, but the plan's own rule ("re-measure every number on the day it is written") is already violated by the plan itself within one day, which is evidence for how tight that rule has to be.
5. Both histograms are off by one row in two buckets. All 125: 2:61 and 3:11 (plan says 2:60, 3:12). Live 96: 2:46 and 3:7 (plan says 2:45, 3:8). Every other bucket matches, the 23-night live maximum holds, and the no-live-22 claim holds.
6. EasternDate.runLastNight has 13 grep hits across 10 files (11 real call sites, 2 comments), not the 9 call sites the plan states. The derivation command is right; the pre-computed answer beside it is not.
7. grep -rl 'naturalKey|showKey' mac/Overture --include='*.swift' returns 53 files, not 54.
8. StageNavigation's .prepBlocked case body is at :238, not :243.
9. Several minor line drifts: PrepQueue.needsPrep starts at :267 (plan says :270-278, though its :275 anchor is exact); openingNightPassed is computed by PrepQueue.swift:246 and called at PrepQueueService.swift:95 (plan says :97); CappedScrollView is at PrepSelectionSheet.swift:52 (plan says :53); the ScoutService dropped-night branch spans :1619-1623 (plan says :1618-1620 and :1622-1624).

## Lessons audit: violations still standing

### 1. L26 / L263 / L96
**Where:** Phase 4.3 changes only `mac/Overture/Domain/EventDateInDraft.swift`. Phase 1.9's derived sibling enumeration is two commands both scoped `mac/Overture --include='*.swift'`. Phase 4.1's v14 artifact list names `src/lib/prepQueueSpec.test.ts` and nothing else in `src/`. Phase 4.4 then relies on `scripts/eval-prep-runbook.sh` to bless the runbook edit.

**Why:** `src/lib/draftEventDate.ts` is the DECLARED TypeScript twin of `EventDateInDraft`. Its own header says so: "The TypeScript twin of `EventDateInDraft` (#2864)... the Swift one is what Dan meets on the draft review screen, and this one scores what a Prep run PRODUCED, so a runbook edit that weakens the rule is caught by `scripts/eval-prep-runbook.sh`... both are tested against ONE committed corpus, `fixtures/draft-event-date/cases.json` (L26)". Its `nights()` is the same span walk the plan is removing (`for (cursor = start; cursor <= end && out.length < 366; ...)`), and `src/lib/prepEval.ts:696` feeds it `runEndDate` straight from the fixture input. So after Phase 4 the Swift half judges by pitched nights and the TypeScript half judges by the span: L263 exactly, two same-purpose implementations either side of a boundary, each internally consistent, diverging indefinitely. Worse, the eval Phase 4.4 runs to prove the runbook edit is the half still measuring the old rule, so it would score a draft naming a skipped interior night as `ok` and report the change as safe. The sibling enumeration cannot see any of this because its grep is scoped to Swift, which is L96's shape (a derivation correct on its own terms whose subject list omits the population that matters). `src/lib/fixtureShape.ts:159` also encodes per-version field presence (`items[i].runEndDate must not be present before version 4`) and is unnamed by the v14 artifact list.

**Fix:** Add `src/lib/` to Phase 1.9's derivation (`grep -rn 'runEndDate' src/lib`, 5 files on 2026-08-30) and put that command in the PR body beside the Swift ones. Change `draftEventDate.ts` in the SAME change as `EventDateInDraft.swift`, extend the shared corpus `fixtures/draft-event-date/cases.json` with a pitched-nights column both sides consume (L26's own remedy, already used here), thread `pitchNights` through `prepEval.ts` and the eval fixtures, and add the v14 presence rule to `src/lib/fixtureShape.ts`. Prove the twins agree by mutating one side's acceptable-set rule and seeing the shared-corpus test go red on the other.

### 2. L204
**Where:** Phase 2.9: "`RunNightDrop.swift:182-186` asserts that 'the night being dropped is always the run's first remaining night...'. That stops being true here. Correct it in the same change and use it as a `mutate.sh` target", followed by `scripts/find-tests-naming.sh dropNight droppedRunNights isAboutOneNight` to hunt TESTS.

**Why:** L204 says find every reliance by searching for the INVARIANT itself rather than by reasoning about the feature, and warns that the reliance is usually recorded only in a comment that reads as reassurance while the code it justifies becomes actively destructive the moment the invariant goes. The plan corrects the comment and sweeps the tests, and never enumerates the CODE that comment justifies. Read against the source, `dropNight` (RunNightDrop.swift:229-271) is built on it end to end: it walks `remaining.sorted()` from the FIRST night, appends every `.taken` candidate to `released` as a `.duplicate` drop, and then unconditionally executes `performanceDate = opening`, `runEndDate = kept.max()` and `naturalKey = Prospect.makeNaturalKey(...)`. Drop a MIDDLE night and that walk still starts at the run's own opening night; `keyAvailability` returns `.free` only while `holder === self`, and this repo has already measured duplicate-keyed rows (#3278 minted ten; the plan's own facts name pk 361 and pk 914 whose `naturalKey` disagrees with `performanceDate`). Where a duplicate holds the opening key, asking to skip night 5 silently records night 1 as a `.duplicate` drop and re-keys the card, relocating it to another date header. Nothing in the plan re-audits that path, and the phase that introduces middle-night drops is the first change that can trigger it.

**Fix:** Before writing the picker, grep the invariant itself (`grep -rn 'first remaining night\|opening night IS\|remaining.sorted' mac/Overture`) and add the result to the PR body's sibling enumeration. Make `dropNight` branch explicitly: a night that is NOT the current `performanceDate` runs no forward walk, releases nothing, and leaves `performanceDate` and `naturalKey` untouched; only an opening-night drop reaches the existing walk. Test both, and mutate the middle-night branch into the walk to see the guard go red.

### 3. L14
**Where:** Phase 3.8: "`conflictOpen` keeps its current meaning for the SEND path: any pitched night is blocked and unwaived... A separate stored value governs PREP eligibility... Both are written in one place (`ConflictSweep` / `setScoutConflict` / `clearConflict` / `restoreConflictClearance`)."

**Why:** Both values are now DERIVED from `pitchedRunNights` and `acceptedNightConflicts`, and the picker is what writes those, yet the picker appears in neither writer list. `Prospect.swift:706` says the flag is written in exactly three places and `conflictOpen` is only ever assigned at `:1031`, `:1038` and `:1057`, all scout/conflict paths. So after a picker press the two stored flags describe the run's PREVIOUS night set until the next scout: skip the blocked night and `conflictOpen` stays true, leaving the row unpreppable and unsendable on a run with no blocked pitched night left; overtly pitch a blocked night and the prep value stays stale in the other direction. L14 is exactly this (derived state re-derives on every input that feeds it, and a correct save that still shows the old value reads as a failed save), and the failure lands on the send gate the plan itself identifies as the security-shaped control.

**Fix:** Name the picker's commit as a writer of both values in the same change: after each run's night decisions are saved, recompute the send value and the prep value from the new pitched set through the same single function `ConflictSweep` uses, inside the same critical section as the night write. Enumerate every input to both values in the PR body's writer enumeration. Test: skip the only blocked night of a run in the picker and assert both flags flip without a scout run; mutate the recompute out and see it go red.

### 4. L33 / L12
**Where:** Phase 2.5: "When a prep run's draft is approved or sent, write the nights that pitch actually named into `pitchedRunNights` on that row, from the same `pitchNights` value the handoff carried... so the fact is captured at the moment it becomes true."

**Why:** This pairs a durable store write with an irreversible external side effect (the Gmail send) and states no ordering, no durable intent record and no confirm-after step. L33 requires exactly that pair be made crash-safe, and CLAUDE.md's "Assume it runs twice" requires the same. The consequence here is not cosmetic: `pitchedRunNights` is what Phase 2.4 makes the commitment set, which is what marks nights spoken-for against every other show. If the mail leaves and the write does not land (a crash, a failed `save()`), Overture has told a stranger it wants nights it now has no record of, and the next show on those nights draws no self-booking warning at all, which is the precise defect this whole feature exists to fix. L12 adds the other half: success may only be shown after the write commits.

**Fix:** Record intent BEFORE the send: write the approved draft's `pitchNights` durably at APPROVE (which is already a decision point in the flow and is reversible), then confirm after the send rather than writing for the first time after it. Make the write idempotent on (row, night). Add a failure-path test, which the pre-push gate requires anyway: a send that succeeds while the following save throws must leave the nights recorded and must not report a clean send.

### 5. L161 / L192
**Where:** Phase 2.5 heading, "Stamp what a pitch actually named", writing `pitchedRunNights` "from the same `pitchNights` value the handoff carried, so the two cannot disagree".

**Why:** What is recorded is what Overture ASKED the drafter for, not what the pitch named, and the field is presented as the latter. L192 forbids presenting an inferred value as the recorded fact it stands in for; L161 says that where the system already holds the true value, check what the AI wrote AGAINST it rather than merely checking that something is there, and its own citation (overture#2864) is a SENT Overture pitch naming July 18 against a stored July 25. The system does hold the true value here: `EventDateInDraft.finding` already extracts every date the subject and body name, and the plan is editing that very function in Phase 4.3. "So the two cannot disagree" is also L70's shape, two sides of a check from one source. #16's funnel then reads a record of a promise nobody verified was made.

**Fix:** Either stamp from the dates the approved draft ACTUALLY names, using `EventDateInDraft`'s own extraction over the approved body, and record any night that was offered but never named as its own reportable state; or rename the field for what it holds (`nightsOfferedToDrafter`) and give the drafter-named set its own column. State which in the field's comment and in the PR body's reader enumeration. Guard, seen to fail: an approved draft naming two of three offered nights records two, not three.

### 6. L47 / L126 / L148
**Where:** Phase 3.6(c): "launch Prep for every run that committed, and report the ones that did not with their own distinct reasons... a run that did not commit is named with its own cause and its state is unchanged." No durable surface is named. The cross-cutting rules meanwhile claim "a re-press after a partial failure finds each run in a state that says what happened to it."

**Why:** Those two sentences contradict each other, and "state is unchanged" is the one that describes the code. L47: an item left with no trace is indistinguishable from one never attempted, so it is silently selected again and the partial result reports as a clean run. L126 and L148 cover where the reason lives: the conditions (a key another card holds, a store that could not be read) PERSIST in the data, while a Prep-launch summary is transient, so every encounter after the first finds the fault still there and the explanation gone. This repo has paid for both already: L126's citation is overture#2621, L148's is downbeat#210, and L109's is overture#2544, all the same shape on the surfaces Dan works from.

**Fix:** Record the attempt on each run that did not commit (the cause, the night or key it failed on, the timestamp) on the ROW, and render it on the durable surface that shows the run, not only in the launch summary. Make the picker show the previous refusal when it reopens on that run. Resolve the contradiction in the plan text. Test each of the four causes separately (store-taken key, in-batch reservation collision, `.cannotCheck`, failed save) and assert a re-press can tell a failed run from an untried one.

### 7. L46 / L65
**Where:** Phase 2.2: "record the members at the moment they are computed, in a store that is plainly not a decision of Dan's. A per-launch record naming the run's key, the nights excluded, and which deciding day excluded each"; and "#16's reporting counts only the `droppedRunNights` entries... The exclusion record is read separately."

**Why:** #16 is an unbuilt milestone, so as specified the record has a writer and no live reader. L46 is exactly this: a field only ever written looks alive to any is-this-used check while the purpose it was added for silently never happens. L65 adds the remedy for anything shipped deliberately dormant: the issue that activates it is filed in the same change, or the dormant state becomes invisible the moment the reason for it is forgotten. The plan's cross-cutting rules require "naming which surface reads the exclusion record" in the PR body but never name one, so the PR body enumeration would be answered by a promise. The record's location, format and retention are also unstated, which L8 (own your paths) and L9 (a retention policy is the user's product decision, never a silent default) both bear on for a per-launch append with no bound.

**Fix:** Name a live reader in the same change: the picker itself is the natural one, showing "2 nights are excluded because you are shooting <named day>", read back from the record rather than recomputed, which also exercises the write on every launch. If no live reader is wanted, file the activating issue and put its number in the field's own comment and the PR body, per L65. State the record's path, format and retention explicitly, and give it a bound.

### 8. CLAUDE.md "Assume it runs twice" / L186
**Where:** Phase 2.5 point 2: "The historical default is a ONE-TIME backfill, written once, for rows sent before this ships (20 rows today, one of them multi-night). It is written against a store copy first, then applied, then never re-evaluated."

**Why:** CLAUDE.md requires any multi-step write to be designed assuming it runs concurrently with itself, is retried, or crashes mid-way, using a database constraint, a lock or an idempotency key, and explicitly forbids relying on careful ordering in application code. "Never re-evaluated" is an intention held by whoever remembers, not a mechanism, and L186 says a durable record that stops an action repeating is only as durable as its key. The second run is the dangerous one, not the first: by then Phase 3 may have written real per-night decisions, and re-applying "every recorded night is pitched" over a row Dan has since decided about overwrites his own judgement with a default, silently, on rows already sent to strangers. The plan's own accessor comment is supposed to say which rows carry a stamp and which were backfilled, which is the information a guard could key on and does not.

**Fix:** Give the backfill a durable key it checks before writing: skip any row already carrying a `pitchedRunNights` entry, and stamp each backfilled entry with a marker distinguishing it from a real decision (the accessor's comment already promises to tell them apart, so make it a stored fact rather than prose). Add a failure-path test running the backfill twice over a store where Phase 3 has since written a real decision, asserting the second run changes nothing and reports how many rows it skipped.

### 9. L325 / L501
**Where:** Phase 2.7: "Add a store-wide invariant test keyed on rows carrying drops... printing its corpus count and carrying a real third UNMEASURED state on the `ReplyInvariantsLiveStoreTests` precedent, so a suite that measured nothing cannot read as a clean bill of health (L98, L11)."

**Why:** L325 was recorded from overture#3276 on 2026-08-30, the same day as this plan, and is about that exact test: `ReplyInvariantsLiveStoreTests` reports its corpus by PRINTING and the runner reads it out of xcodebuild's output, so under `-parallel-testing-enabled YES` the line appears zero times in 10,059 log lines, the suite passes, and the readout blames a scope the run did not have. The plan clones the pattern AS FIRST WRITTEN, which is L501 precisely: the correction already exists in the original's own history and the clone's note that it follows a proven precedent is what makes it read as safe. Since this repo is actively moving toward parallel testing (milestone 60, #3233, #3266), the new invariant's corpus count would be born blind on the run shape it is heading for, and the emptiest possible failure would again read as the cleanest possible pass.

**Fix:** Carry the corpus measurement on a channel the reader owns rather than on the test process's stdout: have the invariant write its counts to a file beside the repo (the `.overture-live-corpus-seen` precedent already in use) and have the runner read that, so a worker process whose stdout xcodebuild does not forward cannot silently delete the measurement. Prove it by running the new suite under `-parallel-testing-enabled YES` and confirming the count still reaches the readout.

## Dan's answers to the five escalated decisions (2026-08-30, in session, via picker)

1. **Warning scope.** Only nights on a pitch already SENT or APPROVED mark the date against other shows. A night merely kept in the picker still tells the drafter what to write. Decision 1 is untouched for the email; the commitment set shrinks to what has left the building. Recorded as scoped to a RUN'S NIGHTS only: a single-night show's existing commitment rule (`drafted` or `approved` with a draft) is NOT tightened by this, since nothing asked for that and it would be a silent behaviour change to an unrelated case.

2. **Decision 6 stands**, on the corrected reasoning rather than the original one. The original argument (the card-wide freeze would stop the picker ever opening) was measured as empty: Keep already clears the flag on the way in (#1583), and of the 13 multi-night rows carrying an open conflict, ten are blocked on a later night and every one is dismissed. The argument that survives is different: Keep accepts a run's whole clash card-wide before anybody has looked at which night, and the picker is where that acceptance gets itemised.

3. **Skip every night** is a card dismissal and says so before acting, in a sentence naming the run and the reason it will record. One mechanism, consistent with decision 1.

4. **A Prep launch partially succeeds.** Runs that committed launch; runs that did not are each named with their own distinct cause. The panel's own audit (L47, L126, L148) requires the cause be recorded ON THE ROW and shown on a durable surface, not only in the transient launch summary, so a re-press can tell a run that refused from one nobody attempted.

5. **The eval runs before the runbook edit ships**, as the runbook's own rule asks. Not split into a separate pull request.
