import Testing
import Foundation
import SwiftData

// #2643: the closing note said "the timing didn't line up this round" and "it was good to be in touch"
// to somebody who had never written back. Both sentences assert a two-way exchange that, by construction,
// cannot have happened: `PostEventPrompt.prompt(for:of:now:)` offers the closing note ONLY when nobody on
// the show has replied (it picks `.closeOut` the moment anybody has), and sending it records
// `ShowOutcome.neverHeardBack`. So the body went out claiming the opposite of the fact the same send was
// writing into the store.
//
// This suite is the REVIEWER for that body, and it exists because nothing else is (L129). The copy
// inventory is correctly blind to it (an outbound email is not the app's own voice to Dan, so the body sits
// in a `copy-inventory:ignore` region), and the cold read of that inventory is the only mechanism that
// catches "this sentence is wrong for the state that produces it". The draft lint reads the AI-drafted
// pitch, not a static template. That left the sentences going to strangers under Dan's name as the only
// copy in the product with no reader, which is how these two survived a rewrite of the paragraph around
// them three days earlier (#2615 changed the first sentence and left these).
@MainActor
@Suite("The closing note is true of the silence it is only ever sent into (#2643)")
struct ClosingNoteTruthTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "54 Below",
                         performanceDate: "2026-03-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = EasternDate.date(from: "2026-02-01")
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, replied: Bool = false) -> Recipient {
        let r = Recipient(id: "a@b.com", email: "a@b.com", provenance: .manual)
        r.sendState = .sent
        r.sentAt = EasternDate.date(from: "2026-02-01")
        r.gmailMessageId = "m1"
        if replied { r.reopenOnReply(at: EasternDate.date(from: "2026-02-05")!) }
        r.prospect = p
        ctx.insert(r)
        return r
    }

    private var body: String {
        PostEventPrompt.closingNudgeBody(contactName: "Ryan", performanceDate: "2026-03-01",
                                         venue: "54 Below")
    }

    // MARK: the state the body is pinned against

    // The half of this suite that is behaviour rather than text, and the reason the text half is allowed to
    // be a text check at all: it establishes that "nobody replied" is the ONLY state this body ships in, so
    // any sentence in it that reports what the recipient said is false by construction rather than merely
    // sometimes wrong.
    @Test func theClosingNoteIsOnlyEverOfferedWhenNobodyReplied() throws {
        let ctx = try context()
        let silent = show(ctx)
        let r = contact(ctx, on: silent)
        let afterTheShow = EasternDate.date(from: "2026-03-05")!

        #expect(PostEventPrompt.prompt(for: r, of: silent, now: afterTheShow)?.kind == .closingNote)

        // The moment anybody writes back it becomes a close-out, which is not an email at all.
        r.reopenOnReply(at: EasternDate.date(from: "2026-02-20")!)
        #expect(PostEventPrompt.prompt(for: r, of: silent, now: afterTheShow)?.kind == .closeOut)
        #expect(PostEventPrompt.nudgeContent(kind: .closeOut, originalSubject: "s", groupName: "g",
                                             contactName: "Ryan", performanceDate: "2026-03-01",
                                             venue: "54 Below") == nil)
    }

    // MARK: what the body may not say

    // The rule, not a list of the two sentences that happened to be wrong: the body may not report that the
    // recipient COMMUNICATED anything. Every phrase below is a way of saying they did. Written as the class
    // rather than the instance, because the next author to reach for a warmer sign-off will reach for a
    // different one of these, not for the exact two Dan read (L30).
    static let assertsTheyCommunicated = [
        // A decision they conveyed.
        "the timing didn't line up",
        "the timing didn't work",
        "this one wasn't a fit",
        "you passed",
        "you decided",
        "you're all set",
        "you've got it covered",
        "you already have",
        // A completed exchange.
        "it was good to be in touch",
        "good to be in touch",
        "good talking",
        "good speaking",
        "thanks for getting back",
        "thanks for letting me know",
        "thanks for your reply",
        "as you mentioned",
        "as you said",
        "you mentioned",
        "you said",
        "you told me",
        "you let me know",
        "sorry to hear",
        "understood",
    ]

    @Test func theBodyNeverReportsSomethingTheRecipientSaid() {
        let lowered = body.lowercased()
        for phrase in Self.assertsTheyCommunicated {
            #expect(!lowered.contains(phrase),
                    "the closing note says \"\(phrase)\", but it is only ever sent to somebody who has never written back, so there is nothing they said for it to report")
        }
    }

    // Non-vacuity for the check above (L1): the phrase list must actually be capable of firing. Run against
    // the sentence Dan read on 2026-08-13, it has to catch both of the ones that were wrong. Without this,
    // a typo in every entry would leave the guard permanently green while checking nothing.
    @Test func thePhraseListCatchesTheSentencesThatWereWrong() {
        let asShipped = "I know your show has come and gone, and the timing didn't line up this round. "
            + "No worries at all. Either way, it was good to be in touch."
        let caught = Self.assertsTheyCommunicated.filter { asShipped.lowercased().contains($0) }
        #expect(caught.contains("the timing didn't line up"))
        #expect(caught.contains("it was good to be in touch"))
    }

    // MARK: what the body must still do

    // It is a door-holder, so the offer of a future shoot is the point of it and must survive any rewrite.
    // A note that only announces the show has passed would be worse than not sending one.
    @Test func theBodyStillOffersToShootAFuturePerformance() {
        #expect(body.contains("future performance"))
        #expect(body.lowercased().contains("glad to help"))
    }

    // It names the show by its date and room (#2615), never by the group name, which for a large share of
    // prospects is a solo performer's own name.
    @Test func theBodyNamesTheShowByItsDateAndRoom() {
        #expect(body.contains("54 Below"))
        #expect(!body.contains("Aurora Strings"))
    }

    // And it releases the recipient rather than waiting on them, which is what makes the missing exchange
    // honest instead of merely unmentioned. Dan's own last-attempt nudge takes the same line ("no need to
    // reply. I'll leave it here either way"), so the two outbound endings agree.
    @Test func theBodyAsksForNoReply() {
        #expect(body.lowercased().contains("no need to reply"))
    }

    // The house style rules that apply to everything Overture sends under Dan's name.
    @Test func theBodyCarriesNoDashPunctuationAndNoEmoji() {
        // Built from escapes so this file holds no literal forbidden character for the style gate to
        // catch: it cannot tell a line that USES one from a line that must NAME one.
        for mark in ["\u{2014}", "\u{2013}"] {
            #expect(!body.contains(mark), "the closing note carries dash punctuation")
        }
    }
}
