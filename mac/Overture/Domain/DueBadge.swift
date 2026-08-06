import Foundation

// #2115: the number of things owing Dan a response today, as it appears OUTSIDE the app.
//
// He asked for three surfaces and chose all three: a count on the Dock icon, a count beside the menu bar
// glyph, and the Dock icon staying present while the count is above zero even with the main window
// closed. The third is not a nicety: Overture is menu-bar-only with the window closed, so without it the
// badge would be invisible exactly when he is not already looking at the app, which is the only time it
// has a job to do.
//
// The count itself is DueWork.counts(...).total, the same predicate the toolbar Due badge reads, so
// nothing here decides for itself what "due" means. Due covers overdue: Dan, 2026-08-05, "if it's
// overdue it should be counted."
enum DueBadge {
    // Above this the Dock's small circle renders a number as an unreadable smear, so it says "more than
    // 99" rather than a wrong number or an illegible right one.
    static let cap = 99

    // What the Dock tile shows, or nil for no badge at all. Nothing due is NOT a zero: a badge reading 0
    // is a red dot claiming work, and the presence of this thing is the whole signal.
    //
    // A negative count is a bug upstream, and painting it would publish that bug on the Dock, so it reads
    // as nothing. "-1 due" is a sentence about the app, never about Dan's work.
    static func label(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > cap ? "\(cap)+" : "\(count)"
    }

    // The menu bar's own version, empty rather than nil because the glyph is always there and only the
    // count comes and goes. Derived from `label` rather than computed again, so the two surfaces cannot
    // state different numbers for one count, which is exactly how the pills and the toolbar drifted apart
    // in #2114.
    static func menuBarTitle(count: Int) -> String { label(count: count) ?? "" }

    // What VoiceOver reads for the menu bar item. A bare number beside a glyph is not a sentence, and an
    // icon-only control has to say what it is (L20). Says the app's name when there is nothing due, so
    // the item is still identifiable rather than announcing itself as nothing.
    static func menuBarAccessibilityLabel(count: Int) -> String {
        guard count > 0 else { return "Overture" }
        return "Overture, \(Plural.count(count, "thing")) due"
    }

    // Where the count lives between the tick that computes it and the two surfaces that draw it.
    //
    // Published rather than derived at each surface, deliberately. The Dock tile is set from AppKit and
    // the menu bar label is SwiftUI in a Scene, and neither can hold a SwiftData query; recomputing in a
    // view body would also pay the whole due-work sweep on every redraw, which is the cost L59 and L62
    // are about. The reconcile tick already has the prospects fetched and already writes to defaults.
    static let countKey = "dueWorkCount"

    static func publish(_ count: Int, into defaults: UserDefaults = .standard) {
        defaults.set(max(0, count), forKey: countKey)
    }

    static func current(from defaults: UserDefaults = .standard) -> Int {
        max(0, defaults.integer(forKey: countKey))
    }
}
