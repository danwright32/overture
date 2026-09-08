import Testing
import Foundation
import SwiftData

// #3653 Phase 3: `QueueModel.items(from:)` and `QueueModel.scope(from:).items` are one derivation.
//
// `scope` builds the cheap rows every whole-scope sweep reads AND the cards the screen draws, from one
// walk of each show's contacts. `items` is what the two callers that never wanted rows still call, and it
// forwards. Two entry points onto one derivation is the shape that drifts, and the drift here would be
// SILENT in the worst way: both arms would go on returning perfectly good cards, and only the arm the
// render pass does not take would be right (L263, L107).
//
// It compares the CARDS rather than a count, because two arms that build a different number of cards is
// not the failure to worry about: the failure is a card built with a different answer on it, and equal
// counts is exactly what that produces.
@MainActor
@Suite("The cards-only arm and the scope arm build the same cards (#3653)")
struct ScopeAndItemsAgreeTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// A corpus shaped like the live store rather than a uniform one, on `QueueScopeRowParityTests`'s
    /// precedent: the fields that could differ between the two arms are the contact-derived ones, and
    /// 962 of the live store's 1,224 rows carry no contact at all (L102, L48).
    private func corpus(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<30 {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: n % 3 == 0 ? nil : "Room \(n % 5)",
                             performanceDate: n % 7 == 0 ? nil : "2099-01-\(String(format: "%02d", n % 28 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: n % 2 == 0 ? "high" : "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            p.presenter = n % 4 == 0 ? "Company \(n % 3)" : nil
            if n % 5 == 0 { p.sentAt = Date() }
            if n % 8 == 0 { p.draftBody = LiveContactShape.draftBody }
            if n % 11 == 0 { p.outcome = .booked }
            if n % 6 == 0 { p.runNights = ["2099-01-01", "2099-01-02"] }
            ctx.insert(p)
            if n % 4 == 0 {
                let r = Recipient(id: "c\(n)@example.invalid", email: "c\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = n % 8 == 0 ? .sent : .pending
                p.recipients.append(r)
            }
            out.append(p)
        }
        return out
    }

    @Test func bothArmsBuildTheSameCards() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        try ctx.save()

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let viaItems = QueueModel.items(from: shows, corpus: shows, now: now, today: "2026-10-09")
        let viaScope = QueueModel.scope(from: shows, corpus: shows, now: now, today: "2026-10-09")

        #expect(!viaItems.isEmpty, "the fixture built nothing, so neither arm was measured")
        #expect(viaItems == viaScope.items)
        // The rows are the same shows in the same order as the cards beside them, which is what every
        // whole-scope sweep now relies on: it reads the rows while the screen draws the cards.
        #expect(viaScope.rows.map(\.id) == viaScope.items.map(\.id))
    }

    // The row and the card answer the same for the two fields the row gained in this change, and both are
    // fields NOTHING else compares: `inheritedReachability` is handed in per pass rather than read off the
    // show, and `reachabilityRecheckRequestedAt` was simply missing.
    //
    // They matter together rather than separately. `hasFreshReachabilityAnswer` asks the re-check request
    // FIRST and the inherited answer SECOND, so a row carrying neither would answer that question with two
    // of its three inputs missing, and the paid-check offer on Scout is what reads the answer.
    @Test func aRowCarriesTheTwoFieldsTheFreshnessRuleReads() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        let asked = shows[1]
        asked.reachabilityRecheckRequestedAt = Date(timeIntervalSince1970: 1_759_000_000)
        try ctx.save()

        let scope = QueueModel.scope(from: shows, corpus: shows)
        let row = try #require(scope.rows.first { $0.id == asked.naturalKey })
        let card = try #require(scope.items.first { $0.id == asked.naturalKey })

        #expect(row.reachabilityRecheckRequestedAt == asked.reachabilityRecheckRequestedAt)
        #expect(row.reachabilityRecheckRequestedAt == card.reachabilityRecheckRequestedAt)
        #expect(row.inheritedReachability == card.inheritedReachability)
    }
}
