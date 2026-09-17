# Per-night decisions, phases 2 to 5

Replaces phases 2 to 5 of `PLAN-per-night-decisions-at-prep-launch-and-a-run-aware-self-booking-check.md`,
whose phase 1 is BUILT (#3323, extended by #3676), whose phase 3.8 splits a gate #3369 deleted, and whose
phase 2.7 repairs a corpus that a launch migration empties and the next scout refills (#3962). Read that
file's correction block for the full account. Tracking: #3957.

Planned with `/plan-lite` on 2026-09-17: a grilling, a draft, an independent red team, a lessons audit over
all ~690 recorded lessons, then this revision. **Both critics were run and both are answered below.**

Row identities are primary keys only. This repository is PUBLIC (L482, #3958).

## Verification status, read this first

- **Red team: 10 findings, 3 of them blocking. All 10 are answered in the design below**, not in an
  appendix. Where one is answered by accepting a limit rather than removing it, the limit is stated at the
  point it applies and carries a gating issue number.
- **Lessons audit: 16 findings, read against ~690 lessons. All 16 are answered below.**
- **No finding is carried into an "open risks" section.** That is L481, which was recorded this morning
  from this plan's own predecessor, whose nine violations each carried a written fix sitting in an
  appendix the implementer meets only after building from the phase text above it. The first draft of
  THIS plan repeated it. Every remaining limit is now stated where it bites, with its issue.

### Measurements and how to re-take them

Every figure below carries the command or the predicate that produced it, so it can be re-measured on the
day it is next written rather than trusted (L316). Two readings are quoted, hours apart on 2026-09-17, and
the store grew between them: a SQL reading over a WAL consistent copy at **1,257 prospects** (all
`ZRUNNIGHTS` and `ZDROPPEDRUNNIGHTS` blobs decoded, 0 failures, 0 nulls), and the predicate reading below at
**1,260**. Where they differ the predicate reading wins, and part of the difference is real drift rather
than method: this store moves by a few rows a day and by 11% in a day on some populations.

**RE-DERIVED 2026-09-17 by #3963.** Every figure below was re-taken through the shipped Swift predicates,
under `RealStoreTestLock` against a `LiveStoreClone` backup, because a figure taken in SQL beside the app is
not admissible for a design decision (L107). Corpus at that measurement: **1,260 prospects, 620 live**, a
few hours after the 1,257 reading. One design decision did not survive it, and section 2.5 is rewritten
below rather than annotated.

## The six answers Dan gave, plus the two collisions they produced

Answers, 2026-09-17 in session:

1. **Default is pitch every night, and the choice is RECORDED.**
2. **The email names the kept dates**, span only when they are contiguous AND more than three, and it may
   **never** name a night he skipped.
3. **A night the feed ADDS after a pitch marks the Reached Out row**, with a control to judge it there.
   The card never returns to triage.
4. **A night the feed DROPS after a pitch does not rewrite what was promised.** The promise is frozen; the
   row says it diverged.
5. **A blocked night is SHOWN unticked, naming the clash, and is still tickable.**
6. **The 48 already sent rows record nothing**, and say so.

The critics found answers 1 and 5 collide, and found that answer 2's "never" had been downgraded to a
notice. Both went back to Dan, same session:

7. **The picker OPENS when the run has a clash, and stays closed otherwise.** A clean run keeps the single
   press; a run with a blocked night cannot hide its warning behind a disclosure nobody opened
   (L610, L678).
8. **A draft naming a night he SKIPPED blocks the send.** The opposite direction, a kept night the draft
   did not name, is advisory. Answer 2 said "never", and the app has proof, so it refuses rather than
   labelling (L67, L27).
9. **Unticking a night is not a dismissal.** It gets its own quiet record and never enters Dan's four
   reason vocabulary or the #16 funnel.

## The population

Commands in `mac/`, measured 2026-09-17.

- 1,257 rows at the SQL reading: new 560, dismissed 640, contacted 48, drafted 9, queued 0, approved 0.
  1,260 rows, 620 live, hours later at the predicate reading.
- **126 multi-night rows, 78 live.** Live histogram (nights: rows): 2:31, 3:7, 4:7, 5:2, 6:4, 7:3, 8:4,
  9:2, 10:4, 11:1, 12:6, 13:1, 16:1, 18:1, 20:3, **28:1**. **45 of 78 are two to four nights**; the worst
  case is 28 and it is live.
- 22 rows carry a span with an EMPTY `runNights`, 9 live. **MEASURED across 29 dated snapshots back to
  2026-06-28: ZERO of them has ever gained nights**, and the one that ever held any lost them to drops.
  Twelve consecutive daily snapshots show the cohort frozen at 22 and 9. See 3.3: the sentence saying they
  pick their nights up on the next scout is FALSE and is deleted.
- **19 rows hold duplicate entries in `runNights`, 11 of them live** (through `QueueModel.selfBookingNights`,
  `QueueView+Model.swift:2665`). A control confirmed no divergence in either direction. The shape matters
  more than the count: one LIVE `new` row stores every night of a 20 night run twice.
- **310 rows carry `conflictOpen`, 74 multi-night, 48 blocked on a later night, 25 of those live** (through
  `Prospect.hasUnclearedConflict` and `ConflictScope.of`). The stored column is NOT stale:
  `ConflictSweep.reapplyAll` against a healthy Release export changed 0 of 1,260 rows.
- **16 of 89 live multi-night runs carry TWO OR MORE blocked nights**, one of them 12 blocked nights out of
  12. This is the figure that invalidated 2.5 as first written.
- 41 rows carry `droppedRunNights`, 16 still `new`. 48 rows carry `sentAt`, four multi-night.

---

## Phase 2: the record

### 2.1 Three lists, and why the untick gets its own

The red team's first blocking finding: `RunNightDrop.dropNight` (`RunNightDrop.swift:194-196`) takes a
**non-optional** `reason: ShowOutcome`, written verbatim into the stored entry (`:257`). The only values
are Dan's four (`aboutOneNight`, `:19-20`), the show-level set (`:35-36`), or `.duplicate`, the app's own
release marker. A tick box carries none. Routing the untick through it would either mint a new
`ShowOutcome` case, which lands in the funnel 2.4 spends a paragraph refusing, or fabricate one of Dan's
four, which is the #2691 defect this file exists to prevent.

Answer 9 settles it. **The picker does not call `dropNight`.** Two new stored properties on `Prospect`:

- `pitchedRunNights: [String]`, nights Dan is offering.
- `skippedRunNights: [String]`, nights Dan passed on, with no reason and no funnel membership.

`droppedRunNights` is **untouched** in name, format, meaning and writers. It stays the card-level
dismissal record, and `DroppedNight.keeping` stays its only fold rule.

**Skipping the LAST remaining night is still a card dismissal** (Dan, 2026-08-30), so it leaves the picker
entirely and goes through the existing card dismissal path, which does ask a reason. The picker says so
before acting, in a sentence naming the run and the reason it will record.

### 2.2 The entry format, parsed with a MINIMUM arity

Entries are `night|epoch|origin`. `origin` is `default` (the run was committed without the picker being
opened) or `chosen` (Dan opened it and this is what he left). Section 2.3 is why that third field exists.

**The parser requires AT LEAST three fields and ignores unknown trailing ones.** This is deliberate and it
is the correction to the pattern beside it: `DroppedNight.init?(stored:)` (`:99-107`) requires
**exactly** three and returns nil otherwise, which is why 2.1 of the superseded plan had to argue for a
whole new column rather than a fourth field. Cloning that as first written would force a fourth column the
first time this record needs another fact (L501, and L255, whose evidence in this repo is
`DownbeatBridge.supportedVersions` never getting `PrepResultsDecoder`'s version-range fix).

An entry that cannot be parsed at all is **dropped, and the night reads as unjudged**, which is the safe
direction: Dan is asked again rather than having a decision invented for him. `DroppedNight`'s own comment
reasons the same way about its own unreadable case and reaches the same answer. Ship the test that a
future-build entry carrying a fourth field round-trips rather than vanishing.

**The guard ships with the comment, not instead of it** (L407, whose evidence is overture#3558 in this
repo: three files said a stored property must never be dropped, and one was dropped with 8,960 tests
green). The comment says what an older build does; the test asserts the parser's tolerance; a scan asserts
nothing widens `droppedRunNights`'s arity.

An older build cannot see either new column and will treat every judged night as simply present. That is a
degradation, stated plainly in the property's comment and the PR body, not a rollback promise the code
cannot keep (L267).

### 2.3 What a tick MEANS, which is the finding both critics reached independently

Answer 1 says the point is telling "he looked and kept them all" from "nobody looked". A bare affirmative
entry cannot do that: with the picker closed, one keypress on a 28 night run writes 28 entries
indistinguishable from 28 read decisions, and Phase 5 then reads them back as evidence he judged each one.
The first draft filed this as a risk. It is a design decision and it belongs here (L548, L432, L636).

**The `origin` field carries it, in the decision itself rather than as a second piece of state beside it**
(L544). `default` and `chosen` are one discriminated value per night, not a boolean on the row, because a
run can be committed closed once and opened later, and only the nights present at each moment are covered.

Every consumer states which it accepts. The drafter takes both. The booking match and the follow-up nudge
in Phase 5 take both but say which they used. Anything asserting to Dan that he judged a night may use
`chosen` only.

### 2.4 One night, one state, asserted at the write

Four memberships, all independent: `runNights`, `pitchedRunNights`, `skippedRunNights`,
`droppedRunNights`. The red team found the first draft's "three exclusive states" both wrong and reachable:
an opening-night drop walks `remaining.sorted()` and writes other nights into `droppedRunNights` as
`.duplicate` (`RunNightDrop.swift:231-252`, `:258-260`), so a night can be pitched and dropped at once.
The first draft's stated derivation ("`runNights` minus the two lists") was also right only by accident,
because `dropNight` removes the night from `runNights` (`:263-267`) and the two are disjoint by
construction.

So the state space is written out, the illegal combinations are named, and **precedence is enforced at
WRITE time, not resolved at read time**:

| In `runNights` | pitched | skipped | dropped | State |
| --- | --- | --- | --- | --- |
| yes | no | no | no | **unjudged** |
| yes | yes | no | no | **pitched** |
| yes | no | yes | no | **skipped** |
| no | any | any | yes | **dropped**, and any pitch or skip entry is removed in the same write |
| no | yes or no | yes or no | no | **gone from the feed**, entries RETAINED as evidence (2.6) |
| yes | yes | yes | no | **illegal**, refused by the writer |

A test loops every combination over one night and asserts exactly one state, because a test checking one
bucket is satisfied by an item that fell out of all of them (L517).

### 2.5 Blocked nights: one predicate owns the question

Answer 5 and answer 7. A night blocked by the Downbeat calendar or a day off is shown unticked with the
clash named, and the disclosure OPENS when the run has one.

The red team found a second predicate already on this sheet: the confirm dialog reads
`QueueModel.calendarClashesForPrep` (`QueueView+Model.swift:2806-2815`), which filters on
`item.hasUnclearedConflict` and renders `item.conflictNote`, one `Day?` from `BlockedCalendar.conflict`
(`BlockedCalendar.swift:297`) gated by the card-level `conflictClearedKey`. A per-night derivation beside
it gives one sheet two answers to one question (L261, L342), and a card whose `conflictClearedKey` Dan
already set (live on two rows) would read cleared in the dialog and blocked in the picker.

**`conflictClearedKey` is consulted, not bypassed.** A night whose deciding day matches the cleared key is
shown as already waived rather than re-raised, because an acknowledgement Dan gives must be consulted by
every rule raising that question or it goes on asking after it has been answered (L330, whose evidence is
overture#3307 in this repo).

**CORRECTED 2026-09-17 by #3961 and #3963: the existing waiver CANNOT hold the answer, so a per-night
override record ships after all.** An earlier draft said ticking a blocked night clears the conflict
through the existing `conflictClearedKey` path and that no new column was needed. That is structurally
false. `Prospect.conflictKey` and `Prospect.conflictClearedKey` are each a single `String?`
(`Prospect.swift:761`, `:767`) and `BlockedCalendar.conflict` returns one `Day?`, so the card level
vocabulary cannot express "I accept the 12th but not the 14th".

Measured through the shipped predicates: **89 live multi-night runs, of which 16 carry TWO OR MORE blocked
nights** (ten with 2, two with 3, two with 4, one with 5, and one 12 night run with all 12 blocked). All 16
are `new`, all 16 are `conflictOpen`, and **not one has a `conflictClearedKey` set**, which is exactly why
the collision has never bitten and was invisible to the first draft. Waiving the second blocked night would
silently overwrite the record of waiving the first, and on one run it would overwrite eleven.

So `pitchedRunNights` entries carry the deciding day key when the night was blocked and ticked anyway, on
the `DroppedNight` precedent so a clash that CHANGES under Dan re-blocks that night (#718's pattern). This
is the old plan's `acceptedNightConflicts` in substance, and it is justified now for the reason it was not
then: it has a LIVE reader, the row explaining why a night with a shoot on it was pitched, exercised on
every render rather than waiting for a milestone that has shipped nothing (L46, L65). The card level
`conflictClearedKey` stays as it is, for the card level question.

**There is no shipped predicate for "which nights of this run are blocked", and this plan must add one.**
`conflict` returns one `Day?` and `decidingDay` is private (`:167`), so without a new member returning the
per-night SET the picker and the confirm dialog each invent their own loop and can disagree (L342, L261),
which is the exact failure the paragraph above exists to prevent. The set is built ONCE per open, outside
the sheet.

**The default is not stable across opens, and that is stated rather than hidden.** `BlockedCalendar`
filters `cancelledBookingIds` on every call (`:317-322`), so a booking cancelled overnight changes which
nights pre-tick. The `origin` field is what makes this legible: a `chosen` entry records what Dan actually
left, whatever the default was that day. Nothing durable records the blocked set at the moment of the
pitch, and that is a real gap: **#3961**, filed with this plan, because "why was this night unticked on
the 17th" is otherwise unanswerable on the 18th.

### 2.6 The scout rewrites `runNights`, so both new lists need a fold rule

The red team's fifth finding, and it is the one `DroppedNight.keeping` already exists to prevent on the
other column. `ScoutService.swift:1821` rewrites `runNights` wholesale every run.

**The rule: a pitch or skip entry is RETAINED when its night leaves `runNights`, and is honoured when the
night returns.** Retained because it is evidence of a decision Dan made and the row may already have been
pitched on it. Honoured on return because a night that goes away and comes back has been judged, so
re-asking would be the new-nights marker firing on an old decision.

This is the opposite choice from `droppedRunNights`, which is subtracted, and the difference is stated
where both live: a drop must survive the fold to stay dropped, and a pitch must survive the fold to stay
evidence. Tested against a re-fold, not only against a picker commit.

**The re-key in `ScoutService.swift:1713-1718` moves `performanceDate` in both branches.** A card whose
opening night becomes a night with no entry renders as unjudged on a run already decided. The fold rule
covers it because entries are keyed on the night, not on the row's opening.

### 2.7 The promise, and the extractor that actually exists

`Recipient.promisedNights`, written once when a send commits, never rewritten by any scout. Answer 4.

**The first draft cited the wrong function.** `EventDateInDraft.finding` (`EventDateInDraft.swift:44-68`)
returns `EventDateFinding?` and **returns nil on success** (`:65`): it is a warning, not an extraction.
The extractor is `namedDays(in:assumingYearOf:)` (`:98`).

`namedDays` expands a span into every day between the endpoints (`:120-125`). For a PROMISE that is
correct: an email saying "November 10 to 14" has promised all five. What it also does is resolve a bare
`M/D` (`:134-144`) and a bare ordinal after any month word (`:155-161`), stamped with the show's year
(`:99`), so an incidental date elsewhere in the body lands in the extraction.

**So the stored value is discriminated, never a bare array** (L544, L192). It carries the nights, the
source (`extracted` or `notRecorded`), and the extractor version. Three consequences the first draft's
bare `[String]` could not express: not stamped, stamped and found nothing, stamped by a build that could
not read the shape.

**Pinning the extractor version is the reason this is STORED rather than recomputed.** The red team is
right that `prospect.freezeSentCopy(subject:body:)` (`SendService.swift:129`) already freezes the sent
body, so a recomputation gives the same answer as long as the extractor does not change. The column earns
its place only because the extractor will change, and the stored version is what lets a later, better
extractor re-derive and **disagree** rather than silently overwrite (L345). Keeping the frozen body is
what makes that possible; nothing here deletes it.

### 2.8 The send-time check, and what it refuses

Answer 8, at the send sheet, before the send, computed from `namedDays` over the approved body against the
kept set:

- **A named night that is in `skippedRunNights` BLOCKS the send**, naming the date, and offers the two
  ways out: fix the draft, or add that night back to the kept set. Answer 2 said never, and a detection
  beside an enabled action is a label rather than a guard (L67).
- **A named date that is in no list at all** (an incidental date the extractor resolved) is advisory.
- **A kept night the draft did not name** is advisory: it understates the offer.

The divergence **persists on the row**, not only on the sheet, because the condition lives in the frozen
promise for ever while the sheet dies with the attempt (L126, L148, L269).

Answer 2's rule change also inverts `finding`'s predicate at `:65` from any-named-day-acceptable to
all-named-days-acceptable. That change ships with the runbook edit in 4.2, not separately, or the check
judges the old rule.

### 2.9 Crash safety, and a test that can actually pass

`SendService.deliver` (`SendService.swift:76-145`, with the rollback in the catch at `:138-145`) already
composes and refuses before any write, claims the recipient durably before the network await, writes the
receipt after, and confirms through `saveOrWarnSendNotConfirmed`. A crash between claim and outcome leaves
the row `.sending`, surfaced by `Recipient.isSendStuck` (`Recipient.swift:1224`).

`promisedNights` is written **inside that structure**, in the same write as the receipt fields.

**The first draft's failure test asserted an impossibility**: it asked that the promise be recorded when
the save that records it throws (L561, L159). The real assertions are: the row is left `.sending`,
`isSendStuck` surfaces it, no clean send is reported, and **the `.sending` recovery path is where
`promisedNights` comes from for those rows**, which is named here rather than left to the implementer.

### 2.10 No backfill, and a label that measures what it claims

Answer 6. No one-time backfill, which removes the idempotency hazard rather than solving it (L186).

**The label is keyed on `sentAt` earlier than this feature's ship date**, not on emptiness. An empty
`pitchedRunNights` on a sent row is also produced by a refused launch, a failed save, and a single-night
row, so emptiness cannot establish the cause it was being asked to assert (L223, L133, L11). "Sent after
this shipped with nothing recorded" gets its own sentence and its own consequence.

Beside the label, the dates the frozen sent body names are shown **read only**, sourced and labelled the
same way 2.7 discriminates them.

### 2.11 The guard, and the defect is LIVE

**CORRECTED 2026-09-17, later the same day, by #3962. An earlier draft of this section said the corpus was
clean and the repair redundant. That reading was true for about an hour.**

Re-verified directly against a copy of the live store: **1,260 rows, 19 of them carrying a `naturalKey`
whose embedded date disagrees with `performanceDate`**, and pk 361, one of the two the superseded plan
named, is among them. The "zero of 1,257" reading was taken between the 10:36 launch and the scout run that
followed it.

**It oscillates, because a repair and a writer are fighting.** The launch backups record it: 19 drifted in
three of the twelve snapshots and 0 in the rest, and a backup shows 19 exactly when a scout ran during the
previous session.

- **The repair** is `NaturalKeyVenueMigration.run`, called unconditionally every launch from
  `LaunchMigrations.swift:115`. It is not a date repair by intent: it groups by
  `Prospect.scoutAnchoredNaturalKey` (`Prospect.swift:1662`), which embeds `performanceDate`, and re-keys
  any singleton whose stored key differs (`NaturalKeyVenueMigration.swift:74-77`). The date half is
  corrected as a SIDE EFFECT of a pass written for the venue half, and nothing names or counts it.
- **The writer** is the `.reKey` arm of `ScoutService` (around `:1355-1360`), which stores a key computed
  at `:1318` from the FEED's opening night, after which `apply` overwrites `performanceDate` with the
  DROP FILTERED opening (`:1712-1719`). Pre-subtraction date into the key, post-subtraction date into the
  field, same call, in that order.

An earlier draft named `:1713-1719` as the cause. That is only the half that moves `performanceDate`; the
defect is the disagreement between the two writes, 350 lines apart.

**So the guard must NOT be a live store invariant.** A "zero drifted rows" assertion flips red or green on
whether a scout has run since the last launch, with nothing changed but the clock: green at 10:36 today,
red at 11:36 (L336, L182). It asserts the **signature at the writer** instead, that the key the `.reKey`
arm stores and the `performanceDate` that `apply` then assigns name the same night. That is a unit level
assertion, it fails today, and a launch cannot quieten it (L68).

Anything the guard does report over the live store goes through `LiveCorpusReport`
(`mac/OvertureTests/LiveCorpusReport.swift`), which #3276 shipped on 2026-08-31 and which survives a
parallel run, rather than cloning the print-to-stdout pattern as first written (L501, L325).

**And this is written down because removing it is easy to do by accident:** the repair only works because
an unrelated venue migration happens to re-key on a property that embeds the date. Whoever narrows
`NaturalKeyVenueMigration` to the venue half deletes the repair without knowing it existed, and the
oscillation stops at the drifted end.

One row is permanently clean and is not evidence against any of this: pk 914's only dropped night and its
own `performanceDate` are both past, the show has left the feed, and nothing will re-key it again. The two
rows the superseded plan named are the live case and the retired one, not two instances of one story.

---

## Phase 3: the picker

### 3.1 Where it lives, what it costs, and when it opens

A `DisclosureGroup` per run inside `PrepSelectionSheet`, which already stages keys in view state, already
takes all items for clash detection, already has a confirm-then-commit gate and already writes nothing on
Cancel.

**It opens when the run has a blocked night, and stays closed otherwise** (answer 7). Closed and committed
writes `origin: default` for every night; opened writes `chosen`.

**The night rows are built inside the disclosure's own closure.** `PrepSelectionSheet.swift:70-75` is a
plain `VStack` with `ForEach(rows)` inside `CappedScrollView`, not a lazy container, so nights built
outside the closure are constructed for every run in the sheet whether or not anything is open.

### 3.2 The sheet is keyed on `naturalKey`, and this phase changes it

`PrepSelectionSheet.Row.id` IS the prospect's `naturalKey` (`:24`, `:50`), `selected` is a `Set<String>` of
those keys (`:36`), the clash checks take `forKeys: selected` (`:88`, `:90`), and `onRun` hands those keys
to the launch (`:30`). A card dismissal from the picker re-keys the row, so every key the sheet holds for it
is dead, including the one `onRun` is about to pass.

So this phase states, rather than implies: the new `onRun` payload carries per-night decisions and not only
keys; the commit happens before `onRun` fires; and **the keys passed to the launch are re-derived from the
store, never from `selected`**.

The sheet's header comment records two invariants this phase reverses (`:6-9`, `:21-22`): the selection is
per-run and transient with nothing persisted, and the sheet never holds a SwiftData model across the run.
Both are superseded deliberately, and the comment is rewritten in the same change rather than left to argue
for the old design (L613).

### 3.3 28 nights, and the rows with none

Nights grouped by week with the weekday named. **Screenshot at 28 and at 2, in both themes, at a WIDE
window and a laptop window, and put them in the PR** (L606, in full: the first draft asked for three of
the four).

`CappedScrollView(maxHeight: 360)` (`:69`) clips. At 28 nights, say whether the confirm control is still
reachable and screenshot that state, because the amount of content deciding whether the primary action can
be clicked is a measured failure (L189), and a clipping region must show at rest that content continues
past its edge (L76).

22 rows carry a span and no `runNights`, 9 live. **MEASURED 2026-09-17 across 29 dated snapshots back to
2026-06-28, and the answer is the bad one: ZERO of the 22, and zero of the 9 live, has ever gained nights.**
The one row that ever held any went the other way, from 4 nights to none, because they were dropped. Twelve
consecutive daily snapshots show the cohort frozen at exactly 22 and 9.

**So the sentence "they pick their nights up on the next scout" is FALSE for this cohort and is deleted.**
Those 9 live rows are permanently outside this feature, and the picker's cannot-help state is their
permanent condition rather than a transient edge. It says why rather than rendering an empty list (L10).

The mechanism is not wholly dead, which is why the claim looked safe: the cohort was 36 in the 2026-07-28
snapshot and 2 of the 7 still traceable gained nights as the scout first re-touched pre-#1523 rows. It has
not touched one of today's 22 in seven weeks.

**And the cohort is not what everyone has been calling it.** 2 of the 22 carry `droppedRunNights`, so they
came through POST-#1523 machinery: `ScoutService.swift:1821` sets `runNights = DroppedNight.keeping(...)`,
and when the drops subtract every night the list empties while the `runEndDate` correction on the next line
only fires `if !existing.runNights.isEmpty`. **The state is reachable today**, so an empty night list means
two different things and every consumer branching on it has to say which it assumes.

**The same false sentence is in the CODE**, in `BlockedCalendar.conflict`'s own comment
(`BlockedCalendar.swift:~296`, "They pick up their nights on the next scout"). Correcting this plan alone
leaves it standing exactly where the next implementer reads it, so it is corrected in the same change
(L57: a correction recorded only in a transcript recurs, because the artifact that governs never changed).

### 3.4 Duplicates

The picker deduplicates on read. **Re-derived 2026-09-17 through `QueueModel.selfBookingNights`: 19 rows,
11 live, and the premise is stronger than it was written.** Nine are a simple 2 to 1; the rest run to 20 to
19, 10 to 7 and, on a LIVE `new` row, 20 to 10, every night of a 20 night run stored twice. Without the
deduplication that card renders twenty rows for a ten night run. The upstream fold defect is filed
separately.

### 3.5 A partial launch, and why the obvious mechanism is the wrong one

Runs that commit launch; runs that do not are each named with their own cause (Dan, 2026-08-30), and a
re-press must tell a refused run from an untried one (L47, L126, L148).

**The first draft cited `recordHeldBack` and the red team killed it.** It stores two fields, `heldBackAt`
and `heldBackBySlot` (`Prospect.swift:580`, `:585`), where the second is a `RunSlot` raw value and not a
cause; `QueueModel.heldBackNote` (`QueueView+Model.swift:3451-3463`) switches on the slot and can say
exactly three sentences, all of them "another run is working on this one". And
`sweepStaleHeldBackMarks` (`PrepQueueService.swift:1045-1061`) **clears it whenever the holding run ends**.
Three of the four causes here outlive the run, so the mark would be gone by morning: a test written the same
day passes, and the durable trace does not exist. That is a mechanism that ships green and does nothing.

So this phase adds a per-row field carrying the **cause**, and **each cause carries its own clearing rule
derived from that cause's own lifetime**: `.cannotCheck` clears on a successful read, a key another card
holds clears when the key is free, an in-batch collision clears on the next launch, a failed save clears on
a successful one. Four causes, four messages, four tests, because two outcomes with distinct messages and
the same consequence are one outcome (L11, L260).

The same class is **already live and unfixed** on a shipped sibling: `.cannotCheck` on the bulk dismiss
path increments a local counter (`ProspectMutations.swift:812`, `:836`) that only becomes a banner, and
`dropNight` is written so a refusal leaves the row as it was (`:211-213`). Covered here, not filed, because
it is the same defect in the same mechanism.

### 3.6 Ordering, and the sweep the first draft omitted

Settle every key-availability lookup before the first write, then commit and save, then re-read every
`naturalKey`, then **call `ConflictSweep.reapply`**, then compute clashes, then build the queue, with a
failed save aborting the launch. `reapply` (`DayOff.swift:175-183`) already re-derives the conflict key from
`runNights`, so the picker joins a shared recompute rather than inventing one; the first draft left it out
of the ordering entirely.

### 3.7 The middle-night hazard, specified as writes

The diagnosis survived the red team intact. `dropNight`'s comment (`RunNightDrop.swift:183-185`) asserts the
dropped night is always the run's first remaining night, and the code is built on it: the walk starts at
`remaining.sorted()`'s first element (`:231`), appends `.taken` candidates to `released` (`:238-252`), then
unconditionally sets `performanceDate` (`:266`), `runEndDate` (`:267`) and `naturalKey` (`:271`).

Under answer 9 the picker no longer calls `dropNight`, which removes the common path into this hazard. It
does **not** remove the hazard, because a card dismissal from the picker still reaches it, so the branch
ships anyway and the prescription is given as writes rather than prose:

| | opening-night drop | any other night |
| --- | --- | --- |
| forward walk | runs, as today | **does not run** |
| `released` | as today | **empty** |
| `runNights` | night removed | **night removed** |
| `performanceDate` | rewritten | **untouched** |
| `runEndDate` | `kept.max()` | **`kept.max()`**, so dropping a closing night moves it |
| `naturalKey` | rewritten | **untouched** |

`runEndDate` is the one the first draft missed: dropping the LAST night takes the non-opening branch, and
twelve readers take the span from that field, `BookingMatch.swift:39`, `FollowUp.swift:162`,
`OutreachFunnel.swift:83`, `BulkDismiss.swift:74` and `EventDateInDraft.swift:48-51` among them. Moving it
is correct and is stated; the interior of a span already has holes on any weekly series, which is the
argument Phase 5 makes rather than assumes.

Both branches tested, and the middle-night branch mutated INTO the walk to see the guard go red. Find the
reliance by grepping the invariant itself, not by reasoning about the feature (L204):
`grep -rn 'first remaining night\|remaining.sorted' mac/Overture`, result in the PR body.

### 3.8 Undo is the inverse, or it is not undo

The picker's commit writes `pitchedRunNights`, `skippedRunNights`, possibly `conflictClearedKey` (2.5), and
possibly the card dismissal path's fields. **Every one of them is enumerated with what the restore does**,
and the round trip is tested rather than the restore alone, because an undo restoring fewer fields than the
action changed is not its inverse and any copy calling it reversible is a claim about two separate writes
(L574, L38). `restoreNights` is already plural; the new lists join it.

---

## Phase 4: the drafter, on both sides of the language boundary

### 4.1 The handoff

`PrepQueueService` sends `performanceDate` (`:90`) and `runEndDate` (`:92`) and nothing else about dates. It
gains the kept nights. Version is **14** (`PrepQueue.swift:270`), so the bump is **v14 to v15**.
`docs/contracts.md:30` still lists 1 to 13 and is already stale against 14, guarded by nothing, because
`PrepQueueVersionsAreDocumentedTests` reads only the paragraph below the table. Fixed here, with a guard on
the table row.

### 4.2 The runbook rule, in one place

Name the kept dates; span only when contiguous AND more than three; never a night outside the kept set. The
passed-opening-night half is unchanged and keeps its own test.

**The threshold and the contiguity predicate live in the shared contract, not written out in five places.**
They would otherwise be repeated in `docs/prep-runbook.md`, the brand voice skill, `references/email-and-alt-text.md`
and both halves of the twin, which is L263 reintroduced one level below the fix 4.3 makes (L41, L70).
Fixtures are derived from the threshold, never written as literals at its edge (L401).

The rule lives in THREE files, two outside this repo and authoritative:
`~/.claude/skills/dan-wright-brand-voice/SKILL.md:73` and `references/email-and-alt-text.md:10` both carry
the run-date sentence. `scripts/check-brand-voice-drift.sh:37` holds **24** anchors (the first draft said 33
and was not re-measured, which is the parent plan's own rule broken again), and **none of the 24 matches
this paragraph**, so the drift guard cannot see this rule change. An anchor is added in the same change.

### 4.3 The TypeScript twin

`src/lib/draftEventDate.ts` declares itself the twin of `EventDateInDraft` (#2864). Its `nights()` is the
same span walk this phase removes (`:96-99`), `prepEval.ts` feeds it `runEndDate` (`:693`), both consume
`fixtures/draft-event-date/cases.json`, and `src/lib/fixtureShape.ts:158` and `:163` encode per-version
presence.

Change only Swift and the two halves diverge indefinitely, each internally consistent (L263), and **the
eval that is supposed to prove the runbook edit safe is the half still measuring the old rule**, so it
would score a draft naming a skipped night as fine.

**Both halves change in ONE commit.** The shared corpus gains a kept-nights column both sides consume
(L26), `prepEval.ts` threads it, `fixtureShape.ts` gains the v15 rule, and the twins are proved to agree by
mutating one side's rule and watching the shared-corpus test go red on the other.
`grep -rn 'runEndDate' src/lib` returns **5** files; that command goes in the PR body beside the Swift one,
because the superseded plan's enumeration was scoped to Swift and structurally could not see any of this
(L96).

### 4.4 The eval runs before the runbook edit ships

Dan, 2026-08-30, unchanged. Not split into its own pull request.

---

## Phase 5: the siblings, and the two notices

Enumerated by command (L96, L30). `grep -rln 'runEndDate' mac/Overture --include='*.swift'` returns **25**.
`grep -rn 'EasternDate.runLastNight' mac/Overture --include='*.swift'` returns **13 hits over 10 files: 10
call sites and 3 comments**. Both commands in the PR body.

Four consumers compute over the whole span and become wrong once kept nights are a decided subset:
`BookingMatch.swift:39`, `FollowUp.swift:162`, `OutreachFunnel.swift:83`, and `BulkDismiss.swift:64-65`
and `:74` (the first draft's `:68` and `:72` were a comment and a declaration). Each gets a stated answer in
the PR body with an issue number where it is not closed here.

### 5.1 The new-nights marker

Answer 3. A run that grows after a pitch marks the Reached Out row, naming how many nights nobody has
judged, with the control to judge them there. It reads the **unjudged** set from 2.4, which is why that
state has to be enumerable rather than merely countable (L507). A night that left and returned is not new
(2.6).

### 5.2 The dropped-night notice, which ships INERT and says so

Answer 4. A row whose frozen promise names a night no longer in `runNights` says so.

**On the day this ships it can fire on nothing.** `promisedNights` is written going forward only, and
answer 6 means all 48 sent rows have none, **including the one row that is in this state today and is the
reason the notice exists**. A writer that only fills records going forward leaves every consumer running
correctly over an empty set while the feature reads as working (L389, L543).

So the notice takes the 2.10 read-back as a **labelled fallback** for pre-feature sends: same extraction,
same discriminated source, rendered as read back from the email rather than recorded at the time. That is
what makes it fire on the row that motivated it. Where the fallback cannot answer, the row says so rather
than saying nothing.

The figure "one of the four multi-night sent rows is in this state" was measured over `droppedRunNights`
against `runNights`, which is **not** the predicate the shipped notice uses, so it is re-taken through the
shipped predicate before this merges (L629, L418).

---

## What this plan deliberately does NOT do

- **A per-night override record SHIPS after all**, which reverses this plan's own first draft. It is the
  old `acceptedNightConflicts` in substance, and the reason it is justified now is not the prep gate
  (#3369 deleted that) but that 16 of 89 live multi-night runs carry two or more blocked nights and the
  single `conflictClearedKey` cannot hold two answers. Measured through the shipped predicates, #3963.
  What makes it a live column rather than a dead one is that the row reads it back to explain why a night
  with a shoot on it was pitched (L46, L65). See 2.5.
- **No two-gate split.** Same reason. Gone, not deferred.
- **No backfill of the 48 sent rows.** Answer 6, and it removes an idempotency hazard rather than solving it.
- **No exclusion record for #16.** Its only named reader has never shipped an issue (milestone 66: 11 open,
  0 closed). The evidence gap this leaves is **#3961**, filed rather than waved through.
- **No repair of the natural key corpus**, and NOT because there is nothing to repair. #3962 answered on
  2026-09-17: 19 rows are drifted right now, a launch migration repairs them as a side effect of an
  unrelated pass, and the scout re-creates them on its next run. A one time repair would win until the
  next scout. The guard ships instead, asserting the signature at the writer rather than the corpus's
  state, because the corpus's state depends only on which side of that cycle the clock is on (2.11).

## The gating issues, filed WITH the phases

L481, applied to this plan rather than only cited by it. Each blocks the section that names it.

- **#3961**: nothing durable records which nights were blocked at the moment of a pitch, so a decision
  recorded as Dan's cannot be explained the next day. Gates 2.5.
- **#3962**: ANSWERED 2026-09-17. The corpus is not clean, it oscillates: a launch migration repairs it as
  a side effect of an unrelated pass and the scout re-creates it. 2.11 is rewritten and the guard asserts
  the signature at the writer rather than the corpus's state.
- **#3963**: ANSWERED 2026-09-17, all four figures re-derived through the shipped predicates. The duplicate
  premise held and is stronger; the conflict population is real and the stored column is not stale; the
  span-only rows have NEVER gained nights, so 3.3's reassuring sentence was false and is deleted; and the
  fourth figure, 16 of 89 live runs with two or more blocked nights, reversed 2.5's design.
- **#3964**: the per-card cost of the two Phase 5 notices is unpriced against a surface measured at
  **0.368 ms per card over 426 cards, about 157 ms, already over the 100 ms bar**
  (`ScoutStageCardLoadLiveStoreTests.swift:56-58`). Both notices add a blob decode per card and one adds a
  to-many traversal. Gates Phase 5.
