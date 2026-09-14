import Testing
import Foundation
import SwiftData

// #3654 step 4c: the running app checks one of its own cards against a fresh build, on every pass.
//
// The suite half of this milestone is not the whole of what was asked for: the constraint is that the
// result is verified continuously in the suite AND cheaply re-checked in the running app, so a divergence
// reports itself loudly rather than Dan noticing a wrong row. This is that check.
@MainActor
@Suite("The queue checks one of its own cards on every pass (#3654)")
struct TheAppChecksItsOwnCardsTests {
    private static let corpusSize = 30

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// A corpus with a MINORITY carrying contacts, which is the live shape, and a smaller minority
    /// carrying a pending contact with a body, which is the risky population the sampler must find.
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: "Room \(n % 4)",
                             performanceDate: "2099-03-\(String(format: "%02d", n % 27 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: n % 10,
                             tier: "mid", fitReason: "r", matchedClientName: nil,
                             possibleMatchSource: nil, possibleMatchName: nil)
            ctx.insert(p)
            if n % 4 == 0 {
                let r = Recipient(id: "c\(n)@example.invalid", email: "c\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                // The risky one: pending AND carrying a body, which is where the send grouping, the
                // greeting rules and the draft lint all do their work.
                r.sendState = n == 8 ? .pending : .sent
                if n == 8 { p.draftBody = LiveContactShape.draftBody }
                p.recipients.append(r)
            }
            out.append(p)
        }
        return out
    }

    // CORRECTION C4: by RISK, never by cost. The cheapest rendered card is the one with no contacts at
    // all, which is most of the live store and is exactly the card on which nothing contact-derived can
    // differ, so a cheapest-card rule samples the population that cannot fail (L147, L142).
    @Test func theSampleIsTheRiskiestCardAndNotTheCheapest() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()
        let contacts = Dictionary(uniqueKeysWithValues: shows.map { ($0.naturalKey, $0.recipients) })

        let picked = QueueModel.riskiestKey(among: shows.map(\.naturalKey), contactsByKey: contacts)

        #expect(picked == "k8", "the sampler did not find the one show with a pending body-carrying contact")
    }

    // A pass over a healthy store samples a card, finds nothing, and SAYS it looked. An empty answer and
    // an unlooked-at queue are different facts (L98, L557).
    @Test func aHealthyPassRecordsThatItCheckedAndFoundNothing() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()

        let scope = QueueModel.scope(from: shows, corpus: shows)

        #expect(scope.cardCheck.ran)
        #expect(scope.cardCheck.divergence == nil)
    }

    // A pass that built no cards at all did not check anything, and must not claim it did. That is the
    // ordinary first frame, before anything has been drawn.
    @Test func aPassThatBuiltNoCardsDoesNotClaimToHaveChecked() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()

        let scope = QueueModel.scope(from: shows, corpus: shows, cardKeys: [])

        #expect(scope.cardCheck.ran == false)
        #expect(scope.cardCheck.divergence == nil)
    }

    // THE comparison, exercised directly on two cards that really differ, so the mechanism is seen to
    // fire rather than only to agree (L1, L557).
    @Test func theComparisonNamesTheFieldsThatDifferAndNothingElse() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()
        let built = QueueModel.scope(from: shows, corpus: shows)
        let mine = try #require(built.cards.alreadyBuilt("k8"))
        var wrong = mine
        wrong.presenterLine = "not what the fresh build says"
        wrong.bookingSuggested = !mine.bookingSuggested

        let fields = QueueModel.differingFieldNames(wrong, mine)

        #expect(fields == ["bookingSuggested", "presenterLine"])
        // BY NAME, never by value. The names are constants of this app; the values are contacts' names,
        // addresses, greetings and letters. See `CardDivergenceRecord` for the whole of that decision.
        #expect(QueueModel.differingFieldNames(mine, mine).isEmpty)
    }

    // CORRECTION C1: the person is not shown a card the app has just proved wrong. On a divergence the
    // FRESH card is what the store hands back.
    @Test func aDivergentCardIsReplacedByTheFreshOneBeforeItDraws() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()
        let pre = QueueModel.CardPreamble(linked: [:], inherited: [:],
                                          venueBrands: ProducerGate.VenueBrands(shows: [], overrides: .none),
                                          rowCounts: [:], calendarBySourceId: [:], overrides: .none,
                                          clients: .none, now: Date(), day: "2099-03-01")
        let show = try #require(shows.first { $0.naturalKey == "k8" })
        var stale = QueueModel.card(show, contacts: nil, preamble: pre)
        stale.presenterLine = "a card left over from an earlier pass"

        let found = try #require(QueueModel.checkOneCardAgainstAFreshBuild(
            cards: ["k8": stale], contactsByKey: ["k8": show.recipients], corpus: shows, preamble: pre))

        #expect(found.key == "k8")
        #expect(found.fields == ["presenterLine"])
        #expect(found.fresh.presenterLine != stale.presenterLine,
                "the fresh card is what the render should draw, and it is not the stale one")
    }

    // The record's identity is the session AND the sequence, because a sequence restarts at 1 in every
    // launch. `FreezeLog.reportedIdsKey` records what keying on the bare number cost: the notice went
    // permanently silent after the first session (L186).
    @Test func aRecordsIdentityIsItsSessionAndItsSequence() {
        let a = CardDivergenceRecord(session: "s1", sequence: 3, at: Date(), fields: ["venue"],
                                     cardsBuilt: 20, stage: "scout")
        let b = CardDivergenceRecord(session: "s2", sequence: 3, at: Date(), fields: ["venue"],
                                     cardsBuilt: 20, stage: "scout")
        #expect(a.identity != b.identity)
        #expect(a.identity == "s1#3")
    }

    // Compaction keeps ONE EXAMPLE OF EACH DISTINCT FIELD SET. A cap by count alone would let a thousand
    // records of a common divergence flush out the single record naming a different one, and the dropped
    // count would say some were lost but never that the only example of a kind was among them (L191, L63).
    @Test func compactionKeepsOneOfEachKindOfDivergence() {
        let rare = CardDivergenceRecord(session: "s", sequence: 0, at: Date(), fields: ["draftLintBlockers"],
                                        cardsBuilt: 20, stage: nil)
        let common = (1...12).map {
            CardDivergenceRecord(session: "s", sequence: $0, at: Date(), fields: ["venue"],
                                 cardsBuilt: 20, stage: nil)
        }

        let out = CardDivergenceLog.compacted([rare] + common, cap: 10)

        #expect(out.dropped == 3)
        #expect(out.records.count == 10)
        #expect(out.records.contains(rare), Comment(rawValue:
            "the only record of a rare divergence was evicted by a common one, which is the whole reason "
            + "this rule is not a plain cap by count"))
    }

    // The stamp that separates "everything matched" from "nothing ever looked", and its throttle.
    @Test func theStampIsWrittenOnceAMinuteAndNotOncePerRender() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CardDivergenceReport.shouldStamp(last: nil, now: now),
                "a check that has never stamped must stamp, or the file's silence means two things")
        #expect(!CardDivergenceReport.shouldStamp(last: now.addingTimeInterval(-5), now: now))
        #expect(CardDivergenceReport.shouldStamp(last: now.addingTimeInterval(-61), now: now))
    }

    // The three states of the reader, kept apart. An empty file with no stamp is not the same answer as
    // an empty file with one.
    @Test func theReaderTellsNeverLookedApartFromEverythingMatched() throws {
        let support = URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "card-divergence-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let neverLooked = CardDivergenceReport.newlyReported(in: support, defaults: defaults,
                                                             read: { _ in .init(fileWasAbsent: true) })
        #expect(neverLooked == CardDivergenceCopy.neverRan)
        // Said ONCE per install, not on every launch: a notice carrying no action, delivered every time,
        // is what teaches a person to skip the whole surface.
        #expect(CardDivergenceReport.newlyReported(in: support, defaults: defaults,
                                                   read: { _ in .init(fileWasAbsent: true) }) == nil)

        defaults.set(Date(), forKey: CardDivergenceLog.lastRanKey)
        #expect(CardDivergenceReport.newlyReported(in: support, defaults: defaults,
                                                   read: { _ in .init(fileWasAbsent: true) }) == nil,
                "a queue that has been checked and matched says nothing, which is the healthy day")
    }

    @Test func aDivergenceIsSaidOncePerRecord() throws {
        let support = URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "card-divergence-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let record = CardDivergenceRecord(session: "s", sequence: 1, at: Date(),
                                          fields: ["presenterLine"], cardsBuilt: 20, stage: "scout")
        let read: (URL) -> CardDivergenceLog.Read = { _ in .init(records: [record]) }

        let first = CardDivergenceReport.newlyReported(in: support, defaults: defaults, read: read)
        let second = CardDivergenceReport.newlyReported(in: support, defaults: defaults, read: read)

        // The SENTENCE names no field, by the cold read's finding, so what proves the record was read is
        // that something was said at all and that it is the report rather than the never-ran line.
        #expect(first != nil)
        #expect(first != CardDivergenceCopy.neverRan)
        #expect(second == nil, "the same divergence was said twice")

        // AND it does not then fall through to "nothing has ever looked", which is what it did when the
        // never-ran branch read only the stamp. A file holding a record is itself proof the check ran,
        // and saying otherwise while holding that record would be a message contradicted by its own
        // evidence (L11).
        #expect(second != CardDivergenceCopy.neverRan)
    }
}
