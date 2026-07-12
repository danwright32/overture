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
