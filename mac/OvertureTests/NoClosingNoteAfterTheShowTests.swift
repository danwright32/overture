import Testing
import Foundation
import SwiftData

// #2710: the final follow-up is the last thing Overture ever emails a contact who has not written back.
//
// Dan's call, 2026-08-14, after reading both emails rendered as a recipient meets them: "I don't want two
// closing notes. I think I actually want to make it so nudge 2 of 2 is the last email and I don't do a
// closing note after the show." Reconfirmed 2026-08-16 against the alternative of keeping it wherever an
// address exists.
//
// #2651 had suppressed the note only for a contact who had ALREADY had the final follow-up, which left it
// going out to anybody whose nudges had not run out: a lead pitched close to the date, one whose nudges
// were stopped early, one where the show arrived between nudge 1 and nudge 2. This is the broader rule.
//
// This suite replaces `ClosingNoteSendTests`, `ClosingNoteTruthTests` and `OneGoodbyePerContactTests`,
// which tested the email and the narrower rule. It keeps the two claims that still matter: nothing is
// composed or sent after the show, and the row still asks to be dealt with.
@MainActor
@Suite("No closing note after the show (#2710)")
struct NoClosingNoteAfterTheShowTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)   // 2026-08-06, Eastern
    private var afterTheShow: Date { now.addingTimeInterval(60 * 60 * 24 * 30) }

    @discardableResult
    private func pitched(_ ctx: ModelContext, followUps: Int, replied: Bool = false) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2026-08-10", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        let r = Recipient(id: "emma@aurora.org", email: "emma@aurora.org", name: "Emma Robinson",
                          provenance: .presenter)
        r.sentAt = now
        r.sendState = .sent
        r.gmailMessageId = "m1"
        r.gmailThreadId = "t1"
        r.followUpCount = followUps
        r.replied = replied
        p.addRecipient(r)
        return (p, r)
    }

    // MARK: nothing is emailed after the show

    // The whole issue in one assertion, at EVERY follow-up count. #2651 only covered the exhausted one,
    // which is exactly the gap this closes: a lead pitched close to the date never reaches that count.
    @Test("a silent show that has passed is never owed an email, whatever the follow-up count")
    func nothingIsEverOwedAnEmail() throws {
        for count in 0...FollowUpConfig().maxFollowUps {
            let ctx = ModelContext(try container())
            let (p, r) = pitched(ctx, followUps: count)

            let prompt = try #require(PostEventPrompt.prompt(for: r, of: p, now: afterTheShow),
                                      "the row must still be prompted at \(count) follow-ups")
            #expect(prompt.kind == .closeOutUnanswered, "at \(count) follow-ups")
            #expect(ReachedOutAction.of(r, in: p, now: afterTheShow, today: "2026-09-05") == .sayHowItEnded)
        }
    }

    // Derived from the type rather than from the two cases somebody remembered, so a kind added later
    // cannot quietly reintroduce an email (L96, L113).
    @Test("no post-event prompt sends anything")
    func noPromptSends() {
        for action in ReachedOutAction.allCases where action.sendsAnEmail {
            #expect(action == .sendNudge,
                    "\(action) sends an email; after #2710 the follow-up is the only one that may")
        }
    }

    // MARK: but the row still asks to be dealt with

    // The part that must not be missed. Sending the note used to write `ShowOutcome.neverHeardBack`, and
    // that write is what took the row off Reached out. Removing the email removes the only PROMPT a silent
    // show ever got, so without this a silent show would sit in Reached out until Dan happened to notice.
    @Test("a silent show that has passed asks to be closed out, in words that are true of it")
    func theSilentShowStillAsks() throws {
        let ctx = ModelContext(try container())
        let (p, r) = pitched(ctx, followUps: 2)

        let prompt = try #require(PostEventPrompt.prompt(for: r, of: p, now: afterTheShow))
        #expect(prompt.kind == .closeOutUnanswered)
        #expect(prompt.reason.contains("nobody replied"),
                "the sentence may claim only what was measured: nobody wrote back")
        #expect(!prompt.reason.contains("they replied"))
    }

    // The other half of the vocabulary, untouched by this issue and asserted so it stays that way: a show
    // somebody DID reply to keeps its own prompt and its own sentence.
    @Test("a show somebody replied to still gets the reply close-out")
    func theRepliedShowIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let (p, r) = pitched(ctx, followUps: 1, replied: true)

        let prompt = try #require(PostEventPrompt.prompt(for: r, of: p, now: afterTheShow))
        #expect(prompt.kind == .closeOut)
        #expect(prompt.reason.contains("they replied"))
    }

    // Dan chose the prompt over recording it himself, 2026-08-16, and the reason is this: the show may
    // have ended some way he knows about and Overture does not.
    @Test("nothing records an outcome by itself")
    func nothingIsRecordedAutomatically() throws {
        let ctx = ModelContext(try container())
        let (p, r) = pitched(ctx, followUps: 2)

        _ = PostEventPrompt.prompt(for: r, of: p, now: afterTheShow)

        #expect(p.showOutcome == nil, "the ending is Dan's to record, and the prompt is what asks him")
    }

    // And once he HAS recorded one, the asking stops. The prompt is the replacement for a send that used
    // to end the row itself, so it has to end the row too.
    @Test("recording the outcome stops the prompt")
    func recordingItEndsTheAsking() throws {
        let ctx = ModelContext(try container())
        let (p, r) = pitched(ctx, followUps: 2)
        #expect(PostEventPrompt.prompt(for: r, of: p, now: afterTheShow) != nil)

        p.showOutcome = .neverHeardBack

        #expect(PostEventPrompt.prompt(for: r, of: p, now: afterTheShow) == nil)
    }
}
