import Testing
import Foundation
import SwiftData

// #4208: pressing "Draft with AI" on a reply that already has a draft did nothing at all.
//
// Two faults stacked. The drafter's eligibility rule refused a contact that already held a draft unless
// their newest message postdated the request, and the press had just stamped the request, so it could
// never qualify. The refusal came back as a thrown `nothingToClassify` that `launchReplyDrafter` threw
// away with `try?`. And the screen's own "is a draft under way" reading treats any draft on file as
// "nothing awaited", so no Drafting label appeared either. Measured on Dan's store, 2026-09-24: the press
// landed at 11:53:27, the 261 character draft stayed, and no queue file was written after 10:18.
@MainActor
@Suite("Draft with AI replaces a draft already on file, and says so when it cannot start (#4208)")
struct RedraftWithAITests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private static let oldDraft = "Hi Alan, understood. Break a leg with the run!"
    private static let earlierRequest = Date(timeIntervalSince1970: 1_790_000_000)

    // A show whose contact replied and already holds an AI draft of the answer, the state on screen in
    // the report: requested earlier, landed, untouched by Dan.
    @discardableResult
    private func showWithAIDraft(_ ctx: ModelContext, key: String = "luigi",
                                 address: String = "alan@x.org") -> Recipient {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "theater", venue: "V",
                         performanceDate: "2026-11-09", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.replied = true
        r.lastReplyText = "We have no plans for photos as of yet!"
        r.replyDraftRequestedAt = Self.earlierRequest
        r.replyDraftBody = Self.oldDraft
        p.addRecipient(r)
        return r
    }

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("redraft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The report itself, driven through the REAL launcher and the real `startClassify` down to the queue
    // file, because the refusal happened below the seam every other draft test stops at (L3).
    @Test func pressingDraftWithAIOnADraftAlreadyOnFileQueuesThatConversation() throws {
        let ctx = ModelContext(try container())
        showWithAIDraft(ctx)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queueURL = dir.appendingPathComponent("queue.json")
        let feedback = ActionFeedback()

        ProspectMutations.draftReply("luigi", "alan@x.org",
                                     prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     context: ctx, feedback: feedback,
                                     start: { context, target in
                                         try ProspectMutations.launchReplyDrafter(
                                             context, target, queueURL: queueURL,
                                             markerURL: dir.appendingPathComponent("marker"),
                                             cancelURL: dir.appendingPathComponent("cancel"),
                                             launch: { }, announce: { })
                                     })

        let written = try #require(try? Data(contentsOf: queueURL),
                                   "pressing Draft with AI on a reply that already had a draft queued nothing, so the button did nothing (#4208)")
        let queue = try JSONDecoder().decode(ReplyClassifyQueue.self, from: written)
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.recipientId == "alan@x.org")
        #expect(feedback.message == nil, "a launch that started must not report a refusal")
    }

    // While the replacement is being written the screen says so, and the draft he already had stays on
    // file until the new one lands, so a run that fails costs him nothing (L5).
    @Test func aRedraftReadsAsUnderWayAndKeepsTheOldDraftUntilTheNewOneLands() throws {
        let ctx = ModelContext(try container())
        let r = showWithAIDraft(ctx)

        ProspectMutations.draftReply("luigi", "alan@x.org",
                                     prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     context: ctx, feedback: ActionFeedback(), start: { _, _ in })

        #expect(ReplyPanel.isDrafting(r), "a redraft under way drew no Drafting label (#4208)")
        #expect(r.replyDraftBody == Self.oldDraft, "the draft on file must survive until its replacement exists")

        let landed = ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "luigi", intent: "not_now", recipientId: "alan@x.org",
                                draftBody: "A fresh draft."),
        ])
        ReplyClassifyImporter.ingest(landed, into: ctx)

        #expect(r.replyDraftBody == "A fresh draft.")
        #expect(!ReplyPanel.isDrafting(r), "once the new draft lands, nothing is awaited")
        #expect(!ReplyClassifyService.recipientNeedsClassify(r),
                "a redraft that has landed must not be drafted again by the next press's queue")
    }

    // A draft on file that nobody asked to replace is still left alone: the flag is what makes the
    // difference, never the draft's mere presence.
    @Test func aDraftOnFileWithNoRedraftRequestIsNotRedrafted() throws {
        let ctx = ModelContext(try container())
        let r = showWithAIDraft(ctx)
        #expect(!ReplyClassifyService.recipientNeedsClassify(r))
        #expect(!ReplyPanel.isDrafting(r))
    }

    // A redraft whose result is skipped because Dan's own words are on file has still finished, so it
    // must not read as drafting for ever.
    @Test func aRedraftSkippedForDansOwnWordsStopsReadingAsUnderWay() throws {
        let ctx = ModelContext(try container())
        let r = showWithAIDraft(ctx)
        ProspectMutations.draftReply("luigi", "alan@x.org",
                                     prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     context: ctx, feedback: ActionFeedback(), start: { _, _ in })
        r.applyReplyDraftEdit("My own answer.")

        ReplyClassifyImporter.ingest(ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "luigi", intent: "not_now", recipientId: "alan@x.org",
                                draftBody: "An AI draft."),
        ]), into: ctx)

        #expect(r.replyDraftBody == "My own answer.")
        #expect(!ReplyPanel.isDrafting(r))
    }

    // Every refusal the launcher can raise reaches Dan, in a sentence naming why, and a press that
    // started nothing leaves the request stamp where it was: that stamp is what tells a newer message
    // from them apart from the draft on file, so moving it on a refused press hides that message.
    @Test(arguments: [
        ReplyClassifyService.ClassifyLaunchError.alreadyRunning,
        ReplyClassifyService.ClassifyLaunchError.nothingToClassify,
        ReplyClassifyService.ClassifyLaunchError.runnerUnavailable("The runner script is missing."),
    ])
    func aRefusedLaunchIsReportedAndRestoresTheRequest(_ refusal: ReplyClassifyService.ClassifyLaunchError) throws {
        let ctx = ModelContext(try container())
        let r = showWithAIDraft(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.draftReply("luigi", "alan@x.org",
                                     prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     context: ctx, feedback: feedback,
                                     start: { _, _ in throw refusal })

        #expect(feedback.message == ReplyPanelCopy.draftNotStarted(refusal),
                "a refused Draft with AI said nothing, which is the whole of #4208")
        #expect(feedback.tone == .warning)
        #expect(r.replyDraftRequestedAt == Self.earlierRequest,
                "a press that started nothing moved the request stamp")
        #expect(!ReplyPanel.isDrafting(r), "a press that started nothing must not read as drafting")
    }

    // The sentence names the cause rather than restating the error's own wording, which talks about
    // classifying rather than drafting.
    @Test func eachRefusalHasItsOwnSentence() {
        let sentences = [
            ReplyPanelCopy.draftNotStarted(ReplyClassifyService.ClassifyLaunchError.alreadyRunning),
            ReplyPanelCopy.draftNotStarted(ReplyClassifyService.ClassifyLaunchError.nothingToClassify),
            ReplyPanelCopy.draftNotStarted(ReplyClassifyService.ClassifyLaunchError.runnerUnavailable("Missing runner.")),
            ReplyPanelCopy.draftNotStarted(CocoaError(.fileWriteNoPermission)),
        ]
        #expect(Set(sentences).count == sentences.count)
        #expect(sentences[2].contains("Missing runner."))
        #expect(!sentences.contains { $0.localizedCaseInsensitiveContains("classif") })
    }

    // The refusal is said through the shared banner, and the reply screen is a sheet, which on macOS is its
    // own window: the main window's banner is drawn behind it (#285). It is also the one sheet that
    // acknowledges while it stays open (saving a writer, taking an address off), so without its own banner
    // every one of those sentences was drawn where Dan could not see it.
    @Test func theReplySheetCarriesItsOwnFeedbackBanner() {
        #expect(SourceGuardHelper.source("Overture/UI/ReplySheet.swift").contains(".actionFeedbackBanner(composition.feedback)"),
                "a refused Draft with AI would be announced behind the reply sheet, which is the silence #4208 fixed")
    }
}
