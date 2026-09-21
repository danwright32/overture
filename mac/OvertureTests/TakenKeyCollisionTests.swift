import Testing
import Foundation
import SwiftData

// #4079: what does SwiftData actually DO when a live row is given a natural key another live row holds?
//
// This codebase has asserted an answer in comments for months without ever reproducing it. `#2754`
// recorded it from a one-off measurement and `SurvivorInheritance`'s header repeats it as the reason its
// callers must delete the losers BEFORE the survivor adopts a key:
//
//   SwiftData does not throw on that collision, it silently MERGES the rows
//
// Everything downstream rests on that sentence. `ScoutService.keyAvailability` gained a `.taken` branch
// for it (#3324), `dropNight` settles the whole walk before its first write because of it, and #4079 was
// filed because a deleted row's `Recipient` arrived on the survivor with every field intact, including
// its primary key, which nothing in the app can do: the only three writes to that relationship outside
// `Prospect.swift` all CREATE a recipient rather than re-point one.
//
// So the sentence is either the mechanism behind two open defects or a piece of folklore, and no test
// could say which. This one drives it and records what happens (L681: a cause inferred by reading code
// must be REPRODUCED before anything is built on it).
//
// WHAT IT ASSERTS is deliberately narrow. Not "SwiftData merges", which is a claim about a framework
// this repository does not own and which a point release may change, but the two properties the app's
// own guards depend on: that the collision does NOT throw, and that the store afterwards does not hold
// two live rows under one natural key. Written that way, the test stays honest if Apple changes the
// behaviour: it goes red and names which half moved.
@MainActor
@Suite("What SwiftData does when a live row takes a key another row holds (#4079)")
struct TakenKeyCollisionTests {

    private static let key = "operation mincemeat|2026-10-26|the green room 42"
    private static let otherKey = "nihao broadway|2026-09-29|the green room 42"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String,
                     contact: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theatre",
                         venue: "The Green Room 42", performanceDate: "2026-10-26",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        if let contact {
            let r = Recipient(id: "\(contact.lowercased())@example.test",
                              email: "\(contact.lowercased())@example.test",
                              name: contact, role: "booking", provenance: .manual)
            r.prospect = p
            ctx.insert(r)
        }
        return p
    }

    // THE REPRODUCTION. Two live rows, each carrying its own contact, and one is handed the other's key
    // with nothing deleted.
    @Test func takingALiveRowsKeyDoesNotThrow() throws {
        let ctx = ModelContext(try container())
        row(ctx, key: Self.key, title: "Operation Mincemeat", contact: "Alex")
        let taker = row(ctx, key: Self.otherKey, title: "Nihao Broadway", contact: "Mijiang")
        try ctx.save()

        taker.naturalKey = Self.key

        // The whole point: this is the write every guard in the app is arranged to avoid, and it is
        // expected to succeed silently. A throw here would be BETTER than the documented behaviour and
        // would mean several guards are defending against something that cannot happen, so it is worth
        // knowing either way.
        #expect(throws: Never.self) { try ctx.save() }
    }

    // THE CONSEQUENCE the app's guards actually turn on: afterwards, is the key still unique?
    //
    // `Prospect.stored(key:)` is what every caller asks, and `keyAvailability` is built on it answering
    // for ONE row. If a collision can leave two live rows under one key, that read is ambiguous and the
    // `.taken` branch is guarding the wrong thing.
    @Test func afterACollisionTheStoreDoesNotHoldTwoLiveRowsUnderOneKey() throws {
        let ctx = ModelContext(try container())
        row(ctx, key: Self.key, title: "Operation Mincemeat", contact: "Alex")
        let taker = row(ctx, key: Self.otherKey, title: "Nihao Broadway", contact: "Mijiang")
        try ctx.save()

        taker.naturalKey = Self.key
        try? ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let sharing = all.filter { $0.naturalKey == Self.key }
        // WHICH object survived, which is the half that decides whether this is also #4068's mechanism.
        // #4068's four rows kept their identity and changed TITLE; if the survivor here keeps its own
        // title and merely absorbs the other's relationships, then this collision is NOT that signature
        // and #4068 has to be explained some other way (L203: a cause is not established until you find
        // a case where the suspected cause is present and the effect is ABSENT).
        print("#4079 identity: survivor is \(all.first?.groupName ?? "NONE"), "
              + "taker object still registered as \(taker.groupName), "
              + "taker is the survivor: \(all.first === taker)")
        // Printed rather than only asserted, because this suite exists to RECORD a behaviour as much as
        // to pin it, and the counts are what a later reader needs (L92 is the opposite failure: a
        // measurement nobody wrote down).
        print("#4079 after collision: \(all.count) row(s) total, \(sharing.count) under the taken key, "
              + "titles \(all.map(\.groupName).sorted())")
        for p in all {
            print("   \(p.groupName) key=\(p.naturalKey) recipients=\(p.recipients.count)")
        }

        #expect(sharing.count <= 1,
                "two live rows share one natural key, so every keyAvailability read is now ambiguous")
    }

    // AND THE PART #4079 WAS ACTUALLY ABOUT: where does a contact end up? A `Recipient` costs money to
    // find, and #4060 is the standing record of a merge destroying some. If the collision moves one onto
    // the survivor, that is the mechanism for the `Nihao Broadway` observation and a candidate for
    // #4068's four renamed dismissals.
    @Test func whereTheContactsEndUpAfterACollision() throws {
        let ctx = ModelContext(try container())
        row(ctx, key: Self.key, title: "Operation Mincemeat", contact: "Alex")
        let taker = row(ctx, key: Self.otherKey, title: "Nihao Broadway", contact: "Mijiang")
        try ctx.save()

        taker.naturalKey = Self.key
        try? ctx.save()

        let contacts = try ctx.fetch(FetchDescriptor<Recipient>())
        print("#4079 recipients after collision: \(contacts.count), "
              + "\(contacts.map { "\($0.name) -> \($0.prospect?.groupName ?? "NO ROW")" }.sorted())")

        // The assertion is that NONE is orphaned, which is the loss that costs money. A recipient whose
        // `prospect` is nil is unreachable from every screen and from every paid-check ledger, and it is
        // invisible to a count of rows.
        #expect(contacts.allSatisfy { $0.prospect != nil },
                "a paid contact was left attached to no show, so nothing on any screen can reach it")
    }
}
