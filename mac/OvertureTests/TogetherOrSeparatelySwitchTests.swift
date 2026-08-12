import Testing
import Foundation
import SwiftData

// #2034, and the request the whole milestone came from. Dan, 2026-08-03, on the by-hand prep sheet:
//
//   "sometimes I don't want contacts to get a separate email. Can you allow me to email them together?
//    This applies to manual drafts and cold emails/ai drafts as well. I should have the option and it
//    should default to emailing them together."
//
// And, when shown that defaulting to together reverses the act-then-presenter ladder (#366/#368):
//
//   "Basically it's all or nothing. I want to have a selector that says email separately or together and
//    just choose the one I want for each event. It should default to together."
//
// So: one switch per event, in both places a draft is prepared, defaulting to together. The machinery is
// already there (#2031, #2033); this is the control that reaches it, and the line that stopped being true
// the moment together became the default.
@MainActor
@Suite("The together or separately switch (#2034)")
struct TogetherOrSeparatelySwitchTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, contacts: Int = 2) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora", discipline: "music", venue: "V",
                         performanceDate: "2026-12-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hello,\n\nI photograph performing arts."
        ctx.insert(p)
        let all = [("emma@org.example", "Emma"), ("noah@org.example", "Noah")].prefix(contacts)
            .map { Recipient(id: $0.0, email: $0.0, name: $0.1, provenance: .presenter) }
        for r in all { ctx.insert(r) }
        p.setRecipients(Array(all))
        try? ctx.save()
        return p
    }

    // MARK: - the control is offered where a choice exists

    // A choice between one email and one email is not a choice, and a control that does nothing is worse
    // than no control: he would wonder what it changed.
    @Test func theswitchIsOfferedOnlyWhenThereIsMoreThanOneContact() throws {
        let ctx = ModelContext(try container())

        #expect(QueueItem(show(ctx, contacts: 2)).offersSendModeChoice)
        #expect(QueueItem(show(ctx, contacts: 1)).offersSendModeChoice == false)
    }

    @Test func thecardShowsWhichWayTheEmailWillGo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        #expect(QueueItem(p).sendsTogether)
        p.sendsTogetherOverride = false
        #expect(QueueItem(p).sendsTogether == false)
    }

    // MARK: - flipping it is what the send reads

    // A stored setting no send path consults is a field that looks alive and does nothing (L46). This is
    // the one assertion that proves the control is wired to the behaviour rather than to itself.
    @Test func flippingTheSwitchChangesWhoTheNextEmailReaches() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let item = QueueItem(p)

        ProspectMutations.setSendsTogether(item, false, prospects: [p], context: ctx,
                                           feedback: ActionFeedback())
        #expect(SendGroup.pendingGroup(of: p).count == 1)

        ProspectMutations.setSendsTogether(item, true, prospects: [p], context: ctx,
                                           feedback: ActionFeedback())
        #expect(SendGroup.pendingGroup(of: p).count == 2)
    }

    @Test func thesettingSurvivesBeingSaved() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        ProspectMutations.setSendsTogether(QueueItem(p), false, prospects: [p], context: ctx,
                                           feedback: ActionFeedback())
        let reread = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)

        #expect(reread.sendsTogether == false)
    }

    // MARK: - the by-hand sheet

    // The line under the address field promised each contact its own email. That became a false statement
    // the moment together became the default, and it is the sentence Dan was reading when he asked for
    // this (L21: copy is a contract).
    @Test func thebyHandSheetStatesTheCountAndLeavesTheModeToTheSwitch() {
        let note = ManualPrepCopy.recipientCountNote(for: "a@x.org, b@y.org")

        #expect(note?.contains("2") == true)
        // The switch sits directly beside this line and says which way it goes out, so a line saying it
        // too would be the same sentence twice (#843).
        #expect(note?.contains("separate") == false)
        #expect(note?.contains("share one") == false)
    }

    // One address is not a choice on this sheet either, so it says nothing about it rather than saying
    // something true and useless (#843).
    @Test func thebyHandSheetSaysNothingForOneAddress() {
        #expect(ManualPrepCopy.recipientCountNote(for: "a@x.org") == nil)
    }

    // A hand-written draft to two people defaults to together, the same as an AI-drafted one, because his
    // request covered both: "This applies to manual drafts and cold emails/ai drafts as well."
    @Test func ahandPreppedShowDefaultsToTogetherAndCanBePreppedSeparately() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: 0)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: "a@x.org, b@y.org", name: nil,
                                       subject: "S", body: "Body", sendsTogether: true,
                                       prospects: [p], context: ctx, feedback: feedback)
        #expect(p.sendsTogether)

        ProspectMutations.prepManually(QueueItem(p), email: "a@x.org, b@y.org", name: nil,
                                       subject: "S", body: "Body", sendsTogether: false,
                                       prospects: [p], context: ctx, feedback: feedback)
        #expect(p.sendsTogether == false)
    }
}
