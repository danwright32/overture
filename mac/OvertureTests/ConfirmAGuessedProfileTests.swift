import Testing
import Foundation
import SwiftData

// #2937. Since #2912 the card shows a social handle the check found BY NAME and could not tie to the
// show. Dan looks at it, and the whole point is that he decides: if he recognises the person he sends the
// DM by hand. There was nowhere to tell Overture he did.
//
// `FormPitch` is what records outreach Gmail never touched (copy the draft, open their profile, mark it
// sent), and it is gated on the show's verdict being `contactFormOnly` or `socialOnly`. A name match is
// deliberately excluded from `Prospect.socialRouteURLs`, so such a show's verdict is `noEmailFound` and
// the control is unavailable. That exclusion is CORRECT and is what keeps #2147 intact: the app must not
// CLAIM a route it cannot tie to anybody.
//
// What was missing is DAN'S ANSWER, not a looser verdict. Confirming clears the doubt on that one row,
// and everything else follows for free, because all four readers ask the same list: the profile rejoins
// `socialRouteURLs`, the verdict becomes `socialOnly`, the pill says so, and the record-a-DM path opens.
//
// HIS ANSWER SURVIVES A RE-CHECK, which is the first thing #2937 says has to be decided. `nameMatchOnly`
// is deliberately re-derived on every ingest rather than latched (#2912), so a later run that still
// cannot tie the account to the show would put the doubt back and take his answer with it. A separate
// `...Dismissed` field is how the four contact guards already solve exactly this, and it is the answer
// here too.
@MainActor
@Suite("Confirming a guessed profile is the right person (#2937)")
struct ConfirmAGuessedProfileTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let handle = "https://instagram.com/kestrelquartet"

    @discardableResult
    private func show(_ ctx: ModelContext, nameMatchOnly: Bool = true) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet",
                                          performanceDate: "2027-10-03", venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-10-03", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        let r = Recipient(id: "form:" + handle, email: nil, name: "Wren Ashby", role: nil,
                          provenance: .performer, contactMethodRaw: "form_or_dm",
                          contactConfidenceRaw: "low", contactFormURL: handle, contactSourceURL: nil)
        r.nameMatchOnly = nameMatchOnly
        p.addRecipient(r)
        try? ctx.save()
        return p
    }

    // The state before he answers, which is #2912's and is unchanged.
    @Test func anUnconfirmedGuessIsStillNotARouteTheAppClaims() throws {
        let ctx = try context()
        let p = show(ctx)
        #expect(p.socialRouteURLs.isEmpty)
        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
        #expect(FormPitch.state(of: p) == .unavailable)
    }

    // His answer, and everything that follows from it. Four readers, one list, so confirming is one write.
    @Test func confirmingItMakesTheShowReachableAndOpensTheDmPath() throws {
        let ctx = try context()
        let p = show(ctx)

        ProspectMutations.confirmGuessedProfile(QueueItem(p), "form:" + handle,
                                                prospects: [p], context: ctx,
                                                feedback: ActionFeedback())

        #expect(p.socialRouteURLs == [handle])
        #expect(p.reachabilityResultFromRecipients == .socialOnly)
        #expect(FormPitch.state(of: p) != .unavailable)
    }

    // The decision #2937 asks for first: his answer survives a later run that still cannot tie the
    // account to the show. `nameMatchOnly` is re-derived on every ingest by design, so without a separate
    // field the next check would take his answer with it.
    @Test func hisAnswerSurvivesARecheckThatStillCannotTieTheAccountToTheShow() throws {
        let ctx = try context()
        let p = show(ctx)
        ProspectMutations.confirmGuessedProfile(QueueItem(p), "form:" + handle,
                                                prospects: [p], context: ctx, feedback: ActionFeedback())

        var c = PrepContact()
        c.name = "Wren Ashby"
        c.method = "form_or_dm"
        c.confidence = "low"
        c.provenance = "performer"
        c.formUrl = handle
        c.nameMatchOnly = true      // the run still cannot tie it
        PrepImporter.ingest(PrepResults(version: 12, generatedAt: "2027-09-01T00:00:00Z",
                                        results: [PrepResult(naturalKey: p.naturalKey, contacts: [c])]),
                            into: ctx, isProbe: true)

        let r = try #require(p.recipients.first)
        #expect(r.nameMatchOnly, Comment(rawValue:
            "the run's own doubt is re-derived and still stands, as #2912 requires"))
        #expect(r.nameMatchOnlyDismissed, Comment(rawValue:
            "Dan's answer is his, so a re-check may not take it"))
        #expect(p.socialRouteURLs == [handle])
    }

    // The card stops saying the profile is unconfirmed once he has said it is not, which is the whole
    // point of answering: a doubt that stays on screen after it is settled teaches him to ignore the line
    // (L269).
    @Test func theCardStopsMarkingAProfileHeHasConfirmed() throws {
        let ctx = try context()
        let p = show(ctx)
        let before = QueueItem(p).displayedContactRoutes().map(\.isNameMatchOnly)
        #expect(before == [true])

        ProspectMutations.confirmGuessedProfile(QueueItem(p), "form:" + handle,
                                                prospects: [p], context: ctx, feedback: ActionFeedback())
        let after = QueueItem(p).displayedContactRoutes().map(\.isNameMatchOnly)
        #expect(after == [false])
    }

    // A profile nobody ever doubted has nothing to confirm, so the control is not offered on it. Without
    // this the row would carry a control that changes nothing, which reads as a decision Dan has to make
    // about every handle on every card.
    @Test func aProfileNobodyDoubtedOffersNothingToConfirm() throws {
        let ctx = try context()
        let p = show(ctx, nameMatchOnly: false)
        #expect(QueueItem(p).displayedContactRoutes().map(\.offersConfirmation) == [false])
    }

    // Wired, not merely built: the mutation is reachable and its own tests would stay green while no
    // control on any screen ever called it (L3). Asserted on the SOURCE, because the row is SwiftUI
    // and this is the connection a runtime test of the model cannot see.
    @Test func theRouteLineOffersTheControlAndItIsWiredToTheMutation() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(!row.isEmpty)
        #expect(SourceGuardHelper.containsCode("route.offersConfirmation", in: row),
                "the route line never offers the control, so a guess can only ever stay a guess")
        #expect(SourceGuardHelper.containsCode("onConfirmGuessedProfile(id)", in: row),
                "the control is drawn and calls nothing")

        let factory = SourceGuardHelper.source("Overture/UI/ProspectRowFactory.swift")
        #expect(!factory.isEmpty)
        #expect(SourceGuardHelper.containsCode("ProspectMutations.confirmGuessedProfile(", in: factory),
                "the row takes his answer and hands it to nothing, so nothing is ever written")
    }

    @Test func aguessOffersTheConfirmation() throws {
        let ctx = try context()
        let p = show(ctx)
        let route = try #require(QueueItem(p).displayedContactRoutes().first)
        #expect(route.offersConfirmation)
        #expect(route.recipientId == "form:" + handle)
    }
}
