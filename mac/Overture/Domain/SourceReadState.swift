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
    func isWorthShowing(lastCheckedAt: Date?, failure: SourceFailure? = nil) -> Bool {
        switch self {
        case .unreadChangesWaiting:
            // This line's job is the one that must never be skimmed: listings changed, nobody has read
            // them, and a scout Dan starts is what reads them. But for two failures "Run a scout to read
            // them" is the wrong thing to say, so it steps aside for the failure line instead:
            //   - notRead (#843): the run died before opening the page; the failure line already says
            //     "That page has not been read. The next scout will try it again.", and the run's own note beside it says WHY, so the
            //     two together said the one thing twice.
            //   - unreadable (#958): the page is drawn by JavaScript, so a plain re-fetch reads the same
            //     empty shell every time. "Run a scout to read them" promises a re-run will fix what a
            //     re-run cannot; the failure line ("drawn by JavaScript, nothing to read") is the truth.
            //   - noDatedContent (#1545): the page was read in full and had nothing dated on it, so there
            //     are no new listings to promise and no scout can produce any. This flag is not merely
            //     unhelpful here, it is PINNED: ScoutExtractIngest.fail() sets it on every failed read and
            //     only a successful read or a Confirm empty can clear it, so the row said "Run a scout to
            //     read them" forever on a page with nothing to read. And this is the one failure carrying
            //     BOTH buttons, so the honest next step is "Fix the address" or "This page is right",
            //     never a scout. Dan's call, 2026-07-26: hide it rather than reword it, matching the two
            //     above. The row is not left silent; the failure line still says the page is empty.
            // Any other failure (a transient fetch error, say) can genuinely be cleared by another scout,
            // so the line stays, always loud.
            switch failure {
            case .verdict(.notRead), .verdict(.unreadable), .verdict(.noDatedContent): return false
            default: return true
            }
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

// #885: the "when was this last looked at" line, out of SourcesView's body. It sat three lines below
// SourceReadState.label and source.readabilityNote, both properly domain-owned; this was the one sibling
// that was not, and it built its own formatter in the view each time.
//
// "Never" is a real answer and is said out loud, rather than left as a blank cell that reads like a
// rendering bug.
extension SourceReadState {
    // #1758: and it may only say CHECKED when something was actually read.
    //
    // `lastCheckedAt` is stamped on the failure path too (`ScoutExtractIngest.fail`), so a run that never
    // opened the page still refreshes it. Inside the app "checked" means "a run touched this source",
    // which is true. On screen, in the row's largest and most scannable slot beside an org name, it reads
    // as "we have current information about this org", which is false: two live rows said "Checked 1 hour
    // ago" while their own third line said the page had not been read (measured 2026-07-29).
    //
    // So the word follows the failure. An attempt that came away with nothing says it was TRIED, which is
    // exactly what happened and is visibly a different word; the failure line beneath says why. This is
    // not "did it fail": a page read in full with nothing dated on it WAS checked, and says so
    // (`SourceFailure.leftThePageUnread` owns that distinction, per verdict).
    //
    // The failure is required, not defaulted. Defaulted, forgetting it at the call site would restore the
    // old sentence on every row with every test here still green, which is precisely how #843's read-state
    // line was left mis-wired one line lower on this same row.
    static func lastCheckedLine(at lastCheckedAt: Date?, now: Date, failure: SourceFailure?) -> String {
        // "Never" is a real answer, and nothing has been attempted, so there is no claim here to be wrong.
        guard let lastCheckedAt else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let ago = formatter.localizedString(for: lastCheckedAt, relativeTo: now)
        return failure?.leftThePageUnread == true ? "Tried \(ago)" : "Checked \(ago)"
    }
}
