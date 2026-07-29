import Foundation
import SwiftData

// #1694: the tripwire under the possible-match flag.
//
// A possible match is a QUESTION Dan has to answer by hand ("Possible match to a past client: X?"), so
// its whole value is in how rarely it is wrong. #1693 was found because he happened to notice one wrong
// flag on one card. The store actually held 18 prospects all asking about the SAME record ("Carnegie Hall
// Citywide: Ivalas Quartet"), which is by itself conclusive evidence that the rule had locked onto
// something those shows shared (the building's own brand, arriving through the presenter field) rather
// than onto the act. Nothing measured that, and nothing said it, so it took a person reading a card.
//
// #1702 fixed that cause. This catches the CLASS, because however the rule goes wrong next the tell is
// the same: one name, many cards. One bad rule silently becoming a crowd of unanswerable questions is how
// the flag stops being read at all, and the two or three legitimate flags in the store go with it.
//
// What it deliberately does NOT do:
//
//  - It does not touch the flags. Dan's call (2026-07-29): the questions stay on the cards exactly as
//    they are, and Overture says separately that one of them looks like a pattern. A rule that hid them
//    would be deciding on his behalf that a fan-out is always wrong, and the whole reason this exists is
//    that nobody knows what the next cause will be.
//  - It is not applied to a CONFIDENT client match (`matchedClientName`). A client Dan works with
//    repeatedly legitimately appears on many cards at once, so the same rule there would fire on his best
//    relationships, and an alert that cries wolf gets ignored.
enum PossibleMatchFanOut {
    struct Finding: Equatable, Sendable {
        let name: String
        let count: Int
    }

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="prospects carrying each distinct possible-match name"
    // Three cards asking the identical question is already a pattern rather than a coincidence: a real
    // possible match is one specific act, so it lands on the one show that act is playing. On the live
    // store the three genuine flags sit at one card each (Bay Ridge School of Music, TENET Vocal Artists,
    // The Pushover) while the defective one sits at 19. Set low deliberately: the cost of a false report
    // is one sentence Dan reads and dismisses, and the cost of missing one is a season of questions he
    // learns to skip past.
    static let defaultThreshold = 3

    // The pure count, over the flag names themselves, so the rule can be exercised without a store.
    // Sorted worst-first, and by name within a tie so the order is stable rather than incidental.
    static func findings(names: [String], threshold: Int = defaultThreshold) -> [Finding] {
        var counts: [String: Int] = [:]
        for name in names {
            // A row carrying no flag is not a name, and neither is an empty one. Counted, they would fan
            // out across the entire store instantly and report a crowd on every launch forever.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            counts[trimmed, default: 0] += 1
        }
        return counts
            .filter { $0.value >= threshold }
            .map { Finding(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    // The same rule over a real store. Reads every prospect and asks nothing else of it.
    static func findings(in context: ModelContext, threshold: Int = defaultThreshold) -> [Finding] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return findings(names: all.compactMap(\.possibleMatchName), threshold: threshold)
    }

    // The sentence Dan reads, built here rather than in the view so it can be read cold in a test and so
    // the number it states is provably the number the rule counted.
    //
    // It names the worst offender, because a warning Dan cannot connect to anything on screen is just
    // unease. Any others are counted rather than listed: the alternative grows the masthead by a line per
    // finding, and this fires precisely when something has gone broadly wrong, which is the worst moment
    // to start pushing the queue down the window.
    //
    // Nothing found says NOTHING. A line that renders every launch to report that all is well is how the
    // one launch where it matters gets read straight past.
    static func warningLine(_ findings: [Finding]) -> String? {
        guard let worst = findings.first else { return nil }
        var line = "\(worst.name) is flagged as a possible match on \(worst.count) shows, "
            + "which usually means the match is wrong."
        let others = findings.count - 1
        if others == 1 {
            line += " One other match is flagged the same way."
        } else if others > 1 {
            line += " \(others) other matches are flagged the same way."
        }
        return line
    }
}
