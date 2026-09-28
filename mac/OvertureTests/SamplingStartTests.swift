import Testing
import Foundation

// #4307: `/usr/bin/sample` prints "Sampling process ..." once it has ATTACHED, and that line can come well
// before the first sample is taken (#4106 measured whole readings timed from it going unsampled). So a probe
// that starts its measured work on that line can leave the start of the work out of the samples, and under
// report exactly the work it exists to attribute.
//
// The signal that sampling has really begun is read from the SAMPLER's own counters, never from the target's
// own timing: each sample suspends the target, walks every thread's stack and resumes it, which is a burst of
// Mach calls around one context switch per sample. Counters do not depend on how loaded the Mac is, where
// timing the target's own pauses does: measured 2026-09-28 at a load average near 100, a spinning watcher in
// the target saw as many short pauses before sampling began as during it.
//
// The fixtures below are the sampler's per 100 ms counter deltas from two real runs on 2026-09-28 (a 3 s
// sample of a small process, and of one holding 60 extra threads), measured with proc_pidinfo, not shaped to
// fit the rule (L48). Their "setup" rows are the attach and symbol grab phase, where the sampler does many
// Unix calls (reading images) and no steady per sample rhythm.

private typealias Delta = (ms: UInt64, switches: UInt64, mach: UInt64, unix: UInt64)

private func cumulative(_ deltas: [Delta]) -> [SamplingStart.Reading] {
    var mach: UInt64 = 0, unix: UInt64 = 0, switches: UInt64 = 0
    return deltas.map { d in
        mach += d.mach; unix += d.unix; switches += d.switches
        return SamplingStart.Reading(at: d.ms * 1_000_000, machCalls: mach, unixCalls: unix, switches: switches)
    }
}

// 60 extra threads: the sampler's steady state is about 88 samples and 6,200 Mach calls a 100 ms.
private let manyThreads: [Delta] = [
    (3, 2, 35, 78), (105, 404, 611, 1682), (209, 3, 6, 3), (314, 0, 0, 0), (419, 0, 0, 0),
    (522, 20, 29, 49), (625, 22, 13, 40), (727, 563, 1793, 6325), (829, 291, 5174, 2277),
    (931, 87, 6144, 86), (1036, 91, 6406, 90), (1137, 86, 6053, 85), (1238, 88, 6137, 86),
]

// A small process: about 90 samples and 1,000 Mach calls a 100 ms, and NO Unix calls while sampling.
private let fewThreads: [Delta] = [
    (0, 2, 0, 0), (105, 657, 1039, 2798), (206, 615, 2890, 7905), (306, 90, 995, 0), (406, 90, 995, 0),
    (507, 89, 995, 0), (612, 93, 1039, 0),
]

@Suite("Sampling has really begun, read from the sampler's own counters (#4307)")
struct SamplingStartTests {

    @Test func theFirstSteadySamplingIntervalOpensTheWindowWithManyThreads() {
        // 727 to 829 is still the symbol grab (Unix calls at 44% of the Mach calls); 829 to 931 is the first
        // interval of the per sample rhythm, so sampling began no earlier than the reading at 829.
        #expect(SamplingStart.began(cumulative(manyThreads)) == 829_000_000)
    }

    @Test func theFirstSteadySamplingIntervalOpensTheWindowWithFewThreads() {
        #expect(SamplingStart.began(cumulative(fewThreads)) == 206_000_000)
    }

    @Test func theAttachAndSymbolPhaseAloneIsNotSampling() {
        // Everything up to and including the reading at 829, which opens the first sampling interval.
        let setup = cumulative(Array(manyThreads.prefix(9)))
        #expect(SamplingStart.began(setup) == nil)
        for i in 1..<setup.count {
            #expect(!SamplingStart.looksLikeSampling(from: setup[i - 1], to: setup[i]),
                    "interval \(i) of the attach and symbol phase was read as sampling")
        }
    }

    @Test func oneSamplingIntervalIsNotEnough() {
        // The setup plus exactly one steady interval: a single burst could be anything, two in a row is the
        // rhythm.
        let one = cumulative(Array(manyThreads.prefix(10)))
        #expect(SamplingStart.looksLikeSampling(from: one[8], to: one[9]))
        #expect(SamplingStart.began(one) == nil)
    }

    @Test func tooFewReadingsAnswerNothing() {
        #expect(SamplingStart.began([]) == nil)
        #expect(SamplingStart.began(Array(cumulative(fewThreads).suffix(1))) == nil)
    }

    @Test func aCounterGoingBackwardsIsNotSamplingAndDoesNotTrap() {
        // A reading of a different process (the pid reused) or a partial read must not underflow, and readings
        // taken out of order (the second one earlier than the first) are not an interval at all.
        let a = SamplingStart.Reading(at: 0, machCalls: 10_000, unixCalls: 0, switches: 500)
        let b = SamplingStart.Reading(at: 100_000_000, machCalls: 20, unixCalls: 0, switches: 3)
        #expect(!SamplingStart.looksLikeSampling(from: a, to: b))
        #expect(!SamplingStart.looksLikeSampling(from: b, to: a))
    }

    @Test func burstsOfMachCallsWithoutContextSwitchesAreNotSampling() {
        // Every sample ends in a wait, so an interval with Mach calls and next to no switches is some other
        // work (reading the target's memory while grabbing symbols).
        let a = SamplingStart.Reading(at: 0, machCalls: 0, unixCalls: 0, switches: 0)
        let b = SamplingStart.Reading(at: 100_000_000, machCalls: 6_000, unixCalls: 0, switches: 2)
        #expect(!SamplingStart.looksLikeSampling(from: a, to: b))
    }
}

// The wiring: `LandingSelfSampler.start()` returns only once the counters say sampling has begun, and refuses
// rather than returning when they never do. A stub stands in for `/usr/bin/sample` (it prints the attach line
// and waits), and the counters are scripted, so no real sampler and no clock is involved.
@MainActor
@Suite("The self sampler waits for sampling to really begin (#4307)")
final class SelfSamplerStartWaitsForSamplingTests {

    private let sandboxes = TemporarySandboxes()

    private final class Script: @unchecked Sendable {
        var readings: [SamplingStart.Reading]
        var taken = 0
        init(_ readings: [SamplingStart.Reading]) { self.readings = readings }
        func next(_ pid: Int32) -> SamplingStart.Reading? {
            defer { taken += 1 }
            return taken < readings.count ? readings[taken] : readings.last
        }
    }

    private func stub(exitingAfter seconds: Int) throws -> URL {
        let url = try sandboxes.makeFile(named: "sample-stub.sh", inSandboxNamed: "overture-4307-sampler")
        try "#!/bin/sh\necho \"Sampling process $1 for $2 seconds with 1 millisecond of run time\"\nsleep \(seconds)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func startReturnsOnlyOnceTheCountersLookLikeSampling() async throws {
        let script = Script(cumulative(manyThreads))
        let sampler = LandingSelfSampler(seconds: 2, file: try sandboxes.makeFile(named: "out.txt",
                                                                                    inSandboxNamed: "overture-4307-out"),
                                         executable: try stub(exitingAfter: 3), counters: script.next,
                                         readingEvery: .zero)
        try await sampler.start()
        // Two sampling intervals after the reading at 829 means the reading at 1036 had to be taken.
        #expect(script.taken >= 11, "start returned after \(script.taken) counter readings, before sampling began")
        #expect(sampler.beganAt == 829_000_000)
    }

    @Test func startRefusesWhenSamplingNeverBegins() async throws {
        let script = Script(cumulative(Array(manyThreads.prefix(9))))
        let sampler = LandingSelfSampler(seconds: 2, file: try sandboxes.makeFile(named: "out.txt",
                                                                                    inSandboxNamed: "overture-4307-out"),
                                         executable: try stub(exitingAfter: 3), counters: script.next,
                                         readingEvery: .zero, beginTimeout: .milliseconds(300))
        var refused = false
        await withKnownIssue("the wait timing out is the point of this case") {
            do { try await sampler.start() } catch LandingSelfSampler.SamplerError.neverBegan { refused = true }
        }
        #expect(refused, "start returned although the counters never looked like sampling")
        #expect(sampler.beganAt == nil)
    }

    @Test func startRefusesAtOnceWhenTheSamplerExitsBeforeSampling() async throws {
        let script = Script(cumulative(Array(manyThreads.prefix(9))))
        let sampler = LandingSelfSampler(seconds: 2, file: try sandboxes.makeFile(named: "out.txt",
                                                                                    inSandboxNamed: "overture-4307-out"),
                                         executable: try stub(exitingAfter: 1), counters: script.next,
                                         readingEvery: .zero)
        var refused = false
        do { try await sampler.start() } catch LandingSelfSampler.SamplerError.neverBegan { refused = true }
        #expect(refused, "start returned although the sampler exited before sampling began")
    }
}
