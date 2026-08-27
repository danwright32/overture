import Testing
import Foundation
import SwiftData

// #2873: every AI reply draft Overture produced was discarded in silence.
//
// `ReplyClassifyResults.generatedAt` was declared non-optional with no default, so Swift's synthesized
// decoder REQUIRED the key. The drafting run stopped writing it, `ReplyClassifyResultsDecoder.decode`
// threw `keyNotFound("generatedAt")` on every real results file, and the one call site read
// `guard let outcome = try? ...else { return }`, so the throw was dropped and the ingest returned as
// though there were simply nothing to read. A paid draft was written to disk, never reached the store,
// and the reply sheet went on showing a spinner for it.
//
// Two claims here, and they are separate: that the shape the runner ACTUALLY writes decodes (the bug),
// and that a file which cannot be read REPORTS rather than reading as an empty one (the silence that
// made a one-line bug cost a day). Every fixture in fixtures/reply-classify/ carried `generatedAt`, so
// the contract guard was green for the whole time the live path was broken (L48, L52).
@MainActor
@Suite("Reply classify read failures")
struct ReplyClassifyReadFailureTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func lead(_ ctx: ModelContext, key: String, recipient: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        let rec = Recipient(id: recipient, email: recipient, provenance: .presenter)
        rec.sendState = .sent
        rec.replied = true
        p.setRecipients([rec])
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-results-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - The shape the runner actually writes

    // The live runner writes exactly these three top-level keys, measured from
    // ~/Library/Application Support/Overture/overture-reply-classify-results.json on 2026-08-17:
    // ["model", "results", "version"]. No generatedAt. This is the file the app could not read.
    @Test func theShapeTheRunnerActuallyWritesDecodes() throws {
        let json = #"""
        {"model":"claude-sonnet-5","version":3,
         "results":[{"naturalKey":"k","intent":"has_question","recipientId":"p@x.example",
                     "draftSubject":"Re: A","draftBody":"A drafted reply."}]}
        """#
        let decoded = try ReplyClassifyResultsDecoder.decode(Data(json.utf8))
        #expect(decoded.generatedAt == nil)
        #expect(decoded.model == "claude-sonnet-5")
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].draftBody == "A drafted reply.")
    }

    // The whole cost of the defect: the draft must land in the store. Decoding is not the point.
    @Test func aRunWithNoGeneratedAtStillLandsTheDraft() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "show", recipient: "p@x.example")
        let url = try temporaryFile(#"""
        {"model":"claude-sonnet-5","version":3,
         "results":[{"naturalKey":"show","intent":"has_question","recipientId":"p@x.example",
                     "draftSubject":"Re: your March 10 concert","draftBody":"Happy to help."}]}
        """#)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = ReplyClassifyImporter.read(at: url, into: ctx, queueURL: url)

        guard case .ingested(let outcome) = read else {
            Issue.record("expected the file to be ingested, got \(read)")
            return
        }
        #expect(outcome.matched == 1)
        #expect(p.recipients.first?.replyDraftBody == "Happy to help.")
        #expect(p.recipients.first?.intentHint == "has_question")
    }

    // MARK: - An unreadable file is not an empty one (L11, L105)

    @Test func aFileThatCannotBeDecodedIsReportedRatherThanReadAsEmpty() throws {
        let ctx = ModelContext(try container())
        // A required per-result field is missing, so the decoder refuses the file.
        let url = try temporaryFile(#"{"version":3,"results":[{"intent":"has_question"}]}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let read = ReplyClassifyImporter.read(at: url, into: ctx, queueURL: url)

        guard case .unreadable(let reason) = read else {
            Issue.record("expected unreadable, got \(read)")
            return
        }
        #expect(reason.contains("naturalKey"))   // names the field, which is what makes it actionable
    }

    @Test func aFileThatIsNotJSONAtAllIsReportedTooRatherThanIgnored() throws {
        let ctx = ModelContext(try container())
        let url = try temporaryFile("not json at all")
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .unreadable = ReplyClassifyImporter.read(at: url, into: ctx, queueURL: url) else {
            Issue.record("a results file that is not JSON must report, not read as empty")
            return
        }
    }

    // An unsupported version is a refusal the decoder makes on purpose, and it is still a file that
    // could not be read. It must not be silent either.
    @Test func anUnsupportedVersionIsReportedAsUnreadable() throws {
        let ctx = ModelContext(try container())
        let url = try temporaryFile(#"{"version":99,"results":[]}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .unreadable(let reason) = ReplyClassifyImporter.read(at: url, into: ctx, queueURL: url) else {
            Issue.record("an unsupported version must report, not read as empty")
            return
        }
        #expect(reason.contains("99"))
    }

    // The ordinary idle state: no run has ever written a results file. That is genuinely nothing to
    // read, and it must stay silent, or the warning fires on every fresh install and gets ignored (L36).
    @Test func noFileAtAllStaysSilent() throws {
        let ctx = ModelContext(try container())
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-results-absent-\(UUID().uuidString).json")

        #expect(ReplyClassifyImporter.read(at: missing, into: ctx, queueURL: missing) == .nothingToRead)
    }

    // MARK: - What Dan is told

    @Test func theUnreadableMessageSaysTheDraftWasNotSavedAndNamesTheReason() {
        let message = ReplyClassifyRunSummary.unreadableMessage(
            reason: "a required field is missing: generatedAt")

        #expect(message.contains("generatedAt"))
        #expect(message.contains("overture-reply-classify-results.json"))
        // It must not read as "there was nothing to do", which is what the swallowed error said.
        #expect(!message.lowercased().contains("nothing to"))
    }

    // MARK: - The wire, which is a separate claim from the guard above

    // Every test above calls `read` directly, so all of them stay green if `ingestReplyClassifications`
    // goes back to `try? ReplyClassifyImporter.ingestFile(...) else { return }`. That line IS the defect,
    // and it lives inside a SwiftUI view where no test can reach it (#885), so a source guard holds the
    // wire, scoped to the one function so a legitimate use elsewhere in the file cannot answer for it
    // (L135).
    @Test func theLaunchIngestGoesThroughTheReportingRead() throws {
        let rootView = SourceGuardHelper.source("Overture/App/RootView.swift")
        guard let fn = SourceGuardHelper.bodyOfFunction(named: "ingestReplyClassifications",
                                                        in: rootView) else {
            Issue.record("ingestReplyClassifications not found in RootView")
            return
        }
        #expect(fn.contains("ReplyClassifyImporter.read("))
        // The swallowed throw. It made a completed, paid draft indistinguishable from an empty file.
        #expect(!fn.contains("try? ReplyClassifyImporter.ingestFile("))
        // And the failure has to reach a surface: a read outcome nobody renders is the defect, not a fix.
        #expect(fn.contains("unreadableMessage"))
    }
}
