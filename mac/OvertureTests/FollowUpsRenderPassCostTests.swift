import Testing
import Foundation
import SwiftData

// #3814: what one render pass of the FOLLOW-UPS SHEET is allowed to cost, counted rather than timed.
//
// WHY A COUNT WHEN THIS SURFACE ALREADY HAS A STOPWATCH, which is the premise re-check this issue needed
// and did not have. `FollowUpsCostTests` (#3657, Phase 7 of this same milestone) already times
// `DueWork.rows` against a clone of the live store, with a quiet arm and a busy arm and a positive
// control. So #3814's line about these seven surfaces having "no counter of any kind" is not true of this
// one, and the gap is narrower and different: that reading is opt-in, it cannot ride the push gate
// because a timing assertion on a shared Mac measures what else the machine is running (L224), and it
// prices ONE function rather than the pass. A count can ride every push, so a sweep added to this surface
// next month goes red on the push that adds it rather than waiting for Dan to notice the sheet has gone
// slow.
//
// WHAT THE COUNT COVERS THAT THE STOPWATCH CANNOT. The stopwatch measures `DueWork.rows`, which was
// already a pure function in Domain. What nothing measured is everything ELSE one evaluation of this
// sheet ran: the store read itself, the watchlist index, and the second clock, all of them inside a
// `@ViewBuilder` where no test can reach them and no counter can see them. That is the half #3814 is
// actually about, in its own words: a surface can be counted and still sweep the store four times per
// pass with nothing saying so.
//
// PINNED DELIBERATELY, and meant to be argued with rather than updated to whatever the code does. Raising
// this number is a decision about how much opening this sheet is allowed to cost.
@MainActor
@Suite("One render pass of the Follow-ups sheet costs a pinned number of sweeps (#3814)")
struct FollowUpsRenderPassCostTests {
    // The live store, measured 2026-09-11 on the same read the drift check takes: 1,238 prospects and 73
    // watched sources. Both carry a LIVE-SHAPE tag, so scripts/check-fixture-corpus-drift.sh names
    // whichever has fallen behind on every push instead of this fixture quietly exercising a smaller
    // world than the one that ships (L354).
    // LIVE-SHAPE: prospects
    static let corpusSize = 1238
    // LIVE-SHAPE: sources
    static let sourceCount = 73

    // ONE sweep of the store per pass, and it is one rather than four for a reason worth stating where
    // the number is (L11). `DueWork.rows` runs four rules, but it runs them over the array this single
    // read returns, in memory. Counting those four as four sweeps would make this sheet read as four
    // times more expensive than the queue for doing something cheaper. What prices them is the pass
    // duration the view records beside this count (#3815) and `FollowUpsCostTests`'s live-store reading.
    //
    // If this number moves, either the pass has grown a second store read or `DueWork` has been given a
    // corpus of its own, and both are decisions rather than accidents.
    static let allowedSweeps = 1

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The instant every reading here is taken at. Fixed, so nothing below moves with the calendar, and
    // every dated value in the fixture is DERIVED from it rather than written out, because a fixture
    // whose meaning is its relationship to a clock has to pin both ends (L130).
    private static let now = Date(timeIntervalSince1970: 1_785_000_000)

    // A corpus at the live store's shape in which the silent-follow-up rule really FIRES.
    //
    // THE PITCHED MINORITY IS LOAD BEARING. `FollowUp.dueRecipients` calls `SendGroup.oneRowPerGroup`
    // only on the contacts that are actually due, so a corpus where nothing is due hands it an empty
    // array every time and measures the SHORT CIRCUIT rather than the pass (L101, L102).
    // `FollowUpsCostTests` records exactly this trap on the live store, where nothing is currently due.
    // Here roughly one row in four carries a contact pitched well past the nudge gap and never chased.
    private func seed(_ ctx: ModelContext) -> (prospects: [Prospect], sources: [WatchedSource]) {
        let venues = ["Weill Recital Hall", "SoHo Playhouse", "The Green Room 42", "Merkin Hall",
                      "Roulette Intermedium", "The Tank", "Bargemusic", "54 Below"]
        var rows: [Prospect] = []
        for n in 0..<Self.corpusSize {
            // Ahead of the pinned `now`, which is what `FollowUp.hasPerformed` requires of a show still
            // waiting on a nudge. A date behind it would put every row in the post-event rule instead and
            // leave the silent one measuring nothing (L165).
            let performance = EasternDate.today(Self.now.addingTimeInterval(60 * 60 * 24 * Double(30 + n % 60)))
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: venues[n % venues.count], performanceDate: performance,
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: n % 4 == 0 ? .contacted : .new)
            p.location = "New York, NY"
            p.sourceIds = ["src-\(n % Self.sourceCount)"]
            if n % 4 == 0 {
                // Every clause `FollowUp.isAwaitingNudge` and `Recipient.isAwaitingFollowUp` ask, set
                // explicitly rather than inherited from a default, so this fixture cannot go quiet
                // because a default moved. Copied in shape from `FollowUpsCostTests`'s own control.
                let r = Recipient(id: "contact-\(n)@example.invalid", email: "contact-\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = .sent
                r.outreachChannel = .email
                r.replied = false
                r.bounced = false
                r.sentAt = Self.now.addingTimeInterval(-60 * 60 * 24 * 30)
                p.recipients.append(r)
            }
            ctx.insert(p)
            rows.append(p)
        }
        var sources: [WatchedSource] = []
        for n in 0..<Self.sourceCount {
            let s = WatchedSource(sourceId: "src-\(n)", orgName: "Org \(n)",
                                  listingsURL: "https://org\(n).example/events", kind: .html)
            ctx.insert(s)
            sources.append(s)
        }
        try? ctx.save()
        return (rows, sources)
    }

    private func inputs(_ seeded: (prospects: [Prospect], sources: [WatchedSource]),
                        tally: FollowUpsRenderPass.CostTally? = nil)
        -> FollowUpsRenderPass.Inputs {
        FollowUpsRenderPass.Inputs(
            prospects: FollowUpsRenderPass.Corpus(seeded.prospects, tally: tally),
            inquiries: [],
            sources: seeded.sources,
            now: Self.now,
            replyRunAlive: false)
    }

    // THE MEASUREMENT. One pass over a realistic store reads it a pinned number of times.
    @Test func onePassSweepsTheStoreAPinnedNumberOfTimes() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        let tally = FollowUpsRenderPass.CostTally()

        let data = FollowUpsRenderPass.make(inputs(seeded, tally: tally))

        #expect(tally.sweeps == Self.allowedSweeps)
        // And it really did derive something, so the count above is not the cost of doing nothing. A
        // sweep count taken over a pass that returned an empty sheet would be the same number and would
        // mean nothing at all (L171, L90).
        #expect(!data.rows.silent.isEmpty, """
        the fixture produced no silent follow-ups, so this pass took the short circuit and the count \
        above is a reading of the branch that does nothing
        """)
        #expect(!data.sourceCalendars.isEmpty, "the watchlist index came back empty, so half the pass was inert")
    }

    // A sheet with nothing to draw indexes nothing.
    //
    // The body renders one sentence and no rows when nothing is due, so the index it would thread into
    // those rows must not be built. Not an optimisation: a pass that indexed the watchlist to draw one
    // sentence would be a cost nobody could see from the screen.
    @Test func aPassWithNothingDueDoesNotIndexTheWatchlist() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)
        // Nothing pitched, so no rule can produce a row. The watchlist is untouched and still full, which
        // is what makes the empty index below a decision of the pass rather than a property of the input.
        for p in seeded.prospects { p.recipients.removeAll() }
        let tally = FollowUpsRenderPass.CostTally()

        let data = FollowUpsRenderPass.make(inputs(seeded, tally: tally))

        // Bound to Bools before asserting, deliberately: a failing `#expect` renders its own operands,
        // and comparing the dictionary directly printed all 73 entries over the sentence saying what went
        // wrong (L445). Seen while proving this guard fails.
        let nothingDue = data.rows.isEmpty
        let indexedNothing = data.sourceCalendars.isEmpty
        #expect(nothingDue, "the fixture still had work due, so this is not the empty case at all")
        #expect(indexedNothing, "an empty sheet still indexed the whole watchlist")
        // Still ONE read, because the pass has to look at the store to find out it is empty. Stated so
        // that a later reading of zero here is recognised as the pass not running rather than as a
        // saving (L98).
        #expect(tally.sweeps == Self.allowedSweeps, "an empty sheet no longer reads the store at all")
        #expect(!seeded.sources.isEmpty, "the watchlist was empty, so the index above proves nothing")
    }

    // THE EQUIVALENCE. The lifted pass answers exactly what the body's own derivation answered.
    //
    // Without this, the pass could quietly change WHICH rows the sheet lists while every count above
    // stayed green, and a wrong list on this surface is a follow-up Dan never sends rather than a
    // millisecond (L1, and the three-arm matrix #3659 describes for the queue).
    @Test func theLiftedPassAnswersWhatTheInlineDerivationDid() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)

        let lifted = FollowUpsRenderPass.make(inputs(seeded)).rows
        // The derivation the body ran before the lift, spelled out here rather than called through the
        // pass, so this compares two things rather than one thing with itself (L70).
        let inline = DueWork.rows(prospects: seeded.prospects, inquiries: [], now: Self.now, replyRunAlive: false)

        #expect(lifted.rendered == inline.rendered)
        #expect(lifted.counts == inline.counts)
        // Field for field on the identities, not only on the counts: two lists of the same length can
        // hold different rows, and which contact is listed is the whole product question here.
        #expect(lifted.silent.map(\.recipient.id) == inline.silent.map(\.recipient.id))
        #expect(lifted.afterTheShow.map(\.recipient.id) == inline.afterTheShow.map(\.recipient.id))
        #expect(lifted.stalledReplyDrafts.map(\.recipient.id) == inline.stalledReplyDrafts.map(\.recipient.id))
        #expect(lifted.conversationsToConfirm.map(\.recipient.id)
                == inline.conversationsToConfirm.map(\.recipient.id))
        #expect(inline.rendered > 0, "both arms returned nothing, so they agree about nothing (L159)")
    }

    // ONE instant for the whole drawing, which this sheet did not have.
    //
    // `rows` read `Date()` and the scroll holder eight lines below read a second `Date()`, so a row's
    // sentence and the rule that put the row there were dated a moment apart. The comment on the second
    // one stated the rule it was breaking (#2919). The pass now carries the instant it judged at.
    @Test func theRowsAndTheirSentencesAreDatedFromOneInstant() throws {
        let ctx = ModelContext(try container())
        let seeded = seed(ctx)

        let data = FollowUpsRenderPass.make(inputs(seeded))

        #expect(data.now == Self.now, """
        the pass carried an instant other than the one it was given, so the rows and the sentences \
        drawn beside them can be dated apart again
        """)
    }
}

// The pass reaches nothing but the values it is handed. Its own file, on `SourcesRenderPassIsPureTests`'s
// precedent, because these are source-text guards rather than measurements.
@Suite("The Follow-ups render pass is a pure derivation (#3814)")
struct FollowUpsRenderPassIsPureTests {
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/FollowUpsRenderPass.swift") }

    @Test func thePassNeverTouchesTheFilesystem() {
        #expect(!renderPass.isEmpty)
        // `ReplyClassifyService.isRunning` is the one that matters here and the reason the pass takes
        // `replyRunAlive` as a value: it is a marker file read, and this sheet's own body used to take it
        // on every evaluation (#3852 is the class).
        for reader in ["ReplyClassifyService.isRunning", "PrepQueueService", "DetachedRunner",
                       "GmailConnection", "FileManager", "Data(contentsOf:"] {
            #expect(!renderPass.contains(reader),
                    "\(reader) is a filesystem read, and this runs on every render pass")
        }
    }

    // The counting is not optional. If the rows could be reached around the corpus, a new sweep would be
    // invisible to the measurement above and the guard would quietly stop guarding.
    @Test func theRowsCanOnlyBeReachedThroughTheCountedAccessor() {
        #expect(renderPass.contains("typealias Corpus = QueueRenderPass.Corpus"),
                "the pass no longer takes its rows through the counted corpus")
    }
}
