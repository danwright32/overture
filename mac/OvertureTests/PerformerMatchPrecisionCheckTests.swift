import Testing
import Foundation
@testable import Overture

// Phase 7 (#755): the offline precision check, run against Dan's REAL Downbeat client list and
// booking history before the matcher is trusted to auto-correct a live lead.
//
// Opt-in, and SKIPPED (not failed) everywhere by default: it reads files that only exist on Dan's
// Mac, so CI and a normal local run never touch it. Run it with:
//
//     TEST_RUNNER_OVERTURE_PRECISION_CHECK=1 mac/scripts/run-tests-locked.sh
//
// The TEST_RUNNER_ prefix is required: xcodebuild does not forward the parent environment to the
// test process, it only forwards vars carrying that prefix, and strips it on the way in.
//
// Kept rather than thrown away because the same check has to be re-run whenever the matching rule is
// retuned, and re-deriving it from scratch is how a precision regression slips through.
@Suite("Performer-match precision check against real data (#755, opt-in)")
struct PerformerMatchPrecisionCheckTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["OVERTURE_PRECISION_CHECK"] == "1" }

    // Real person names drawn from Dan's own booking history and client list, plus two deliberate
    // TRAPS: names of people the org is merely NAMED AFTER, where a match would be a false positive.
    private static let realPerformerNames = [
        "Janani Sreenivasan",       // a Downbeat client in her own right
        "Kento Hong",               // history: "Kento Hong, violin"
        "Rainer Crosett",           // history: "Rainer Crosett, Cello" (multi-line)
        "Victor Santiago Asuncion", // history: same entry, second line
        "Leonela Alejandro",        // history: "Leonela Alejandro, Guitar"
        "Amandine Beyer",           // history: "Amandine Beyer" (multi-line, name alone on line 1)
        "Daniel Colalillo",         // history: "Daniel Colalillo, Piano"
        "Lisa Batiashvili",         // history: "Lisa Batiashvili, Violin"
        "Giorgi Gigashvili",        // history: same entry, second line
        "Sydney Lee",               // history: "American Recital Debut Award Recital (Sydney Lee)"
        "Michel Pascal",            // history: "Presented by Michel Pascal Inc, ..."
        "Sophia Rosoff",            // TRAP: a concert SERIES named after her, not a client
        "Abby Whiteside",           // TRAP: a FOUNDATION named after her, not a client
    ]

    private func realData() throws -> (clients: [DownbeatClient], history: [HistoryRecord]) {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Overture")
        let export = try DownbeatBridge.decode(
            try Data(contentsOf: dir.appendingPathComponent("downbeat-export.json")))
        let history = try JSONDecoder().decode(
            [HistoryRecord].self,
            from: try Data(contentsOf: dir.appendingPathComponent("overture-history.json")))
        return (export.clients, history)
    }

    @Test(.enabled(if: PerformerMatchPrecisionCheckTests.enabled))
    func reportWhatTheMatcherWouldDoToRealPerformers() throws {
        let (clients, history) = try realData()

        print("\n=== PERFORMER-MATCH PRECISION CHECK (#755) ===")
        print("\(clients.count) Downbeat clients, \(history.count) history records\n")

        var matched = 0
        for name in Self.realPerformerNames {
            let verdict = HistoryMatch.matchPerformer(
                performerName: name, performerEmail: "", production: .selfProduced,
                clients: clients, history: history)
            if verdict.isMatch { matched += 1 }
            let outcome = verdict.isMatch
                ? "MATCH  -> \(verdict.relationship.rawValue)  \(verdict.note ?? "")"
                : "no match"
            print(String(format: "%-28s %@", (name as NSString).utf8String!, outcome))
        }
        print("\n\(matched) of \(Self.realPerformerNames.count) matched.")

        // What the person matcher actually SEES for each history entry it would compare against, so a
        // miss can be explained rather than guessed at.
        print("\n=== how each history entry normalizes ===")
        for r in history where GroupNameMatch.tokens(r.groupName).count <= 4 {
            print("  \(GroupNameMatch.tokens(r.groupName).joined(separator: " "))   [\(r.status ?? "nil")]")
        }
        print("")
    }
}
