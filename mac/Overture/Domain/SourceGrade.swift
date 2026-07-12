import Foundation

// #800: how a watched source READS to Dan.
//
// A domain rule, not a view detail, because one of these mistakes cannot be taken back. A source that
// asked Dan to stop must never render as merely "broken": the natural response to broken is to go and
// fix it, and the natural response to fixing it is to start pitching them again. So `isActive` (whether
// they want to hear from Dan) always outranks `health` (whether the scraper works), and the view is
// given a grade rather than a pile of fields to interpret for itself.
enum SourceGrade: Equatable, Sendable, CaseIterable {
    case watching                // checked, healthy
    case failing                 // broken, STILL WATCHED, reported every run, never auto-deactivated
    case neverChecked            // added, not yet checked. Says so, rather than claiming health.
    case stoppedAtTheirRequest   // the org asked Dan to stop
    case removed                 // Dan stopped watching a permanently dead source. Not a refusal.

    init(isActive: Bool, inactiveReason: SourceInactiveReason?, health: SourceHealth) {
        guard isActive else {
            // Whatever the scout thinks of this source's health, it has no say here. Consent is not a
            // health signal, and a broken site does not make a refusal any less of a refusal.
            switch inactiveReason {
            case .removedByDan: self = .removed
            case .orgRefusal, nil: self = .stoppedAtTheirRequest
            }
            return
        }
        switch health {
        case .ok: self = .watching
        case .failing: self = .failing
        case .neverChecked: self = .neverChecked
        }
    }

    init(_ source: WatchedSource) {
        self.init(isActive: source.isActive, inactiveReason: source.inactiveReason, health: source.health)
    }

    var isStopped: Bool { self == .stoppedAtTheirRequest || self == .removed }
    var isBroken: Bool { self == .failing }

    // The order Dan should read the sections in: what is working, then what needs him, then what he
    // must leave alone. Lives here rather than in the view so the sheet has no ordering of its own to
    // get wrong, and so "a stopped source can never appear in the failing section" is a fact with a
    // test rather than a property of some SwiftUI code nobody can run in the suite.
    static let sectionOrder: [SourceGrade] = [
        .watching, .failing, .neverChecked, .stoppedAtTheirRequest, .removed,
    ]

    // Empty sections are omitted entirely: a heading with nothing under it reads like something failed
    // to load.
    static func sections(_ sources: [WatchedSource]) -> [(grade: SourceGrade, sources: [WatchedSource])] {
        sectionOrder.compactMap { grade in
            let rows = sources.filter { SourceGrade($0) == grade }
            return rows.isEmpty ? nil : (grade, rows)
        }
    }

    // Words, never color alone.
    var label: String {
        switch self {
        case .watching: return "Watching"
        case .failing: return "Failing"
        case .neverChecked: return "Not checked yet"
        case .stoppedAtTheirRequest: return "Stopped at their request"
        case .removed: return "Removed"
        }
    }

    var systemImage: String {
        switch self {
        case .watching: return "eye"
        case .failing: return "exclamationmark.triangle"
        case .neverChecked: return "clock"
        case .stoppedAtTheirRequest: return "hand.raised"
        case .removed: return "minus.circle"
        }
    }

    // What the section means, so a quiet section is never mistaken for an empty one.
    var explanation: String {
        switch self {
        case .watching:
            return "Checked on every scout."
        case .failing:
            return "Still watched and still checked. Overture will keep reporting these every run rather than quietly giving up on them."
        case .neverChecked:
            return "Added, but no scout has reached them yet."
        case .stoppedAtTheirRequest:
            return "These organizations asked not to be contacted. Overture no longer watches them, and will not draft to them."
        case .removed:
            return "Sources you stopped watching."
        }
    }
}
