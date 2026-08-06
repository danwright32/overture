import Testing
import Foundation
import SwiftData

// #2145, step four: what the shared reply screen is answering, as a value the call site builds.
//
// The pieces that differ by entity arrive as CLOSURES wherever they are live, not as strings captured
// when the value was made. That is not a style choice: the AI draft lands on the contact while the panel
// is open (#2143), and a frozen copy would go stale the moment the run came back, which is exactly the
// behaviour #2143 shipped to fix. Anything genuinely static (an inquiry's notes) is a plain value.
@MainActor
@Suite("What the shared reply screen is answering (#2145)")
struct ReplyCompositionTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-10-31", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func repliedContact(_ p: Prospect) -> Recipient {
        let r = Recipient(id: "nbecker@evc.org", email: "nbecker@evc.org", provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailThreadId = "t"
        r.replied = true
        r.repliedAt = Date(timeIntervalSince1970: 2)
        r.lastReplyText = "Tuesday works for us."
        r.replyAudience = ["nbecker@evc.org"]
        p.addRecipient(r)
        return r
    }

    // MARK: the show's composition

    @Test func aShowsCompositionNamesTheGroupAndAnswersThroughTheContactThatWrote() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedContact(p)

        let c = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())
        #expect(c.title == "Every Voice Choirs")
        #expect(ReplyPanel.theirWords(c.contact) == "Tuesday works for us.")
        #expect(c.audience == ["nbecker@evc.org"])
        #expect(c.writer == r.replyFromAddress)
    }

    // A show answers into a Gmail thread that already has a subject, so there is nothing for Dan to type.
    @Test func aShowHasNoSubjectToType() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedContact(p)
        let c = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())
        #expect(c.editableSubject == nil)
    }

    // MARK: the live half

    // The defect this shape exists to avoid: a draft that lands while the screen is open must be VISIBLE
    // to it. Read through the closure, the value written after the composition was built is the value the
    // screen sees.
    @Test func theDraftIsReadWhenAskedNotFrozenWhenBuilt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedContact(p)
        let c = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())
        #expect(c.aiDraft?.current() == nil)

        r.replyDraftBody = "The AI's attempt."
        #expect(c.aiDraft?.current() == "The AI's attempt.",
                "a draft landing after the screen opened must be seen by it, not missed")
    }

    // Same for the run itself: whether one is out is asked, never remembered.
    @Test func whetherADraftIsOnItsWayIsAskedNotRemembered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedContact(p)
        let c = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())
        #expect(c.aiDraft?.isRunning() == false)

        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 3)
        #expect(c.aiDraft?.isRunning() == true)
        #expect(c.aiDraft?.requestedAt() == Date(timeIntervalSince1970: 3))
    }

    // The audience is asked too, so taking somebody off the reply is reflected without rebuilding.
    @Test func theAudienceIsAskedSoARemovalShows() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedContact(p)
        r.replyAudience = ["nbecker@evc.org", "chelsea@evc.org"]
        let c = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())
        #expect(c.audience.count == 2)

        r.replyAudience = ["nbecker@evc.org"]
        #expect(c.audience == ["nbecker@evc.org"])
    }

    // MARK: what it refuses

    // The screen's refusal is the shared rule, asked with this composition's own subject, so a show and
    // an inquiry cannot come to disagree about when a send is impossible (L16).
    @Test func theRefusalIsTheSharedRuleAskedWithThisCompositionsSubject() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedContact(p)
        let c = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())

        #expect(c.refusal(body: "", gmailConnected: true) == .nothingTyped)
        #expect(c.refusal(body: "Tuesday.", gmailConnected: false) == .gmailDisconnected)
        #expect(c.refusal(body: "Tuesday.", gmailConnected: true) == nil)
    }
}
