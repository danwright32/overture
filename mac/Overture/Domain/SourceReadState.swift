import Foundation

// #803: whether a watched calendar has actually been READ, as opposed to merely checked.
//
// These are different things, and the Sources sheet could not tell them apart. The free daily run
// fetches and hashes every calendar and reads none of them (Dan's own decision: watching is free, only a
// scout he starts spends tokens). So a source can report "Watching, checked an hour ago" for weeks while
// nobody has ever looked at what is on it.
//
// That is the design, not a bug. But it is invisible, and invisible is how a calendar Dan is counting on
// goes months without being read while reporting as perfectly healthy. `lastCheckedAt` answers "did we
// fetch it"; only `lastSucceededAt` answers "did we read it".
enum SourceReadState: Equatable, Sendable {
    case neverRead                                // fetched, hashed, never actually looked at
    case read(at: Date)
    case unreadChangesWaiting(lastRead: Date?)    // its listings changed and no scout has read them yet

    static func of(_ source: WatchedSource) -> SourceReadState {
        if source.hasUnreadChanges {
            return .unreadChangesWaiting(lastRead: source.lastSucceededAt)
        }
        if let read = source.lastSucceededAt { return .read(at: read) }
        return .neverRead
    }

    // The only state that asks Dan for anything: there are listings here nobody has read, and a scout he
    // starts is what reads them. Everything else is just a fact.
    var needsAScout: Bool {
        if case .unreadChangesWaiting = self { return true }
        return false
    }

    // #840: does this line tell Dan anything the CHECKED line above it does not?
    //
    // His Carnegie row read "Checked 8 hours ago" and then "Read 8 hours ago": one event, described
    // twice. A successful run stamps `lastCheckedAt` and `lastSucceededAt` from the same instant, so when
    // they are the same instant, reading and checking were the same act and there is nothing to add. The
    // free daily run stamps only `lastCheckedAt`, which is exactly when the two diverge and exactly when
    // this line starts earning its place.
    //
    // Decided on the FACTS, not on the source's kind. A native feed's shows arrive with the check, so it
    // falls out silent on its own, and if one ever were checked without being read, the row would say so
    // rather than stay quiet because of what type it is.
    //
    // Copy that repeats itself teaches Dan to skim, and the line this protects (listings changed, nobody
    // has read them) is the one line here that must never be skimmed past.
    func isWorthShowing(lastCheckedAt: Date?) -> Bool {
        switch self {
        case .unreadChangesWaiting:
            // Not a fact about time, and the whole reason the line exists. Always said, always loud.
            return true
        case .neverRead:
            // "Never checked" already tells him nobody has read it. Said twice, it says nothing.
            return lastCheckedAt != nil
        case .read(let at):
            guard let checked = lastCheckedAt else { return true }   // read but never checked: say so
            // Within the same second is the same run. A tolerance rather than exact equality only
            // because these round-trip through the store as a stored interval, never because two
            // separate events could land this close: the daily check and a scout are hours apart.
            return abs(at.timeIntervalSince(checked)) >= 1
        }
    }

    var label: String { label(now: Date()) }

    func label(now: Date) -> String {
        switch self {
        case .neverRead:
            return "Not read yet"
        case .read(let at):
            return "Read \(relative(at, now: now))"
        case .unreadChangesWaiting:
            // What it means, and what to do about it. A state Dan cannot act on is one he learns to
            // scroll past.
            return "New listings, not read yet. Run a scout to read them."
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
