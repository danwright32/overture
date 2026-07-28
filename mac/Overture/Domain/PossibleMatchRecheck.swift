import Foundation
import SwiftData

// #1693: re-run the possible-match verdict over the rows that already carry one.
//
// `possibleMatchSource` / `possibleMatchName` are STORED on the prospect and only rewritten when the
// hash-gated scout re-emits that exact row, so tightening the matcher clears nothing already on screen.
// When the colon-strip defect was found, 18 Carnegie Hall cards were asking Dan whether the show was a
// match for an act he has never worked with, and they would have gone on asking for as long as
// carnegiehall.org happened not to be re-scouted. A matcher fix that leaves the wrong question on the
// screen ships looking broken, and the flag it is meant to protect is exactly the kind that stops being
// read the moment it cries wolf.
//
// Two properties keep this safe to run every launch:
//
//  - It only ever CLEARS or REPLACES a flag on a row that already has one. It cannot invent one, so it
//    can never put a question on Dan's screen with no scout run behind it.
//  - It writes back nothing but the possible flag. The verdict's relationship, client id and
//    passed-on-this-show are left exactly as the scout stored them, so this can never silently rescore
//    a row or move it between stages.
enum PossibleMatchRecheck {
    // The two things the verdict is judged against, taken as a value so the pass can be tested without
    // the files, and so the "can't judge" case has somewhere to live (see load below).
    struct Inputs: Sendable {
        var clients: [DownbeatClient]
        var history: [HistoryRecord]
    }

    // nil means CANNOT JUDGE, and the caller must then touch nothing.
    //
    // Both sides are files that can be missing or corrupt: Downbeat's export and the imported booking
    // history. Judged against an empty client list every genuine `downbeat_client` flag looks stale, so
    // reading on regardless would delete Dan's real flags on the first morning Downbeat had not written
    // its export yet, and the only symptom would be flags quietly vanishing. A STALE export is still a
    // real client list and is fine to judge with; missing and unreadable are not.
    static func load(prospects: [Prospect], now: Date = Date()) -> Inputs? {
        let export = DownbeatBridge.loadWithHealth(now: now)
        switch export.health {
        case .missing, .unreadable: return nil
        case .ok, .stale: break
        }
        let history = LocalHistory.forMatchingWithHealth(existing: prospects)
        if history.unreadable { return nil }
        return Inputs(clients: export.clients, history: history.records)
    }

    // Returns how many rows changed.
    @discardableResult
    static func run(in context: ModelContext,
                    loadInputs: ([Prospect]) -> Inputs? = { load(prospects: $0) }) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let flagged = all.filter { !($0.possibleMatchName ?? "").isEmpty }
        guard !flagged.isEmpty else { return 0 }
        guard let inputs = loadInputs(all) else { return 0 }

        var changed = 0
        for p in flagged {
            // The same three identities the scout matched on, read off the row: its displayed name (which
            // is Dan's own if he renamed it, and that is the identity he means), its presenter, and its
            // venue. The venue is passed for the same reason the scout passes it, so a #384 pass stays
            // aimed at one show.
            let verdict = HistoryMatch.matchRelationship(
                name: p.groupName, presenter: p.presenter, venue: p.venue,
                clients: inputs.clients, history: inputs.history)
            guard verdict.possible?.source != p.possibleMatchSource
                    || verdict.possible?.name != p.possibleMatchName else { continue }
            p.possibleMatchSource = verdict.possible?.source
            p.possibleMatchName = verdict.possible?.name
            changed += 1
        }
        return changed
    }
}
