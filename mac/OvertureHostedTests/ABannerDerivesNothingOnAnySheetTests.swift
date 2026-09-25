import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4197: raising a banner with NO data change must not re-derive the sheet it is drawn over.
//
// #4112 measured this on the Sources sheet (`RemovingOneSourceCostsOnePassTests`) and the issue named
// four more surfaces that apply `.actionFeedbackBanner()` and derive on their render path: Follow-ups,
// Days off, Skipped towns and Struck addresses. This suite takes the same reading on each of them.
//
// THE REAL TYPE IS HOSTED, NOT AN `AnyView`, and that is the difference this suite exists to respect.
// `ExternalRebuildProbeTests` records why: the app contains no `AnyView`, SwiftUI cannot diff an erased
// view structurally, and a rig that erases the root measures a view tree the product does not have
// (L472). The banner is drawn by a `ViewModifier` that reads the feedback object in its OWN body, so in
// the product a message invalidates the modifier and not the sheet beneath it, unless the sheet's own
// body reads the feedback object while it is evaluated.
//
// So the claim asserted is the one that matters to Dan, stated as a count: a message costs each of these
// sheets ZERO derivations. It is a count and not a duration because a count is a statement about this
// code and a duration is a statement about the machine (L63).
//
// THE READING, taken before anything was memoised, as the issue asked (2026-09-25): all four sheets
// derived ZERO times for a banner, at the live store's size. So none of them was given a `ScopeMemo`:
// a memo there would protect nothing and still cost a key to keep complete. What CAN break the zero is
// the sheet reading the feedback object in its own body, seen by adding `let _ = feedback.revision` to
// the Follow-ups body, which made this suite read one derivation over one evaluation. That read is what
// `ABannerSurfaceNeverReadsItsBannerGuardTests` refuses on every banner surface, including ones added later.
//
// TWO CONTROLS, both asserted. The sheet's own banner must be mounted and carrying the message, or a
// zero below would mean the banner never arrived (L159). And the sheet must have derived at least once
// while appearing, so a counter that was never wired cannot read as a sheet that never derived (L98).
@MainActor
@Suite("A banner with no data change derives nothing on any sheet (#4197)", .serialized)
struct ABannerDerivesNothingOnAnySheetTests {

    // The live store's shape, read off a copy on 2026-09-25: 1,340 prospects and 47 struck addresses.
    // A two row fixture is exactly what hides a re-derivation, since the work per pass scales with the
    // list (L606, L354).
    static let prospectCount = 1340
    static let struckCount = 47

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private func seedProspects(_ ctx: ModelContext) -> [Prospect] {
        var rows: [Prospect] = []
        for n in 0..<Self.prospectCount {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Weill Recital Hall",
                             performanceDate: String(format: "2027-%02d-%02d", 1 + (n % 12), 1 + (n % 27)),
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: n % 4 == 0 ? .contacted : .new)
            if n % 4 == 0 {
                // Pitched a month ago and never chased, so the Follow-ups sheet has rows to draw and its
                // derivation does real work rather than taking the empty short circuit (L101).
                let r = Recipient(id: "contact-\(n)@example.invalid", email: "contact-\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = .sent
                r.outreachChannel = .email
                r.replied = false
                r.bounced = false
                r.sentAt = Date().addingTimeInterval(-60 * 60 * 24 * 30)
                p.recipients.append(r)
            }
            ctx.insert(p)
            rows.append(p)
        }
        try? ctx.save()
        return rows
    }

    private func host<V: View>(_ view: V) -> (window: NSWindow, hosting: NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // Required by `TestWindowsAreNotReleasedOnCloseGuardTests` (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Quiet by the surface's own evaluation count, polled while layout and display are driven, because
    // this window is never ordered front and AppKit runs no display cycle for it (#3480). An absence is
    // being established, so this waits on the condition rather than a fixed time (L290).
    @discardableResult
    private func waitUntilQuiet(_ surface: StallSurface, in hosting: NSView, quietPolls: Int = 25,
                                timeout: Duration = .seconds(20)) async -> Bool {
        var last = QueueRenderCounter.renderCount(for: surface.rawValue)
            + QueueRenderCounter.derivationCount(for: surface.rawValue)
        var quiet = 0
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let now = QueueRenderCounter.renderCount(for: surface.rawValue)
                + QueueRenderCounter.derivationCount(for: surface.rawValue)
            quiet = (now == last) ? quiet + 1 : 0
            last = now
            if quiet >= quietPolls { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // Whether the banner is really up over this sheet: the sheet's own banner has mounted (it registers
    // on appear, and it is the only one in this window) and the message is the one just raised. The
    // positive control, because a banner that never reached the sheet would leave every count below at
    // zero for the wrong reason (L159).
    private func bannerIsShowing(_ text: String, feedback: ActionFeedback) -> Bool {
        feedback.topBanner > 0 && feedback.message == text
    }

    private struct Reading {
        let derivations: Int
        let evaluations: Int
        let bannerShown: Bool
    }

    // The one measurement, shared by every sheet so the four readings are taken the same way.
    private func raiseABanner(over surface: StallSurface, in hosting: NSView,
                              feedback: ActionFeedback) async -> Reading {
        await waitUntilQuiet(surface, in: hosting)
        let derivationsBefore = QueueRenderCounter.derivationCount(for: surface.rawValue)
        let evaluationsBefore = QueueRenderCounter.renderCount(for: surface.rawValue)

        let message = "Banner over \(surface.rawValue) \(UUID().uuidString)"
        feedback.acknowledge(message)

        await waitUntilQuiet(surface, in: hosting)
        let shown = bannerIsShowing(message, feedback: feedback)
        return Reading(
            derivations: QueueRenderCounter.derivationCount(for: surface.rawValue) - derivationsBefore,
            evaluations: QueueRenderCounter.renderCount(for: surface.rawValue) - evaluationsBefore,
            bannerShown: shown)
    }

    private func expectNothingDerived(_ reading: Reading, _ surface: StallSurface,
                                      appeared: Int) {
        // The reading itself, printed so a run records it and not only a verdict over it (#4197 asks
        // for a reading on each surface before anything is memoised).
        print("banner-reading \(surface.rawValue): appeared=\(appeared) derivations=\(reading.derivations) "
              + "evaluations=\(reading.evaluations) bannerShown=\(reading.bannerShown)")
        #expect(appeared > 0, Comment(rawValue:
            "the \(surface.rawValue) sheet never derived while appearing, so its counter is not wired "
            + "and the zero below would mean nothing ran (L98)"))
        #expect(reading.bannerShown, Comment(rawValue:
            "the banner never appeared over the \(surface.rawValue) sheet, so this fixture never "
            + "exercised the case and the count below proves nothing (L159)"))
        #expect(reading.derivations == 0, Comment(rawValue:
            "raising a banner with no data change derived the \(surface.rawValue) sheet "
            + "\(reading.derivations) time(s) over \(reading.evaluations) body evaluation(s). Every "
            + "message shown while this sheet is open would cost a derivation (#4197)"))
    }

    @Test func followUps() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        let prospects = seedProspects(ctx)
        let feedback = ActionFeedback()
        let (window, hosting) = host(
            FollowUpsView(prospects: prospects, inquiries: [], gmailConnectedOverride: true,
                          replyRunAliveOverride: false)
                .modelContainer(c)
                .environment(feedback))
        defer { window.close() }

        await waitUntilQuiet(.followUps, in: hosting)
        let appeared = QueueRenderCounter.derivationCount(for: StallSurface.followUps.rawValue)
        let reading = await raiseABanner(over: .followUps, in: hosting, feedback: feedback)
        expectNothingDerived(reading, .followUps, appeared: appeared)
    }

    @Test func struckAddresses() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        let prospects = seedProspects(ctx)
        for n in 0..<Self.struckCount {
            ctx.insert(RefusedContactAddress(id: "refusal-\(n)", scopeRaw: "show", scopeId: "row-\(n)",
                                             handleKey: "struck-\(n)@example.invalid", refusedAt: Date()))
        }
        try ctx.save()
        let feedback = ActionFeedback()
        let (window, hosting) = host(
            StruckAddressesView(prospects: prospects)
                .modelContainer(c)
                .environment(feedback))
        defer { window.close() }

        await waitUntilQuiet(.struckAddresses, in: hosting)
        let appeared = QueueRenderCounter.derivationCount(for: StallSurface.struckAddresses.rawValue)
        let reading = await raiseABanner(over: .struckAddresses, in: hosting, feedback: feedback)
        expectNothingDerived(reading, .struckAddresses, appeared: appeared)
    }

    @Test func excludedTowns() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        for town in ["Albany", "Buffalo", "Ithaca", "Rochester", "Syracuse", "Utica"] {
            ctx.insert(ExcludedTown(town: town))
        }
        try ctx.save()
        let feedback = ActionFeedback()
        let (window, hosting) = host(
            ExcludedTownsView()
                .modelContainer(c)
                .environment(feedback))
        defer { window.close() }

        await waitUntilQuiet(.excludedTowns, in: hosting)
        let appeared = QueueRenderCounter.derivationCount(for: StallSurface.excludedTowns.rawValue)
        let reading = await raiseABanner(over: .excludedTowns, in: hosting, feedback: feedback)
        expectNothingDerived(reading, .excludedTowns, appeared: appeared)
    }

    // ONE fetch of the listing per drawing. The two seed sections used to read the computed `listing`, a
    // store fetch, five times between them per body (L383), found by the #4197 lessons review. Evaluations
    // and derivations are counted apart, so their ratio is the number of fetches per drawing.
    @Test func skippedTownsFetchesItsListingOncePerDrawing() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        for town in ["Albany", "Buffalo", "Ithaca"] { ctx.insert(ExcludedTown(town: town)) }
        try ctx.save()
        let surface = StallSurface.excludedTowns.rawValue
        let derivationsBefore = QueueRenderCounter.derivationCount(for: surface)
        let evaluationsBefore = QueueRenderCounter.renderCount(for: surface)
        let (window, hosting) = host(ExcludedTownsView().modelContainer(c).environment(ActionFeedback()))
        defer { window.close() }

        await waitUntilQuiet(.excludedTowns, in: hosting)
        let evaluations = QueueRenderCounter.renderCount(for: surface) - evaluationsBefore
        let derivations = QueueRenderCounter.derivationCount(for: surface) - derivationsBefore
        #expect(evaluations >= 1, "the sheet never drew, so the ratio below measures nothing (L98)")
        #expect(derivations == evaluations, Comment(rawValue:
            "the Skipped towns sheet fetched its listing \(derivations) time(s) over \(evaluations) "
            + "drawing(s); it should be once per drawing (#4197, L383)"))
    }

    @Test func daysOff() async throws {
        let c = try container()
        let ctx = c.mainContext
        for n in 0..<23 {
            let day = EasternDate.dayString(from: Date().addingTimeInterval(Double(n * 5) * 86_400))
            ctx.insert(DayOff(startDate: day, endDate: day, note: "Away"))
        }
        ctx.insert(WeeklyDayOff(weekday: 4, note: "Rehearsal"))
        try ctx.save()
        let snapshot = AvailabilitySnapshot(loadExport: { (bookings: [], blockedDates: [], health: .ok) })
        snapshot.attach(to: ctx)
        defer { snapshot.detach() }
        let feedback = ActionFeedback()
        let (window, hosting) = host(
            DaysOffView()
                .modelContainer(c)
                .environment(feedback)
                .environment(snapshot))
        defer { window.close() }

        await waitUntilQuiet(.daysOff, in: hosting)
        let appeared = QueueRenderCounter.derivationCount(for: StallSurface.daysOff.rawValue)
        let reading = await raiseABanner(over: .daysOff, in: hosting, feedback: feedback)
        expectNothingDerived(reading, .daysOff, appeared: appeared)
    }
}
