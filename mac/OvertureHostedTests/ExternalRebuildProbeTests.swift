import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3805: WHAT re-derives the Archive when no data changed.
//
// `aScrollBuildsNoCards` fails about one full run in five, always with `queueRows` exactly equal to the
// seeded row count, never a partial tail. Measured 2026-09-13 across 484 runs by the Ovation session:
// ZERO failures in 208 runs with nothing else on the Mac (including 0 of 36 first-in-process), and all
// 21 failures while ANOTHER APP's hosted tests were in their testing phase, which was 6.1 percent of
// that guest's time. Spread over guest time that slice would hold about 1.3 of them.
//
// So something another process does while drawing makes this view re-derive the whole store. Two
// readings were already disproved by that data and are recorded so nobody re-runs them: leftover
// SwiftData observers from earlier tests (predicts MORE failure with more preceding tests, and #3805
// measures the opposite, worst when scoped), and an unsettled first render (predicts first-in-process
// failures, and solo it is 0 of 36).
//
// This probe does not wait for the coincidence. It fires candidate triggers itself, one at a time, in
// one process, and reports which of them costs a whole-store pass.
//
// WHY IT CAN BE BELIEVED, which is the whole design rather than a remark on it. Three arms are controls
// and are ASSERTED, so a run that reports "no trigger re-derives" cannot be a probe that was incapable
// of seeing one (L159, L98):
//
//   SETTLE    the first pass must complete before anything is measured, and its size is reported,
//             because whether it lands during `host()` or inside the settle window is itself the
//             measurement that disproved the unsettled-first-render reading.
//   NULL      no trigger at all must cost ZERO rows. A harness that is not quiet attributes its own
//             noise to whichever arm runs next.
//   POSITIVE  a real store write must cost a whole pass. If this reads zero the probe cannot detect a
//             re-derivation at all and every other number here is meaningless.
//
// WHAT IT CANNOT SEE, said plainly. Posting a notification is not the state change itself: AppKit and
// SwiftUI may do more on a real activation or occlusion change than the notification carries. A trigger
// reading zero here is therefore NOT proof that the real event is innocent, only that the notification
// alone does not do it. The two-app arm is what settles that, and it is queued separately.
//
// OPT IN, like every stopwatch here: it is a diagnostic, it holds a deadline per arm, and a loaded Mac
// could make a slow rebuild look like an absent one. The controls are what bound that risk.
@MainActor
@Suite("What re-derives the Archive when no data changed (#3805)")
struct ExternalRebuildProbeTests {

    // The Archive suite's own corpus, so the number this prints is comparable with the failure it is
    // about, which reads exactly 120 every time.
    static let seededRows = 120

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self, WatchedSource.self, RefusedContactAddress.self, PromotedProducer.self, DemotedHouse.self])
    }

    private func seed(_ ctx: ModelContext, rows: Int = seededRows) {
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Weill Recital Hall",
                             performanceDate: String(format: "2027-%02d-%02d", 1 + (n % 12), 1 + (n % 27)),
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            ctx.insert(p)
        }
        try? ctx.save()
    }

    // #3480's rig, and `isReleasedWhenClosed = false` is required by
    // `TestWindowsAreNotReleasedOnCloseGuardTests`: AppKit's default releases a window this scope still
    // holds, which crashed the shared app host and truncated the whole hosted target.
    // NOT `AnyView`, and the difference is load bearing rather than tidiness. Every other hosted suite
    // here wraps its root in `AnyView`, which type-erases it, and SwiftUI cannot diff an erased view
    // structurally: an invalidation re-evaluates everything inside it. The APP contains ZERO `AnyView`
    // (measured 2026-09-13 across `mac/Overture`), so a rig that erases is measuring a view tree the
    // product does not have, and a whole-store pass seen through one could be the wrapper rather than
    // the screen. This probe exists to say what the PRODUCT costs, so it hosts the real type.
    private func host<V: View>(_ view: V) -> (window: NSWindow, hosting: NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Run one arm: fire `trigger`, then turn the run loop until a pass appears or the deadline passes.
    //
    // The pump deliberately does NOT lay out or display, because that is itself one of the candidate
    // triggers and doing it here would contaminate every other arm with the thing arm 7 exists to test.
    // It stops the moment a row is built, so a trigger that fires is fast and only a trigger that does
    // nothing costs its whole deadline (L290).
    private func rowsProvokedBy(_ trigger: () -> Void, seconds: Double = 1.5) -> Int {
        QueueRenderPass.WorkTally.measure {
            trigger()
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline && (QueueRenderPass.WorkTally.current?.queueRows ?? 0) == 0 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }.queueRows
    }

    @Test func whatCostsAWholeStorePassWithNoDataChange() throws {
        guard ProcessInfo.processInfo.environment["PROBE_EXTERNAL_REBUILD"] != nil else {
            // Not silently skipped: an instrument that says nothing is indistinguishable from one that
            // ran and found nothing (L98).
            print("external-rebuild-probe: not measured. Set TEST_RUNNER_PROBE_EXTERNAL_REBUILD=1 to run it.")
            return
        }
        // #3842: a locked session never lays this window out, so every arm below would read zero and the
        // probe would report every trigger innocent (L98, L11).
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("ExternalRebuildProbeTests.whatCostsAWholeStorePassWithNoDataChange")
            return
        }

        let c = try container()
        let ctx = ModelContext(c)
        seed(ctx)

        let view = RowsFromStore { (rows: [Prospect]) in ArchiveView(prospects: rows) }
            .modelContainer(c)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest())
        let (window, hosting) = host(view)
        defer { window.close() }

        // SETTLE. Reported as well as asserted: a zero here means the first pass completed inside
        // `host()`, and a full count means it landed in this window instead, which is the reading that
        // disproved the unsettled-first-render story.
        let settle = QueueRenderPass.WorkTally.measure {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline
                    && (QueueRenderPass.WorkTally.current?.queueRows ?? 0) < Self.seededRows {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        // NULL CONTROL, before any trigger: the harness must be quiet at rest.
        let quiet = rowsProvokedBy({})

        // THE CANDIDATE TRIGGERS, each a thing another app's hosted tests plausibly cause here.
        //
        // ORDER IS LOAD BEARING and this first arm exists because the arms are NOT independent. The
        // first version of this probe posted resign-active, become-active and resign-key before it
        // posted become-key, read 120 on become-key, and attributed the pass to becoming key alone. A
        // separate guard posting ONLY become-key then read 0. So the arms have to be read as a
        // sequence, and this arm is the control for that: become-key with NOTHING posted before it.
        //
        //   this reads 120   becoming key alone does it, and the guard's green needs another explanation
        //   this reads 0     the trigger is the TRANSITION, and what matters is what preceded it
        var readings: [(String, Int)] = []
        readings.append(("became key, nothing before it", rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window) }))
        readings.append(("app resigned active",
                         rowsProvokedBy { NotificationCenter.default.post(
                            name: NSApplication.didResignActiveNotification, object: NSApp) }))
        readings.append(("app became active",
                         rowsProvokedBy { NotificationCenter.default.post(
                            name: NSApplication.didBecomeActiveNotification, object: NSApp) }))
        readings.append(("window resigned key",
                         rowsProvokedBy { NotificationCenter.default.post(
                            name: NSWindow.didResignKeyNotification, object: window) }))
        readings.append(("window became key",
                         rowsProvokedBy { NotificationCenter.default.post(
                            name: NSWindow.didBecomeKeyNotification, object: window) }))
        readings.append(("occlusion state changed",
                         rowsProvokedBy { NotificationCenter.default.post(
                            name: NSWindow.didChangeOcclusionStateNotification, object: window) }))
        readings.append(("screen parameters changed",
                         rowsProvokedBy { NotificationCenter.default.post(
                            name: NSApplication.didChangeScreenParametersNotification, object: NSApp) }))
        // The display cycle, which is what the guest is actually doing while it draws, and the arm the
        // Ovation session asked for: its failures clustered in the guest's TESTING phase rather than
        // around the guest app's launch, which points at drawing rather than at activation alone.
        readings.append(("forced layout and display", rowsProvokedBy {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }))
        readings.append(("window appearance changed", rowsProvokedBy {
            window.appearance = NSAppearance(named: .darkAqua)
        }))
        // The RESET is itself one of the candidate triggers, so it is measured and DISCARDED rather than
        // left loose above the positive control. `rowsProvokedBy` returns the moment a row appears, so a
        // rebuild provoked by the reset would otherwise be counted as the WRITE's, which is this file's
        // own named hazard: a positive control that passes for the wrong reason licenses every zero
        // above it (L98, L159).
        _ = rowsProvokedBy { window.appearance = nil }
        let resetSettleBy = Date().addingTimeInterval(10)
        while Date() < resetSettleBy && rowsProvokedBy({}, seconds: 0.3) != 0 { }

        // POSITIVE CONTROL, LAST because it is the only arm that changes the store. If this reads zero
        // the probe cannot see a re-derivation at all and nothing above means anything.
        let onARealWrite = rowsProvokedBy({
            let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            rows.first?.fitScore = 9
            try? ctx.save()
        }, seconds: 20)

        print("""
        external-rebuild-probe: \(Self.seededRows) rows, one process, nothing else driven (#3805)
          settle, the first pass          \(settle.queueRows) rows \
        (\(settle.queueRows == 0 ? "completed inside host()" : "landed in the settle window"))
          NULL control, no trigger        \(quiet) rows
        """)
        for (name, rows) in readings {
            let label = name.padding(toLength: 32, withPad: " ", startingAt: 0)
            let flag = rows >= Self.seededRows ? "   <-- A WHOLE STORE PASS" : ""
            print("  \(label)\(rows) rows\(flag)")
        }
        print("  POSITIVE control, a write       \(onARealWrite) rows")

        // The three claims this probe rests on, asserted rather than printed, because a probe that
        // cannot see a pass reports every trigger innocent and reads exactly like good news.
        #expect(quiet == 0, Comment(rawValue:
                "the harness built \(quiet) rows with NO trigger at all, so it is not quiet at rest and "
                + "every reading below it is attributing its own noise to whichever arm ran next"))
        #expect(onARealWrite >= Self.seededRows, Comment(rawValue:
                "a real store write provoked \(onARealWrite) rows out of \(Self.seededRows), so this "
                + "probe cannot detect a whole-store re-derivation and every trigger it reports as "
                + "innocent is unmeasured rather than clean (L98)"))
    }

    // THE GUARD, and unlike the two probes around it this one rides along on every push and carries no
    // clock. #3876: bringing the window to the front must cost NOTHING, because nothing changed.
    //
    // Its two controls are what make a zero mean anything. The settle waits for the surface to go QUIET
    // rather than for a fixed time, and the POSITIVE control runs in the same fixture afterwards, so a
    // run where the view was never live reports a failed positive control instead of a reassuring zero
    // (L159, L98). The order matters: the trigger is fired BEFORE the write, because the write is the
    // only thing here that changes the store.
    //
    // Reading a red under LOAD is safe and a green under load is not: heavy load can only make a real
    // rebuild miss its deadline, which turns a 120 into a 0, so it can hide this defect and never invent
    // it.
    @Test func becomingKeyCostsNoWholeStorePass() throws {
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("ExternalRebuildProbeTests.becomingKeyCostsNoWholeStorePass")
            return
        }

        let c = try container()
        let ctx = ModelContext(c)
        seed(ctx)

        let view = RowsFromStore { (rows: [Prospect]) in ArchiveView(prospects: rows) }
            .modelContainer(c)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest())
        let (window, _) = host(view)
        defer { window.close() }

        // PROVE IT DREW, before anything is concluded from a quiet counter. Settling only requires one
        // 0.3s window with no rows, which a surface whose first pass has not STARTED satisfies instantly.
        // A late first render then lands in the become-key window, reads 120, and this guard reports the
        // defect it exists to catch while the positive control afterwards still passes. `whetherTheMain
        // QueueDoesItToo` calls its own warm-up not optional for the mirror-image reason, and this is the
        // only test here that runs on every push (L98, L159).
        let drew = rowsProvokedBy({
            let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            all.last?.fitScore = 8
            try? ctx.save()
        }, seconds: 60)
        #expect(drew >= Self.seededRows, Comment(rawValue:
                "the Archive built \(drew) rows out of \(Self.seededRows) from a real write, so it never "
                + "drew and every reading below would come from an empty surface rather than a quiet one"))

        // Settle on the CONDITION of being quiet, never on a duration: a fixed wait here would be an
        // assertion about how loaded the Mac is (L290).
        var settled = false
        let settleBy = Date().addingTimeInterval(30)
        while Date() < settleBy {
            if rowsProvokedBy({}, seconds: 0.3) == 0 { settled = true; break }
        }
        #expect(settled, "the Archive never stopped building rows, so a zero below would prove nothing")

        // ESTABLISH THE STATE FIRST, and this is not ceremony: it is what makes the reading below
        // deterministic. The trigger is the key status CHANGING, in either direction, not becoming key
        // as such. Posting become-key to a window SwiftUI already treats as key changes nothing and
        // costs nothing, so a guard that posts only become-key passes or fails on whatever state the
        // window happened to be in when the test started. This one measured green once and red once on
        // the same code before that was understood, which is the whole reason this step exists.
        //
        // The cost of this transition is deliberately discarded: it is setup, and asserting on it would
        // report the defect twice while making the message below ambiguous about which transition it meant.
        _ = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        var requiet = false
        let requietBy = Date().addingTimeInterval(30)
        while Date() < requietBy {
            if rowsProvokedBy({}, seconds: 0.3) == 0 { requiet = true; break }
        }
        #expect(requiet, Comment(rawValue:
                "the Archive never went quiet after the setup transition, so the reading below would "
                + "measure the tail of that rather than the transition under test"))

        let onBecomingKey = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }

        // POSITIVE CONTROL, in the same fixture and after the trigger, because it writes.
        let onARealWrite = rowsProvokedBy({
            let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            rows.first?.fitScore = 9
            try? ctx.save()
        }, seconds: 20)
        #expect(onARealWrite >= Self.seededRows, Comment(rawValue:
                "a real store write provoked \(onARealWrite) rows out of \(Self.seededRows), so this "
                + "fixture cannot see a re-derivation at all and the reading beside it is unmeasured "
                + "rather than clean (L98)"))

        #expect(onBecomingKey == 0, Comment(rawValue:
                "a change in the window's key status derived \(onBecomingKey) rows out of "
                + "\(Self.seededRows), which is the whole store rebuilt because focus moved and for no "
                + "other reason (#3876). Either direction does it, so this is one reading of a pair. "
                + "The scope must be derived from its INPUTS, not once per body evaluation, because a "
                + "body runs for reasons that are not data changes at all (L471, L383)."))
    }

    // WHICH PART of the screen reacts to focus, so the safe fix can be aimed rather than guessed.
    //
    // EVERY VARIANT CARRIES ITS OWN POSITIVE CONTROL, in the same fixture, seconds apart, and that is
    // what makes this runnable on a busy Mac. A variant is only read as innocent when its key reading is
    // ZERO **and** its write reading is a whole pass: the harness has then just demonstrated that it can
    // see a pass and did not see one for the trigger. Load takes the positive control down with it, so a
    // starved run reports UNMEASURED rather than a false all clear (L98, L159, L411).
    private func focusReading<V: View>(_ build: ([Prospect]) -> V) -> (key: Int, write: Int, settled: Bool) {
        guard let c = try? container() else { return (-1, -1, false) }
        let ctx = ModelContext(c)
        seed(ctx)
        let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let (window, _) = host(build(rows)
            .modelContainer(c)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest()))
        defer { window.close() }

        func quieten() -> Bool {
            let by = Date().addingTimeInterval(30)
            while Date() < by {
                if rowsProvokedBy({}, seconds: 0.3) == 0 { return true }
            }
            return false
        }
        let settled = quieten()
        // Establish the state, as the guard does: the trigger is the key status CHANGING.
        _ = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        _ = quieten()
        let key = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
        let write = rowsProvokedBy({
            rows.first?.fitScore = 9
            try? ctx.save()
        }, seconds: 20)
        return (key, write, settled)
    }

    @Test func whichPartOfTheScreenReactsToFocus() throws {
        guard ProcessInfo.processInfo.environment["PROBE_EXTERNAL_REBUILD"] != nil else {
            print("external-rebuild-probe: not measured. Set TEST_RUNNER_PROBE_EXTERNAL_REBUILD=1 to run it.")
            return
        }
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("ExternalRebuildProbeTests.whichPartOfTheScreenReactsToFocus")
            return
        }

        // A view that derives the scope in its body and NOTHING else. If this rebuilds on a key change,
        // then re-evaluation on focus is what SwiftUI does to a hosted tree, no part of the Archive is
        // to blame, and isolating a sensitive element cannot be the fix.
        let bare = focusReading { rows in ScopeProbe(prospects: rows) { EmptyView() } }
        // The same, plus a focus participant, which is the cheapest thing that could explain it.
        let withAField = focusReading { rows in
            ScopeProbe(prospects: rows) { TextField("q", text: .constant("")) }
        }
        // THE SIBLING, added after code review on #3878 found the PR's own sweep too narrow to see it.
        // `FollowUpsView` has the identical shape: `@Environment(\\.dismiss)` at view level (`:10`), a
        // whole-table `@Query prospects` (`:15`), `makeRenderData()` called from `body` (`:128`), and one
        // `dismiss()` call site (`:138`). It also carries #3861's measured, unattributed freezes.
        //
        // IT READS UNMEASURED, and that is the instrument refusing rather than failing. `WorkTally` counts
        // QUEUE rows; `FollowUpsRenderPass` increments none of its counters, so this harness cannot see a
        // follow-ups pass at all. Its own positive control does not fire, so the arm reports UNMEASURED
        // instead of the false all clear a bare zero would have been (L98). Measuring it needs a counter
        // on that pass, which is app instrumentation and belongs with the sibling fix, not here. The arm
        // is kept deliberately: an absent arm and an unmeasurable one read alike, and this one says which.
        let followUps = focusReading { _ in FollowUpsView() }
        // THE SECOND SUSPECT, after the banner came back quiet. Comparing the two screens' property
        // wrappers, `ArchiveView` reads `@Environment(\\.dismiss)` and `QueueView` does not, which is
        // the kind of value a presentation context can revise when focus moves.
        let readingDismiss = focusReading { rows in DismissProbe(prospects: rows) }
        // THE FIRST SUSPECT, narrowed by comparing the two screens rather than by guessing. The Queue does not
        // rebuild on focus and the Archive does, both built on the same store-to-screen path, so the
        // difference is something the Archive holds and the Queue does not. Of the focus-relevant
        // modifiers, exactly one is on the Archive and absent from the Queue: `.actionFeedbackBanner()`.
        // Both carry `.sendConfirmAndReconnectAlerts`, so that one cannot be it.
        let withTheBanner = focusReading { rows in
            ScopeProbe(prospects: rows) { EmptyView() }.actionFeedbackBanner()
        }
        // The real screen, as the reference the other two are read against.
        let theArchive = focusReading { rows in ArchiveView(prospects: rows) }

        func line(_ name: String, _ r: (key: Int, write: Int, settled: Bool)) -> String {
            let verdict: String
            if r.write < Self.seededRows { verdict = "UNMEASURED, its own positive control did not fire" }
            else if r.key >= Self.seededRows { verdict = "REBUILDS on a key change" }
            else if r.key == 0 { verdict = "quiet" }
            else { verdict = "partial, worth reading by hand" }
            return "  \(name.padding(toLength: 30, withPad: " ", startingAt: 0))"
                + "key \(r.key), write \(r.write)   \(verdict)"
        }
        print("""
        external-rebuild-probe, which part reacts to focus (#3876)
        \(line("scope only, nothing else", bare))
        \(line("scope plus a text field", withAField))
        \(line("scope plus the feedback banner", withTheBanner))
        \(line("scope plus a dismiss read", readingDismiss))
        \(line("FollowUpsView, the sibling", followUps))
        \(line("the real ArchiveView", theArchive))
        """)

        #expect(bare.settled && withAField.settled && withTheBanner.settled
                && readingDismiss.settled && theArchive.settled,
                "a variant never went quiet, so its readings are the tail of its first render")
        #expect(theArchive.write >= Self.seededRows, Comment(rawValue:
                "the reference variant's positive control read \(theArchive.write), so this whole "
                + "comparison is unmeasured rather than informative (L98)"))
    }

    // DOES THE MAIN SURFACE DO IT TOO, which is the question that decides what this costs Dan.
    //
    // `ArchiveView` is a SHEET (`RootView.swift:1261`), so a freeze on it is paid only while that sheet
    // is open. `QueueView` is the surface he actually lives in. Until this arm existed, #3876's impact
    // was an extrapolation from the sheet.
    //
    // THE WARM-UP IS NOT OPTIONAL HERE and this arm would silently lie without it. `FeltWaitCostTests`
    // measured it on 2026-09-05: a hosted `QueueView` whose window is never ordered front evaluates NO
    // body from laying out and pumping, sixty seconds of it building zero cards, and what provokes it is
    // a SwiftData change. So an unwarmed Queue reads 0 on the focus trigger while its positive control
    // still fires on the write, which is the exact shape of a control that passes for the wrong reason:
    // "quiet on focus" and "never drew at all" are the same number (L98, L159).
    @Test func whetherTheMainQueueDoesItToo() throws {
        guard ProcessInfo.processInfo.environment["PROBE_EXTERNAL_REBUILD"] != nil else {
            print("external-rebuild-probe: not measured. Set TEST_RUNNER_PROBE_EXTERNAL_REBUILD=1 to run it.")
            return
        }
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("ExternalRebuildProbeTests.whetherTheMainQueueDoesItToo")
            return
        }

        let c = try container()
        let ctx = ModelContext(c)
        seed(ctx)
        let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let (window, _) = host(QueueHarness(container: c))
        defer { window.close() }

        // WARM: a throwaway write on a row this test never asserts about, pumped until the list has
        // actually built. Asserted, because everything below is meaningless if it did not.
        let warm = rowsProvokedBy({
            rows.last?.fitScore = 8
            try? ctx.save()
        }, seconds: 60)
        #expect(warm > 0, Comment(rawValue:
                "the Queue built \(warm) rows from a real write, so it never drew and the focus reading "
                + "below would be a zero from an empty surface rather than from a quiet one (L98)"))

        func quieten() -> Bool {
            let by = Date().addingTimeInterval(30)
            while Date() < by {
                if rowsProvokedBy({}, seconds: 0.3) == 0 { return true }
            }
            return false
        }
        _ = quieten()
        _ = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        _ = quieten()
        let onKeyChange = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }
        let onARealWrite = rowsProvokedBy({
            rows.first?.fitScore = 9
            try? ctx.save()
        }, seconds: 30)

        print("""
        external-rebuild-probe, the MAIN queue surface (#3876)
          warm-up write, did it draw      \(warm) rows
          key status changed              \(onKeyChange) rows\
        \(onKeyChange > 0 ? "   <-- THE MAIN SURFACE REBUILDS ON FOCUS" : "   (quiet)")
          POSITIVE control, a write       \(onARealWrite) rows
        """)

        #expect(onARealWrite > 0, Comment(rawValue:
                "the positive control read \(onARealWrite), so this arm measured nothing and its focus "
                + "reading is unmeasured rather than clean (L98)"))
    }

    // WHICH HALF re-derives, because the answer decides whether this is a product defect or a property
    // of the test harness, and guessing it is exactly the leap that was wrong twice already tonight.
    //
    // The first probe hosts `RowsFromStore`, a `@Query` playing RootView's part (#3846). So a whole-store
    // pass on becoming key is either the PROSPECT QUERY re-fetching and handing down a new array, or the
    // view re-evaluating what it was already given. This runs the SAME trigger against rows handed in as
    // a plain array, fetched once, here.
    //
    // WHAT THIS ARM CANNOT SETTLE, corrected after code review on #3878 and worth stating precisely,
    // because the earlier wording claimed more than the fixture supports. Removing `RowsFromStore`
    // removes the PROSPECT query only: `ArchiveView` still declares five of its own
    // (`orgAnswers`, `refusedAddresses`, `promotedProducers`, `demotedHouses`, `watchedSources`,
    // `ArchiveView.swift:66` onward), so the tree is not query-free and a 120 here does not by itself
    // acquit every query.
    //
    //   this arm reads 0    the prospect query re-fetching is the whole story
    //   this arm reads 120  something OTHER than the prospect query re-fires, and which is not said here
    //
    // What DOES settle it is the `scope plus a dismiss read` variant in `whichPartOfTheScreenReactsToFocus`:
    // `DismissProbe` holds no `@Query` at all and still rebuilds, so the trigger is an environment read
    // rather than any query. Read that arm for the conclusion and this one only for the prospect query.
    @Test func whetherItIsTheQueryOrTheView() throws {
        guard ProcessInfo.processInfo.environment["PROBE_EXTERNAL_REBUILD"] != nil else {
            print("external-rebuild-probe: not measured. Set TEST_RUNNER_PROBE_EXTERNAL_REBUILD=1 to run it.")
            return
        }
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("ExternalRebuildProbeTests.whetherItIsTheQueryOrTheView")
            return
        }

        let c = try container()
        let ctx = ModelContext(c)
        seed(ctx)
        let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        #expect(rows.count == Self.seededRows,
                "the fixture did not seed, so this arm would read zero for the wrong reason")

        // No `RowsFromStore`, so no PROSPECT query. The view's own five queries remain, which is why the
        // header above is careful about what this can conclude.
        let view = ArchiveView(prospects: rows)
            .modelContainer(c)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest())
        let (window, _) = host(view)
        defer { window.close() }

        let settle = QueueRenderPass.WorkTally.measure {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline
                    && (QueueRenderPass.WorkTally.current?.queueRows ?? 0) < Self.seededRows {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        let quiet = rowsProvokedBy({})
        let onBecomingKey = rowsProvokedBy {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }

        // POSITIVE CONTROL, which this arm was missing. Without it a surface that never drew reads 0 for
        // the trigger, 0 for the null control, and passes, while the table above reports a conclusion
        // drawn from a window that rendered nothing. Every other arm in this file runs one (L98, L159).
        let onARealWrite = rowsProvokedBy({
            rows.first?.fitScore = 9
            try? ctx.save()
        }, seconds: 20)

        print("""
        external-rebuild-probe, no PROSPECT query in the tree (#3805)
          settle, the first pass          \(settle.queueRows) rows
          NULL control, no trigger        \(quiet) rows
          window became key               \(onBecomingKey) rows\
        \(onBecomingKey >= Self.seededRows ? "   <-- A WHOLE STORE PASS" : "")
          POSITIVE control, a write       \(onARealWrite) rows
        """)

        #expect(quiet == 0, Comment(rawValue:
                "the harness built \(quiet) rows with no trigger, so the reading beside it is noise"))
        #expect(onARealWrite >= Self.seededRows, Comment(rawValue:
                "a real store write provoked \(onARealWrite) rows out of \(Self.seededRows), so this arm "
                + "never drew and its reading is unmeasured rather than informative (L98)"))
    }
}

// A view that derives the scope in its body and holds only what it is given, so a variant of it isolates
// ONE suspect at a time. Deliberately in the test target rather than the app: the question is which kind
// of content makes a body re-evaluate on a focus change, and answering it by deleting parts of
// `ArchiveView` would churn a hot path that several guards read.
private struct ScopeProbe<Extra: View>: View {
    let prospects: [Prospect]
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        let scope = QueueModel.scope(from: prospects)
        VStack(alignment: .leading) {
            Text("\(scope.rows.count) rows")
            extra()
        }
    }
}

// RootView's part for the Queue, matching `FeltWaitCostTests.Harness`, so the main surface is measured
// through the same store-to-screen path the app uses rather than a shape invented here.
private struct QueueHarness: View {
    let container: ModelContainer
    @State private var deepLinkedKey: LeadDeepLink?
    @State private var deepLinkedKeys: LeadsDeepLink?
    @State private var feedback = ActionFeedback()
    @State private var dayOffOffer = DayOffOfferRequest()

    var body: some View {
        RowsFromStore { (rows: [Prospect]) in
            QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys, allProspects: rows)
        }
        .modelContainer(container)
        .environment(feedback)
        .environment(dayOffOffer)
    }
}

// The same probe, but reading the one environment value `ArchiveView` holds and `QueueView` does not.
// The read has to happen IN the body: an `@Environment` property that is never accessed registers no
// dependency, so an unread one would test nothing while looking like it tested something.
private struct DismissProbe: View {
    let prospects: [Prospect]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let scope = QueueModel.scope(from: prospects)
        let _ = dismiss
        VStack(alignment: .leading) {
            Text("\(scope.rows.count) rows")
        }
    }
}
