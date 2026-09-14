import Testing
import Foundation

// Three defects in what #3435 shipped, found by the end of turn review the same day and fixed here
// rather than filed, which is the standing rule for a finding about your own change.
@Suite("The freeze watchdog stands down, and its log is bounded (#3435)")
struct TheWatchdogStandsDownTests {

    private var watchdog: String { SourceGuardHelper.source("Overture/Integration/MainThreadWatchdog.swift") }
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var model: String { SourceGuardHelper.source("Overture/Domain/MainThreadStall.swift") }

    // 1. IT REALLY STANDS DOWN.
    //
    // The comment said "`pause()` is called when the app has no window on screen", and nothing called
    // anything: there was no `pause`, nothing called `stop`, and the watchdog pinged for the life of the
    // process. Overture is a menu bar app that sits with no window most of the day, and Dan's standing
    // rule is that an idle surface must pay nothing.
    //
    // A constraint recorded only as a comment is enforced by nothing, and sitting there it reads as
    // binding, so the first person to break it does so with every check green (L407). This is the check.
    @Test("something actually stops the watchdog when the window goes away")
    func theWatchdogIsStoodDown() {
        #expect(rootView.contains("freezeWatch.stop()"),
                Comment(rawValue: "nothing stops the freeze watchdog, so it pings for the life of the "
                        + "process on an app that sits idle most of the day (#3435, L353)"))
        #expect(rootView.contains("case .background: freezeWatch.stop()"),
                "the stand-down is not driven by the window going away")
        #expect(rootView.contains("@Environment(\\.scenePhase)"),
                "RootView cannot see whether its window is on screen, so nothing can drive the stand-down")
    }

    // And the comment says what the code does. It named a function that never existed, which is the
    // shape that made the first version look correct to a reader.
    @Test("the watchdog's own note describes what really happens")
    func theNoteMatchesTheCode() {
        #expect(!watchdog.contains("`pause()` is called"),
                Comment(rawValue: "the watchdog still claims a `pause()` nothing calls and nothing "
                        + "defines. A note describing behaviour the code does not have is worse than "
                        + "no note, because it is read as binding (L407)."))
        #expect(watchdog.contains("scene goes to the background"),
                "the note no longer names what actually stands it down")
    }

    // 2. EVERY SURFACE CASE HAS A WRITER.
    //
    // Four had none: a freeze with no window open reported `.queue`, which is WRONG rather than merely
    // incomplete. The repo's own PR rule is that anything nothing writes is deleted or carries the number
    // of the issue that activates it, and neither was done.
    //
    // Checked against the SOURCE that writes them rather than a list here, so a case added later without
    // a writer is caught by the same test (L96).
    @Test("every surface case is one something can actually record")
    func everySurfaceCaseHasAWriter() {
        // BOTH writers, because there are two and they are different in kind: `RootView` stamps the
        // surface on screen, and the watchdog's box holds `notRecorded` as its starting value, which is
        // what a stall recorded before anything ever stamped reports. Reading only the first would have
        // condemned the one case whose writer is a default (L11).
        let writers = rootView + watchdog
        let written = StallSurface.allCases.filter { writers.contains(".\($0.rawValue)") }
        let orphans = StallSurface.allCases.filter { !written.contains($0) }
        #expect(orphans.isEmpty,
                Comment(rawValue: "\(orphans.map(\.rawValue).joined(separator: ", ")) can never be "
                        + "recorded, so a freeze in that situation reports a different surface instead "
                        + "of saying it does not apply (L90, and this repo's writer rule)."))
        #expect(written.count >= 5, "read only \(written.count) writers, so this checked almost nothing")
    }

    // `noWindow` is gone rather than wired, and that is the consequence of the stand-down rather than a
    // separate decision: with the watchdog stopped whenever the window is away, a stall with no window
    // cannot be recorded, so a case for it would report zero forever (L90).
    @Test("there is no case for a state the stand-down makes impossible")
    func noWindowIsGone() {
        #expect(!model.contains("case noWindow"),
                "a surface case exists for a situation the watchdog is no longer running in")
    }

    // 3. THE LOG FILE IS BOUNDED.
    //
    // The cap was on the in-memory record and not on the file, so the file grew for the life of the
    // install. It only grows when the app really freezes, which is why this is slow rather than urgent,
    // and why compaction happens at LAUNCH rather than on the freeze path: an append is safe to do while
    // the main thread is wedged and a read-modify-write is not (L105).
    @Test("compaction keeps the newest records and says how many it dropped")
    func compactionKeepsTheNewest() {
        let records = (1...10).map { n in
            StallRecord(session: "s", sequence: n, at: Date(timeIntervalSince1970: 1_785_000_000),
                        seconds: 0.3, surface: .queue, load: .baseline, loadAverage: 1,
                        passes: nil)
        }
        let kept = FreezeLog.compacted(records, cap: 4)
        #expect(kept.records.count == 4)
        #expect(kept.records.map(\.sequence) == [7, 8, 9, 10], "it kept the oldest rather than the newest")
        #expect(kept.dropped == 6)
    }

    // THE ONE THAT MATTERS, and it is the same rule #3435 wrote for the in-memory store one layer down: a
    // cap by count over a file where a blip and a 58 second freeze are one line each means cheap writers
    // evict expensive observations, and the single reading this file exists to support is the maximum
    // (L191, L63).
    @Test("the longest stall survives compaction however old it is")
    func theLongestStallSurvivesCompaction() {
        var records = [StallRecord(session: "s", sequence: 1,
                                   at: Date(timeIntervalSince1970: 1_785_000_000), seconds: 58.0,
                                   surface: .queue, load: .baseline, loadAverage: 1,
                                   passes: nil)]
        records += (2...20).map { n in
            StallRecord(session: "s", sequence: n, at: Date(timeIntervalSince1970: 1_785_000_000),
                        seconds: 0.3, surface: .queue, load: .baseline, loadAverage: 1,
                        passes: nil)
        }
        let kept = FreezeLog.compacted(records, cap: 5)

        #expect(kept.records.contains(where: { $0.seconds == 58.0 }),
                Comment(rawValue: "the longest stall on record was compacted away by nineteen small "
                        + "ones, which is the eviction #3435 named as its own defect (L191, L63)"))
        #expect(kept.records.count == 5, "keeping the worst must not grow the file past its cap")
        #expect(kept.dropped == 15)
    }

    @Test("a file already under the cap is left exactly as it is")
    func aShortFileIsUntouched() {
        let records = (1...3).map { n in
            StallRecord(session: "s", sequence: n, at: Date(timeIntervalSince1970: 1_785_000_000),
                        seconds: 0.3, surface: .queue, load: .baseline, loadAverage: 1,
                        passes: nil)
        }
        let kept = FreezeLog.compacted(records, cap: 200)
        #expect(kept.records == records)
        #expect(kept.dropped == 0)
    }

    // Compaction happens where it is safe, and NOT on the path that runs during a freeze.
    @Test("the freeze path stays a pure append")
    func theFreezePathStaysAnAppend() {
        let append = SourceGuardHelper.bodyOfFunction(named: "append", in: SourceGuardHelper.source("Overture/Domain/FreezeLog.swift"))
        #expect(append?.contains("compacted") == false,
                Comment(rawValue: "the write that runs DURING a freeze now reads and rewrites the whole "
                        + "file. A read, modify, write whose read fails erases the record at exactly the "
                        + "moment it is worth having (L105)."))
    }
}
