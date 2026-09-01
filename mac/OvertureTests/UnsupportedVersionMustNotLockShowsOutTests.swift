import Testing
import Foundation
import SwiftData

// #3358 Phase 2, taking the sibling that phase names by name: "a `version` the app does not support,
// which today locks a whole batch out silently and is the same defect one level up".
//
// The mechanism is documented in `PrepResultsDecoder`'s own comment and was never closed:
// `PrepImporter.answeredKeys` decoded with NO version gate and succeeded on a newer file, while
// `ingestFile` came through the gate and threw, and `consumeIfNew` swallowed that with `try?`. So a
// results file one version ahead of this build made `markProbed` stamp EVERY show in the run with the
// no-email floor and a 90 day freshness stamp, nothing upgraded them, and the badge locked them out of
// a re-check for about three months with no error anywhere. That is the #1594 shape and it is exactly
// what Phase 2 exists to make impossible: not a rarer wrong verdict, an unrecordable one.
//
// The fix is that `answeredKeys` asks the SAME question the ingest asks. A file this build cannot read
// is then UNREADABLE rather than empty, which is a different claim (L11, L98), and #2879's recorder
// already carries an unreadable handoff file to a surface Dan sees.
@MainActor
@Suite("A results version this build cannot read must not lock every show out (#3358 Phase 2)")
struct UnsupportedVersionMustNotLockShowsOutTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func scratch() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unsupported-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func resultsFile(_ dir: URL, version: Int, key: String) throws -> URL {
        let url = dir.appendingPathComponent("results.json")
        try #"{"version":\#(version),"generatedAt":"now","results":[{"naturalKey":"\#(key)"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // The defect exactly: one version ahead of this build, and every show in the run is written off.
    @Test func aVersionAheadOfThisBuildStampsNothing() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try resultsFile(dir, version: PrepResultsDecoder.supportedVersion + 1, key: key)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityProbedAt == nil, "a file this build cannot read started a 90 day lockout")
        #expect(p.reachabilityResult == nil, "and wrote a firm negative nothing could upgrade")
    }

    // And the show stays RE-CHECKABLE rather than silently dropping out of the queue, which is the half
    // that makes the refusal useful rather than merely harmless.
    @Test func theShowIsStillOfferedARecheck() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try resultsFile(dir, version: PrepResultsDecoder.supportedVersion + 1, key: key)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityUnansweredAt != nil,
                "the run did not answer this show in any way this build can read")
        #expect(Reachability.wasMissedByACheck(probedAt: p.reachabilityProbedAt,
                                               unansweredAt: p.reachabilityUnansweredAt,
                                               now: Date()))
    }

    // A SUPPORTED version still works exactly as before, or the fix would be a reader that refuses
    // everything and the tests above would pass for the wrong reason (L159).
    @Test func aSupportedVersionStillStampsTheFloor() throws {
        let ctx = ModelContext(try container())
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "kestrel-2027-04-18-rowan"
        let p = show(ctx, key)
        let url = try resultsFile(dir, version: PrepResultsDecoder.supportedVersion, key: key)

        var saveFailed = false
        _ = PrepQueueService.markProbed(keys: [key], answeredIn: url, in: ctx, now: Date(),
                                        anIngestIsStillToCome: true, saveFailed: &saveFailed)

        #expect(p.reachabilityProbedAt != nil)
        #expect(p.reachabilityResult == .noEmailFound)
    }

    // A file this build cannot read is UNREADABLE, not empty, and the two are different claims: empty
    // says the run answered nobody, unreadable says nobody can tell (L11, L98). #2879 already carries an
    // unreadable handoff file to a surface Dan sees, so routing through the gate is what puts an
    // unsupported version on that surface instead of leaving it silent.
    @Test func anUnsupportedVersionIsRecordedAsUnreadable() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try resultsFile(dir, version: PrepResultsDecoder.supportedVersion + 1, key: "k")

        let recorder = HandoffReadFailures()
        let read = HandoffFile.read(at: url, recorder: recorder) { try PrepResultsDecoder.decode($0) }
        switch read {
        case .unreadable: break
        default: Issue.record("an unsupported version read as \(read) rather than unreadable")
        }
        #expect(!recorder.current().isEmpty, "nothing recorded the file Overture could not read")
    }
}
