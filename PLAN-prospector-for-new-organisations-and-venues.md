# Prospector for new organisations and venues

Planned with `/plan-council` on 2026-08-10. 24 agents, 89 minutes. Planning record only: no application code was written or changed.

## Verification status, read this first

- Reality check after 2 correction rounds: **needs-fixes**, 6 claims still wrong.
- Lessons audit: **violations**, 9 violations against 98 recorded lessons.
- Preflight: repo fully readable. No hosted database schema was reached because this project has none (Supabase is the retired architecture); the panel measured against a WAL consistent online backup of the live SwiftData store instead.

### Reality check: claims that do not reproduce
1. P3.3 states the accept path's recurring cost is 'not AI'. That is wrong. ScoutReadBudget's `pending` counts pages whose CONTENT CHANGED and therefore need a PAID read (ScoutReadBudget.swift header: 'the question moved to where the money actually is'). Every accepted organisation adds a source that will trigger a paid AI read on any scout where its calendar changes. The cost line must say: a fetch-and-hash that is free, PLUS a paid read every time that calendar changes, PLUS Dan's time. Rewrite before filing, because the task's hard constraint is that each phase states its cost honestly in time and run count.
2. P3.3's mechanism is misread: 'Accepting twenty organisations makes the "N calendars have new listings to read" prompt fire on nearly every scout.' askAbove=20 is compared against pending CHANGED sources, not the watchlist total (73 today, already far above 20, and the prompt does not fire on nearly every scout). Twenty new sources raise the pending count only on nights when all twenty changed. The concern is real; the stated mechanism is not.
3. P1.2 frames the forward L5 hazard as conditional: 'After P1.1 the OvationTix and TicketTailor adapters emit nil for exactly the room-named rows P1.2 and P1.4 have just filled.' The erasure is ALREADY LIVE. ExtractedEventGuard.presenterThatIsNotTheRoom is applied on both ingest paths today (ScoutService.swift:546 and ScoutExtractResults.swift:50), so `existing.presenter = p.presenter` at ScoutService.swift:1420 already nils a room-named presenter on every ordinary re-read. A P1.4 answer written before the provenance guard ships would be erased by the next scout, not by a future adapter change. This makes the guard a PREREQUISITE of P1.4 rather than a companion to P1.1, and the issue ordering should say so.
4. P4.2's pool row count is wrong: measured 221 organisations over 259 rows, not 261. (The 221 is exact; only the row total is off.)
5. P4.2's blank-location count is wrong: measured 10 pool organisations whose every row has an empty ZLOCATION, not 11. The ten are Elizabeth Acevedo, Kyle MacLachlan, National Theatre Live, On Her Shoulders, R.F. Kuang, Selected Shorts, Silent Clowns Film Series, The Folk Music Society of New York, Treble Harmony Brigade, Uptown Showdown. (Three of those are bare personal names, which is useful evidence for P0.1(d)'s unmeasured filter and should be cited there.)
6. P3.2's arithmetic is off: measured through ProducerGate.Corpus, 237 of 254 presenters play exactly ONE distinct venue (nobody plays zero); 17 clear the >= 2 arm. The plan says 235. The argument is unchanged and slightly stronger, but the number as written does not reproduce.

### Lessons audit violations
1. **L16** at Phase 4. P4.2 states "The pool is sized through `GroupNameMatch.isConfident`, the shipped fold, and it is 225 of 254" and reports the headline pool as 221 organisations. P4.1 states `AlreadyKnownOrg` "must not become a fourth org fold (P2.1). It reads P2.1's claim set and nothing else", and P2.1 states "name -> the claim reuses `OrgKey.of`".

   The count Dan is shown and the rows the channel will actually propose are decided by two different predicates for the same question (is this organisation already known). The plan itself measures that these two folds disagree: it records that `OrgKey.of` does not strip a leading article while `ProducerGate.key` and `GroupNameMatch` do, and that `GroupNameMatch.isConfident` collapses "The New York Neo-Futurists" onto the watched "New York Neo-Futurists". So the 221 headline is produced by a fold the shipping filter will not use, and the release note P4.2 promises ("its release note states the organisation count") is a promise about rows a different predicate selects. This is the exact L16 shape, and it also silently reintroduces the fourth-fold problem P2.1 was written to prevent, since two folds now decide one question.

2. **L55** at P1.2 and P1.4, which add `sweep` and `aiBatch` as new writers of `Prospect.presenter`, targeting exactly the rows the plan counts as "337 rows flagged `presenterWasTheRoom`" and "454 rows with no presenter". Neither issue re-checks any rule that reads `presenterWasTheRoom`.

   `presenterWasTheRoom` is a stored flag with live readers. `mac/Overture/UI/QueueView+Model.swift:36` documents it as "#1788: this row's blank presenter is a name Overture DISCARDED, not a page that named nobody", and `:2069` copies it onto every queue item. `mac/Overture/Domain/PrepQueue.swift:106` explicitly declines to use the flag and derives `onlyTheActIsNamed` live from presenter emptiness instead. Once P1.2 or P1.4 writes a presenter onto a flagged row, the stored flag stays true while the presenter is no longer blank, so the queue card asserts a blank-presenter explanation on a row that now names an organisation, while PrepQueue's live derivation quietly corrects itself. That is L55 precisely: a reader whose correctness depends on which code path produced the state, breaking silently when a second writer appears, with the assumption recorded only in a comment.

3. **L92** at P2.2 shape and mechanics. The read side says "A blocking match on ANY claim. A group first seen on a venue listing has a name and no URL; the same group seen later has a URL and a different spelling. One key cannot cover both." The write side says only "`@Attribute(.unique)` on the stored claim so two refusals racing cannot leave two rows that disagree", and nowhere states how many claim rows one refusal writes.

   The plan specifies any-claim matching on read but leaves the write as a single unique-keyed claim. A refusal recorded against only one of the claims a proposal carried does not block the same group arriving later through a channel that produces a different claim kind: a name-only refusal never blocks the Instagram handle (P9.1) or the listings URL, and a host-only refusal never blocks a name. This is exactly overture#2392 -> #2421, which the plan cites: the recording works perfectly on every item you tested it on, and is blind on the items that lack the recorded identifier. Constraint 6 is that a refusal MUST be remembered so the same group is never proposed again, so this is the milestone's own hard requirement leaking.

4. **L95** at P1.2's change to `RoomPresenterSweep`: "`RoomPresenterSweep.run` keeps clearing a room-named presenter ... but may no longer do it silently: when the presenter it clears is not `scout`-sourced, it records an explicit cleared-because-it-named-the-room fact against that (group, venue) pair", whose named reader is "P1.4's batch selector (which must not re-pay for a pair already answered and then cleared)".

   This adds a durable WRITE to a classification path that until now only cleared a field, and the shipped file's own header states the clearing is recoverable by design: "Runs every launch for the same reason the merges do, since a later scout can write the name back" (`mac/Overture/Domain/RoomPresenterSweep.swift`). Once that path also writes a permanent exclusion, a misclassification by `ExtractedEventGuard.presenterThatIsNotTheRoom` stops being a recoverable wrong field and becomes a permanent lockout from the only pass in this milestone that actually names organisations. The classification was never audited against that new consequence. The plan supplies its own evidence that this family of room detectors has real false positives on real organisations: it measures the sibling `ProducerGate.isVenueBrand` dropping "Museum of Chinese in America and Chinese Theatre Works" and "52nd Street Project". And the path is not rare: 337 rows already carry the flag.

5. **L96** at P7.1's "declared junk exclusion list, measured at floor 2: `stage` (5), `google meet` (3), `337 e 6th st #4` (2), `398 broome street` (2), `75 river terrace` (2), `brasserie 8 1 / 2 and rosie o'grady` (2), `holy apostles soup kitchen 296 9th ave on` (2)", combined with P0.1(a)'s invariant "every declared junk shape is in the declared set".

   That is a hand-written registry of literal folded keys standing beside a source the plan itself says is regenerated wholesale ("the shoot history is regenerated wholesale and a re-export can re-mint ids"). The guard checks only what the registry lists, so the next Zoom link, street address, or scratch entry Dan types into Downbeat is exempt from the very check written to catch it, and P0.1's invariant reports green while blind. It is also L41: a list mirroring another source of truth, maintained by hand beside it, drifting silently. The plan applies L96 correctly to P0.2's realignment coverage and then does exactly the thing it forbade here.

6. **L77** at The declared ship order "Phase 0 -> 1 -> 2 -> 3 -> 4 (store-only channel, the first shipping channel) -> 5 -> 6 (harness) -> 7 -> 8 -> 9", against P6.4's rejection-rate requirement, which lives in Phase 6 and is phrased "report per run".

   Phase 4 is the first channel Dan actually sees, and it is the one channel with no run at all ("ZERO runs, ZERO fetches, ZERO AI"), so P6.4's per-run rejection accounting neither applies to it nor exists yet when it ships. Phase 4 rejects candidates through four filters the plan names (the geography gate, `ProducerGate.isVenueBrand`, the refusal set, bare personal names), and every one of those rejections is classified as an ordinary expected outcome that nothing counts. A geography predicate that started answering false, a fold change from P0.2, or a `GroupNameMatch` regression would empty the channel while producing exactly the same screen as "you already watch everyone", for as long as it lasts, and the detector goes back to being Dan noticing nothing has appeared. The plan states this lesson for the run-based channels and then ships the first channel without it.

7. **L4** at P0.2's realignment pass: "the pass is rehearsed against a WAL-consistent copy of the Release store with a before and after row count per table before it ever runs at launch on Dan's machine". Nothing in the plan verifies the pass actually ran, or what it did, on Dan's installed Release store afterwards.

   A rehearsal on a copy plus a merged PR is not a completed migration. This pass re-keys protective tables and, on the answer-shaped tables, deletes duplicate rows. It runs at launch inside a build Dan has to install, and AGENTS.md records that the installed build reaches him through `update-overture.sh` and the freshness panel, which have their own refusal paths. So the change can be merged, green and entirely absent from the store it exists to correct, and every downstream phase reads keys assumed to have been rewritten. That is L4, on the one step in this milestone that touches rows that cannot be reconstructed.

8. **L91** at P2.2's shape note: "Never `RefusedContactAddress`. `mac/Overture/UI/QueueView.swift:46` holds `@Query private var refusedAddresses` ... so every refusal click would invalidate that query and rebuild the whole queue." The plan then chooses a new model and stops, while P3.2 does the full enumeration only for `WatchedSource` and `PromotedProducer` inserts, in a later phase.

   The diagnosis is right and then stops one model short. `RefusedOrgClaim` is read by the proposal filter (P2.2c) and by `AlreadyKnownOrg` (P4.1), so any surface holding those as a live `@Query` is invalidated by every refusal press. P2.3 ships the refuse control and its undo in Phase 2, two phases before P3.2 does the enumeration work, so the refuse press is the one control in this milestone that ships with its invalidation cost unexamined. Under L44 a control that lags reads as broken and Dan presses it again, and a second press writes into a unique-keyed table. The plan quotes L30 (fix the class) at itself in P3.2 and then leaves the earlier instance uncovered by ordering.

9. **L53** at P1.3's shared requirements for its two independent forced re-reads: "(a) `ovation_tix_feed`-scoped re-read" and "(b) `venue_tix_feed`-scoped re-read for Green Room 42's 164 rows", followed by "Shared requirements: one-shot, not a mode; clears `lastContentHash` for exactly the selected `WatchedSource` rows, records that it did, idempotent by a stored marker".

   Two passes with two separate justifications (the plan is explicit that (a) is because the adapter changed and (b) is because #2259's boundary rule shipped after those rows were written) are given one idempotency marker. A pass that has run then marks the other done, so the second re-read silently never happens and its 164 rows keep the wrong presenter, while the surface reports the one-shot as complete. That is L53: a pass from one check erasing the other's failure through a shared status field, and it is worse here because the two are precisely the inputs P1.4 is ordered to run after.

## Why this option won

Winner: "engine" (seed-manifest discovery engine), with mandatory grafts from both rivals.

Why not "harvest", despite being the cheapest. Its measured work is the best-grounded material on the panel (the OvationTix/TicketTailor supertitle discard is real and is L30 sitting unfixed; the RefusedContactAddress/QueueView @Query rebuild point is real; its self-correction that a store sweep only reaches about 12 rows is the mark of an honest plan). But as a WHOLE OPTION it fails the brief twice. First, its actual recommendation is "build no finder, and gate #9 and #12 behind two weeks of send-rate data", which is the argument hard constraint 9 records Dan as already having heard and rejected ("chose breadth over precision HAVING BEEN SHOWN THE COST"). Judging is inside the settled constraints, and an option whose thesis is that the feature should not be built cannot win a scoring of how to build it. Second, its claimed #311 coverage is falsified by its own red team with numbers: only 49 of 167 shoot venues match anything Overture has ever scouted, so for roughly 71 percent of Dan's real venue history there is no group level fact to fold and the surface reads as covering #311 while structurally unable to (L83, cited and earned). Its two week send-rate gate is also a single noisy window against a 1 to 2 shows a night cadence (L36). It is an excellent Phase 1 and a poor answer to the question asked.

Why not "booked", despite the best risk profile. Its central claim is the one its red team measured false: folding overture-shoot-history.json through the real VenuePlaces.canonicalKey yields 151 keys, not "roughly 40 to 50", and even a band floor of 2 gives 33 inflated by fold failures that split Carnegie into three keys and split the already watched Merkin. That matters because the entire argument for the option is "the seed set is naturally small, so constraint 10 needs no architecture". If the fold is wrong by 3x and the tool was calibrated on a different corpus (L15, L48, L34), the cheap satisfaction of constraint 10 is not established. Its second pillar, the free already watched half, is conceded in its own champion case to yield mostly show titles: only about 75 of 866 rows carry a presenter that is not the room, and websiteURL is empty on all 866. So the free half is gated on exactly the presenter work it says it will defer. Finally, it treats one venue as one cost unit for a time cap when Lincoln Center and a boutique room are not remotely the same job (L81). The channel is still the right FIRST channel; it is not the right whole plan.

Why "engine" wins. It is the only option that reads constraint 10 as an architecture requirement rather than a copy requirement, and it grounds that in two in repo precedents that both work only because the app authored the work list (HandoffShortfall's own header says it never synthesizes a result and trusts the results file mtime over the run's self report; SweepCoverage treats a run that reported nothing as INCOMPLETE). A free ranging discovery run has no denominator, so "found nothing more" and "ran out of clock" are the same bytes: the app authored seed manifest is the minimum that makes those existing rules apply at all. It is also the only option that measured the identity trap rather than assuming it away: OrgKey does not strip a leading "the" and ProducerGate does, they disagree on The New York Neo-Futurists, and that is the single org Dan has ever removed, so a single key refusal would re propose it and break constraint 6 on the first name. Claim set refusal with one row per claim, matching on any, is the only shape that survives a group first seen as a name with no URL. The ProducerOverride promotion is arithmetic, not taste: 235 of 254 presenters play exactly one venue, so without promotion on accept, constraint 8 collapses into paying a fresh reachability check per show forever. Refusing to extend RunKind (a two case enum whose header records #1809 discarding every draft) and folding the runner flags through its own claude_scope function (check-detached-runner-scope.sh, the #1026 hole) are both the repo's own rules rather than invention.

Its red team lands one real hit and it is correctable inside the same architecture: seed level completeness as a single boolean recreates SweepCoverage's problem one level down for directory and search query seeds, which is a proxy guard (L63) and a loop with no stated volume (L24). That is a gap to close in the issue set, not a refutation of the design, and the seed manifest is the only structure on the panel that can host the fix. The secondary objections (AlreadyKnownOrg needing one declared fold, cost not stated per channel, a refused org resurfacing with zero shared claims) are all plan text corrections, and the last is a residual risk every option shares.

Cost was weighted first class and did not decide it, correctly: no option spends money, all three run on the Max plan, and the difference is run count and Dan's time. Engine's discovery is one capped on demand run per press plus one batched presenter pass keyed on 278 distinct (title, venue) pairs rather than 454 rows. Its genuine recurring cost is not AI at all: every accepted org becomes a WatchedSource fetched forever, and with 73 sources today against ScoutReadBudget.askAbove of 20, accepting twenty orgs makes the read budget prompt fire on nearly every scout. That cost is shared by booked and must be a named phase item, not a discovery.

Mandatory grafts into the winner, in this order:
1. Ship harvest's Phase 1 unchanged and first, including its self correction: one shared ProducerShapedName rule across all four call sites with a source text guard against a private copy, the honest ~12 row store sweep (state 12, not a vague number), and the hash bypass forced re read that is the only way the corrected boundary reaches the 337 already stored rows (L55).
2. Make booked's #311 the FIRST seed kind in the manifest, with its Phase 0 free measurement (print the real fold table at floors 1, 2 and 3, print the presenter fill rate, show the junk list, let Dan set the floor) and with the corrected 151 key figure, not 40 to 50, written into the issue.
3. Close the within seed coverage hole before any directory or search query seed is built: every seed records what it covered in the seed's own unit (pages, result ranks, months), never a boolean, and states its expected volume up front.
4. Adopt harvest's ledger keying decision verbatim (new independent @Model, never RefusedContactAddress, because QueueView holds an @Query on it and every refusal click would rebuild the whole queue, cf. #2417), and ship Refuse and Propose again in the same change (L97, #2392/#2408).
5. Adopt booked's folded venue idempotency key and its reuse of HandoffShortfall for the truncation report over an app authored queue.
6. Adopt harvest's success metric: emails sent per week wired against ZSENTAT (currently 6 ever), never proposals produced, and wire it so it cannot report a confident zero from a value nothing writes (L90). Use it as a phase gate between channels, not as a veto on the feature.
7. Name the WatchedSource growth and the ScoutReadBudget.askAbove consequence as its own issue in the milestone, with a decision for Dan about the threshold, before the first accept path ships.

## The plan

> **Scope note.** Planning and issue-filing only. No application code is written or changed by this document. Every number below was measured on 2026-08-10 against a WAL-consistent SQLite ONLINE BACKUP of `~/Library/Application Support/Overture/Overture.store` plus the real handoff files in `~/Library/Application Support/Overture/`, or read out of the source in this checkout. Where a number came from running SHIPPED Swift (compiled straight out of `mac/Overture/Domain/`), it says so; where it came from a reimplementation, it says that instead, because a reimplementation can only confirm my own assumption about the real rule (L52).
>
> **Cost is stated in TIME and RUN COUNT, never dollars** (Dan is on a Max plan). Every phase carries a cost line and names its free version.

---

## What I measured before planning

Everything in the "shipped code" rows below was produced by compiling the real files (`VenuePlaces.swift` + `VenueNormalization.swift`, `ProducerGate.swift` + `ProducerOverride.swift`, `ProducerShapedName.swift`, `GroupNameMatch.swift`) with `swiftc` and running them over the live data. No copies of any rule were written.

| Fact | Value | How |
|---|---|---|
| `ZPROSPECT` rows | 866 | store clone |
| Rows with no presenter | 454, across **427 distinct group names** | store clone |
| Rows flagged `presenterWasTheRoom` | 337 | store clone |
| Rows carrying a real presenter | 412, across **254 distinct** names | store clone |
| `ZWEBSITEURL` non-empty | **0 of 866** | store clone |
| Pitches ever sent (`ZSENTAT` not null) | **6** | store clone |
| Future-dated rows | **638** under `ZPERFORMANCEDATE >= date('now')` (629 under `>`) | store clone |
| Future + `status='new'` | **588** under `>=` (587 under `>`) | store clone |
| `ZPERFORMANCEDATE` column type | **TEXT, `'YYYY-MM-DD'`**, not a Core Data timestamp | store clone |
| Presenter-less rows with `status='new'` | 283, collapsing to **278 distinct (group, venue) pairs** | store clone |
| Total text of those 278 pairs | **12,155 characters**; mean group name 26.4 chars, max 142 | store clone |
| Green Room 42 share of presenter-less **rows** | 164 of 454 (**36.1%**) | store clone |
| Green Room 42 share of the 278 **pairs** | **123 of 278 (44%)** | store clone |
| SoHo Playhouse / The Players Theatre presenter-less rows | **35 / 27** | store clone |
| `ZWATCHEDSOURCE` rows / active | 73 / 72 | store clone |
| `ZWATCHEDSOURCE.ZVENUENAME` non-null | **0 of 73** (field exists, `WatchedSource.swift:214`, never filled) | store clone |
| Sources with `inactiveReason` | exactly one: `"New York Neo-Futurists"`, **`removedByDan`** | store clone |
| Sources with `inactiveReason = orgRefusal` | **ZERO** | store clone |
| Prospects with `ZORGDONOTCONTACT = 1` | **ZERO** | store clone |
| That org's spelling in `ZPROSPECT.ZPRESENTER` | **"The New York Neo-Futurists"** (12 rows) | store clone |
| Source kinds | 68 html, 2 ovation_tix_feed, 1 venue_tix_feed, 1 opera_america_feed, **1 algolia (that one is Carnegie Hall)**. Zero ticket_tailor. | store clone |
| Live row counts on every key-bearing table this milestone touches | `ZREFUSEDCONTACTADDRESS` **3**, `ZORGREACHABILITYANSWER` **2**, `ZVENUEPLACEANSWER` **3**, `ZPROMOTEDPRODUCER` **0**, `ZDEMOTEDHOUSE` **0** | store clone |
| `overture-shoot-history.json` | 322 shoots, **175 raw venue spellings** | file |
| Those 175 spellings through **the shipped `VenuePlaces.canonicalKey`** | **133 distinct keys; 35 at floor 2; 15 at floor 3** | shipped code |
| Of the 133: keys with prospect rows / additionally matching a watched-source name | **16 / 4** → **113 unseeded** | shipped code |
| **Unseeded keys at floor 2 / floor 3** | **24 / 7** | shipped code |
| Carnegie Hall's folded key | **122 of 322 shoots (38% of Dan's whole history)**, already a watched source | shipped code |
| `ProducerShapedName.from` over the 427 presenter-less group names | **3 hits** | shipped code |
| Presenters not confidently matching any watched source, via **`GroupNameMatch.isConfident`** | **225 of 254** | shipped code |
| Of those 225, dropped by **shipped `ProducerGate.isVenueBrand`** against the store's 120 venue keys | **4** → **221 remain** | shipped code |
| Of those 221, organisations with at least one row located outside the NYC area | **13** (plus 11 whose every row has a blank location) | store clone |
| `ScoutReadBudget.askAbove` | 20 (`ScoutReadBudget.swift:25`) | source |

Six of these decide the architecture, and five overturn what an earlier draft assumed.

**There is no live refusal to calibrate against, and the machinery already exists.** Zero `orgRefusal` sources, zero `orgDoNotContact` prospects. The one inactive source is `removedByDan`, and `WatchedSource.swift:628` states in its own words that this is **"a permanently dead source Dan chose to stop watching. Not a refusal."** `WatchedSourceProposal.swift:64-70` deliberately allows re-proposing such a source, and `WatchlistEditing.swift:117` agrees. Meanwhile a real org-refusal ledger is already shipped: `mac/Overture/Domain/OrgDoNotContact.swift` + `LocalHistory`'s `"dnc"` record (`LocalHistory.swift:26-27`) + `GroupNameMatch.isConfident` + `WatchedSource.inactiveReason == .orgRefusal`. Its header says: *"Deliberately NOT a new org entity... A parallel mechanism would have been a second thing to get wrong."* Phase 2 extends that, and every proposal filter reads all three homes.

**Carnegie does not split four ways. It already folds to one key.** `VenuePlaces.swift:196-200` maps `weill recital hall`, `zankel hall`, `stern auditorium / perelman stage`, `resnick education wing` to the parent `Carnegie Hall`; `key()` (`:152-156`) drops the leading article; `sourceCleaned` (`:104-122`, doc comment from `:96`) strips wrapping quotes and newline addresses; `candidates()` (`:131-142`) splits on `" at "`. Run over the 175 spellings that folds sixteen spellings into ONE key at **122 shoots**. Only `stern auditorium` (7), `carnegie` (1) and `carnegie hall stage door` (1) sit outside it. The earlier draft's headline fold-repair work item was already done.

**#311 is roughly twice the size the earlier drafts thought, and that is the single most consequential correction here.** The unseeded pool is **24 keys at floor 2 and 7 at floor 3**, not 9 and 3. Subtracting the declared junk at floor 2 (`stage` 5, `google meet` 3, `337 e 6th st #4` 2, `398 broome street` 2, `75 river terrace` 2, `brasserie 8 1 / 2 and rosie o'grady` 2, `holy apostles soup kitchen 296 9th ave on` 2) and the three P0.2 fold fixes absorb (`stern auditorium` 7 into Carnegie, `merkin concert hall 129 w. 67th street` 2 into Merkin, `david geffin hall` 2 into `david geffen hall`) leaves **roughly 14 real unseeded rooms at floor 2**. The illustrative head of the unseeded floor-2 list, measured: **`park central hotel` 9, `lincoln center` 7, `stern auditorium` 7, `stage` 5, `gramercy theatre` 4, then `google meet` and `milbank chapel` at 3.** (`field` is a SINGLE shoot and is not at floor 2 at all.)

**The store-only channel is still an order of magnitude larger, so it still ships first, but the argument is now stated on the corrected numbers.** Through the named fold `GroupNameMatch.isConfident`, **225 of 254** presenters match no watched source; `ProducerGate.isVenueBrand` drops 4 of those, leaving **221**. Against #311's ~14. Phase 4 first; #311 second (see escalatedDecisions, because a 14-seed channel has a genuinely competitive free version).

**The identity trap is real, but it is a FOLD disagreement, not a refusal failure.** `ProducerGate.key` strips a leading `"the "` (`ProducerGate.swift:36`), `VenuePlaces.key` strips it (`:154`), and **`OrgKey.of` does not** (verified: no `hasPrefix("the ")` anywhere in `OrgKey.swift`). The store holds the same organisation as `"The New York Neo-Futurists"` (12 prospect rows) and `"New York Neo-Futurists"` (the single inactive `WatchedSource`). That belongs in `OrgIdentityAgreementTests`, which today asserts bracket agreement and says nothing about a leading article. It is **not** evidence that a refusal ledger matches across spellings, because neither row is a refusal.

**`ProducerShapedName` is nearly silent on this store, and it mangles the one real organisation it finds.** Compiled and run over all 427 distinct presenter-less group names, it returns **3** hits: `In Pleasant Company`, `On Stage Collective`, and `Orchestra of St. Luke's`, which it returns as **`"Orchestra of St. Luke"`**, because `withoutPossessive` (`ProducerShapedName.swift:59-66`) strips a trailing `'s` from an ensemble whose actual name ends in one. Correct for its current job (peeling a possessive off a marketing supertitle before a show title); wrong for any job that stores the result as an organisation's name. `The Ukulele Kids Club` and `Indianapolis Children's Choir` both return **nil** under the shipped rule. Any figure above 3 was computed with a second, broader rule, which is exactly the drift P1.1 exists to forbid.

---

## Milestone and issue conventions

**Milestone: `Prospector for new organisations and venues`** (names the feature, no punctuation, six words).

**Milestone description states, in Dan's own frame:** venues are not neglected. **Phase 7 (booked venues, #311) IS the venue channel**, and #9's venue half is satisfied by it plus the seed layer P8.3 plugs into.

Every issue carries that milestone, a `priority-p*` I chose (stated per issue, since I found these rather than Dan reporting them), and at least one category label: `discovery`, `enhancement`, `tech-debt`, `data-integrity`, `cost`, `security`, `accessibility`.

Phase gating is real: **no issue in a later phase may be started before its predecessor's guard has been seen to fail and then pass** (L1).

**Ship order:** Phase 0 → 1 → 2 → 3 → **4 (store-only channel, the first shipping channel)** → 5 (metric) → 6 (harness) → 7 (#311) → 8 (open web) → 9 (Instagram).

---

## Phase 0: Free measurement, before anything is spent

Nothing ships to Dan. This phase exists because rival plans disagreed about the size of the #311 seed list by 3x, and because a plan that sizes a channel on a wrong floor picks the wrong first channel.

**Cost: zero runs, zero AI, zero fetches.** One local test invocation, seconds. There is no paid version.

### P0.1: Measure the seed table and the candidate pool through `LiveStoreClone`, not a parallel tool. `priority-p1`, `discovery`, `data-integrity`.

An earlier draft proposed a bespoke one-shot tool with its own hand-written refusal to open the Release store. **That duplicates a shipped mechanism, which is the exact defect this plan cites `OrgDoNotContact` against.** `mac/OvertureTests/LiveStoreClone.swift` is "the ONE way a test may read Dan's real store": it takes a WAL-consistent SQLite ONLINE BACKUP (answering the torn-copy objection in its own words) and "refuses outright if the clone it is about to hand over is the live path" (answering the L2 objection). **17 `*LiveStoreTests.swift` suites use it, across 27 files.** So:

- **(a) The measurement is a live-store suite using `LiveStoreClone`**, following `OneVenueIdentityLiveStoreTests`'s convention exactly: *"Each expectation below is the invariant, not the count that happened to be true on the day."* It asserts INVARIANTS, never the day's census, every raw shoot spelling folds to a non-empty key; a wrapping-quote spelling and its bare form fold together; a newline-address spelling and its bare form fold together; every declared junk shape is in the declared set; no unseeded key is also a prospect key. A count-pinning assertion is forbidden here (L63: a pinned count stays green while the thing it stands for doubles, which is precisely how the 9/3 figure survived).
- **(b) The same suite emits the census as diagnostic output**, and that output is pasted into the issue body tagged with the shipped convention (`scripts/check-live-store-claims.sh`): `// LIVE-STORE-CLAIM verified=2026-08-10 measure="the 175 raw shoot venue spellings folded through the shipped VenuePlaces.canonicalKey, and how many fold to a key with no prospect row and no watched-source name match"`. It must print, at minimum:
  - the distinct key count and the seed count at floors 1, 2 and 3;
  - for each key, the raw spellings that folded into it, so a fold failure is visible rather than inferred;
  - **the subtracted list**: keys with no prospect rows AND no watched-source name match, and how many clear each floor;
  - the junk list;
  - the presenter fill rate and the `websiteURL` fill rate.
- **(c) The FIXTURE half stays in the standing suite.** `fixtures/shoot-history/v1.json` holds **6 measured shape rows**, so it cannot reproduce the census; it carries the fold assertions above, each **seen red first** by reverting one line of `sourceCleaned`. Per that fixture's README, any new row is a shape **measured** in the real export, never invented (L48).
- **(d) P0.1 also measures P4.2's two judgment filters, before either is built (L93).** Both drop candidates before Dan can ever see them, which makes their mistakes structurally invisible to the only person who could correct them. Already measured here and to be re-measured in the issue: **`ProducerGate.isVenueBrand` drops 4 of the 225** (`52nd Street Project`, `LOL! The Players Theatre Short Play Festival 2026`, `Museum of Chinese in America and Chinese Theatre Works`, `The Royal Concertgebouw`). The **bare-personal-name** filter has NOT been measured and must be, with its full drop list in the issue, because constraint 9 records that Dan chose breadth having been shown the cost, and a great many performing groups carry a founder's or conductor's name. **The issue names what that fallback gets wrong (a group named for its founder) and, if the drop rate is material, the filter does not discard silently: dropped items go to a visible "probably not a group" list Dan can overrule.**

**Corrected numbers to put in the issue body up front**, measured through shipped code: **133 keys / 35 at floor 2 / 15 at floor 3; 16 prospect-matched and 4 more source-name-matched, leaving 113 unseeded; 24 unseeded at floor 2 and 7 at floor 3.** Earlier figures of 150/37/14, 151/33 and "9 / 3 unseeded" are all superseded and named as superseded (L61). If P0.1's own run disagrees, that is the finding, and nothing downstream may be sized until it is understood.

**What P0.1's own run found (2026-08-10, `SeedTableCensusLiveStoreTests`, #2450).** Every seed-table number above reproduced exactly, through the shipped fold and the shared `LiveStoreClone`. Three things did not, and each is a correction to this document rather than to the run:

1. **The junk list is wrong in one entry and short by 27 at floor 1.** `brasserie 8 1 / 2 and rosie o'grady` is not a key at all: the calendar spells that name with a curly apostrophe, and the phrase actually splits four ways (`brasserie 8 1 / 2 and rosie o'grady` 2, plus three singletons spelling it differently). Beyond the declared seven, floor 1 also holds **six Zoom links, one Google Meet, twenty-five keys that are nothing but a street address, `Phone Call` and a one-character `T`**, none of which the hand-written list names. At FLOOR 2 the declared set is otherwise right, which is exactly why the registry read as complete. So the exclusion is now DERIVED by shape (a link, a leading all-digit token followed by a street word, a key too short to name anything) and declared by hand only for the residue it cannot see, per L96.
2. **The candidate-pool figures have drifted with the store, while the FOLD numbers have not.** 874 prospects (was 866), 275 distinct presenters (was 254), and the `GroupNameMatch.isConfident` pool is **246, not 225**. `ProducerGate.isVenueBrand` still drops exactly the four named in (d), which is now **4 of 246**.
3. **The bare-personal-name filter's drop rate is material and it is wrong on real organisations.** A candidate rule (2 or 3 capitalised words, no digits, no organisation vocabulary, no connector, no leading article) drops **75 of 242**, roughly 31 percent, and its drops include `Live Nation`, `Selected Shorts`, `Young Euro Classic`, `Fundacion Sinfonia`, `Harmony Sweepstakes`, `Monday Night Magic`, `Classical Nomads` and `Treble Harmony Brigade`. The condition P4.2 attached to this ("if the drop rate is material, the drops go to a visible list Dan can overrule") is therefore MET, not hypothetical, and P4.2 may not ship this filter as a silent discard. Two arms were added after seeing the first measurement, and both were measured rather than guessed: without a leading-article arm it also dropped five bands out of five (`The Klezmatics` and four more), and without `university` and `college` in the vocabulary it dropped `Concordia University Irvine`.

### P0.2: Fix the fold failures that are real, and ship a realignment pass with them. `priority-p1`, `data-integrity`.

The Carnegie four-way claim is **withdrawn**. The genuine failures, all measured:

1. **Merkin splits three ways plus a fourth neighbour.** `merkin hall` (3), `merkin concert hall 129 w. 67th street` (2), `merkin hall @ kaufman music center` (1). Cause: `candidates()` splits on `" at "` and knows nothing about `@`; `"Merkin Concert Hall"` is not a table key. Separately **`kaufman music center` (3) is its own key** sitting beside them while a watched source is literally named `"Kaufman Music Center (Merkin Hall)"`.
2. **`stern auditorium` at 7 shoots** misses its Carnegie parent, because the table key is `"stern auditorium / perelman stage"` and the bare clause never matches it.
3. **`milbank chapel` (3) and `milbank chapel at teachers college` (1) are two keys, both unseeded.** Instructive: `candidates()` DOES split on `" at "`, yet neither half is a curated table key, so the whole string falls to the `normalizeForKey` fallback. A split that works and still fails.
4. **`david geffin hall` (2) is a typo variant of `david geffen hall` (6).**

Fix all four in `VenuePlaces`' curated table and its candidate logic, the file that already owns venue identity, **never in a private fold beside it**.

**L15, a stored-fold change ships its realignment pass in the same change.** `VenuePlaces.canonicalKey`, `OrgKey.of` and `ProducerGate.key` are stored keys on live rows. **But the shipped `OrgKeyRealignmentMigration` may NOT be copied line for line onto every table** (L5). Its own header states its blast radius: *"It rewrites `orgKey`, a UNIQUE column, and it can delete a row"*, and its `Summary` carries `duplicatesDeleted` (`:33`, deleting at `:71-72`). Those semantics were chosen for reachability ANSWERS, where a redundant duplicate is genuinely disposable. On a protective table they mean **a fold change can delete a refusal**, silently, reported as a merge both sides agreed on. That is the one loss this milestone exists to prevent, it is the shape of #2392 → #2421, and a refusal ledger one row shorter is indistinguishable from no refusal at all (L42). So the pass has **two behaviours by table class**:

- **Protective tables, `RefusedContactAddress` (3 live rows), the new `RefusedOrgClaim`, any DNC record, get a RE-KEY-ONLY pass that NEVER deletes.** On a key collision it keeps both rows under both keys and counts it, because two refusals can only ever mean refuse. A `duplicatesDeleted` counter must not exist on this path.
- **Answer-shaped tables keep the existing merge-on-agreement semantics**: `OrgReachabilityAnswer.orgKey` (`OrgReachabilityAnswer.swift:21`, `@Attribute(.unique)`, 2 live rows), `PromotedProducer.orgKey` and `DemotedHouse.orgKey` (`ProducerOverride.swift:23` and `:38`, both unique, 0 live rows each), `VenuePlaceAnswer` (3 live rows).
- **Every affected table's live row count goes in the issue, live-store-claim tagged, before the pass is written** (the numbers above), and **the pass is rehearsed against a WAL-consistent copy of the Release store with a before and after row count per table** before it ever runs at launch on Dan's machine (L7; the shipped migration's own header did this and the earlier draft dropped it).

**L96, the consumer list is DERIVED, not hand-written.** An earlier draft enumerated the key-bearing fields by hand. That is a registry standing in for the set of stored fold keys, and a guard built on it checks only what the list remembers, while this milestone is actively minting new key-bearing models (`RefusedOrgClaim`, `OrgClaim`, P7.2's seed stamp). The entries that go missing are exactly the ones the realignment was written to protect (L41). So: **a guard in `OvertureTests` using `mac/TestSupport/SourceGuardHelper.swift` and `SwiftSource.swift` finds every `@Model` stored property assigned from `OrgKey.of`, `ProducerGate.key` or `VenuePlaces.canonicalKey`, and fails when one is not covered by a realignment pass.** A new key-bearing field then fails the suite the day it is added rather than being exempted by omission. Seen red first by adding a stored key field with no coverage.

#1784 is the record of what happens without any of this: rows filed under a spelling nothing computes any more, invisible, and paid for again.

**Never seed from raw venue strings**, from `downbeat-export.json` (0 bookings, 4 venues) or `overture-history.json` (46 entries, no venue field): #311's literal text points at both and both are empty for this purpose.

**Gate:** Dan sees P0.1's output, including the subtracted list at its corrected size, and **sets the shoot floor** before Phase 7 is scoped. Escalated, not locked.

---

## Phase 1: One producer-shaped name rule, everywhere (prerequisite, ships first)

A proposal surface fed by a store where 52% of rows name a room instead of an organisation inherits the defect (L30). This is constraint 2.

**Cost: P1.1, P1.2, P1.3 are FREE** (source changes, a store sweep, re-reads of pages the scout already fetches). **P1.4 is one AI run, once.** The free version of P1.4 is "ship P1.1 to P1.3 and accept that the 278 pairs stay unnamed until a page is re-read"; that is a real option and the issue says so.

### P1.1: Route all four call sites through `ProducerShapedName`. `priority-p1`, `tech-debt`, `data-integrity`. **Free: zero runs.**

Measured in this checkout:
- `mac/Overture/Integration/VenueTixCalendar.swift:217/231`, already routes through it. Correct.
- `mac/Overture/Domain/ListingOrganiser.swift:62`, already routes through it. Correct.
- `mac/Overture/Integration/OvationTixCalendar.swift`, lifts `production.supertitle` into `OTEvent.superTitle` at line 120, joins it into a description at 196, then `extractedEvents` at 297 writes `presenter: presenter` **unconditionally**. The producing company is decoded, held in memory and discarded on the same pass.
- `mac/Overture/Integration/TicketTailorCalendar.swift:121`, writes `presenter: venueName` unconditionally. Every row from that adapter is born naming a room.

Fix both by asking the same shared rule. **Guard:** a source-text check in `OvertureTests` using `mac/TestSupport/SourceGuardHelper.swift` + `SwiftSource.swift` (the convention `TicketTailorTests` and `DeadEndContactTests` already use) asserting no adapter's `extractedEvents` assigns a presenter without folding through `ProducerShapedName`, **plus a private-copy check** that no file outside `ProducerShapedName.swift` re-declares the connector list or the length caps. Seen red first by reverting one call site (L1).

### P1.2: The honest store sweep: it is worth THREE rows, and it must not mangle the one real name. `priority-p2`, `data-integrity`. **Free: zero runs, one launch-time pass.**

A sweep over the 454 presenter-less rows can only read fields the store holds, and the producing supertitle **is not stored on `Prospect` at all**. Running the shipped `ProducerShapedName.from` over all **427** distinct group names on those rows returns **3 hits**: `In Pleasant Company`, `On Stage Collective`, `Orchestra of St. Luke's`. **The issue says 3.** Any larger figure was computed with a second, broader rule, which P1.1 exists to forbid; and an optimistic number here is worse than none, because it is exactly what someone checks a suspicious later run against (L32). **The direct consequence is that P1.2 barely justifies itself alone and its real value is the provenance guard below, which P1.4 cannot ship without.**

**The mangling, and the design change it forces.** `ProducerShapedName.from("Orchestra of St. Luke's")` returns **`"Orchestra of St. Luke"`**, `withoutPossessive` (`ProducerShapedName.swift:59-66`) strips the trailing `'s`. Correct for its current job, wrong for writing `Prospect.presenter`. So **P1.2 uses `ProducerShapedName` as a PREDICATE and stores the ORIGINAL string unchanged**; no store write is routed through `withoutPossessive`. A test asserts the swept row reads `Orchestra of St. Luke's`, seen red first against the naive implementation. (If a later issue wants the stripped form anywhere, it needs its own reason; that is not this one.)

**L5, the defect that would have shipped, in BOTH directions.**

*Forward:* `ScoutService.swift:1420` reads `existing.presenter = p.presenter` **unconditionally**, three lines below `if !existing.groupNameOverriddenByDan` at `:1417`, a guard that exists precisely because the scout used to clobber the field beside it. After P1.1 the OvationTix and TicketTailor adapters emit **nil** for exactly the room-named rows P1.2 and P1.4 have just filled. Every ordinary re-read would then erase the swept answer and the paid answer alike, leave no trace the pair was ever answered, and the next P1.4 batch would select and pay for it again (L47 on top of L5).

*Backward, and this is the writer the earlier draft missed entirely:* **`RoomPresenterSweep` is not a pattern, it is a shipped launch-time writer going the OTHER way.** `mac/Overture/Domain/RoomPresenterSweep.swift` is wired into `LaunchMigrations.swift:127` and runs **every launch**, and it **CLEARS** a presenter that names the room (`p.presenter = nil; p.presenterWasTheRoom = true`, `:47-48`). It is what produced the 337 `presenterWasTheRoom` rows. So a swept or AI-filled presenter that happens to reduce to its venue under `ProducerGate.key` is erased at the next launch **with no trace**, which is the exact L47 shape P1.4 pays to avoid.

So **P1.2 ships the provenance guard in the same change that adds the second writer**, on the shipped `groupNameOverriddenByDan` precedent, and it covers BOTH writers:

- `Prospect` gains a stored `presenterSource` (`scout` / `sweep` / `aiBatch` / `dan`). Confirmed additive: nothing by that name exists in `mac/Overture` today.
- **`ScoutService.apply` refuses to replace a non-`scout` presenter with nil.**
- **`RoomPresenterSweep.run` keeps clearing a room-named presenter (that data really is wrong) but may no longer do it silently:** when the presenter it clears is not `scout`-sourced, it records an explicit *cleared-because-it-named-the-room* fact against that (group, venue) pair. That record is L46-named in this same issue: **its readers are P1.4's batch selector (which must not re-pay for a pair already answered and then cleared) and the failed-attempt list on the proposal surface (P8/L46 below).** A test asserts a sweep-cleared pair is excluded from a second P1.4 batch, seen red first.
- Both guards get their own test, each seen red by reverting it.

### P1.3: Two separate one-shot forced re-reads, each with its own justification. `priority-p2`, `data-integrity`. **Free: zero AI runs; re-fetches pages the scout already fetches, one scout press each, minutes.**

- **(a) `ovation_tix_feed`-scoped re-read.** Selectable by `kind`. Reaches SoHo Playhouse (**35** presenter-less rows) and The Players Theatre (**27**). Justification: the adapter changed in P1.1 and a rule only reaches rows written after it (L55).
- **(b) `venue_tix_feed`-scoped re-read for Green Room 42's 164 rows.** Justification is **not** "the adapter changed", that adapter was already correct. It is **"#2259's boundary rule shipped after these rows were written"**, the same lesson from the other direction.
- **TicketTailor is dropped from the re-read entirely.** There are **zero `ticket_tailor` sources**; `TicketTailorCalendar` is reached opportunistically when an html page carries a Ticket Tailor widget (`ScoutService.swift:483`, inside `inlineNativeExtractor` at `:481-490`, via `SourceFetcher.swift:102` `ticketTailorWidgetHTML`), and nothing stores which sources have ever produced ticket-tailor rows. There is no selector for that adapter. Its P1.1 fix is **boundary-only and reaches future rows**, and the issue says so rather than implying a backfill exists.

Shared requirements: one-shot, not a mode; clears `lastContentHash` for exactly the selected `WatchedSource` rows, records that it did, idempotent by a stored marker; must **not** clear `hasUnreadChanges` or `lastManualReadAt` (`WatchedSource.swift:51`, `:68`), which is #1189's fairness clock; must **not** fire automatically on launch; failure is loud (a re-read leaving any targeted source unread names those sources).

### P1.4: One batched AI pass over the 278 distinct (group, venue) pairs. `priority-p2`, `discovery`, `cost`.

**Cost: exactly ONE run, once. Expected wall clock a few minutes.** Not repeatable per scout and must not become so. **Free version:** skip it; the 278 pairs stay unnamed until a page re-read happens to fill them, and Phase 4 ships on the 412 rows that already carry a presenter. With P1.2 now worth only 3 rows, this is the pass that actually names organisations, and the issue must say that plainly rather than leaning on a deterministic sweep that does almost nothing.

- Batch on the **distinct (group name, venue) pair (278)**, not the 283 rows and never the 454.
- **Sized in characters, from the real payload** (L81, L87): the 278 pairs total **12,155 characters** (mean group name 26.4, max 142). That fits comfortably in one call, and the number goes in the issue.
- **Green Room 42 is 123 of the 278 pairs (44%)**, not 36.1% (which is its share of presenter-less rows). Calibrate the prompt per source or the batch shape is tuned to one room.
- **Ordering is stated and enforced: P1.3's forced re-reads run BEFORE this pass, never after** (L5).
- **L25 / L28, the model is pinned.** A new `OVERTURE_MODEL_PRESENTER_BATCH` in `mac/scripts/lib/models.sh`, following `OVERTURE_MODEL_EXTRACTION` / `OVERTURE_MODEL_REPLY_CLASSIFY` / `OVERTURE_MODEL_REACHABILITY`, recording its model id into the results file via the shipped `record_model` helper (`models.sh:73`). The run may not ask questions, and leaves an honest failure record when it dies rather than an absent file.
- **L27, a deterministic boundary check on every returned name.** Every returned name routes through `ProducerShapedName` (as a predicate, storing the original string) **and** `ExtractedEventGuard.presenterThatIsNotTheRoom` (`ExtractedEventGuard.swift:116`) before storage. **Any key not present in the batch that was sent is discarded and counted, never written.**
- **This run is the proving ground for the truncation reporting Phase 6 depends on.** It is small, bounded and app-authored, so `HandoffShortfall.missingKeys` applies to it directly. Prove the reporting here before an open-ended channel relies on it.
- **L47/L46:** a batch that partly fails records the attempt on the pairs it failed, and **a pair the model could not answer is stored as an explicit answered-unknown whose READER is named in this same issue: P1.4's own batch selector, which must exclude already-attempted pairs.** Asserted by a test that runs the selection twice and gets an empty second batch. If it has no reader, the field is not added.

---

## Phase 2: Identity and refusal, as a claim set that EXTENDS the shipped ledger

Built before any surface, because a refusal ledger retrofitted onto live proposals is a store migration, and L92 already cost this repo #2392 → #2421 for exactly this shape.

**Cost: zero runs, zero AI, zero fetches. Entirely free.**

### P2.1: `OrgClaim`: a proposal's identity is a set, and it must reuse an existing fold. `priority-p1`, `data-integrity`.

A proposal carries any of: a **name** claim, a **site host** claim, a **listings URL** claim (folded through the existing `CalendarIdentity`, never a new host comparison, #2377 already merged two spellings of that), and later an **Instagram handle** claim. Each claim is `(kind, value)` with one declared fold per kind, and every fold is a named existing function.

`OrgIdentityAgreementTests.swift:3-11` names **three** existing org folds, `VenueNormalization.normalizeForKey`, `ProducerGate.key`, `OrgKey.of`, and `VenuePlaces.key` is a fourth, for venues. Anything this milestone adds would be a **fourth org fold**. So:

- name → the claim **reuses `OrgKey.of`**, stated explicitly, or states which of the three it uses and why. No new normalizer.
- listings URL → `CalendarIdentity.same`.
- host → the same strip `WatchedSourceProposal` uses.
- Any change to any of these ships **P0.2's realignment pass**, under P0.2's two-behaviour rule and covered by P0.2's derived guard.

**The fixture, corrected (L48/L58).** The store holds **zero `orgRefusal` rows**, so there is **no live calibration data for refusal matching at all**, and the issue says that in its first paragraph. What the Neo-Futurists rows demonstrate is a **fold disagreement**: `"The New York Neo-Futurists"` on 12 prospect rows against `"New York Neo-Futurists"` on the single `removedByDan` source, where `ProducerGate.key` strips the leading article (`:36`) and `OrgKey.of` does not. That is filed into `OrgIdentityAgreementTests` as a **leading-article agreement test**, seen red first, and labelled a name-fold fixture, never a refusal fixture.

**The refusal-matching fixture comes from records each side created independently (L58):** the first real refusal Dan makes on a live run, or a claim pair whose name came from `ZPRESENTER` and whose URL came from a `WatchedSource` neither minted from the other. Until one exists, the refusal-match test is explicitly **awaiting live calibration**, and per L65 **the issue that activates it is filed in the same change**.

### P2.2: `RefusedOrgClaim`: a deliberate second model, reconciled against `SourceInactiveReason`, reading the shipped ledger, failing closed. `priority-p1`, `data-integrity`.

**(a) Why a second model is correct here, when `OrgDoNotContact`'s own header says it was wrong there.** A **discovery refusal** ("never propose this group to me again") is a different fact from `orgDoNotContact` ("they asked me to stop"). The first is Dan's taste and reversible; the second is theirs and is not. Collapsing them would either make a taste decision permanent or make an unrecoverable one reversible. `OrgDoNotContact` refused a parallel mechanism for the *same* fact; this is a different fact, and the issue argues it explicitly rather than asserting it.

**(b) The KIND of no is carried on the claim, derived from the shipped vocabulary (L89).** `WatchedSource.swift:625-629` declares exactly two ways an organisation comes off Overture: `orgRefusal` ("they asked Dan to stop. The one mistake that cannot be taken back") and `removedByDan` ("Not a refusal."). `RefusedOrgClaim` carries a kind derived from `SourceInactiveReason` where a source exists, plus its own `passedOnByDan` case for a discovery-only refusal. A guard fails if a case is added to `SourceInactiveReason` or to the claim kind without the other.

**The two actions must be structurally unlike each other (L9, L89).** Removing the undo from `orgRefusal` without putting anything in its place is worse than the ordinary case: the safe action and the unrecoverable one would sit one pixel apart in one menu, writing one stored vocabulary, and only one of them reversible. So:

- **"Pass on this group"** stays a one-click default, with its undo on the refused list (P2.3).
- **"They asked me to stop"** requires an **explicit confirmation naming in words what it makes permanent** (never proposed, never scouted, no way back) before the claim is written. That copy goes through `docs/copy-inventory.md` and the cold read.
- **A test asserts no code path can write an `orgRefusal`-kind claim without the confirmed flag**, seen red first.
- An `orgRefusal` claim is permanent and **structurally absent from the "Propose again" surface**.

**(c) The proposal filter reads BOTH homes plus the source flag, before anything reaches a card.** Nothing is proposed while any of these says no: a `RefusedOrgClaim` matching on any claim; `Prospect.orgDoNotContact` on a confident `GroupNameMatch` (the bar `OrgDoNotContact.sameOrg` itself uses); a `LocalHistory` `"dnc"` record (`LocalHistory.swift:26-27`); a `WatchedSource` with `inactiveReason == .orgRefusal`.

**(d) The read FAILS CLOSED (L42).** If `RefusedOrgClaim`, the dnc history, or `AlreadyKnownOrg`'s inputs cannot be loaded, **the run proposes NOTHING and says why**, naming the read that failed. Failure-path tests: make the fetch throw and assert zero proposals plus a named error; assert the same for a load returning an empty set because the store is unreadable. Both seen red first.

**Shape and mechanics:**
- **Never `RefusedContactAddress`.** `mac/Overture/UI/QueueView.swift:46` holds `@Query private var refusedAddresses: [RefusedContactAddress]` (read at `:189` and `:249`), so every refusal click would invalidate that query and rebuild the whole queue. That is the #2417 shape, and Dan already named the lag (L91).
- Follows `PromotedProducer`/`DemotedHouse` in `ProducerOverride.swift`: SwiftData-only, no relationship to `Prospect`, `@Attribute(.unique)` on the stored claim so two refusals racing cannot leave two rows that disagree.
- **A blocking match on ANY claim.** A group first seen on a venue listing has a name and no URL; the same group seen later has a URL and a different spelling. One key cannot cover both.
- **L92, as a build rule:** every item the run can propose must carry at least one claim, or it is **refused rather than proposed**. An item with no claim is not a weak proposal, it is an unrecordable refusal.
- **L75:** when identity resolution fails, refuse the action. Never fall back to a nearby candidate.

### P2.3: Refuse and "Propose again" ship in the same change. `priority-p1`, `discovery`. **Free.**

Striking a card removes the only handle Dan has to reverse it (L97, paid for in #2392/#2408). The refusal list is a visible surface with the way back attached to each row, reachable without Dan having to remember the name he struck. Same PR, not a follow-up. `orgRefusal`-kind claims never appear on it (P2.2b).

---

## Phase 3: The proposal surface (a holding pen, never the watchlist)

**Cost: zero runs, zero AI. Free.**

### P3.1: `DiscoveredOrgProposal` @Model and the proposal list, with its evidence stamped at write time. `priority-p1`, `discovery`, `accessibility`.

- A discovered candidate lands **here**, never on the watchlist and never in the queue (constraint 6).
- Each card shows: the claims, the seed it came from, the evidence (which page, which listing, how many shows), and the reason it was proposed. **Evidence on this card is a VALIDATED field, not a display field, see P8's L28 rule, which is what makes the words on it true.**
- **L37 / L91, the evidence and the reason are STAMPED at write time and the card renders stored values only.** A proposal sits in a holding pen until Dan reviews it, which may be weeks later. Derived live, "three upcoming shows" renders as zero once those dates pass, and the reason Dan is being asked to approve it disappears from the card. Phase 4's channel is the worst case, because its evidence is *entirely* derived. Stamping also means the list costs nothing to draw, which matters because #2417 already made Dan wait on a whole-corpus derivation in a card list.
- **L67:** any placeholder standing in for a missing required value (no readable name, no reachable page, unconfirmed evidence) **blocks** Accept; it does not merely label it.
- **L49:** Accept and Refuse look like controls at rest, not on hover. **L76:** the list shows at rest that content continues past the edge (`CappedScrollView` / `ScrollOverflow` exist for this). **L69:** the card is read on both light and dark backgrounds. **L20:** labels on icon-only controls, real buttons, AA contrast, focus management, as part of building the control.
- **#843 / L21 cold read:** `docs/copy-inventory.md` and `docs/copy-surfaces.md` diffs read cold, in the order a person meets the lines on screen, **in every branch**: empty list, one card, many cards, all-refused, and the branch carrying the explaining sentence *not taken* (#1547 is exactly that defect).

### P3.2: The accept path, its promotion, its cost disclosure, and its UNDO, all in one change. `priority-p1`, `discovery`.

Arithmetic, not taste: **235 of 254 presenters play exactly one venue**, and `ProducerGate.qualifies` requires `distinctVenueCount >= 2` (`ProducerGate.swift:76`). Without writing a `PromotedProducer` (keyed on `ProducerGate.key`) when Dan accepts an organisation, nearly every accepted org fails the venue-count arm forever. `ZPROMOTEDPRODUCER` holds **0 rows**, so this path has never been exercised live: L46 applies and the issue names the reader of the row it writes.

**L64, what Dan approves must be what ships, including what the app composes onto it.** What he reviews is a group and a link; what actually ships on his approval is a calendar fetched on every scout from then on, plus a store-wide change to how `ProducerGate` answers for that organisation. Both are invisible at the moment of approval. So **the accept confirmation names both consequences in his terms**: *this adds a calendar the scout reads every run (you now watch N)*, and *this tells Overture to treat this group as a producer wherever its shows appear*. **N is the live watched count, shown inside the sentence**, so P3.3's cost is visible at the moment it is incurred rather than only in an issue body. Both sentences go through `docs/copy-inventory.md` and the cold read.

**L91 / L30, sweep the class, do not fix one model.** P2.2 diagnosed the whole-corpus invalidation for `RefusedContactAddress` and then left the MORE expensive action unexamined. A `WatchedSource` insert is observed by live `@Query` surfaces, and a `PromotedProducer` insert changes `ProducerGate`'s answer for every one of that org's shows: a whole-corpus derivation on the main thread. That is #2417 exactly, the card takes a second or two to leave the screen, Dan presses Accept again, and the second press is a duplicate write into two unique-keyed tables. So the issue must:
- **enumerate every `@Query` and derivation a `WatchedSource` insert and a `PromotedProducer` insert invalidate**, the same way P2.2 did for `RefusedContactAddress`;
- **decouple the press from the recompute**: the card leaves the proposal list immediately, from stamped state, and the store recomputes after;
- **make the accept path idempotent at the STORE layer** so a second press cannot write twice;
- **test the press response against a store seeded at realistic size**, not a handful of rows.

**L9 / L38 / L97, Accept ships with an undo in the same change**, reachable from a **visible accepted list**, not from Dan remembering a name. The issue **enumerates every derived resource the undo must reverse**: the `WatchedSource`, the `PromotedProducer`, the proposal's state, and any seed stamp. A test asserts none is left behind (the N-minus-1 shape L38 names).

### P3.3: Watchlist growth and the `ScoutReadBudget.askAbove` consequence. `priority-p1`, `cost`. **Filed before the first accept path ships.**

**This is the feature's genuine recurring cost, and it is not AI.** Every accepted org becomes a `WatchedSource` fetched forever. 73 today; `askAbove` is 20 (`ScoutReadBudget.swift:25`). Accepting twenty organisations makes the "N calendars have new listings to read" prompt fire on nearly every scout Dan presses, and each press costs him time. The issue carries the decision for Dan (escalatedDecisions) and must not resolve it unilaterally. **Free version: none; this cost is inherent to accepting, which is why the decision is Dan's, and why P3.2 puts the count in front of him at the press.**

---

## Phase 4: Channel A: organisations already inside Overture (#9's free half): THE FIRST SHIPPING CHANNEL

Promoted ahead of #311 because the corrected numbers still demand it: this channel's pool is **221 organisations** after both shipped filters, while #311's unseeded pool is **roughly 14 rooms** at floor 2 after junk and fold fixes.

**Cost: ZERO runs, ZERO fetches, ZERO AI.** A query over rows Dan already owns, drawn from stamped values. There is no paid version and no separate free version to name, because it is already the free one. That is the strongest thing this plan can say about a discovery channel.

### P4.1: `AlreadyKnownOrg`, reading every home, adding no new fold. `priority-p2`, `discovery`.

The predicate unions: watched sources active and inactive; `RefusedOrgClaim` rows; **`Prospect.orgDoNotContact`**; **`LocalHistory`'s `"dnc"` records**; **`WatchedSource.inactiveReason == .orgRefusal`**; promoted and demoted overrides; presenters already in the store; past clients.

- It **must not become a fourth org fold** (P2.1). It reads P2.1's claim set and nothing else.
- **It fails closed** (P2.2d): if any input cannot be loaded, the channel proposes nothing and names the read that failed.

### P4.2: Propose the unwatched organisations Overture already holds, sized through a NAMED fold. `priority-p2`, `discovery`.

**The corrected pool, and which fold produced it.** A plain string comparison is not good enough and must not be the sizing method: raw case-sensitive gives **232**, case-insensitive with a leading article stripped gives **228**, and neither is the number to build on, because real near-misses survive both (`"Ballets with a Twist"` at 4 rows against the watched source `"Ballet With A Twist"`; `"Tenet Vocal Artists & Alkemie"` against `"TENET Vocal Artists"`). **The pool is sized through `GroupNameMatch.isConfident`, the shipped fold, and it is 225 of 254.** Measured: that fold DOES collapse `Tenet Vocal Artists & Alkemie` and `The New York Neo-Futurists`, and does NOT collapse `Ballets with a Twist` (a plural difference), which is a real residual the issue names rather than hides.

**The four filters, each named, each with its measured drop rate (L93):**
1. **The geography gate itself**, run over the org's own rows through the existing `EventPlace` / `GeoRefusals` predicate. Not redesigned (constraint 13), invoked.
2. **`ProducerGate.isVenueBrand`** (`ProducerGate.swift:140`), to drop venue-brand names. **Measured: drops 4 of the 225**, `52nd Street Project`, `LOL! The Players Theatre Short Play Festival 2026`, `Museum of Chinese in America and Chinese Theatre Works`, `The Royal Concertgebouw`. Note `"Carnegie Hall Presents"` (33 rows, the single largest presenter in the store) never reaches this filter: `GroupNameMatch.isConfident` already matches it to the watched `Carnegie Hall` source, so it leaves at the pool stage. The issue states which filter removes it, so the head is not misread as raw.
3. **The refusal set** from P4.1.
4. **Bare personal names.** Unmeasured today and **must be measured in P0.1 before it is built**, with its full drop list in the issue, because a group named for its founder or conductor is common and this filter's mistakes never reach Dan. If the rate is material, the drops go to a visible "probably not a group" list he can overrule rather than being discarded.

**The head of the pool after filters 2 and the pool fold**, measured: Metropolitan Opera 8, New York Philharmonic 5, Chautauqua Opera 4, Ballets with a Twist 4, SheATL 4, New York Chamber Music Festival 3, Emily Johnson and Kai Recollet 3, then a long tail at 2 and 1 (221 organisations, 261 rows). Institutions, promoters and agents sit in it alongside the small companies #9's scope names, which is what filters 1, 2 and 4 are for.

**The geography premise is withdrawn, on measured evidence.** An earlier draft claimed these presenters are in Dan's geography because "they passed the existing gate to be stored". They did not: `EventPlace` / `GeoRefusals` is a **queue-surface** gate, not a storage filter. **Measured: 13 of the 221 have at least one row located outside the NYC area**, `Young Euro Classic` (Berlin, Germany), `Britten Pears Arts` (Aldeburgh, England), `Edinburgh International Festival`, `SFJAZZ` (San Francisco), `China National Centre for the Performing Arts` (Beijing), `The Management of New Arts` (Taichung, Taiwan), `LABBS` (Harrogate, UK), `Harmony Sweepstakes` (San Rafael, CA), `Kaleidoscope Chamber Orchestra` (Santa Monica, CA), **`Fundación Sinfonía`** (Santo Domingo and Santiago, Dominican Republic, spelled with accents in the store, and the accent is load-bearing for an exact query), `SheATL` (Atlanta, GA), `SheDFW` (Fort Worth, TX), `Ballets with a Twist` (Bridgeport CT, Fort Lee NJ, Enterprise AL, Georgia). A further **11 have a blank location on every row**, which the gate cannot judge at all and which must not be silently treated as in-geography. **`Fryderyk Chopin Society of Texas, Inc.` is NOT an example and is deliberately excluded from the issue: both its rows read `New York, NY`, at Weill Recital Hall on 2026-10-16 and 2026-10-25.** It is a Texas-named organisation performing in New York, and citing it would be the sentence someone checks and disbelieves.

**Other requirements:**
- Ships **behind Phase 1**, because 412 of 866 rows carry a presenter and 0 of 866 carry a `websiteURL`; before Phase 1 this channel is mostly show titles.
- Its evidence is stamped at write time (P3.1, L37). This channel is the reason that rule exists.
- Its release note states the **organisation count**, not the row count.

---

## Phase 5: Success metric, wired to something with a live writer

**Cost: zero runs, zero AI. Free.**

### P5.1: Emails sent per week, against `ZSENTAT`. `priority-p2`, `discovery`.

- The metric is **emails sent**, never proposals produced. Proposals produced is a number every rival design can move without moving anything Dan cares about.
- Wired against `ZSENTAT`, which currently reads **6 ever**. **L90:** assert that every value the readout branches on is actually produced somewhere, so it cannot report a confident zero from a field nothing writes. #2401 is that exact defect here, and it is worse than a blank because it fails as a number.
- **L39, the week boundary goes through the shipped helper in Overture's one declared zone** (`mac/Overture/Domain/EasternDate.swift`, `BusinessDay.swift`, `ClockTime.swift`), never the host clock's default. With six sends in the whole store, one row in the wrong week is a visible swing in the only number the feature is judged by. **Tested with a pinned clock across a month boundary, a DST boundary and a send at midnight.**
- **L36 / L74:** a single two-week window against a one-to-two-shows-a-night cadence is noisy, so the readout aggregates and anchors ages to the **stored send instant**, never to a threshold recomputed from "now".
- **Used as a phase gate between channels, never as a veto on the feature.** Constraint 9 records that Dan chose breadth having been shown the cost.

---

## Phase 6: The seed manifest and the truncation architecture (the harness for every run-based channel)

Needed by Phases 7, 8 and 9. Its justification is two shipped files. `mac/Overture/Domain/HandoffShortfall.swift`: *"The APP wrote the queue, so it already knows what it asked for... it never synthesizes a result"*, trusting the results file's mtime over the `generatedAt` the run wrote inside it because *"the run is a fallible process reporting on itself."* `mac/Overture/Domain/SweepCoverage.swift`: *"A run that reported nothing ... is treated as INCOMPLETE, not complete."* Both work **only because the app authored the work list**. A free-ranging discovery run has no denominator, so "found nothing more" and "ran out of clock" are the same bytes (L70).

**Cost: zero runs to build; store, contract and UI work. Free.** What it protects is constraint 10, which has no free alternative.

### P6.1: `DiscoverySeedManifest`, written by the app before launch. `priority-p1`, `discovery`.
- A fixed-shape JSON handoff beside the others, with a **`docs/contracts.md` entry and a `fixtures/` guard**.
- Each seed carries an **opaque `seedId` the run must echo back verbatim, never rebuild** (the `ScoutExtractQueue` rule, learned the hard way by `PrepQueue`).
- Each seed carries its own `lastCoveredAt`, and the plan is ordered **oldest-first**, on the `WatchedSource.lastManualReadAt` precedent (`WatchedSource.swift:51`). #1189 records what a shared clock costs.
- The run may work **only** seeds present in the manifest. A result naming a seed never queued is a different failure (`unmatchedKeys`) and must not cancel out one that went missing.
- **L98, "the manifest held zero seeds" is its own non-success outcome**, distinct from a complete run and from a truncated one, and it is said on the surface. `HandoffShortfall.missingKeys` over an empty manifest reports nothing missing, which is byte-identical to a run that covered everything, and it arrives exactly when the result is most likely to be believed. Phase 7's seed list is derived from a floor Dan sets, a fold P0.2 changes and a junk exclusion list, so a near-empty manifest is a realistic outcome of an ordinary mistake. **Test: build an empty manifest and require the end state to be neither complete nor silent.** Seen red first.

### P6.2: Within-seed coverage, in the seed's own unit, never a boolean. `priority-p1`, `discovery`. **Ships before any directory or search-query seed is built.**

A single `lastCoveredAt` boolean recreates `SweepCoverage`'s problem one level down: a run that reads page 1 of a 6-page directory and hits its clock marks the seed covered, indistinguishably from one that read all 6.
- Every seed declares its **unit** (pages, result ranks, months, listing rows) and its **expected volume up front** (L24), before the loop is written.
- The run reports **what it covered in that unit**, as `SweepCoverage` takes `monthsCovered` against `stitchedMonths`; a seed is complete only when the covered set includes everything the app put in front of it.
- **A seed that reported no coverage at all is INCOMPLETE, not complete.**
- **L63:** the guard asserts the quantity it protects (ranks or pages actually read), never a proxy like "the run finished".

### P6.3: One seed is not one cost unit. `priority-p1`, `cost`.
A boutique room and a major hall's resident roster are not the same job, and a directory can consume the entire clock. The cap is expressed in the unit the limit really is (wall clock, plus per-seed unit volume), each seed states its expected volume, and the run stops on the cap rather than on a seed boundary (L81, L24).

### P6.4: End states in `RunProgress`, and a notice on a surface Dan will actually see. `priority-p1`, `discovery`.
- `mac/Overture/Domain/RunProgress.swift:153-170` defines `RunLiveness` with `idle`, `running`, `finishing`, `stopping`, `waitingOnYou`, `stalled`. **There is no state meaning "the clock ran out and I did not reach everything."** Reusing `finishing` ships the exact defect Dan named. Add the case; do not overload an existing one (`stopping` and `waitingOnYou` were each added for precisely this reason, `waitingOnYou` by #2201).
- **Three distinct non-complete end states, never collapsed:** `truncated` (the clock), `cancelled` (Dan asked it to stop, P6.6), and `emptyManifest` (P6.1). Each names the seeds it did not reach.
- **L77, a rejection RATE is its own outcome, not an ordinary expected result.** Every rejection in this design (geography, `ProducerShapedName`, the refusal read, evidence confirmation) is classified as benign, and nothing counts them, so a run that rejects one hundred percent of what it found produces the same end state, the same empty list and the same wording as a run where the web genuinely held nothing new. A fold change, a `ProducerShapedName` regression, or a geography predicate that started answering false would make the prospector permanently useless while reporting complete runs, and the detector goes back to being Dan noticing nothing has appeared for weeks. So: **report per run "found N candidates, proposed M, rejected N minus M", broken down by which check rejected them, and make a run whose rejection rate is at or near one hundred percent a NON-SUCCESS outcome with a named cause.** Tested with a fixture run whose every candidate fails one check, asserting the surface does not say nothing was found.
- The notice reuses `AppNoticeAction.finishShowsACheckMissed`'s shape (`AppNotice.swift:50/59`), a named action on the message itself, because **L80** says a message naming a specific target must carry the way to act on it.
- **Do not put it in `StatusLine`.** `StatusLine.set` refuses only a strictly lower-priority write (`if text != nil && newPriority < priority { return false }`, `StatusLine.swift:46`), so an equal-or-higher second warning silently replaces the first. A truncation notice in that one slot is erasable.
- **L79:** the notice must be *seen* at the window width Dan actually uses before the issue is closed. The toolbar tops out at ten items and macOS condenses it.

### P6.5: The discovery runner: tool scope, model pin, clock, and hostile-input posture. `priority-p0`, `security`.
- `scripts/check-detached-runner-scope.sh` scans every `mac/scripts/*.sh` calling `"$CLAUDE" -p` and fails any that hardcodes `--allowedTools` or does not fold through a `*_claude_scope` function in `mac/scripts/lib/claude-run-scope.sh`. It rides inside `scripts/test-all.sh`. The new runner **must** define its own `*_claude_scope` function. Not a style rule: #1026 measured a run making 13 Bash and 14 Edit calls with zero denials under the inherited auto mode, on a run whose own comment claimed "No Bash".
- **WebSearch is not new to this repo.** `mac/scripts/lib/claude-run-scope.sh:167` already reads `PREP_ALLOWED_TOOLS="Read,Write,WebSearch,WebFetch,Bash,Skill"`. **The decision to state is why a discovery run gets prep's breadth**: who may launch it, what it may read, what it may write, and that `--permission-mode manual` plus the #1682 plugin lockout still apply. State whether it needs Bash at all (it should not) and deny `Edit`.
- **L25 / L28, the model is pinned per task**, as `OVERTURE_MODEL_DISCOVERY` in `mac/scripts/lib/models.sh`, recorded via `record_model` (`models.sh:73`). The run may not ask questions, and leaves an honest failure record when it dies rather than an absent file.
- **L82, NAME THE CLOCK AND PROVE IT, because constraint 10 rests entirely on it.** All three shipped detached runners source `mac/scripts/lib/sleep-guard.sh`, whose header says why: a run holds a `caffeinate -i -s -w <pid>` assertion so *"an idle-sleep timeout (or a lid close) mid run"* cannot suspend or kill it, and a suspended run *"stops touching its heartbeat marker and only LOOKS dead after the marker goes stale."* The discovery runner **sources it too, exactly as the other three do**. The cap is measured on a **wall clock `Date` difference, never `ProcessInfo.systemUptime` or any awake-only clock**: overture#2220 is this app's own record of `systemUptime` losing 7.6 minutes across two closed lids on Apple Silicon and producing a confident false report every morning, and every test that injects an elapsed value agrees with the documentation by construction, so the suite is structurally unable to notice. **The chosen clock is measured across one real closed-lid sleep on Dan's Mac and the measurement is recorded in the issue before the cap is trusted.** A run whose elapsed measurement cannot be trusted (a heartbeat gap larger than the poll interval) reports as **truncated, naming the seeds it did not reach**, never as complete.
- **L11, the fourth detached run needs its own sentence in the shipped vocabulary.** `mac/Overture/Domain/DetachedRunOutcome.swift` defines `Kind` as `{ prep, scoutExtract, replyClassify }`, with `finishedEmptyMessage` giving each its own line and the file's own comment stating why: *"A run that finished empty is not silence. It is the one shape of failure that would otherwise be indistinguishable from a quiet calendar... which is why each sentence says something different and true about ITS OWN work."* Refusing to extend `RunKind` (below) is right, but leaving discovery out of THIS vocabulary means a run that dies before refreshing its results file either borrows another run's sentence or falls off the surface, and *"the prospector found nothing out there"* is precisely the message a dead run must never produce. P6.1's L98 protection covers an empty MANIFEST, not an absent or unrefreshed RESULTS file, which is the likelier of the two. **Add a `discovery` case with its own sentence in the same change, shaped like the `scoutExtract` one: say the queued seeds were NOT read, name how many, say they will be offered again on the next press.** Tested with a run that starts and produces no fresh results file, asserting the surface says the seeds went unread and never says nothing was found. Seen red first by pointing the new case at the generic prep sentence.
- **L23, fetched content is DATA, never instruction.** This is the first Overture run whose input is the open web rather than a page Dan chose to watch, and it holds Write. The run writes **only** to its own results file, **only** under the manifest's `seedId`s; it may not choose paths, tools or targets from page content; and **every field it emits is validated against a fixed shape by the app before anything is stored**. **Failure-path test:** feed a fixture page carrying instruction-shaped text and assert the output is still a well-formed result confined to the queued seeds. Seen red first.
- **Do not extend `RunKind`.** `mac/Overture/Domain/RunKind.swift:14-16` is a two-case enum (`prep`, `reachabilityCheck`) whose header records #1809: a Prep run misread as a check had every draft it wrote discarded, silently. Discovery gets its own queue file, results file and marker, on the `ScoutExtractQueue` pattern.
- **L71:** the run's watchdog must not share the abort-on-error behaviour of the work it watches. An incidental failure that kills the watchdog leaves the work running unobserved, which looks exactly like a healthy system.
- **L2:** the runner takes an injected seam for the store path (**`mac/Overture/App/StoreLocation.swift`**, not under Domain), the handoff directory, the clock and the `claude` binary, and refuses **inside the service itself** to run against the Release store or spend a real run under test. Recorded hazard: Swift tests already write into the live Debug handoff directory.

### P6.6: Stopping a discovery run, on the shipped cooperative-cancel mechanism. `priority-p1`, `discovery`, `accessibility`.

The prospector is the longest run this plan proposes (a wall-clock cap, entirely on Dan's clock, on demand) and the only one with no described way to stop it. Every other detached runner sources `mac/scripts/lib/scout-cancel.sh` and honours a cooperative cancel on its heartbeat tick (*"a cooperative stop between ticks can never interrupt a source mid-write and corrupt the shared results file, the way a kill -9 could"*), and `RunLiveness.stopping` exists with L44 and #1684 named in its own source comment. Under L44 a control that keeps offering itself after being pressed reads as broken, so the person presses it again, and here the work meanwhile is still consuming the run and still stamping seeds covered. So:
- **Source `lib/scout-cancel.sh` in the discovery runner and clear the sentinel before each start**, exactly as the other three do.
- **Wire `RunLiveness.stopping` to the ACCEPTED request** so the control stops offering itself the instant it is pressed.
- **`cancelled` is its own end state** alongside `truncated`, `emptyManifest` and `complete` (P6.4), reporting the seeds not reached.
- **Leave those seeds' `lastCoveredAt` untouched** so the next press picks them up first.

---

## Phase 7: Channel B: booked venues (#311), reframed as org discovery

Second, not first. Its seed list is enumerable up front and it carries the warmest opener the product has (Dan has already photographed in that room), but at roughly 14 usable seeds it cannot carry the milestone's first release.

**Cost: one run per press, capped by wall clock (P6.3). Expected run count: single digits, because the seed list is a low double-digit number above any floor Dan would plausibly set.** **Free version: the seed list itself is free to produce and can be handed to Dan as a list of rooms to look at by hand, with no run at all. The issue must offer that**, at ~14 seeds it is a serious option, though a weaker one than the ~9 an earlier draft assumed (escalatedDecisions).

### P7.1: Reframe and re-scope #311 in its own body. `priority-p2`, `discovery`.
#311 as written says "seed new sources from Downbeat booking venue names not already watched". Measured: `downbeat-export.json` holds **0 bookings** and 4 venues; `overture-history.json` holds 46 entries with **no venue field at all**. The literal issue is unbuildable. The real input is `overture-shoot-history.json` (322 shoots, 175 spellings), and the reframe is **find the GROUPS who play there**, not merely watch the room's calendar.

Write the corrected numbers into the issue: **133 fold keys, 35 at floor 2, 15 at floor 3; 16 already carry prospect rows and 4 more match a watched-source name, leaving 113 unseeded, of which 24 clear floor 2 and 7 clear floor 3**; after the declared junk and P0.2's fold fixes, **roughly 14 real rooms at floor 2**. **Carnegie Hall alone is 122 of 322 shoots (38%) and is already watched (its source kind is `algolia`, not html).** Earlier estimates of "40 to 50", "150/37/14", "151/33" and **"9 at floor 2 / 3 at floor 3"** are all superseded and named as superseded, so nobody sizes against them later (L61).

**The declared junk exclusion list, measured at floor 2:** `stage` (5), `google meet` (3), `337 e 6th st #4` (2), `398 broome street` (2), `75 river terrace` (2), `brasserie 8 1 / 2 and rosie o'grady` (2), `holy apostles soup kitchen 296 9th ave on` (2). **`field` is a single shoot and is not at floor 2**, so it belongs to the sub-floor junk, not the head.

### P7.2: Booked-venue seeds, idempotent on the folded venue, with an exclusion that can actually run. `priority-p2`, `discovery`.
- Keyed on the **folded venue**, not a booking id: the shoot history is regenerated wholesale and a re-export can re-mint ids. `VenueShootHistory` reached the same conclusion independently, keying its union on (venue, date).
- Seeds above Dan's chosen floor only, junk list excluded.
- **The already-watched exclusion, corrected.** An earlier draft said watched rooms are excluded "through `CalendarIdentity` / the name comparison `WatchedSourceProposal.verdict` uses". **That mechanism cannot run here.** `WatchedSourceProposal.swift:63` uses `CalendarIdentity.same($0.listingsURL, pageURL)`, a **URL** comparison and nothing else; there is no name comparison in that file. A shoot-history venue is a bare string with **no URL**. Worse, **`ZVENUENAME` is NULL on all 73 `WatchedSource` rows** (the field exists at `WatchedSource.swift:214` and nothing has ever filled it), so there is no name field to compare against either. The runnable exclusion is: **compare the folded shoot venue key against `VenuePlaces.canonicalKey` of each `WatchedSource`'s `orgName` AND its `venueName`**, and **backfilling `venueName` is a prerequisite of this phase, filed as its own sub-issue**, not an assumption buried inside it. Measured today, `orgName` alone matches only 4 further keys beyond the 16 that already carry prospect rows, which is exactly why the missing `venueName` matters.
- Truncation reported through **`HandoffShortfall`** over the app-authored manifest, naming the venues it never reached. This is the free half of constraint 10, available here and only here because the queue is finite.
- **L83:** declare ONE home for the fact "this venue was seeded". A fact written at the venue level and read at the org level goes missing in exactly one direction and each file looks correct alone (#2225 and #2226 are both that shape). Any key this mints is caught by P0.2's DERIVED guard, not by a hand-written list.

### P7.3: The honest coverage statement for #311. `priority-p2`, `discovery`.
Measured exactly through the shipped fold: **only 16 of the 133 canonical shoot keys (12%) match any venue Overture has ever scouted.** For **88%** of Dan's real venue history there is no group-level fact to fold. An earlier draft's "49 of 167 (~29%)" is withdrawn: 167 matches neither the 175 raw spellings nor the 133 canonical keys, and any generous two-way substring figure must state its denominator or it is not a number. The issue **states 16 of 133** rather than letting a surface imply coverage it is structurally unable to deliver (L83). Whether the remaining 88% gets a venue-to-calendar resolver is escalated, not assumed.

---

## Phase 8: Channel C: the open web (#9's org scout), gated on P6.2

Every one of these is unbounded by nature, which is why the manifest, the per-seed unit, the cap and the end states must all exist and be **proven** before the first one runs.

**Cost, stated before either is filed.** Each issue carries: **a hard per-run wall-clock cap (proposal: 10 minutes, measured on the clock P6.5 proves), an expected run count (proposal: one run per press, at most one press a night), and the expected unit volume per seed.** **Free version for both:** Dan reads the same directory or runs the same search himself and pastes a link into the existing lead intake, which already produces a `WatchedSourceProposal`. The issues say so, because for a handful of seeds that is genuinely competitive.

**P8.1, Directory seeds.** `priority-p3`, `discovery`. Named directories only, each declaring its unit (pages) and expected volume. Cannot start before P6.2 ships.
**P8.2, Search-query seeds.** `priority-p3`, `discovery`. Specific enumerated queries, each declaring its unit (result ranks) and expected volume. Cannot start before P6.2 ships.
**P8.3, Venue and calendar seeds (#9's second half), plugging in at the seed layer only.** `priority-p3`, `discovery`. Reuses P3's surface and P2's ledger. The milestone description already records that Phase 7 IS the venue channel, so this is additional venue reach, not the only place venues appear.

### The validation rule every open-web issue inherits, and why the earlier version of it was not enough

**L28's fourth clause is the one that matters here: verify the run did the expensive step.** The earlier draft adopted three of L28's four clauses (pin the model, forbid questions, require an honest failure record) and dropped exactly that one, on the first Overture run whose entire job is to go and look at the open web, holding WebSearch and WebFetch. **A model can return twenty entirely plausible NYC performing groups out of training data without issuing a single fetch, and every check the earlier draft listed passes for a real well-known group**: the host resolves, the name is producer-shaped, the geography gate passes. The run would report a complete, in-budget, non-truncated success; Dan would accept groups the run never found on any page; and the seed would be stamped covered so the real page is never read. That is L48's fabricated-fixture shape moved into live data, and it is invisible to every reviewer.

**So provenance is a VALIDATED field, not a display field:**
- Every proposed organisation carries **the manifest's opaque `seedId`, the exact URL it was found on, and a verbatim quoted snippet naming the group.**
- **Before any `DiscoveredOrgProposal` row exists, the APP checks in code that (a) the cited URL belongs to the seed that was queued**, never a URL the run chose for itself, **and (b) the snippet is actually present in a copy of that page THE APP fetches, not the run.**
- A proposal whose evidence cannot be confirmed is **recorded as an unverified attempt with its reason and is never shown as a proposal.** A page that changed between the run's read and the app's confirm is its own recorded reason, distinct from a snippet that was never there, because those are different facts and only one of them is fabrication (L11).
- **Failure-path test, seen red first: a fixture run output whose cited snippet does not appear at the cited URL, asserting no proposal row is created and the reason is recorded.**
- **Report per run how many proposals failed evidence confirmation**, on the same surface as P6.4's rejection breakdown.

**L27, applied on top:** the host must resolve, the name must be producer-shaped (`ProducerShapedName`, used as a predicate), and the **geography gate must pass** (constraint 13's shipped machinery, invoked not redesigned).

**L46/L47, the failed-attempt record's READER is named in the same issue that adds it**: a reachable list on the proposal surface saying how many candidates were rejected and why, grouped by cause (evidence unconfirmed, out of geography, not producer-shaped, already known, refused). Without that reader the write path runs, any is-this-used check finds the field alive, and the purpose it was added for, Dan seeing why a group he expected never appeared, silently never happens, while the records sit in the store matching no view (L45). **If it has no reader, the field is not added.**

---

## Phase 9: #12 Instagram, its own entity and its own surface

### P9.1: Instagram engagement scout. `priority-p4`, `discovery`.

**Cost: same harness, same per-run wall-clock cap, expected one run per press. Free version: Dan looks at his own follower list.** The issue states this, because Instagram is the only channel that never produces a show to shoot, which makes its cost the hardest to justify.

Reuses the harness (manifest, seed units, end states, cancel, refusal ledger) but **never the prospect row and never the queue**: a handle folds to a different key than a real name, and an Instagram account never produces a show to shoot. It gets its own entity and its own surface. Its handle is a *claim kind* in P2.1 so a refusal recorded against an org's name also blocks its handle, and vice versa. Whether it ships in this milestone at all is escalated.

---

## Cross-cutting requirements every issue in this milestone inherits

- **Fail loud.** No catch block returns a blank result or a fake success. "found nothing here" and "could not read this" are different sentences (L10, L11).
- **Protective reads fail CLOSED** (L42). The refusal ledger, `AlreadyKnownOrg`'s inputs and the geography gate's inputs: if any cannot be loaded, propose nothing and name the read that failed.
- **Rejections are counted against a RATE, not only classified by kind** (L77). A run rejecting everything is a non-success outcome with a named cause, never a quiet "nothing found".
- **Assume it runs twice.** Every write path (seed stamps, refusals, accepts, promotions) is idempotent by a store-layer unique constraint or an idempotency key, never by careful ordering in application code. This explicitly includes a second press of Accept (P3.2).
- **Never destroy good state.** A discovery refusal is additive and reversible; an **`orgRefusal` is permanent, is written only behind an explicit confirmation naming that permanence, and is never offered for reversal from a proposal surface** (P2.2b); **Accept ships with its undo** (P3.2); `ScoutService.apply` may not replace a non-scout presenter with nil and `RoomPresenterSweep` may not clear one without recording that it did (P1.2); the forced re-reads leave the fairness clock alone; nothing prunes the manifest until its replacement is verified written.
- **Any change to a stored fold ships its realignment pass in the same change**, under P0.2's two-behaviour rule: **protective tables re-key only and never delete; answer tables merge on agreement.** Coverage is enforced by a guard that DERIVES the key-bearing fields from the source, never by a hand-written list (L96, L41).
- **Every AI call site pins its model** in `mac/scripts/lib/models.sh` and records the model id in its results file (L25, L28). No run may ask questions; every run leaves an honest failure record when it dies; **every run that goes to the open web proves it went** (P8's evidence rule).
- **Every detached runner sources `lib/sleep-guard.sh` and `lib/scout-cancel.sh`**, and caps on a wall clock measured on the real hardware, never an awake-only clock (L82, L44).
- **Every AI output crossing into a store row passes a deterministic boundary check in code** (L27). A prompt rule is a hope.
- **Fetched web content is data, never instruction** (L23).
- **Errors classified once.** One shared classifier decides transient vs permanent for discovery failures. Never branch on message substrings; never default an unknown error to retryable (L35).
- **Business dates go through the shipped helper in one declared zone** (`EasternDate` / `BusinessDay` / `ClockTime`), tested with a pinned clock across month, DST and midnight boundaries (L39).
- **Deliberately inactive guards carry their activation issue in the same change** (L65). This applies to P2.1's refusal-match test.
- **`docs/contracts.md` + `fixtures/` guard** for every new handoff file, in the same PR.
- **Live-store numbers carry a live-store-claim tag**, in the shape `verified=<date> measure="..."`, per `scripts/check-live-store-claims.sh`, and use its `fixture=/pattern=/expect=` form wherever the count can be recomputed from a checked-in fixture. **Any suite reading Dan's real store goes through `mac/OvertureTests/LiveStoreClone.swift`, never a second copy of that mechanism**, and asserts invariants rather than the day's counts.
- **`scripts/test-all.sh` before every push**; a Mac change merges via `scripts/verify-and-merge-branch.sh` or `merge-when-green.sh`, never a bare `gh pr merge`, or a stale `project.pbxproj` reaches main.
- **`docs/copy-inventory.md` regenerated and cold-read** on every PR that changes what the app says, in every branch the surface can render, including the `orgRefusal` confirmation and the Accept confirmation, which are the two sentences in this milestone that describe an irreversible or recurring-cost action.

## Rival options considered

### Harvest what Overture already found (free, zero discovery runs) (`harvest`)

Bet that the binding constraint is not supply but pitchability, and answer it entirely from data already in the store. Three panellists independently measured the same numbers on the live store: 866 prospects, ~588 untriaged and future-dated across roughly 555 distinct group names, and 6 or 7 pitches ever sent. Meanwhile 454 rows (52%) carry no presenter at all and 337 of those were drained by the room guard, so most cards name a rental room Dan cannot sell a shoot to. This option builds NO finder. Phase 1a routes every feed adapter through the one shared ProducerShapedName rule (VenueTixCalendar.swift:231 already does it; OvationTixCalendar.swift:296 discards the same field, and TicketTailorCalendar.swift:121 sets presenter to the venue name unconditionally), with a source-text guard against a private copy. Phase 1b adds a ProducerNameSweep on the existing RoomPresenterSweep pattern, because a boundary rule reaches nothing already stored: 17 Green Room 42 rows re-ingested on 2026-08-09 have producer-shaped supertitles in the live feed and still carry presenter NULL. Phase 2 then ships the proposal sheet with its cards seeded ONLY from organisations Overture already holds (presenters named on prospects that are not watched, not refused, not past clients, not DNC), plus booked venues folded out of overture-shoot-history.json. That is real discovery from Dan's point of view (groups he has never acted on, provably in his geography, provably playing rooms he already watches) at zero AI cost. Ships the refusal ledger and the proposal surface, so if the panel later wants a finder, the hard parts are already built and walked. Gate: measure emails sent per week for two weeks before anything else is authorised.

**Cost:** Free, and the cheapest option by a wide margin. Zero new detached runs, zero AI calls, no widening of any runner's tool scope, no new recurring cost. The only ongoing cost is Dan's attention on the new proposal list, which is why it ships with a ceiling on unreviewed cards.

### Seed-manifest discovery engine (durable foundation, all channels plug in) (`engine`)

Bet that discovery is worth building properly once, and that constraint 10 (a truncated run must never look complete) is an ARCHITECTURE requirement rather than a copy requirement. The panel converged hard on one finding: both in-repo precedents for reporting a shortfall work only because the APP wrote the work list. HandoffShortfall.swift says so in its own header, and SweepCoverage.swift adds the rule that a run reporting nothing is treated as INCOMPLETE. A free-ranging discovery run has no denominator, so a clock-stopped run would report 'nothing pending' indistinguishably from a complete one, which is exactly the failure Dan named. So the app authors a finite, enumerated SEED MANIFEST before launch (unwatched presenters, venues with N+ shows and no calendar, booked venues from the shoot history, named directories, specific search queries), the run may only work seeds from that file, and the shortfall is a set difference computed app-side, trusting the results file's mtime over anything the run says about itself. Each seed carries its own last-covered stamp and the plan is ordered oldest-first, on the WatchedSource.lastManualReadAt precedent (#1189 is the record of what a shared clock costs: the same head of the list every press and a tail deferred forever). Identity is a CLAIM SET, not one key: a proposal carries name, site, listings and handle claims, and a refusal writes one row per claim and blocks on any match, because a group first seen on a venue listing has a name and no URL while the same group seen later has a URL and a different spelling. The data engineer measured the trap: OrgKey's fold and ProducerGate's fold disagree on exactly two of 305 live org names, and one of them is The New York Neo-Futurists, the ONE source Dan has ever taken off. A single-key refusal would re-propose it. Channels (#9 org, #9 venue, #311 booked-venue) plug in at the seed layer only. #12 Instagram gets its own entity and its own surface, reusing the harness but never the row, because a handle folds to a different key than a real name and it never produces a show to shoot.

**Cost:** No new paid services and no new recurring bill: the runs go through the existing headless claude mechanism on Dan's Max plan, so the cost is TIME and RUN COUNT (one capped run per press, default 10 to 15 minutes, plus one batched presenter pass of single-digit minutes for the backlog). What the extra spend buys over the free option is the only thing the free option cannot produce: organisations that are NOT already in the store. It also carries the largest hidden recurring cost of the three, and it is not AI: every accepted org becomes a WatchedSource fetched forever, and at 73 sources today with ScoutReadBudget.askAbove at 20, accepting twenty orgs makes the read-budget prompt fire on nearly every scout and lengthens it permanently. Build time is the real price: this is the multi-phase option.

### One channel end to end: booked venue to the groups who play there (#311 first) (`booked`)

Bet that the way to learn whether a prospector is worth building is to ship the narrowest channel that has a real chance of a booking, all the way through, and let the general engine earn itself later. #311 is the strongest candidate on the panel's own evidence: its seed list is enumerable up front and small (overture-shoot-history.json holds 322 shoots across 175 raw venue spellings, roughly 40 to 50 genuine venues once folded through VenuePlaces.canonicalKey with a band floor), so constraint 10 is satisfiable without inventing a general seed-manifest architecture, and it carries the warmest possible opener: Dan has already photographed in that room. It also cannot flood, because the seed set is bounded by venues he has actually worked. Scope: fold the shoot history to canonical venues, drop the junk the raw data contains ('Google Meet', 'Stage', 'Park Central Hotel', a newline-and-address form of Carnegie Hall), and for each venue find the groups that perform there. For venues already watched, that answer is FREE and needs no run at all, because those groups are already in the store; ship that half first and see how many cards it produces. For venues not watched, the venue-to-groups hop goes inside one capped run. Reuse the deterministic presenter work from the free option as the prerequisite (a venue whose listings name only the room yields nothing), but skip the batched AI pass unless the free half proves insufficient. Refusals get a claim-set ledger from day one (it is cheap and unbuildable later without a migration), but no seed-manifest engine, no channel abstraction, no promoted-producer wiring until the first accepted org actually reaches a show. If a pitch comes out of this, build the engine option next with real evidence behind it. If it does not, the panel has spent one channel instead of six phases finding out.

**Cost:** No new paid services. One capped run per press (default 10 minutes) for the unwatched-venue half, and zero runs for the watched-venue half, which ships first. Cheaper than the engine option in both AI time and build time because the seed set is bounded at roughly 50 venues and no general architecture is written; more expensive than the free option because it does reach outside the store. The money (really, the time) buys the one thing the free option structurally cannot: groups Overture has never seen, reached through the warmest introduction Dan has.

## Overruled dissent

- #311 doubling in size (24 unseeded keys at floor 2, not 9) is a real argument for shipping it before Phase 4, and I overruled it. The counter is measured, not stylistic: after the declared junk and P0.2's fold fixes #311 offers roughly 14 rooms, while Phase 4's pool through GroupNameMatch.isConfident is 225 organisations, 221 after ProducerGate.isVenueBrand, at zero runs and zero fetches. An order of magnitude, on the free side. I kept the order but removed the sentence the earlier draft leaned on ('#311's real yield is single digits, so it cannot be the first channel'), because that sentence is now false and a plan should not keep an argument whose premise it just corrected.
- The earlier draft's framing that P1.2's deterministic sweep is a substantial win is overruled by its own measurement: 3 hits over 427 names. I did not delete P1.2, because its provenance guard is what makes P1.4 safe and what closes the RoomPresenterSweep erasure. But the issue must say the sweep itself is worth three rows, rather than presenting a near-worthless pass as a phase deliverable.
- I overruled the instinct to keep P0.1 as a bespoke one-shot tool with its own Release-store refusal, even though a standalone tool is easier to run ad hoc. 17 shipped suites already read the live store through LiveStoreClone, whose header answers both objections (torn WAL copy, structural inability to touch the live path) in its own words. A second mechanism here would be the exact defect this plan cites OrgDoNotContact against, and 'easier to run' is not a deciding factor (right over fast).

## Ideal versus doable

The ideal version differs in four places, all deferred deliberately. (1) Evidence confirmation is specified as an app-side re-fetch of the cited page plus a verbatim snippet match; the ideal version would archive the fetched page bytes alongside the proposal so a later dispute can be settled without a third fetch, and so a page that changes between the run and the confirm can be shown to Dan rather than merely classified. Deferred because it adds a storage-growth question this milestone has not sized. (2) P4.2's bare-personal-name filter is specified as measure-first, propose-with-doubt-if-material; the ideal version would not filter at all and would instead let the card carry the doubt, since constraint 9 records that Dan chose breadth. Deferred to P0.1's measurement because dropping the filter entirely without knowing its rate is as blind as keeping it. (3) The 88% of Dan's shoot venues with no scouted-venue fact (16 of 133 canonical keys) deserves a venue-to-calendar resolver, which would turn #311 from ~14 seeds into most of his history. That is a whole channel, escalated rather than assumed. (4) The realignment pass is specified to be rehearsed against a WAL-consistent copy with per-table before and after counts; the ideal version would make that rehearsal an automatic part of shipping any fold change (a harness, not a checklist item), which is a tooling issue of its own and is not filed here.

## Open risks

- The evidence-confirmation rule (P8/L28) can produce false rejections: a listing page that legitimately changes between the run's read and the app's confirm will fail the snippet match, and a real organisation is then recorded as an unverified attempt rather than proposed. The plan gives that its own recorded reason distinct from a snippet that was never there, but the rate is unknown until the first live run, and if it is high the channel looks broken while working correctly. P6.4's rejection-rate outcome is what makes that visible rather than silent.
- P1.4's 12,155 characters is measured on today's 278 pairs. Nothing caps that number: a scout run that adds a few hundred presenter-less rows moves it, and the batch was sized once. The issue must re-measure at run time and refuse rather than truncate if the payload exceeds what one call can carry (L81/L87).
- RoomPresenterSweep runs every launch and clears any presenter that reduces to its own venue. P1.2 keeps that behaviour and adds a record, but if P1.4's model returns a name that legitimately IS close to the room's name (a resident company named for its hall), the sweep will keep clearing it and the record will keep saying so. The plan does not resolve that case; it only makes it visible.
- The bare-personal-name filter's drop rate is unmeasured. If it turns out to be large, P4.2's pool shrinks materially and the channel's headline number (221) is optimistic. That is the single biggest remaining uncertainty in Phase 4's sizing and it is why P0.1 must measure it before the filter is built.
- The wall-clock measurement across a real closed-lid sleep (P6.5/L82) needs Dan's own Mac and one overnight cycle. Until that measurement exists, constraint 10's hard requirement rests on an unproven guarantee, and the plan's own record (overture#2220) is that this app has already been burned by exactly that assumption.
- GroupNameMatch.isConfident does not collapse 'Ballets with a Twist' against the watched source 'Ballet With A Twist' (a plural difference). So the 225-name pool contains at least one organisation that is already watched, and probably more of the same shape. The plan names this residual rather than fixing it, because widening a shipped confidence fold is a separate change with its own blast radius.
- ZVENUENAME is NULL on all 73 watched sources, and P7.2's exclusion depends on backfilling it. That backfill is filed as a prerequisite sub-issue, but nothing has yet established where the venue name would come from for every source kind, so the prerequisite may itself be non-trivial.
- The store holds zero orgRefusal rows and zero orgDoNotContact prospects, so the entire refusal-matching path ships uncalibrated against real data and stays that way until Dan makes his first live refusal. P2.1 marks that test as awaiting calibration with its activation issue filed alongside (L65), which is the honest handling, but it means the product's one unrecoverable action is guarded by a rule nobody has yet seen fire on real input.


---

# Filed as milestone 57

https://github.com/danwright32/overture/milestone/57 (issues #2450 to #2476, created 2026-08-10).
The issues carry the corrections below, not the panel wording above.

# Corrections applied to the prospector plan

Authoritative. Where this document and the panel's plan disagree, this document wins.
Applied 2026-08-10 after Dan answered the escalated decisions.

## A. Phase 7 replaced wholesale (Dan's design, 2026-08-10)

The panel planned #311 as a discovery channel over a backfilled list of about 14 historical rooms.
Dan rejected the premise: he has already worked his backlog, so those rooms are not opportunity, they
are rooms he already considered and decided about. Everything the panel measured about shoot floors
(24 at floor 2, 7 at floor 3, the junk exclusion list, the 88% coverage statement) is **withdrawn as
the basis for this phase**, and the escalated questions about which floor to use and whether to build
a venue-to-calendar resolver for the remaining 88% are **void**.

The replacement is forward-only:

1. A booking appears at a venue Overture is not already watching.
2. Overture surfaces it: you shot here, do you want to watch this room's calendar.
3. Dan answers yes or no. That is the whole interaction. No run, no AI, no group discovery.
4. **No backfill, ever.** Every venue present in the shoot history when this ships is seeded into the
   decided-set at install, so none of it is ever surfaced.

**How "new" is detected.** The shoot history is regenerated wholesale, so a booking id cannot be
trusted (`VenueShootHistory` reached the same conclusion and keys its union on venue plus date). New
means a folded venue key absent from a stored decided-set. That set is seeded at install with every
key currently in history, which is the same mechanism that delivers the no-backfill rule. One
mechanism, two requirements.

**Reuse rather than invent.** `ClientCoverage` already does this exact shape for clients: it names
Downbeat clients no watched source covers, offers to add a source, and offers to set one aside so a
decided client stops reappearing. The venue version is that, forward-only.

**Surviving prerequisite from the panel's work.** The already-watched exclusion still cannot run as
the panel's earlier draft assumed: `WatchedSourceProposal.swift:63` compares URLs only, a shoot venue
is a bare string with no URL, and **`ZVENUENAME` is NULL on all 73 `WatchedSource` rows** though the
field exists at `WatchedSource.swift:214`. Backfilling `venueName` remains a prerequisite sub-issue.

**Cost:** free. Zero runs, zero AI. The only cost is the paid read of the accepted calendar when it
changes, which is the same commitment as any other accept (see C1).

## B. New phase added: the venue channel

With #311 reduced to a prompt, it discovers nothing, so the panel's answer that "Phase 7 is the venue
channel" no longer holds and #9's venue half had no home. Dan chose a real venue channel, shipped
after the organisation channel so the proposal surface and refusal memory are proven first. It uses
the same seed manifest, time cap and truncation reporting as the org channel, and proposes rooms and
calendars into the same proposal list.

## C. Six claims corrected (reality check, still failing after two automatic rounds)

1. **P3.3's cost line said "this cost is not AI". Wrong.** `ScoutReadBudget.pending` counts pages whose
   content CHANGED and therefore need a PAID read. Every accepted organisation adds a calendar that
   triggers a paid read whenever it changes. The honest line is: a free fetch and hash, plus a paid
   read on every change, plus Dan's time.
2. **P3.3's mechanism was misread.** `askAbove` (20) is compared against pending CHANGED sources, not
   the watchlist total, which is already 73. Twenty accepts do not make the prompt fire on nearly
   every scout; they raise it only on nights when those twenty changed. The concern is real, the
   stated mechanism was not.
3. **P1.2's erasure hazard is already live, not conditional on a future adapter change.**
   `ExtractedEventGuard.presenterThatIsNotTheRoom` runs on both ingest paths today
   (`ScoutService.swift:546`, `ScoutExtractResults.swift:50`) and `ScoutService.swift:1420` already
   nils a room-named presenter on an ordinary re-read. The provenance guard is therefore a
   **prerequisite of P1.4**, not a companion to P1.1, and the issue order says so.
4. **P4.2's row count:** 259 rows, not 261. The 221 organisations figure is exact.
5. **P4.2's blank-location count:** 10 organisations, not 11. They are Elizabeth Acevedo, Kyle
   MacLachlan, National Theatre Live, On Her Shoulders, R.F. Kuang, Selected Shorts, Silent Clowns
   Film Series, The Folk Music Society of New York, Treble Harmony Brigade, Uptown Showdown. Three
   are bare personal names, which is evidence for the unmeasured bare-name filter and is cited there.
6. **P3.2's arithmetic:** 237 of 254 presenters play exactly one distinct venue and 17 clear the
   two-or-more arm, not 235. Nobody plays zero. The argument is unchanged and slightly stronger.

## D. Nine lessons violations resolved

1. **L16 (P4.2).** The count shown to Dan and the rows the channel proposes must come from ONE
   predicate. The plan sized the headline through `GroupNameMatch.isConfident` while the shipping
   filter uses a different fold (`OrgKey.of` does not strip a leading article; `ProducerGate.key` and
   `GroupNameMatch` do). Fix: one named fold, used by both the count and the filter, stated in the
   issue.
2. **L55 (P1.2, P1.4).** `presenterWasTheRoom` has live readers (`QueueView+Model.swift:36` and
   `:2069`) that explain a blank presenter. Writing a presenter onto a flagged row leaves the flag
   true and the card asserting an explanation that is no longer true. Fix: any write that fills the
   presenter clears or re-derives the flag in the same change.
3. **L92 (P2.2).** A refusal must be recorded against **every** claim the proposal carried, not one
   unique-keyed claim, or a name-only refusal fails to block the same group arriving as a handle or a
   URL. This is overture#2392 into #2421 exactly, and constraint 6 makes it the milestone's core
   promise.
4. **L95 (P1.2).** `RoomPresenterSweep` today only clears a field, and its own header says that is
   recoverable by design because a later scout can write the name back. The plan would add a durable
   exclusion write to that path, turning a misclassification into a permanent lockout. Fix: keep the
   sweep recoverable; if an exclusion must be stored, it is a separate reviewable record with a way
   back, not a silent write on a classification path.
5. **L96 (P7.1).** Void with Phase 7's rewrite. The hand-written junk list is gone with the backfill.
6. **L77 (Phase 4).** Phase 4 ships before any run accounting exists, and rejects candidates through
   four filters whose rejections nothing counts, so a broken geography predicate or fold regression
   would empty the channel while showing the same screen as "you already watch everyone". Fix: Phase
   4 counts its own rejections by filter from its first release.
7. **L4 (P0.2).** The realignment pass re-keys protective tables and deletes duplicate rows. Merged
   and green is not applied: it runs at launch in a build Dan has to install, and the installer has
   its own refusal paths. Fix: the issue is not done until the pass is verified to have run against
   the live store.
8. **L91 (P2.2, P2.3).** `RefusedOrgClaim` is read by the proposal filter and by `AlreadyKnownOrg`, so
   a live query over it rebuilds those surfaces on every refusal press. The refuse control ships in
   Phase 2, two phases before the enumeration work. Fix: the refuse press must not invalidate a whole
   list; the invalidation cost is examined in the change that ships the control.
9. **L53 (P1.3).** Two independent forced re-reads with two separate justifications were given one
   idempotency marker, so whichever runs first marks the other done and 164 rows keep the wrong
   presenter while the surface reports complete. Fix: one marker each.

## E. Decisions Dan settled

1. #311 is forward-only, no backfill (A above).
2. A real venue channel ships after the organisation channel (B above).
3. The accept confirmation states the cost as Dan accepts: how many calendars he watches and that
   this adds one more to be read whenever it changes.
4. Instagram stays in this milestone as its own phase at the lowest priority.
5. The two questions about shoot floors and a venue-to-calendar resolver for the unscouted 88% are
   void with the Phase 7 rewrite.
