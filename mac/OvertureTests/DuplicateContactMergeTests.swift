import Testing
import Foundation
import SwiftData

// #2422: the pairs already in the store. Fixing the importer only decides what a FUTURE run does; six
// pairs were sitting on the live store when this was written and a re-prep would have kept finding both
// handles and keeping both rows.
//
// This pass DELETES a recipient, so every test below is about what it refuses to touch as much as what it
// merges. The launch backup (#601/#602) is the net under it, and these are the rules that mean it should
// not be needed.
@MainActor
@Suite("Reconciling the duplicate contacts already in the store (#2422)")
struct DuplicateContactMergeTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Cabaret for the Chronically Dramatic",
                                          performanceDate: "2026-08-11", venue: "54 Below")
        let p = Prospect(naturalKey: key, groupName: "Cabaret for the Chronically Dramatic",
                         discipline: "music", venue: "54 Below", performanceDate: "2026-08-11",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @discardableResult
    private func add(_ p: Prospect, name: String, email: String? = nil, formURL: String? = nil,
                     role: String? = nil, provenance: RecipientProvenance = .performer,
                     sourceURL: String? = nil) -> Recipient {
        let r = Recipient(id: Recipient.makeId(email: email, formURL: formURL) ?? name,
                          email: email, name: name, role: role, provenance: provenance,
                          contactFormURL: formURL, contactSourceURL: sourceURL)
        p.addRecipient(r)
        return r
    }

    // The Monroe pair Dan struck by hand on 2026-08-10, which is the shape five more of them share.
    @Test func aFormOnlyRowAndAnAddressRowForOnePersonBecomeOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Ryan James Monroe", formURL: "https://www.instagram.com/ryanjamesmonroe/")
        add(p, name: "Ryan James Monroe", email: "ryan@ryanjamesmonroe.example")
        try ctx.save()

        let merged = DuplicateContactMerge.reconcile(p, in: ctx)

        #expect(merged == 1)
        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.email == "ryan@ryanjamesmonroe.example")
        #expect(p.recipients.first?.id == "ryan@ryanjamesmonroe.example")
    }

    // The two pairs where the LATER find was strictly worse: her own booking page must survive, not the
    // Instagram that arrived beside it.
    @Test func theUsableFormSurvivesAndTheSocialOneGoes() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Cydney McQuillan-Grace", formURL: "https://www.cydneymcg.example/booking")
        add(p, name: "Cydney McQuillan-Grace", formURL: "https://www.instagram.com/cydneyemcg/",
            role: "Vocalist")
        try ctx.save()

        DuplicateContactMerge.reconcile(p, in: ctx)

        #expect(p.recipients.count == 1)
        let kept = try #require(p.recipients.first)
        #expect(kept.contactFormURL == "https://www.cydneymcg.example/booking")
        // And what only the losing row knew came with it (L5): her role was on the Instagram row.
        #expect(kept.role == "Vocalist")
    }

    // Ben Cameron, the worst pair in the store: the rows disagreed about what he is, and only the address
    // row carried his role.
    @Test func nothingTheLosingRowKnewIsLost() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Ben Cameron", formURL: "https://www.instagram.com/bwaysessions/",
            provenance: .act, sourceURL: "https://www.instagram.com/bwaysessions/")
        add(p, name: "Ben Cameron", email: "bwaysessions@example.test",
            role: "Creator & Host, Broadway Sessions", provenance: .performer)
        try ctx.save()

        DuplicateContactMerge.reconcile(p, in: ctx)

        let kept = try #require(p.recipients.first)
        #expect(p.recipients.count == 1)
        #expect(kept.email == "bwaysessions@example.test")
        #expect(kept.role == "Creator & Host, Broadway Sessions")
        #expect(kept.contactFormURL == "https://www.instagram.com/bwaysessions/",
                "his only other handle is still recorded, it is simply not the way in any more")
    }

    // A sent row's address is locked (#408), so a group holding one is left entirely alone rather than
    // partly merged: this pass is not the place to decide what a sent duplicate means.
    @Test func agroupHoldingASentRowIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let sent = add(p, name: "Olivia Terpin", email: "olivia@example.test")
        sent.sendState = .sent
        sent.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        add(p, name: "Olivia Terpin", formURL: "https://www.instagram.com/oliviaterpinofficial/")
        try ctx.save()

        #expect(DuplicateContactMerge.reconcile(p, in: ctx) == 0)
        #expect(p.recipients.count == 2)
    }

    // Dan's own contact is not this pass's to delete (#388).
    @Test func aGroupHoldingAManualRowIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Miguel Amell", email: "typed@example.test", provenance: .manual)
        add(p, name: "Miguel Amell", formURL: "https://www.instagram.com/migueamell/")
        try ctx.save()

        #expect(DuplicateContactMerge.reconcile(p, in: ctx) == 0)
        #expect(p.recipients.count == 2)
    }

    // Two different people are not a duplicate, and neither are two rows with no name to compare.
    @Test func differentPeopleAndNamelessRowsAreUntouched() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Olivia Terpin", email: "olivia@example.test")
        add(p, name: "Bethany Griffin", email: "bethany@example.test")
        let a = Recipient(id: "form:https://one.example", email: nil, name: nil, provenance: .performer,
                          contactFormURL: "https://one.example")
        let b = Recipient(id: "form:https://two.example", email: nil, name: nil, provenance: .performer,
                          contactFormURL: "https://two.example")
        p.addRecipient(a); p.addRecipient(b)
        try ctx.save()

        #expect(DuplicateContactMerge.reconcile(p, in: ctx) == 0)
        #expect(p.recipients.count == 4)
    }

    // Running twice changes nothing the second time, which is what makes it safe at every launch.
    @Test func itIsIdempotent() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Ryan James Monroe", formURL: "https://www.instagram.com/ryanjamesmonroe/")
        add(p, name: "Ryan James Monroe", email: "ryan@ryanjamesmonroe.example")
        try ctx.save()

        #expect(DuplicateContactMerge.reconcile(p, in: ctx) == 1)
        #expect(DuplicateContactMerge.reconcile(p, in: ctx) == 0)
        #expect(p.recipients.count == 1)
    }

    // Three rows for one person collapse to one, not to two, which is what a pairwise pass would leave.
    @Test func threeHandlesForOnePersonCollapseToOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Maggie Stephens", formURL: "https://www.instagram.com/maggieestephens/")
        add(p, name: "Maggie Stephens", formURL: "https://www.maggiestephens.example/contact")
        add(p, name: "Maggie Stephens", email: "maggie@example.test")
        try ctx.save()

        #expect(DuplicateContactMerge.reconcile(p, in: ctx) == 2)
        let kept = try #require(p.recipients.first)
        #expect(p.recipients.count == 1)
        #expect(kept.email == "maggie@example.test")
        #expect(kept.contactFormURL == "https://www.maggiestephens.example/contact",
                "of her two forms the one on her own site survived")
    }

    // Two rows that are equally good resolve the same way every run, rather than by fetch order, or the
    // pass would produce a different store each launch.
    @Test func atieBreaksTheSameWayEveryTime() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Alex Kim", email: "b@example.test")
        add(p, name: "Alex Kim", email: "a@example.test")
        try ctx.save()

        DuplicateContactMerge.reconcile(p, in: ctx)

        #expect(p.recipients.first?.email == "a@example.test")
    }

    // The whole-store entry point reports what it did, so a launch that reconciled something can say so
    // and a test can tell "nothing to do" apart from "did nothing".
    @Test func theStoreWidePassReportsWhatItMerged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        add(p, name: "Ryan James Monroe", formURL: "https://www.instagram.com/ryanjamesmonroe/")
        add(p, name: "Ryan James Monroe", email: "ryan@ryanjamesmonroe.example")
        try ctx.save()

        #expect(DuplicateContactMerge.run(in: ctx) == 1)
        #expect(DuplicateContactMerge.run(in: ctx) == 0)
    }
}

// The reconcile has to actually run at launch. A guard and its wiring are two claims (#887), and this one
// is a pass nobody would notice was missing: the duplicates would simply stay.
@Suite("The duplicate reconcile runs at launch (#2422)")
struct DuplicateContactMergeWiringTests {
    @Test func launchRunsIt() {
        let source = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("DuplicateContactMerge.run(in: context)"))
    }

    // After the natural-key merge, which can itself move recipients between rows: reconciling first would
    // leave the pairs that arrive from that merge for another launch.
    @Test func itRunsAfterTheNaturalKeyMerge() throws {
        let source = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        let keyMerge = try #require(source.range(of: "NaturalKeyVenueMigration.run(in: context)"))
        let reconcile = try #require(source.range(of: "DuplicateContactMerge.run(in: context)"))
        #expect(keyMerge.lowerBound < reconcile.lowerBound)
    }
}
