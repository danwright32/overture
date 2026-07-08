import Testing
import Foundation
import SwiftData
@testable import Overture

// #650: a show-level conversation state started before per-recipient state existed must not go
// silent the moment this ships. Seeds it onto whichever recipient actually replied (the most recent
// one, if more than one), exactly once (idempotent).
@Suite("Recipient conversation state migration")
struct RecipientConversationStateMigrationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @Test func seedsTheMostRecentReplierWhenTheLeadHasAConversationState() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        p.conversationState = .interested
        p.conversationStateSetAt = now
        p.conversationStateSource = .manual
        let earlierReplier = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        earlierReplier.replied = true
        earlierReplier.repliedAt = now.addingTimeInterval(-1_000)
        let laterReplier = Recipient(id: "b@presenter.example", email: "b@presenter.example", provenance: .presenter)
        laterReplier.replied = true
        laterReplier.repliedAt = now
        let neverReplied = Recipient(id: "c@manual.example", email: "c@manual.example", provenance: .manual)
        p.setRecipients([earlierReplier, laterReplier, neverReplied])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(laterReplier.conversationState == .interested)   // the MOST RECENT replier
        #expect(laterReplier.conversationStateSetAt == now)
        #expect(laterReplier.conversationStateSource == .manual)
        #expect(earlierReplier.conversationState == nil)
        #expect(neverReplied.conversationState == nil)
    }

    @Test func isANoOpWhenTheLeadHasNoConversationState() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replied = true
        p.setRecipients([r])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(r.conversationState == nil)
    }

    // #652: widened from the original #650 seed. A single-recipient show can have its state set by
    // hand (via the still-live lead-level picker) without an auto-detected reply ever firing, so
    // gating strictly on `replied` left it unseeded forever. The lone recipient is the only sensible
    // target when there's no reply to attribute it to.
    @Test func seedsTheLoneRecipientOfASingleContactShowEvenWithoutAReply() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        p.conversationState = .interested
        p.conversationStateSetAt = now
        p.conversationStateSource = .manual
        let onlyContact = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([onlyContact])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(onlyContact.conversationState == .interested)
        #expect(onlyContact.conversationStateSetAt == now)
    }

    // A never-replied MULTI-contact show stays ambiguous: there's no reply to attribute the lead-level
    // state to and more than one plausible recipient, so it's never guessed.
    @Test func isANoOpWhenAMultiContactShowNeverReplied() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        p.conversationState = .interested
        let a = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        let b = Recipient(id: "b@presenter.example", email: "b@presenter.example", provenance: .presenter)
        p.setRecipients([a, b])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(a.conversationState == nil)
        #expect(b.conversationState == nil)
    }

    @Test func isIdempotentOnceARecipientAlreadyHasAConversationState() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        p.conversationState = .interested
        let already = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        already.replied = true
        already.conversationState = .wantsToBook   // Dan (or a prior migration run) already set this directly
        p.setRecipients([already])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(already.conversationState == .wantsToBook)   // untouched, never re-seeded or clobbered
    }

    // #652: self-correcting. If Dan changes the lead-level state a SECOND time (a real, newer
    // timestamp) after the first seed already ran, the recipient-level copy would otherwise be
    // permanently stale once the UI stops reading the lead-level field. Re-seed the SAME target when
    // the lead's own timestamp is genuinely newer.
    @Test func reseedsTheSameTargetWhenTheLeadStateChangedAgainMoreRecently() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let firstSeed = Date(timeIntervalSince1970: 1_000_000)
        let secondChange = Date(timeIntervalSince1970: 2_000_000)
        let target = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        target.replied = true
        target.conversationState = .interested
        target.conversationStateSetAt = firstSeed
        p.setRecipients([target])
        p.conversationState = .wantsToBook           // Dan changed his mind on the lead-level picker...
        p.conversationStateSetAt = secondChange       // ...more recently than the first seed

        RecipientConversationStateMigration.run(in: ctx)

        #expect(target.conversationState == .wantsToBook)
        #expect(target.conversationStateSetAt == secondChange)
    }

    // Never seeded and never re-seeded when the lead-level state has no timestamp to prove it's
    // actually newer (both original #650 idempotency and this widened self-correction stay
    // conservative rather than guessing from absent data).
    @Test func doesNotReseedWhenTheLeadHasNoTimestampToCompare() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let target = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        target.replied = true
        target.conversationState = .wantsToBook
        p.setRecipients([target])
        p.conversationState = .interested   // no conversationStateSetAt set at all

        RecipientConversationStateMigration.run(in: ctx)

        #expect(target.conversationState == .wantsToBook)   // untouched
    }
}
