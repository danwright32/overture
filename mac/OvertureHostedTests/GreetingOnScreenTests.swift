import Testing
import Foundation
import SwiftData
import SwiftUI
import ViewInspector
@testable import Overture

// #2018. #2010 was tested as two halves that never meet: one suite asserted what the SEND composes, the
// other asserted what the SCREEN shows. Neither would fail if the screen began showing one thing while
// the send composed another, as long as each stayed internally consistent. That is the shape L1 and L3
// warn about, two green halves and no proof the whole holds.
//
// This is the join, and #2545 makes it stricter rather than retiring it. There is no opening block on
// screen any more and nothing is composed above the body, so the email Dan reads must now be, character
// for character, a single string the card renders. If anything ever starts being appended again, this is
// the test that goes red.
@MainActor
@Suite("The reviewed email is the sent email (#2018)")
struct ReviewedEmailIsTheSentEmailTests {
    private let signature = OutboundSignature(html: nil, plainText: "Best,\nDan")

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func draft(_ ctx: ModelContext, body: String) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k|2026-09-12|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.draftSubject = "Photography for your September concert"
        p.draftBody = body
        ctx.insert(p)
        let r = Recipient(id: "sarah@aurora.example", email: "sarah@aurora.example", name: "Sarah Chen",
                          provenance: .presenter)
        p.recipients.append(r)
        ctx.insert(r)
        try? ctx.save()
        return (p, r)
    }

    private func textsOnScreen(_ p: Prospect) throws -> [String] {
        let view = DraftReviewView(item: QueueItem(p), onUnapprove: {}, onSaveDraft: { _, _ in },
                                   outboundSignature: signature)
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The whole rule as one assertion, and it is a stronger claim than it used to be: the outgoing email
    // is now ONE string on screen, not the longest visible prefix plus the rest.
    private func assertScreenMatchesSend(_ p: Prospect, _ r: Recipient,
                                         _ sourceLocation: SourceLocation = #_sourceLocation) throws {
        let sent = GmailMessage.previewBody(body: try #require(OutgoingPitch.text(for: r, of: p)),
                                            signature: signature)

        #expect(try textsOnScreen(p).contains(sent),
                "the email that would send is not on screen character for character",
                sourceLocation: sourceLocation)
    }

    @Test func anuntouchedDraftReadsExactlyAsItWillSend() throws {
        let ctx = try context()
        let (p, r) = draft(ctx, body: "Hi Sarah,\n\nI photograph performing arts in New York.")

        try assertScreenMatchesSend(p, r)
    }

    // The shared-inbox case, which used to be where the app added most: an `Attn:` block AND a greeting,
    // neither of them in the box Dan read. Both are the drafter's words now, so they are simply part of
    // the one string.
    @Test func asharedInboxDraftReadsExactlyAsItWillSendToo() throws {
        let ctx = try context()
        let (p, r) = draft(ctx, body: "Attn: Sarah Chen, Artistic Director\n\nHello,\n\n"
                           + "I photograph performing arts in New York.")

        try assertScreenMatchesSend(p, r)
    }
}

// #2545. The domain half (a body that does not greet, or greets one person on an email several people
// receive, is not sendable) is pinned in the pure suite. This is the half only a rendered view can
// answer: does the REASON actually reach the screen, beside the button it disables.
//
// That question is the whole reason the sentence lives with the send button rather than up by the body.
// A refusal only the disabled action could have spoken is a refusal nobody ever reads (L109), and Dan has
// met exactly that here before: a greyed Send with nothing said next to it (#2052, #2012).
@MainActor
@Suite("The greeting hold says why, on screen (#2545)")
struct GreetingHoldOnScreenTests {
    private func allTexts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func item(body: String, missing: Bool = false, misaddressed: Bool = false,
                      audience: Int = 1, overridden: Bool = false) -> QueueItem {
        var item = QueueItem(
            id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Carnegie Hall",
            performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "warm", production: "self", profile: "strong",
            coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        item.contacts = [RecipientSnapshot(id: "emma@aurora.example", name: "Emma Robinson",
                                           email: "emma@aurora.example", role: "Artistic Director",
                                           provenance: .act, sendState: .pending, replied: false,
                                           lastReplyText: nil, resolution: nil, bounced: false,
                                           outcomeSource: nil)]
        item.draftSubject = "Photographing Aurora Strings"
        item.draftBody = body
        item.draftMissingGreeting = missing
        item.draftGreetingMisaddressed = misaddressed
        item.greetingAudienceSize = audience
        item.greetingOverridden = overridden
        return item
    }

    private func view(_ item: QueueItem) -> some View {
        DraftReviewView(item: item, onUnapprove: {}, onSaveDraft: { _, _ in })
    }

    // The live case on the day this shipped: 10 of the 14 drafts in the store were written under the old
    // rule and open with no greeting at all.
    @Test func aheadlessDraftSaysSoBesideTheSendButton() throws {
        let rendered = view(item(body: "I photograph performing arts in New York.", missing: true))

        #expect(try allTexts(rendered).contains(
            DraftReviewNotes.greeting(missing: true, misaddressed: false, audience: 1,
                                      overridden: false) ?? "no note"))
    }

    // The other half of the hold, which needs its own sentence because it needs the opposite fix.
    @Test func agreetingThatNamesOnePersonOnASharedEmailSaysSoToo() throws {
        let rendered = view(item(body: "Hi Emma,\n\nI photograph performing arts.",
                                 misaddressed: true, audience: 2))
        let texts = try allTexts(rendered)

        #expect(texts.contains(DraftReviewNotes.greeting(missing: false, misaddressed: true, audience: 2,
                                                         overridden: false) ?? "no note"))
        #expect(texts.contains { $0.contains("goes to 2") }, "it has to say how many it reaches")
    }

    // The way OUT of the hold has to be on screen with it, or the sentence is a dead end: it tells him
    // what is wrong and offers nothing to do about it.
    @Test func theoverrideIsOfferedBesideTheReason() throws {
        let rendered = view(item(body: "I photograph performing arts in New York.", missing: true))

        #expect(try allTexts(rendered).contains("Override"))
    }

    // #718's audit trail, rendered: an overridden hold tones down rather than vanishing, and the way out
    // is no longer offered because it has already been taken.
    @Test func anoverriddenHoldLeavesItsTrailAndDropsTheButton() throws {
        let rendered = view(item(body: "I photograph performing arts in New York.", missing: true,
                                 overridden: true))
        let texts = try allTexts(rendered)

        #expect(texts.contains("Sending despite the greeting warning you confirmed."))
        #expect(!texts.contains("Override"))
    }

    // Carried over from #718's suite, which #2545 replaces. ViewInspector cannot look inside a native
    // .alert, so this proves the first half of the two-step gate: tapping "Override" alone must NOT fire
    // the callback, it must open the confirm. Without it, an override that Dan meant to read first
    // becomes a single tap, which is exactly what a two-step gate exists to prevent.
    @Test func tappingOverrideAloneDoesNotFireTheCallbackWithoutConfirming() throws {
        var overridden = false
        let view = DraftReviewView(item: item(body: "I photograph performing arts.", missing: true),
                                   onUnapprove: {}, onSaveDraft: { _, _ in },
                                   onOverrideGreeting: { overridden = true })

        try view.inspect().find(button: "Override").tap()

        #expect(overridden == false)
    }

    // And it stays quiet on an ordinary draft, or it is a warning Dan learns to scroll past.
    @Test func adraftThatGreetsProperlyCarriesNoNotice() throws {
        let rendered = view(item(body: "Hi Emma,\n\nI photograph performing arts in New York."))
        let texts = try allTexts(rendered)

        #expect(!texts.contains { $0.hasPrefix("This draft won't send: it doesn't open") })
        #expect(!texts.contains { $0.contains("the greeting names one person") })
    }
}
