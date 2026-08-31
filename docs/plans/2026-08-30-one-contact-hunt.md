# One contact hunt, with declared targets and evidence that outlives the run

Planned with /plan-council on 2026-08-30. Revision 3.
Round 1: 23 agents. Revision round: 6 agents. Winner scored 8.3 of 10 against criteria fixed before any option existed.

## READ THIS FIRST: what is still wrong with this document

This plan is recorded WITH its defect list rather than after being made clean, because it did not converge under audit.
Round 1 produced 7 lessons violations and 1 broken claim. Those were all closed. The fresh audit over the corrected
version then produced 9 broken claims and 6 further violations. There is no reason to expect a third round to be the last,
and each round costs a full panel. Dan's call, 2026-08-30, in session: record it with the gaps named, build Phase 0 only,
and check each later phase against the tree as it is when we reach it.

Treat every numbered claim below as unverified until checked. The items in this section are the ones already KNOWN to be wrong.

### Reality-check verdict: needs-fixes (9 items)

1. THE FREE-RECOVERY HEADLINE OVERSTATES THE LIVE HALF. The order-of-work section says 0.1 alone 'recovers roughly 7 to 11 shows'. The 11 rows break down as: 5 dismissed rows already stored email_found (dated 2026-08-05 and 08-09), 1 dismissed no_email_found (08-12), 1 dismissed social_only (08-31), and 4 rows with status 'new' (weak_contact_only 09-10, no_email_found 09-14, 09-24, 09-25). So 7 of 11 are dismissed and 6 of 11 are past-dated. The rows that are both live and dated ahead number FOUR. '7 to 11' reads as the recovery a person would see on the queue and it is 4.

2. THE 0.1 CONSUMER TABLE IS INCOMPLETE AGAINST ITS OWN STATED DERIVATION. The plan says the table comes from grep -rn 'reachabilityResultFromRecipients|contactTierFromRecipients|contactTierForScoring|contactRouteForScoring' mac/Overture and names six consumers outside Prospect.swift. That grep returns EIGHT. Missing from the table: ClassificationOverride.swift:35,37 and ContactScoreAdjustment.swift:18,23 (named in the anchors table but absent from the enumeration the PR body is supposed to carry), and QueueView+Model.swift:2529 (item.contactRoute = $0.contactRouteForScoring(now: now)), which appears NOWHERE in the plan and is a genuine consumer putting the scoring route onto the QueueItem. This is the plan's own PR rule 3 and L96 failing on the plan itself.

3. THE RunCoverage R3 CORRECTION OVER-CORRECTS. The plan says '.unreadable is a refusal the caller must honour' and warns that 'a caller written to catch a throw would silently treat .unreadable as permission'. The shipped caller does not have that hazard: PrepQueueService.heldByOtherRun (:996) switches on RunCoverage.read and its .unreadable branch at :1006-1009 does 'throw PrepLaunchError.holdingsUnreadable(runNoun:)'. Read end to end, an unreadable holding DOES throw. The three-case substance is right; the hazard sentence describes a gap that is already closed.

4. PrepResults.swift CITATION IS WRONG. The anchors table cites deniedByRoute at ':41'. It is declared at :53; :41-42 is the #2387 comment ABOUT it. The '24-66' range for WebCalls is right (the struct opens at :25).

5. THE CASE-SENSITIVE BILLING-TOKEN SEQUENCE DOES NOT FULLY REPRODUCE AND IS UNLABELLED. The plan gives '20 / 13 / 10 / 4 / 5 / 0' with no field names, and separately asserts Producer family is 4 under both matchings. Measured: case-sensitive any-token 20, Featuring|Starring 13, Director family 10, Producer family 4, Choreograph 0 all reproduce, but case-sensitive Music Director is SIX, not 4 or 5. Under either reading of the unlabelled ordering, one member is wrong. This sits inside the argument that the matching rule changes the number by 35 percent, so it is load-bearing.

6. 'find-tests-naming.sh CANNOT SEE TYPESCRIPT AT ALL' IS TOO STRONG. ROOT_LIST at :63 is the two Swift test targets, but :68 reads an OVERTURE_TEST_ROOTS environment override, so the scope is a default rather than structural. The plan's remedy (a separate rg sweep over src/, fixtures/, docs/) is still correct, but for a different reason it should state: the tool attributes every hit to an enclosing @Test func or @Suite, which TypeScript has none of, so pointing it at src/ would report nothing useful rather than nothing at all.

7. prepRunbookRules.ts:20-37 UNDERSTATES THE ARRAY. RUNBOOK_RULES opens at :19 and runs well past :37; a 'representative-only-when-the-target-names-a-person' rule and a '#1720 the two halves of the house rule' block follow the Carnegie entry the plan treats as the last. Phase 6's deletion sweep sized to :20-37 would leave rules behind.

8. EmptyAnswerReport.swift:74 IS CITED UNDER THE WRONG PROPERTY. The anchors row bundles it into 'an exhaustive switch that names nil explicitly'. label(for:) at :70-81 takes a NON-optional EmptyReason and has no nil case; the switches that name nil are ReachabilityCopy's badge (:559) and help (:598). The exhaustiveness claim about label(for:) is true, the nil-naming claim about it is not.

9. THE OVERWRITE WINDOW IN 1.2 IS 37 MINUTES, NOT 45. The seven surviving chunk streams are stamped 17:29-17:31 local, and the 20260830-205244 archive folder is named from a UTC generatedAt corresponding to 16:52 local. Trivially wrong but the sentence is quoted as a measurement.

### Lessons audit: violations (366 lessons read)

1. **L25 (with L28, L209)**
   Where: Phase 5.2, "The experiment": "Run the post Phase 4 single hunt over the whole primary stratum. Run the current Prep style deep hunt over the same set, independently, neither seeing the other's answers, against a pinned runbook revision, named in the report". The plan pins the runbook revision and nothing else.

   Why: Verified in the tree: mac/scripts/prep-run.sh:120-127 chooses RUN_MODEL by whether the run is a PROBE. Arm 1 is a check, so it runs on OVERTURE_MODEL_REACHABILITY = "sonnet" (models.sh:31). Arm 2 is a Prep-style hunt, so it runs on OVERTURE_MODEL_DRAFTING = "opus" (models.sh:19). The two arms of the gate therefore run on DIFFERENT model tiers by construction, and models.sh records Dan's call that the TIER is pinned and not the version, so even one arm's model can change between the two runs. L25 says pin everything including AI models; L28 says pin its model per task. The gate that decides whether the second hunt is removed at all would be measuring Sonnet against Opus, not one-hunt against two, and the co-varying component moves WITH the arm so the whole difference is attributed to the wrong variable (L209). The plan's own #1597 precedent is that the cheap tier was chosen for the check on a measured eval, which is exactly the confound.

   Fix: Pin BOTH arms explicitly for the experiment and record the pinned value in the report beside the runbook revision. Either (a) run both arms on the same model, and say in the report that the finding is about hunt design at that tier and says nothing about the other tier; or (b) run four arms (each hunt at each tier) and state which of the two variables the reach difference is attributable to. Either way the report must print the model each arm actually used, read back from record_model's own output in the results file rather than from the plan's intention, and the pre-committed 10 percent bar must name which arm-pair it applies to. Add the model to the list of premises Phase 5.2 records re-measurably (L316), beside the runbook revision.

2. **L58 (with L267, L5)**
   Where: Phase 5.2, "The experiment", steps 1 to 3: arm 1 then arm 2 over the same 77 rows, compared "show by show", with no snapshot, no isolation and no statement of what each arm writes. Phase 0.3 by contrast requires a confirmed launch backup, a dated snapshot JSON and a tested reverse before it writes anything.

   Why: Arm 1 is a real check run: PrepImporter.ingestContacts (PrepImporter.swift:277) matches or APPENDS recipients onto the live Prospect, markProbed writes reachabilityResult and reachabilityProbedAt, and a settle writes OrgReachabilityAnswer. RunCoverage (RunCoverage.swift:17-40) forbids two runs holding the same show, so the arms cannot be concurrent and arm 2 necessarily runs against rows arm 1 has already written into. L58 is exactly this: two things that must be compared cannot be verified against records one of them wrote into the other. Arm 2's "reach" on a show is then partly arm 1's own contribution, and the 5.1 foundAt stamp attributes those recipients to arm 1's slot, so the contamination is invisible in the comparison. L267 is the second half: arm 1 spends the store's pre-experiment state, and the marked set, the negative-verdict corpus and WrittenOffBacklog are all defined over that state, so the baseline the gate is read against no longer exists once arm 1 has run. And this is the largest destructive live-data write in the whole plan, over 77 rows, with none of the snapshot-and-reverse discipline Phase 0.3 applies to a smaller one (L5, L7).

   Fix: Before either arm runs: confirm a success line in overture-store-backups/backup.log for that launch and refuse otherwise, and write a dated snapshot of every field either arm can touch on all 77 rows plus every OrgReachabilityAnswer row for their organisations, reusing ReachabilityRederivation's snapshot-and-revert machinery rather than a second one. Then run the arms so neither can read the other's writes: run arm 2 against a copy of the store restored to the pre-arm-1 snapshot, or run arm 1, snapshot, revert to the baseline, run arm 2, and compare the two snapshots against the common baseline rather than against the live row. State in the report which of those was done. Judge arm 2's "reach" only against contacts whose foundBySlot names arm 2, and print the count of rows where arm 1 had already added a recipient, as the contamination control.

3. **L517 (with L332, L98)**
   Where: Phase 0.3 Step 3: "WrittenOffBacklog.rows(now:) = rows where contradictionMarkedAt != nil + rows still carrying a negative or weak verdict with hasAnyRoute == false", combined with Step 0's "writer: the migration, once, and nothing else ever."

   Why: Read the two strata as sorting rules and a row can land in neither. Take a row that on migration day carries a negative verdict and NO route: it is unmarked, and correctly in stratum 2. It then acquires a route (a Prep hunt, which exists until Phase 6; a manual recipient; #3283/#3289 making a route render at all, which the plan ships in 0.4 and says is a growing set). It now has hasAnyRoute == true, so it drops out of stratum 2, and it has no marker, so it never enters stratum 1. It is in no bucket, on the one surface built to name written-off shows, and the silence is indistinguishable from the show having been correctly settled. That is L517's shape exactly, and the plan applies L517 rigorously to the 0.2.1 incomplete-reason rules while leaving its own backlog definition unchecked. It is L332 compounding it: a marker whose only writer is a launch migration is blind to everything the running system writes afterwards, and 0.2's refusal only covers the barren-re-check path, not the acquire-a-route-later path. Phase 5.2's second stratum reads the same marker, so the same rows are missing from the enriched reading too.

   Fix: Assert, over every combination of (verdict negative/weak or not, hasAnyRoute true/false, marker present/absent), that each row lands in exactly one of the strata or is explicitly excluded with a named reason, and see it fail by removing one stratum's guard. Then close the gap in one of two ways: either give contradictionMarkedAt a second writer that stamps a row the moment a route arrives while a negative verdict stands (the same shared refusal helper 0.2 already introduces is the right place, since it is already on the ingest path), or define stratum 2 as "negative or weak verdict" with no hasAnyRoute term and report the routed and unrouted halves as separate lines under it. Whichever is chosen, print the count of rows matching neither stratum as its own line, so the gap is measured rather than silent.

4. **L11 (with L158, L47)**
   Where: Phase 1.1 ("One definition of 'this stream finished'") and Phase 4.2/4.3. 4.2: "For every app named target with no TargetAnswer: record a MISS, adding targetNotAnswered". 0.2.1's writer table gives runDidNotFinish exactly three writers: "the #3007 watchdog kill, an unparsable results file, an unsupported version".

   Why: Measured in this repo's own archive at check-run-archives/20260830-205244: queue 97 items, results 90, runCost {recorded:false, streams:10, streamsRecorded:9} beside webCalls {recorded:true, streams:10}. Seven shows were lost to a stream that produced no terminal envelope, with no watchdog kill, no unparsable file and no version problem, so none of runDidNotFinish's three writers fires. Under Phase 4.2 those seven shows have app-named targets and no TargetAnswer, so every one of them is stamped targetNotAnswered, and 4.3 then reads their absent evidence as canonicalDomainNeverFetched or evidenceUnmeasured. The row is made to say "the run declined to answer this target" when the true fact, which 1.1 makes knowable in the same plan, is that the chunk carrying it died. A message may claim only what its check measured, and here the diagnosis is handed to the wrong reporter exactly as in L158. The consequence is not cosmetic: targetNotAnswered's own counter is what 4.2's 35 percent enforcement bar is read off, so a run that lost a worker inflates the bar the rule is judged against.

   Fix: Make stream completeness an input to the per-target rules rather than a separate report. Add "a stream that produced no terminal result envelope" as a fourth writer of runDidNotFinish, sourced from 1.1's shared stream_completed(), and have 4.2 and 4.3 consult it FIRST: a target whose item belongs to an incomplete stream settles runDidNotFinish and is excluded from targetNotAnswered, canonicalDomainNeverFetched, searchNotEvidenced and evidenceUnmeasured entirely, and from the denominators of the 35 percent and 65 percent bars. Report the excluded count as its own line. Prove it with a fixture built from this archive's shape (97 queued, 90 results, one stream with no envelope) asserting the seven shows carry runDidNotFinish and no targetNotAnswered; mutate the ordering so the coverage rule runs first and record the failure text.

5. **L211 (with L98, L83)**
   Where: Phase 0.3 Step 2, the OrgReachabilityAnswer half: "Recompute each row through the ledger's own rule (the same expression record uses, over the prospects of that organisation by OrgKey.stored), and where the recomputed value differs, delete the row." The only refusal named is "A row whose sourceNaturalKey names no prospect is reported in its own line and left alone."

   Why: The deciding read and the refusal are keyed on two different things. The recompute reads prospects by OrgKey.stored; the orphan refusal reads sourceNaturalKey. The plan's own measurement proves the prospect population behind a ledger row can be incomplete (three of sixty rows already name a sourceNaturalKey no prospect carries), and the two keys can disagree in the other direction too: an organisation whose prospects have been closed out or merged away returns an empty or short set by OrgKey while its sourceNaturalKey still resolves. An empty prospect set recomputes to a value that differs from any stored positive verdict, so the row is deleted. That is L211 exactly, an incompleteness in the read turned into a deletion, and here the deletion is effectively permanent rather than merely slow to rebuild, because the plan's own consolation ("a deleted row simply has no inherited answer until the next settle rebuilds it") requires prospects for that organisation to exist and be checked again, which is the very thing that came back empty. The loss is silent on both sides: the migration reports a clean deletion count and every sibling show simply stops showing an inherited answer.

   Fix: Make the recompute refuse on a short read rather than only on a fully absent one. Count the prospects the OrgKey read returns; refuse to delete (report the row under its own "could not recompute" line, leave it alone) whenever that count is zero, and, where a prior count is available, whenever it has collapsed against the previous run. Use ONE key for both the read and the refusal, or state explicitly which of OrgKey.stored and sourceNaturalKey is the declared home of "which prospects answer for this organisation" and make both halves consult it (L83). Report the three counts separately: deleted, kept because recomputed the same, refused because unmeasurable. Prove the refusal fails first, on a fixture whose ledger row names an organisation with zero live prospects, and record the failure text.

6. **L113 (with L167, L27)**
   Where: Phase 3.1 (`PrepTarget`: `var kind: String  // organisation | person | act`, `var source: String  // presenter_on_record | listing_organiser | listing_billing | group_name`) and Phase 4.1 (`TargetAnswer`: `var outcome: String  // route_found | no_route_found | no_such_site | not_reached`). Phase 4.1's boundary assertions cover only a malformed `no_route_found` and the presence of `targetAnswers` at all.

   Why: Three closed vocabularies crossing the AI boundary are declared as bare Strings whose members live only in a trailing comment, and the plan states no behaviour for a value outside them. The plan is meticulous everywhere else about this: `IncompleteReason` is an enum with an exhaustive switch naming nil so a new case breaks the build, and `EmptyReason` is decoded through `init(rawValue:)`. Here nothing says what a target with `kind: "ensemble"` or an answer with `outcome: "partially_found"` does. Under 4.2 an unrecognised outcome is either silently treated as an answer (so a target reads as covered on a word nobody recognises) or falls to MISS (so a run that answered is accused of not looking), and neither is written down, which is L113's missing key taking a default that is indistinguishable from a deliberate choice. It is also #2893's shape one level up: the runner can read PrepResults.swift, and a field typed as String with four values in a comment teaches it that any string is permitted (L167), while a prompt sentence naming the four is the rule living only in a prompt (L27). The class most likely to arrive is the one 3.3 explicitly invites, a run-discovered target the app never named.

   Fix: Type all three as String-backed, CaseIterable Swift enums beside `IncompleteReason`, decoded through `init(rawValue:)` at the boundary, with an exhaustive switch wherever they are read. Then state and test the refusal for an unrecognised value: a `TargetAnswer` whose outcome does not decode is a MALFORMED answer reported as a fact about the run (the same class as 4.1's existing malformed rule) and routes the row to `incomplete` carrying its own reason, never to a satisfied target and never to a negative verdict about the show. Add the boundary count to the per-run report so an unrecognised vocabulary value is visible on the first run that emits one (L128). Prove it: a fixture whose answer carries an unknown outcome must not satisfy 4.2's coverage; mutate the decode to fall through to satisfied and record the exact failure text.

## Open risks the plan names itself

1. Every store figure in this plan is SQL taken beside the app, not the shipped Swift predicate, and this repo has its own instance of that gap (#2035/#2517: SQL said 81 where the shipped rule said 66). Phase 0.3 Step 1 requires a debug-menu recompute of all load-bearing figures before anything writes, but until that runs, the 11, the 4, the 27/10, the 33/77 and the ledger's 60/28/7/3 are all provisional, and the Phase 5.2 gate is sized by two of them.

2. The 11-row free-recovery figure is an explicit LOWER bound: SQL cannot see the blank-subject, draft-lint and greeting holds that `isSendablePending` also folds in, so the true count of badge-suppressed addresses is higher by an unmeasured amount. It could be materially higher, which would make 0.1 worth more than the plan claims, or barely higher. Nobody knows until it is measured through the shipped predicate.

3. Decision 7 is now the largest unresolved item and it sits in Phase 0 while changing the power of a measurement taken in Phase 5. If Dan approves the verdict sweep, the 77-row primary stratum shrinks by however many rows the sweep moves and 5.2 must be re-sized; if he declines, it stays at 77. The plan prints both strata before spending, but the sequencing means an early decision silently governs a late gate.

4. Phase 0.1 now changes behaviour at six consumer sites rather than three, and one of them removes a control from cards that carry it today (the hand-pitch control on conflict-held rows). That is defensible on FormOutreach's own stated scope, and it is still a visible loss on rows Dan did not touch, sized by a count nobody has taken yet.

5. Splitting the incomplete reasons into a set with per-reason counters adds two encoded blob columns to `Prospect` (a newline-joined set and a JSON count map). Both are hand-rolled encodings on a SwiftData model, and a decode that silently drops unknowns is the right boundary rule but also means a writer bug loses reasons quietly. The L517 test covers erasure between rules; it does not cover a malformed blob.

6. The three separate archive directories are the right shape but triple the number of rotations nobody has watched run in production, and `eventArchiveKeep = 10` is still sized on one night's seven files. A busier run with more chunks scales the 1.7 MB linearly, and the plan has no measurement of what a full 97-item run's streams actually cost.

7. Phase 4.3's precision measurement is specified over the 36 form-bearing hosts and the archived attributed queries, but the archived queries only exist for runs after Phase 1.2 ships, and today's surviving streams are all single-show chunks. So the query-token precision half cannot be measured until at least one multi-item run has been archived, which is the same dependency that already gates 1.3's attribution-rate measurement.

8. Phase 6's TypeScript sweep is specified as an `rg` over named files, and `prepRunbookRules.ts` holds its rules as REGEXES rather than as the symbol names the sweep searches for. A sweep for a symbol may therefore miss a rule whose pattern spells the behaviour differently, which is the same class of blindness the Swift tool had, one level down. The plan says a nothing-found result is a finding to investigate; it does not give a mechanical way to enumerate the rules.

## Decisions escalated to Dan, still unanswered

1. What does a card say when its last check came back incomplete, and what does the app say on a run where more than half the shows settle incomplete? The named people and the 'Only names, no way to reach them' badge stay per your decision; what changes is the sentence above them, from a claim about the show to a claim about the search.
   * I write both sentences myself; show me the rendered card and the run notice, not the code
   * Draft both, show them rendered in every branch (found, incomplete, never checked, empty list), and I will edit
   * Use 'The last check did not finish for this show' plus a re-check offer, and a run-level line naming the count; ship it and I will correct it live

2. Phase 0.1 moves the contact tier onto the same clean predicate as the verdict, which is what keeps the badge and the fit score answering from one list. Consequence: shows whose only address is held by an uncleared calendar conflict acquire a tier they did not have, and their fit score moves. Should that happen?
   * Yes, move it: a blocked night is not a fact about reachability and should not depress the score either
   * Move it, but show me the per-direction count of score movements before the migration writes anything, and let me abort
   * No, leave the tier where it is and accept that the badge and the score answer from different lists

3. After Phase 6, the route found at triage is the only route, and nothing re-confirms it before the send. The plan proposes a warning (never a block) on the send sheet when a route is older than 60 days. Is 60 the right clock?
   * 60 days, warn only, with the age named in the sentence
   * 90 days, matching the verdict's own freshness window
   * 30 days: an inbox goes stale faster than that and I would rather be told too often
   * No note at all; I will judge it from the card

4. Phase 3's listing-billing parser reaches at most 27 of 97 shows on the measured queue. Below what precision on person targets should it ship disabled rather than enabled?
   * Ship it enabled at 90% precision or better, disabled below that with the activating issue filed
   * Ship enabled at 80% or better: a wrong extra target costs one wasted lookup, a missed lead costs a show
   * Ship it disabled regardless until I have read a full run's worth of what it named

5. Phase 6 (removing the Prep hunt) is gated on a two-armed experiment over the written-off backlog: population at least 25 negatives with both readings, and the deep arm reaching at most 10% of what the single hunt called negative. Is that the right bar, and do you approve spending two full hunts over that backlog to measure it?
   * Yes to both: 25 and 10%, and spend the two runs
   * Approve the experiment, but I want a stricter bar: at most 5% reached
   * Approve the experiment, looser bar: 20% reached is fine if the misses are all shows with no site at all
   * Do not remove the Prep hunt at all; keep it as a cheap conditional second look on kept shows only

## How the revision answered round 1

1. BROKEN CLAIM 1 (hasAnyRoute collapses the five-way cascade) - ACCEPTED AND FIXED. Verified `Prospect.swift:291-307` is a five-arm cascade and only its first arm is address-only. Phase 0.1 now ships TWO predicates: `Recipient.hasUnguardedAddress` (address present, not held by a guard) which goes into the emailFound arm at :292, the tier at :260-261, the emptyReason count at PrepImporter:139 and `OrgReachabilityAnswer.swift:125`; and `Prospect.hasAnyRoute`, now DERIVED from the corrected cascade as `reachabilityResultFromRecipients != .noEmailFound` rather than reimplemented beside it, used only where the question is genuinely 'is there a way in at all' (0.2's refusal, 0.3's marker, 0.5's residual). Added a cascade-preservation guard, seen to fail: one fixture per arm, with the mutation being exactly revision 2's substitution, asserting three of four go red.

2. BROKEN CLAIM 2 (the free-recovery claim is wrong because the badge re-derives) - ACCEPTED AND FIXED. Verified `QueueView+Model.swift:2716` feeds `p.reachabilityResultAsHeld`, and `Prospect.swift:386-390` recomputes for any unsent, unbooked show. Added both facts to the verified-anchors table. Rewrote the measurement section: the 27 routed named_but_no_route rows already badge 19 contactFormOnly / 4 socialOnly / 4 weakContactOnly; only 49 rows carry no_email_found, of which 4 hold a guard-aware route and 3 have a date ahead; 11 rows (a lower bound, since SQL cannot see the subject/lint/greeting holds) have a badge suppressing an unguarded address. The closing 'smallest first change' line now reads 0.1 ALONE, 7 to 11 shows, and says why the 28 figure was wrong.

3. BROKEN CLAIM 3 (Phase 0.3's migration reverses a recorded Dan decision) - ACCEPTED AND FIXED, and it reshaped the phase rather than only its wording. Since the badge re-derives, the stored verdict's live consumer is `contactRouteForScoring` (Prospect.swift:271-289), whose comment records the 2026-08-13 reversal verbatim. Phase 0.3 Step 2 now SPLITS: the ledger correction ships unconditionally (0.1 changes what `foundEmails` means on 32 rows, a defect this phase creates), and the prospect verdict sweep is escalated as NEW DECISION 7, quoting both the 2026-08-13 and 2026-07-27 records with their own dates per L249. If he declines, the 4 wrong rows get a narrow one-direction pass in the shape the existing migration already uses. Risk 10 records that decision 7 changes the power of the Phase 5.2 measurement.

4. BROKEN CLAIM 4 (Phase 0.5 mis-diagnosed and under-sized) - ACCEPTED AND FIXED. Verified `EmptyAnswerReport.make` at :41-46 applies no verdict test, and `ProspectRowView.swift:643-654` renders the sentence only under the `.noEmailFound` badge. Rewrote 0.5 entirely: 105 counted, 43 renderable, 62 counted for a claim no card makes, with your full breakdown as a table including the 7 rows carrying a reason with no verdict at all. Named the cause as the writer/reader split (PrepImporter writes the reason whenever usableRecipients == 0, independent of the cascade). The fix is at the READER, with the excluded 62 reported as their own line rather than silently vanishing, a precedence statement for the PR body, and a guard seen to fail. Removed the false claim that 0.1 and 0.3 would largely fix it.

5. BROKEN CLAIM 5 (the version fixture cannot go green and forcing it green causes the lockout) - ACCEPTED AND FIXED. Confirmed on disk: check-results v6, prep-results v11, supportedVersion 11. Added a new section 4.0 that separates the two paths explicitly: the check path keeps its five versions of cushion and its literals stay at 6; the prep path has zero cushion and is what the ordering is built around. The fixture is now an INEQUALITY (every writer's version <= supportedVersion and >= minimumVersion), enumerating the merger constant, the runbook's declared version and the live files, seen to fail by raising the runbook above supportedVersion. Open risk 2 rewritten to say revision 2's own framing was the dangerous part.

6. BROKEN CLAIM 6 (five measurements do not reproduce) - ACCEPTED AND FIXED, all five. named_but_no_route now 27 with a route / 10 without (was 28/9); the whole negative-or-weak population 33/77 (was 34/76); the Producer family 4, stated as 4 under both matchings (was 5); host shape restated as 51 recipient rows, 36 form-bearing splitting 19/1/16, plus 15 carrying an address and no URL, with revision 2's '2' called out as off by an order of magnitude. Every downstream use was chased: the 5.2 gate table, the marked-set expectation (33, 27), decision 5's population, 4.3's widening corpus (36 hosts, not 46), and open risk 3. The coin-flip conclusion is kept and now reads 19 of 36 against 16, with a note that the single-token host is counted with the name-bearing group.

7. BROKEN CLAIM 7 (the archive comparison uses the outlier as the baseline) - ACCEPTED AND FIXED. Measured all seven archives myself: 24, 36, 40, 40, 52, 92, 224 KB, median about 40. Phase 1.2 now states the median, names 224 as the single largest on the one 97-item run, and gives the ratio as roughly 12x rather than 8x. Also verified and added your second point: `PrepRunArchive.swift:14-15` says the pair 'is about 14 KB' and `:48` says thirty runs are 'under half a megabyte', both stale in the file Phase 1.2 edits, so correcting both sentences with today's date and the seven measured sizes is now an explicit task in that phase (L32, L210). Open risk 8 updated.

8. BROKEN CLAIM 8 (a fifth hold state neither predicate reads) - ACCEPTED AND FIXED. Verified `Recipient.swift:185` and its only readers, `DraftReviewView.swift:234` and `QueueView+Model.swift:618,626`. Added it to the verified-anchors table and DECIDED it in 0.1 rather than leaving it to happen: `hasUnguardedAddress` treats a held-down address as a route, which matches today's behaviour, with the reasoning written into the predicate's own comment and a test asserting a held-down address still yields emailFound, so the next reader of `isHeldByAGuard`'s 'all the guards' comment does not conclude a case was overlooked.

9. BROKEN CLAIM 9 (three smaller citation errors) - ALL THREE ACCEPTED AND FIXED. The canonical guess is now cited as `docs/prep-runbook.md:307` and `:495` as two separate lines (I confirmed :307, :495 and an unrelated :545), with revision 2's nonexistent ':494-495' span called out. RunCoverage is restated in 1.6 and the anchors table as a three-case enum whose `.unreadable` is a refusal, with the only `throws` being `write` at :82, and I added why the distinction matters (a caller written to catch a throw would treat `.unreadable` as permission). `EmptyAnswerReport`'s 'one of nine reasons' header against eight cases is now both an anchor row and an explicit task in 0.2.1's change, since that file is cited as the exhaustiveness model.

10. L204 (Phase 0.3 removes an invariant recorded only in ContactFormResultMigration's comment) - ACCEPTED AND FIXED. I did the invariant search by grep as instructed rather than reasoning about the feature, and recorded the method in the plan. `ContactFormResultMigration` is now: a verified-anchors row, a named consumer in 0.1's derived enumeration, and an enumerated subject of 0.3 with its 2026-07-27 comment quoted in full. Launch ordering is stated (it runs before any new pass, and the new pass reports how many rows it had already moved). Dan's 2026-07-27 decision is folded into decision 7 rather than overturned as a side effect. And if decision 7 approves the sweep, the file is dead code and is DELETED in the same change (L29), with the PR body saying which of the two happened.

11. L30 (the sibling enumeration was derived for one predicate and written from memory for the other) - ACCEPTED AND FIXED. I ran your grep and added the full derived table to 0.1: PrepImporter :112/:122/:190, DebugStaging :309/:310/:367, OrgReachabilityAnswer :121, ContactFormResultMigration :26, and FormOutreach :180-181, each with a one-line verdict, all carried in the PR body under the `sibling` heading beside the 28. The hand-pitch consequence is decided rather than discovered: the control correctly disappears from conflict-held rows on FormOutreach's own stated scope (Dan, 2026-07-28: only where the form is the ONLY way through), with two mutations seen to fail and the count of live rows losing the control measured before the change ships. I also corrected revision 2's wrong file reference: :234 is the `isSendablePending` send-path use that stays; :180 is the verdict gate that moves.

12. L285 (three retentions inside one folder drained by one folder-keyed rotation) - ACCEPTED AND FIXED. I read `DatedFolderRotation.prune` and confirmed it rotates whole folders by one keep, and `RunSlot.archiveKeep` is one number per slot. Took the first of your two options, on the #2760 precedent this repo already set for exactly this: `eventArchivesDirectory` with `eventArchiveKeep = 10` and `attributionArchivesDirectory` with `attributionArchiveKeep = 60`, each pruned by its own call, so no consumer's history is drained by another's key. Replaced the constant-comparison test with one that archives past every keep (61+ runs) and asserts per directory which stamps survive, specifically that the pair still holds 30, seen to fail by pointing all three at one directory with one keep. And `eventArchiveKeep`'s own comment now states that for the 50 runs between the keeps the sidecar survives while the streams do not, so re-derivation is impossible there and nobody later cites it as a safety net (L174); 4.4 says the same.

13. L330 (the set-aside acknowledgement is written to a field the second offer rule never reads) - ACCEPTED AND FIXED. I confirmed `Reachability.recheckState` is an independent offer path that already takes `isStillOpen` as a caller-supplied gate for precisely this reason, and found that `probeIsWorthOffering` has four call sites (2215, 2268, 2291, 2335), not one. `Reachability.isSetAside(setAsideUntil:now:)` is now the one shared predicate, taken by all four paths: `probeIsWorthOffering` (as a term, so all four call sites inherit it), `recheckState` (a new parameter beside `isStillOpen`), the bulk filter at :1784, and QueueView.swift:450 through 0.2's consolidation. The guard is one test over the trio asserting `.notOffered` AND absent from candidate keys AND absent from the bulk selection, plus a second case past the expiry asserting all three offer it again, seen to fail by removing the parameter from `recheckState`. Cited overture#3307 as the same defect in this product.

14. L523 (a hand-set suppression with no expiry and nowhere listing what is suppressed) - ACCEPTED AND FIXED. Added `reachabilitySetAsideUntil`, so a set-aside is a deferral that returns the row to candidacy with the reason named rather than a permanent, undetectable silence. The durable list from 0.2.2 item 3 now carries a second section, 'Set aside', with each row's reason, age and expiry, which closes the trap you identified: the repeat-offender list is exactly the surface a set-aside show drops off. Added item 4, the per-run notice reporting the count skipped as set aside, since a run that skipped N for that reason and a run with N fewer candidates are otherwise the same silence (L98, L11). And 5.2 now reports set-aside rows as their own line in both strata and excludes them from the arms, so `NegativeVerdictCorpus` cannot count a suppressed show as a negative nobody re-examined.

15. L53 (nine reasons with independent bars stored in one field and one counter) - ACCEPTED AND FIXED. 0.2.1 now stores the reasons as a SET (`reachabilityIncompleteReasonsRaw`, newline-joined, decoded per line through `init(rawValue:)` dropping unknowns, exactly the boundary rule PrepImporter:148 already uses) plus per-reason counts (`reachabilityIncompleteCountsRaw`, JSON keyed by rawValue, unknown keys dropped). I also split out `reachabilityIncompleteRunCount`, because one run can fire several reasons and a sum of the per-reason counts would overstate how often the show has been paid for; the card line reports the run count and the observe bars read their own counters. Added the L517 assertion (every rule's outcome lands in exactly one of satisfied/violated/unmeasured, and no rule's finding can be erased by another's), seen to fail by making two rules fire on one fixture, and I made 4.3's venue-host-plus-show-title fixture double as that two-rule case. Each of 3.4's 50 percent, 4.2's 35 percent and 4.3's 65 percent bars now says which counter it is read off.

16. L252 / L320 (Phase 6 delegates to a tool structurally blind to the half the guards live in) - ACCEPTED AND FIXED. I read `find-tests-naming.sh:63` and confirmed ROOT_LIST is the two Swift test directories only, and I confirmed every TypeScript subject you named exists: `prepRunbookRules.ts:20-37` holds the literal presence patterns for all six rules plus the Carnegie example, with `prepRunbookRules.test.ts`, `prepEval.ts`, `prepEval.test.ts` and `fixtures/prep-eval/` (whose fixture filenames are the removed behaviour written down). Phase 6 now has a four-point sweep section: the Swift tool covers the Swift half only; an explicit `rg -n '<symbol>' src/ fixtures/ docs/` covers the TypeScript half with every subject named and marked for deletion or re-pointing in the same change; `docsCommands.test.ts` means the AGENTS.md paragraphs move in the same PR; and a run naming nothing is a finding to investigate, not a clearance. Revision 2's 'a run that names nothing means the symbols are spelled differently' sentence is DELETED, since that is precisely the explain-away for a tool that was never looking.

17. L104 (both tests are shape filters and only recall was measured) - ACCEPTED AND FIXED. Added a dedicated subsection to 4.3 stating that the over-match direction is the dangerous one here, because a match makes the rule STAND DOWN and lets a permanent negative stand, and naming both collision routes you identified: a common-word name token matching the venue's own host or a ticketing host fetched anyway, and a WebSearch query naming the show title containing the performer's name whenever the performer is billed in the title. Precision is now measured over the 36 form-bearing hosts and the archived attributed queries BEFORE the observe run and published BESIDE the demotion rate, not after. A token match answered only by the show title or by the item's own venue/ticketing host is explicitly excluded as evidence. The guard you asked for by name is in, seen to fail: venue host plus show-title-verbatim query asserting `incomplete` carrying both `canonicalDomainNeverFetched` and `searchNotEvidenced`. And every widening in the guess set is re-measured for precision before adoption rather than only widened.

18. L46 (contradictionPriorResultRaw and contradictionPriorEmptyReasonRaw are written and read by nothing) - ACCEPTED, AND I TOOK ONE OF EACH OF YOUR TWO CLOSES. `contradictionPriorResultRaw` SURVIVES with its consumer named in the same change: the 5.2 trend line, which needs to know WHICH negative verdict was contradicted, since `no_email_found` and `social_only` are different findings about the hunt. `contradictionPriorEmptyReasonRaw` is DELETED, because it has no such consumer and the prior reason lives in the dated JSON the reverse migration already reads. Both are stated under the `reader` heading, 5.2's trend-line paragraph now names the field explicitly, and the cross-cutting rules list records the deletion beside `roleOnListing` so the same discipline reads as applied consistently rather than applied once and abandoned.

## Why this option won

Correctness (40) plus proof robustness (25) is 65 of the 100 points, and only one option addresses both at their root. The brief's own framing says a proof that witnesses fetches but not judgement scores badly, and that rules out any design where the safety net is a call log: a fetch record can show that bethanylivers.com was fetched and misread, but it can never show that Aidan S. Wells was skipped, because nothing anywhere declared he was expected. targets[] is the missing declaration, and once it exists a coverage check is deterministic Swift over the app's own list rather than the run's account of itself, which is the rule PrepImporter already follows (#2265/#2269). That makes targets-and-evidence the only option that ends with one hunt and a reason to trust it.

I verified its correctness lever rather than taking it on trust: PrepImporter.swift:105 stamps reachabilityProbedAt unconditionally in the probe branch against a 90-day freshness window, so today there are exactly two outcomes and both start a lockout. A run that was killed by the stuck-tool watchdog, rate-limited or simply thin is written down as a firm negative on a show with a live date. `incomplete` makes that state unrecordable, which is what constraint 1 actually asks for (make the wrong verdict impossible to store, not merely rarer). Neither rival removes it, and a model upgrade makes it worse, since an opus run that dies mid-chunk writes the same lockout at higher cost.

The red team against it is correct and I confirmed it: ListingOrganiser's own header states that everything looser than its two narrow shapes deliberately stays with the model, and the failing card is the looser case. That trims the promise, it does not break it, because the parser abstains by design (failure mode is today's behaviour, not a new wrong answer) and the org-level half is already shipped and proven by #2983. Score it as a floor being raised across the top templates, not as a general solution, and say so in the plan rather than discovering it later. The objection I did NOT see answered is the more serious one and becomes a required part of the design: coverage-against-targets proves a target was considered, not that the search was exhausted before a MISS was accepted.

deterministic-first is free and holds the best-evidenced diagnosis on the board, and I confirmed both anchors in the source: reachabilityResultFromRecipients gates on isSendablePending, which folds in a calendar clash, a blank subject line and two lint judgements, so a show holding published addresses badges as unreachable for reasons that are not about reachability at all; and the emptyReason count is fed a send-contaminated number while the verdict beside it counts forms. Those are permanent-cost defects that every option inherits, so they are grafted as prerequisite work, not discarded. It loses as an architecture because it scores zero on the 25-point proof criterion by design, keeps two hunts sharing one runbook (the existing L263 failure), and defends that with a rescue rate its own source disclaims for 30 of 31 cases (L203).

measure-then-buy-depth is the only non-free option and does not earn it. Both instruments it is buying are broken for the question asked: the eval harness forbids tool use by construction and so cannot test a tool-choice failure (L246), and the chunk-size arm is confounded by #3007's whole-chunk kill, which would produce the same signal for a different cause. Its diagnostics are valuable and are grafted; its gate is not one I would spend on.

Cost note: the winner is free and roughly usage-neutral, so the cheapest-clears-the-bar rule is satisfied without argument. Build effort played no part; targets-and-evidence is the longest build here and wins anyway.

## Overruled dissent

1. The straightforward shape (upgrade the reachability check to opus, delete Prep's hunt, done) was argued for on the grounds that tonight's failure is a model-quality failure. Overruled: the check that failed used 692 of an allowance of 1620 web calls with overCap false, so budget was not the constraint, and the billed Music Director appears nowhere in its output, which is a targeting failure no tier upgrade addresses. A better model on the same contract still leaves nothing anywhere declaring who was supposed to be found.
1. A dissent held that proof-of-work IS sufficient, since a fetch record plus a coverage rule catches under-searching. Overruled, and written into the plan as a stated limit rather than a design detail: the address the Prep run found is published on the front page of a domain a fetch record would show as fetched, so the receipt cannot distinguish reading a page from opening it. Phase 4.4 says so plainly because Dan chose the mechanism and is owed the case against it.
1. One-show-per-stream was proposed for clean attribution and is deleted rather than deferred. The splitter makes min(items, MAX_PARALLEL) chunks with MAX_PARALLEL defaulting to 10, and prep-run.sh:395-405 records why ten is a ceiling; a 97-item queue would need 97 concurrent web-fetching processes. Attribution is solved by the event-derived sidecar instead, and interleaving keeps the loss-correlation benefit.
1. A dissent wanted the fit-score consequence of moving contactTierFromRecipients onto hasAnyRoute handled by leaving the tier on isSendablePending. Overruled: Prospect.swift:251-252 declares the badge-and-score-from-one-list invariant explicitly, and splitting the pair is the same L16 defect this phase exists to remove. The score movement is escalated to Dan and measured per direction instead of being avoided.
1. A dissent argued the standing contradiction count was good enough as the Phase 6 gate, since it is cheap and already has three honest states. Overruled on the store's own numbers: 43 of 209 checked shows were never prepped, the negatives are exactly the ones a keep decision suppresses, and no arrangement of measuring/DORMANT/NOT REPORTED separates a low rate from a suppressed one. The count survives as a labelled trend line; the gate is a two-armed experiment.

## Ideal versus doable

The ideal version closes the judgement gap rather than bounding it: a second, independent reading of the same pages by a different reader, disagreeing per target, so that "chose the wrong canonical domain" and "read the page and missed the address" are detectable rather than merely unprovable. That is what the current second hunt accidentally provides, and this plan removes it. It is deferred because a real judgement check means either keeping a second full hunt (the thing Dan has decided to remove, and which fact F prices at roughly 375 hunts for 20 emails) or building an adjudicator that re-reads fetched pages, which needs the archived page bodies this plan does not capture and would double the per-show cost for a benefit nobody has measured. The Phase 5.2 experiment is the affordable substitute: it buys one bounded, two-armed comparison over a fixed backlog instead of a permanent second reader, and it is honest that what remains after Phase 6 is a trend line rather than an instrument. The second deferral is the cheap-first-pass-at-triage shape (a canonical-domain existence probe at triage, the full hunt at keep-time), which the 209-to-20 ratio argues for directly; it is filed as its own issue because it changes what Dan is choosing between at triage, which is a product decision rather than a refactor. The third is capturing fetched page bodies alongside the event streams, which would make a post-hoc read-quality audit possible; deferred on retention grounds until the event archive's real size is observed in practice.

---

# One contact hunt, with declared targets and evidence that outlives the run

Revision 3, 2026-08-30. Revision 2 closed seven lessons violations and one reality-check item. **Revision 3 closes nine broken claims and nine further lessons violations**, all of them re-verified against the current tree and a WAL inclusive copy of the live store. Changes made in this revision are marked **[R3]**; revision 2's are still marked **[R2]**.

**No real person's name and no real host appears anywhere in this document.** Every finding is stated as a shape and a count. This repository is PUBLIC (`gh repo view --json visibility` answers PUBLIC, AGENTS.md, checked 2026-08-29) and this plan is posted to a GitHub Discussion, so the plan document is itself a public artifact. #2833 and #2839/#3110 are what this repo already paid for the other habit. The redaction happens **here, before publication**, not as a step the implementer is trusted to remember (L155, L230).

## What this plan does, in one paragraph

Overture hunts for a show's contacts twice, and the cheap hunt is measurably unreliable. The diagnosis is not primarily model quality: **nothing anywhere declares who was supposed to be found**, so a dropped Music Director leaves no trace, "did not find" cannot be told from "did not look", and per-party proof is unimplementable. The plan makes the app name the parties (`PrepQueue` v14 `targets[]`), makes the run answer **per target** with the URLs it searched and fetched (`PrepResults` v12), makes a target with no answer a **MISS with its own outcome** rather than silence, and adds a third verdict, `incomplete`, that an unfinished search lands in and that **cannot start a 90 day lockout**. The second hunt is removed **last**, gated not on a receipt and not on a rate drawn from Dan's ordinary workflow, but on a **two armed experiment over a population the negative verdict cannot suppress**.

Two things come first, because the winner's own architecture inherits them otherwise: a contaminated reachability predicate that badges reachable shows as unreachable, and a verdict overwrite path that the second hunt is currently the only repair for. Removing the second hunt while leaving that overwrite open would be strictly worse than today.

**[R2] And one thing comes before all of it: the repair destroys the evidence the whole feature is argued from.** The contradiction between a stored negative verdict and a stored route is a fact nothing in this system ever recorded deliberately. It is the entire evidence base for #3345, and Phase 0.3 was ordered so that the fix erased it before Phase 5 could measure anything over it (L277). Phase 0.3 now stamps a durable marker in the same pass that snapshots, and the Phase 5.2 gate population is re-stated and re-measured against what actually survives.

**[R3] And a correction to what "the repair" is worth, which changes the shape of Phase 0 rather than only its numbers.** Revision 2 claimed 0.1 plus 0.3 recovers 28 live dated shows for free. **It does not, because the badge already re-derives.** `QueueItem.reachabilityResult` is fed `p.reachabilityResultAsHeld` (`QueueView+Model.swift:2716`), which recomputes from current recipients on every read for any unsent, unbooked show (`Prospect.swift:386-390`). So the routed rows are not written off on screen at all. What the stored verdict still drives is the RANKER (`contactRouteForScoring`), and moving that is a decision Dan has already reversed once. Phase 0.3 is therefore re-scoped and re-escalated rather than re-sized.

---

## Verified anchors (re-checked 2026-08-30 against the current tree and a WAL inclusive copy of the live store)

| Claim | Verified at |
|---|---|
| `reachabilityResultFromRecipients` is a **five way cascade**, and only its FIRST arm gates on `isSendablePending` | `mac/Overture/Domain/Prospect.swift:291-307` |
| `contactTierFromRecipients` **also** filters on `isSendablePending`, and its comment binds it to the predicate above | `Prospect.swift:251-252`, `:260-261` |
| That tier feeds `contactTierForScoring` then `ClassificationOverride` then `ContactScoreAdjustment.settle` | `Prospect.swift:266-268`; `ClassificationOverride.swift:35,37`; `ContactScoreAdjustment.swift:18,23` |
| `contactRouteForScoring` reads the **stored** verdict, not the recipient derived one, and its comment records Dan's reversal of 2026-08-13 in terms | `Prospect.swift:271-289` |
| **[R3]** The BADGE reads `reachabilityResultAsHeld`, which **re-derives from current recipients** for any unsent, unbooked show | `QueueView+Model.swift:2716`; `Prospect.swift:386-390` |
| `isSendablePending` folds in a calendar clash, a blank subject, two lint judgements, `pausedByReply` and `sendState == .pending` | `Recipient.swift:671-696` |
| `isHeldByAGuard` names all four holds (venue, press, duplicate, another person's) | `Recipient.swift:646-652` |
| **[R3]** A FIFTH hold, `isHeldDownToUnverified`, is in **neither** predicate and drives only warnings | `Recipient.swift:185`; readers `DraftReviewView.swift:234`, `QueueView+Model.swift:618`, `:626` |
| **[R3]** The hand pitch control gates on the **verdict**, so it moves when the cascade moves | `FormOutreach.swift:180-181` |
| `emptyReason` is fed `recipients.filter(\.isSendablePending).count` while the verdict beside it counts forms | `PrepImporter.swift:139` |
| The probe branch stamps `reachabilityProbedAt` **unconditionally**, found or not | `PrepImporter.swift:105` |
| The empty branch decodes `emptyReason` through `EmptyReason.init(rawValue:)` and **drops** an unrecognised value on purpose | `PrepImporter.swift:148` |
| The Prep side correction this plan removes in Phase 6 | `PrepImporter.swift:189-191` |
| `ingestContacts` never deletes a recipient: it matches or appends, and the empty branch never reaches it | `PrepImporter.swift:277` onward |
| **[R3]** `ContactFormResultMigration` is a LIVE launch migration reading the very predicate 0.1 changes, and its comment records Dan's decision of 2026-07-27 | `ContactFormResultMigration.swift:12-16`, `:26` |
| Freshness window is 90 days | `Reachability.swift:123` |
| `markProbed`'s floor is already conditional (#1623): first settle branch writes both fields, re settle branch fills only nils | `PrepQueueService.swift:417`, `:418-419`, `:421-427` |
| `markProbed` clears `reachabilityUnansweredAt` **and** `reachabilityRecheckRequestedAt` unconditionally for every answered key | `PrepQueueService.swift:433`, `:437` |
| Candidacy: `probeIsWorthOffering` AND `!hasFreshReachabilityAnswer`, with **four** call sites | `QueueView+Model.swift:2224` (decl), called at `:2215`, `:2268`, `:2291`, `:2335` |
| **[R2]** "A check missed this" has **FIVE** call sites in three variants (see 0.2) | enumerated in 0.2, each re-verified 2026-08-30 |
| **[R3]** `Reachability.recheckState` is an INDEPENDENT offer path that already takes `isStillOpen` as a caller supplied gate | `Reachability.swift:165-193` |
| `ProbeResult` has exactly five cases, no `incomplete`; the cost of a sixth is stated in the source | `Reachability.swift:205-221`, `:223-232` |
| `EmptyReason` is a String backed, `CaseIterable` enum of **eight** cases, each with a distinct badge sentence and a distinct help sentence, both produced by an **exhaustive switch that names `nil` explicitly** | decl `Reachability.swift:238-303`; badge switch `:548` region; help switch `:562` region; `EmptyAnswerReport.swift:74` |
| **[R3]** `EmptyAnswerReport`'s own header says "one of **nine** reasons" while the enum has eight and its exhaustive switch handles eight | `EmptyAnswerReport.swift:5`, `:69-81` |
| **[R3]** `EmptyAnswerReport.make` counts every stored reason with **no verdict test at all** | `EmptyAnswerReport.swift:41-46` |
| **[R3]** The empty answer sentence renders ONLY under the `.noEmailFound` badge | `ProspectRowView.swift:643-654` |
| `EmptyReason.routeNamedButNotSupplied` is described as the only one that says the search did not finish | `Reachability.swift:287` |
| `PrepResults.WebCalls` is counts only. It does **not** decode `byRoute` or `streams`. It **does** decode `deniedByRoute` (#2387) | `PrepResults.swift:24-66`, `:41` |
| A newer results version silently locks a whole batch out for about 90 days | `PrepResults.swift:211-221`; gate at `:227-233`; `supportedVersion = 11` at `:227` |
| **[R3]** On disk today: `overture-check-results.json` is **version 6**, `overture-prep-results.json` is **version 11** | both read 2026-08-30 |
| `PrepContact` already carries `var role: String?` | `PrepResults.swift:147` |
| `webCalls` completeness: `eventFiles.length > 0 && reported === eventFiles.length` | `mac/scripts/lib/models.sh:285` |
| `runCost` completeness: `envelopes.length === eventFiles.length` | `mac/scripts/lib/models.sh:355` |
| Chunks are sliced contiguously; the shared splitter is called by two runners | `scout-parallel.sh:26`, `:39`; callers `prep-run.sh:406`, `scout-extract-run.sh:300` |
| Chunking happens only on the probe path; the merger's version is the literal `6` in two places | `prep-run.sh:394-408`, `:489`; literals `:237`, `:504` |
| `OVERTURE_PREP_MAX_PARALLEL` defaults to 10, and the source says why ten is a ceiling | `prep-run.sh:120`, `:395-405` |
| Event streams are deliberately **not** archived; only queue and results are, and the file's own justification quotes **14 KB** a pair and **under half a megabyte** for thirty | `PrepRunArchive.swift:14-15`, `:43-44`, `:48` |
| Event files sit at fixed per slot paths, so the next run overwrites them | `RunSlot.swift:48`, `:53` |
| Archive `keep` lives on the slot, **one number per slot**, and #2760's precedent is a **separate directory per consumer** | `RunSlot.swift:70-83` |
| **[R3]** `DatedFolderRotation.prune` rotates whole **folders**, newest N by name, one `keep` per directory | `DatedFolderRotation.swift`, `prune(in:keep:)` |
| **[R2]** Event streams DO record `WebSearch` tool_use with its `input.query`, alongside `WebFetch` | measured in `check-run-events.chunk-3.jsonl` 2026-08-30: 9 `WebSearch`, 6 `WebFetch`, 1 `Write` |
| **[R2]** `OrgReachabilityAnswer` is a stored `@Model`; its result derives from `p.reachabilityResultFromRecipients` and its emails from `isSendablePending` | `OrgReachabilityAnswer.swift:16-40`, `:121`, `:125` |
| **[R2]** The ledger is read by `inheritedAnswers` and fanned onto sibling shows | `QueueView+Model.swift:2495`, `:2567` |
| `Recipient` carries **no discovery timestamp of any kind** | `.schema ZRECIPIENT`; `Recipient.swift` |
| `ListingOrganiser`'s own header rules out everything looser than two narrow shapes | `ListingOrganiser.swift:23-29` |
| `isSendablePending` appears on 28 lines across 11 files | `grep -rn "isSendablePending" mac/Overture` |
| The check is user triggered, not scheduled | `RootView.swift:1428`, wired at `:579` |
| **[R3]** `RunCoverage` is per show and fail closed. It returns a **three case enum** whose third case, `.unreadable`, is a refusal; the only `throws` in the file is `write` | `RunCoverage.swift:18-40`, `:82`; caller `PrepQueueService.swift:996` |
| **[R3]** Runbook section 1 is lines 241-679; the canonical `firstnamelastname.com` guess is required at **`:307`** and **`:495`** | `docs/prep-runbook.md` |
| **[R3]** `scripts/find-tests-naming.sh` searches **only** `mac/OvertureTests` and `mac/OvertureHostedTests` | `find-tests-naming.sh:63` (`ROOT_LIST`) |
| **[R3]** The runbook's judgement rules are guarded in **TypeScript**, by literal presence patterns | `src/lib/prepRunbookRules.ts:20-37`; `prepRunbookRules.test.ts`; `prepEval.ts`; `fixtures/prep-eval/` |
| The runbook instructs a full rewrite of the results file after EACH item (#1023) | `docs/prep-runbook.md`, "Write incrementally as you go" |

### **[R3]** Corrections to earlier drafts, carried into the plan text

1. **`WebCalls` is counts only.** Per item URLs live only in `<slot>-run-events.chunk-N.jsonl`, at a fixed path the next run overwrites. That is why Phase 1 exists and precedes anything that leans on evidence.
2. **The predicate rewire is not one substitution at three sites.** `reachabilityResultFromRecipients` is a five way cascade and **only its first arm is address only**. Substituting a route bearing predicate there would report every form only and social only show as `emailFound`. 0.1 now ships **two** predicates and says which goes where.
3. **There is no version cushion on the Prep path, and the check path has five.** The live check results file is version **6**; the live prep results file is version **11**, exactly `supportedVersion`. An equality assertion across merger, runbook and app is **false today** and forcing it green by bumping `prep-run.sh`'s literals is the lockout. 4.0 restates the fixture as an inequality.
4. **The badge already re-derives**, so the free recovery is 7 to 11 shows, not 28, and the stored verdict's live consequence is the ranker.
5. **`RunCoverage` refuses by returning `.unreadable`**, not by throwing.
6. **`EmptyAnswerReport`'s header says nine reasons and there are eight**, which matters because this plan cites that file as the model for exhaustiveness. Correct it in 0.2.1's change.

### One correction to a code comment this plan reasons beside

`hasFreshReachabilityAnswer` carries the parenthetical "The ledger holds 0 rows on the live store as of 2026-08-07". **It holds 60 rows today.** The comment is load bearing in the argument for why a re-check does not touch the ledger, and a stale count sitting inside that argument makes it read as settled when the situation it was written before now exists (L244, L210). Correct it in Phase 0.3, and state the correction in the PR body.

### The live store measurements this plan is sized by (2026-08-30, store plus `-wal` plus `-shm` copied first)

**Every number below is a SQL measurement taken beside the app, and the plan treats that as provisional (L107).** #2035/#2517 is this repo's own instance: a funnel counted by SQL said 81 where the shipped rule said 66. **[R3] Five figures quoted in revision 2 did not reproduce and are corrected here; where a corrected figure is still SQL, it is still provisional.**

- 1,126 prospects. 209 have had a check spent on them. 20 have ever been sent. 166 of the 209 later hold a recipient, so **43 checked shows were never prepped at all**.
- Verdicts: 917 nil, **49 `no_email_found`**, 99 `email_found`, 31 `social_only`, 26 `contact_form_only`, 4 `weak_contact_only`.
- `emptyReason`: 37 `named_but_no_route`, 29 `only_social_profile`, 20 `nothing_published`, 8 `only_venue_contact`, 8 `no_one_identified`, 2 `only_press_contact`, 1 `unconfirmed_social_profile`, and **0 `route_named_but_not_supplied`**. **105 rows carry a reason.**
- Of the 37 `named_but_no_route` rows, **31 hold a route by the loose predicate**.
- **[R3] The same question through a guard aware predicate (unguarded address, or a form URL that is not a known social host), which is the closest SQL can get to the shipped rule: 27 of the 37 hold a route, and 10 do not.** Revision 2 said 28 and 9. The whole negative or weak population is **110 rows**, of which **33 hold a guard aware route and 77 do not**. Revision 2 said 34 and 76. All four figures must be recomputed through the shipped Swift predicate before Phase 5 ships.
- **[R3] What the badge actually shows today, which is the figure the free recovery claim has to be drawn from.** Because `reachabilityResultAsHeld` re-derives, the 27 routed `named_but_no_route` rows are **not** written off on screen: 19 already badge `contactFormOnly`, 4 `socialOnly`, 4 `weakContactOnly`. Only **49** rows carry a `no_email_found` verdict at all, and just **4** of those hold a guard aware route, **3** of them with a date still ahead. Measured directly, the rows whose live badge suppresses an existing unguarded address are **11**, and that is a **lower bound**: SQL cannot see the subject, lint and greeting holds that `isSendablePending` also folds in.
- **[R3] The organisation ledger holds 60 rows**: 32 `email_found`, 12 `no_email_found`, 9 `social_only`, 5 `contact_form_only`, 2 `weak_contact_only`. **Seven of the 28 negative or weak ledger rows have a source prospect that holds a guard aware route.** **Three ledger rows name a `sourceNaturalKey` no prospect in the store carries**, which the reverse migration has to handle rather than crash on.
- 7 prospects carry a negative or weak verdict while holding an unguarded pending email. **6 of the 7** are caused by an uncleared calendar conflict. 21 hold such an email **and** an open conflict, so are one re-derivation away from a wrong verdict; 5 of those currently read `email_found` and would be actively downgraded.
- `showListing` on the archived 97 item check queue: present on 58 of 97. 50 of the 58 carry an HTML entity (`&nbsp;` on 49, `&amp;` on 44; no numeric reference appeared, which is not proof none ever will). **Billing tokens, matched case INSENSITIVELY with word boundaries:** any of {Featuring|Starring, Music Director, Director|Directed by, Producer|Produced by, Choreograph, Conductor, Curator} on **27 of 97**; Featuring|Starring 18, Director family 12, Music Director 7, **Producer family 4** (revision 2 said 5; **4 is the count in BOTH the case insensitive and the case sensitive matching**), Choreograph 1, Conductor 0, Curator 0. **Case SENSITIVE matching over the same corpus gives 20 / 13 / 10 / 4 / 5 / 0.** A parser matching case insensitively on a `Featuring` token carries a different precision risk from one matching the billed capitalisation, so the parser declares which it does and its fixture covers both.
- Source host concentration on that queue: the top host is 43 of 97, the top two are 57, the top five are 77.
- **[R3] Host shape on the `named_but_no_route` rows, corrected.** Revision 2 said "46 named route bearing recipients splitting 25 / 1 / 18 / 2". The measurement is **51 recipient rows** on those prospects: **36 carry a form URL**, splitting **19 on a host containing two name tokens, 1 on a host containing one, 16 on a host containing none** (11 of the 16 being one social platform); and **15 carry an address and no URL at all**. Revision 2's "2 carry an address and no URL" was off by an order of magnitude. Read as the canonical guess question: **19 of the 36 form bearing hosts carry a name token and 16 carry none**, with the single token host counted with the name bearing group. **The coin flip CONCLUSION survives; the numbers it was drawn from did not**, which is exactly why 4.3 is stated as a negative test.

---

## Phase 0: Split the predicate, stop the verdict damage, record the evidence, take the free recovery

Ships alone. Every later phase inherits it.

### 0.1 **[R3]** TWO predicates, not one, because the cascade is five way

Two different questions are asked through one predicate:

- **"Does a way in exist?"** A fact about research. What reachability, the tier, the org ledger, the empty answer report and the hand pitch control need.
- **"May this go out right now?"** A fact about the send. What the send path needs, and it correctly folds in a calendar clash (#901), a missing subject (#2052), the lint holds (#2545), `pausedByReply` and `sendState == .pending`.

**Revision 2 answered that with a single `hasAnyRoute` and would have collapsed the verdict cascade.** `reachabilityResultFromRecipients` (`Prospect.swift:291-307`) is a five way cascade: `isSendablePending` gives `emailFound`; `isHeldByAGuard` gives `weakContactOnly`; `usableContactFormURLs` gives `contactFormOnly`; `socialRouteURLs` gives `socialOnly`; else `noEmailFound`. A predicate defined as "an unguarded address **or** a surviving form URL" substituted into the FIRST arm makes every form only and social only show report `emailFound`, which then drives `OrgReachabilityAnswer.foundEmails` (empty, the very guard 0.1 adds), the send path, the ranker's route points, and the hand pitch control. So:

Add to `Recipient`:

```
// Does an ADDRESS exist that is not held by a research guard. Deliberately NOT isSendablePending:
// that answers whether this may go out RIGHT NOW and folds in a calendar clash (#901), a blank
// subject (#2052), two lint judgements (#2545), pausedByReply and this row's send state, none of
// which are facts about reachability. A show holding a published address badged "No email found"
// because Dan blocked the night is the defect.
//
// ADDRESS ONLY, on purpose. It is substituted into the FIRST arm of the verdict cascade, and a
// route bearing predicate there would report every form-only and social-only show as emailFound.
var hasUnguardedAddress: Bool { email?.isEmpty == false && !isHeldByAGuard }
```

and to `Prospect`:

```
// Does a way in of ANY kind exist. Derived from the corrected cascade rather than reimplemented
// beside it, so there is one definition of "reachable" and not two that can drift (L263).
var hasAnyRoute: Bool { reachabilityResultFromRecipients != .noEmailFound }
```

**[R3] The fifth hold state, decided here rather than left to happen.** `Recipient.isHeldDownToUnverified` (`Recipient.swift:185`) is in **neither** `isHeldByAGuard` nor `isSendablePending`; it drives warnings only, in `DraftReviewView.swift:234` and `QueueView+Model.swift:618,626`. So `hasUnguardedAddress` treats a held down address as a route. **That matches today's behaviour and is the right answer** (the hold down describes confidence in who is on the end, which the card already warns about, and withholding the route as well would silently remove a show Dan can still judge in seconds). It is written down, noted in the predicate's own comment, and carries a test asserting a held down address still yields `emailFound`, so the next person to read `isHeldByAGuard`'s "all the guards" comment does not conclude a case was overlooked.

**[R3] The rewire, site by site, with the predicate each site takes.**

| # | Site | Predicate | Why |
|---|---|---|---|
| 1 | `Prospect.swift:292`, the `emailFound` arm | `hasUnguardedAddress` | address only; a route bearing predicate here collapses the cascade |
| 2 | `Prospect.swift:260-261`, `contactTierFromRecipients` | `hasUnguardedAddress` | the tier is `ContactTier.best` over addresses, and its own comment at `:251-252` says a guard held address does not set it |
| 3 | `PrepImporter.swift:139`, the `emptyReason` count | `hasUnguardedAddress` per recipient | it counts usable RECIPIENTS, which has always meant addresses |
| 4 | `OrgReachabilityAnswer.swift:125`, `foundEmails` | `hasUnguardedAddress` | it is a list of addresses, and the verdict at `:121` is now address led |

`hasAnyRoute` is **not** substituted into any of those four. It exists for the question "is there a way in at all", which 0.2's refusal, 0.3's marker and 0.5's residual report all ask, and it is derived from the cascade rather than beside it.

**Decision, taken here rather than left to a PR body: site 2 moves too.** The invariant binding the tier to the verdict is right; the predicate both halves shared was wrong. Two consequences:

- `contactTierForScoring` feeds `ClassificationOverride.rescored` and `ContactScoreAdjustment.settle`, whose guard compares the **pair** (route, tier).
- `contactRouteForScoring` reads the **stored** verdict, so the route half only moves if 0.3 writes it. The tier half moves the instant the predicate changes. So on the first launch after 0.1, rows holding a conflict held address acquire a tier where they had nil, `settle` sees a changed pair, and their fit score moves.

That is a real change to what ranks where, so it is **escalated** (decision 2) and **measured**: the 0.3 migration report gives fit score movements per direction, printed before anything is written.

#### **[R3] The second derived enumeration, which revision 2 wrote from memory (L30, and the repo's PR rule 3)**

Revision 2 enumerated the 28 `isSendablePending` lines mechanically and then wrote the consumers of the predicates it actually changes the MEANING of from memory, naming only `OrgReachabilityAnswer`. Derived from `grep -rn "reachabilityResultFromRecipients\|contactTierFromRecipients\|contactTierForScoring\|contactRouteForScoring" mac/Overture`, there are **six consumers outside `Prospect.swift`**, and the PR body carries all of them under the `sibling` heading with a one line verdict each:

| Site | Verdict |
|---|---|
| `PrepImporter.swift:112`, `:122` | writes the re-derived verdict on ingest. Moves with the cascade by design. |
| `PrepImporter.swift:190` | the Prep side correction Phase 6 deletes. Moves with the cascade until then. |
| `DebugStaging.swift:309`, `:310`, `:367` | debug fixtures. Move with the cascade; assert the staged rows still read as intended. |
| `OrgReachabilityAnswer.swift:121` | the ledger's verdict. Moves with the cascade, and 0.3 re-derives the stored rows. |
| `ContactFormResultMigration.swift:26` | **a live launch migration reading this predicate.** See 0.3. |
| **`FormOutreach.swift:180-181`** | **the hand pitch control, and revision 2 named the wrong line here.** |

**[R3] The hand pitch control, decided rather than discovered.** `FormOutreach.swift:180-181` gates the control on `verdict == .contactFormOnly || verdict == .socialOnly`. Under the corrected cascade, a row whose only address is held by an uncleared calendar conflict moves from `contactFormOnly` to `emailFound`, and **the hand pitch control silently disappears from rows that carry it today**. That is correct on the file's own stated scope, which is Dan's from 2026-07-28: forms only, and only where the form is the ONLY way through, because a show with a working address goes through Overture's own send path. A blocked night is a temporary send hold, not the absence of an address. But it is a control vanishing from a card, which no existing assertion covers, so it ships with:

- **Guard seen to fail:** a fixture holding a published address plus an open conflict plus a usable form URL asserts `FormPitch.state(of:) == .unavailable` and that the row's verdict is `.emailFound`. Mutate the gate to include `.emailFound` and record the exact failure text. A second mutation reverts `hasUnguardedAddress` to `isSendablePending` and asserts the control reappears, which is the behaviour being deliberately removed.
- The count of live rows that lose the control, measured before the change ships and reported in the PR body.

`grep -rn "isSendablePending" mac/Overture` returns 28 lines across 11 files. **Enumerate all 28 in the PR body with a one line verdict each**, derived from the grep, not from memory (L30, L96). `FormOutreach.swift:234` (`if !recipients.contains(where: \.isSendablePending) { status = .contacted }`) **stays**: that is a send path use.

**Other guards that must be seen to fail.**

- A prospect with a published address plus `conflictOpen = true` asserts `reachabilityResultFromRecipients == .emailFound`. Prove with `scripts/mutate.sh --at 'var hasUnguardedAddress' mac/Overture/Domain/Recipient.swift '<expression reverting it to isSendablePending>' -only-testing:OvertureTests/<Suite>`, `--at` **first** and literal, and record the exact failure text.
- **[R3] A cascade preservation test**, over one fixture per arm: a form only show still reads `contactFormOnly`, a social only show still reads `socialOnly`, a guard held show still reads `weakContactOnly`, an empty show still reads `noEmailFound`. Mutate the first arm to take `hasAnyRoute` and assert three of the four go red. This is the guard for the defect revision 2 shipped.
- The verdict, the tier and the `emptyReason` count all derive from the **same** address predicate, written as one assertion over the trio so a future change to one alone goes red (L63, L70).
- Whenever an `OrgReachabilityAnswer` row reads `emailFound`, its `foundEmails` is non-empty. Seen to fail first against a conflict held fixture. This move changes the address set on all **32** `email_found` ledger rows, which is the second of the two reasons the ledger is an enumerated subject of the 0.3 migration.

### 0.2 A barren re-check may not destroy the verdict standing over a live route

**What is destroyed is not the route.** `ingestContacts` never deletes a recipient, and the empty branch never reaches it. A guard written as "the recipient survived" passes today and always will (L1, L151).

What a barren re-check destroys is **the verdict, the reason, and the freshness clock**: `markProbed` writes `reachabilityProbedAt = now` and `reachabilityResult = .noEmailFound` in its first settle branch (`PrepQueueService.swift:418-419`); `PrepImporter.swift:105` stamps `reachabilityProbedAt` unconditionally; `PrepImporter.swift:148` writes the empty reason unconditionally. So a show holding a published address, re-checked by a run that came home empty, has its stored verdict overwritten and no way to ask again for three months. Today the Prep hunt is the only repair (`PrepImporter.swift:189-191`), and this plan removes it, so the refusal has to land before the repair path goes (L5).

#### FIVE call sites, not four, and they land before the new writer

Re-verified against the current tree on 2026-08-30, the five are:

| # | Site | Variant |
|---|---|---|
| 1 | `QueueView+Model.swift:2270-2271` | shared `Reachability.wasMissedByACheck(probedAt:unansweredAt:now:)` |
| 2 | `ProspectRowView.swift:1075-1077` | shared `Reachability.wasMissedByACheck(...)` |
| 3 | `QueueView+Model.swift:357-358` | inline weaker: `unansweredAt != nil && !probeIsStale(...)`, **no `probedAt` test** |
| 4 | `QueueView+Model.swift:1784-1786` | inline weaker: same shape, inside the `previouslyMissed` filter, **no `probedAt` test** |
| 5 | `QueueView.swift:450` | weakest: `previouslyMissed: item.reachabilityUnansweredAt != nil`, **no staleness and no `probedAt`** |

`Reachability.swift:154-157` already claims one shared definition exists; the file asserting one definition while the code holds three is itself the argument for doing this first.

**Force all five through `Reachability.wasMissedByACheck`, in the same change, before the incomplete fields are added.** The PR body enumerates all five with their file and line, under the `sibling` heading, **derived from `grep -rn "reachabilityUnansweredAt\|wasMissedByACheck\|previouslyMissed" mac/Overture`** rather than from this table (L96), and because these line numbers will have moved.

**Guard seen to fail:** mutate site 5 back to the bare `!= nil` form and assert the bulk count and the card's offer disagree. Record the failure text.

#### The incomplete fields

In the importer's empty branch and in `markProbed`'s first settle branch, when `p.hasAnyRoute` is true, record the fact as **incomplete** instead: leave `reachabilityResult` and `reachabilityEmptyReason` as they were, do **not** stamp `reachabilityProbedAt`, and write the fields 0.2.1 specifies.

**Brought forward from Phase 2 deliberately, and `reachabilityUnansweredAt` is deliberately NOT reused (L55, L16, L46).** Reusing it would add a second writer to a field whose five readers were written against one code path, and `markProbed:433` clears it unconditionally for every answered key, and a row the run refused **is** an answered key.

`markProbed` also clears `reachabilityRecheckRequestedAt` unconditionally at `PrepQueueService.swift:437`. A row Dan explicitly pressed "Check again" on, which comes back barren over a live route and is refused into the incomplete state, would have its request consumed by the same pass, and with `probedAt` not advanced, `unansweredAt` cleared and the request cleared, `Reachability.recheckState` returns `.notOffered` until Phase 2's badge ships. **The refusal path therefore also declines to clear `reachabilityRecheckRequestedAt`**, with its own test in both directions.

#### 0.2.1 **[R3]** The reason is a typed vocabulary, stored as a SET, with a counter per reason

Revision 2 declared one `reachabilityIncompleteReasonRaw: String?` and one `reachabilityIncompleteCount: Int`, then hung three separate enforcement decisions on rates those fields structurally cannot support. **A single row can fail several of these rules at once**: a run can both never fetch the canonical domain and never answer the billed lead first, and a barren re-check over a live route can also be a run the #3007 watchdog killed. One field holds one reason, so whichever writer runs last erases the others, and one counter cannot say how many of a row's N failures were `canonicalDomainNeverFetched` versus `searchNotEvidenced`. That is L53 exactly: two independent checks sharing one status field, where one check's pass silently erases the other's failure, so the alert that depends on it can never reach its threshold.

```
extension Reachability {
    enum IncompleteReason: String, Equatable, Sendable, CaseIterable {
        case barrenOverALiveRoute        = "barren_over_a_live_route"
        case targetNotAnswered           = "target_not_answered"
        case canonicalDomainNeverFetched = "canonical_domain_never_fetched"
        case searchNotEvidenced          = "search_not_evidenced"
        case evidenceUnmeasured          = "evidence_unmeasured"
        case claimUnsupported            = "claim_unsupported"
        case routeNamedButNotSupplied    = "route_named_but_not_supplied"
        case billedLeadNotAnsweredFirst  = "billed_lead_not_answered_first"
        case runDidNotFinish             = "run_did_not_finish"
    }
}
```

Stored as:

```
var reachabilityIncompleteAt: Date? = nil
// A SET, newline joined, decoded per line through init(rawValue:) dropping unknowns.
var reachabilityIncompleteReasonsRaw: String? = nil
// Per reason, JSON keyed by rawValue, decoded through init(rawValue:) dropping unknown keys, so
// every rule owns its own counter and can be judged against its own bar (L53, L517).
var reachabilityIncompleteCountsRaw: String? = nil
// How many RUNS came back incomplete on this row, which is what the card line reports. Distinct
// from the sum of the per reason counts, because one run can fire several reasons at once and a
// sum would overstate how often this show has been paid for.
var reachabilityIncompleteRunCount: Int = 0
```

Every case has a **writer**, named here so none is a value nothing produces (L90, and the repo's PR rule 1):

| Case | Writer | Ships in |
|---|---|---|
| `barrenOverALiveRoute` | 0.2's shared refusal helper | 0.2 |
| `targetNotAnswered` | 4.2's coverage MISS | 4 |
| `canonicalDomainNeverFetched` | 4.3 state 3 | 4 |
| `searchNotEvidenced` | 4.3's `no_such_site` evidence test | 4 |
| `evidenceUnmeasured` | 4.3 state 4 | 4 |
| `claimUnsupported` | 4.3 state 5, fetches and searches alike | 4 |
| `routeNamedButNotSupplied` | 2.1's routing of the existing `EmptyReason` case | 2 |
| `billedLeadNotAnsweredFirst` | 3.4's `TargetPriorityCheck` | 4 |
| `runDidNotFinish` | 2.3's sibling coverage: the #3007 watchdog kill, an unparsable results file, an unsupported version | 2 |

Cases whose writer ships later than the enum itself carry **the number of the issue that activates them**, in the same change (L65).

Rules:

- Unknown values are **dropped rather than rendered**, at every boundary, exactly as `PrepImporter.swift:148` does.
- Sentence and help are produced by **exhaustive switches naming `nil`**, so a new case breaks the build rather than falling to a default. Mirrors `emptyAnswerBadge` and `emptyAnswerHelp`.
- A row carrying several reasons renders them as a list, in `CaseIterable` order so the order is stable between reads, never as whichever one happened to be written last.
- A test over `CaseIterable.allCases` asserts every case has a **distinct** badge sentence and a **distinct** help string, and that no incomplete sentence is byte identical to any `EmptyReason` sentence (the #843 duplicate copy shape).
- **[R3] The L517 assertion:** over every combination of the rules' inputs, each rule's outcome lands in **exactly one** of satisfied, violated, unmeasured, and no rule's finding can be erased by another's. **Seen to fail** by making two rules fire on one fixture and asserting both survive; then by mutating the store back to a single reason field and recording the exact failure text.
- **[R3] While in this file, correct `EmptyAnswerReport`'s header**, which says the check records "one of nine reasons" against an enum of eight and an exhaustive switch handling eight. The plan cites that file as the model for exhaustiveness, so a wrong count inside it is the same defect one level up (L32, L210).
- `docs/copy-inventory.md`, `docs/outbound-copy.md` and `docs/copy-surfaces.md` are regenerated with `TEST_RUNNER_REGENERATE_COPY_INVENTORY=1`, and every new sentence is **cold read in the branch that produces it, including the branch where the reason set is empty**, in the order a person meets it on screen.
- **Guard seen to fail:** mutate the badge switch to add a `default:` and assert the distinctness test still passes while a removed case renders the wrong sentence; then mutate a case's rawValue and assert the boundary drops it rather than storing it. Record both failure texts.

#### 0.2.2 The condition is persistent, so it lives on a persistent surface with an action on it, and the suppression has an expiry

Revision 1 grew a counter on a row that returns to candidacy and reported it only in a run summary that clears. That is L126 and it is #2621's shape in this same feature. The row's re-candidacy is real, because `probedAt` is never advanced, so `hasFreshReachabilityAnswer` stays false and `reachabilityProbeCandidateKeys` returns it. Four things change:

1. **The count renders on the card**, beside the incomplete sentence, as its own line: how many times this show has come back incomplete (`reachabilityIncompleteRunCount`) and when the last one was. It is not a repeat of the badge (843): the badge says what state the show is in and this says how many times the search has failed to settle it. It renders **only on incomplete rows**.

2. **A control on the card sets the show aside from candidacy**, and **[R3] the suppression carries an expiry and is listed somewhere visible (L523)**. Revision 2 shipped a hand set suppression on a paid check with no deadline and nowhere naming what was currently suppressed, and the durable list it did build was "shows that keep coming back incomplete", which a set aside show by definition stops appearing on. A show set aside in March would then never be checked again for the life of the row, while `NegativeVerdictCorpus` counted it as a negative nobody re-examined. So:

   ```
   var reachabilitySetAsideAt: Date? = nil
   var reachabilitySetAsideReason: String? = nil
   // The suppression EXPIRES. A row past this returns to candidacy with the reason named on the
   // card, so a set aside is a deferral rather than a permanent, undetectable silence (L523).
   var reachabilitySetAsideUntil: Date? = nil
   ```

   **writer**: the card control and its undo, plus the expiry sweep that returns a lapsed row to candidacy. **reader**: the shared predicate in the next paragraph, the card, and the list in item 3.

   **[R3] It is an input to ONE shared predicate that every offer path consults (L330).** Revision 2 named `probeIsWorthOffering` as the only reader, and it is not the only rule that raises "should this show be checked again". `Reachability.recheckState` (`Reachability.swift:165-193`) independently draws the card's re-check control and returns `.offer` on `missedByACheck` alone, and Phase 2.2 adds the incomplete badge's own re-check offer through exactly that function. Pressing it sets `reachabilityRecheckRequestedAt`, which `hasFreshReachabilityAnswer` reads FIRST as an unconditional release. So Dan's durable acknowledgement would be written to a field the second rule never reads, the card would go on asking, and the answer he gave would put the show straight back into candidacy. That is overture#3307 in this same product, and the plan forces the five `wasMissedByACheck` readers through one predicate two sections above and would then have introduced a second acknowledgement with the same split.

   `Reachability.isSetAside(setAsideUntil:now:)` is that predicate, and **every offer path takes it**:

   | Path | How |
   |---|---|
   | `probeIsWorthOffering` (`QueueView+Model.swift:2224`, called at `:2215`, `:2268`, `:2291`, `:2335`) | a term in the predicate, so all four call sites inherit it |
   | `Reachability.recheckState` (`Reachability.swift:165-193`) | a new parameter beside `isStillOpen`, which is already there for exactly this reason |
   | the bulk `previouslyMissed` filter (`QueueView+Model.swift:1784`) | a term in the filter |
   | `QueueView.swift:450` | through the same filter once 0.2's five site consolidation lands |

   **Guard:** one test over the whole set asserts a set aside row has `recheckState == .notOffered` **and** is absent from `reachabilityProbeCandidateKeys` **and** is absent from the bulk selection, so a future change to one alone goes red (L16, L63). A second case takes the same row past `reachabilitySetAsideUntil` and asserts all three offer it again with the reason named. **Seen to fail** by removing the parameter from `recheckState` and recording the failure text.

   **sibling**: every other stored per row suppression (`reachabilityRecheckRequestedAt`, the geo refusal, `OpenForDecision`), enumerated by grep in the PR body with a one line verdict each.

3. **A durable list**, reachable from the run notice rather than replacing it: "Shows that keep coming back incomplete", naming the specific shows with their counts and their last reasons. **[R3] It carries a second section, "Set aside", listing every currently suppressed show with its reason, its age and its expiry**, so the suppression is visible rather than inferred from a show's absence. This is the shape Dan chose himself on #2513: a report he goes to when he wants it, naming the specific shows rather than only counting them.

4. **[R3] The per run notice reports the count of shows skipped because they are set aside**, since a run that skipped N shows for that reason and a run with N fewer candidates are otherwise the same silence (L98, L11).

**What I am NOT shipping, and why it is escalated rather than decided.** An automatic "past N incomplete outcomes, stop offering by default" rule is **decision 6**, with Dan's #2513 quote attached, because the same repository holds his recorded refusal of that shape. The L126 finding is closed by items 1 to 4 regardless of how decision 6 lands.

#### The rest of 0.2

- The per reason counts and `reachabilityIncompleteRunCount` increment on each incomplete outcome and **do not reset**.
- **The clearing rule is stated and tested in both directions.** A later run that ANSWERS the row clears `reachabilityIncompleteAt` and the reason set and **leaves the counts**, which are history. A later run that comes back incomplete again **increments rather than resets**.
- Each check run prints how many of the shows it was given had already come back incomplete before, how many times, and how many were skipped as set aside, in the run log and the app's notice surface, as a shortcut into the list above.
- Prove the clearing rule with `scripts/mutate.sh --at` on it, both directions, and record the failure text.
- `markProbed`'s first settle branch and the importer's empty branch route through **one shared helper** so the two cannot drift (L263). Log every refusal loudly with the natural key.
- **Idempotence.** Both writers run on a path that can settle the same file twice (`consumeIfNew` swallows a throw with `try?`). The refusal is a pure function of the row's current state, returning the new values, applied by the caller, the shape `live_corpus_seen_update` uses, so it is testable without a store.
- **Observe before enforce (L93, L142).** Ships enforcing only after one full check run reports how many settles it *would* have refused and on which shows, with a pre-recorded expectation: roughly the 7 currently wrong rows plus whatever the run itself would have downgraded, so a refusal rate in the low single digits per run. A rate far above that means the address predicate is admitting addresses it should not, which is a 0.1 defect rather than a reason to disable the refusal. The activating issue is filed in the same change (L65).
- **The predicted rate is sized against the right population:** "after the refusal an incomplete row has `probedAt == nil`" holds only for a **never probed** row. For a row that already carries a `probedAt`, the refusal declines to ADVANCE the stamp, so the old stamp stands and the row is not returned to candidacy until it goes stale. The observe run reports the two subsets separately.
- **Guard seen to fail.** A prospect holding a clean unguarded email, given a barren probe result, must end with `reachabilityResult != .noEmailFound` **and** `reachabilityProbedAt` not advanced **and** `reachabilityIncompleteRunCount == 1` **and** `reachabilityRecheckRequestedAt` unchanged. Prove with `scripts/mutate.sh --at` on the refusal's own condition, scoped through `mac/scripts/run-tests-locked.sh`.

### 0.3 **[R3]** Record the evidence, then decide what may be re-derived, because the verdict half is a decision Dan has already reversed

The ordering is reversed from revision 1: the marker is stamped before anything writes, because the contradiction between a negative verdict and a stored route is a fact nothing recorded deliberately, it is the entire evidence base for #3345, and the repair is what deletes it (L277, dragging L182).

**[R3] And the scope is cut, because revision 2's blanket re-derive reversed two recorded Dan decisions and presented itself as a repair.**

#### Step 0: stamp the contradiction before anything writes

Two new stored properties on `Prospect`, written in the **same pass** that snapshots, before a single re-derived value is written:

```
var contradictionMarkedAt: Date? = nil
// WHICH negative verdict was contradicted. Not a spare copy of the snapshot: the 5.2 trend line
// reads it, and `no_email_found` and `social_only` are different findings about the hunt, so a
// marker saying only THAT one was contradicted cannot answer the question the trend line asks.
var contradictionPriorResultRaw: String? = nil
```

**[R3] `contradictionPriorEmptyReasonRaw` is DELETED (L46, and the repo's PR rule 2).** Revision 2 declared three properties, named readers for only the first, and specified the reverse migration to restore from the dated JSON rather than from these columns, so two of the three were written once and read by nothing. That is the same defect the plan correctly applies to `roleOnListing` two sections later. `contradictionPriorResultRaw` **survives with its consumer named in the same change**, the 5.2 trend line, which needs to know which verdict was contradicted. The prior empty reason has no such consumer and lives solely in the dated JSON the reverse migration already reads.

A row is marked when the stored verdict says there is no way in **and** `hasAnyRoute` is true at migration time. **writer**: the migration, once, and nothing else ever. **reader**: `WrittenOffBacklog.rows(now:)`, Phase 5.2's second stratum, and the standing trend line in 5.2, which reads `contradictionPriorResultRaw` to say what was contradicted. **sibling**: every other place a prior value is preserved across a rewrite, `fitScoreBeforeContactCheck`, `contactRouteAtScore`, `contactTierAtScore`, enumerated in the PR body.

Two properties of the marker are deliberate:

- **The reverse migration restores the snapshotted fields and LEAVES the marker.** The marker records what was observed at a moment, not a state the migration created, so reverting the repair does not unobserve it.
- **It is also the backfill L223 requires.** A check keyed on a marker cannot see anything written before the marker shipped, and the whole contradicting population predates it. Taking the marker at migration time is the only moment that population is still readable.

**Measured expectation, to be recomputed through the shipped predicate before it runs:** **33** marked rows across the whole negative or weak population, **27** of them inside `named_but_no_route`.

#### Step 1: re-measure through the app's own predicates

Of the 37 `named_but_no_route` rows, a loose SQL predicate says **31** hold a contact route; a guard aware predicate closer to the shipped rule says **27**. **That four row gap is the finding, not a rounding difference** (L107). Nothing here may quote a recovery figure produced by a query written beside the app.

**Before step 2 ships:** recompute all load bearing figures, the 7, the 21, the 5, the 37/31/27, the 110/33/77, the 49/4/3, the 11, and the ledger's 60/28/7/3, through the shipped Swift predicates from a debug menu command that prints them. Quote **both** numbers, SQL and predicate, in the plan record and the PR body, with the command that reproduces each, so the figure carries its source and can be re-measured rather than being a dated sentence (L316). Where they differ, name the difference.

#### Step 2 **[R3]**: what is re-derived, what is not, and the two recorded decisions in the way

**The badge does not need this migration.** `QueueItem.reachabilityResult` is fed `p.reachabilityResultAsHeld` (`QueueView+Model.swift:2716`), which recomputes from current recipients on every read for any unsent, unbooked show (`Prospect.swift:386-390`). So the 27 routed `named_but_no_route` rows already badge correctly today: 19 as `contactFormOnly`, 4 as `socialOnly`, 4 as `weakContactOnly`. What 0.1 changes on screen is the smaller, real population: the **11** rows (a lower bound) whose live badge currently suppresses an existing unguarded address, of which the ones carrying a stored `no_email_found` number **4**, **3** with a date still ahead.

**So the stored verdict's only significant remaining reader is `contactRouteForScoring` (`Prospect.swift:271-289`), the ranker.** And its comment records Dan's call in terms:

> "#2664 briefly made this follow the badge, on the reasoning that a card saying 'No email found' beside a score still paying route points is a contradiction. Dan's call, 2026-08-13, on being shown that this went further than the decision he actually made: the badge was what he chose, and ranking stays tied to what the paid check CONCLUDED."

**Re-deriving the stored verdict for every unsent prospect moves the ranker onto current holdings across roughly 690 rows, which is exactly what he reversed.** Revision 2 escalated the tier half as decision 2 and never noticed that the verdict half is the same decision, larger. So:

- **The verdict re-derivation is ESCALATED as decision 7**, carrying that quotation with its own date from the record it lives in (L249), rather than being taken as a side effect of a repair.
- **What ships unconditionally in 0.3 is the marker, the ledger correction, the snapshot and the reverse.** The prospect verdict sweep waits on decision 7.
- If decision 7 is "do not re-derive", the 4 rows carrying a stored `no_email_found` over a live route are corrected by a **narrow, one direction pass** in the shape `ContactFormResultMigration` already establishes, which is not the thing he reversed, and the plan says so.

**[R3] `ContactFormResultMigration` is an enumerated subject, and its own comment states the invariant a blanket re-derive removes (L204).** `ContactFormResultMigration.swift:12-16` is a live launch migration reading `reachabilityResultFromRecipients`, and says:

> "Deliberately narrow, in one direction only: `no_email_found` becomes `contact_form_only`, and nothing else is touched. A blanket re-derive would also move a badge whose venue warning Dan has since dismissed, and he decided on 2026-07-27 that dismissing a warning makes the address sendable but does NOT move the badge until a re-check. This pass must not quietly overturn that."

Revision 2's Phase 0.3 **is** that blanket re-derive, and named the file nowhere. This is L204's shape exactly: a change removes an invariant other code silently relied on, the reliance is recorded only in a comment that reads as reassurance, and the comment is both the tell and the trap. It is compounded because both passes run in the same launch block, so `ContactFormResultMigration` would then re-apply its narrow rule over rows the sweep had just rewritten, with nothing anywhere comparing them. So:

- **The 2026-07-27 decision is put to Dan as its own escalated question** (folded into decision 7, quoted from the record with that record's date), rather than being overturned as a side effect.
- **The launch ordering is stated**: `ContactFormResultMigration` runs before any new pass, and the new pass's own report names how many rows the narrow migration had already moved.
- **If decision 7 approves the sweep, `ContactFormResultMigration` is dead code the moment it lands, and is deleted in the same change** (L29), not left running behind it. The PR body says which of the two happened.
- The invariant search was done by grep, not by reasoning about the feature: `grep -rn "reachabilityResultFromRecipients\|contactTierFromRecipients" mac/Overture` plus a read of every comment that justifies a narrowing. That is how this file was found, and the method is recorded so the next sweep uses it.

**Before anything writes, snapshot.** `fitScoreBeforeContactCheck` holds only the score before the *last* move and `ContactScoreAdjustment.settle` replaces it; a sweep overwrites all of them irrecoverably.

1. The launch store backup already runs (`overture-store-backups/`, #601/#602). Confirm a `success` line in `backup.log` for this launch **before** anything runs, and refuse outright if the backup did not report success (L5).
2. Write the prior state per touched row into a dated JSON beside the backups, **and ship the reverse migration in the same change** (L46, L7). The reverse is a named command (`ReachabilityRederivation.revert(from:)`, reachable from the debug menu), with a test that applies, reverts, and compares **every** snapshotted field per row. Retention: kept **indefinitely**, named `reachability-rederivation-<yyyyMMdd-HHmmss>.json`, deliberately outside the plain `yyyyMMdd-HHmmss` folder shape the store rotation counts and deletes, on the `.foreign` precedent (#1410).
3. Report how many rows changed, per direction, and how many fit scores moved, per direction, in the run log and the app's notice surface, before and after. A migration that reports nothing is indistinguishable from one that did not run (L98).

**The enumerated derived resources, and there are TWO, not one (L38).**

**(a) `Prospect`**, six fields per touched row: `(reachabilityResult, reachabilityEmptyReason, contactTierAtScore, contactRouteAtScore, fitScore, fitScoreBeforeContactCheck)`. **The tier half moves in 0.1 regardless of decision 7**, because the predicate change moves it; the verdict half waits on decision 7.

**(b) `OrgReachabilityAnswer`**, which is a **stored, derived resource of the two predicates 0.1 changes**: its result derives from `p.reachabilityResultFromRecipients` (`:121`) and its `foundEmails` from the address predicate (`:125`). It is written **only** when a run settles answered keys, so **nothing re-derives it**, and its rows are read by `inheritedAnswers` (`QueueView+Model.swift:2567`) and fanned onto every sibling show with no answer of its own. **This half ships unconditionally**, because 0.1 changes what `foundEmails` means on all **32** `email_found` rows, and a ledger row promising addresses a stricter predicate withholds is a defect this phase creates rather than one it inherits.

Measured 2026-08-30: **60 ledger rows**, 28 negative or weak, **7** with a source prospect holding a guard aware route, **3** naming a `sourceNaturalKey` no prospect carries.

- **Snapshot every one of the 60 rows** as `(orgKey, resultRaw, probedAt, foundEmailsRaw, sourceNaturalKey, sourceGroupName, presenterName)` into the same dated JSON.
- **Recompute each row through the ledger's own rule** (the same expression `record` uses, over the prospects of that organisation by `OrgKey.stored`), and where the recomputed value **differs**, delete the row rather than rewrite it. Deletion, not rewrite, because `record` is last writer wins across an organisation's prospects and takes an `answeredKeys` set the migration cannot synthesise, so a rewrite from one named source prospect would be a second, different rule (L263). A deleted row simply has no inherited answer until the next settle rebuilds it, which is the correct direction: a wrong inherited negative is worse than no inherited answer.
- **Report the count deleted, by prior result**, and the count of shows that consequently lose an inherited answer, before and after. A row whose `sourceNaturalKey` names no prospect is reported in its own line and left alone rather than crashing or being silently dropped (L11).
- **The reverse restores the deleted ledger rows verbatim**, including the three orphans, and the round trip test compares every ledger field as well as the snapshotted prospect fields.
- **Guard seen to fail:** delete the ledger from the enumerated set and assert the round trip test goes red naming the ledger; record the failure text. A second mutation makes the recomputation always agree, and asserts the deletion count goes to zero on a fixture where it must not.
- The PR body states this enumeration under the **sibling** heading, **derived from `grep -rn "OrgReachabilityAnswer" mac/Overture`** rather than from this text.

Also in this change: correct the stale "the ledger holds 0 rows as of 2026-08-07" comment in `hasFreshReachabilityAnswer` to the measured figure with today's date (L244).

#### Step 3: `WrittenOffBacklog.rows(now:)`, defined over the marker

The brief's written off backlog figure (46 shows, 19 within 14 days) did not reproduce: nine plausible predicates gave nine answers. So this ships a **named, tested Swift predicate** with its own fixture and a surface reporting the count, defined over **the marker and the surviving negatives**, not over live `reachabilityEmptyReason`:

```
WrittenOffBacklog.rows(now:) =
    rows where contradictionMarkedAt != nil            // the repair's own record, 33 measured
  + rows still carrying a negative or weak verdict     // 77 measured
      with hasAnyRoute == false
```

The two strata are **reported separately and never summed into one number**. **It does not sweep.** The sweep runs after Phase 4, reports the count it is about to act on, and asks before spending.

### 0.4 Ship #3283 and #3289

A route carrying contact rendered nowhere is an unreachable show that was never unreachable, and the reported set is growing (15 shows measured one day, 23 the next). Same class as 0.1: a route that exists and is not counted. It ships here because the Phase 5 measurement is meaningless while a route can exist and be invisible.

### 0.5 **[R3]** The empty answer report counts a claim no card makes, and 0.1 plus 0.3 will not fix it

Revision 2 said the report's contradiction "should be largely gone after 0.1 and 0.3". **It is a different defect, it is larger than revision 2 assumed, and neither phase touches it.**

`EmptyAnswerReport.make` (`EmptyAnswerReport.swift:41-46`) counts **every** stored `reachabilityEmptyReason` with **no verdict test at all**: **105 rows today**. Only **43** of them, the ones whose stored verdict is `no_email_found`, can render the sentence being counted, because `ProspectRowView.swift:643-654` renders the empty answer sentence **only under the `.noEmailFound` badge**. The other **62** are counted for a claim no card makes:

| Verdict + reason | Rows |
|---|---|
| `contact_form_only` + `named_but_no_route` | 19 |
| `social_only` + `only_social_profile` | 27 |
| `social_only` + `named_but_no_route` | 4 |
| `weak_contact_only` + `named_but_no_route` | 4 |
| `contact_form_only` + `nothing_published` | 1 |
| an empty reason with **no stored verdict at all** | 7 |

**The cause is a writer/reader split the plan had never enumerated:** `PrepImporter` writes the reason whenever `usableRecipients == 0`, **independent of where the cascade lands**, so a show with no address but a form on its own site gets both `contact_form_only` and a reason saying nobody could be reached. The report then reads that field with no verdict test and reports it as a claim.

The fix is at the reader, and it is a **reader/writer precedence statement** rather than a data change:

- `EmptyAnswerReport.make` takes the verdict as well as the reason and counts **only rows whose stored verdict is `no_email_found`**, which is the population whose card actually says the sentence. It reports the **62 excluded rows as their own line**, by verdict and reason, so the exclusion is visible rather than a number quietly getting smaller (L11, L98).
- The **7 rows carrying a reason with no verdict** get their own line and their own sentence, since a reason without a verdict is a different fault from a reason contradicted by one.
- The PR body states, under "where two sources could answer one question, which wins": **the VERDICT decides whether an empty reason is a claim; the reason only says which claim.**
- **Guard seen to fail:** a fixture holding one `contact_form_only` + `named_but_no_route` row and one `no_email_found` + `named_but_no_route` row asserts `count(of: .namedButNoRoute) == 1` and the excluded line reads 1. Mutate the verdict test away and record the failure text.
- Separately, and after 0.1, **measure and print the residual**: a show that holds a route and still carries `namedButNoRoute` under a `no_email_found` verdict is either a stale reason or a live defect, and the report says which rather than counting it silently.

---

## Phase 1: Make evidence exist and survive

### 1.1 One definition of "this stream finished" (L263)

`~/Library/Application Support/Overture/check-run-archives/20260830-205244/` holds a 97 item queue, a 90 result file, `runCost` reporting `streams: 10, streamsRecorded: 9, recorded: false`, and `webCalls` reporting `recorded: true, overCap: false, streams: 10` about the same run. Seven shows were silently lost. The two disagree because `models.sh:285` says a stream reported if its event file merely **parsed**, while `models.sh:355` says it reported if it carries a terminal **result envelope**.

Extract one `stream_completed()` used by both, defined as the envelope test, and make `webCalls` publish **no `total` at all** on the incomplete path, the rule `runCost` already follows and `PrepResults.WebCalls` already documents at `:24-29`.

**Guard seen to fail:** a shell fixture driving `record_web_calls` and `record_run_cost` over the same synthetic event set with one stream truncated, asserting both report incomplete and that `total` and `usd` are absent. Mutate the shared definition back to "it parsed" and record the failure text. Run it through `scripts/run-shell-fixtures.sh <path>` (the scoped form, since the runner's own rules exist only there). **Ask the yes or no questions with a herestring, never `cmd | grep -q`** (#3275).

### 1.2 **[R3]** Archive the event streams and the sidecar, each in its OWN dated directory

`PrepRunArchive.swift:14-15` deliberately excludes the streams; `RunSlot.chunkEventsURL` puts them at a fixed per slot path.

**This is a measurement, not a prediction.** The support directory holds 7 `check-run-events.chunk-N.jsonl`, all from the 21:27 seven show run. The 20:52 run's ten streams are **already gone**, overwritten 45 minutes later, while its archived `webCalls` still reports `streams: 10`. The failing run's per item evidence was destroyed on the evening it was produced (L202).

**Sized on the measured numbers, and the baseline is corrected.** The 7 files run 214 KB to 310 KB each, **about 1.7 MB per run**, roughly 6 times the "300 KB each" the archive's comment assumes. Revision 2 compared that against "about 225 KB per run today" for the queue and results pair. **225 KB is the single largest of seven archives, on the one 97 item run.** Measured across all seven: **24, 36, 40, 40, 52, 92 and 224 KB, median about 40 KB.** So an events keep of 10 (about 17 MB) against a pair keep of 30 (about 1.3 MB at the median) is roughly **12 times** the existing footprint, not the 8 times revision 2 stated.

**And `PrepRunArchive.swift`'s own justification is stale in the very file this phase edits (L32, L210).** Its comment at `:14-15` says the pair "is about 14 KB" and at `:48` that thirty runs are "under half a megabyte". At the measured median that is wrong by 3 times, and at the top by 16 times. **Correct both sentences in this change**, with today's date and the seven measured sizes, since a stale size sitting inside a retention justification is exactly what makes the next retention decision be argued from a number nobody re-measured.

**[R3] Three retentions cannot live in one folder, which is what revision 2 proposed (L285, L191).** `DatedFolderRotation.prune(in:keep:)` rotates whole dated **FOLDERS**, keeping the newest N by name, and `RunSlot.archiveKeep` is one number per slot. Whatever single keep governs the folder, two of the three consumers get a lifetime nobody chose, silently on both sides: at 10 the #1616 learner's queue and results history collapses from 30 to 10, which is precisely the defect #2760 was filed to fix; at 60 the 1.7 MB event streams stay for six times their stated budget. And revision 2's test compared two constants and could not see the rotation at all, so it would have passed while measuring nothing (L63).

**The fix is the #2760 precedent, which this repo already established for exactly this reason: a separate dated directory per consumer, each with its own keep.**

```
// RunSlot, beside archivesDirectory(in:) and archiveKeep

// The RAW event streams. About 1.7 MB per run, measured 2026-08-30 over seven files of 214 to
// 310 KB. Reader: a same-week diagnosis of a run that went wrong, and re-derivation of the
// sidecar below if its derivation code changes. Nobody reads these months later.
func eventArchivesDirectory(in support: URL) -> URL   // "<slot>-run-event-archives"
var eventArchiveKeep: Int { 10 }

// The per item attribution SIDECAR. A few KB per run. Readers: Phase 4.3's canonical-domain and
// no_such_site rules, Phase 4.4's proof, Phase 5.2's experiment. Those arrive weeks to months
// after the run, so this is deliberately DOUBLE the queue and results keep of 30.
//
// Note what the two keeps together mean, so nobody later cites a safety net that is not there
// (L174): for the 50 runs between eventArchiveKeep and this, the sidecar SURVIVES and the raw
// events it was derived from do NOT, so re-deriving it from the streams is impossible for those
// runs. The archived derivation is the only copy. That is the reason it is archived at all.
func attributionArchivesDirectory(in support: URL) -> URL  // "<slot>-run-attribution-archives"
var attributionArchiveKeep: Int { 60 }
```

Each directory is pruned by its own `DatedFolderRotation.prune(in:keep:)` call, so no consumer's history is drained by another's key (L285). The three directories share the run's stamp, so one run's queue, results, events and sidecar are found under the same folder name in three places.

**[R3] The test measures what SURVIVES ON DISK, not what the constants say (L212).** Revision 2 asserted `attributionArchiveKeep >= archiveKeep`, which compares two integers and cannot see the rotation. Replaced by: archive **past every keep** into all three directories (at least 61 runs), then assert, per directory, exactly which stamps are present and which are gone, and specifically that the queue and results pair still holds 30 after 61 events archives have rotated. **Seen to fail** by pointing all three at one directory with one keep, which is revision 2's design, and recording the failure text naming the pair count that collapsed.

The archive's existing three properties are kept unchanged: named for the run, renamed into place atomically, and a failed run is archived too. This is #3346's substance; close it here.

### 1.3 Per item attribution, derived not invented, archived with the run, and measured before anything depends on it

The runbook instructs a full rewrite of the results file after **each** item (#1023), and the event stream captures each `Write` tool_use with its complete content, so in principle the newly appearing `naturalKey` in each `Write` names the item, and every web tool_use between the previous `Write` and this one belongs to that item.

**That is an instruction in a prompt, not an observed behaviour, and no evidence on disk can currently verify it (L27, L98).** Measured across all seven surviving chunk streams: **one show per chunk, exactly one `Write` per chunk, and chunk 7 has zero `Write`s at all.** There is no multi item chunk anywhere on disk, because the only run that had them has already been overwritten, which is 1.2's argument restated as a fact.

**Sequencing is explicit: 1.3 ships the derivation and its three outcomes, then MEASURES the per item rewrite rate on the first archived multi item run. Phase 3.4, 4.3, 4.4 and 5.2 may not depend on attribution until that measurement exists.** If the rate is low, the remedy is a runbook change plus a re-measure, not a plan that assumes the instruction was followed.

Three outcomes, never two:

- **attributed**, a `Write` boundary was found and the calls fall between boundaries;
- **UNATTRIBUTABLE**, no boundary, or calls before the first boundary. Reported per item and **never divided evenly across a chunk**, since averaging is what hides a starved show inside a busy chunk;
- **UNMEASURED**, no event file, or it did not parse.

The per run report prints the attributed, unattributable and unmeasured split on every run.

**The sidecar attributes SEARCHES as well as FETCHES.** Verified on the live streams: `WebSearch` tool_use records carry `input.query` and sit in the same stream as `WebFetch` (measured in one chunk: 9 `WebSearch`, 6 `WebFetch`, 1 `Write`). Phase 4.3's `no_such_site` rule depends on this, so it is built here rather than added later.

**Redaction, stated at the point the data is handled:** those queries carry real people's names. The sidecar and the archive are local and gitignored, which is fine, but **any fixture derived from them goes through the same redacting generator Phase 3.2 uses**, emitting shapes and counts and never a name or a host, and `scripts/check-test-identity-provenance.sh` runs over the result in the same change (L155, L230, L222).

**The sidecar is archived in the same change**, into `attributionArchivesDirectory` with `attributionArchiveKeep`. `<slot>-run-attribution.json` sits at a fixed per slot path like every other `RunSlot` file, and the next run overwrites it, while 4.3, 4.4 and 5.2 read it long afterwards.

This writes a sidecar, not a change to `PrepResults`, so Phase 1 needs no contract bump and can ship independently.

### 1.4 Interleave the chunk split (this supersedes "one show per stream", which is deleted)

`split_queue_into_chunks` slices contiguous ranges, so a killed chunk loses one room's worth of shows, loss correlates with difficulty, and any chunk to chunk comparison compares venues rather than chunk sizes. On the 97 item run one host supplies 43 of 97 listings, so a contiguous slice is very nearly a per venue slice. Change to a round robin deal.

**Why this rather than one show per stream.** They are alternatives. One show per stream is unreachable at the observed queue sizes: the splitter makes `min(items, MAX_PARALLEL)` chunks, `MAX_PARALLEL` defaults to 10, and `prep-run.sh:395-405` states why ten is a ceiling. A 97 item queue would need 97 concurrent live web fetching processes. Attribution is solved directly by 1.3; interleaving is only for the loss correlation half.

**Sibling:** `split_queue_into_chunks` is shared by `prep-run.sh:406` **and** `scout-extract-run.sh:300`. Interleaving changes scout-extract's behaviour too. The function's stated invariants (disjoint partition, plain concatenation merge, never an empty chunk, a cap of 1 yielding the sequential behaviour byte for byte) all still hold; `scout-parallel.test.sh` asserts them and must stay green, and the PR body states that it did.

### 1.5 Name the #3007 confound in writing

The stuck tool call watchdog kills a **whole chunk** when one WebFetch stalls. Any comparison of chunk sizes or model tiers must log every watchdog kill with the chunk and the item it died on, and any run used as comparison evidence must report zero kills or be discarded. Recorded here so it is not discovered during Phase 5. A killed chunk's items settle as `runDidNotFinish`, never as a negative.

### 1.6 Constraint 8: what this does to the other run slot

The check and Prep are **not** subject to a blanket lockout, and the milestone that fixed this is closed (#2620, #2765, #3010). `RunCoverage` is per show and fail closed: `heldByOtherRun` reads the other slot's `<slot>-covers.json` and excludes the overlapping shows from this launch. **[R3] The mechanism, corrected:** it does **not** throw when the other slot is live and its holdings cannot be read; `RunCoverage.read` returns a **three case enum** whose third case, `.unreadable`, is a refusal the caller must honour (`RunCoverage.swift:18-40`), and the only `throws` in the file is `write` at `:82`, which fails loud when a run's coverage was not published. The substance is unchanged and the distinction matters, because a caller written to catch a throw would silently treat `.unreadable` as permission, which is the fail open direction on the one control that stops two paid runs colliding.

Dan's call, 2026-08-15: exclude the overlapping shows and say so, never refuse the whole run; and 2026-08-20: whichever run starts second yields, in both directions.

Nothing here lengthens the blocking window. Phase 6 **reduces** contention outright: with the Prep hunt gone, the class of overlap `RunCoverage` arbitrates shrinks to drafting.

---

## Phase 2: `incomplete`, make the wrong verdict unrecordable

Today there are exactly two probe outcomes and **both** start a 90 day lockout. A run killed by the watchdog, rate limited, or simply thin is written down as a firm negative on a show with a live date. Constraint 1 asks for the wrong verdict to be *impossible to store*, not rarer.

### 2.1 The verdict

`incomplete` is deliberately **not** a sixth `ProbeResult` case. `Reachability.swift:223-232` explains why a new case is expensive: it reaches the fit score (#1648), `ContactScoreAdjustment`, the org ledger, `ContactFormResultMigration`, a stored string migration whose unknown values read as "never checked", and a pill tone with no free slot.

Instead it is the **absence of a verdict plus a recorded reason set and per reason counts**, on the fields Phase 0.2 shipped. Phase 2 adds the reader half: the badge, the `recheckState` extension, and the routing rules.

**`EmptyReason.routeNamedButNotSupplied` routes here.** `Reachability.swift:287` describes it as the only one that says the search did not finish, which is `incomplete` by another name. **It has never been written on this store: 0 rows, against seven `emptyReason` values that do appear.** Its current behaviour is *unmeasured*, not proven benign (L90). Say so in the PR body, and add a boundary assertion that fires the first time a run emits one.

Hard invariants, each with its own test:

- `incomplete` never sets `reachabilityProbedAt`, so no 90 day lockout;
- `incomplete` never writes `OrgReachabilityAnswer`, so a thin run cannot fan a negative to sibling shows;
- `incomplete` never touches `fitScoreBeforeContactCheck`, `contactRouteAtScore` or `contactTierAtScore`;
- `incomplete` never overwrites a standing verdict over a live route (0.2's refusal routes here);
- `incomplete` never consumes `reachabilityRecheckRequestedAt`;
- an incomplete row's re-candidacy is counted and reported per run, and rendered on the card per 0.2.2.

### 2.2 What Dan sees, including on the day everything reads incomplete

A show whose last check came back incomplete must not read as "No email found" and must not read as "never checked". It gets its own sentence and its own re-check offer through `Reachability.recheckState`, which already has a three state vocabulary to extend, and the sentence comes from the exhaustive switch in 0.2.1. **That offer path takes the set aside predicate as a parameter** (0.2.2), so the card cannot go on asking after Dan has answered.

**Constraint 5 fixes one thing about this and it is stated here, not discovered.** The "Only names, no way to reach them" badge and its named people **stay**. When a verdict becomes `incomplete`, the named people the run did find are still listed and the badge still shows them; what changes is the *sentence above them*, from a claim about the show to a claim about the search. Dan caught this defect through that badge, so a change that quietly removed it for the population the badge exists for would be removing the instrument.

**And the all incomplete day gets its own loud state (L93, L11).** After Phase 4 there is a real failure mode where a runner has not adopted `targetAnswers`, every app named target MISSes, and every show routes to `incomplete`: the badge goes quiet while every check still costs a run, a silently exculpatory failure. So a run in which **more than half** the shows settle incomplete prints its own distinct notice naming the count, the commonest reason, and the fact that this reads as a runner adoption problem rather than a set of hard shows. Once per run, not per card.

The exact wording of both is a product call and is escalated (decision 1). The copy goes through the cold read step in **every** branch including the empty one and the empty reason set one.

### 2.3 Writers, readers, siblings

Per the repo's PR rule, enumerated in the PR body using the literal words *writer*, *reader*, *sibling*, *seen*:

- **writer** of the incomplete fields: `PrepImporter`'s probe branch and `markProbed`'s first settle refusal path, through the one shared helper. Nothing else. Every `IncompleteReason` case's writer is named in 0.2.1's table, and any case whose writer ships later carries the number of the issue that activates it.
- **reader**: the badge, `recheckState`, the empty answer report, the candidacy and cost path, the card's count line and set aside control (0.2.2), the "keeps coming back incomplete" and "set aside" lists, the per run incomplete report, and the Phase 5 measurement. If any does not read it, say so and why.
- **sibling**: every other place a "the run did not finish" state can arise, the #3007 watchdog kill, an unparsable results file, `routeNamedButNotSupplied`, and a `version` the app does not support (`PrepResults.swift:211-221`, which today locks a whole batch out silently and is the same defect one level up). Cover each or file it.

---

## Phase 3: `targets[]`, the app names who is on the show (PrepQueue v14)

Ordering is fixed and not stylistic: **app first, runbook second**, because `PrepImporter.answeredKeys` decodes with no version gate while `ingestFile` throws and `consumeIfNew` swallows it, so a runner writing a version the app does not know stamps every show in the run with the no email floor and locks them out for about 90 days. Ship the app's reader, with fixtures in the same commit, before a single line of runbook changes.

### 3.1 The field

```
// v14: the parties the APP has established are on this show. The run answers PER TARGET.
// A target with no answer is a MISS with its own outcome, not silence.
//
// ABSENT means this queue predates the field. EMPTY means the app looked and named nobody,
// which is a different claim (the same distinction `houses` already draws, PrepQueue.swift:26).
var targets: [PrepTarget]? = nil

struct PrepTarget: Codable, Equatable, Sendable {
    var id: String              // opaque, echoed back verbatim, same rule as naturalKey
    var name: String
    var kind: String            // organisation | person | act
    var billingRank: Int?       // 1 = the billed lead the app parsed, ascending.
                                // nil = the app did not rank this target. NEVER the run's judgement.
    var source: String          // presenter_on_record | listing_organiser | listing_billing | group_name
}
```

**`roleOnListing` is deleted and replaced by `billingRank` (L46 plus L237).** A field only ever written looks alive to any is-this-used check while the purpose it was added for silently never happens, and if the intended reader was the runbook prompt then it was a rule living only in a prompt with no boundary check that it was honoured (L27). It also collided with `PrepContact.role` (`PrepResults.swift:147`), leaving two fields answering one question with no declared precedence.

The close taken is **give it a deterministic consumer**, not carry the hierarchy in target order. Order was tempting and is wrong here: addressing something by its **position** rather than its identity measures whatever currently occupies that position (L237), and every rule in Phase 4 is keyed on `targetId`, so a later sort for display, a merge, or a runner that reorders would silently lose the rank while every check still passed.

`billingRank` is an `Int?` rather than a role word so that it cannot be confused with `PrepContact.role`, and **the precedence is stated rather than implied**: `PrepContact.role` is the **run's** free text word about a contact, display and diagnostics only, and **no rule reads it**; `billingRank` is the **app's** parse and is the only thing any rule reads. Where they disagree, `billingRank` decides and `role` is not consulted. That sentence goes in the PR body under "where two sources could answer one question, which wins", and `billingRank` is enumerated under the **reader** heading with `TargetPriorityCheck` named.

The role WORD the parser matched is not thrown away: it is recorded in the parser's own calibration corpus and label file, which is where it earns its keep, and not in a cross boundary contract where nothing reads it.

`source` is load bearing: it says how confident the app is, and lets Phase 4's coverage rule treat an app named target differently from a run discovered one.

### 3.2 What the app can actually name today, measured on the archived 97 item queue

| Source | Present on | Yields |
|---|---|---|
| `groupName` | 97 of 97 | one `act` target |
| `presenterOnRecord` (v13, #2983) | 39 of 97 (40 percent) | one `organisation` target |
| `organisationNamedOnListing` via `ListingOrganiser` (v11) | **0 of 97** | nothing, on this queue |

The earlier draft listed the third as a free tier. **Empirically it contributes nothing here.** Every organisation shaped *person* target the plan expects for free must come from the new, unbuilt parser.

**New, and narrow: a `ListingBilling` parser** reading billed people off `showListing.text`, on the same discipline as `ListingOrganiser`.

- **Structural ceiling 58 of 97**, because that is how many queue items carry a `showListing` at all.
- **Realistic reach far smaller**, and stated with its matching rule because the rule changes the number by 35 percent: **case insensitive, word bounded**, 27 of 97 carry any billing token; case sensitive gives 20. The parser declares which it does, and its fixture covers both a billed capitalisation and a lower case occurrence. **[R3] The `Producer|Produced by` family is 4 of 97, not 5, and it is 4 under both matchings.**
- **50 of the 58 listings carry HTML entities.** The parser decodes before matching, its fixture includes an entity bearing case, and the decoder handles **named and numeric** references, because no numeric reference appearing in one corpus is not evidence none will.
- It parses **only** shapes it can name: a `Featuring:` or `Starring:` run of names, and a role token (Music Director, Director, Conductor, Choreographer, Curator, Produced by) with the name span that follows it. Both colon terminated and bare.
- It **abstains** on everything looser, and abstention is a distinct answer from "the page names nobody", `ListingOrganiser`'s three state rule.
- **Ranking:** the parser assigns `billingRank` from word order and role token weight only. It assigns **no rank at all** where it abstains, and a nil rank is never read as rank last.
- **Calibration is measured, and the corpus is generated, never transcribed (L48, L155, L230).** Calibrated against real stored `showListing.text` on the live store, hand labelled. The committed fixture is produced by a **generator emitting shapes and counts and never a name or a host**; the label file records positions, roles and ranks against synthetic substitutions, and the substitution map lives only in the local store. Redaction happens **before** the corpus file is written. `scripts/check-test-identity-provenance.sh` runs over the result and any new identity is recorded in `fixtures/test-identity-provenance.txt` in the same change.
- **Publish the measured precision and recall on that corpus in the PR body**, as numbers, with no examples. If precision on `person` targets is below a bar Dan sets, the parser ships **disabled with the issue that activates it named** (L65, decision 4).

**The honest limit, stated here rather than found later.** `ListingOrganiser.swift:23-29` says outright that everything looser than its two narrow shapes deliberately stays with the model, and the failing card's own listing is the looser case. **The plan does not rank on the run's emitted `role` field** (#2258, L27); the hierarchy comes from the app's own parse of word order, carried in `billingRank`, or from nothing at all. This parser raises a floor across the top templates (one host is 43 of 97, two are 57, five are 77). It does not solve the general case. **Anyone reading this plan as "the app now knows who is on every show" has read it wrong.**

### 3.3 The run may still add targets

The run discovers parties the app could not name. Those come back as answers carrying a target the queue did not contain, flagged `discoveredByRun`. They are kept, they become recipients as they do today, and they are **excluded from the coverage rule**: a MISS is only ever assertable for a target the app named. That is what stops the coverage check becoming a rule the run can satisfy by naming nobody.

### 3.4 `TargetPriorityCheck`, the deterministic consumer of `billingRank`

Ships with Phase 4 (it needs `targetAnswers` and the sidecar), specified here because it is what makes `billingRank` a read field rather than a written one.

Per item, in Swift, over the app's own list and the sidecar's attribution, never over the run's account of itself:

> Among the app named targets carrying a non nil `billingRank`, the **rank 1** target's `TargetAnswer` must carry **at least as much attributed evidence** as any higher numbered rank's: at least as many attributed fetches, and at least as many attributed searches. A violation means the run answered a supporting name more thoroughly than the billed lead.

- A violation is a **fact about the run**: reported per item, counted per run, and it adds `billedLeadNotAnsweredFirst` to the row's incomplete reason set with its own counter. It is never a negative about the show.
- **Three states, never two:** satisfied; violated; and **UNMEASURED** where the sidecar says UNATTRIBUTABLE or UNMEASURED for this item, or where no target carries a rank. UNMEASURED is reported as itself and never folded into satisfied (L11, L98).
- **Observe before enforce**, on the same terms as 4.2 and 4.3: one full run reporting the violation rate with a pre-recorded bar, and the activating issue filed in the same change (L65). The bar is pre-committed here: **above 50 percent of ranked items violating, the finding is that the ranking or the attribution is wrong rather than that the run is careless**, and enforcement waits. **Because 0.2.1 stores reasons as a set with per reason counters, that 50 percent bar is measured against its own counter and cannot be erased by another rule firing on the same rows** (L53).
- **Guard seen to fail:** a fixture where the rank 2 target carries three attributed fetches and rank 1 carries one; mutate the comparison to `<=` and record the failure text. A second mutation removes the UNMEASURED branch and asserts an unattributable chunk stops reading as satisfied.

---

## Phase 4: Per target answers and per target evidence (PrepResults v12)

### 4.0 **[R3]** The version ordering, and the fixture that can actually go green

Measured on disk 2026-08-30: `overture-check-results.json` is **version 6**, `overture-prep-results.json` is **version 11**, `PrepResultsDecoder.supportedVersion` is **11**.

**Revision 2 proposed a fixture asserting "the merger's output version equals the runbook's declared version equals the app's `supportedVersion`". That is false today (6 is not 11), and the only way to force it green is to bump `prep-run.sh`'s two literals from 6 to 12, which before the app reader ships is precisely the silent 90 day lockout `PrepResults.swift:211-221` describes.** The two paths have opposite version positions and must not be given one rule:

- **The CHECK path has five versions of cushion.** `merge_chunk_results` overwrites the model's version with the literal `6` that `prep-run.sh` passes at `:237` and `:504`. It does **not** need to move for v12, and it is not moved.
- **The PREP path has ZERO cushion.** There is no chunking, no merger runs, and the model itself writes `"version": 11` per the runbook, exactly `supportedVersion`. This is the path a v12 bump must be ordered around.

So the ordering and the fixture are:

- The app's v12 reader ships **first**, with its fixture, in its own commit, raising `supportedVersion` to 12, before any runbook edit. The tolerant range `minimumVersion...supportedVersion` means a v11 file keeps working throughout.
- **Only then** does the runbook's declared version move from 11 to 12.
- The check path's literals stay at 6, and are **replaced by one shared constant read from a single place** anyway (L263), so the two cannot drift from each other.
- **The fixture asserts an INEQUALITY, not an equality**, because that is the invariant that is actually true and actually protective: **every version any writer can emit is less than or equal to the app's `supportedVersion`, and greater than or equal to `minimumVersion`.** The writers it enumerates are the merger's shared constant, the runbook's declared version parsed out of `docs/prep-runbook.md`, and the two live files on disk where present. **Seen to fail** by raising the runbook's declared version above `supportedVersion` and recording the exact failure text, which is the lockout the assertion exists to prevent.

### 4.1 The contract

Each `PrepResult` gains `targetAnswers: [TargetAnswer]?`:

```
struct TargetAnswer: Codable, Equatable, Sendable {
    var targetId: String
    var outcome: String        // route_found | no_route_found | no_such_site | not_reached
    var urlsSearched: [String]?
    var urlsFetched: [String]?
    var contactIndex: Int?     // which contacts[] entry answers this target
}
```

`contacts[]` stays exactly as it is, so the whole existing ingest path is untouched and this is purely additive.

**Optional fields are permission, not neutrality (L167, L128), and this repo has already paid for it.** #2893: told to record a social route with the profile URL in `formUrl`, the check read `PrepResults.swift` mid run, wrote down that `formUrl` is optional, and emitted two contacts each naming a route and carrying none. The runner here can read the same file. So the constraint is expressed **at the boundary, in Swift, not in the runbook**:

> A `TargetAnswer` whose outcome is `no_route_found` and which carries no `urlsFetched` is a **MALFORMED answer**. It is reported per item as a **fact about the run**, never as `unmeasured` about the show. The same rule applies to `no_such_site` with an empty `urlsSearched`.

**Two boundary assertions, not one (L128).** The first is above. The second is on **`targetAnswers` presence at all**: at least one result in each run carries the field, reported as `NOT REPORTED` when it cannot be checked. Without the second, a runner that never adopted the field is indistinguishable from one that had nothing to say, every app named target MISSes, and 4.2 routes the whole run to `incomplete`.

### 4.2 Coverage is computed in Swift over the app's own list, with its own observe phase

Deterministic, from the queue the app wrote, never from the run's account of itself. This is the rule `PrepImporter` already follows and states at `:128-131`.

For every app named target with no `TargetAnswer`: record a **MISS**, adding `targetNotAnswered` to the row's incomplete reason set with its own counter. A MISS is a fact about the run, so it routes to `incomplete` and never to a negative verdict.

**Observe before enforce, and for a sharper reason than usual (L93, L142):** it is the rule with the widest blast radius, its only writer is a prompt, and its failure mode is the badge going quiet across an entire run. So one full check run reporting how many app named targets would have MISSed and how many verdicts would have become `incomplete`, with a **pre-recorded bar of 35 percent of app named targets MISSing**, above which the finding is a runbook or runner defect and enforcement waits. **That 35 percent is read off `targetNotAnswered`'s own counter** (L53). The activating issue is filed in the same change (L65), carrying the measured rate and the bar. Phase 2.2's all incomplete notice is what Dan sees if this is wrong in production.

### 4.3 The #3345 production fix, wired into the verdict, honestly downgraded, and reading the evidence rather than the claim

This closes the objection the winning shape did not answer: **coverage proves a target was considered, not that the search was exhausted before a MISS was accepted.**

Rule: **refuse to record `no_route_found` for a named `person` target whose canonical domain was never fetched.** The runbook already requires that fetch at `docs/prep-runbook.md:307` and `:495` (**[R3] two separate lines; revision 2 cited a nonexistent `:494-495` span**); this makes skipping it visible.

**The authority for what was done is the attribution sidecar, not the run's own field (L70, and this repo's #2269 rule).** `urlsFetched` and `urlsSearched` are the run's **CLAIM**. The tool_use records, via 1.3, are the **EVIDENCE**. So the precedence is written into the code, into the plan, and into the PR body as the answer to "where two sources could answer one question, which wins":

1. Where the sidecar attributes calls to this item, **the sidecar wins**.
2. Where the sidecar says **UNATTRIBUTABLE** or **UNMEASURED**, the rule says so and does **not** silently fall back to the claim.
3. Where the claim and the evidence **disagree**, a claimed call that is in no event record, that is its own outcome, `claimUnsupported`, distinct from a satisfied rule and from an unmeasured one. A fact **about the run**, reported and counted, never a negative about the show.
4. Prove it with a mutation that makes the claim disagree with the events, and record the failure text.

The verdict logic is **five** state:

1. Build the canonical guesses from the target's name and test them against every host the **sidecar** attributes to this item.
2. A host satisfying the test was fetched, so the `no_route_found` stands.
3. No such host, and no `no_such_site` evidence, so the outcome becomes **`incomplete`** for that target, adding `canonicalDomainNeverFetched`.
4. The evidence is absent (a run predating v12, an unparsable stream, an UNATTRIBUTABLE chunk), so **unmeasured**, adding `evidenceUnmeasured` and naming itself; never a negative, never silence (L98, L11).
5. Claim and evidence disagree, so `claimUnsupported` per (3).

#### `no_such_site` is judged on the search EVIDENCE, not on the run's word

It is **the one outcome in the whole design that lets a permanent negative verdict stand**. Everything else routes to `incomplete`. A model that emits `no_such_site` with three plausible search strings would close the show permanently. That is L167 exactly: the runner can read `PrepResults.swift`, and an outcome the schema accepts on the run's word alone is permission.

So **the precedence extends to searches, with the same five states**, and this is why 1.3 attributes `WebSearch` records:

1. Where the sidecar attributes searches to this item, **the sidecar wins**. A `no_such_site` is satisfied only when the sidecar holds **at least one attributed search naming the target**, judged by the same name token test the canonical guesses use over `input.query`.
2. No attributed search naming the target: **`incomplete`**, adding `searchNotEvidenced`. The verdict does **not** settle negative.
3. UNATTRIBUTABLE or UNMEASURED attribution: **`evidenceUnmeasured`**. It does not fall back to the claim.
4. A claimed search present in **no** event record is **`claimUnsupported`**.
5. Satisfied, so the verdict settles at `no_route_found` with the badge and its named people intact per constraint 5.

**Guard seen to fail:** a fixture whose `TargetAnswer` carries `outcome: "no_such_site"` with three plausible `urlsSearched` strings and an event stream containing **no** `WebSearch` naming that target. The test asserts the verdict is `incomplete` carrying `searchNotEvidenced` **and** that a `claimUnsupported` is counted for the run. Then mutate the rule to accept the field, and record the exact failure text. A second mutation makes the sidecar return UNMEASURED and asserts the outcome is `evidenceUnmeasured` rather than either satisfied or `searchNotEvidenced` (L11).

The PR body states, under "where two sources could answer one question, which wins": **`no_such_site` is judged by evidence and never by the field.**

**The rule must be satisfiable, or it is a badge with a dead remedy (L109, L111, L93).** A jobbing performer with a social profile and no website can never satisfy step 2 of the canonical rule, which is why `no_such_site` exists at all. What the change above does is require the search to have happened, which is a thing the run can always do and the evidence can always show, rather than requiring a site to exist. So the escape stays open and it stops being free.

#### **[R3] Both tests are shape filters, so PRECISION is measured before the observe run, not only recall (L104)**

Revision 2's calibration was entirely one directional: widen the guess set from the real data, then read a demotion rate. **Both the canonical guess test and the query token test are filters that identify data by its SHAPE, and here the over match direction is the dangerous one, because a match makes the rule STAND DOWN and lets a permanent negative verdict stand.** A performer whose name token is a common word matches the venue's own host or a ticketing host that was fetched anyway; and a `WebSearch` query naming the SHOW TITLE will contain the performer's name whenever the performer is billed in the title, which on this corpus is the ordinary case. Every widening the plan commits to (nicknames, hyphenated forms, dropped middle names, one name token plus a common noun, four extra TLDs) increases that collision rate, and revision 2 measured none of it. This repo has already paid for the mirror of it in `VenueContactGuard` (L147) and for the over match half in L273's casefold.

So, **before the observe run**:

- Run the widened guess set and the query token test over the **36 form bearing hosts** measured on the `named_but_no_route` rows and over the attributed search queries in the archived streams, and **report how often each SATISFIES the rule on an item where the target's own site was demonstrably never fetched.** That is the precision number, and it is **published beside the demotion rate**, not after it.
- **Where a token match is answered by the show title or by the venue host, that is not evidence and must not stand the negative down.** The query token test excludes a match whose only support is the show title verbatim, and the canonical guess test excludes a host the item's own venue or ticketing route already supplies.
- **Guard seen to fail:** a fixture where the only attributed host is the venue's and the only attributed query is the show title verbatim, asserting the verdict is `incomplete` carrying **both** `canonicalDomainNeverFetched` and `searchNotEvidenced` rather than a standing `no_route_found`. **This fixture is also the L517 two-rules-on-one-row case from 0.2.1**, so it proves the set storage at the same time. Mutate the exclusion away and record the failure text.

**Downgrade the claim, in the plan text, because the measurement does not support the strong version, and the measurement itself is corrected.** Of the **51** recipient rows on `named_but_no_route` prospects, **36 carry a form URL**: **19 sit on a host containing two name tokens, 1 on a host containing one, 16 on a host containing none** (11 of the 16 being one social platform). The other **15 carry an address and no URL at all**. So among form bearing hosts, **19 carry a name token and 16 do not**. **"Canonical domain never fetched" is close to a coin flip as a proxy for "the search was not exhausted".** It catches the specific shape behind the failing card and nothing stronger. It is a **negative test**, and the plan says so.

**Widen the guess set before the observe run, from the real data, described as shapes (L48, L155).** The measured hosts require, as classes and without naming anyone: nickname and diminutive expansion of a first name; hyphenated first and last forms; dropped middle names on a three token name; hosts built from one name token plus a common noun; and TLDs beyond `.com`, at least `.net`, `.org`, `.online` and a city TLD all appear. The fixture corpus is generated from those 36 values by the same redacting generator Phase 3.2 uses. **Every widening is re-measured for precision by the rule above before it is adopted.**

This lands inside `Reachability.emptyReason`'s derivation, not beside it, so the badge stops being able to say "Only names, no way to reach them" about a search that never happened.

**Observe before enforce, and observe the dangerous half (L142).** The dangerous path is enforcement demoting nearly everything to `incomplete`. Ship report only first: one full check run reporting how many verdicts *would* have become `incomplete`, on which shows, split by which of the five states produced it, and split by the `no_such_site` states above.

Three commitments made **now**, before the number is seen:

- **File the activating issue in the same change (L65).**
- **Pre-commit the base rate.** Roughly half of real stored form bearing hosts sit on a non name bearing host, so a demotion rate around **40 to 55 percent** is what this rule *predicts*. Reading a high rate as evidence the rule is broken would be reading the base rate as a finding.
- **Write down the bar.** If the demotion rate on app named `person` targets exceeds **65 percent** after `no_such_site` is available and evidence judged, the rule is judged too strict and the guess set is widened again rather than enforced. Below that, enforce. **Read off `canonicalDomainNeverFetched`'s own counter, so another rule firing on the same rows cannot move it** (L53).

### 4.4 Proof of work, framed honestly, in the plan text

**Answering the brief's first question plainly: a proof of work mechanism is NOT sufficient to replace a second independent hunt, and the gap cannot be closed by any mechanism of this kind.**

Proof of work is a **negative test**. It catches a run that did too little. It can never be a sufficiency claim that a run did enough, well. A fetch record can show that a performer's own site was fetched and misread. It cannot show that the right canonical domain was chosen, that the page was read correctly, or that the billed lead was targeted at all. A run that fetches the venue's own site fifteen times passes any fetch count proof cleanly, and the failing card was exactly that shape of nothing.

Two consequences, both binding:

- **What survives to the send, and for how long, stated precisely rather than promised.** What survives **permanently, on the row**, is `Recipient.foundAt` and `foundBySlot` (5.1) and the verdict the 4.3 rules produced. What survives **for `attributionArchiveKeep` runs**, roughly one to two months at the observed cadence, is the sidecar the rules were computed from. The raw event streams survive **`eventArchiveKeep` runs**, about a week, and are the re-derivable source, **and only for those runs: between the two keeps the sidecar exists and the streams it came from do not, so re-derivation is impossible there** (1.2's comment says so in the code). Each of those three is named beside the reader it serves.
- The proof is **never the sole gate** on removing the second hunt. Phase 5 is, and Phase 5 measures outcomes rather than receipts.

What genuinely narrows the gap is not the receipt but the four things around it: `targets[]` makes "did not look" nameable, `billingRank` plus `TargetPriorityCheck` makes "looked at the wrong person first" nameable, `incomplete` makes the wrong verdict unstorable, and the canonical domain and search evidence rules turn two specific classes of under searching into refusals. Those are real. The judgement gap stays open, and this plan says so.

---

## Phase 5: Make "which hunt was right" measurable (the gate on Phase 6)

`ZRECIPIENT` carries no discovery timestamp of any kind, so the ordering behind the contradiction is proven for **exactly one case** (#3345 says so in its own body). For the others the stored verdict and the stored routes merely contradict each other and nothing records which was written first.

### 5.1 `Recipient.foundAt` and `Recipient.foundBySlot`

Written by `ingestContacts` at the moment a recipient is created, stamped with the run's slot. Never overwritten on a later touch, a discovery timestamp rather than a modified timestamp, and a repair that backfilled it would erase the evidence of the delay it repaired (L516).

- **writer:** `PrepImporter.ingestContacts`, and the manual recipient path (stamped `manual`).
- **reader:** the 5.2 measurement, the recheck surface, **and the send path**.
- **sibling:** every other path that creates a `Recipient`, enumerated by grep, not by memory.
- Existing rows get `nil`, meaning "minted before this existed", which must never read as "found by the check". A nil is excluded from the measurement and **counted separately**, so a measurement over an empty population reports UNMEASURED rather than clean.

**Does a contact found at triage go stale before the send? Answered here, because Phase 6 makes it load bearing (L175).** Once the Prep hunt is removed, the triage time route is the **only** route, and nothing re-confirms it between the check and the send. `probeFreshness` is 90 days, which is the *verdict's* freshness, not the *route's*.

**The decision, written down rather than left unstated:** a route older than **60 days** is re-confirmed before a send. `foundAt` is read on the send path, in `SendConfirmation` where Dan can act on it, and a route past it shows a "found N days ago, not re-confirmed" note beside the address rather than blocking the send, his standing preference being warn, never block, with the reason named. **A nil `foundAt` gets its own sentence, never the reassuring one.** Sixty rather than ninety because "is this inbox still that person's" is a different clock from "is this verdict still current". Escalated as decision 3.

**The threshold is a guess by construction, and its own code comment says so.** The store carries no discovery timestamp today, so nothing can calibrate 60 until `foundAt` has been accumulating for some months. The comment states that in the code rather than letting the number read as a measured bar (L316), and names the issue that revisits it once there is a distribution to read.

### 5.2 The gate on Phase 6 is an experiment, not an observed rate

**The obvious design is wrong, and the plan says so rather than shipping it.** A standing count of "shows the single hunt verdicted negative that later acquire a route" is measured in a fixture where the thing being asserted about largely **cannot occur** (L159, L102, L144). Before Phase 6 the only path that can contradict a check's negative verdict is the Prep hunt, and Prep runs only on shows Dan keeps, and reachability is an **input to the keep decision**. So a wrong "unreachable" verdict suppresses the keep, which suppresses the Prep run, which is the only observer that could contradict it. The store confirms the leak: **209 checked, 166 later hold a recipient, so 43 checked shows were never prepped at all**, disproportionately the negatives.

#### The gate population, with the corrected arithmetic

Revision 1 ran the gate over the `named_but_no_route` written off rows with a minimum of **25**. Measured 2026-08-30, through a guard aware predicate:

| Population | Size |
|---|---|
| `named_but_no_route` rows today | 37 |
| of those, holding a guard aware route (so **marked** at migration) | **27** |
| of those, holding no route (so still written off) | **10** |
| whole negative or weak population today | 110 |
| of those, holding a guard aware route (**marked**) | **33** |
| of those, holding no route (**still negative**) | **77** |

**Ten does not clear twenty five**, and even taking all 37 as subjects the gate needs 25 called negative by arm 1 while 27 of the 37 are known to hold a route. **The gate as written was structurally unreachable whichever way the backlog was defined.** So:

- **Primary stratum, and the one the bar is set on: `NegativeVerdictCorpus.rows()`**, every prospect carrying a negative or weak verdict, whatever its empty reason, whether or not it was ever prepped, whether or not its date has passed. **Measured today: 77.** It clears 25 with margin, and it is not suppressed by the keep decision, because it is selected by stored verdict over the whole store rather than by anything Dan did. **[R3] Note that its size no longer moves with a verdict sweep, since the sweep is escalated as decision 7: if decision 7 is "do not re-derive", the corpus stays at 77 and the gate is if anything better powered.**
- **Second stratum, reported separately and never summed in: the marked set**, `contradictionMarkedAt != nil`, **measured today: 33**. It is deliberately **enriched for shows a route is known to exist for**, so a rate computed over it means something stricter. It is reported as its own number with its own control, and it is **not** what the bar is read against (L172, L93).
- A date that has passed does **not** exclude a show from either stratum. The experiment asks whether a party is reachable, which is a fact about the party; only pitching needs a live date.
- **A set aside show is reported as its own line in both strata and excluded from the arms**, since a suppression must be visible rather than inferred from an absence (L523), and a stratum silently shrunk by suppressions is a population nobody chose.
- Both strata are recomputed through the shipped Swift predicate before the experiment runs, and the run prints both sizes. **If the primary stratum has fallen below 25 by then, the experiment does not run and the finding is reported as UNDERPOWERED.**

#### The experiment

1. Run the **post Phase 4 single hunt** over the whole primary stratum.
2. Run the **current Prep style deep hunt** over the **same** set, independently, neither seeing the other's answers, **against a pinned runbook revision, named in the report**, since Phase 6's removal work must not have begun or the two arms are not measuring what the gate claims.
3. Compare show by show. The quantity that gates Phase 6 is: **of the shows arm 1 calls negative, how many does arm 2 reach.**

Published beside it, always, as the control that proves the contradicting path could have fired (L159): **how many of the measured negatives were actually observed by the second arm at all**. If that control is short, the report says **UNDERPOWERED** on the control, not only on the population size. A rate computed over shows Dan chose to prep is explicitly named as *not the quantity the gate needs*.

**The bar is recorded before Phase 5 ships, not read off afterwards (L182).**

- **Minimum population: 25** shows verdicted negative by arm 1 within the primary stratum, each with an arm 2 reading.
- **The bar: at or under 10 percent** of arm 1's negatives are reached by arm 2. Above it, Phase 6 does not ship and the finding is a Phase 4 defect to fix.
- **The second stratum's rate is printed beside it with no bar attached**, labelled as the harder, enriched reading.
- **The population size and the control print on every reading**, the pattern `ReplyInvariantsLiveStoreTests`'s corpus line established.

**The standing measurement still exists, and is honestly labelled.** Alongside the experiment, keep the cheap observational count (negatives that later acquire a route from any source), with its own three states, `measuring` with the population size and rate, `DORMANT`, `NOT REPORTED`, and a written note in its own output that it is **suppressed by construction** and is a trend line, never a gate. It reads `foundAt` where present and **the marker plus `contradictionPriorResultRaw` plus archive attribution where not**, because the contradicting rows measured today all predate the stamp and a check keyed on a marker cannot see anything written before the marker shipped (L223), and because `no_email_found` and `social_only` are different findings about the hunt so the marker has to say which was contradicted. **This is the second reason the 0.3 marker exists, and the only reason `contradictionPriorResultRaw` is stored** (L46).

**And say what it means after Phase 6.** Once the second hunt is gone, the contradiction the standing count observes is *produced by* that second hunt (L277). It goes DORMANT by construction on the day Phase 6 ships, and that day must not read as a clean bill of health. Phase 6 **repurposes** it: "shows verdicted negative that Dan later reaches by hand or that acquire a route from any source", a weaker instrument, labelled as one in its own output.

**Where it is evaluated (L51, L13).** The check is user triggered, so there is no run loop to hang this on. It is evaluated at **app launch**, beside the store backup and the launch migrations, and as a **`scripts/test-all.sh` advisory**, beside the live corpus readout, carrying the same age bearing record so an absent run reads as "last measured N days ago" rather than as silence, and **a run that measured nothing does not stamp the record**.

**The record's path is a seam (L250).** It lives beside the repo, gitignored, with the date inside the file rather than as its mtime, and #3161 is the record of what went wrong with exactly that: `check-tree-untouched.sh` decides from `git status --porcelain -uall`, which lists untracked files and never ignored ones, so a fixture drove the real wrapper and wrote a live store record into the repository root asserting both invariants had measured rows on a day the store held zero of both, and the guard passed clean. So **the path is injectable**, every fixture that drives the writer points it somewhere disposable, and a test asserts a suite run leaves the real path byte identical.

---

## Phase 6: Remove the Prep hunt (last, and gated)

`docs/prep-runbook.md` section 1 (lines 241-679) stops being run by the Prep pass; Prep drafts from the recipients already on the row. The queue item's `reprepMode: "contacts_only"` path and `PrepImporter`'s Prep side correction (`PrepImporter.swift:189-191`) go with it.

**The gate is the Phase 5.2 experiment clearing its pre-recorded bar over the PRIMARY stratum** (population at least 25 negatives with both arms read, arm 2 reach on arm 1 negatives at or under 10 percent, control not UNDERPOWERED, runbook revision named), **not a receipt, not a green suite, and not the standing observational rate.** Dan can move the bar (decision 5); he cannot be asked to read a number with no bar beside it.

**Answering the brief's second question: is moving expensive contact work to triage right at all, given fact F?** 209 shows have had a check spent on them; 20 have ever been sent. On that ratio, contact finding at triage spends roughly ten times what contact finding at keep time would. The counter argument is that reachability is an *input to the keep decision*, so deferring the hunt changes what Dan is choosing between, and #1585's design decisions put reachability at triage deliberately. **The plan keeps the hunt at triage** and treats the 10 to 1 as the price of that decision rather than as waste. But the ratio is worth a separate issue: a **cheap first pass at triage** (does any target have a canonical domain at all) with the full hunt at keep time is a real alternative shape, and it is not this feature. File it. Note also that this same ratio is what makes the Phase 5.2 suppression real.

### **[R3] Finding the guards that defend the removed behaviour, in BOTH languages (L252, L320)**

Before implementing, list the tests asserting the removed rules, **and know what each tool can see**:

1. **`scripts/find-tests-naming.sh <symbol> ...` covers the SWIFT half only.** Its `ROOT_LIST` at `:63` is `mac/OvertureTests` and `mac/OvertureHostedTests`. **It cannot see TypeScript at all.** Revision 2 named it as the tool for this job and added "a run that names nothing means the symbols are spelled differently in the tests, not that there is nothing to delete", which would have explained away a tool that was never looking (L320: a run over a set that cannot contain the answer looks exactly like a run that found nothing). That sentence is deleted.
2. **The guards defending `docs/prep-runbook.md` section 1 are all TypeScript**, and they are found by an explicit sweep: `rg -n '<symbol>' src/ fixtures/ docs/`. The named subjects, verified 2026-08-30, are:
   - `src/lib/prepRunbookRules.ts:20-37`, which holds hard presence patterns for `never-host-venue-target`, `venue-address-disqualified`, `press-media-disqualified`, `agency-inbox-never-satisfies-step-two`, `never-hunt-the-agent` and `empty-answer-carries-a-reason`, plus the Carnegie press example;
   - `src/lib/prepRunbookRules.test.ts`, which asserts them;
   - `src/lib/prepEval.ts` and `src/lib/prepEval.test.ts`, which score `fixtures/prep-eval/` against the same rules;
   - `fixtures/prep-eval/`, whose fixture names are the removed behaviour written down (`host-venue-not-target.json`, `agency-inbox-is-not-the-performers-contact.json`, `carnegie-citywide-press-inbox.json`, `presenter-not-venue.json`, and the rest).
   
   **Every one of those is a guard whose whole content is the behaviour being removed, so it is deleted or re-pointed in the same change, never adjusted** (L252).
3. **`src/lib/docsCommands.test.ts` asserts that every path AGENTS.md mentions still exists**, so the AGENTS.md paragraphs describing the removed hunt move in the same PR or that test goes red for a reason unrelated to the change (L32).
4. A run of either sweep that names **nothing** is a finding to investigate, not a clearance: for the Swift tool it means the symbol is spelled differently there, and for the TypeScript sweep it means the pattern is written as a regex in the rules file rather than as the literal symbol.

The #3007 watchdog logging, both archive retentions, `incomplete`, 1.3's measured attribution rate, `TargetPriorityCheck`, and the Phase 4 enforcement must all be in place first, since removing the second hunt removes today's repair path.

---

## Cross cutting rules this plan is built to

- **Fail loud.** Every refusal in 0.2, 3.4, 4.1, 4.2 and 4.3 logs the natural key and the reason. Nothing swallows. The `try?` that turns an unsupported version into a silent 90 day lockout gets its own issue in Phase 2's sibling enumeration, and the version constant unification in 4.0 is its partner.
- **Assume it runs twice.** Every write here is on a path that can settle the same results file twice. All are pure functions of current state returning new values, applied by the caller.
- **Who may call it, whose data it touches.** No network routes are added. The one privilege question is the 0.3 migration: it **deletes organisation ledger rows** and, if decision 7 approves, writes every unsent prospect, in the single user local store, refuses without a confirmed launch backup, and ships with its reverse covering both.
- **Keep the good state, and record what the repair destroys.** 0.2 and 0.3 are the whole of this. Nothing overwrites a verdict it did not earn; nothing sweeps without a snapshot that has a tested reverse; and the contradiction the repair removes is stamped on the row before the repair runs (L277).
- **A recorded decision is not reversed as a side effect.** Where a change would overturn something Dan decided, the decision is quoted from the record it lives in, with that record's date, and put to him as its own question (L249, L204). Decision 7 is the instance.
- **Evidence beats the run's account of itself, for fetches AND for searches.** Wherever a rule judges the run, the attribution sidecar is the authority and the run's own field is the claim, with disagreement given its own outcome.
- **A shape filter is measured in both directions.** Any rule that recognises data by its shape publishes its precision on the content it must PRESERVE beside its recall on the content it must catch, before it is enforced (L104).
- **Every new value is typed, and independent checks never share a field.** A vocabulary Dan reads is an enum with an exhaustive switch and a distinct sentence per case, decoded through `init(rawValue:)` at every boundary (L113). Where several rules can fire on one row, each owns its own counter and its own bar (L53, L517).
- **Every new value has a reader named in the same change, or it is deleted.** `billingRank` has `TargetPriorityCheck`; `contradictionMarkedAt` and `contradictionPriorResultRaw` have `WrittenOffBacklog` and the 5.2 trend line; `contradictionPriorEmptyReasonRaw` had none and was deleted; `reachabilityIncompleteRunCount` has the card, the lists and the candidacy path (L46).
- **A persistent condition gets a persistent surface with an action on it**, never only a run summary that clears (L126). **A hand set suppression gets an expiry and a place it is listed** (L523).
- **One acknowledgement is read by every rule that raises the question.** A durable answer Dan gives is an input to one shared predicate consulted by every offer path, never a field one rule writes and another never reads (L330).
- **A store is drained by the key it is written by.** Consumers with different lifetimes get different directories, and the retention test counts what survives on disk (L285, L191, L212).
- **Identities are redacted where the evidence is RECORDED.** No real name or host in this plan, in an issue, in a PR body, or in a fixture. Fixture corpora are **generated** artifacts emitting shapes and counts; `scripts/check-test-identity-provenance.sh` runs over every change that adds test data. **This explicitly covers the attributed search queries**, which carry real names.
- **Every guard seen to fail.** Each phase names the mutation, proved with `scripts/mutate.sh` with `--at` **first** and literal (`--at-regex` when a pattern is genuinely wanted), scoped through `mac/scripts/run-tests-locked.sh`, never raw `xcodebuild`, with the exact failure text recorded in the PR body. Read a `SURVIVED` carefully: check the scope actually ran a suite naming the mutated file, and check the needle is not answered by a second harmless occurrence in the same file. Escape `\$`, `\@` and `\|` in the perl expression.
- **Three states, never two,** wherever a check can be unmeasured. Applied to coverage, attribution, canonical domain evidence, search evidence, claim versus evidence disagreement, `webCalls` completeness, `no_such_site`, `TargetPriorityCheck`, `RunCoverage`, the experiment's control, both experiment strata, and the standing measurement.
- **A tool is only asked questions its scope can answer.** Where a sweep is scoped to one tree, the plan says so and pairs it with a sweep over the other (L320). Phase 6's Swift and TypeScript sweeps are the instance.
- **A cited line number, size or version is re-read before it is quoted.** Revision 3 corrected nine such citations; the method is a grep and a `sed -n`, not memory (L32, L210).
- **Fixtures do not age.** Every dated fixture added here goes through `scripts/check-fixtures-do-not-age.sh --record` in the same change; new entrants are read, not rubber stamped. Every fixture holding a far future date goes through `scripts/check-far-future-fixtures.sh`.
- **Temp files and processes.** Every script uses `overture_scratch_dir` / `overture_scratch_file`; every fixture uses `fixture_scratch_dir` and, where it starts anything, `fixture_run_in_own_group`.
- **Copy.** Every phase touching a sentence Dan reads regenerates `docs/copy-inventory.md`, `docs/outbound-copy.md` and `docs/copy-surfaces.md`, and the diff is cold read in every branch including the empty one.
- **PR bodies** carry the literal words *writer*, *reader*, *sibling*, *seen*, and a `Closes` keyword before **each** issue number rather than fronting a list.

---

## Order of work, and what ships independently

| Phase | Ships alone | Model spend | Blocks |
|---|---|---|---|
| 0.1 **two** predicates, four sites, the cascade preservation test, the hand-pitch decision, the fifth hold decision | yes | none | everything |
| 0.2 five missed-by-a-check call sites through one predicate, then incomplete fields with a **typed reason SET and per-reason counters**, the refusal, the card surface, the **set-aside with an expiry through one shared offer predicate**, observe then enforce | after 0.1 | one run to observe | Phase 2, Phase 6 |
| 0.3 **Step 0 stamp the contradiction**, re-measure through the app's predicates, **ledger correction unconditionally**, reverse migration covering both, **prospect verdict sweep gated on decision 7**, then `WrittenOffBacklog` over the marker | after 0.1/0.2 | none | the sweep, Phase 5.2 |
| 0.4 #3283/#3289 | yes | none | Phase 5 |
| 0.5 **the empty-answer report's writer/reader split**, verdict-scoped, with the 62 excluded rows reported | after 0.1 | none | - |
| 1.1 shared `stream_completed` | yes | none | 1.3, 4 |
| 1.2 archive events and the sidecar in **their own dated directories with their own keeps**, retention test counting what survives (#3346) | yes | none | 1.3, 4, 5 |
| 1.3 attribution sidecar covering searches as well as fetches, archived, then measured on a real multi-item run | after 1.1/1.2 | none to build; one archived multi-item run to measure | 3.4, 4.3, 4.4, 5.2 |
| 1.4 interleave chunks (sibling: scout-extract) | yes | none | any comparison |
| 1.5 log watchdog kills | yes | none | any comparison |
| 1.6 constraint-8 note (no code) | n/a | none | - |
| 2 `incomplete` badge, routing, all-incomplete notice, `routeNamedButNotSupplied` | after 0.2 | none | 4, 6 |
| 3 targets v14 with `billingRank` (+ `ListingBilling`, possibly disabled) | after 2 | none | 4 |
| 3.4 `TargetPriorityCheck`, observe | with 4 | one run to observe | 6 |
| 4.0 **app reader first, `supportedVersion` to 12, one shared merger constant, INEQUALITY fixture** | after 3, 1.3 | none | 4.1+ |
| 4 per-target answers v12, `no_such_site` judged on search evidence, **precision measured before both observe runs**, coverage observe, canonical rule observe | after 4.0 | two runs to observe | 6 |
| 5.1 `foundAt` + send-path staleness | after 0.4, 1.2 | none | 5.2 |
| 5.2 two-armed experiment over the **negative-verdict corpus (77)** and the **marked set (33)**, plus the standing trend line | after 4, 5.1, 1.3's measurement | one full hunt per arm over the primary stratum | 6 |
| 6 remove the Prep hunt, **Swift AND TypeScript guard sweeps** | gated on 5.2 clearing its bar on the primary stratum with a sound control | reduces | - |

**[R3] The smallest first change that makes live-dated unreachable shows recoverable is 0.1 alone, and it recovers roughly 7 to 11 shows, not 28.** The badge already re-derives through `reachabilityResultAsHeld`, so the 27 routed `named_but_no_route` rows are not written off on screen. What 0.1 fixes is the population whose live badge suppresses an existing unguarded address: **11 rows measured, a lower bound**, of which **4** carry a stored `no_email_found` and **3** have a date still ahead. It costs no model spend. 0.3's ledger half ships beside it because 0.1 changes what `foundEmails` means on 32 ledger rows; 0.3's prospect verdict sweep is a separate decision.

Phases 0 and 1 are thirteen changes; eleven need no model spend, and the two that do (0.2's observe run, 1.3's measurement) ride along on a check Dan was going to run anyway.

---

## Decisions escalated to Dan

The first six are unchanged in substance. The seventh is new in this revision and is the largest.

1. What does a card say when its last check came back incomplete, and what does the app say on a run where more than half the shows settle incomplete? The named people and the "Only names, no way to reach them" badge stay per your decision; what changes is the sentence above them, from a claim about the show to a claim about the search.
   - I write both sentences myself; show me the rendered card and the run notice, not the code
   - Draft both, show them rendered in every branch (found, incomplete, never checked, empty list), and I will edit
   - Use "The last check did not finish for this show" plus a re-check offer, and a run-level line naming the count; ship it and I will correct it live

2. Phase 0.1 moves the contact tier onto the same clean address predicate as the verdict, which is what keeps the badge and the fit score answering from one list. Consequence: shows whose only address is held by an uncleared calendar conflict acquire a tier they did not have, and their fit score moves. Separately, the hand-pitch control disappears from those rows, because they now have a working address. Should both happen?
   - Yes to both: a blocked night is not a fact about reachability, and a show with an address is not a hand-pitch case
   - Move the tier, but show me the per-direction count of score movements and the count of rows losing the hand-pitch control before anything writes, and let me abort
   - No, leave the tier where it is and accept that the badge and the score answer from different lists

3. After Phase 6, the route found at triage is the only route, and nothing re-confirms it before the send. The plan proposes a warning (never a block) on the send sheet when a route is older than 60 days. Is 60 the right clock?
   - 60 days, warn only, with the age named in the sentence
   - 90 days, matching the verdict's own freshness window
   - 30 days: an inbox goes stale faster than that and I would rather be told too often
   - No note at all; I will judge it from the card

4. Phase 3's listing-billing parser reaches at most 27 of 97 shows on the measured queue. Below what precision on person targets should it ship disabled rather than enabled?
   - Ship it enabled at 90 percent precision or better, disabled below that with the activating issue filed
   - Ship enabled at 80 percent or better: a wrong extra target costs one wasted lookup, a missed lead costs a show
   - Ship it disabled regardless until I have read a full run's worth of what it named

5. Phase 6 is gated on a two-armed experiment over every show carrying a negative or weak verdict, measured at 77 today (the earlier plan's population would have had 10 shows in it against a minimum of 25). Bar: at least 25 negatives with both readings, and the deep arm reaching at most 10 percent of what the single hunt called negative. Is that the right bar, and do you approve spending two full hunts over that set?
   - Yes to both: 25 and 10 percent, and spend the two runs
   - Approve the experiment, but I want a stricter bar: at most 5 percent reached
   - Approve the experiment, looser bar: 20 percent reached is fine if the misses are all shows with no site at all
   - Do not remove the Prep hunt at all; keep it as a cheap conditional second look on kept shows only

6. A show can come back "incomplete" over and over, and each time it does it returns to the check's candidate list and costs another lookup. The plan puts the count and a "set this aside" control on the card (with an expiry, and a list of what is currently set aside), plus a list of the repeat offenders. The question is whether the app should ALSO stop offering such a show by default after N failures, with the reason named and an override always available. I did not decide this myself because on #2513 you said "It's not the app's decision which shows I pitch", and declined even a note at the moment of buying, choosing a report instead.
   - Yes: after 3 failures stop offering it by default, name the reason on the card, and let me ask for it anyway
   - Yes, but a higher N: 5
   - No automatic exclusion at all: leave every show in the default set, and I will use the set-aside control and the list myself
   - No exclusion and no card line either: just the list, and I will go to it when I want it

7. **[R3] NEW, and the one I most need you to answer.** The earlier version of this plan proposed re-deriving the stored reachability verdict for every unsent show, presented as a repair. Two things it did not notice. First, **the card already re-derives** (it reads what the show HOLDS, not what the check concluded), so this changes nothing on any badge; what it changes is **the RANKER**, across roughly 690 rows. Second, the ranker's own code records your call of **2026-08-13**: "#2664 briefly made this follow the badge... Dan's call, 2026-08-13, on being shown that this went further than the decision he actually made: the badge was what he chose, and **ranking stays tied to what the paid check CONCLUDED**." A blanket re-derive is that reversal undone. There is a second recorded decision in the way, from **2026-07-27**, in `ContactFormResultMigration`'s own comment: "A blanket re-derive would also move a badge whose venue warning Dan has since dismissed, and he decided on 2026-07-27 that dismissing a warning makes the address sendable but does NOT move the badge until a re-check."
   - Leave the ranker alone. Fix only the 4 rows that carry a stored "no email found" over a live route, one direction only, the way the existing narrow migration already works, and delete nothing
   - Re-derive the whole stored verdict, and yes I am reversing my 2026-08-13 and 2026-07-27 calls: show me the per-direction counts and the fit-score movements before it writes, and delete the now-dead narrow migration in the same change
   - Re-derive it, but only for shows whose date is still ahead, and leave the past ones carrying what the check concluded
   - Show me the 4 rows and the 11 badge-suppressed rows first, and I will decide after looking at them

---

## Open risks

1. Phase 1.3's attribution rests on the runbook's instruction to rewrite the results file after each item, and no evidence on disk verifies that instruction is followed: every surviving chunk stream holds one show and exactly one `Write`, and one holds zero. If the real per-item rewrite rate is low, most chunks come back UNATTRIBUTABLE and the canonical-domain rule, the search-evidence rule, the proof, `TargetPriorityCheck` and the experiment all degrade to "unmeasured" at once. The plan sequences a measurement ahead of those dependents, but the measurement could come back bad and there is no fallback designed yet. **This risk grew in revision 2** because `no_such_site` and `TargetPriorityCheck` now depend on attribution too.
2. **[R3] The version risk is on the PREP path only, and the plan's earlier framing of it was itself dangerous.** The live prep results file is version 11 against a `supportedVersion` of 11: zero cushion. The check path is at 6 and has five versions of cushion and is not moved. Revision 2 proposed a fixture asserting all three versions are equal, which is false today and whose only green path was bumping the check literals to 12 before the app reader shipped, which **is** the lockout. The fixture is now an inequality. The window between shipping the app reader and shipping the runbook edit is still real.
3. **[R3] The canonical-domain rule is close to a coin flip, on corrected numbers: 19 of 36 form-bearing hosts carry a name token and 16 do not** (revision 2 said 25 of 46 and 18). Enforcing at the 65 percent bar could still demote a large share of genuinely searched shows to incomplete, and incomplete rows return to candidacy, so the cost lands as repeat checks rather than as a visible error. **And the precision half is now measured before enforcement rather than after**, which is the new mitigation; nobody has yet seen that number either.
4. Phase 5.2's experiment needs the deep arm to be a faithful reproduction of today's Prep hunt at the moment the experiment runs. If Phase 6's removal work has begun, or the runbook has drifted, the two arms are not measuring what the gate claims. The experiment runs against a pinned runbook revision and names it.
5. **The gate population changed once already, on measurement, and its corrected size is 77.** It shrinks every time a check answers a row correctly, which is the feature working. If Phase 0 through 4 succeed as intended, the population the gate needs gets smaller as the product gets better. That is why both strata are recomputed and printed before the experiment starts and why an under-25 primary stratum reports UNDERPOWERED rather than running. Set-aside rows are reported and excluded so the stratum is not quietly shrunk by suppressions.
6. **The 0.3 migration deletes rows from a second entity**, and that half ships unconditionally. Deleting an organisation ledger row removes an inherited answer from every sibling show of that organisation until the next settle rebuilds it, so a show that showed "Email found" inherited from a sibling will show nothing until a run settles again. That is the correct direction and it is reported, but it is a visible change to what Dan sees on rows he did not touch.
7. Nothing in this plan reduces the 209-checked-to-20-sent ratio, and the same suppression that makes the standing contradiction count untrustworthy also means a systematically too-negative hunt would look like a quiet queue rather than like a defect. The all-incomplete notice, the per-run incomplete counts, the card line and the two lists are the only surfaces that would speak, and all are new and unproven in production.
8. **[R3] Archiving event streams adds about 1.7 MB per run against a queue-and-results pair whose MEDIAN is about 40 KB** (the seven archives measure 24, 36, 40, 40, 52, 92 and 224 KB; revision 2 quoted the 224 as the baseline). At `eventArchiveKeep = 10` that is roughly 12 times the existing archive footprint, not 8. The three separate dated directories are what stop one consumer's rotation draining another's, but nobody has yet watched any of the three rotations run in production, and `eventArchiveKeep` is sized on one night's files: a busier run with more chunks scales it linearly.
9. **`billingRank` is only as good as the parser that sets it**, and the parser reaches at most 27 of 97 shows and may ship disabled. On every unranked target `TargetPriorityCheck` reports UNMEASURED, so on the long tail the targeting half of the brief is answered by nothing at all. The check is honest about that rather than silent, but honest and absent is still absent.
10. **[R3] Decision 7 can block Phase 5.2's primary stratum from behaving as modelled.** If Dan declines the verdict sweep, the corpus stays at 77 and the gate is well powered. If he approves it, the corpus shrinks by however many rows the sweep moves, and the experiment must be re-sized before it runs. The plan prints both strata before spending, which is the mitigation, but the sequencing means a decision taken in Phase 0 changes the power of a measurement taken in Phase 5.

---

## Ideal versus doable

The ideal version closes the judgement gap rather than bounding it: a second, independent reading of the same pages by a different reader, disagreeing per target, so that "chose the wrong canonical domain" and "read the page and missed the address" are detectable rather than merely unprovable. That is what the current second hunt accidentally provides, and this plan removes it. It is deferred because a real judgement check means either keeping a second full hunt (the thing Dan has decided to remove, and which fact F prices at roughly 375 hunts for 20 emails) or building an adjudicator that re-reads fetched pages, which needs the archived page bodies this plan does not capture and would double the per-show cost for a benefit nobody has measured. The Phase 5.2 experiment is the affordable substitute, and it is honest that what remains after Phase 6 is a trend line rather than an instrument. The second deferral is the cheap-first-pass-at-triage shape, filed as its own issue because it changes what Dan is choosing between at triage. The third is capturing fetched page bodies alongside the event streams, deferred on retention grounds until the event archive's real size is observed in practice.
