import Testing
import Foundation
import SwiftData

// #4170: a show Dan has already pitched had no way to reach a DIFFERENT person.
//
// THE CASE, reported 2026-09-22. He pitched Dessoff Choirs' "Symphony in Motion" to Kimberley Cohan.
// Her autoresponse said she is on maternity leave and named somebody else to write to. The show is on
// Reached out, and every path to a new contact was closed: the hand-added field lives inside
// `DraftReviewView` (drawn only under `hasDraft`, on the review card he no longer has) and in
// `ProspectRowView` (drawn only where the reachability badge asks for one), "Close this out" offers
// only endings, and `ReplyPanel.saveWriterAsContact` covers the person who WROTE rather than the
// person named inside the message. The workaround was to email from Gmail by hand and leave the show
// open, with that thread tracked nowhere.
//
// DAN'S TWO CALLS, 2026-09-23, asked with the alternatives in front of him:
//   - the control lives UNDER the "Close this out" menu, on every sent row, never gated on Overture
//     recognising an autoresponse (which it cannot do reliably: `ReplyDetection.isAutomated` matches
//     only a sender's local part);
//   - the new contact gets an ORDINARY first contact draft, so nothing here has to carry who
//     redirected him into the prompt.
//
// WHAT THAT NEEDS FROM THE DOMAIN. A sent show is `.contacted`, and `PrepQueueBuilder.needsPrep` deliberately
// refuses to re-prep one. That refusal is right for a show nobody asked about and wrong for this: the
// request is Dan's, the draft it rewrites has already gone and is frozen elsewhere, and the contact it
// is for was typed in a moment ago.
@MainActor
@Suite("Pitching somebody else on a show already sent (#4170)")
struct APitchToSomebodyElseTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func sentShow(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "symphony in motion|2026-11-01|church of the ascension",
                         groupName: "Symphony in Motion", discipline: "choral",
                         venue: "Church of the Ascension", performanceDate: "2026-11-01",
                         sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7,
                         tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.draftSubject = "Photographing Symphony in Motion"
        p.draftBody = "Hi Kimberley,\n..."
        p.sentSubject = p.draftSubject
        p.sentBody = p.draftBody
        ctx.insert(p)
        let sent = Recipient(id: "kimberley.cohan@example.org", email: "kimberley.cohan@example.org",
                             name: "Kimberley Cohan", provenance: .presenter)
        sent.sendState = .sent
        sent.sentAt = Date(timeIntervalSince1970: 1_758_000_000)
        sent.gmailMessageId = "msg-1"
        p.setRecipients([sent])
        try? ctx.save()
        return p
    }

    // THE DOMAIN RULE. A sent show Dan has asked for a fresh draft on is prepped again; one nobody
    // asked about is not, which is the refusal that has always been there and is not weakened.
    @Test func asentShowIsPreppedAgainOnlyWhenTheReDraftWasAskedFor() {
        #expect(PrepQueueBuilder.needsPrep(status: .contacted, hasDraft: true, reprepDraftRequested: true, lastNightHasPassed: false),
                "a sent show Dan asked for a new draft on cannot reach the prep queue at all")
        #expect(!PrepQueueBuilder.needsPrep(status: .contacted, hasDraft: true, lastNightHasPassed: false),
                "an ordinary sent show became prep eligible, which spends money nobody asked for")
        #expect(!PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: true, reprepDraftRequested: true, lastNightHasPassed: false),
                "a dismissed show is still refused, whatever flag it carries")
    }

    // THE ACTION. The route is added as a pending contact and the show asks for a DRAFT only: the
    // contact research half is exactly what Dan has just done by hand, so paying for it again would be
    // spending on an answer he supplied.
    @Test func addingSomebodyElseMakesThemPendingAndAsksForADraft() throws {
        let ctx = try context()
        let show = sentShow(ctx)

        ProspectMutations.pitchSomeoneElse(show, route: "ben.tucker@example.org", name: "Ben Tucker",
                                           context: ctx, feedback: ActionFeedback())

        let added = try #require(show.recipients.first { $0.email == "ben.tucker@example.org" })
        #expect(added.sendState == .pending)
        #expect(added.sentAt == nil)
        #expect(show.reprepDraftRequested, "the show never asked for the draft this contact needs")
        #expect(!show.reprepContactsRequested,
                "it asked for a contact hunt as well, which is the answer Dan just typed in")
        #expect(PrepQueueBuilder.needsPrepEligible(show, today: "2026-09-24"),
                "the show is not in the prep queue, so no draft is ever written for the new contact")
    }

    // AND THE ORIGINAL CONTACT IS UNTOUCHED. She is away rather than declining: her thread stays
    // recorded, stays on Reached out, and nothing here ends it or marks it lost.
    @Test func theoriginalContactKeepsItsPlaceOnReachedOut() throws {
        let ctx = try context()
        let show = sentShow(ctx)
        let original = try #require(show.recipients.first)
        #expect(ReachedOutQueue.isInPlay(original, of: show), "the fixture is not on Reached out to start with")

        ProspectMutations.pitchSomeoneElse(show, route: "ben.tucker@example.org", name: "Ben Tucker",
                                           context: ctx, feedback: ActionFeedback())

        #expect(ReachedOutQueue.isInPlay(original, of: show),
                "adding a second contact took the first one's conversation off the stage")
        #expect(original.sendState == .sent)
        #expect(original.resolution == nil, "the original contact was marked resolved by a redirect")
    }

    // WHAT THE NEW DRAFT MAY OVERWRITE. The prep run rewrites the show's draft box, which still holds
    // the text that went to the first contact, so this asserts the record of that send is somewhere
    // else: `sentSubject` and `sentBody` are frozen at the first send and are what voice learning and
    // the archive read (L5, nothing good is destroyed before its replacement exists).
    @Test func thepitchThatAlreadyWentIsNotKeptInTheDraftBox() throws {
        let ctx = try context()
        let show = sentShow(ctx)
        let wasSent = show.sentBody

        ProspectMutations.pitchSomeoneElse(show, route: "ben.tucker@example.org", name: "Ben Tucker",
                                           context: ctx, feedback: ActionFeedback())
        // What the prep importer will do when the run comes back.
        show.draftSubject = "Photographing your November concert"
        show.draftBody = "Hi Ben,\n..."
        try ctx.save()

        #expect(show.sentBody == wasSent,
                "the text that went to the first contact lived only in the draft box and is now gone")
        #expect(show.sentSubject == "Photographing Symphony in Motion")
    }

    // WHERE THE CONTROL LIVES, which is Dan's call and is the half no domain test can see: inside
    // `CloseOutMenu`, under the separator, beside the reply link rather than as a fifth ending. Asked of
    // the source for the same reason #3707's own guard is: a Menu spelled out at the call site would put
    // its buttons into the reached-out row's trailing column, where `ReachedOutRowSlots` counts them, so
    // a person would see one control and the guard would count several.
    @Test func thecontrolIsInTheCloseOutMenuUnderTheSeparator() {
        let menu = SourceGuardHelper.source("Overture/UI/CloseOutMenu.swift")
        #expect(!menu.isEmpty)
        // Asked as booleans rather than `#expect(source.contains(...))`, because a failing expectation
        // renders its operands and the operand here is a whole file (L445).
        let offersTheItem = menu.contains("RePitchCopy.menuLabel")
        let separatesIt = menu.contains("Divider()")
        #expect(offersTheItem, "the pitch-someone-else item is not in the menu at all")
        #expect(separatesIt, "the item is not separated from the endings, so it reads as one of them")

        let row = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(row.contains("onPitchSomeoneElse:"),
                "the reached-out row never passes the item, so the menu draws it nowhere")
    }

    // A ROUTE IT CANNOT USE changes nothing at all: no contact, no prep request, no spend.
    @Test func atypedNonRouteAddsNothingAndAsksForNothing() throws {
        let ctx = try context()
        let show = sentShow(ctx)

        ProspectMutations.pitchSomeoneElse(show, route: "not an address", name: nil,
                                           context: ctx, feedback: ActionFeedback())

        #expect(show.recipients.count == 1)
        #expect(!show.reprepDraftRequested,
                "a show was queued for a paid run over a route it never accepted")
    }
}
