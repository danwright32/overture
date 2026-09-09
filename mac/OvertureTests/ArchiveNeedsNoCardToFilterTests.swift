import Testing
import Foundation
import SwiftData

// #3655 Phase 5: Archive sorts and searches the whole store without building a card for any of it.
//
// WHAT THIS IS ABOUT. `mac/Overture/UI/PinnedScrollHolder.swift:9-10` records #3437's own profile putting
// `ArchiveView.items` at 65% of the main thread WHILE TYPING. Archive built a full card for every prospect
// in the store on every keystroke, and it did that for two reasons, both of which turn out not to need a
// card: the status chips ask `ArchiveStatus.of`, which is three row fields, and the search asks
// `ShowSearch.matches`, which a row now answers through `ShowSearchFacts`.
//
// WHY THIS IS A BEHAVIOURAL TEST AND NOT A SOURCE GUARD. A guard reading `ArchiveView.swift` for the
// absence of `QueueModel.items(` asserts a PROXY for the quantity it protects: it would pass unchanged
// while some other line in the file built the same cards a different way (L63). What is asserted here is
// the number of cards that exist after the whole of Archive's filter has run, which is the quantity
// itself.
//
// WHAT IT CANNOT SEE, said so nobody reads more into it: `ArchiveView.body` cannot be evaluated in a test
// at all, so this drives the derivation the view calls rather than the view. The wiring between them is
// `ArchiveWiringGuardTests` below.
@MainActor
@Suite("Archive filters and searches the whole store with no cards (#3655)")
struct ArchiveNeedsNoCardToFilterTests {
    private static let corpusSize = 60

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Shaped like the live store rather than uniformly: `LiveContactShape` records that 962 of the live
    // store's 1,224 rows carry no contact at all, and the contact-derived half is exactly what a card
    // costs, so a corpus where every show has contacts would overstate the saving (L48, L102).
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: "Room \(n % 5)",
                             performanceDate: "2099-01-\(String(format: "%02d", n % 28 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: n % 2 == 0 ? "high" : "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            ctx.insert(p)
            if n % 4 == 0 {
                let r = Recipient(id: "c\(n)@example.invalid", email: "c\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = .pending
                p.recipients.append(r)
            }
            out.append(p)
        }
        return out
    }

    // Archive's own derivation, as the view calls it: every row in the store, and cards only for what the
    // last frame drew. An empty key set is the state on the FIRST frame, which is the one that used to
    // cost 1,224 cards.
    private func archiveScope(_ shows: [Prospect], drawing keys: Set<String> = []) -> QueueModel.Scope {
        QueueModel.scope(from: shows, cardKeys: keys)
    }

    // THE ONE THAT MATTERS. The whole of Archive's filter, over every show, with nothing drawn yet.
    @Test("sorting the whole store into status chips and searching it builds zero cards")
    func theWholeFilterRunsWithNoCards() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let scope = archiveScope(shows)

        // Exactly what `ArchiveView.filteredItems` does, in the order it does it.
        let statuses = Set(scope.rows.map(ArchiveStatus.of))
        let filtered = scope.rows
            .filter { statuses.contains(ArchiveStatus.of($0)) }
            .filter { ShowSearch.matches($0, query: "Contact 4") }
            .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }

        #expect(scope.rows.count == Self.corpusSize,
                Comment(rawValue: "the pass produced \(scope.rows.count) rows for \(Self.corpusSize) "
                        + "shows, so this measured a different corpus from the one it seeded"))
        #expect(!filtered.isEmpty,
                Comment(rawValue: "the search matched nothing, so the zero below is a filter that never "
                        + "ran rather than a filter that needed no cards (L98)"))
        #expect(scope.cards.builtCount == 0,
                Comment(rawValue: "Archive built \(scope.cards.builtCount) cards to sort and search a "
                        + "store nobody is drawing yet. That is the 65% of the main thread while typing "
                        + "that #3655 removed."))
        // No miss either: nothing asked for a card, so neither counter moved.
        #expect(scope.cards.expectedFirstFrameMisses == 0)
        #expect(scope.cards.unexpectedCardMisses == 0)
    }

    // The other half of the same claim: what is DRAWN still gets a real card, so the saving is not the
    // list quietly losing its contents.
    @Test("the rows Archive draws get a card, and only those")
    func drawnRowsGetCards() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let drawn: Set<String> = ["k0", "k4", "k8"]
        let scope = archiveScope(shows, drawing: drawn)

        #expect(scope.cards.builtCount == drawn.count,
                Comment(rawValue: "built \(scope.cards.builtCount) cards for \(drawn.count) drawn rows"))
        for key in drawn {
            let card = try #require(scope.cards.alreadyBuilt(key))
            #expect(card.id == key)
        }
        for key in ["k1", "k2", "k3"] {
            #expect(scope.cards.alreadyBuilt(key) == nil,
                    Comment(rawValue: "a card exists for \(key), which nothing drew"))
        }
    }

    // A row that scrolls into view before any pass predicted it still draws, from a card built on the
    // spot, and that is counted as EXPECTED rather than as a defect. This is #3654's ordering contract
    // reaching Archive, and it is what makes "zero cards on the first frame" safe rather than a blank
    // screen (L67).
    @Test("a row nobody predicted still gets a card, counted as an expected first-frame miss")
    func anUnpredictedRowStillDraws() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        let scope = archiveScope(shows)
        let row = try #require(scope.rows.first { $0.id == "k4" })

        let card = scope.cards.card(for: row)

        #expect(card.id == "k4")
        #expect(card.contacts.count == 1, "the card built on the spot lost this show's contacts")
        #expect(scope.cards.expectedFirstFrameMisses == 1)
        #expect(scope.cards.unexpectedCardMisses == 0,
                Comment(rawValue: "a first-frame request read as a defect in the key set, which is the "
                        + "one counter pinned at zero (L11)"))
    }
}

// The wiring, which the behavioural suite above cannot reach: no SwiftUI body can be evaluated in a test,
// so what Archive actually CALLS is asserted from its source, the way `QueueInvalidationGuardTests` does.
@Suite("Archive is wired to the narrowed pass (#3655)")
struct ArchiveWiringGuardTests {
    private var archive: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }

    // Every needle is bound to a NAMED local before the expectation. `#expect(archive.contains(...))`
    // renders its operand on failure, and `archive` is the whole file: the first form of this suite
    // printed 250 lines of ArchiveView over the one sentence saying what had gone wrong (L445).
    @Test("Archive asks for a narrowed scope, not every card in the store")
    func archiveAsksForANarrowedScope() {
        #expect(!archive.isEmpty)
        // The whole-store card build this phase removed. Named as the call it was, so a revert is red.
        let buildsEveryCard = archive.contains("QueueModel.items(from:")
        #expect(!buildsEveryCard,
                Comment(rawValue: "ArchiveView is building a card for every show in the store again, "
                        + "which is the #3437 profile's 65% of the main thread while typing (#3655)"))
        let narrows = archive.contains("cardKeys: cardKeys.takeKeys()")
        #expect(narrows, "Archive no longer narrows its card build to what the last frame drew")
        let records = archive.contains("cardKeyRegistry: cardKeys")
        #expect(records,
                Comment(rawValue: "Archive builds a narrowed set of cards and records nothing, so the "
                        + "NEXT frame would predict nothing and every row would miss (#3654's contract)"))
    }

    // TAKEN, not read. Left to accumulate, the registry would hold every key Dan has ever scrolled past,
    // so the set the next pass prebuilds would grow through a session until it was the whole store again
    // and the saving would quietly disappear with nothing saying so (L289).
    @Test("the registry is emptied by each pass")
    func theRegistryIsTakenRatherThanRead() {
        let readsWithoutEmptying = archive.contains("cardKeys: cardKeys.keys")
        #expect(!readsWithoutEmptying,
                Comment(rawValue: "Archive reads the registry without emptying it, so the prebuilt set "
                        + "grows through a session until it is the whole store again (L289)"))
    }

    // The row request is the ONE place a drawn row turns into a card, which is what records the key. A
    // surface that reached for a card any other way would draw correctly and register nothing.
    @Test("a drawn row gets its card through the store")
    func aDrawnRowGoesThroughTheStore() {
        let goesThroughTheStore = archive.contains("cards.card(for: scopeRow)")
        #expect(goesThroughTheStore,
                Comment(rawValue: "Archive's row no longer resolves its card through the store, so "
                        + "nothing records what it drew and the next pass predicts nothing (L621)"))
    }
}
