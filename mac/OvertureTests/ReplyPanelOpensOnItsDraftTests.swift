import Testing
import Foundation
import SwiftData

// #2143: the reply panel must open on the draft that is already waiting on this contact.
//
// ReplyPanelSheet held its compose text in `@State private var body_ = ""` and never read
// `replyDraftBody`, so the draft written by the scoped AI run (#2129) was invisible on the only surface
// Dan uses. The only view rendering it was the Archive card, and his premise for the whole feature was
// that he never goes there: "archive is only for things that are done and that I can't pitch/respond to
// anymore" (2026-08-05). Typing into the empty box and sending then silently replaced the draft he asked
// for (L5: never destroy good state, and never let a blank value beat real data).
//
// The decisions live here rather than in the view, where nothing could test them.
@MainActor
@Suite("The reply panel opens on the draft already waiting")
struct ReplyPanelOpensOnItsDraftTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func contact(_ ctx: ModelContext) -> Recipient {
        let r = Recipient(id: "c@x.org", email: "c@x.org", provenance: .act)
        ctx.insert(r)
        return r
    }

    // MARK: what the box opens with

    // The defect itself: a drafted reply is what the panel shows.
    @Test func aWaitingDraftIsWhatTheBoxOpensWith() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "Tuesday works. I'll bring the 85mm."
        #expect(ReplyPanel.openingBody(r) == "Tuesday works. I'll bring the 85mm.")
    }

    // Hand-written stays the default: nothing drafted means an empty box, exactly as before.
    @Test func noDraftStillOpensEmptyForHimToType() throws {
        let ctx = ModelContext(try container())
        #expect(ReplyPanel.openingBody(contact(ctx)) == "")
    }

    // An empty stored draft is nothing to show either, and must not read as one.
    @Test func anEmptyStoredDraftOpensEmpty() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "   "
        #expect(ReplyPanel.openingBody(r) == "")
    }

    // MARK: a draft landing while the panel is open

    // Nothing of his to lose, so the draft he pressed for simply appears.
    @Test func aDraftArrivingOverAnEmptyBoxIsAdopted() {
        #expect(ReplyPanel.arriving(draft: "The AI's attempt.", typed: "", seeded: "")
                == .adopt("The AI's attempt."))
    }

    // He opened on an older draft and has not touched it, so the newer one replaces it.
    @Test func aDraftArrivingOverAnUntouchedOlderDraftIsAdopted() {
        #expect(ReplyPanel.arriving(draft: "The second attempt.", typed: "The first attempt.",
                                    seeded: "The first attempt.")
                == .adopt("The second attempt."))
    }

    // The case that must never overwrite: he has been typing while the run was out.
    @Test func aDraftArrivingOverHisOwnWordsIsOfferedNeverImposed() {
        #expect(ReplyPanel.arriving(draft: "The AI's attempt.",
                                    typed: "Tuesday works. I'll bring the 85mm.", seeded: "")
                == .offer("The AI's attempt."))
    }

    // Whitespace is not typing. A box holding a stray newline has nothing worth protecting.
    @Test func whitespaceInTheBoxIsNotWordsToProtect() {
        #expect(ReplyPanel.arriving(draft: "The AI's attempt.", typed: "\n  ", seeded: "")
                == .adopt("The AI's attempt."))
    }

    // Nothing arrived, so nothing is said. An offer for text already on screen would be furniture.
    @Test func nothingArrivingSaysNothing() {
        #expect(ReplyPanel.arriving(draft: nil, typed: "Tuesday works.", seeded: "") == .ignore)
        #expect(ReplyPanel.arriving(draft: "", typed: "", seeded: "") == .ignore)
        #expect(ReplyPanel.arriving(draft: "Tuesday works.", typed: "Tuesday works.", seeded: "")
                == .ignore)
    }

    // MARK: what the box holds afterwards

    // The state transition itself, kept out of the view so the promise that matters ("his words are never
    // overwritten") is asserted somewhere a test can reach, rather than in three lines of a SwiftUI
    // closure nothing can run.
    private let empty = ReplyPanel.ComposeState(typed: "", seeded: "", offered: nil)

    @Test func anAdoptedDraftFillsTheBoxAndCountsAsGiven() {
        let after = ReplyPanel.applying(.adopt("The AI's attempt."), to: empty)
        #expect(after.typed == "The AI's attempt.")
        // Seeded too, so a SECOND draft landing on words he still has not touched replaces this one
        // rather than being offered as though he had written it himself.
        #expect(after.seeded == "The AI's attempt.")
        #expect(after.offered == nil)
    }

    @Test func anOfferedDraftLeavesHisWordsExactlyWhereTheyWere() {
        let writing = ReplyPanel.ComposeState(typed: "Tuesday works.", seeded: "", offered: nil)
        let after = ReplyPanel.applying(.offer("The AI's attempt."), to: writing)
        #expect(after.typed == "Tuesday works.", "what he wrote must survive a draft landing on it")
        #expect(after.offered == "The AI's attempt.")
    }

    // Taking the offer is his press, and once taken there is nothing left to offer.
    @Test func takingTheOfferReplacesTheBoxAndClearsTheOffer() {
        let offered = ReplyPanel.ComposeState(typed: "Tuesday works.", seeded: "",
                                              offered: "The AI's attempt.")
        let after = ReplyPanel.taking(offered)
        #expect(after.typed == "The AI's attempt.")
        #expect(after.seeded == "The AI's attempt.")
        #expect(after.offered == nil)
    }

    // Nothing arriving changes nothing, including an offer already on screen, which stays until he
    // answers it one way or the other.
    @Test func nothingArrivingLeavesTheBoxAlone() {
        let held = ReplyPanel.ComposeState(typed: "Tuesday works.", seeded: "",
                                           offered: "The AI's attempt.")
        #expect(ReplyPanel.applying(.ignore, to: held) == held)
    }

    // MARK: whether a draft is on its way

    // Requested, nothing back yet: the panel has a live run to show, not a silent wait.
    @Test func aRequestedDraftWithNothingBackYetIsDrafting() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 1_000)
        #expect(ReplyPanel.isDrafting(r))
    }

    // It arrived, so the run is over and the words are the thing to show.
    @Test func anArrivedDraftIsNoLongerDrafting() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 1_000)
        r.replyDraftBody = "The AI's attempt."
        #expect(!ReplyPanel.isDrafting(r))
    }

    // The stale-stamp case. recordAnswerSent consumes the draft body and leaves replyDraftRequestedAt
    // standing, so a request from a previous exchange would otherwise make the panel claim a run is
    // drafting a reply nobody asked for, months after it finished (L68: assert the signature of the
    // failure, not a state that expires).
    @Test func aRequestFromAnAnswerAlreadySentIsNotDrafting() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 1_000)
        r.replyDraftBody = "The AI's attempt."
        r.recordAnswerSent(now: Date(timeIntervalSince1970: 2_000))
        #expect(!ReplyPanel.isDrafting(r))
    }

    // And a fresh request on a contact who has been answered before is genuinely drafting again.
    @Test func aFreshRequestAfterAnEarlierAnswerIsDraftingAgain() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "The AI's attempt."
        r.recordAnswerSent(now: Date(timeIntervalSince1970: 2_000))
        r.replyDraftRequestedAt = Date(timeIntervalSince1970: 3_000)
        #expect(ReplyPanel.isDrafting(r))
    }
}
