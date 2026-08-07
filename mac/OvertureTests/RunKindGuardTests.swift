import Testing
import Foundation

// #1810: which KIND of run just finished, decided somewhere a test can reach.
//
// A reachability check and a Prep run share one detached runner, one queue file and one results file. Which
// of the two finished was decided by the mere PRESENCE of a side file, inside a SwiftUI view, so nothing
// could assert the mapping (#863). #1809 is what that costs: a leftover check marker made a Prep run
// ingest as a check, which short-circuits before any draft handling, and every draft that run wrote was
// discarded with nothing on screen saying why.
//
// The fix is not another traced path. It is to stop the decision resting on a file EXISTING and tie it to
// the run it describes: a marker written before this run started belongs to a previous one and cannot
// speak for it.
@Suite("Which kind of run just finished (#1810)")
struct RunKindGuardTests {

    private let runStart = Date(timeIntervalSince1970: 1_780_000_000)
    private func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    // No marker at all: a Prep run, which is the ordinary case and the safe default. Reading a Prep run as
    // a check is the direction that loses work, so an absent marker must never produce one.
    @Test func noMarkerIsAPrepRun() {
        #expect(RunKind.of(runStartedAt: runStart, probeMarkerStartedAt: nil) == .prep)
    }

    @Test func aMarkerFromThisRunIsACheck() {
        #expect(RunKind.of(runStartedAt: runStart,
                           probeMarkerStartedAt: stamp(runStart)) == .reachabilityCheck)
    }

    // THE #1809 CASE. A marker left behind by a check that already ended, sitting there when a Prep run
    // starts afterwards. Its stamp is older than this run, so it cannot speak for it, and the Prep run
    // ingests as a Prep run with its drafts intact.
    @Test func aLeftoverMarkerFromAnEarlierRunNeverClaimsThisOne() {
        let stale = stamp(runStart.addingTimeInterval(-3600))
        #expect(RunKind.of(runStartedAt: runStart, probeMarkerStartedAt: stale) == .prep)
    }

    // A marker written moments after the run's own recorded start is still this run's: the two stamps are
    // taken at slightly different points, so an exact match cannot be required.
    @Test func aMarkerWrittenMomentsLaterIsStillThisRun() {
        #expect(RunKind.of(runStartedAt: runStart,
                           probeMarkerStartedAt: stamp(runStart.addingTimeInterval(2))) == .reachabilityCheck)
    }

    // Nothing recorded about when this run started. The marker is all there is, so it is believed: this is
    // the launch-time settle of a run the app did not watch, and refusing to classify it would leave a
    // paid check ingesting as a Prep run, drafting over shows nobody kept.
    @Test func withNoRunStartTheMarkerIsBelieved() {
        #expect(RunKind.of(runStartedAt: nil, probeMarkerStartedAt: stamp(runStart)) == .reachabilityCheck)
    }

    // An unreadable stamp cannot establish that the marker belongs to a previous run, and it cannot
    // establish that it belongs to this one either. It is believed, for the same reason as above: the
    // direction that loses work is reading a CHECK as a Prep run, because that drafts over shows Dan never
    // kept and spends a send path on them. A Prep run misread as a check loses drafts, which is what #1809
    // was; both are bad, and this arm is the one where a marker really is present.
    @Test func anUnreadableStampIsStillAMarker() {
        #expect(RunKind.of(runStartedAt: runStart, probeMarkerStartedAt: "not a date") == .reachabilityCheck)
    }
}

// The wiring, which is a separate claim from the rule. Every caller asking "is a check running" goes
// through one place, so the class is closed rather than the individual paths #1809 traced (L30).
@MainActor
@Suite("A leftover marker never makes a Prep run ingest as a check (#1810)")
struct StaleMarkerNeverClaimsAPrepRunTests {

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func liveRunMarker(at url: URL, startedAt: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }

    // THE #1809 CASE, through the function every surface actually calls: a Prep run is live, and a check
    // that ended an hour ago left its marker behind. The run must read as a Prep run.
    @Test func aPrepRunWithAnHourOldCheckMarkerIsNotAProbe() throws {
        let d = dir()
        let runMarker = d.appendingPathComponent("prep-run.json")
        let probeMarker = d.appendingPathComponent("probe-run.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try liveRunMarker(at: runMarker, startedAt: now)
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: ["k"],
                                    startedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))),
            to: probeMarker)

        #expect(PrepQueueService.isProbeRunning(probeRunURL: probeMarker, markerURL: runMarker,
                                                now: now, runStartedAt: now) == false)
    }

    // And a check really in flight still reads as one, so closing the hole does not close the feature.
    @Test func aCheckStartedWithThisRunIsAProbe() throws {
        let d = dir()
        let runMarker = d.appendingPathComponent("prep-run.json")
        let probeMarker = d.appendingPathComponent("probe-run.json")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        try liveRunMarker(at: runMarker, startedAt: now)
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: ["k"], startedAt: ISO8601DateFormatter().string(from: now)),
            to: probeMarker)

        #expect(PrepQueueService.isProbeRunning(probeRunURL: probeMarker, markerURL: runMarker,
                                                now: now, runStartedAt: now))
    }
}
