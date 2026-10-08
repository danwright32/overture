import Testing
import Foundation
import SwiftData

// #4357 slice I3 (plan v7 Phase 3, step 6): a total order on every tie in the queue's render pass.
//
// WHY. Every input the pass is handed arrives in an order nobody declared: the whole store comes from an
// unsorted `@Query`, so do the inquiries, the organisation answers and the watched sources, and a show's
// contacts are a relationship SwiftData hands back in whatever order it likes (L343). A term that breaks a
// tie by the order its input arrived in gives a different answer for the same data, which Dan sees as rows
// swapping places between launches, and which the Phase 4 verifier would report as a mismatch between a
// published pass and a rebuild of the same store.
//
// WHAT THIS RUNS. One corpus, built so that every term whose input the shuffle reaches holds a tie, run
// through the whole pass 20 times under seeded permutations of every unordered input, each output compared
// member by member with the slice I1 comparator (`RenderDataComparison.differingFields`). The seed is fixed
// and named in every failure, so a red run reproduces exactly (L339).
//
// ONE TIE IS HELD, AND IT IS NAMED. `QueueModel.queueScope` breaks a full tie on its own two keys by input
// position on purpose, to reproduce RootView's `@Query`, and `QueueScopeMatchesTheQueryTests` defends that
// until the query is deleted. Plan v7 reserves its natural key tie break for the Phase 4 plus 5 cutover
// (decision 13(i)), and says the canonical wrapper stands in for it in tests until then (section 6). So the
// rows that tie on both of its keys keep natural key order among the positions they were shuffled into,
// and every other relative order is free. `theScopesOwnTieStillNeedsTheHold` is the premise, and the
// cutover consumes it (L373).
//
// WHAT THIS CANNOT SEE, said so nobody reads more into it. With the scope's own order held, the terms that
// run over the scope's rows (the stage placement, Reached out, the engagement link, the order within a
// night) are handed one order on every permutation, so their tie breaks are guarded by their own
// permutation tests rather than by this one: `OrderDependenceReproductionTests` for the plan's Step T
// terms, and the per-term tests below and in `QueueTiebreakTests` for the ones this slice made total.
//
// Every name and address is invented, on example.org (L155, L222). The clock is pinned at both ends (L130).
@MainActor
@Suite("The render pass is one answer whatever order its inputs arrive in (#4357, slice I3)")
final class RenderPassTotalOrderTests {
    private let container: ModelContainer
    private let context: ModelContext

    // 2027-01-15 12:00 UTC, which is 2027-01-15 in Eastern time.
    private let now = Date(timeIntervalSince1970: 1_800_014_400)
    private let asOf = "2027-01-15"
    private let seed: UInt64 = 4357_06
    private let permutationCount = 20

    init() throws {
        container = try TestModelContainer.inMemory(AppSchema.models)
        context = ModelContext(container)
    }

    // MARK: the corpus

    private struct Corpus {
        var shows: [Prospect]
        var inquiries: [Inquiry]
        var answers: [OrgReachabilityAnswer]
        var sources: [WatchedSource]
    }

    private var day: TimeInterval { 86_400 }

    @discardableResult
    private func show(_ key: String, _ title: String, at venue: String?, on date: String?, fit: Int = 5,
                      status: ReviewStatus = .new, runEnd: String? = nil, nights: [String]? = nil,
                      into shows: inout [Prospect]) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "choral", venue: venue,
                         performanceDate: date, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: fit,
                         tier: "mid", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status, ingestedAt: now, runEndDate: runEnd,
                         partOfRelatedRun: runEnd != nil, runSourceURLs: [],
                         runNights: nights ?? date.map { [$0] } ?? [])
        context.insert(p)
        shows.append(p)
        return p
    }

    private func contact(_ address: String, name: String) -> Recipient {
        Recipient(id: address, email: address, name: name, provenance: .act)
    }

    private func inquiry(_ event: String, from name: String, on date: String?, sentAt: Date? = nil,
                         into inquiries: inout [Inquiry]) {
        let i = Inquiry(source: .directEmail, inquirerName: name, inquirerEmail: nil, eventName: event,
                        performanceDate: date, createdAt: now.addingTimeInterval(-5 * day))
        if let sentAt {
            i.sentAt = sentAt
            i.gmailMessageId = "msg-\(name)"
        }
        context.insert(i)
        inquiries.append(i)
    }

    // Each block plants the tie one term breaks, and the positive control below asserts it is there.
    private func plantedCorpus() throws -> Corpus {
        var shows: [Prospect] = []

        // queueScope: three shows on one night at one fit, and two undated at one fit. The held tie.
        show("tie lantern", "Lantern Revue", at: "Harbor Hall", on: "2027-03-10", fit: 6, into: &shows)
        show("tie glass", "Glass Lantern", at: "harbor hall", on: "2027-03-10", fit: 6, into: &shows)
        show("tie cedar", "Cedar Strings", at: "Quarry Hall", on: "2027-03-10", fit: 6, into: &shows)
        show("undated harbor", "Harbor Lights", at: "Harbor Hall", on: nil, fit: 4, into: &shows)
        show("undated cedar", "Cedar Trio", at: "Willow Barn", on: nil, fit: 4, into: &shows)
        // A dismissed show beside them, which only the whole-store terms see.
        show("dismissed harbor", "Harbor Lights", at: "Harbor Hall", on: "2027-03-10", fit: 6,
             status: .dismissed, into: &shows)

        // laterLookalikes: three rows that arrived looking like "tie glass", two never stamped with a first
        // sighting, so the newest-first order ties between them (#4349).
        let lookalikes: [(String, String, String, String, Date?)] = [
            ("look b", "Glass Lantern Encore", "Quarry Hall", "2027-03-20", nil),
            ("look a", "Glass Lantern Matinee", "Willow Barn", "2027-03-21", nil),
            ("look c", "Glass Lantern Late", "Harbor Hall", "2027-03-22", now.addingTimeInterval(-day)),
        ]
        for (key, title, venue, date, seen) in lookalikes {
            let p = show(key, title, at: venue, on: date, into: &shows)
            p.arrivedLookingLike = "tie glass"
            p.firstSeenAt = seen
        }

        // ShowLink: three rows of one production in one room on intersecting nights, so the whole-store
        // group and its collapse have a cluster to order.
        show("salt a", "Saltmarsh Suite", at: "Quillon Room", on: "2027-02-04", runEnd: "2027-02-06",
             nights: ["2027-02-04", "2027-02-05", "2027-02-06"], into: &shows)
        show("salt b", "Saltmarsh Suite", at: "Quillon Room", on: "2027-02-05", into: &shows)
        show("salt c", "Saltmarsh Suite", at: "Quillon Room", on: "2027-02-06", into: &shows)
            .missedScoutCount = 1

        // FeedBreakEvent: two breaks of three in one room, spelled three ways, on two miss counts, so the
        // events tie on size and room and the label ties on spelling (#4348). One flagged row has a live
        // twin, which ContradictedCancellation finds.
        let flagged = [("cinder 3 x", "Ninefold Quartet", "Cinder Hall", "2027-02-10", 3),
                       ("cinder 3 y", "Copper Moth Revue", "CINDER HALL", "2027-02-11", 3),
                       ("cinder 3 z", "Lantern Parade", "cinder hall", "2027-02-12", 3),
                       ("cinder 2 p", "Driftwood Choir", "Cinder Hall", "2027-02-13", 2),
                       ("cinder 2 q", "Ember Consort", "Cinder Hall", "2027-02-14", 2),
                       ("cinder 2 r", "Pewter Band", "Cinder Hall", "2027-02-15", 2)]
        for (key, title, venue, date, missed) in flagged {
            show(key, title, at: venue, on: date, into: &shows).missedScoutCount = missed
        }
        show("cinder live", "Ninefold Quartet", at: "Cinder Hall", on: "2027-02-10", runEnd: "2027-02-12",
             into: &shows)

        // The rows a merge kept that the next sweep did not list (#3596), in no particular key order.
        for (key, title, venue, date) in [("survivor b", "Quill Ensemble", "Willow Barn", "2027-02-20"),
                                          ("survivor a", "Birch Quartet", "Quarry Hall", "2027-02-21"),
                                          ("survivor c", "Moss Choir", "Harbor Hall", "2027-02-22")] {
            show(key, title, at: venue, on: date, into: &shows).mergeSurvivorUnseenAt = now.addingTimeInterval(-2 * day)
        }

        // PossibleMatchFanOut: two records each flagged across three acts, so the findings tie on count.
        for key in ["tie lantern", "tie glass", "tie cedar"] {
            shows.first { $0.naturalKey == key }?.possibleMatchName = "Aurora Quartet"
        }
        for key in ["survivor a", "survivor b", "survivor c"] {
            shows.first { $0.naturalKey == key }?.possibleMatchName = "Birch Ensemble"
        }

        // Reached out: shows pitched at one instant, so their dates tie across shows, and contacts that tie
        // inside one show on the representative's keys (#4345), which only the relationship order can move.
        let pitchedAt = now.addingTimeInterval(-10 * day)
        let pair = show("pitched pair", "Rowan Consort", at: "Harbor Hall", on: "2027-02-25", into: &shows)
        pair.setRecipients([contact("rowan@example.org", name: "Rowan Vale"),
                            contact("hazel@example.org", name: "Hazel Vale")])
        let shared = show("pitched shared", "Shared Line Choir", at: "Quarry Hall", on: "2027-02-26", into: &shows)
        shared.setRecipients([contact("shared@example.org", name: "First Desk"),
                              contact("shared@example.org", name: "Second Desk")])
        let replied = show("pitched replied", "Answer Ensemble", at: "Willow Barn", on: "2027-02-27", into: &shows)
        replied.setRecipients([contact("yarrow@example.org", name: "Yarrow Penn"),
                               contact("alder@example.org", name: "Alder Penn")])
        let single = show("pitched single", "Lone Voice", at: "Quillon Room", on: "2027-02-25", into: &shows)
        single.setRecipients([contact("lone@example.org", name: "Lone Voice")])
        for p in [pair, shared, replied, single] {
            DebugStaging.stageAsSent(p, now: pitchedAt)
        }
        for r in replied.recipients {
            r.replied = true
            r.repliedAt = pitchedAt.addingTimeInterval(day)
            r.inboundReplySentAt = pitchedAt.addingTimeInterval(day)
        }

        // The ledger: one organisation playing two rooms, and one spelled two ways that fold to one
        // organisation and to two producer keys (#4351): the plain spelling plays two rooms and qualifies,
        // the entity spelling plays one and does not, so a verdict remembered per organisation would hand
        // both whichever spelling the loop met first.
        var answers: [OrgReachabilityAnswer] = []
        let presenters = [("north a", "Winter Lights", "Harbor Hall", "2027-03-01", "Northwind Players"),
                          ("north b", "Spring Lights", "Quarry Hall", "2027-03-02", "Northwind Players"),
                          ("pair a", "Comic Revue", "Willow Barn", "2027-03-03", "Tom &amp; Jerry Ensemble"),
                          ("pair b", "Comic Revue Two", "Quillon Room", "2027-03-04", "Tom & Jerry Ensemble"),
                          ("pair c", "Comic Revue Three", "Cinder Hall", "2027-03-05", "Tom & Jerry Ensemble")]
        for (key, title, venue, date, presenter) in presenters {
            show(key, title, at: venue, on: date, into: &shows).presenter = presenter
        }
        for (presenter, address) in [("Northwind Players", "booking@example.org"),
                                     ("Tom & Jerry Ensemble", "office@example.org")] {
            let answer = OrgReachabilityAnswer(orgKey: try #require(OrgKey.stored(for: presenter)),
                                               result: .emailFound, probedAt: now.addingTimeInterval(-3 * day),
                                               sourceNaturalKey: "north a", sourceGroupName: "Winter Lights",
                                               presenterName: presenter, foundEmails: [address])
            context.insert(answer)
            answers.append(answer)
        }

        // Sources, so the calendar index has more than one entry to order.
        var sources: [WatchedSource] = []
        for (id, org) in [("src-harbor", "Harbor Hall"), ("src-quarry", "Quarry Hall")] {
            let source = WatchedSource(sourceId: id, orgName: org, listingsURL: "https://example.org/\(id)",
                                       kind: .html, addedAt: now.addingTimeInterval(-30 * day))
            context.insert(source)
            sources.append(source)
        }
        shows.first { $0.naturalKey == "tie lantern" }?.sourceIds = ["src-quarry", "src-harbor"]

        // Inquiries. On Review (nothing sent): two on one night, one sharing its event key with another, a
        // later one and an undated one. On Reached out: three sent at one instant, two sharing a key.
        var inquiries: [Inquiry] = []
        inquiry("Spring Gala", from: "Ada Lark", on: "2027-04-02", into: &inquiries)
        inquiry("Autumn Recital", from: "Bo Finch", on: "2027-03-01", into: &inquiries)
        inquiry("Winter Showcase", from: "Cy Wren", on: "2027-03-01", into: &inquiries)
        inquiry("Open Rehearsal", from: "Ed Pike", on: nil, into: &inquiries)
        inquiry("Autumn Recital", from: "Di Moss", on: "2027-03-01", into: &inquiries)
        let repliedOn = now.addingTimeInterval(-2 * day)
        inquiry("Harvest Dance", from: "Fay Holt", on: "2027-03-05", sentAt: repliedOn, into: &inquiries)
        inquiry("Choir Social", from: "Hal Reed", on: "2027-03-06", sentAt: repliedOn, into: &inquiries)
        inquiry("Harvest Dance", from: "Gil Hart", on: "2027-03-05", sentAt: repliedOn, into: &inquiries)

        // Saved, so every identifier is permanent and distinct: the comparator compares rows by them.
        try context.save()
        return Corpus(shows: shows, inquiries: inquiries, answers: answers, sources: sources)
    }

    // MARK: the pass

    private func pass(_ c: Corpus, focus: StageFocus) -> QueueView.RenderData {
        var inputs = QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus(c.shows), inquiries: c.inquiries,
                                            orgAnswers: c.answers, context: .at(asOf, now: now),
                                            focusedStage: focus)
        inputs.sources = c.sources
        return QueueRenderPass.make(inputs)
    }

    // Every unordered input shuffled, each show's contacts included. Drawn from one generator in a fixed
    // sequence, so a seed names one series of orders on every run and every machine (L339).
    private func shuffled(_ c: Corpus, using generator: inout SeededGenerator,
                          holdingTheScopesTie: Bool) -> Corpus {
        let order = c.shows.shuffled(using: &generator)
        for show in c.shows where show.recipients.count > 1 {
            show.setRecipients(show.recipients.shuffled(using: &generator))
        }
        return Corpus(shows: holdingTheScopesTie ? Self.holdingTheScopesTie(order) : order,
                      inquiries: c.inquiries.shuffled(using: &generator),
                      answers: c.answers.shuffled(using: &generator),
                      sources: c.sources.shuffled(using: &generator))
    }

    // The rows `queueScope` cannot tell apart on its own two keys (an undismissed show's date and fit) keep
    // natural key order among the positions they were shuffled into. Only those rows move, and only among
    // themselves, so every other relative order is the shuffle's.
    static func holdingTheScopesTie(_ shows: [Prospect]) -> [Prospect] {
        var held = shows
        var positions: [String: [Int]] = [:]
        for (index, p) in shows.enumerated() where p.statusRaw != ReviewStatus.dismissed.rawValue {
            positions["\(p.performanceDate ?? "\u{0}")\u{1}\(p.fitScore)", default: []].append(index)
        }
        for slots in positions.values {
            let members = slots.map { shows[$0] }.sorted { $0.naturalKey < $1.naturalKey }
            for (slot, member) in zip(slots, members) { held[slot] = member }
        }
        return held
    }

    private func contactOrder(of key: String, in c: Corpus) -> String {
        guard let p = c.shows.first(where: { $0.naturalKey == key }) else { return "" }
        return p.recipients.map { "\($0.persistentModelID)" }.joined(separator: ",")
    }

    // MARK: the property

    // The corpus as planted, with the scope's own tie held the same way every permutation holds it, so the
    // baseline answers the held question too.
    private func held(_ c: Corpus) -> Corpus {
        Corpus(shows: Self.holdingTheScopesTie(c.shows), inquiries: c.inquiries, answers: c.answers,
               sources: c.sources)
    }

    @Test(arguments: [StageFocus.scout, .review, .reachedOut])
    func everyOrderOfTheInputsGivesOnePass(focus: StageFocus) throws {
        let corpus = try plantedCorpus()
        let baseline = pass(held(corpus), focus: focus)
        var generator = SeededGenerator(seed: seed)
        var failures: [String] = []
        var contactOrders: Set<String> = [contactOrder(of: "pitched shared", in: corpus)]
        for index in 0..<permutationCount {
            let order = shuffled(corpus, using: &generator, holdingTheScopesTie: true)
            contactOrders.insert(contactOrder(of: "pitched shared", in: order))
            let differing = RenderDataComparison.differingFields(baseline, pass(order, focus: focus))
            if !differing.isEmpty {
                failures.append("permutation \(index): " + differing.joined(separator: ", "))
            }
        }
        // The relationship order really moved, or the contact tie breaks were never exercised (L159).
        try #require(contactOrders.count > 1, "the shuffle never changed the order a show's contacts are held in")
        #expect(failures.isEmpty, Comment(rawValue: "seed \(seed), focus \(focus): the pass answered differently "
            + "for the same corpus in another order, in these members:\n" + failures.joined(separator: "\n")))
    }

    // The positive control: every tie the shuffle is meant to exercise is really in the corpus, so a green
    // run above is about something (L159, L98).
    @Test func theCorpusHoldsATieForEveryTermTheShuffleReaches() throws {
        let corpus = try plantedCorpus()
        let scout = pass(corpus, focus: .scout)
        let lookalikes = try #require(scout.cards.alreadyBuilt("tie glass")).laterLookalikeTitles
        #expect(lookalikes.count == 3, "the lookalike target does not name its three later rows")
        #expect(scout.feedBreaks.count == 2, "the corpus does not form two feed breaks that tie on size")
        let survivors = try #require(scout.mergeSurvivorsDropped.first?.action)
        guard case .showMergeSurvivorsTheFeedDropped(let keys) = survivors else {
            Issue.record("the merge survivor notice carries no control to show its rows")
            return
        }
        #expect(keys.count == 3, "the merge survivor notice does not carry its three rows")
        let reached = Set(scout.reachedOut.map { $0.show.naturalKey })
        #expect(reached == ["pitched pair", "pitched shared", "pitched replied", "pitched single"])
        #expect(try #require(scout.cards.alreadyBuilt("north a")).inheritedReachability != nil,
                "the organisation answer reached no show, so the ledger orders nothing")
        #expect(try #require(scout.cards.alreadyBuilt("pair b")).inheritedReachability != nil
                    && scout.cards.alreadyBuilt("pair a")?.inheritedReachability == nil,
                "the two spellings of one organisation do not take different verdicts")

        let review = pass(corpus, focus: .review)
        #expect(review.inquiryRows.count == 5, "the Review stage does not draw the five inquiries planted on it")

        let reachedOut = pass(corpus, focus: .reachedOut)
        let inquiryDates = reachedOut.reachedOutList.entries.compactMap { entry -> Date? in
            if case .inquiry = entry { return entry.next }
            return nil
        }
        #expect(inquiryDates.count == 3 && Set(inquiryDates).count == 1,
                "the three sent inquiries are not due at one instant, so their order is never a tie")
    }

    // The premise behind the hold, which the cutover consumes (L373): today `queueScope` really does break a
    // full tie by input position, so without the hold the scope moves. When the cutover gives it the natural
    // key, this fails: delete `holdingTheScopesTie` and this test together.
    @Test func theScopesOwnTieStillNeedsTheHold() throws {
        let corpus = try plantedCorpus()
        let baseline = pass(held(corpus), focus: .scout)
        var generator = SeededGenerator(seed: seed)
        var moved = 0
        for _ in 0..<permutationCount {
            let order = shuffled(corpus, using: &generator, holdingTheScopesTie: false)
            if RenderDataComparison.differingFields(baseline, pass(order, focus: .scout)).contains("queueScope") {
                moved += 1
            }
        }
        #expect(moved > 0, Comment(rawValue: "queueScope no longer breaks a full tie by input position, so the "
            + "cutover has landed: delete the hold and this test (L373)"))
    }

    // MARK: the terms this slice made total, each over its own permutations

    private func distinct<T, Output: Hashable>(_ items: [T], _ render: ([T]) -> Output) -> Set<Output> {
        Set(CanonicalOracle.permutations(items, count: permutationCount, seed: seed).map(render))
    }

    // The stage's inquiry block, which arrived in store order: dated by date, undated last (#1436's order,
    // lost when #2348 deleted the function that applied it), then the event's key, then the store's own
    // identifier for two inquiries about one event.
    @Test func aStagesInquiryBlockIsInDateOrderWithEveryTieBroken() throws {
        let review = try plantedCorpus().inquiries.filter { $0.sentAt == nil }
        let rendered = distinct(review) { order in
            QueueModel.inquiryRows(order, now: self.now).map { "\($0.eventName)/\($0.id)" }
        }
        #expect(rendered.count == 1, Comment(rawValue: "seed \(seed): \(rendered.count) orders over "
            + "\(permutationCount) permutations"))
        let rows = QueueModel.inquiryRows(review, now: now)
        #expect(rows.map(\.eventName) == ["Autumn Recital", "Autumn Recital", "Winter Showcase", "Spring Gala",
                                          "Open Rehearsal"])
        let autumn = review.filter { $0.eventName == "Autumn Recital" }
        let first = try #require(autumn.min { $0.persistentModelID < $1.persistentModelID })
        #expect(rows.first?.id == String(describing: first.persistentModelID),
                "two inquiries about one event are not in the store identifier's order")
        #expect(QueueModel.groupRowsByDate(rows.map { QueueRow.inquiry($0) }).map(\.id)
                    == ["2027-03-01", "2027-04-02", "tbd"])
    }

    // The Reached out list at one instant: the show before the inquiries, as before, and the inquiries by
    // their event's key and then the store's identifier, where they kept the order the store returned.
    @Test func reachedOutEntriesBreakAnEqualInstantByKindThenKeyThenIdentifier() throws {
        let corpus = try plantedCorpus()
        let sent = corpus.inquiries.filter { $0.sentAt != nil }
        let instant = try #require(sent.first?.nextReachOutDate(now: now))
        let pitched = try #require(corpus.shows.first { $0.naturalKey == "pitched single" })
        let show = (prospect: pitched, recipient: try #require(pitched.recipients.first), next: instant)
        func names(_ order: [Inquiry]) -> [String] {
            QueueModel.reachedOutEntries(prospects: [show], inquiries: order, now: now).map { entry in
                switch entry {
                case .show(let snapshot): return snapshot.show.naturalKey
                case .inquiry(let identity, let row, _): return "\(row.eventName)/\(identity.inquiryID)"
                }
            }
        }
        let rendered = distinct(sent, names)
        #expect(rendered.count == 1, Comment(rawValue: "seed \(seed): \(rendered.count) orders over "
            + "\(permutationCount) permutations"))
        let choir = try #require(sent.first { $0.eventName == "Choir Social" })
        let harvest = sent.filter { $0.eventName == "Harvest Dance" }
            .sorted { $0.persistentModelID < $1.persistentModelID }
        #expect(names(sent) == ["pitched single", "Choir Social/\(choir.persistentModelID)"]
            + harvest.map { "Harvest Dance/\($0.persistentModelID)" })
    }

    // The merge survivors, which came back in the order the corpus listed them and rode the notice's
    // control in that order.
    @Test func unseenSurvivorsAreInKeyOrderWhateverTheCorpusOrder() throws {
        let shows = try plantedCorpus().shows
        let rendered = distinct(shows) { QueueRenderPass.unseenSurvivors(among: $0, today: self.asOf) }
        #expect(rendered == [["survivor a", "survivor b", "survivor c"]],
                Comment(rawValue: "seed \(seed): "
                    + rendered.map { $0.joined(separator: ",") }.joined(separator: " | ")))
    }
}
