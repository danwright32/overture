import Testing
import Foundation
import SwiftData

// The write half of the recent-openers handoff (#730): the service exports the file from the store,
// and startPrep writes it alongside the queue when a run launches, so the drafter reads fresh openers
// to avoid. Mirrors VoiceFeedbackTests' export/wiring pair.
@MainActor
@Suite("Recent openers export wiring (#730)")
struct RecentOpenersServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func drafted(key: String, original: String, sentAt: Date) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.originalDraftBody = original
        p.sentAt = sentAt
        return p
    }

    @Test func exportWritesADecodableFile() throws {
        let ctx = ModelContext(try container())
        ctx.insert(drafted(key: "k1", original: "I photograph performing arts in New York. Rest.",
                           sentAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let count = try RecentOpenersService.export(from: ctx, generatedAt: "2026-06-26T00:00:00Z", url: url)
        #expect(count == 1)
        let decoded = try JSONDecoder().decode(RecentOpeners.self, from: Data(contentsOf: url))
        #expect(decoded.version == RecentOpenersBuilder.version)
        #expect(decoded.openers.first?.naturalKey == "k1")
        #expect(decoded.openers.first?.opener == "I photograph performing arts in New York.")
    }

    @Test func startPrepWritesRecentOpenersAlongsideTheQueue() async throws {
        let ctx = ModelContext(try container())
        // One kept-undrafted prospect so the queue is non-empty (otherwise startPrep throws).
        let toPrep = Prospect(naturalKey: "to-prep", groupName: "G2", discipline: "music", venue: "V",
                              performanceDate: "2026-08-01", sourceListingURL: nil,
                              priorRelationship: "none", production: "self", profile: "strong",
                              coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                              status: .queued)
        ctx.insert(toPrep)
        // One already-drafted prospect whose opener should land in the recent-openers file.
        ctx.insert(drafted(key: "already-drafted", original: "A distinctive opener sentence. Rest.",
                           sentAt: Date(timeIntervalSince1970: 100)))
        try ctx.save()

        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString)")
        let feedbackURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-\(UUID().uuidString).json")
        let openersURL = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString).json")
        defer { [queueURL, marker, feedbackURL, openersURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        try await PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                             queueURL: queueURL, markerURL: marker,
                                             voiceFeedbackURL: feedbackURL, recentOpenersURL: openersURL,
                                             launch: {})

        let decoded = try JSONDecoder().decode(RecentOpeners.self, from: Data(contentsOf: openersURL))
        #expect(decoded.openers.map(\.opener) == ["A distinctive opener sentence."])
    }

    @Test func startPrepStillProceedsWhenTheRecentOpenersWriteFails() async throws {
        // The export is best-effort (try?): a failure to write the anti-repetition file must never block
        // the Prep run itself. Force the write to fail by pointing it under a path whose parent is a
        // FILE, so createDirectory throws, and prove the queue is still written and the launch happens.
        let ctx = ModelContext(try container())
        let toPrep = Prospect(naturalKey: "to-prep", groupName: "G2", discipline: "music", venue: "V",
                              performanceDate: "2026-08-01", sourceListingURL: nil,
                              priorRelationship: "none", production: "self", profile: "strong",
                              coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                              status: .queued)
        ctx.insert(toPrep)
        try ctx.save()

        let tmp = FileManager.default.temporaryDirectory
        let queueURL = tmp.appendingPathComponent("q-\(UUID().uuidString).json")
        let marker = tmp.appendingPathComponent("m-\(UUID().uuidString)")
        let feedbackURL = tmp.appendingPathComponent("vf-\(UUID().uuidString).json")
        // A regular file standing in as the openers URL's parent directory, so the export's
        // createDirectory (and thus the write) fails.
        let blocker = tmp.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let openersURL = blocker.appendingPathComponent("child.json")
        defer { [queueURL, marker, feedbackURL, blocker].forEach { try? FileManager.default.removeItem(at: $0) } }

        var launched = false
        let count = try await PrepQueueService.startPrep(from: ctx, now: Date(timeIntervalSince1970: 0),
                                                         queueURL: queueURL, markerURL: marker,
                                                         voiceFeedbackURL: feedbackURL, recentOpenersURL: openersURL,
                                                         launch: { launched = true })

        #expect(count == 1)                                              // the run went ahead
        #expect(launched)                                               // and launched
        #expect(FileManager.default.fileExists(atPath: queueURL.path))  // the queue was still written
        #expect(!FileManager.default.fileExists(atPath: openersURL.path))  // the openers write did fail
    }
}
