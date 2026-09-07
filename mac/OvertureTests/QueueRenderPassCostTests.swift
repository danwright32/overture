import Testing
import Foundation
import SwiftData

// #1913: what one render pass of the queue is allowed to cost.
//
// Every issue in this milestone was found by reading code AFTER Dan reported the queue stuttering on
// 2026-07-29. Nothing measured what a pass costs, so once they were fixed there was no mechanism that
// would notice the cost creeping back: the detector was Dan, months later, and the same investigation
// would run again.
//
// The cost here is countable rather than timed, which is what makes it a test rather than a flaky
// benchmark. A whole-store sweep is the unit: the pass can only reach the rows through `Corpus.all`, so
// every sweep is counted whether or not whoever added it thought about the cost. A counter the new code
// had to opt into would only ever measure the costs somebody already knew about.
//
// The number below is pinned deliberately, and is meant to be READ and argued with rather than updated to
// whatever the code happens to do. Raising it is a decision about how much a keystroke, a dismiss and a
// scroll are allowed to cost Dan.
@MainActor
@Suite("One render pass of the queue costs a pinned number of sweeps (#1913)")
struct QueueRenderPassCostTests {
    // The live store, re-measured 2026-09-02 on a WAL-inclusive copy: 1,139 prospects, 587 of them
    // untriaged. A corpus that size is what makes the count meaningful: at ten rows every shape is fast
    // and nothing is learned.
    //
    // Both figures carry a LIVE-SHAPE tag, so scripts/check-fixture-corpus-drift.sh compares them
    // against the real store on every push and says which one has fallen behind. Before #3426 this read
    // 724 and 511, measured 2026-08-01, and had been exercising a store a third smaller than the one
    // that ships for a month with nothing reporting it: the guard stays GREEN the whole time, because it
    // is protecting a smaller world rather than failing (L354).
    // LIVE-SHAPE: prospects
    private static let corpusSize = 1224
    // LIVE-SHAPE: untriaged
    private static let untriaged = 545

    // Ten sweeps of the store, once each, and every one of them named. If this number moves, one of
    // these lines has changed or a new one has appeared, and either is a decision rather than an accident:
    //
    //   1. the whole-store corpus the rows are judged against (venue brands, inherited answers)
    //   2. deriving the queue's own scope from it (#3507)
    //   3. resolving each show's place for the pass (#1962)
    //   4. building the queue's rows
    //   5. the shows already reached out to
    //   6. which shows are in a stage at all
    //   7. which of those the focused stage renders
    //   8. the agent strip's inputs
    //   9. the possible-match fan-out scan
    //  10. handing the scope to the render path, which walks it per row (#3507)
    //
    // WAS EIGHT UNTIL #3507, AND THE RISE IS THE PASS GETTING CHEAPER, which is the one reading of this
    // number that has to be written down rather than left to be worked out. `QueueView` used to hold TWO
    // `@Query` properties over `Prospect`, and SwiftData satisfies each independently: measured against
    // the live store on 2026-09-05, a repeat of the identical descriptor cost 143.3 ms against a cold
    // 148.5 ms over 1153 rows, so the whole table was read and materialised twice on every store
    // notification (`QueueRenderPassLiveStoreCostTests`). #3507 removed the second query and derives the
    // scope from the first instead. Lines 2 and 10 are what that costs: two in-memory walks, in place of
    // an 85 ms database read this counter never could see, because it counts walks over rows the pass was
    // HANDED and the fetch happens before the pass begins.
    //
    // So this counter is not a cost measure on its own and must not be read as one (L63). The figure that
    // moved in the direction anybody cares about is in `QueueRenderPassLiveStoreCostTests`.
    private static let allowedSweeps = 10

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A corpus with the spread a real store has: most rows untriaged, the rest drafted or contacted, and
    // dates either side of today, so no sweep can short-circuit on an empty or uniform list.
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let venues = ["Weill Recital Hall", "SoHo Playhouse", "The Green Room 42", "Merkin Hall",
                      "Roulette Intermedium", "The Tank", "Bargemusic", "David Geffen Hall"]
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let day = 1 + (n % 27)
            let month = 8 + (n % 4)
            let date = String(format: "2026-%02d-%02d", month, day)
            let venue = venues[n % venues.count]
            let key = "row-\(n)"
            let p = Prospect(naturalKey: key, groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: venue, performanceDate: date, sourceListingURL: nil,
                             priorRelationship: "none", production: n % 3 == 0 ? "self" : "presenter",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 4 + (n % 5),
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil,
                             possibleMatchName: n % 40 == 0 ? "Carnegie Hall" : nil,
                             status: n < Self.untriaged ? .new : (n % 2 == 0 ? .drafted : .contacted))
            p.presenter = n % 5 == 0 ? venue : "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
            rows.append(p)
        }
        try? ctx.save()
        return rows
    }

    private func inputs(_ rows: [Prospect], tally: QueueRenderPass.CostTally) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows, tally: tally),
            inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: .scout, focusedKeys: nil)
    }

    // The measurement. One pass over a realistic store sweeps it a pinned number of times.
    @Test func onePassSweepsTheStoreAPinnedNumberOfTimes() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let tally = QueueRenderPass.CostTally()

        let data = QueueRenderPass.make(inputs(rows, tally: tally))

        // The list at the top of this file names every one of them. Raising the number is a decision
        // about how much a keystroke, a dismiss and a scroll are allowed to cost Dan.
        #expect(tally.sweeps == Self.allowedSweeps)
        // And it really did derive the whole store, so the count above is not the cost of doing nothing.
        #expect(data.items.count == Self.corpusSize)
        #expect(!data.visible.isEmpty)
    }

    // The cost does not grow with what Dan is looking at. A stage focus, a frozen key set and a deep link
    // all change what renders, and none of them may add a trip through the store.
    @Test func lookingAtADifferentStageCostsTheSameSweeps() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        for stage in [StageFocus.scout, .review, .prep, .sendApproved, .followUps] {
            let tally = QueueRenderPass.CostTally()
            var i = inputs(rows, tally: tally)
            i.focusedStage = stage
            _ = QueueRenderPass.make(i)
            #expect(tally.sweeps == Self.allowedSweeps, "the \(stage) stage cost a different number")
        }
    }

    // A frozen key set (leads mode) is the other way the queue can be narrowed, and it must not cost more
    // either: the rows are filtered from what the pass already built.
    @Test func aFrozenKeySetCostsTheSameSweeps() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let tally = QueueRenderPass.CostTally()
        var i = inputs(rows, tally: tally)
        i.focusedStage = nil
        i.focusedKeys = rows.prefix(20).map(\.naturalKey)

        let data = QueueRenderPass.make(i)

        #expect(tally.sweeps == Self.allowedSweeps)
        #expect(data.focusedRows.count == 20)
    }
}

// The other half of the cost, and the one a sweep count cannot see: a file read on the render path. The
// pass takes every file-backed answer as a value, so it cannot reach the filesystem at all, and this is
// what holds it to that.
@Suite("A render pass reads no files (#1913)")
struct QueueRenderPassIsPureTests {
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift") }

    @Test func thePassNeverTouchesTheFilesystem() {
        #expect(!renderPass.isEmpty)
        // Each of these was, at some point, read from inside the queue's own derivation: the Gmail token
        // (#1770), the shoot history and the Downbeat export (#1964), and the two detached run markers
        // (#1923, #1938). The rest are handed in as values now; the shoot history is not read here at
        // all any more (#2080 removed the only card that wanted it), and stays on this list so putting
        // a file read back on the render path is a red test rather than a silent regression.
        for reader in ["GmailConnection", "VenueShootHistory.current", "DownbeatBridge.loadedExport",
                       "ShootHistory.load", "PrepQueueService.isRunning", "ReplyClassifyService.isRunning",
                       "FileManager", "Data(contentsOf:"] {
            #expect(!renderPass.contains(reader),
                    "\(reader) is a filesystem read, and this runs on every render pass")
        }
    }

    // The counting is not optional. If the rows could be reached around the corpus, a new sweep would be
    // invisible to the measurement above and the guard would quietly stop guarding.
    @Test func theRowsCanOnlyBeReachedThroughTheCountedAccessor() {
        guard let corpus = SourceGuardHelper.propertyBody("struct Corpus {", in: renderPass) else {
            Issue.record("expected to find the corpus")
            return
        }
        #expect(corpus.contains("private let rows: [Prospect]"))
        #expect(corpus.contains("tally?.recordSweep()"))
    }
}

// #2048: the sweep count above is a PROXY for render cost, not render cost.
//
// Demonstrated by #2033 part 2: that change tripled the per-card work (three `SendGroup.pendingGroup`
// calls, each running the draft lint over every contact) entirely INSIDE one sweep. The sweep count did
// not move, so the guard passed and the whole suite stayed green while the thing the guard exists to
// protect grew threefold. That is L63 exactly: a regression guard must assert the quantity it exists to
// protect, never a proxy for it, because the pinned number stays constant for the whole time the defect
// is growing.
//
// So the unit here is the WORK UNIT, counted where the work actually happens rather than where somebody
// remembered to add a counter. All three counters are read through a task-local, which is what gives
// them the same property `Corpus.all` has: a new call site is counted whether or not whoever adds it
// thinks about the cost. A tally handed in as a parameter would have been opt-in, and #2033's three
// calls were added by someone who was not thinking about cost, which is the whole point.
//
// WHY THE FIXTURE GREW CONTACTS. Before this it held 1,139 prospects and NOT ONE recipient, so every
// per-contact path short-circuited on its first line and a lint counter pinned against it would have
// read zero. Zero is indistinguishable from a real measurement (L90), and a fixture that exercises only
// the cheap branch measures the branch that does not ship (L101).
@MainActor
@Suite("One render pass does a pinned amount of per-card work (#2048)")
struct QueueRenderPassWorkUnitCostTests {
    // The live store, measured 2026-09-03 on a WAL-inclusive read-only copy: 1,142 prospects, 305
    // recipients spread over 198 of them, 279 of those recipients pending, and 39 prospects carrying a
    // draft body. Every one carries a LIVE-SHAPE tag so check-fixture-corpus-drift.sh names whichever has
    // fallen behind the real store, rather than the fixture quietly measuring a smaller world (L354).
    //
    // The SPREAD is the load-bearing part, not the totals. 944 of the 1,142 rows have no contact at all,
    // so the per-contact work short-circuits on the overwhelming majority, and a fixture giving every row
    // a contact would measure a path the live store does not take and argue for a fix aimed at the wrong
    // half (the same reasoning QueueRebuildCostTests records for its own shape).
    // LIVE-SHAPE: prospects
    private static let corpusSize = 1224
    private static let recipientCount = LiveContactShape.recipients
    private static let prospectsWithAContact = LiveContactShape.prospectsWithAContact
    private static let pendingRecipients = LiveContactShape.pendingRecipients
    private static let prospectsWithADraftBody = LiveContactShape.prospectsWithADraftBody
    // #3506: the INTERSECTION, and the dimension this fixture was missing. Every figure above matched the
    // live store exactly and the corpus still exercised five and a half times the real draft lint load,
    // because the lint scales with PENDING recipients that carry a body and nothing recorded that pairing.
    // Measured 2026-09-03: 42 recipients sit on the 38 body-carrying rows that have a contact, and only 16
    // of them are pending. Every one of the store's 26 non-pending recipients is on such a row, which is
    // what makes the shape consistent: a row gets a body when it is prepped, and its contacts are sent
    // from there.
    private static let recipientsOnDraftBodyRows = LiveContactShape.recipientsOnDraftBodyRows
    private static let pendingRecipientsWithADraftBody = LiveContactShape.pendingRecipientsWithADraftBody

    // #3516: the DATE dimension, which is what the self-booking check scales with and what nothing here
    // recorded. `SelfBookingConflict.NightIndex` buckets by night and the work per row is the size of the
    // bucket its nights fall in, so the term is quadratic in shows sharing a DATE and flat in row count.
    //
    // The fixture used to spread its dates as `1 + (n % 27)` over four months, giving 108 distinct dates
    // and a largest cluster of 11 against the live store's 19. #3516 read that as the term being
    // exercised at half intensity. MEASURED, it was the opposite, and this is worth knowing before anyone
    // reaches for the largest cluster again as the thing to match: an even spread of 1,142 rows over 108
    // dates carries a nightly comparison load of 12,102 against the live store's 9,037, because packing
    // MORE rows into FEWER dates raises the total even while lowering the maximum. The largest cluster
    // bounds the worst single row; it does not describe the load (L391).
    //
    // So BOTH are recorded, and the seed is built from the live store's own size histogram rather than
    // from a spread chosen to hit one number. Measured 2026-09-05 on a WAL-inclusive copy: 1,153 rows
    // over 235 dates, none undated, largest cluster 19, and 9,037 as the sum of each date's squared size,
    // which is the quantity the check actually pays.
    // LIVE-SHAPE: largestSingleDateCluster
    private static let largestSingleDateCluster = 19
    // LIVE-SHAPE: sameNightComparisonLoad
    private static let sameNightComparisonLoad = 10086

    // One card built per row, and not one more. This is the counter #2033 would have moved.

    // RE-DERIVED 2026-09-07, against the live store's own shape rather than a corpus 7% short of it.
    // Every pin below moved, and each moved with the dimension it depends on rather than on its own:
    //
    //   cards and send groups   1142 -> 1224, exactly the corpus, one of each per row as before
    //   draft lint runs           32 -> 82,   two per pending body-carrying recipient, as before,
    //                                         and that dimension went 16 -> 41 (2.6x)
    //   lint outside the build    16 -> 41,   exactly one per pending body-carrying recipient
    //   self-booking examined    145 -> 320
    //
    // The last one moved 2.2x while the corpus moved 1.07x and the comparison load 1.13x, and that is
    // expected rather than a defect: the check is quadratic in shows sharing a DATE, and the live
    // histogram has thickened in the middle since it was last recorded (dates holding 13 shows went 5 to
    // 10, one now holds 15, and dates holding a single show fell 66 to 62). The largest cluster did not
    // move at all, which is exactly why this fixture records the whole histogram and not the maximum
    // (L391).
    //
    // What this says about the instrument, which is the reason Phase 0 exists: before this, the fixture
    // reported the app running the draft lint 32 times per pass when it really runs it 82, so every
    // judgement about whether that cost was worth attacking was made against a store 60% smaller than
    // the one that ships (L354).
    private static let allowedQueueItems = 1224

    // One send-group build per card. #2046 collapsed three of these into one; nothing pins that it stays
    // one, which is exactly how #2033 put the cost back without moving a number.
    private static let allowedSendGroupBuilds = 1224

    // How many times the draft lint actually runs over a body during one pass. MEASURED, then pinned,
    // and meant to be argued with rather than updated to whatever the code does.
    //
    // Only a recipient whose `effectiveBody` is non-empty reaches `DraftCheck` at all, because
    // `Recipient.draftLintBlockers` short-circuits on an empty body first, so this is a fact about the
    // SHAPE and not about the row count. It is held separately from the two counters above for that
    // reason (#3435 2c: a shape-driven term goes against its own measure, never folded into a per-row
    // figure).
    //
    // #3498 brought it down. Every reader on a card now shares ONE pass of the lint per pending
    // contact carrying a body, so the card build runs it 16 times over this corpus, one per such contact,
    // where it ran 64. What remains is the 18 outside card construction, which this change does not touch
    // and which is now the larger share.
    //
    // #3506 re-derived it before that. This read 402 while the corpus gave every body-carrying row two PENDING
    // contacts, which no dimension then recorded: the fixture matched the live store on recipients,
    // contacts, pending count and bodies, and still exercised five and a half times the real lint load,
    // because the lint scales with the INTERSECTION. At the measured shape it is 82, against the live
    // store's own reading of 73 taken through `QueueRenderPassLiveStoreCostTests` the same day, both
    // BEFORE #3498. The
    // remaining gap against the live store is the same unattributed term #3498 records. How the 82 splits
    // between card construction and the rest of the pass is MEASURED by
    // `theLintRunsAreAttributedBetweenCardBuildAndTheRestOfThePass`, not asserted here.
    // #3516 moved it from 34 to 32, and the reason is the fixture's DATE SPREAD rather than anything in
    // the code. This corpus used to lay 1,142 rows across 108 dates in four months; it now lays them
    // across 224 dates at the live store's own clustering, which spans about eight. The live store spans
    // 2026-06-22 to 2027-07-08, so the old window held far more of the corpus inside the scout horizon
    // than the real one does, and both lint terms were measured against that.
    private static let allowedDraftLintRuns = 82

    // MEASURED on this corpus by `theLintRunsAreAttributedBetweenCardBuildAndTheRestOfThePass`, not
    // derived. An earlier version of this file asserted the split from arithmetic on a different
    // fixture's per-contact figure and wrote it down as fact; the arithmetic happened to be right, and
    // that is luck rather than method (L32, L353).
    //
    // Unchanged by #3498, which is the point of holding it separately: that change removed the repeated
    // linting inside card construction and this term is somewhere else in the pass, so it is now the
    // MAJORITY of what the lint costs. It is what #3498's own text called the unattributed 90 at the
    // original shape.
    //
    // #3518 GAVE IT AN OWNER, and decided from the number rather than fixing it. All sixteen belong to
    // `StageNavigation.counts`, reached through `AgentInputs.from`, and every other whole-store
    // derivation in the pass runs the lint zero times. They are an exact duplicate of the sixteen the
    // card build already ran, over the same sixteen pending contacts, so they COULD be removed. They
    // cost 3.5 ms against a pass of 584.3 ms, which is 0.595%, and this file has watched two caches be
    // built and reverted on #1930 for larger savings than that. So the term is attributed and priced
    // rather than removed, which is a real result and stops it being investigated again (L248).
    // `LintRunsOutsideTheCardBuildTests` holds both the attribution and the price.
    private static let allowedLintRunsOutsideTheCardBuild = 41

    // WHERE the 82 goes, measured on THIS corpus rather than inferred from the single-row attribution
    // test below. The first version of this suite carried the split as a comment reading "64 of the 82
    // are card construction and 18 elsewhere", arrived at by multiplying 16 contacts by the per-contact
    // figure of 4 measured on a DIFFERENT fixture, and written down as though it had been measured. That
    // is the habit this milestone has spent a day correcting in other code (L32, L353).
    @Test func theLintRunsAreAttributedBetweenCardBuildAndTheRestOfThePass() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let cardsOnly = QueueRenderPass.WorkTally.measure {
            for row in rows { _ = QueueItem(row) }
        }
        let wholePass = QueueRenderPass.WorkTally.measure {
            _ = QueueRenderPass.make(inputs(rows))
        }

        #expect(cardsOnly.draftLintRuns > 0, "building every card ran the lint zero times")
        #expect(wholePass.draftLintRuns == Self.allowedDraftLintRuns)

        let elsewhere = wholePass.draftLintRuns - cardsOnly.draftLintRuns
        #expect(elsewhere == Self.allowedLintRunsOutsideTheCardBuild,
                Comment(rawValue: "building every card ran the lint \(cardsOnly.draftLintRuns) times and "
                        + "a whole pass ran it \(wholePass.draftLintRuns), so \(elsewhere) happen "
                        + "OUTSIDE card construction. #3498 is where that term is chased; this pins it so "
                        + "it cannot grow unnoticed."))
    }

    // #3516: the self-booking term, pinned at last, and BOTH numbers are the finding.
    //
    // A render PASS examines ZERO shows, on any stage. `QueueRenderPass.make` BUILDS the night index and
    // never asks it a question; every question is asked by the view, per rendered row and per date
    // heading. So pinning "per pass" as #3516 proposed would have pinned zero, and a counter whose only
    // input is a value nothing produces reports zero indistinguishably from a real measurement (L90).
    // It is pinned anyway, as its own assertion, because zero here is a FACT about where the work lives
    // and the next person to look should not have to rediscover it.
    private static let allowedSelfBookingShowsExaminedInThePass = 0

    // What the SCREEN costs, which is the number this issue was really after: a pass on a stage that
    // shows the marker, plus the three questions the view asks of the index while drawing the result.
    // Measured on the corpus at the live clustering.
    private static let allowedSelfBookingShowsExaminedOnScreen = 320

    // And zero again on Scout, because the view asks nothing there (`focusedStage != .scout` gates both
    // the row marker and the date-heading note). Held separately so a change that starts asking on Scout
    // is visible rather than absorbed into the number above.
    private static let allowedSelfBookingShowsExaminedOnScout = 0

    // The per-contact multiplier, pinned separately so a change that moves work between the send-group
    // build and the card build is visible even when the total holds. Measured, not read off the code.
    private static let allowedLintRunsPerContactInCardBuild = 1
    private static let allowedLintRunsPerContactInSendGroupBuild = 0

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The corpus, at the spread measured above. Contacts go on the FIRST `prospectsWithAContact` rows and
    // bodies on the first `prospectsWithADraftBody` of those, so the two populations nest the way they do
    // on the real store (a row cannot carry a drafted body with nobody to send it to).
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        let venues = ["Weill Recital Hall", "SoHo Playhouse", "The Green Room 42", "Merkin Hall",
                      "Roulette Intermedium", "The Tank", "Bargemusic", "David Geffen Hall"]
        var rows: [Prospect] = []
        // #3516: the live store's own date clustering, from the one place that records it.
        let dates = LiveDateClustering.dates(forRows: Self.corpusSize)
        for n in 0..<Self.corpusSize {
            let date = dates[n]
            let venue = venues[n % venues.count]
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: venue, performanceDate: date, sourceListingURL: nil,
                             priorRelationship: "none", production: n % 3 == 0 ? "self" : "presenter",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 4 + (n % 5),
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil,
                             possibleMatchName: n % 40 == 0 ? "Carnegie Hall" : nil,
                             status: n % 3 == 0 ? .drafted : .new)
            p.presenter = n % 5 == 0 ? venue : "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            // A body on the first `prospectsWithADraftBody` rows only. Invented text, never a real draft,
            // and deliberately clean of anything DraftCheck blocks, so the lint does its whole pass
            // rather than bailing at its first finding.
            if n < Self.prospectsWithADraftBody {
                p.draftBody = "Hello there,\n\nI photograph performances in New York and would love to "
                    + "cover this one. My work is at the link below.\n\nBest,\nDan"
            }
            ctx.insert(p)
            rows.append(p)
        }
        // The recipients, laid out to the measured shape rather than spread evenly, because the shape
        // is the whole point. The layout DECISION lives in `LiveContactShape` because the hosted rig
        // needs the identical spread and a rule's data shared while the loop applying it is copied is
        // not consolidation (L370). What stays here is turning that decision into this target's objects,
        // which a shared file cannot do: `mac/TestSupport` is compiled into both targets and they reach
        // the app differently, so it cannot name `Recipient` at all.
        for (index, place) in LiveContactShape.placements(rowCount: rows.count).enumerated() {
            addRecipient(ctx, to: rows[place.row], index: index, pending: place.pending)
        }
        try? ctx.save()
        return rows
    }

    private func addRecipient(_ ctx: ModelContext, to prospect: Prospect, index: Int, pending: Bool) {
        let r = Recipient(id: "contact-\(index)",
                          email: "contact\(index)@example.com",
                          name: "Contact \(index)",
                          role: "programming",
                          provenance: .presenter)
        r.sendState = pending ? SendState.pending : SendState.sent
        r.prospect = prospect
        ctx.insert(r)
    }

    private func inputs(_ rows: [Prospect], stage: StageFocus = .scout) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows),
            inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: stage, focusedKeys: nil)
    }

    // The fixture really does carry the shape it claims, because every count below is only meaningful if
    // the rows underneath it exist (L48).
    //
    // Read what this can and cannot see. Both sides come from the same constants, so it CANNOT tell that
    // the fixture has drifted from the live store: that is scripts/check-fixture-corpus-drift.sh's job,
    // through the LIVE-SHAPE tags above, and it compares against the real thing (L70). What it CAN see is
    // a seed that did not produce what it intended, which is the likelier accident here, because the
    // recipient loop distributes a fixed total over a fixed number of prospects and an off-by-one in
    // either bound leaves it short with nothing else complaining.
    @Test func theFixtureCarriesTheLiveShape() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let recipients = try ctx.fetch(FetchDescriptor<Recipient>())
        #expect(rows.count == Self.corpusSize)
        #expect(recipients.count == Self.recipientCount)
        #expect(Set(recipients.compactMap { $0.prospect?.naturalKey }).count == Self.prospectsWithAContact)
        #expect(recipients.filter { $0.sendState == .pending }.count == Self.pendingRecipients)
        #expect(rows.filter { ($0.draftBody ?? "").isEmpty == false }.count == Self.prospectsWithADraftBody)
        // #3506: the INTERSECTION the lint scales with, held here so a seed that drifts back to giving
        // every body-carrying row two pending contacts is caught by the shape test rather than by
        // somebody noticing the pinned lint count looks large.
        let onBodyRows = recipients.filter { ($0.prospect?.draftBody ?? "").isEmpty == false }
        #expect(onBodyRows.count == Self.recipientsOnDraftBodyRows)
        #expect(onBodyRows.filter { $0.sendState == .pending }.count
                    == Self.pendingRecipientsWithADraftBody)

        // #3516: the DATE clustering, which is the dimension the self-booking check scales with. Both
        // numbers, because neither describes the load on its own: the largest cluster bounds the worst
        // single row and the comparison load is what the pass pays (L391).
        var perDate: [String: Int] = [:]
        for row in rows { perDate[row.performanceDate ?? "", default: 0] += 1 }
        #expect(perDate[""] == nil, "a row carries no date, so the clustering below is over the wrong set")
        #expect(perDate.values.max() == Self.largestSingleDateCluster)
        #expect(perDate.values.reduce(0) { $0 + $1 * $1 } == Self.sameNightComparisonLoad)
    }

    // One card per row, and one send-group build per card. These are the two counters #2033 would have
    // moved and the sweep count did not.
    @Test func onePassBuildsOneCardAndOneSendGroupPerRow() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueRenderPass.make(inputs(rows))
        }

        #expect(work.queueItems == Self.allowedQueueItems)
        #expect(work.sendGroupBuilds == Self.allowedSendGroupBuilds)
    }

    // #3516. Read the three numbers together: the pass alone, the screen on a stage that draws the
    // marker, and the screen on Scout.
    //
    // WHAT THE MIRROR IS AND IS NOT. A SwiftUI body cannot be evaluated in a unit test, which is the whole
    // reason `QueueRenderPass` exists, so the three questions the view asks of the night index are asked
    // here in the same order and with the same arguments. That is a second expression of what the view
    // does, and the danger is that it drifts (L263), so `SelfBookingScreenWorkMirrorTests` asserts the
    // view's render path asks exactly these three and no others.
    static func askTheScreensSelfBookingQuestions(_ data: QueueView.RenderData, stage: StageFocus) {
        guard stage != .scout else { return }
        for group in data.dateGroups {
            _ = QueueModel.selfBookingNote(group.items, on: group.id, in: data.selfBooking)
        }
        for item in data.focusedRows {
            _ = QueueModel.selfBookingRowMarker(for: item, in: data.selfBooking)
            _ = QueueModel.selfBookingWorkableNote(for: item, in: data.selfBooking)
        }
    }

    @Test func aRenderPassAsksTheNightIndexNothingAtAll() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueRenderPass.make(inputs(rows))
        }
        #expect(work.selfBookingShowsExamined == Self.allowedSelfBookingShowsExaminedInThePass,
                Comment(rawValue: "the pass examined \(work.selfBookingShowsExamined) shows. It BUILDS "
                        + "the index and asks it nothing; if that has changed, the screen figures below "
                        + "are now double counting."))
    }

    @Test func drawingTheScreenExaminesAPinnedNumberOfShows() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let onReview = QueueRenderPass.WorkTally.measure {
            let data = QueueRenderPass.make(inputs(rows, stage: .review))
            Self.askTheScreensSelfBookingQuestions(data, stage: .review)
        }
        let onScout = QueueRenderPass.WorkTally.measure {
            let data = QueueRenderPass.make(inputs(rows, stage: .scout))
            Self.askTheScreensSelfBookingQuestions(data, stage: .scout)
        }

        #expect(onReview.selfBookingShowsExamined == Self.allowedSelfBookingShowsExaminedOnScreen)
        #expect(onScout.selfBookingShowsExamined == Self.allowedSelfBookingShowsExaminedOnScout)
    }

    // The draft lint, counted where it actually runs. Only a recipient carrying a non-empty body reaches
    // DraftCheck at all, so this number is a fact about the SHAPE rather than about the row count, which
    // is why it is held separately from the two above (#3435 2c).
    @Test func onePassRunsTheDraftLintAPinnedNumberOfTimes() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)

        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueRenderPass.make(inputs(rows))
        }

        #expect(work.draftLintRuns == Self.allowedDraftLintRuns)
    }

    // WHERE the 402 comes from, attributed by measuring each stage in isolation rather than by reading
    // the code and guessing. One prospect, one pending contact, one body: whatever this reports is the
    // per-contact multiplier the whole-pass number is 78 copies of.
    //
    // This is the test that makes the pinned number ARGUABLE instead of mysterious. A future change that
    // moves work between the send-group build and the card build shows up here even if the total holds.
    @Test func theLintMultiplierIsAttributedToItsTwoStages() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "one", groupName: "Ensemble", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-10",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .drafted)
        p.draftBody = "Hello there,\n\nI photograph performances in New York.\n\nBest,\nDan"
        ctx.insert(p)
        let r = Recipient(id: "c1", email: "contact@example.com", name: "Contact",
                          role: "programming", provenance: .presenter)
        r.sendState = SendState.pending
        r.prospect = p
        ctx.insert(r)
        try? ctx.save()

        let groupsOnly = QueueRenderPass.WorkTally.measure { _ = SendGroup.CardGroups(of: p) }
        let wholeCard = QueueRenderPass.WorkTally.measure { _ = QueueItem(p) }

        let inInit = wholeCard.draftLintRuns - groupsOnly.draftLintRuns
        #expect(groupsOnly.draftLintRuns == Self.allowedLintRunsPerContactInSendGroupBuild,
                Comment(rawValue: "the send-group build ran the draft lint \(groupsOnly.draftLintRuns) "
                        + "time(s) for one contact. #2033 put three of these on the card and the sweep "
                        + "count could not see it."))
        #expect(inInit == Self.allowedLintRunsPerContactInCardBuild,
                Comment(rawValue: "building one card ran the draft lint \(inInit) time(s) over one "
                        + "contact's body. Each run is a whole pass of DraftCheck over the letter."))
    }

    // The counters are OFF unless somebody is measuring, so the app pays a nil check per card and nothing
    // else. Asserted rather than reasoned about, because this instrument lives on the exact path the
    // milestone exists to make cheaper (L353).
    @Test func nothingIsCountedWhenNobodyIsMeasuring() throws {
        let ctx = ModelContext(try container())
        let rows = seed(ctx)
        _ = QueueRenderPass.make(inputs(rows))
        #expect(QueueRenderPass.WorkTally.current == nil,
                "a pass run outside `measure` must leave no tally behind")
    }
}
