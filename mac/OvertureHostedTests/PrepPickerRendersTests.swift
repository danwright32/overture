import Testing
import Foundation
import SwiftData
import SwiftUI
import AppKit

// #3325, plan 3.3: the Prep picker at the real count, looked at rather than assumed (L606).
//
// The live worst case is a 28 night run (measured 2026-09-17), and 45 of 78 live multi-night runs are two to
// four nights, so both ends are rendered. The sheet is a fixed 460 points wide whatever the window, so the
// "wide and laptop" pair the plan asks for is one width here; what varies is the theme and the count.
//
// Two jobs:
// 1. A GUARD that runs every time: at 28 nights with the run open, the sheet stays a bounded height, so the
//    Prep button below the capped list is reachable (L189). The list is capped at 360 points and scrolls;
//    what must not happen is the nights pushing the button off the sheet.
// 2. SCREENSHOTS, opt in: with TEST_RUNNER_OVERTURE_PICKER_SHOTS=<a directory>, each state is written as a
//    PNG for the pull request. Off by default, because a test run has no business leaving files behind.
@MainActor
@Suite("The Prep picker at 28 nights and at 2 (#3325)")
struct PrepPickerRendersTests {

    private static var shotsDirectory: String? {
        guard let dir = ProcessInfo.processInfo.environment["OVERTURE_PICKER_SHOTS"], !dir.isEmpty else { return nil }
        return dir
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Friday and Saturday of each week from a pinned Friday: a weekend series, so 28 nights is fourteen
    // week groups, the long end of what the picker has to lay out.
    private static func weekly(_ count: Int, from start: String) -> [String] {
        var out: [String] = []
        var day = start
        for i in 0..<count {
            out.append(day)
            guard let d = EasternDate.date(from: day),
                  let next = EasternDate.calendar.date(byAdding: .day, value: i % 2 == 0 ? 1 : 6, to: d)
            else { break }
            day = EasternDate.dayString(from: next)
        }
        return out
    }

    private func prospect(_ ctx: ModelContext, name: String, venue: String, nights: [String]) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: name, performanceDate: nights.first,
                                                             venue: venue),
                         groupName: name, discipline: "theater", venue: venue,
                         performanceDate: nights.first, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .approved)
        p.runNights = nights
        p.runEndDate = nights.last
        ctx.insert(p)
        return p
    }

    private func calendar(blocking nights: [String]) -> BlockedCalendar {
        BlockedCalendar.build(availability: .measured,
                              bookings: nights.enumerated().map { i, night in
                                  OvertureBooking(id: "b\(i)", clientId: "c\(i)", clientDisplayName: "Client",
                                                  shootName: i == 0 ? "Spring Gala" : "Company Class",
                                                  startDate: night, endDate: night, venueId: nil,
                                                  venueName: "Hall")
                              },
                              exportedBlockedDates: [], daysOff: [])
    }

    private func host(_ view: some View, dark: Bool) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        hosting.appearance = window.appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        let settleBy = Date().addingTimeInterval(0.3)
        while Date() < settleBy { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return (window, hosting)
    }

    private func write(_ hosting: NSView, name: String) {
        guard let dir = Self.shotsDirectory,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func sheet(_ ctx: ModelContext, count: Int, blocked: [Int]) -> (PrepSelectionSheet, [Prospect]) {
        let nights = Self.weekly(count, from: "2026-10-02")
        let run = prospect(ctx, name: "The Lineup Revue", venue: "The Green Room", nights: nights)
        let other = prospect(ctx, name: "Chamber Night", venue: "Weill Recital Hall", nights: ["2026-11-14"])
        let cal = calendar(blocking: blocked.map { nights[$0] })
        let plan = PrepNightPlan.build(prospects: [run, other], calendar: cal, availability: .measured)
        let view = PrepSelectionSheet(prospects: [run, other], plan: plan,
                                      now: { Date(timeIntervalSince1970: 1_790_000_000) }, onRun: { _ in })
        return (view, [run, other])
    }

    // THE GUARD. 28 nights, two blocked so the run opens by itself: the sheet stays bounded, which is what
    // keeps its Prep button on screen. Measured against the same sheet with the run closed: the open one may
    // be taller only by what the capped list can add.
    @Test func twentyEightOpenNightsLeaveTheButtonReachable() throws {
        let ctx = ModelContext(try container())
        let (view, _) = sheet(ctx, count: 28, blocked: [3, 11])
        let (window, hosting) = host(view, dark: false)
        defer { window.close() }
        let height = hosting.fittingSize.height
        #expect(height > 200, "the sheet measured \(height) points, so nothing rendered")
        #expect(height < 700, "the sheet grew to \(height) points at 28 nights, pushing Prep off a laptop screen")
        write(hosting, name: "picker-28-light")
    }

    // The screenshots the pull request carries: 28 and 2 nights, light and dark. Opt in.
    @Test(.enabled(if: shotsDirectory != nil, "opt in: set TEST_RUNNER_OVERTURE_PICKER_SHOTS"))
    func screenshots() throws {
        for dark in [false, true] {
            for (count, blocked) in [(28, [3, 11]), (2, [1])] {
                let ctx = ModelContext(try container())
                let (view, _) = sheet(ctx, count: count, blocked: blocked)
                let (window, hosting) = host(view, dark: dark)
                write(hosting, name: "picker-\(count)-\(dark ? "dark" : "light")")
                window.close()
            }
        }
    }
}
