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
    private static let corpusSize = 1139
    // LIVE-SHAPE: untriaged
    private static let untriaged = 587

    // Eight sweeps of the store, once each, and every one of them named. If this number moves, one of
    // these lines has changed or a new one has appeared, and either is a decision rather than an accident:
    //
    //   1. resolving each show's place for the pass (#1962)
    //   2. building the queue's rows
    //   3. the whole-store corpus those rows are judged against (venue brands, inherited answers)
    //   4. the shows already reached out to
    //   5. which shows are in a stage at all
    //   6. which of those the focused stage renders
    //   7. the agent strip's inputs
    //   8. the possible-match fan-out scan
    private static let allowedSweeps = 8

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
            prospects: QueueRenderPass.Corpus(rows, tally: tally),
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
    private static let corpusSize = 1142
    // LIVE-SHAPE: recipients
    private static let recipientCount = 305
    // LIVE-SHAPE: prospectsWithAContact
    private static let prospectsWithAContact = 198
    // LIVE-SHAPE: pendingRecipients
    private static let pendingRecipients = 279
    // LIVE-SHAPE: prospectsWithADraftBody
    private static let prospectsWithADraftBody = 39

    // One card built per row, and not one more. This is the counter #2033 would have moved.
    private static let allowedQueueItems = 1142

    // One send-group build per card. #2046 collapsed three of these into one; nothing pins that it stays
    // one, which is exactly how #2033 put the cost back without moving a number.
    private static let allowedSendGroupBuilds = 1142

    // How many times the draft lint actually runs over a body during one pass. MEASURED, then pinned,
    // and meant to be argued with rather than updated to whatever the code does.
    //
    // Only a recipient whose `effectiveBody` is non-empty reaches `DraftCheck` at all, because
    // `Recipient.draftLintBlockers` short-circuits on an empty body first, so this is a fact about the
    // SHAPE and not about the row count. It is held separately from the two counters above for that
    // reason (#3435 2c: a superlinear or shape-driven term goes against its own measure, never folded
    // into a per-row figure).
    //
    // 78 pending contacts carry a body in this fixture (the first 39 prospects, two contacts each). At
    // the measured 4 runs per contact that is 312, and the pass really runs it 402 times, so 90 runs
    // happen OUTSIDE card construction, in the other whole-store derivations the pass makes. That gap is
    // not explained here and is not this issue's to close: it is filed, and the number is pinned so it
    // cannot grow while nobody is looking.
    private static let allowedDraftLintRuns = 402

    // The per-contact multiplier, pinned separately so a change that moves work between the send-group
    // build and the card build is visible even when the total holds. Measured, not read off the code.
    private static let allowedLintRunsPerContactInCardBuild = 4
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
        var recipientsMade = 0
        var pendingMade = 0
        for n in 0..<Self.corpusSize {
            let date = String(format: "2026-%02d-%02d", 8 + (n % 4), 1 + (n % 27))
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
        // 305 recipients over 198 prospects: the first few carry two, the rest one, so the per-card work
        // is not uniform. 279 of the 305 are pending, matching the live split.
        var n = 0
        while recipientsMade < Self.recipientCount && n < Self.prospectsWithAContact {
            let howMany = recipientsMade + (Self.prospectsWithAContact - n) < Self.recipientCount ? 2 : 1
            for k in 0..<howMany where recipientsMade < Self.recipientCount {
                let pending = pendingMade < Self.pendingRecipients
                let r = Recipient(id: "contact-\(recipientsMade)",
                                  email: "contact\(recipientsMade)@example.com",
                                  name: "Contact \(recipientsMade)",
                                  role: "programming",
                                  provenance: .presenter)
                r.sendState = pending ? SendState.pending : SendState.sent
                if pending { pendingMade += 1 }
                r.prospect = rows[n]
                ctx.insert(r)
                recipientsMade += 1
                _ = k
            }
            n += 1
        }
        try? ctx.save()
        return rows
    }

    private func inputs(_ rows: [Prospect]) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(
            prospects: QueueRenderPass.Corpus(rows),
            allProspects: QueueRenderPass.Corpus(rows),
            inquiries: [], orgAnswers: [],
            context: .at("2026-08-02", now: Date(timeIntervalSince1970: 1_785_000_000)),
            focusedStage: .scout, focusedKeys: nil)
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
