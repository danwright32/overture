import Testing
import Foundation
import SwiftUI
import AppKit
import SwiftData

// The Days off sheet, drawn to PNG in both themes, for the pull request that changes it. Opt in: it writes
// files and asserts nothing about pixels, because what it exists for is a person LOOKING at the composed
// sheet at the real count (Dan's L606), which no assertion can do for them.
//
//   TEST_RUNNER_DAYS_OFF_SHEET_PNG_DIR=/some/dir mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/DaysOffSheetScreenshotTests
//
// The fixture is sized from the live store as read on 2026-09-18 (19 day off ranges, 20 booked shoots,
// most of both already past), with invented names, because this repository is public. Dates are placed
// around the real today so the filters have both sides to act on whenever it is run.
@MainActor
@Suite("The Days off sheet, drawn for a person to look at")
struct DaysOffSheetScreenshotTests {
    private static var outputDir: String? {
        ProcessInfo.processInfo.environment["DAYS_OFF_SHEET_PNG_DIR"]
    }

    private func day(_ offset: Int) -> String {
        EasternDate.dayString(from: EasternDate.calendar.date(byAdding: .day, value: offset, to: Date())!)
    }

    private func booking(_ i: Int, _ name: String, _ offset: Int, nights: Int = 1) -> OvertureBooking {
        OvertureBooking(id: "b\(i)", clientId: "c\(i)", clientDisplayName: "Client \(i)", shootName: name,
                        startDate: day(offset), endDate: day(offset + nights - 1), venueId: nil,
                        venueName: "Hall")
    }

    // Returns the CONTAINER, which the caller must hold: a `mainContext` does not keep its container alive,
    // and reading `.container` from one whose container has gone traps inside SwiftData.
    private func seededContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, CancelledShoot.self, WeeklyDayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        // Twelve past ranges, the shape Dan saw on 2026-08-31, and seven ahead, one of them running today.
        for offset in [-45, -40, -39, -34, -30, -25, -16, -9, -6, -3, -2, -1] {
            ctx.insert(DayOff(startDate: day(offset), endDate: day(offset), note: offset % 2 == 0 ? "Rehearsal" : nil))
        }
        ctx.insert(DayOff(startDate: day(-1), endDate: day(2), note: "Family trip"))
        for (offset, note) in [(5, "Rehearsal"), (12, "Rehearsal"), (19, nil), (21, "Away"),
                               (164, "Residency"), (195, "Residency")] as [(Int, String?)] {
            ctx.insert(DayOff(startDate: day(offset), endDate: day(offset + (note == "Residency" ? 29 : 0)),
                              note: note))
        }
        // #3620: a standing weekly rule with one week freed, and a bounded one that has already ended.
        let wednesday = WeeklyDayOff(weekday: 4, note: "Empire Harmony rehearsal")
        if let nextWednesday = (1...7).map({ day($0) }).first(where: { WeeklyBlock(weekday: 4).blocks($0) }) {
            wednesday.freedDates = [nextWednesday]
        }
        ctx.insert(wednesday)
        ctx.insert(WeeklyDayOff(weekday: 2, lastDate: day(-3), note: "Summer class"))
        ctx.insert(CancelledShoot(bookingId: "b0", shootName: "Spring Showcase", startDate: day(-60)))
        ctx.insert(CancelledShoot(bookingId: "b13", shootName: "Autumn Benefit", startDate: day(3)))
        try ctx.save()
        return container
    }

    private func render(_ view: some View, dark: Bool, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: max(size.height, 200))
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    @Test func drawTheSheetInBothThemes() throws {
        guard let dir = Self.outputDir else {
            print("days-off-sheet: not drawn. Set TEST_RUNNER_DAYS_OFF_SHEET_PNG_DIR to a folder to draw it.")
            return
        }
        let names = ["Spring Showcase", "Chamber Series", "Youth Orchestra", "Dance Festival", "Gala Night",
                     "Opera Scenes", "Choral Evening", "Jazz Brunch", "Recital Hall", "Film Score Night",
                     "Holiday Concert", "Winter Gala", "New Works", "Autumn Benefit", "Premiere", "Cabaret",
                     "Masterclass", "Season Opener", "Brass Night", "String Quartet"]
        let offsets = [-60, -55, -48, -44, -37, -33, -28, -21, -14, -10, -7, -4, 0, 3, 9, 26, 47, 80, 150, 240]
        let bookings = zip(names, offsets).enumerated().map { i, pair in
            booking(i, pair.0, pair.1, nights: pair.0 == "Dance Festival" || pair.0 == "Autumn Benefit" ? 3 : 1)
        }
        let export: DayOffEditing.Export = (bookings: bookings, blockedDates: [], health: .ok)
        let container = try seededContainer()
        let ctx = container.mainContext
        let snapshot = AvailabilitySnapshot(loadExport: { export })
        snapshot.attach(to: ctx)
        defer { snapshot.detach() }

        // A second pair with no shoots in the export, because the sheet caps its scroll area and at the real
        // count the booked shoots fill it: without this the "Days you blocked" rows are below the fold.
        let noShoots = AvailabilitySnapshot(loadExport: { (bookings: [], blockedDates: [], health: .ok) })
        noShoots.attach(to: ctx)
        defer { noShoots.detach() }

        // #3620: the weekly fields, on the add form's own sunk surface and padding. The sheet opens its form
        // from private state, so the fields are drawn on their own rather than through the sheet.
        for dark in [false, true] {
            let fields = WeeklyDayOffFields(weekday: .constant(4), hasFirst: .constant(true),
                                            first: .constant(Date()), hasLast: .constant(false),
                                            last: .constant(Date()), note: .constant("Empire Harmony rehearsal"))
                .padding(OVSpacing.lg)
                .frame(width: 560, alignment: .leading)
                .background(OVColor.surfaceSunk)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("weekly-fields-\(dark ? "dark" : "light").png")
            try render(fields, dark: dark, to: url)
            print("days-off-sheet: drew \(url.path)")
        }

        for (name, shown) in [("days-off", snapshot), ("days-off-blocked-only", noShoots)] {
            for dark in [false, true] {
                let view = DaysOffView()
                    .environment(\.modelContext, ctx)
                    .modelContainer(container)
                    .environment(ActionFeedback())
                    .environment(shown)
                let url = URL(fileURLWithPath: dir)
                    .appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try render(view, dark: dark, to: url)
                print("days-off-sheet: drew \(url.path)")
            }
        }
    }
}
