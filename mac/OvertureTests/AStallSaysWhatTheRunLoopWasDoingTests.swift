import Testing
import Foundation

// #4114: a stall record says what the MAIN RUN LOOP was doing while the stall lasted.
//
// WHAT WAS MEASURED. On 2026-09-21 Dan opened a card's genre dropdown and clicked away without choosing
// anything. No write, no derivation, nothing to recompute. The log recorded 1.62s and 1.17s stalls, and
// the stack sample beside them (`KEPT-chunk-1790019449.txt`) has the main thread idle 95.5% of the
// window with no Overture code running at all. While a menu is up the main thread is in a NESTED event
// loop, and the watchdog's `DispatchQueue.main.async` block can wait there while the app is doing
// nothing wrong. A record saying "the window froze for 1.62s" is not measuring a freeze.
//
// THE SIZE OF THE CONTAMINATION, so nobody over-corrects: of 1,026 records that day, 56 (5.5%) carry no
// render pass and no render time, together 23.9s of a claimed 669.5s (3.6%), longest 2.12s. Every long
// stall filed that session (#4102, #4106, #4110, #4112) carries real render time and is unaffected.
//
// WHY FIX IT ANYWAY. #3660's bar is "no baseline-load main-thread stall over 100 ms, measured by the
// in-app watchdog". A bar judged by an instrument that counts menu-open time can never be met, and
// nothing would say why (L400, L11).
//
// RECORDED, NEVER EXCLUDED, and the issue is explicit about it. A rule that DROPPED these would also
// drop a real freeze that happened to occur while a menu was open, so `seconds` stays exactly as
// measured and this field says what the run loop was doing (L116). That is the same argument #4153 makes
// for sleep, which names this issue as its sibling, and this is the same shape.
//
// WHERE THE READING COMES FROM, and why it needs no help from the main thread. `CFRunLoopCopyCurrentMode`
// on `CFRunLoopGetMain()` is readable from ANY thread, so the watchdog takes it on its own queue. A
// reading that had to ask the main actor would be unavailable at exactly the moment a record is being
// written, which is the one moment it is wanted (L345, and `SurfaceBox`'s docstring makes the same point
// about the surface). Verified before anything was built on it: a background thread polling the main run
// loop sees a nested mode while the main thread is inside it, and sees NO mode at all when the main
// thread has left the run loop entirely.
//
// SAMPLED THROUGHOUT THE STALL, not only at its ends, and the skipped ping is what makes that free.
// `ping()` already fires every interval and returns immediately when one is still outstanding (#3635).
// That skip happens precisely while the main thread is wedged, so it is the one place in this design
// that is awake during a freeze with nothing to do. A 1.6s stall at the shipped 0.1s interval gives
// about sixteen samples.
@Suite("A stall says what the run loop was doing (#4114)")
struct AStallSaysWhatTheRunLoopWasDoingTests {

    // MARK: - Classifying one reading, so every case is PRODUCED rather than reasoned about (L151)

    // NULL from `CFRunLoopCopyCurrentMode` is a READING, not a failed one: it means the main run loop is
    // running no mode at all, which is the main thread being off the run loop and in code. Folding it
    // into `notRecorded` would make "nobody took a reading" and "the reading says the main thread is
    // wedged" one answer, and those call for opposite next steps (L98, L11).
    @Test func noModeAtAllMeansTheMainThreadIsOffTheRunLoop() {
        #expect(RunLoopActivity(modeName: nil) == .offTheRunLoop)
    }

    @Test func theDefaultModeIsOrdinary() {
        #expect(RunLoopActivity(modeName: "kCFRunLoopDefaultMode") == .ordinary)
    }

    // The mode an NSMenu tracks in, which is the one this issue was opened for.
    @Test func theEventTrackingModeIsTracking() {
        #expect(RunLoopActivity(modeName: "NSEventTrackingRunLoopMode") == .tracking)
    }

    // A mode this build does not name is still a mode the run loop really was in. It gets its own answer
    // rather than being called ordinary, which would claim more than the reading supports (L11, L440).
    @Test func aModeThisBuildCannotNameSaysSoRatherThanClaimingOrdinary() {
        #expect(RunLoopActivity(modeName: "NSConnectionReplyMode") == .otherMode)
        #expect(RunLoopActivity(modeName: "SomeModeNobodyHasWrittenYet") == .otherMode)
    }

    // THERE IS NO CASE FOR A MODAL PANEL, and that is a measurement rather than an omission.
    //
    // A case whose only input is a value nothing in the system ever produces reports zero for ever, and
    // zero is indistinguishable from a real measurement (L90). Overture holds no `runModal`, no
    // `NSSavePanel` and no `NSOpenPanel`, and the surface that looked most likely to raise one was
    // probed rather than reasoned about: a sheet-presented `NSAlert`, which is what every `.alert` in
    // this app becomes on macOS, was watched from a background thread on 2026-09-23 and the main run
    // loop went `kCFRunLoopDefaultMode`, `_NSMoveTimerRunLoopMode`, `kCFRunLoopDefaultMode`. It never
    // entered `NSModalPanelRunLoopMode` at all.
    //
    // So the mode classifies as `otherMode`, which is the honest answer for a mode that cannot arise
    // here, and the day this app grows a save panel the record says "a mode this build does not name"
    // rather than nothing.
    @Test func theModalPanelModeIsNotAClaimThisBuildMakes() {
        #expect(RunLoopActivity(modeName: "NSModalPanelRunLoopMode") == .otherMode)
        #expect(!RunLoopActivity.allCases.map(\.rawValue).contains("modal"), Comment(rawValue:
            "a case for a modal panel is back. Nothing in this app can put one up, so it would read "
            + "zero for ever and read exactly like a measurement (L90). If a panel really has been "
            + "added, re-take the probe before adding the case back."))
    }

    // AND THE MODE ORDINARY WINDOW WORK PASSES THROUGH IS NOT COUNTED AS A MENU, which is the half that
    // stops this over-accusing. `_NSMoveTimerRunLoopMode` was seen in the same probe with nothing wrong.
    @Test func theModeOrdinaryWindowWorkPassesThroughIsNotReadAsTracking() {
        #expect(RunLoopActivity(modeName: "_NSMoveTimerRunLoopMode") == .otherMode)
    }

    // MARK: - Folding several readings taken across one stall into the one the record carries

    // The question the field answers is whether this stall could be an artifact of a nested event loop,
    // so ANY nested mode seen during it outranks the ordinary mode seen either side of it. A stall that
    // spanned a menu opening reads `tracking` even though most of its samples are `ordinary`.
    @Test func aNestedModeSeenAtAnyPointOutranksTheOrdinaryModeAroundIt() {
        #expect(RunLoopActivity.moreTelling(.ordinary, .tracking) == .tracking)
        #expect(RunLoopActivity.moreTelling(.tracking, .ordinary) == .tracking)
        #expect(RunLoopActivity.moreTelling(.offTheRunLoop, .tracking) == .tracking)
        #expect(RunLoopActivity.moreTelling(.otherMode, .tracking) == .tracking)
        #expect(RunLoopActivity.moreTelling(.ordinary, .otherMode) == .otherMode)
        #expect(RunLoopActivity.moreTelling(.ordinary, .offTheRunLoop) == .offTheRunLoop)
    }

    // And a reading that was TAKEN always outranks one that was not, so a single sample landing inside a
    // stall is never lost to the absence around it.
    @Test func anyReadingOutranksNoReading() {
        #expect(RunLoopActivity.moreTelling(.notRecorded, .ordinary) == .ordinary)
        #expect(RunLoopActivity.moreTelling(.notRecorded, .offTheRunLoop) == .offTheRunLoop)
        #expect(RunLoopActivity.moreTelling(.notRecorded, .notRecorded) == .notRecorded)
    }

    // Folding is order independent, which is what lets the watchdog accumulate samples as they arrive
    // without holding them.
    @Test func foldingIsOrderIndependent() {
        let everyCase = RunLoopActivity.allCases
        for a in everyCase {
            for b in everyCase {
                #expect(RunLoopActivity.moreTelling(a, b) == RunLoopActivity.moreTelling(b, a),
                        Comment(rawValue: "folding \(a) with \(b) depends on the order they arrived in"))
            }
        }
    }

    // MARK: - The wiring, driven through the real watchdog

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
    }

    // The mode the main run loop is in, as a box a test can move, standing in for the one thing a test
    // cannot have: a real NSMenu tracking on Dan's Mac (L196).
    private final class Mode: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        init(_ initial: String?) { value = initial }
        var current: String? { lock.withLock { value } }
        func become(_ next: String?) { lock.withLock { value = next } }
    }

    private static let interval = 0.05
    private static let freeze = 0.6

    @Test func aStallTakenWhileAMenuWasTrackingSaysSo() async {
        let records = Records()
        let mode = Mode("NSEventTrackingRunLoopMode")
        let watchdog = MainThreadWatchdog(session: "tracking", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          mainRunLoopMode: { mode.current },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.allSatisfy { $0.runLoopActivity == .tracking }, Comment(rawValue:
            "a stall taken while the main run loop was tracking a menu recorded "
            + "\(String(describing: records.all.first?.runLoopActivity)) rather than .tracking, so "
            + "#3660's bar is still judged by an instrument that cannot tell menu-open time from a "
            + "freeze (#4114)"))
    }

    // THE OTHER HALF, and the one that makes the field readable at all. An ordinary freeze must say
    // `ordinary` rather than nothing, or "the run loop was in its usual mode" and "nobody was watching
    // the run loop" read alike (L98, L11).
    @Test func anOrdinaryFreezeSaysTheRunLoopWasOrdinaryRatherThanSayingNothing() async {
        let records = Records()
        let mode = Mode("kCFRunLoopDefaultMode")
        let watchdog = MainThreadWatchdog(session: "ordinary", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          mainRunLoopMode: { mode.current },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.allSatisfy { $0.runLoopActivity == .ordinary }, Comment(rawValue:
            "an ordinary freeze recorded \(String(describing: records.all.first?.runLoopActivity)) "
            + "rather than .ordinary, so a reader cannot tell a run loop in its usual mode from one "
            + "nothing was watching"))
    }

    // THE POINT OF THE DESIGN, and the test that fails if the reading is taken only at the ping's ends.
    // The menu goes up AFTER the ping was posted and comes down BEFORE it runs, so a watchdog that
    // sampled only at post and at run would see `kCFRunLoopDefaultMode` at both ends and record
    // `ordinary`. Only the samples taken on the SKIPPED pings, while the main thread is wedged, can see
    // it. That is the whole reason the skip is the sampling point.
    @Test func aMenuThatWentUpAndCameDownInsideTheStallIsStillSeen() async {
        let records = Records()
        let mode = Mode("kCFRunLoopDefaultMode")
        let watchdog = MainThreadWatchdog(session: "mid-stall", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          mainRunLoopMode: { mode.current },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async {
            // The main thread unavailable, with the menu up only in the MIDDLE of that window.
            Thread.sleep(forTimeInterval: freeze / 3)
            mode.become("NSEventTrackingRunLoopMode")
            Thread.sleep(forTimeInterval: freeze / 3)
            mode.become("kCFRunLoopDefaultMode")
            Thread.sleep(forTimeInterval: freeze / 3)
        }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.contains { $0.runLoopActivity == .tracking }, Comment(rawValue:
            "no record saw the menu that was up in the MIDDLE of the stall (records carried "
            + "\(records.all.map(\.runLoopActivity))), so the reading is being taken only at the ping's "
            + "ends and the contamination #4114 measured is still invisible"))
    }

    // MARK: - The record carries it across a round trip

    // Dan's log holds a thousand records written before this field existed, and they are milestone 80's
    // own "before" half. A decode that rejected them would destroy the comparison the field exists to
    // enable (L133), so absence decodes as `.notRecorded` rather than throwing.
    @Test func aRecordWrittenBeforeThisFieldExistedStillDecodes() throws {
        let line = #"{"session":"old","sequence":1,"at":"2026-09-21T19:37:43Z","seconds":1.62,"#
            + #""surface":"queue","load":"baseline","passes":0,"passSeconds":0}"#
        let data = try #require(line.data(using: .utf8))
        let record = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(record.runLoopActivity == .notRecorded)
        #expect(record.seconds == 1.62)
    }

    // A spelling a LATER build knows and this one does not must not fail the whole record, which is the
    // rule this file already applies to `surface`, `load` and `windows` (L26, L255).
    @Test func aSpellingThisBuildDoesNotKnowFoldsIntoNotRecordedRatherThanThrowing() throws {
        let line = #"{"session":"newer","sequence":1,"at":"2026-09-21T19:37:43Z","seconds":1.62,"#
            + #""surface":"queue","load":"baseline","runLoopActivity":"somethingAddedLater"}"#
        let data = try #require(line.data(using: .utf8))
        let record = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(record.runLoopActivity == .notRecorded)
        #expect(record.seconds == 1.62)
    }

    @Test func theActivitySurvivesTheRoundTripThroughTheLog() throws {
        let written = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 1_800_000_000),
                                  seconds: 1.62, surface: .queue, load: .baseline, loadAverage: 3.1,
                                  passes: 0, rootDraws: 0, passSeconds: 0, windows: .open,
                                  runLoopActivity: .tracking)
        let line = try #require(FreezeLog.line(for: written))
        let data = try #require(line.data(using: .utf8))
        let read = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(read.runLoopActivity == .tracking)
    }

    // MARK: - The wiring, because built is not wired (L3)

    // Every behavioural test above INJECTS the reading, so all of them would pass over a watchdog whose
    // default read nothing at all. What ships is what the app constructs, and `FreezeWatch` builds one
    // with `record:` alone, so the default IS the wiring.
    @Test func theShippedWatchdogTakesItsModeReadingFromTheMainRunLoop() {
        let source = SourceGuardHelper.source("Overture/Integration/MainThreadWatchdog.swift")
        #expect(!source.isEmpty, "MainThreadWatchdog could not be read, so this guard checked nothing")
        #expect(source.contains("mainRunLoopMode: @escaping @Sendable () -> String? "
                                + "= MainThreadWatchdog.mainRunLoopMode"), Comment(rawValue:
            "the watchdog's run loop reading is not defaulted to `MainThreadWatchdog.mainRunLoopMode`, "
            + "so the shipping app, which constructs one with `record:` alone, records nothing about it"))
        #expect(source.contains("CFRunLoopCopyCurrentMode(CFRunLoopGetMain())"), Comment(rawValue:
            "`MainThreadWatchdog.mainRunLoopMode` does not read the MAIN run loop's mode, which is the "
            + "only reading here that needs no help from the wedged main thread (L345)"))
    }

    @Test func theAppBuildsItsWatchdogWithoutOverridingTheReading() {
        let source = SourceGuardHelper.source("Overture/App/FreezeWatch.swift")
        #expect(!source.isEmpty, "FreezeWatch could not be read, so this guard checked nothing")
        #expect(source.contains("MainThreadWatchdog(record: {"), Comment(rawValue:
            "FreezeWatch no longer builds the watchdog with `record:` alone, so whether the shipping app "
            + "takes the default run loop reading is no longer something this guard can say"))
    }

    // MARK: - And whatever READS the log says it too (#4114 asks for this half by name)

    // A field written into the record and absent from the tool everybody reads the record with is a
    // field nothing consults (L46). That half is guarded by `scripts/what-froze-the-queue.test.sh`,
    // which drives the reader against built logs and asserts what it says about each case, rather than
    // by a source-text guard here.
    //
    // WHY NOT HERE. A guard asserting the script merely CONTAINS the word `runLoopActivity` was written
    // first and was seen to SURVIVE its own mutation: breaking the reader's list of nested modes left it
    // green, because the word was still in the file. A guard that cannot go red reads exactly like one
    // that works (L1, L135), so it was deleted rather than kept beside the real one.
}
