import Testing
import Foundation

// #1881: a live run and its reported start time must name the SAME run.
//
// "A run is live" comes from the marker file. "When it started" came from a user default written only
// after the detached runner launches, and between the lock being taken and that write the app truthfully
// reported a live run beside the PREVIOUS run's start. That is how the takeover came to show an elapsed
// counter of 23:47:46 on a run seconds old.
//
// Moving the write earlier would close today's gap and leave two sources free to disagree again, which is
// what the issue asks not to rely on. The marker is the thing that MAKES a run live, so while it exists
// it is also the thing that says when the run began: one source, and the disagreement is unrepresentable.
@MainActor
@Suite("A live run's start comes from the marker that makes it live (#1881)")
struct RunStartComesFromItsMarkerTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("run-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // A private suite, never `.standard`: a test may not reach real shared state (#2540, L2).
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "run-start-\(UUID().uuidString)")!
    }

    // THE invariant, and the state the incident was in: a marker just created, with the previous run's
    // date still in the default. What is reported must be the LIVE run's start, not the old one's.
    @Test func aLiveRunNeverReportsAnEarlierRunsStart() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let yesterday = Date().addingTimeInterval(-24 * 3600)
        PrepQueueService.recordRunStarted(slot: .prep, at: yesterday, defaults: d)

        // The lock, taken now, exactly as a launch takes it.
        try Data().write(to: RunSlot.prep.markerURL(in: dir), options: .withoutOverwriting)

        let reported = try #require(PrepQueueService.lastRunStartedAt(slot: .prep, defaults: d, support: dir))
        #expect(reported.timeIntervalSince(yesterday) > 3600,
                "the live run reported a start 24 hours old, which is #1881 exactly")
        #expect(abs(reported.timeIntervalSinceNow) < 60)
    }

    // With no marker there is no live run, so the stored default is the right answer: it is what "the last
    // run started at" means once a run is over, and several readers ask exactly that.
    @Test func afinishedRunStillReportsWhatWasStored() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let earlier = Date().addingTimeInterval(-7200)
        PrepQueueService.recordRunStarted(slot: .prep, at: earlier, defaults: d)

        let reported = try #require(PrepQueueService.lastRunStartedAt(slot: .prep, defaults: d, support: dir))
        #expect(abs(reported.timeIntervalSince(earlier)) < 1)
    }

    // The two slots have their own markers, so a live check must never be dated by a prep's lock or the
    // other way round (#2760: the check is on its own).
    @Test func eachSlotIsDatedByItsOwnMarker() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let old = Date().addingTimeInterval(-24 * 3600)
        PrepQueueService.recordRunStarted(slot: .prep, at: old, defaults: d)
        PrepQueueService.recordRunStarted(slot: .check, at: old, defaults: d)

        try Data().write(to: RunSlot.check.markerURL(in: dir), options: .withoutOverwriting)

        let check = try #require(PrepQueueService.lastRunStartedAt(slot: .check, defaults: d, support: dir))
        #expect(abs(check.timeIntervalSinceNow) < 60, "the live check should be dated by its own marker")
        let prep = try #require(PrepQueueService.lastRunStartedAt(slot: .prep, defaults: d, support: dir))
        #expect(abs(prep.timeIntervalSince(old)) < 1, "the prep is not live, so its stored date stands")
    }

    // The sanitiser still applies to whatever is reported. A marker with an implausible date is not a
    // reason to believe it: the same rule already guards the stored value, and one of two sources being
    // sanitised is how they come to disagree.
    @Test func animplausibleMarkerDateIsRefusedLikeAnImplausibleStoredOne() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let marker = RunSlot.prep.markerURL(in: dir)
        try Data().write(to: marker, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 0),
                                               .modificationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: marker.path)

        #expect(PrepQueueService.lastRunStartedAt(slot: .prep, defaults: d, support: dir) == nil)
    }
}
