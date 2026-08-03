import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

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
        DraftReviewView(item: item, onApprove: {}, onUnapprove: {}, onSkip: {}, onSaveDraft: { _, _ in })
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
