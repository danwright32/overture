import Testing
import Foundation
@testable import Overture

// #321: a guard that every cross-boundary handoff file resolves under the single shared
// StoreLocation.handoffDirectory. The #317 reply-classify leak happened because two files built
// their own path from the raw application-support root, bypassing StoreLocation, and no test caught
// it — so a Debug run silently read/wrote them in the LIVE folder. This locks the invariant in: a
// future file that constructs its own path (or forgets the Debug/Release split) fails here.
@Suite("Handoff directory guard (#321)")
@MainActor
struct HandoffDirectoryGuardTests {
    // Every public accessor for a file the app reads or writes across the workflow boundary
    // (docs/contracts.md), labelled for a readable failure. System locations that intentionally live
    // elsewhere (the resident agent logs in ~/Library/Logs, the LaunchAgent plist) are excluded.
    private var handoffURLs: [(label: String, url: URL)] {
        [
            ("downbeat-export", DownbeatBridge.defaultURL),
            ("prep-results", PrepImporter.defaultURL),
            ("prep-queue", PrepQueueBuilder.defaultURL),
            ("reply-classify-queue", ReplyClassifyQueueBuilder.defaultURL),
            ("reply-classify-results", ReplyClassifyResultsDecoder.defaultURL),
            ("reply-classify-importer", ReplyClassifyImporter.defaultURL),
            ("voice-feedback", VoiceFeedbackBuilder.defaultURL),
            ("recent-openers", RecentOpenersBuilder.defaultURL),
            ("scout-extract-queue", ScoutExtractQueueBuilder.defaultURL),
            ("scout-extract-results", ScoutExtractResultsDecoder.defaultURL),
            ("scout-extract-progress", ScoutExtractProgressDecoder.defaultURL),
            ("scout-extract-marker", ScoutExtractService.defaultMarkerURL),
            ("scout-extract-run-log", RunLog.scoutExtractURL),
            ("scout-page-pin", ScoutPagePin.url(forSourceId: "example")),
            ("voice-guidance", VoiceGuidanceGuard.defaultURL),
            ("voice-guidance-store", VoiceGuidanceStore.defaultURL),
            ("voice-guidance-backup", VoiceNotesProtector.defaultBackupURL),
            ("prep-run-log", RunLog.prepURL),
            ("reply-classify-run-log", RunLog.replyClassifyURL),
            ("prep-running-marker", PrepQueueService.defaultMarkerURL),
            ("reply-classify-running-marker", ReplyClassifyService.defaultMarkerURL),
            ("gmail-oauth", GmailCredentials.clientConfigURL),
            ("gmail-tokens", GmailCredentials.tokenURL),
        ]
    }

    @Test func everyHandoffFileLivesInTheSharedHandoffDirectory() {
        for entry in handoffURLs {
            #expect(entry.url.deletingLastPathComponent() == StoreLocation.handoffDirectory,
                    "\(entry.label) (\(entry.url.lastPathComponent)) is not under StoreLocation.handoffDirectory")
        }
    }

    // Negative control: prove the assertion has teeth. A file that genuinely lives elsewhere (the
    // resident agent log, ~/Library/Logs/Overture) must NOT register as being under the handoff dir,
    // so the check above would actually catch a misplaced file rather than passing vacuously.
    @Test func aFileOutsideTheHandoffDirectoryIsNotMistakenlyAccepted() {
        #expect(AgentLogLocation.standardOutURL.deletingLastPathComponent() != StoreLocation.handoffDirectory)
    }
}
