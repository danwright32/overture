import Testing
import Foundation
import SwiftData

// #3082: Dan's overrule of a hold-down answered ONE question, and could silently be taken as his answer
// to a different one.
//
// `heldDownToUnverifiedDismissed` is him looking at an address and saying he recognises it. It was reset
// on exactly one condition, the address changing, which was complete while the hold-down had one reason.
// #2895 gave it two, and they ask genuinely different things: "is this address really theirs" versus "is
// this the right person". A dismissal of the first standing as an answer to the second is the same defect
// #2895 was written to fix, handed back through the overrule (L11).
//
// Dormant when filed, because nothing emits `performanceCorroborated` yet. Fixed before adoption rather
// than after, which is the only moment it is cheap.
@MainActor
@Suite("A dismissal answers the accusation it was given (#3082)")
struct ADismissalAnswersOneAccusationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func kept(_ ctx: ModelContext) -> String {
        let key = Prospect.makeNaturalKey(groupName: "Robin Vale", performanceDate: "2026-11-14",
                                          venue: "East Village Playhouse")
        let p = Prospect(naturalKey: key, groupName: "Robin Vale", discipline: "theatre",
                         venue: "East Village Playhouse", performanceDate: "2026-11-14",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func contact(sourceUrl: String?, corroborated: Bool? = nil) -> PrepContact {
        PrepContact(name: "Robin Vale", role: "Playwright", email: "robin@robinvale.example",
                    method: "named_decision_maker", confidence: "high", formUrl: nil,
                    provenance: "performer", sourceUrl: sourceUrl,
                    performanceCorroborated: corroborated)
    }

    private func ingest(_ contact: PrepContact, key: String, into ctx: ModelContext) {
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [contact])
        ]), into: ctx)
    }

    private func recipient(_ ctx: ModelContext, key: String) throws -> Recipient {
        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key }))
        return try #require(p.first?.recipients.first)
    }

    // THE defect. He answered "yes, that address is theirs"; the next run accuses the PERSON instead.
    @Test func adismissalDoesNotCarryOverToADifferentReason() throws {
        let ctx = ModelContext(try container())
        let key = kept(ctx)

        ingest(contact(sourceUrl: nil), key: key, into: ctx)
        var r = try recipient(ctx, key: key)
        #expect(r.heldDownReason == .namedNoPage)
        r.heldDownToUnverifiedDismissed = true
        try? ctx.save()

        ingest(contact(sourceUrl: "https://robinvale.example/about", corroborated: false),
               key: key, into: ctx)

        r = try recipient(ctx, key: key)
        #expect(r.heldDownReason == .pageDoesNotCorroborate)
        #expect(r.heldDownToUnverifiedDismissed == false,
                "his answer about the address became his answer about the person")
        #expect(r.isHeldDownToUnverified, "so the card asks him the new question rather than asserting")
    }

    // The other direction, because a rule that only ever runs one way is a rule half exercised.
    //
    // What it actually looks like is worth knowing, and it is not the mirror image: the update path falls
    // back to the STORED page when a re-run supplies none, so a later run cannot take a citation away. It
    // can only stop declaring, which lifts the hold entirely. The dismissal must still be cleared there,
    // or it sits on the row waiting to answer whatever is alleged next.
    @Test func alaterRunThatStopsDeclaringAlsoClearsHisAnswer() throws {
        let ctx = ModelContext(try container())
        let key = kept(ctx)

        ingest(contact(sourceUrl: "https://robinvale.example/about", corroborated: false),
               key: key, into: ctx)
        var r = try recipient(ctx, key: key)
        #expect(r.heldDownReason == .pageDoesNotCorroborate)
        r.heldDownToUnverifiedDismissed = true
        try? ctx.save()

        ingest(contact(sourceUrl: nil), key: key, into: ctx)

        r = try recipient(ctx, key: key)
        #expect(r.heldDownToUnverified == false, "nothing is alleged now")
        #expect(r.heldDownToUnverifiedDismissed == false,
                "so no stale answer is left lying in wait for the next accusation")
    }

    // The live case that must NOT change: a re-run that still cites nothing keeps saying so, because the
    // run does not know Overture downgraded it and reports `high` again every time. If his dismissal were
    // cleared here he would be asked the same question after every single check.
    @Test func arerunWithTheSameReasonKeepsHisAnswer() throws {
        let ctx = ModelContext(try container())
        let key = kept(ctx)

        ingest(contact(sourceUrl: nil), key: key, into: ctx)
        var r = try recipient(ctx, key: key)
        r.heldDownToUnverifiedDismissed = true
        try? ctx.save()

        ingest(contact(sourceUrl: nil), key: key, into: ctx)

        r = try recipient(ctx, key: key)
        #expect(r.heldDownToUnverifiedDismissed, "nothing new was alleged, so nothing was asked again")
        #expect(r.isHeldDownToUnverified == false)
    }

    // A row dismissed BEFORE #2895 recorded no reason, and there was one reason then, so the first ingest
    // after this must not silently un-dismiss it. Without reading a missing reason as `namedNoPage` this
    // fix would throw away every overrule Dan has ever made (L90).
    @Test func arowDismissedBeforeThereWereTwoReasonsKeepsHisAnswer() throws {
        let ctx = ModelContext(try container())
        let key = kept(ctx)

        ingest(contact(sourceUrl: nil), key: key, into: ctx)
        var r = try recipient(ctx, key: key)
        r.heldDownToUnverifiedDismissed = true
        // Exactly what such a row holds: held down, dismissed, and no reason recorded.
        r.heldDownReasonRaw = nil
        try? ctx.save()

        ingest(contact(sourceUrl: nil), key: key, into: ctx)

        r = try recipient(ctx, key: key)
        #expect(r.heldDownToUnverifiedDismissed, "his existing overrule was thrown away by the upgrade")
    }

    // The address changing still clears it, unchanged: that is a judgement about THIS address and a
    // genuinely different one has to be asked about again.
    @Test func achangedAddressStillClearsIt() throws {
        let ctx = ModelContext(try container())
        let key = kept(ctx)

        ingest(contact(sourceUrl: nil), key: key, into: ctx)
        var r = try recipient(ctx, key: key)
        r.heldDownToUnverifiedDismissed = true
        try? ctx.save()

        var moved = contact(sourceUrl: nil)
        moved.email = "robin.vale@elsewhere.example"
        ingest(moved, key: key, into: ctx)

        r = try recipient(ctx, key: key)
        #expect(r.heldDownToUnverifiedDismissed == false)
    }

    // The four sibling guards each carry their own dismissal and each has ONE reason, so none of them can
    // drift this way. Stated as a check rather than as a claim, so a second reason added to any of them
    // arrives with this question already asked (L30).
    @Test func thesiblingGuardsStillHaveOneReasonEach() {
        let source = SourceGuardHelper.source("Overture/Domain/Recipient.swift")
        for guardName in ["looksLikeVenue", "looksLikePressContact",
                          "looksLikeDuplicateContact", "looksLikeAnotherPersons"] {
            #expect(source.contains("\(guardName)ReasonRaw") == false,
                    "\(guardName) has grown a reason, so its dismissal needs #3082's rule too")
        }
    }
}
