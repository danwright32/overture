import Testing
import Foundation

// #4338 (A10): every Debug landing preview puts its outcome on the surface that outcome really appears on, so each
// can be looked at on a synthetic store: the landing line's own states on the line, and a scout's own outcomes in
// its summary. A name it does not know is said, never shown as nothing (L320).
@MainActor
@Suite("Every landing preview reaches the surface its outcome appears on (#4338)")
final class LandingPreviewTests {
    private let sandboxes = TemporarySandboxes()
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func apply(_ name: LandingPreview.Name) throws -> (LandingPreview.Shown, LandingMarker, EntryFlushRecord) {
        let marker = LandingMarker()
        let flushes = EntryFlushRecord()
        let journals = LandingJournals(directory: try sandboxes.make(named: "landing-preview"),
                                       readFailures: HandoffReadFailures())
        return (LandingPreview.apply(name.rawValue, now: now, marker: marker, flushes: flushes, journals: journals),
                marker, flushes)
    }

    @Test func everyLineStatePutsSomethingOnTheLandingLine() throws {
        let summary: Set<LandingPreview.Name> = [.alreadyLanded, .refused, .recentEditsUnsaved, .notLandedYet,
                                                 .couldNotBeSaved, .couldNotBeSavedRetried, .notAttempted,
                                                 .notReverted, .superseded]
        for name in LandingPreview.Name.allCases where !summary.contains(name) {
            let (shown, marker, flushes) = try apply(name)
            guard case .landingLine = shown else {
                Issue.record(Comment(rawValue: "\(name) did not go to the landing line"))
                continue
            }
            let stuck = flushes.isStuck ? (rows: flushes.rows, lastTryFailedAt: flushes.lastTryFailedAt) : nil
            let drawn = marker.standing(editsStuck: stuck).count + marker.latest.count + (marker.live == nil ? 0 : 1)
            #expect(drawn > 0, Comment(rawValue: "\(name) put nothing on the landing line"))
        }
        for name in summary {
            let (shown, _, _) = try apply(name)
            guard case .summary(let warnings) = shown else {
                Issue.record(Comment(rawValue: "\(name) did not go to the summary"))
                continue
            }
            #expect(!warnings.sections.isEmpty, Comment(rawValue: "\(name) put an empty summary on screen"))
        }
    }

    // The four states Dan's rule keeps apart each have a preview, so each can be looked at.
    @Test func eachOfTheFourStatesCanBePutOnScreen() throws {
        let (_, working, _) = try apply(.working)
        #expect(working.live.map { LandingOutcome.live($0.work, startedAt: $0.startedAt, now: now, waiting: false,
                                                       holder: nil).outcome.look } == .working)
        let (_, alive, _) = try apply(.alive)
        #expect(alive.previewWaitingBehind == .runScoutLanding)
        let (_, stalled, _) = try apply(.stalled)
        #expect(stalled.live.map { LandingOutcome.live($0.work, startedAt: $0.startedAt, now: now, waiting: false,
                                                       holder: nil).outcome.look } == .stalled)
        let (_, failed, _) = try apply(.recordUnreadable)
        #expect(failed.standing(editsStuck: nil).first?.look == .failed)
        let (_, _, flushes) = try apply(.editsStuck)
        #expect(flushes.isStuck)
    }

    @Test func aNameItDoesNotKnowIsSaid() {
        let journals = LandingJournals(directory: URL(fileURLWithPath: NSTemporaryDirectory()), readFailures: HandoffReadFailures())
        guard case .unknown(let why) = LandingPreview.apply("no-such-state", now: now, marker: LandingMarker(),
                                                            flushes: EntryFlushRecord(), journals: journals) else {
            Issue.record("an unknown preview name was shown as something")
            return
        }
        #expect(why.contains("no-such-state") && why.contains(LandingPreview.Name.editsStuck.rawValue))
    }
}
