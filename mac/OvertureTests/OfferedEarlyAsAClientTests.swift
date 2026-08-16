import Testing
import Foundation
import SwiftData

// #2524: a DCINY or TENET date ten months out sits in Scout beside next week's shows, and nothing on the
// card says why.
//
// Since #2365 a returning client's show is offered for triage up to 11 months ahead while everybody else
// is held to 90 days. That is deliberate and it is what Dan asked for, but from the card it is invisible:
// the row reads as a mistake rather than a reach, and it hides the one fact that makes it worth acting on,
// which is that he has worked with these people before.
//
// The rule this asserts is deliberately the SAME predicate the stage applies, not a second one shaped to
// agree with it (L16). `theSentenceAndTheStageCannotDisagree` is the test that holds that true.
@MainActor
@Suite("Why a far-out show is in Scout early (#2524)")
struct OfferedEarlyAsAClientTests {

    // Both ends pinned. A fixture whose meaning is the RELATIVE distance between a date and the clock
    // silently changes which case it stands for as real time walks past it (L130), and every date here
    // means something only against `today`.
    private let today = "2026-08-16"
    private let nextWeek = "2026-08-23"          // well inside the ordinary 90 days
    private let justInside = "2026-11-13"        // 89 days: the last ordinary day
    private let justPast = "2026-11-15"          // 91 days: the first day only a client reaches
    private let tenMonthsOut = "2027-06-13"      // the furthest show the live store held, 2026-08-11
    private let pastTheClientEdge = "2027-08-20" // past 11 months: nothing reaches this

    // MARK: the sentence itself

    @Test("a returning client's show past the ordinary window says why it is here early")
    func theFarOutClientShowSaysIt() {
        #expect(QueueModel.isOfferedEarlyAsAClient(performanceDate: tenMonthsOut,
                                                   isPastClient: true, today: today))
    }

    // The branch that must stay silent, and the one #1547 is about: most cards are this, and a line on
    // every one of them is noise that teaches Dan to stop reading the row.
    @Test("a stranger's show never says it, at any distance")
    func aStrangerNeverSaysIt() {
        for date in [nextWeek, justInside, justPast, tenMonthsOut, pastTheClientEdge] {
            #expect(!QueueModel.isOfferedEarlyAsAClient(performanceDate: date,
                                                        isPastClient: false, today: today),
                    "said it about a stranger's show on \(date)")
        }
    }

    // The half that keeps it from appearing on nearly every client card. A client's show next week is in
    // Scout for the ordinary reason, so a line claiming the client rule is what put it there would be
    // saying something untrue about it.
    @Test("a returning client's show inside the ordinary window says nothing")
    func aNearClientShowSaysNothing() {
        #expect(!QueueModel.isOfferedEarlyAsAClient(performanceDate: nextWeek,
                                                    isPastClient: true, today: today))
        #expect(!QueueModel.isOfferedEarlyAsAClient(performanceDate: justInside,
                                                    isPastClient: true, today: today),
                "the last ordinary day is ordinary")
    }

    @Test("the day after the ordinary edge is where it starts")
    func itStartsAtTheEdge() {
        #expect(QueueModel.isOfferedEarlyAsAClient(performanceDate: justPast,
                                                   isPastClient: true, today: today))
    }

    // Past the client window nothing is offered at all, so there is no row to explain. Asserted because a
    // predicate that only checked "past 90 days and a client" would say it about a show Scout is not
    // holding, which is a sentence about a card that does not exist.
    @Test("a show past the client window says nothing either, because it is not here")
    func pastTheClientEdgeSaysNothing() {
        #expect(!QueueModel.isOfferedEarlyAsAClient(performanceDate: pastTheClientEdge,
                                                    isPastClient: true, today: today))
    }

    // An undated show is IN the ordinary window by the standing rule (#861), so nothing about its date is
    // unusual and there is nothing to explain.
    @Test("an undated show says nothing")
    func anUndatedShowSaysNothing() {
        #expect(!QueueModel.isOfferedEarlyAsAClient(performanceDate: nil, isPastClient: true, today: today))
        #expect(QueueModel.isWithinOrdinaryLeadTime(performanceDate: nil, today: today))
    }

    // MARK: the sentence and the stage are one predicate

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String, on sourceId: String, date: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Merkin Hall", performanceDate: date, sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.sourceIds = [sourceId]
        ctx.insert(p)
        return p
    }

    private func source(_ ctx: ModelContext, id: String, tag: Bool?) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Nothing Like A Client Name",
                              listingsURL: "https://\(id).example", kind: .html)
        s.clientTagOverride = tag
        ctx.insert(s)
        return s
    }

    // The claim the whole design rests on: the card may say "here early" about EXACTLY the rows the far
    // arm of the stage rule kept, and about no others. Written as a comparison of two sets over the same
    // shows rather than as two spot checks, so a change to either side that separates them fails here
    // rather than shipping a card explaining a row that is not there, or a row with nothing said about it.
    @Test("the sentence appears on exactly the rows the client reach is what keeps")
    func theSentenceAndTheStageCannotDisagree() throws {
        let ctx = ModelContext(try container())
        let tagged = source(ctx, id: "tagged", tag: true)
        let untagged = source(ctx, id: "untagged", tag: nil)

        var shows: [Prospect] = []
        for date in [nextWeek, justInside, justPast, tenMonthsOut, pastTheClientEdge] {
            shows.append(show(ctx, key: "client-\(date)", on: "tagged", date: date))
            shows.append(show(ctx, key: "stranger-\(date)", on: "untagged", date: date))
        }
        shows.append(show(ctx, key: "client-undated", on: "tagged", date: ""))

        let context = StageContext(geo: .none,
                                   clients: ClientWindow(sources: [tagged, untagged], clients: []),
                                   today: today)
        let saying = Set(QueueModel.items(from: shows, clients: context.clients, today: today)
            .filter { $0.offeredEarlyAsAClient }.map { $0.id })

        // Every show the ordinary window would have dropped, that Scout is nevertheless holding. Derived
        // from StageNavigation itself, so this is the stage's own answer rather than a restatement of it.
        let inScout = Set(StageNavigation.naturalKeys(for: .scout, in: shows, context: context))
        let keptOnlyByTheClientReach = Set(shows
            .filter { inScout.contains($0.naturalKey) }
            .filter { !QueueModel.isWithinOrdinaryLeadTime(performanceDate: $0.performanceDate, today: today) }
            .map(\.naturalKey))

        #expect(!saying.isEmpty, "nothing said it at all, so this proves nothing (L98)")
        #expect(saying == keptOnlyByTheClientReach, """
            The card's sentence and the stage rule disagree.
            saying it: \(saying.sorted())
            kept only by the client reach: \(keptOnlyByTheClientReach.sorted())
            """)

        // And the untagged half is genuinely in the fixture, so the equality above is not two empty
        // halves agreeing (L104): a stranger's far-out show must be absent from BOTH sets.
        #expect(!inScout.contains("stranger-\(tenMonthsOut)"))
        #expect(!saying.contains("stranger-\(tenMonthsOut)"))
        #expect(inScout.contains("stranger-\(nextWeek)"), "a stranger's near show is ordinary Scout work")
        #expect(!saying.contains("stranger-\(nextWeek)"))
    }

    // MARK: which list says it

    // Dan's call, 2026-08-16. The far reach is applied to Scout and to no other stage, so once he keeps a
    // far-out client's show it is his own decision holding it on screen, not the client rule, and a card
    // still explaining the client rule there is explaining the wrong thing.
    @Test("only the untriaged list says it")
    func onlyScoutSaysIt() throws {
        let ctx = ModelContext(try container())
        let tagged = source(ctx, id: "tagged", tag: true)
        let far = show(ctx, key: "far", on: "tagged", date: tenMonthsOut)
        let row = try #require(QueueModel.items(from: [far],
                                                clients: ClientWindow(sources: [tagged], clients: []),
                                                today: today).first)
        #expect(row.offeredEarlyAsAClient, "the row's own verdict is unchanged; only the saying is scoped")

        #expect(QueueModel.saysOfferedEarlyAsAClient(row, stage: .scout))

        // Every other stage, derived from the type rather than from the ones somebody remembered, so a
        // stage added later cannot quietly start saying it (L96, L113).
        for stage in StageFocus.allCases where stage != .scout {
            #expect(!QueueModel.saysOfferedEarlyAsAClient(row, stage: stage),
                    "\(stage) explains the client rule, but the client rule is not what keeps a row there")
        }
        #expect(!QueueModel.saysOfferedEarlyAsAClient(row, stage: nil))
    }

    // And Scout does not say it about an ordinary row, so the assertion above is the stage test doing its
    // job rather than the row verdict being ignored (L104).
    @Test("the untriaged list still stays silent about an ordinary row")
    func scoutIsStillSilentAboutAnOrdinaryRow() throws {
        let ctx = ModelContext(try container())
        let tagged = source(ctx, id: "tagged", tag: true)
        let near = show(ctx, key: "near", on: "tagged", date: nextWeek)
        let row = try #require(QueueModel.items(from: [near],
                                                clients: ClientWindow(sources: [tagged], clients: []),
                                                today: today).first)
        #expect(!QueueModel.saysOfferedEarlyAsAClient(row, stage: .scout))
    }

    // MARK: what it says, and where

    @Test("the line explains the date and quotes no arithmetic")
    func theLineExplainsTheDate() {
        let line = QueueModel.offeredEarlyAsAClientLine
        #expect(line.contains("further ahead"))
        #expect(!line.contains("11"), "a card must not quote the window's arithmetic at Dan")
        #expect(!line.contains("90"))
    }

    // The cold read's own finding, kept as a test because it is invisible from inside either file. The
    // card carries `historyFlag`'s pill on a booked row, and the first wording of the line above said the
    // same thing one line under it (#843). Compared against the pill's real text rather than a copy of
    // it, so rewording either side is what has to be reconciled, not this assertion.
    @Test("the line does not repeat the pill already on the card")
    func itDoesNotRepeatTheHistoryPill() throws {
        let booked = item(priorRelationship: "booked")
        let pill = try #require(QueueModel.historyFlag(booked))
        #expect(pill == "Worked together before", "the pill moved; re-read the pair (L118)")

        // Neither claims what the other claims. The pill says he knows these people, which it has
        // established; the line says why the date is here, which the pill does not cover.
        #expect(!QueueModel.offeredEarlyAsAClientLine.contains("Worked together"))
        #expect(!QueueModel.offeredEarlyAsAClientLine.lowercased().contains("worked with"))
    }

    // And the claim the reworded line no longer makes. A show on a returning client's calendar is offered
    // early, and the act performing that night is routinely a stranger, so a sentence about who Dan has
    // worked with would be true of the calendar and false of the card it sits on (L11).
    @Test("a show early only because of its source says nothing about knowing the act")
    func theSourceArmClaimsNoRelationship() throws {
        let ctx = ModelContext(try container())
        let tagged = source(ctx, id: "tagged", tag: true)
        let stranger = show(ctx, key: "stranger-on-a-client-calendar", on: "tagged", date: tenMonthsOut)

        let context = StageContext(geo: .none, clients: ClientWindow(sources: [tagged], clients: []),
                                   today: today)
        #expect(QueueModel.items(from: [stranger], clients: context.clients, today: today)
            .allSatisfy { $0.offeredEarlyAsAClient }, "the fixture no longer reaches the arm this is about")

        // Nothing has established a relationship with this act: no booking, no matched client.
        #expect(stranger.priorRelationship == "none")
        #expect(stranger.matchedClientName == nil)
        #expect(QueueModel.historyFlag(item(priorRelationship: "none")) == nil,
                "the card says nothing about history here, and the line must not either")
    }

    // Archive builds its rows with no client window at all, and must stay silent: a line about a show
    // being offered EARLY has nothing to explain about one that already happened. Asserted rather than
    // assumed, because the default is what makes it true and a default is exactly what nobody re-reads.
    @Test("a caller with no client window says nothing about any row")
    func noClientWindowSaysNothing() throws {
        let ctx = ModelContext(try container())
        let tagged = source(ctx, id: "tagged", tag: true)
        let far = show(ctx, key: "far", on: "tagged", date: tenMonthsOut)

        #expect(QueueModel.items(from: [far], clients: .none, today: today)
            .allSatisfy { !$0.offeredEarlyAsAClient })

        // And the same row WITH the window does say it, so the line above is the default doing its job
        // rather than the whole feature being dead (L1).
        #expect(QueueModel.items(from: [far], clients: ClientWindow(sources: [tagged], clients: []),
                                 today: today).allSatisfy { $0.offeredEarlyAsAClient })
    }

    private func item(priorRelationship: String) -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Merkin Hall",
                  performanceDate: tenMonthsOut, sourceListingURL: nil, websiteURL: nil,
                  priorRelationship: priorRelationship, production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    // The row draws it, and draws it only when told to. A predicate nothing renders is a field with no
    // reader (L46), and the default-off half is what keeps Archive and every other surface silent.
    @Test("the row renders the line only when the flag is set")
    func theRowDrawsIt() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        let note = try #require(SourceGuardHelper.propertyBody("private var offeredEarlyNote: some View {",
                                                              in: source))
        #expect(SourceGuardHelper.containsCode("if offeredEarlyAsAClient {", in: note),
                "the note draws unconditionally, so every card would carry it")
        #expect(SourceGuardHelper.containsCode("QueueModel.offeredEarlyAsAClientLine", in: note))
        #expect(SourceGuardHelper.containsCode("var offeredEarlyAsAClient: Bool = false", in: source),
                "defaulting to true would put the line on Archive and every other caller")
    }

    // And the queue actually hands it in. The predicate, the flag and the note above are each proven, and
    // a wire between them that nobody connected would leave all three green with the line never drawn
    // (L3). Scoped to `prospectRow`'s own body rather than searched over QueueView.swift, which is 1400
    // lines and would answer this from anywhere in itself (L135).
    @Test("the queue's own row hands the verdict to the card")
    func theQueueRowPassesIt() throws {
        let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let row = try #require(SourceGuardHelper.bodyOfFunction(named: "prospectRow", in: queueView))

        // Two needles rather than one spanning the wrap. `containsCode` collapses runs of whitespace to a
        // single space, so it can see past a line break but not past the space the break leaves behind.
        #expect(SourceGuardHelper.containsCode(
            "offeredEarlyAsAClient: QueueModel.saysOfferedEarlyAsAClient(", in: row),
                "the card can never say it, whatever the predicate decides")
        #expect(SourceGuardHelper.containsCode("item, stage: focusedStage)", in: row),
                "it is handed the row and this list, which is the whole of what it decides on")

        // Through the function, never as a stage test written into the body: a membership rule stated in
        // a SwiftUI body is one no test can reach (#863).
        #expect(!SourceGuardHelper.containsCode("stage == .scout", in: row))

        // Read off the row, never re-derived here: deciding it per card needs the watched sources and
        // the client roster, which is the whole-store-per-card shape that froze a sheet in #1429 (L91),
        // and asking it as its own pass is the ninth sweep QueueRenderPassCostTests refused.
        #expect(!SourceGuardHelper.containsCode("isOfferedEarlyAsAClient(", in: row))
    }
}
