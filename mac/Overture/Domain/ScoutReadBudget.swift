import Foundation

// #1498: how many pages one scout Dan started may READ before it stops and asks him.
//
// The old budget capped which sources a manual run FETCHED, which rationed the free half of the work.
// Fetching and hashing costs nothing, and the paid read only ever touches a page whose content actually
// changed (SourceCheck.decide). So a 62-source watchlist checked 20 sources a press and left 42 untouched,
// and a source with something to say could sit three presses back through no fault of its own: #1498's
// Finding B looked like a stuck fix for exactly that reason, when the three sources were merely behind the
// rotation. Worse, spreading the same reads across three presses saves nothing. Dan pays for them either
// way; he just has to press three times.
//
// So the fetch is uncapped and the question moved to where the money actually is. By the time this is
// asked the run has fetched and hashed everything, so the number in the sentence is the TRUE count of
// pages that need reading rather than a guess from last night's hashes.
//
// A pure decision, never a computation inside the sweep or the view: the number Dan is asked about and the
// number the run then spends on must be the same number by construction (#863/#885).
enum ScoutReadBudget {

    // The point at which a run asks rather than simply spending. Deliberately the OLD fetch budget: it is
    // the size Dan already has a feel for, and it is about one batched read of comfortable length (a
    // 2026-07-17 run read 18 sources in 16 minutes sequentially, and the runner now splits the work four
    // ways). Below it there is nothing worth interrupting him for.
    static let askAbove = 20

    enum Decision: Equatable {
        case readThemAll             // at or under the threshold: no question, just run
        case ask(pending: Int)       // over it: Dan decides, and the count travels with the question
    }

    static func decide(pending: Int, askAbove: Int = askAbove) -> Decision {
        pending > askAbove ? .ask(pending: pending) : .readThemAll
    }

    // What Dan answered. `none` is the dismissal, and it is a real answer rather than an error: nothing
    // paid happens without an explicit yes, and nothing is lost, because a page fetched but not read keeps
    // its unread flag and its older fairness clock and is offered again at the front of the next press.
    enum Choice: Equatable, Sendable {
        case all
        case firstBatch
        case none
    }

    // The split, decided in ONE place so the sweep cannot grow its own copy of "the first 20". Generic
    // because the only thing that matters here is the ORDER it is handed, which is the sweep's fairness
    // order: oldest first by the manual read clock, so the pages that have waited longest go first.
    static func pagesToRead<T>(_ pending: [T], choice: Choice, askAbove: Int = askAbove) -> [T] {
        switch choice {
        case .all:        return pending
        case .firstBatch: return Array(pending.prefix(askAbove))
        case .none:       return []
        }
    }

    // The question, in whole sentences, with the real number in it. What each answer COSTS is the part Dan
    // is actually deciding between, so the message states the leftover rather than repeating the total the
    // title already gave him (#843: the second line must not restate the first).
    static func askTitle(pending: Int) -> String {
        "\(pending) calendars have new listings to read."
    }

    // The size of the smaller batch is NOT repeated here: its own button already says it, and a message
    // that spells out "reading 20 now" beside a button labelled "Read 20 now" is the on-screen restatement
    // #843 was filed about. This line carries only what the button cannot: how long the whole set takes,
    // and what choosing the smaller one leaves behind.
    static func askMessage(pending: Int, askAbove: Int = askAbove) -> String {
        let leftover = max(0, pending - askAbove)
        let them = leftover == 1 ? "the other one" : "the other \(leftover)"
        return "Reading them all takes a few minutes. A smaller batch leaves \(them) first in line next time."
    }

    static func readAllTitle(pending: Int) -> String {
        "Read all \(pending)"
    }

    static func readBatchTitle(askAbove: Int = askAbove) -> String {
        "Read \(askAbove) now"
    }

    // Backing out. Named for what it does rather than "Cancel", which in a run that is already part-done
    // reads as though it would undo the free half the sweep just finished. It does not: the fetch, the
    // hashes and the health it recorded all stand, and only the paid read is declined.
    //
    // Parallel to the other two buttons ("Read all 47", "Read 20 now") so the three read as one set of
    // amounts rather than two amounts and a mood. It is also why this is not "Not now", which would have
    // been a second copy of BlockDaysSheet's button and a new entry in the copy inventory's duplicate list.
    static let readNoneTitle = "Read none"
}
