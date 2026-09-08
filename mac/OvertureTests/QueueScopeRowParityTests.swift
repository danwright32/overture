import Testing
import Foundation
import SwiftData

// #3653 Phase 3c: a row and a card must never disagree about a show.
//
// The split's whole safety argument is that `QueueScopeRow` carries the same answers `QueueItem` does for
// the fields every whole-scope consumer reads. If one of them drifts, a count on the masthead, a date
// heading, a self-booking clash or the Scout ordering silently describes a different show from the card
// beneath it, and nothing else in the suite would notice: both would be internally consistent.
//
// THE COMPARISON IS DERIVED, NEVER LISTED. Hand-writing the field pairs would check what somebody
// remembered on the day, and a field added to the row later would be exempt from the very test written to
// catch it (L96). This reflects the row's own stored fields and demands a same-named field on the card,
// so a new row field joins the check by existing, and one the card does not have is a compile-time
// impossibility caught here as a named failure instead.
@MainActor
@Suite("A row agrees with the card it is the cheap half of (#3653)")
struct QueueScopeRowParityTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// A corpus shaped like the live store rather than a uniform one.
    ///
    /// `LiveContactShape` records why this matters: 962 of the 1,224 rows carry NO contact at all, so a
    /// fixture giving every show a contact would compare a path the store does not take, and the fields
    /// that differ between a row and a card are exactly the contact-derived ones (L102, L48).
    private func corpus(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<40 {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Show \(n)", discipline: "choral",
                             venue: n % 3 == 0 ? nil : "Room \(n % 5)",
                             performanceDate: n % 7 == 0 ? nil : "2099-01-\(String(format: "%02d", n % 28 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: n % 2 == 0 ? "high" : "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            // The states the row's derived answers turn on, spread across the corpus so each is exercised.
            if n % 5 == 0 { p.sentAt = Date() }
            if n % 8 == 0 { p.draftBody = LiveContactShape.draftBody }
            if n % 11 == 0 { p.outcome = .booked }
            if n % 13 == 0 { p.outcome = .lostSoft }
            if n % 6 == 0 { p.runNights = ["2099-01-01", "2099-01-02"] }
            ctx.insert(p)
            // Contacts on a MINORITY, which is the live shape. Nine of forty carry one, roughly the
            // 21% of rows that have any contact at all on the real store.
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

    @Test func everyStoredRowFieldMatchesTheCard() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        try ctx.save()

        var compared = 0
        for p in shows {
            let row = QueueScopeRow(p, facts: .of(p))
            let card = QueueItem(p)
            let cardFields = Dictionary(uniqueKeysWithValues:
                Mirror(reflecting: card).children.compactMap { child -> (String, Any)? in
                    child.label.map { ($0, child.value) }
                })

            for child in Mirror(reflecting: row).children {
                guard let label = child.label else { continue }
                // The contacts themselves are the row's own reduction and have no card counterpart:
                // the card keeps the models, the row keeps the facts. Excluded by NAME rather than by
                // "whatever did not match", so the exclusion cannot quietly grow (L233).
                if label == "facts" { continue }
                // `hasDraft` is STORED on the row and COMPUTED on the card (`draftBody != nil`), so
                // reflection cannot see the card's. It is compared in the derived test below instead of
                // being dropped, because "reflection could not see it" and "nobody checks it" must not
                // be the same outcome (L98). Named here rather than inferred from what failed to match,
                // so the exclusion cannot quietly grow (L233).
                if label == "hasDraft" { continue }
                guard let mine = cardFields[label] else {
                    Issue.record(Comment(rawValue: "the row has a field `\(label)` the card does not, so "
                                         + "nothing can say whether the two agree about it"))
                    continue
                }
                compared += 1
                #expect(String(describing: child.value) == String(describing: mine),
                        Comment(rawValue: "row and card disagree about `\(label)` on \(p.naturalKey): "
                                + "row \(child.value), card \(mine)"))
            }
        }
        // The L98 half: a reflection that found no fields would pass this test in silence.
        #expect(compared > 20 * shows.count / 2,
                Comment(rawValue: "only \(compared) field comparisons were made across \(shows.count) "
                        + "shows, which is too few for the row's field count: the reflection is not "
                        + "reading what it thinks it is and this proved nothing."))
    }

    /// And the two DERIVED answers, which reflection cannot see because they are computed properties.
    @Test func theDerivedAnswersMatchTheCard() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        try ctx.save()

        for p in shows {
            let row = QueueScopeRow(p, facts: .of(p))
            let card = QueueItem(p)
            #expect(row.performanceStatus == card.performanceStatus,
                    Comment(rawValue: "performanceStatus disagrees on \(p.naturalKey)"))
            #expect(row.isBooked == card.isBooked, Comment(rawValue: "isBooked disagrees on \(p.naturalKey)"))
            #expect(row.isLost == card.isLost, Comment(rawValue: "isLost disagrees on \(p.naturalKey)"))
            // Stored on the row, computed on the card, so the reflection above cannot pair them.
            #expect(row.hasDraft == card.hasDraft,
                    Comment(rawValue: "hasDraft disagrees on \(p.naturalKey)"))
        }
    }

    /// Building a row costs ONE reach for the contacts, the same as a card, which is what makes building
    /// both affordable. If this moves, #3654's whole premise moves with it.
    @Test func buildingARowReachesForTheContactsOnce() throws {
        let ctx = ModelContext(try container())
        let shows = corpus(ctx)
        try ctx.save()
        let p = try #require(shows.first)

        let tally = QueueRenderPass.WorkTally.measure { _ = QueueScopeRow(p, facts: .of(p)) }
        #expect(tally.recipientReaches == 1,
                Comment(rawValue: "building one row reached for its contacts \(tally.recipientReaches) "
                        + "times. One is the number a CARD costs (RecipientWalkCountTests), and a row "
                        + "that costs more than a card is not a cheap half of anything."))
        #expect(tally.queueItems == 0,
                Comment(rawValue: "building a row built \(tally.queueItems) cards, so the row is not "
                        + "cheap at all and every whole-scope consumer would still pay for one."))
    }
}
