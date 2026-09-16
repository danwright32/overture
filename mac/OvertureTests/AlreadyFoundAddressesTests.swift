import Testing
import Foundation
import SwiftData

// #2990. A contacts-only re-run starts from nothing, knowing nothing.
//
// The work-list already tells the run which addresses Dan has STRUCK (`refusedEmails`, #2392) and never
// which the show already HOLDS, so a re-run pays to rediscover and re-report people it was given a
// moment ago. It only arises when Dan explicitly asks for a contact re-run, which is exactly the case
// where he wants MORE than what is there.
//
// MEASURED BEFORE BUILDING, which is what the issue asked for, across every archived run on this Mac
// (2026-09-06): 34 show-answers where an earlier run had already returned routes for that show, 18
// routes rediscovered against 31 genuinely new ones, and 5 of the 34 returned NOTHING the show did not
// already hold. So the waste is real and modest, which is why this is the cheap additive field the issue
// describes and not a change to what the run researches.
//
// CONTEXT, NOT TARGETS, and that distinction is the whole design. Dan asked for this re-run because he
// wants somebody he does not have; a list the run read as "these are done" would make the re-run
// pointless. The runbook is told so in those words.
@MainActor
@Suite("The work-list says which addresses the show already holds (#2990)")
struct AlreadyFoundAddressesTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, emails: [String] = ["devin@devinmarlowe.example"],
                      formURLs: [String] = []) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Devin Marlowe",
                                          performanceDate: "2026-10-03", venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Devin Marlowe", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-10-03",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 20, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.presenter = "Feinstein's/54 Below"
        ctx.insert(p)
        for e in emails {
            p.addRecipient(Recipient(id: ReplyDetection.email(from: e), email: e, name: nil,
                                     provenance: .act))
        }
        for url in formURLs {
            p.addRecipient(Recipient(id: "form:" + url, email: nil, name: nil, provenance: .performer,
                                     contactMethodRaw: "form_or_dm", contactConfidenceRaw: "low",
                                     contactFormURL: url, contactSourceURL: nil))
        }
        try? ctx.save()
        return p
    }

    private func queue(_ ctx: ModelContext) -> PrepQueue {
        PrepQueueService.buildQueue(from: ctx, generatedAt: "2026-09-06T00:00:00Z",
                                    today: "2026-09-06",
                                    venueHistory: VenueShootHistory(shoots: [], bookings: [],
                                                                    today: "2026-09-06"))
    }

    @Test func theWorkListNamesTheAddressesTheShowAlreadyHolds() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["devin@devinmarlowe.example", "booking@kestrelquartet.example"])
        let item = try #require(queue(ctx).items.first { $0.naturalKey == p.naturalKey })
        #expect(item.alreadyFoundEmails?.sorted()
                == ["booking@kestrelquartet.example", "devin@devinmarlowe.example"])
    }

    // Absent, not empty, on a show with nothing found yet, exactly as `refusedEmails` is: a field present
    // on every item asks the run to reason about a list that is almost always nothing.
    @Test func aShowWithNothingFoundCarriesNoListAtAll() throws {
        let ctx = try context()
        let p = show(ctx, emails: [])
        #expect(try #require(queue(ctx).items.first { $0.naturalKey == p.naturalKey })
            .alreadyFoundEmails == nil)
    }

    // ADDRESSES only, the same rule `refusedEmails` follows and for the same reason (#2392, and the guard
    // in `StrikeAFormContactTests`): the field is documented to the run as a list of email addresses, so a
    // form handle in it is a value the run would read as one.
    @Test func aFormOnlyContactPutsNothingInTheList() throws {
        let ctx = try context()
        let p = show(ctx, emails: [], formURLs: ["https://kestrelquartet.example/contact"])
        #expect(try #require(queue(ctx).items.first { $0.naturalKey == p.naturalKey })
            .alreadyFoundEmails == nil)
    }

    // The two lists are DISJOINT by construction, and this is the one interaction that could go wrong. A
    // struck address is one Dan has refused, so naming it here as something the show holds would put it
    // back in front of the run as context on the very run that is meant to leave it alone (L16).
    @Test func aStruckAddressIsNeverAlsoReportedAsAlreadyFound() throws {
        let ctx = try context()
        let p = show(ctx, emails: ["devin@devinmarlowe.example", "wrong@example.com"])
        ContactRefusal.refuse(email: "wrong@example.com", scope: .show(p.naturalKey), in: ctx)

        let item = try #require(queue(ctx).items.first { $0.naturalKey == p.naturalKey })
        #expect(item.refusedEmails == ["wrong@example.com"])
        #expect(item.alreadyFoundEmails == ["devin@devinmarlowe.example"])
    }

    // Additive and optional on the wire, so every queue file written before this still decodes and a run
    // that has never heard of the field is unaffected.
    @Test func theFieldRoundTripsAndIsAbsentWhenUnset() throws {
        let carried = PrepQueueItem(naturalKey: "k", groupName: "g", venue: nil, performanceDate: nil,
                                    discipline: "music", priorRelationship: "none",
                                    alreadyFoundEmails: ["a@example.com"])
        let json = try JSONEncoder().encode(carried)
        #expect(try JSONDecoder().decode(PrepQueueItem.self, from: json) == carried)
        #expect(String(data: json, encoding: .utf8)?.contains("alreadyFoundEmails") == true)

        let bare = PrepQueueItem(naturalKey: "k", groupName: "g", venue: nil, performanceDate: nil,
                                 discipline: "music", priorRelationship: "none")
        #expect(String(data: try JSONEncoder().encode(bare), encoding: .utf8)?
            .contains("alreadyFoundEmails") == false)
        let old = Data(#"{"naturalKey":"k","groupName":"g","discipline":"music","priorRelationship":"none"}"#.utf8)
        #expect(try JSONDecoder().decode(PrepQueueItem.self, from: old).alreadyFoundEmails == nil)
    }
}
