import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #846: the model behind a draft was RECORDED by #804 and shown nowhere, so Dan could not read it.
//
// That record is not bookkeeping, it is the other half of a decision. He pinned drafting to the strong
// TIER rather than an exact version, so he picks up each new Opus as it ships and accepts that his email
// voice can shift with it. That trade is only reasonable BECAUSE the model is recorded: on the day an
// email reads wrong he can check whether the model changed underneath him, instead of sensing that
// something did and having no way to confirm it. Until it is on screen, the trade he agreed to is not
// actually available to him.
//
// The RULE (what the trace says, and when there is one) is a pure function, never computed inside the
// SwiftUI body: #863 is the standing lesson here, a rule stated in a comment and computed in a view
// drifted twice while the suite stayed green. Same reason RecipientSnapshot.contactSourceLinkURL lives
// beside the data rather than in the row.
@MainActor
@Suite("A draft shows what wrote it (#846)")
struct DraftModelTraceDisplayTests {

    // --- The rule, in isolation ----------------------------------------------------------------

    @Test func aDraftWithAModelSaysWhatWroteIt() {
        #expect(DraftTrace.label(for: "opus") == "Drafted by opus")
    }

    // A draft from before #804, or one whose stamp failed to write, simply carries no trace. It must
    // never render a half-sentence ("Drafted by") naming nothing.
    @Test func aDraftWithNoModelShowsNoTrace() {
        #expect(DraftTrace.label(for: nil) == nil)
    }

    // record_model degrading to an empty stamp is the same case as no stamp at all: say nothing.
    @Test func anEmptyOrBlankStampIsTreatedAsNoTraceAtAll() {
        #expect(DraftTrace.label(for: "") == nil)
        #expect(DraftTrace.label(for: "   ") == nil)
    }

    // --- The outreach draft --------------------------------------------------------------------

    private func item(draftModel: String?, contacts: [RecipientSnapshot] = []) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music",
                          venue: "Weill Recital Hall", performanceDate: "2026-08-01",
                          sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                          production: "self", profile: "strong", coverage: "likely_uncovered",
                          fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                          possibleMatchSource: nil, possibleMatchName: nil, status: .drafted,
                          draftSubject: "Photographs of your concert",
                          draftBody: "Hello, I photograph performances.")
        i.draftModel = draftModel
        i.contacts = contacts
        return i
    }

    private func texts(_ view: DraftReviewView) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func view(_ i: QueueItem) -> DraftReviewView {
        DraftReviewView(item: i, onUnapprove: {}, onSaveDraft: { _, _ in },
                        outboundSendSince: nil)
    }

    @Test func theOutreachDraftShowsTheModelThatWroteIt() throws {
        #expect(try texts(view(item(draftModel: "opus"))).contains("Drafted by opus"))
    }

    @Test func anOutreachDraftWithNoTraceSaysNothingAboutAModel() throws {
        #expect(try texts(view(item(draftModel: nil))).allSatisfy { !$0.hasPrefix("Drafted by") })
    }

    // Dan's call (2026-07-13): "Edited" and the trace stay SEPARATE tags. The trace names what wrote the
    // text he then edited (PrepImporter deliberately preserves it), so both facts are true at once and
    // both must be readable.
    @Test func aDraftDanEditedShowsBothThatHeEditedItAndWhatOriginallyWroteIt() throws {
        var i = item(draftModel: "opus")
        i.draftEditedByDan = true

        let t = try texts(view(i))
        #expect(t.contains("Edited"))
        #expect(t.contains("Drafted by opus"))
    }

    // --- The reply draft -----------------------------------------------------------------------
    //
    // #874's lesson, applied: the reply run is a DRAFTER too, and forgetting that is exactly how it spent
    // months on the cheap model. Its stamp was already being written to disk and thrown away on import.

    private func contact(replyDraftModel: String?) -> RecipientSnapshot {
        var c = RecipientSnapshot(id: "r1", name: "Ada Reyes", email: "ada@aurora.org", role: "GM",
                                  provenance: .presenter, sendState: .sent, replied: true,
                                  lastReplyText: "We would love to talk.", resolution: nil,
                                  bounced: false, outcomeSource: nil)
        c.replyDraftSubject = "Re: Photographs of your concert"
        c.replyDraftBody = "Thanks for writing back."
        c.replyDraftModel = replyDraftModel
        // #2934: the case this suite is about is a reply still owed an answer, which is what puts the
        // draft on screen with its controls. Said rather than inherited from a default: the default is
        // the quiet direction, and a fixture that does not declare it is describing the archived record.
        c.hasUnhandledReply = true
        return c
    }

    @Test func theReplyDraftShowsTheModelThatWroteIt() throws {
        let i = item(draftModel: nil, contacts: [contact(replyDraftModel: "opus")])
        #expect(try texts(view(i)).contains("Drafted by opus"))
    }

    @Test func aReplyDraftWithNoTraceSaysNothingAboutAModel() throws {
        let i = item(draftModel: nil, contacts: [contact(replyDraftModel: nil)])
        #expect(try texts(view(i)).allSatisfy { !$0.hasPrefix("Drafted by") })
    }

    // --- The reply stamp, end to end -----------------------------------------------------------

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func prospectWithReplier(_ ctx: ModelContext) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "show", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2099-09-19",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        let r = Recipient(id: "r1", email: "ada@aurora.org", name: "Ada Reyes", role: "GM",
                          provenance: .presenter)
        r.replied = true
        p.recipients = [r]
        ctx.insert(p)
        return (p, r)
    }

    private func replyResults(model: String?, body: String = "Thanks for writing back.")
        -> ReplyClassifyResults {
        ReplyClassifyResults(version: 3, generatedAt: "2026-07-13T00:00:00Z",
                             results: [ReplyClassifyResult(naturalKey: "show", intent: "interested",
                                                           recipientId: "r1",
                                                           draftSubject: "Re: your concert",
                                                           draftBody: body)],
                             model: model)
    }

    @Test func aReplyDraftRemembersTheModelThatWroteIt() throws {
        let ctx = try context()
        let (_, r) = prospectWithReplier(ctx)

        ReplyClassifyImporter.ingest(replyResults(model: "opus"), into: ctx)

        #expect(r.replyDraftBody == "Thanks for writing back.")
        #expect(r.replyDraftModel == "opus")
    }

    // The stamp rides the SAME branch as the text, so it can never end up describing words it did not
    // write. A reply Dan hand-edited is HIS text and the importer already refuses to overwrite it; the
    // trace must survive untouched too, still naming the model that wrote what he edited.
    @Test func aReplyDanEditedKeepsTheTraceOfWhatWroteTheTextHeEdited() throws {
        let ctx = try context()
        let (_, r) = prospectWithReplier(ctx)
        ReplyClassifyImporter.ingest(replyResults(model: "opus"), into: ctx)

        r.replyDraftEditedByDan = true
        ReplyClassifyImporter.ingest(replyResults(model: "haiku", body: "A different draft."), into: ctx)

        #expect(r.replyDraftBody == "Thanks for writing back.")   // his text won
        #expect(r.replyDraftModel == "opus")                      // and so did its trace
    }

    // A results file written before the stamp existed still lands Dan's draft. A gap in the record is
    // never a reason to drop his work on the floor.
    @Test func aReplyResultsFileWithNoModelStillLandsItsDraft() throws {
        let ctx = try context()
        let (_, r) = prospectWithReplier(ctx)

        ReplyClassifyImporter.ingest(replyResults(model: nil), into: ctx)

        #expect(r.replyDraftBody == "Thanks for writing back.")
        #expect(r.replyDraftModel == nil)
    }

    // The runner already stamps `model` into the reply results file (lib/models.sh record_model). The
    // decoder threw it away, which is why the reply half of #804 was invisible.
    @Test func theDecoderKeepsTheModelStampTheRunnerAlreadyWrites() throws {
        let json = """
        {"version":3,"generatedAt":"2026-07-13T00:00:00Z","model":"opus",
         "results":[{"naturalKey":"show","intent":"interested","recipientId":"r1",
                     "draftSubject":"Re: your concert","draftBody":"Thanks."}]}
        """.data(using: .utf8)!

        #expect(try ReplyClassifyResultsDecoder.decode(json).model == "opus")
    }

    // An older file with no stamp at all must still decode, or a version bump would strand Dan's replies.
    @Test func aReplyResultsFileWithoutAStampStillDecodes() throws {
        let json = """
        {"version":3,"generatedAt":"2026-07-13T00:00:00Z",
         "results":[{"naturalKey":"show","intent":"interested","recipientId":"r1"}]}
        """.data(using: .utf8)!

        #expect(try ReplyClassifyResultsDecoder.decode(json).model == nil)
    }
}
