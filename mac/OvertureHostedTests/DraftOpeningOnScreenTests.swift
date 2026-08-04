import Testing
import Foundation
import SwiftData
import SwiftUI
import ViewInspector
@testable import Overture

// #2018. #2010 was tested as two halves that never meet: the pure suite asserts the SENT email is the
// opening plus the body, and the suite below asserts the opening is ON SCREEN. Neither would fail if the
// screen began showing one thing while the send composed another, as long as each stayed internally
// consistent. That is the shape L1 and L3 warn about, two green halves and no proof the whole holds.
//
// This is the join. It builds a real Prospect and Recipient, makes the queue snapshot the app makes from
// them (`QueueItem(p)`), renders the real draft review, reads the email OFF THE SCREEN, and asks the send
// path what it would hand Gmail for that same contact. The two strings must be equal, character for
// character, with nothing composed in between.
@MainActor
@Suite("The reviewed email is the sent email (#2018)")
struct ReviewedEmailIsTheSentEmailTests {
    private let signature = OutboundSignature(html: nil, plainText: "Best,\nDan")

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func draft(_ ctx: ModelContext, opening: String? = nil)
    -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k|2026-09-12|weill", groupName: "Aurora Strings",
                         discipline: "music", venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.draftSubject = "Photography for your September concert"
        p.draftBody = "I photograph performing arts in New York."
        ctx.insert(p)
        let r = Recipient(id: "sarah@aurora.example", email: "sarah@aurora.example", name: "Sarah Chen",
                          provenance: .presenter)
        r.openingOverride = opening
        p.recipients.append(r)
        ctx.insert(r)
        try? ctx.save()
        return (p, r)
    }

    // Every string the real draft review actually renders for this show.
    private func textsOnScreen(_ p: Prospect) throws -> [String] {
        let view = DraftReviewView(item: QueueItem(p), onUnapprove: {}, onSkip: {},
                                   onSaveDraft: { _, _ in }, outboundSignature: signature)
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The whole rule as one assertion. The opening block and the body preview are two separate views on
    // screen, so the email Dan reads is the longer of them appended to the shorter; the send path's string
    // must be exactly that, with no third piece anywhere.
    private func assertScreenMatchesSend(_ p: Prospect, _ r: Recipient,
                                         _ sourceLocation: SourceLocation = #_sourceLocation) throws {
        let sent = GmailMessage.previewBody(body: try #require(OutgoingPitch.text(for: r, of: p)),
                                            signature: signature)
        let texts = try textsOnScreen(p)

        // The greeting, as rendered: the longest thing on screen that the outgoing email begins with. If
        // the screen showed a different greeting from the one that sends, nothing here would match.
        let opening = try #require(texts.filter { !$0.isEmpty && sent.hasPrefix($0) }
                                        .max(by: { $0.count < $1.count }),
                                   "no text on screen is the start of the email that would send",
                                   sourceLocation: sourceLocation)
        // And the rest of the email, which must ALSO be on screen, sign-off included.
        let rest = String(sent.dropFirst(opening.count + 2))
        #expect(texts.contains(rest),
                "the body block on screen is not the rest of the outgoing email",
                sourceLocation: sourceLocation)
    }

    @Test func anuntouchedDraftReadsExactlyAsItWillSend() throws {
        let ctx = try context()
        let (p, r) = draft(ctx)

        try assertScreenMatchesSend(p, r)
    }

    // The case where a re-composition would be most tempting to add back: Dan wrote the opening himself,
    // so the screen has his words and the send path must not put Overture's back on top.
    @Test func adraftWhoseOpeningDanWroteReadsExactlyAsItWillSend() throws {
        let ctx = try context()
        let (p, r) = draft(ctx, opening: "Sarah, hello again,")

        try assertScreenMatchesSend(p, r)
    }
}

// #2010. The domain half (the email is the opening plus the body, and nothing rewrites Dan's text) is
// pinned in the pure suite. This is the half that only a rendered view can answer: is the opening
// ACTUALLY on screen, where he reads the draft, rather than merely available to a caller.
//
// Dan's rule, 2026-08-03: "I want whatever is in the text box that I see to be what's sent. There should
// never be any hidden addition that I cannot see in the app." A composition he cannot see fails that rule
// whether or not the code composing it is correct.
@MainActor
@Suite("The opening is on screen (#2010)")
struct DraftOpeningOnScreenTests {
    private func allTexts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func item(opening: String, custom: Bool = false, body: String, contacts: Int = 1) -> QueueItem {
        var item = QueueItem(
            id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Carnegie Hall",
            performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "warm", production: "self", profile: "strong",
            coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        var first = RecipientSnapshot(id: "emma@aurora.example", name: "Emma Robinson",
                                      email: "emma@aurora.example", role: "Artistic Director",
                                      provenance: .act, sendState: .pending, replied: false,
                                      lastReplyText: nil, resolution: nil, bounced: false,
                                      outcomeSource: nil)
        first.outgoingOpening = opening
        first.openingIsCustom = custom
        var all = [first]
        if contacts > 1 {
            var second = RecipientSnapshot(id: "john@aurora.example", name: "John Reid",
                                           email: "john@aurora.example", role: nil,
                                           provenance: .presenter, sendState: .pending, replied: false,
                                           lastReplyText: nil, resolution: nil, bounced: false,
                                           outcomeSource: nil)
            second.outgoingOpening = "Hi John,"
            all.append(second)
        }
        item.contacts = all
        item.draftSubject = "Photographing Aurora Strings"
        item.draftBody = body
        return item
    }

    private func view(_ item: QueueItem) -> some View {
        DraftReviewView(item: item, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in })
    }

    // #2033: when the show's contacts share ONE email, there is one greeting, so the screen shows one.
    // Two greetings on a card for a message carrying one of them is the #2010 defect in a new place.
    @Test func ajointEmailShowsOneOpeningNotOnePerContact() throws {
        var it = item(opening: "Hi Emma,", body: "I photograph performing arts.", contacts: 2)
        it.jointOpening = "Hi Emma and John,"

        let texts = try allTexts(view(it))

        #expect(texts.contains("Hi Emma and John,"))
        #expect(!texts.contains("Hi Emma,"), "the per-contact greetings are not what this email carries")
        #expect(!texts.contains("Hi John,"))
    }

    // The rule, rendered. The greeting the email will carry is a line Dan can read on the draft.
    @Test func thegreetingTheEmailWillCarryIsOnScreen() throws {
        let rendered = view(item(opening: "Hi Emma,", body: "I photograph performing arts in New York."))

        #expect(try allTexts(rendered).contains("Hi Emma,"))
    }

    // The "Attn:" block was the more surprising half, since it appears only for a generic inbox. It is
    // part of the opening, so it is on screen wherever it applies.
    @Test func anattnLineIsOnScreenToo() throws {
        let rendered = view(item(opening: "Attn: Emma Robinson, Artistic Director\n\nHello,",
                                 body: "I photograph performing arts in New York."))

        #expect(try allTexts(rendered).contains { $0.contains("Attn: Emma Robinson") })
    }

    // With several contacts each opening is shown against its contact's name, so it is unmistakable which
    // line belongs to whom. This is what makes "if it's multiple i just don't touch it" a safe habit
    // rather than a guess.
    @Test func eachcontactsOwnOpeningIsShownAgainstItsName() throws {
        let rendered = view(item(opening: "Hi Emma,", body: "I photograph performing arts.", contacts: 2))
        let texts = try allTexts(rendered)

        #expect(texts.contains("Hi Emma,"))
        #expect(texts.contains("Hi John,"))
        #expect(texts.contains { $0.contains("Emma") && !$0.hasPrefix("Hi ") })
    }

    // An opening Dan wrote himself says so, so he can tell his own words from Overture's at a glance.
    @Test func anopeningDanWroteIsMarkedAsHis() throws {
        let rendered = view(item(opening: "Emma, hello again,", custom: true,
                                 body: "I photograph performing arts."))

        #expect(try allTexts(rendered).contains("Yours"))
    }

    // The notice, on the case that is actually live: the AI drafter writes a bare "Hello," into the body
    // on 4 of the 9 drafts in the store, and the opening above adds one too.
    @Test func abodyThatAlsoGreetsIsPointedAtNotCorrected() throws {
        let rendered = view(item(opening: "Hi Emma,",
                                 body: "Hello, I photograph performing arts in New York."))

        #expect(try allTexts(rendered).contains(DraftOpeningNotice.note))
    }

    // And it stays quiet otherwise, or it is a warning Dan learns to scroll past.
    @Test func anordinaryDraftCarriesNoNotice() throws {
        let rendered = view(item(opening: "Hi Emma,", body: "I photograph performing arts in New York."))

        #expect(try allTexts(rendered).contains(DraftOpeningNotice.note) == false)
    }
}
