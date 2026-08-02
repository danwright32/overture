import Testing
import Foundation
import SwiftData
@testable import Overture

// #1930: the diagnostic that turns "the idle queue re-derived twice" into "and this is what moved".
//
// The count added in #1774 proves an idle window is doing work, and says nothing about why. Reading the
// code to eliminate candidates is what produced #1930's own list, and two of its three entries were wrong
// on this Mac (the reconcile timer sits at its 30 minute default and the Downbeat export had not been
// written that day), so the third cannot be trusted either. This reports, per derivation, which of the
// inputs the queue derives from actually moved.
//
// The rule it reports by is pure and tested here, because a diagnostic used to judge everything else is
// the last thing that should be taken on trust.
@Suite("Each derivation says which of its inputs moved (#1930)")
struct QueueDerivationReasonTests {
    @Test func theFirstRenderHasNothingToCompareAgainst() {
        #expect(QueueRenderCounter.reason(for: ["prospects": "724"], since: [:])
                == QueueRenderCounter.firstRender)
    }

    // The answer that matters most: every input identical means the invalidation came from outside this
    // view entirely, which is a different investigation from any of the candidates named so far.
    @Test func identicalInputsSaySoExplicitly() {
        let inputs = ["prospects": "724", "gmail": "true"]
        #expect(QueueRenderCounter.reason(for: inputs, since: inputs) == QueueRenderCounter.nothingVisible)
    }

    @Test func everyInputThatMovedIsNamed() {
        let before = ["prospects": "724", "gmail": "true", "stage": "scout"]
        let after = ["prospects": "725", "gmail": "true", "stage": "review"]
        #expect(QueueRenderCounter.reason(for: after, since: before) == "prospects, stage")
    }

    // An input that stops being reported changed too. Dropping it silently would report an unchanged
    // render for one that was not the same shape at all.
    @Test func anInputThatDisappearedCountsAsMoved() {
        #expect(QueueRenderCounter.reason(for: ["prospects": "724"],
                                          since: ["prospects": "724", "departing": "1"]) == "departing")
    }

    @Test func recordingCountsAndRemembersWhatItSaw() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log, underTests: false)
        #expect(QueueRenderCounter.derivations == 1)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.firstRender)

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log, underTests: false)
        #expect(QueueRenderCounter.derivations == 2)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.nothingVisible)

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "725"], to: log, underTests: false)
        #expect(QueueRenderCounter.lastReason == "prospects")

        QueueRenderCounter.reset()
        #expect(QueueRenderCounter.derivations == 0)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.firstRender)
    }

    // Catching an idle trigger means leaving the app alone and reading what happened afterwards, so the
    // line has to actually reach the file, and a second one must not overwrite the first.
    @Test func everyDerivationAppendsALineToTheLog() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log, underTests: false)
        QueueRenderCounter.recordDerivation(inputs: ["prospects": "725"], to: log, underTests: false)

        let written = try String(contentsOf: log, encoding: .utf8)
        let lines = written.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\(QueueRenderCounter.queueSurface) #1 \(QueueRenderCounter.firstRender)"))
        #expect(lines[1].contains("\(QueueRenderCounter.queueSurface) #2 prospects"))
    }

    // Caught by reading the live log after a suite run: the unit suite hosts itself in the full app, so a
    // test run opens a real window that renders the real queue, and those renders were landing in the same
    // file a real observation is read from. Two runs of the app then sit interleaved in one log, each
    // starting again at #1, which is exactly the confusion the log exists to remove (it took working out
    // that a "first render" mid-file was a test run and not the queue re-derivating from scratch).
    @Test func aTestHostRenderNeverReachesTheRealLog() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log, underTests: true)

        // Still counted: the count is in-memory and harms nothing. Only the file is protected.
        #expect(QueueRenderCounter.derivations == 1)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    // A write that cannot land says so where the count is read, rather than leaving an empty log to be
    // mistaken for an idle queue that never re-derived at all.
    @Test func aFailedLogWriteIsReportedNotSwallowed() {
        QueueRenderCounter.reset()
        let unwritable = URL(fileURLWithPath: "/System/Overture-should-never-be-writable/derivations.log")

        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: unwritable, underTests: false)

        #expect(QueueRenderCounter.lastReason.contains("failed"))
        #expect(QueueRenderCounter.derivations == 1)
    }
}

// #1931: the fingerprint above describes the store by COUNTS, and an edit to an existing row (a show kept,
// a rank rewritten by a Prep run, a reply landing) leaves every count identical. So the one answer the
// diagnostic is trusted for, "nothing this view reads", was also what it said for a derivation the store
// genuinely caused, and a false one sends the next investigation hunting the screen above the queue for
// something the store did.
//
// The signal it uses instead is the derived ROWS: value-type snapshots this pass has already built, so
// reading them costs no fetch and no stat. That distinction is the whole point, and the measurement below
// pins it: the @Query array cannot see an in-place edit (QueryResultEqualityTests measured that), and the
// rows derived from it can.
@MainActor
@Suite("A derivation reports a row edit that moved no count (#1931)")
struct DerivationRowChangeTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, fit: Int) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium", performanceDate: "2026-11-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: fit, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The measurement the design rests on. QueryResultEqualityTests proved the @Query array and its count
    // are both blind to an in-place edit; this proves the derived rows are not, which is why they are the
    // signal. Without this half, using them would be an assumption rather than a measured fact.
    @Test func theDerivedRowsSeeAnEditNeitherTheArrayNorTheCountCanSee() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "a", fit: 5)
        show(ctx, key: "b", fit: 7)

        let before = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        p.fitScore += 1
        try ctx.save()
        let after = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()))

        #expect(before.count == after.count)   // the count says nothing moved
        #expect(before != after)               // the rows say what did
    }

    // The rule itself: every count identical, and the rows changed anyway.
    @Test func anEditedRowIsNamedInsteadOfReportingNothingChanged() {
        let inputs = ["prospects": "724", "gmail": "true"]
        #expect(QueueRenderCounter.reason(for: inputs, since: inputs, rowsChanged: true)
                == QueueRenderCounter.rowsChanged)
    }

    // An input that moved explains the derivation on its own, so it is what gets named. Saying both would
    // make the common case (a store write that changes a count AND the rows) read as two findings.
    @Test func anInputThatMovedIsNamedRatherThanTheRows() {
        #expect(QueueRenderCounter.reason(for: ["prospects": "725"], since: ["prospects": "724"],
                                          rowsChanged: true) == "prospects")
    }

    // Through the real recording path, which is what the log and the masthead read.
    @Test func recordingAnEditedRowReportsItAsTheReason() {
        QueueRenderCounter.reset()
        let inputs = ["prospects": "2"]
        let before = [item(id: "a", fit: 5), item(id: "b", fit: 7)]
        let after = [item(id: "a", fit: 6), item(id: "b", fit: 7)]

        QueueRenderCounter.recordDerivation(inputs: inputs, rows: before, underTests: true)
        QueueRenderCounter.recordDerivation(inputs: inputs, rows: after, underTests: true)

        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.rowsChanged)
    }

    // Unchanged rows still report the answer this whole diagnostic exists to make trustworthy.
    @Test func identicalRowsAndInputsStillReportNothingThisViewReads() {
        QueueRenderCounter.reset()
        let inputs = ["prospects": "1"]
        let rows = [item(id: "a", fit: 5)]

        QueueRenderCounter.recordDerivation(inputs: inputs, rows: rows, underTests: true)
        QueueRenderCounter.recordDerivation(inputs: inputs, rows: rows, underTests: true)

        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.nothingVisible)
    }

    // The edge the first render is: there is no earlier set of rows, so nothing may be claimed about
    // whether they changed.
    @Test func theFirstDerivationNeverClaimsTheRowsChanged() {
        QueueRenderCounter.reset()
        QueueRenderCounter.recordDerivation(inputs: ["prospects": "1"], rows: [item(id: "a", fit: 5)],
                                            underTests: true)
        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.firstRender)
    }

    private func item(id: String, fit: Int) -> QueueItem {
        QueueItem(id: id, groupName: "Vienna Philharmonic", discipline: "music", venue: "Stern Auditorium",
                  performanceDate: "2026-11-14", sourceListingURL: nil, websiteURL: nil,
                  priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: fit, tier: "high", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }
}

// #1930's stated next step. The first reading (2026-08-01) was a launch burst of five derivations, four of
// them reporting "nothing this view reads", then nothing at all across five idle minutes. Inputs identical
// every time means the invalidation arrives from OUTSIDE the queue, and the only way to name it is the same
// instrument one level up, on the screen that builds the queue.
//
// Both surfaces write to one log so the two streams interleave in the order they happened, which is what
// makes a queue derivation attributable to the render above it that triggered it.
@Suite("The screen above the queue keeps its own trace (#1930)")
struct RenderTraceSurfaceTests {
    // The failure this shape exists to avoid: one shared "previous inputs" would make every queue
    // derivation report the ROOT's inputs as having moved, and the diagnostic would name the wrong
    // surface on every single line.
    @Test func eachSurfaceComparesOnlyAgainstItsOwnPreviousRender() {
        QueueRenderCounter.reset()
        let queueInputs = ["prospects": "724"]

        QueueRenderCounter.recordDerivation(inputs: queueInputs, underTests: true)
        QueueRenderCounter.recordRender(surface: QueueRenderCounter.rootSurface,
                                        inputs: ["watchedSources": "37"], underTests: true)
        QueueRenderCounter.recordDerivation(inputs: queueInputs, underTests: true)

        #expect(QueueRenderCounter.lastReason == QueueRenderCounter.nothingVisible)
    }

    // A render above the queue does not count as a derivation: the masthead number is what says whether
    // the store is being swept, and a render that swept nothing must never inflate it.
    @Test func aRenderAboveTheQueueIsNotCountedAsADerivation() {
        QueueRenderCounter.reset()
        QueueRenderCounter.recordRender(surface: QueueRenderCounter.rootSurface,
                                        inputs: ["watchedSources": "37"], underTests: true)
        #expect(QueueRenderCounter.derivations == 0)
    }

    // Reading the log afterwards is the whole method, so every line has to say which surface it came from
    // and keep the order the two happened in.
    @Test func theLogNamesTheSurfaceOfEveryLine() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordRender(surface: QueueRenderCounter.rootSurface,
                                        inputs: ["watchedSources": "37"], to: log, underTests: false)
        QueueRenderCounter.recordDerivation(inputs: ["prospects": "724"], to: log, underTests: false)

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\(QueueRenderCounter.rootSurface) #1"))
        #expect(lines[1].contains("\(QueueRenderCounter.queueSurface) #1"))
    }

    // Same protection the queue's own recording has: a suite run hosts itself in the full app, so its
    // renders must never land in the file a real observation is read from.
    @Test func aTestHostRenderNeverReachesTheRealLog() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("derivations-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        QueueRenderCounter.reset()

        QueueRenderCounter.recordRender(surface: QueueRenderCounter.rootSurface,
                                        inputs: ["watchedSources": "37"], to: log, underTests: true)

        #expect(!FileManager.default.fileExists(atPath: log.path))
    }
}

// The wiring half. The rule above can be perfect and report nothing at all if the screen above the queue
// never records a render, and no running test can evaluate RootView's body (its @Query properties need a
// live container), so this guards the shape the way QueueInvalidationGuardTests does.
@Suite("The screen above the queue is actually wired to the trace (#1930)")
struct RootRenderTraceWiringTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // Both halves, because either alone is a trace that never runs: the recorder has to exist, and the
    // body has to call it (L3, built is not wired).
    @Test func theRootBodyRecordsEveryRender() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("QueueRenderCounter.recordRender(surface: QueueRenderCounter.rootSurface"))
        guard let body = SourceGuardHelper.propertyBody("var body: some View {", in: rootView) else {
            Issue.record("expected to find RootView's body")
            return
        }
        #expect(body.contains("traceRootRender()"))
    }

    // The fingerprint may not cost a fetch or a stat, or the diagnostic joins the problem it measures.
    // The Prep and reply run markers are the two live examples on this screen, and both are filesystem
    // stats, which is why the queue's own fingerprint leaves them out too.
    @Test func theRootFingerprintNeverCostsAStat() {
        guard let inputs = SourceGuardHelper.propertyBody("private var rootRenderInputs: [String: String] {",
                                                          in: rootView) else {
            Issue.record("expected to find rootRenderInputs")
            return
        }
        #expect(!inputs.contains("isRunning("))
        #expect(!inputs.contains("FileManager"))
        #expect(!inputs.contains("try? "))
    }
}
