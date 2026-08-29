import Testing
import Foundation
import SwiftData

// #2010, the second half of Dan's rule. The first half is that nothing is added at send that he cannot
// see; this is that nothing is CHANGED behind his back either.
//
// A launch pass used to rewrite the stored body of every draft, stripping a greeting it recognised. That
// is Overture editing text Dan wrote, with nothing on screen saying it did, and it made the outcome of
// typing a greeting depend on whether he happened to restart the app (L5, L64).
//
// LIVE-STORE-CLAIM verified=2026-08-03 measure="stored drafts whose body opens with a greeting, against what the launch strip actually matched"
// Measured before removing it: of 9 stored drafts, 4 open with a greeting and the strip matched NONE of
// them. All four are a bare "Hello," with no name, and the pattern requires a name after the opener. So
// the rewrite was not holding anything together, and the drafts that would double are exactly the ones it
// could not see. 0 drafts carried the review flag.
@MainActor
@Suite("Overture never rewrites Dan's own text (#2010)")
struct OvertureNeverRewritesDansTextTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func prospect(_ ctx: ModelContext, body: String) -> Prospect {
        let p = Prospect(naturalKey: "k|2026-09-12|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.draftSubject = "Photographs of your concert"
        p.draftBody = body
        ctx.insert(p)
        return p
    }

    // The rule itself. Whatever he typed is what is stored, launch after launch.
    @Test func alaunchLeavesADraftBodyExactlyAsDanWroteIt() throws {
        let ctx = try context()
        let typed = "Hi Sarah,\n\nGreat to see the festival back this year."
        let p = prospect(ctx, body: typed)

        LaunchMigrations.run(in: ctx)
        LaunchMigrations.run(in: ctx)

        #expect(p.draftBody == typed, "Overture must never edit text Dan wrote")
    }

    // The behaviour that made this so hard to see: the same typed greeting used to survive or vanish
    // depending on whether he had quit the app in between. It must now behave the same either way.
    @Test func therestartNoLongerChangesWhatAnEmailSays() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hi Sarah,\n\nGreat to see the festival back.")
        let r = Recipient(id: "sarah@aurora.example", email: "sarah@aurora.example", name: "Sarah Chen",
                          provenance: .presenter)
        p.recipients.append(r)
        ctx.insert(r)

        let beforeRestart = OutgoingPitch.text(for: r, of: p)
        LaunchMigrations.run(in: ctx)
        let afterRestart = OutgoingPitch.text(for: r, of: p)

        #expect(beforeRestart == afterRestart,
                "what an email says must not depend on whether Overture was restarted")
    }

    // #2545 replaced the notice tests that sat here. The notice existed only because the app composed a
    // greeting ABOVE the body, so a body that greeted too would say hello twice; there is one greeting
    // now and nothing to warn about. What it recognised as a greeting is pinned in
    // GreetingLivesInTheBodyTests, against the type that decides it.
    //
    // The one thing worth restating here, because it REVERSED: a body that opens with its own greeting
    // used to be the anomaly and is now the requirement. It sends; a headless one is what does not.
    @Test func abodyThatOpensWithItsOwnGreetingIsExactlyWhatSendsNow() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hi Sarah,\n\nGreat to see the festival back.")
        p.status = .approved
        let r = Recipient(id: "sarah@aurora.example", email: "sarah@aurora.example", name: "Sarah Chen",
                          provenance: .presenter)
        p.recipients.append(r)
        ctx.insert(r)

        #expect(r.isSendablePending, "the greeting in the body is the greeting the email carries")
        #expect(OutgoingPitch.text(for: r, of: p) == "Hi Sarah,\n\nGreat to see the festival back.")
    }
}
