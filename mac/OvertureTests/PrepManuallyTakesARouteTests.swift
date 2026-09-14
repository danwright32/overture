import Testing
import Foundation
import SwiftData

// #2896. "Prep manually" is the control for writing a pitch yourself with no Prep run and no AI draft.
// Its recipient field accepted an email address and nothing else, so on a show whose only route is a
// contact form or a social profile, the one path that skips the AI entirely was the one path that could
// not take the show's route. A pasted profile or form URL read as `.invalid`, Save draft stayed
// disabled, and the reason beside it said the address was bad. It is not a bad address. It is a route,
// and since #2612 it is a route Dan uses by hand.
//
// THIS IS #2629 ONE CONTROL OVER. That issue fixed exactly this on Add contact and built
// `ManualContactRoute` as the one place that decides what Dan can type as a route. This sheet was not
// moved onto it, so the two controls disagreed about what a contact is (L263, L30).
//
// WHAT A SAVED MANUAL PREP MEANS FOR A LINK, decided explicitly rather than left to fall out. Dan's
// call, 2026-09-06: the saved draft is the text he pastes, and it feeds the EXISTING form-pitch flow
// (`FormOutreach`, #2612), where he opens their form or profile, writes there, and marks it sent. It
// never enters the send path, and that is structural rather than a rule: `isSendablePending` requires an
// address, so a link recipient cannot be emailed by any route.
@MainActor
@Suite("Prep manually takes a route, not only an address (#2896)")
struct PrepManuallyTakesARouteTests {

    // MARK: - what the sheet refuses

    @Test func aContactFormLinkIsAcceptedWhereItUsedToBeCalledABadAddress() {
        #expect(ManualPrepEditing.refusalKind(email: "https://kestrelquartet.example/contact",
                                              subject: "s", body: "b") == nil)
        // Bare, the way it is pasted out of a browser bar, and a social profile too (#2612).
        #expect(ManualPrepEditing.refusalKind(email: "instagram.com/kestrelquartet",
                                              subject: "s", body: "b") == nil)
    }

    @Test func anAddressIsStillAccepted() {
        #expect(ManualPrepEditing.refusalKind(email: "booking@kestrelquartet.example",
                                              subject: "s", body: "b") == nil)
        // Several, which is what this sheet has always taken and what Add contact deliberately does not.
        #expect(ManualPrepEditing.refusalKind(email: "a@kestrelquartet.example, b@kestrelquartet.example",
                                              subject: "s", body: "b") == nil)
    }

    // Everything that is neither is still refused, and the REFUSAL NOW NAMES BOTH KINDS. The old sentence
    // sent Dan looking for an address on a show that does not have one, which is the instruction that
    // cannot be followed (#2629's own words).
    @Test func somethingThatIsNeitherIsRefusedAndTheReasonNamesBothKinds() {
        let refusal = ManualPrepEditing.refusalKind(email: "not a route", subject: "s", body: "b")
        #expect(refusal == .badRoute("not a route"))
        #expect(refusal?.reason.contains("email address or a link") == true)
        #expect(refusal?.acknowledgement.contains("email address or a link") == true)
    }

    @Test func anEmptyFieldStillAsksForARecipient() {
        #expect(ManualPrepEditing.refusalKind(email: "  ", subject: "s", body: "b") == .needsRecipient)
    }

    // A blank between two separators keeps its own sentence, which is a different fault from a bad piece
    // and reads differently (L11).
    @Test func aBlankBetweenSeparatorsKeepsItsOwnSentence() {
        #expect(ManualPrepEditing.refusalKind(email: "a@kestrelquartet.example,,b@kestrelquartet.example",
                                              subject: "s", body: "b") == .extraSeparator)
    }

    // The subject and body rules are untouched, and still refused in the order the fields sit on the
    // sheet, so the sentence names the first thing Dan would look at.
    @Test func theOtherFieldsAreUnchangedAndStillRefusedInSheetOrder() {
        #expect(ManualPrepEditing.refusalKind(email: "instagram.com/kestrelquartet",
                                              subject: " ", body: "b") == .needsSubject)
        #expect(ManualPrepEditing.refusalKind(email: "instagram.com/kestrelquartet",
                                              subject: "s", body: " ") == .needsBody)
    }

    // MARK: - what saving one does

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Kestrel Quartet",
                                          performanceDate: "2027-10-03", venue: "Rowan Hall")
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-10-03", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 20, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func item(_ p: Prospect) -> QueueItem {
        QueueItem(id: p.naturalKey, groupName: p.groupName, discipline: "music", venue: p.venue,
                  performanceDate: p.performanceDate, sourceListingURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 20, tier: "high", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                  status: .queued)
    }

    @Test func savingWithALinkStoresTheRouteAndTheDraft() throws {
        let ctx = try context()
        let p = show(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(item(p), email: "instagram.com/kestrelquartet", name: nil,
                                       subject: "Photographing your show", body: "Hello, ...",
                                       prospects: [p], context: ctx, feedback: feedback)

        let contact = try #require(p.recipients.first)
        // Stored on the SAME field the reachability check writes for a form-only or social-only contact,
        // so a hand-added route and a found one are the same thing to every reader downstream.
        #expect(contact.contactFormURL == "https://instagram.com/kestrelquartet")
        #expect(contact.email == nil)
        #expect(p.draftBody == "Hello, ...")
        #expect(p.status == .drafted)
    }

    // The half that makes the decision structural rather than a rule: there is nothing to send, and no
    // path can send it. `isSendablePending` requires an address, so a link recipient is never in a send
    // group and can never be emailed by the queue, the batch, or the picker (L42, fail closed).
    @Test func aLinkRecipientCanNeverBeEmailed() throws {
        let ctx = try context()
        let p = show(ctx)
        ProspectMutations.prepManually(item(p), email: "kestrelquartet.example/contact", name: nil,
                                       subject: "s", body: "b", prospects: [p], context: ctx,
                                       feedback: ActionFeedback())
        p.status = .approved
        #expect(SendService.nextPendingRecipient(for: p) == nil)
        #expect(SendGroup.pendingGroup(of: p).isEmpty)
    }

    // And the flow it DOES feed. The show's own verdict recomputes to a hand route, which is what makes
    // `FormOutreach` available: Dan opens the profile, writes there, and marks it sent.
    @Test func aSavedLinkPrepOpensTheFormPitchFlow() throws {
        let ctx = try context()
        let p = show(ctx)
        ProspectMutations.prepManually(item(p), email: "instagram.com/kestrelquartet", name: nil,
                                       subject: "s", body: "b", prospects: [p], context: ctx,
                                       feedback: ActionFeedback())
        #expect(p.reachabilityResultFromRecipients == .socialOnly)
        #expect(FormPitch.state(of: p) != .unavailable,
                Comment(rawValue: "the draft is saved and there is no way to record that he sent it, so "
                        + "the show reads as never reached out to and nothing watches for a reply"))
    }

    @Test func savingWithAnAddressIsUnchanged() throws {
        let ctx = try context()
        let p = show(ctx)
        ProspectMutations.prepManually(item(p), email: "booking@kestrelquartet.example", name: "Wren",
                                       subject: "s", body: "b", prospects: [p], context: ctx,
                                       feedback: ActionFeedback())
        let contact = try #require(p.recipients.first)
        #expect(contact.email == "booking@kestrelquartet.example")
        #expect(contact.name == "Wren")
        #expect(contact.contactFormURL == nil)
    }

    // MARK: - the class (L96, derived rather than remembered)

    // Every surface that takes a recipient as TYPED input goes through `ManualContactRoute`. Add contact
    // has since #2629, this sheet does now, and this is what keeps a third one from arriving that reads
    // the field with a bare `EmailAddressList` and disagrees with both about what a contact is.
    @Test func noHandTypedRecipientIsReadAsAnAddressOnly() {
        let offenders = AppSourceWalk.appFiles()
            .filter { file in
                guard file.name != "ManualContactRoute.swift", file.name != "EmailAddressList.swift"
                else { return false }
                let lines = SwiftSource.scannableLines(in: file.text)
                // A file that reads the address list AND never asks for a route is one that decided
                // what a hand-typed contact is on its own.
                let readsAddresses = lines.contains { $0.code.contains("EmailAddressList.parse") }
                let asksForARoute = lines.contains { $0.code.contains("ManualContactRoute") }
                return readsAddresses && !asksForARoute
            }
            .map(\.name).sorted()
        #expect(offenders.isEmpty, Comment(rawValue:
            "these read a hand-typed recipient as addresses only, so they and Add contact disagree about "
            + "what a contact is, which is the defect #2896 fixed on the manual prep sheet: "
            + offenders.joined(separator: ", ")))
    }
}
