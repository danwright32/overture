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
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
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

    // Instead of rewriting, say so. A body that opens with its own greeting is worth pointing at, because
    // the opening above it carries one too, but it is Dan's text and his call.
    @Test func abodyThatOpensWithItsOwnGreetingIsReportedNotRewritten() {
        #expect(DraftOpeningNotice.bodyRepeatsAGreeting("Hi Sarah,\n\nGreat to see the festival back."))
        #expect(DraftOpeningNotice.bodyRepeatsAGreeting("Hello,\n\nI'm a documentary photographer."))
        #expect(DraftOpeningNotice.bodyRepeatsAGreeting("Dear Sarah,\n\nGreat to see you."))
    }

    // The four live bodies this was measured against are all a bare "Hello," with no name, which the old
    // strip could not match. The notice has to catch exactly the case the rewrite missed.
    @Test func thenoticeCatchesTheFormTheOldRewriteCouldNotSee() {
        #expect(DraftOpeningNotice.bodyRepeatsAGreeting("Hello, I photograph performing arts in New York."))
    }

    // It must stay quiet on an ordinary body, or it is a warning Dan learns to scroll past (L36).
    @Test func anordinaryBodyGetsNoNotice() {
        #expect(!DraftOpeningNotice.bodyRepeatsAGreeting("I photograph performing arts in New York."))
        #expect(!DraftOpeningNotice.bodyRepeatsAGreeting("I've photographed at Carnegie Hall for years."))
        #expect(!DraftOpeningNotice.bodyRepeatsAGreeting("My name is Dan Wright and I'm a photographer."))
        #expect(!DraftOpeningNotice.bodyRepeatsAGreeting("Highlights from the season are attached."))
    }

    // It NOTICES, it does not block. Blocking would be the app deciding for him, and the whole point is
    // that he can now see the opening and the body together and judge it himself.
    @Test func thenoticeDoesNotStopTheSend() throws {
        let ctx = try context()
        let p = prospect(ctx, body: "Hi Sarah,\n\nGreat to see the festival back.")
        let r = Recipient(id: "sarah@aurora.example", email: "sarah@aurora.example", name: "Sarah Chen",
                          provenance: .presenter)
        p.recipients.append(r)
        ctx.insert(r)

        #expect(r.isSendablePending, "a repeated greeting is worth saying, not worth refusing")
    }
}
