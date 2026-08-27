import Foundation
import Testing

// #3137: a large reachability check crossed the looks-stuck warning while running normally.
//
// `prep-run.sh` splits the work-list into `min(items, OVERTURE_PREP_MAX_PARALLEL)` chunks and each chunk
// works through its slice in order, so beyond the cap a bigger check does NOT fan out wider: it puts more
// shows in each chunk, and the run's wall clock tracks shows-per-chunk rather than shows.
// `RunTimeouts.reachabilityProbe` was a flat 600 seconds and moved with neither.
//
// Measured 2026-08-22 with Dan at the machine: a 12 show check took 386.6s, which is 64% of the fixed
// budget, at 2 shows per chunk for two of the chunks and 1 for the rest. A 30 show check is 3 per chunk
// and would plausibly land near or past 600s while running perfectly normally.
//
// What it costs is not the one wrong message. Crossing the limit kills nothing (this is the visible stall
// WARNING only, and `PrepQueueService.markerStaleAfter` stays at `prep`), so the cost is a healthy run
// telling Dan it looks stuck moments before it finishes. That is #1530's defect, and a warning that fires
// on healthy runs is a warning that gets ignored, which is exactly what this one cannot afford: it exists
// to surface real hangs (#2577, #2929 were both built after a real hang went unnoticed for over an hour).
@Suite("A check's stall window follows its depth (#3137)")
struct CheckStallWindowFollowsItsDepthTests {

    // The common case is unchanged, and that matters more than the fix: anything up to the runner's cap
    // is one round, so the window Dan has been living with for months does not move under him.
    @Test func aCheckThatFitsInOneRoundKeepsTheWindowItAlwaysHad() {
        for lookups in [1, 2, 3, 9, 10] {
            #expect(RunTimeouts.reachabilityProbeWindow(lookups: lookups) == RunTimeouts.reachabilityProbe,
                    "a \(lookups) show check is one round and must keep the flat window")
        }
    }

    // The measured case. Twelve shows is two rounds, so the run that took 386.6s is judged against 1200s
    // rather than 600s, and the 30 show check the issue projects gets three.
    @Test func aCheckDeeperThanTheCapGetsAWindowPerRound() {
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: 12) == RunTimeouts.reachabilityProbe * 2)
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: 20) == RunTimeouts.reachabilityProbe * 2)
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: 21) == RunTimeouts.reachabilityProbe * 3)
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: 30) == RunTimeouts.reachabilityProbe * 3)
        // #1765's own worked example: 77 lookups is roughly 8 rounds, which is the wait the bar quotes.
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: 77) == RunTimeouts.reachabilityProbe * 8)
    }

    // The 386.6s measurement, stated as the thing it was taken for.
    //
    // The projection is written out here rather than asserted as a round claim, because working it
    // through moved it: at the measured pace a 30 show check lands at 579.9s, which is 97% of the old
    // flat window and NOT past it. #3137 said "near or past" and the arithmetic says near. That is still
    // the defect, and saying so precisely is what makes it checkable: a run 4% slower than the one
    // actually measured crosses a limit it has no business crossing, and the 12 show run this pace comes
    // from had only two of its chunks two deep and the rest one deep, so a genuinely three-deep run is if
    // anything slower per round than this.
    @Test func theMeasuredTwelveShowRunIsInsideItsWindowBothWays() {
        let measured: TimeInterval = 386.6
        #expect(measured < RunTimeouts.reachabilityProbe)
        #expect(measured < RunTimeouts.reachabilityProbeWindow(lookups: 12))

        let perRound = measured / 2
        let thirtyShowRun = perRound * 3
        // Inside the old window, but with nothing left: any margin at all past this pace crosses it.
        #expect(thirtyShowRun < RunTimeouts.reachabilityProbe)
        #expect(thirtyShowRun > RunTimeouts.reachabilityProbe * 0.95)
        // And comfortably inside the new one, which is the whole point: the window now grows with the
        // work rather than staying where a three-show run put it.
        #expect(thirtyShowRun < RunTimeouts.reachabilityProbeWindow(lookups: 30) / 3)
    }

    // An unknown count keeps the flat window rather than inventing one. A marker written before the count
    // existed is the only way this happens, and warning early on it is the behaviour that shipped for
    // months, where a window scaled from a guess could hide a real hang for an hour (L11).
    @Test func anUnknownOrNonsenseCountKeepsTheFlatWindow() {
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: nil) == RunTimeouts.reachabilityProbe)
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: 0) == RunTimeouts.reachabilityProbe)
        #expect(RunTimeouts.reachabilityProbeWindow(lookups: -3) == RunTimeouts.reachabilityProbe)
    }

    // One definition of a round, not two. The window and the wait the selection bar quotes must be built
    // from the same arithmetic, or the panel can call a run stuck at a moment the bar promised it would
    // still be working (L16).
    @Test func theWindowCountsRoundsTheSameWayTheWaitEstimateDoes() {
        for lookups in [1, 7, 12, 21, 77] {
            let streams = min(lookups, ProbeSelection.maxConcurrentLookups)
            let rounds = ProbeDurationHistory.rounds(lookups: lookups, streams: streams)
            #expect(RunTimeouts.reachabilityProbeWindow(lookups: lookups)
                    == RunTimeouts.reachabilityProbe * Double(rounds))
        }
    }

    // MARK: - Built is not wired (L3)

    // The window is only real where the panel and the label actually ask for it. A correct function
    // nothing calls is exactly the shape #3154 was filed about, so both surfaces are checked rather than
    // assumed: the takeover panel by constructing it, the toolbar label by reading its source, because
    // that one lives inside a `some View` builder that no test can reach (L3, "logic in a SwiftUI view is
    // untestable" unless something exercises it).
    @Test func theTakeoverPanelAsksForAWindowThatFollowsTheDepth() {
        let deep = RunProgressView(phase: .probing, since: nil, probeLookups: { 30 })
        #expect(deep.timeout == RunTimeouts.reachabilityProbe * 3)

        let shallow = RunProgressView(phase: .probing, since: nil, probeLookups: { 4 })
        #expect(shallow.timeout == RunTimeouts.reachabilityProbe)
    }

    // A caller with nothing to say keeps the flat window, so every surface that does not know the size is
    // exactly as it was.
    @Test func aPanelThatKnowsNoSizeIsUnchanged() {
        #expect(RunProgressView(phase: .probing, since: nil).timeout == RunTimeouts.reachabilityProbe)
    }

    // And the size never reaches a phase it is not about. A Prep run handed one must still be judged
    // against Prep's own three minutes: one field with two meanings depending on the phase is how the
    // #863 class starts.
    @Test func anotherPhaseIsUnaffectedEvenWhenHandedASize() {
        #expect(RunProgressView(phase: .prepping, since: nil, probeLookups: { 30 }).timeout
                == RunTimeouts.prep)
        #expect(RunProgressView(phase: .reading, since: nil, probeLookups: { 30 }).timeout
                == RunTimeouts.scoutExtract)
    }

    @Test func theToolbarLabelAsksForTheSameWindow() {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(source.contains(
            "RunTimeouts.reachabilityProbeWindow(lookups: PrepQueueService.liveCheckLookups())"))
    }

    // #3186: and the size has ONE definition, on the service that owns the marker. Two surfaces now size
    // a window from it, and a second count derived from the queue would answer differently the moment a
    // show left it mid-run (L16).
    @Test func theSizeComesFromTheCheckSOwnMarkerInOnePlace() {
        let service = SourceGuardHelper.source("Overture/Integration/PrepQueueService.swift")
        #expect(service.contains("static func liveCheckLookups() -> Int?"))
        #expect(service.contains("ReachabilityProbeMarker.read(from: defaultProbeRunURL)"))
        // Nobody reads that marker for a lookup count anywhere else, which is what makes it one place.
        for file in AppSourceWalk.appFiles() where file.name != "PrepQueueService.swift" {
            let lines = SwiftSource.scannableLines(in: file.text, skipping: [])
            #expect(!lines.contains { $0.code.contains("ReachabilityProbeMarker.read") && $0.code.contains("lookups") },
                    "\(file.name) reads the check marker's lookup count itself instead of asking PrepQueueService")
        }
    }

    // MARK: - The row's own re-check label (#3186)

    // The defect #3137 scoped out on reasoning that did not hold. The row's control does not start a run:
    // `requestReachabilityRecheck` sets a flag, and the answer arrives from whatever batch picks it up. So
    // the row was counting from the PRESS against a window sized for one lookup, and a card could say a
    // healthy deep run looked stuck.
    @Test func theRowCountsFromTheRunRatherThanFromThePress() {
        let source = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(source.contains("since: checkRunSince ?? item.reachabilityRecheckRequestedAt"),
                "the row still counts the wait before a run picked the request up against the run")
        #expect(source.contains("timeout: RunTimeouts.reachabilityProbeWindow(lookups: checkLookups)"),
                "the row still judges a run of any depth against the one-round window")
    }

    // Read ONCE per render pass and threaded down, never per card: both facts come from marker files, and
    // a per-card read is a disk read per row per scroll frame, which is the #1770 defect exactly. And only
    // while a check is really in flight, so an idle queue pays nothing for a control it is offering.
    @Test func theRowIsHandedThoseFactsRatherThanReadingThemPerCard() {
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(queue.contains("checkRunSince: inFlight == .reachabilityCheck"))
        #expect(queue.contains("checkLookups: inFlight == .reachabilityCheck ? PrepQueueService.liveCheckLookups() : nil"))
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(!row.contains("PrepQueueService.liveCheckLookups()"),
                "the row reads the marker itself, which is a disk read per card per scroll frame (#1770)")
        #expect(!row.contains("PrepQueueService.lastRunStartedAt"),
                "the row reads the run marker itself, which is a disk read per card per scroll frame")
    }

    // The cap this arithmetic rests on is the runner's, not a second copy of it. `ProbeSelection` already
    // carries that constant with a comment saying it MUST match `OVERTURE_PREP_MAX_PARALLEL`, and this
    // reads it rather than restating the number.
    @Test func theCapComesFromTheOnePlaceThatTracksTheRunner() {
        let source = SourceGuardHelper.source("Overture/Domain/RunTimeouts.swift")
        #expect(source.contains("ProbeSelection.maxConcurrentLookups"))
    }
}
