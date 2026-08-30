import Foundation

// #1597 (milestone 32 Phase 4.3): decide what one reachability check actually researches.
//
// A check costs about $1.36 a show (measured 2026-07-27: $4.08 for three), so what goes in the work list
// is a spending decision, not a plumbing one. Before this, the list was one entry per selected show with
// no grouping, so a week's selection handed the runner Carnegie Hall Presents eight separate times and
// paid for the same answer eight times.
//
// This collapses the selection to one entry per QUALIFYING organisation, and names the shows each entry
// answers for so the run's own result can settle them. ProducerGate decides what qualifies, and it fails
// toward "pay again" rather than toward a shared answer: a room that rents itself out (Green Room 42) is
// never an organisation here, because its shows are unrelated productions sharing an address and one
// contact stamped across them would be wrong on every card.
//
// Within one run only. The persistent cross-run ledger, which reuses an answer on shows Dan never
// selected, is Phase 5 (#1598).
enum ProbeBatch {

    struct Show: Equatable {
        let key: String
        let presenter: String?
        let venue: String?
    }

    struct Plan: Equatable {
        // What the runner is actually paid to research, in a stable order.
        let keysToRun: [String]
        // Every selected show NOT being researched, mapped to the entry whose answer covers it.
        let coveredBy: [String: String]
        // How many entries are an organisation whose answer amortises...
        let organisationCount: Int
        // ...and how many are a one-off hunt that amortises nothing (a room-only show, or no producer).
        let performerHuntCount: Int
        // Everything Dan picked that exists in the store. Always keysToRun + coveredBy.
        let selectedCount: Int
    }

    static func plan(selecting selected: Set<String>, among all: [Show],
                     overrides: ProducerOverrides = .none) -> Plan {
        // The gate is judged against the WHOLE store, never just the selection. Judged against one
        // night's ticks, every producer looks like a single-venue house and nothing amortises, which
        // would throw away the entire saving.
        let corpus = all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }

        // Corpus order, not selection order: the entry chosen for an organisation must not change when
        // Dan ticks the same dates in a different sequence, or the confirm would quote one show while
        // the runner researched another.
        let picked = all.filter { selected.contains($0.key) }

        // #3238: built ONCE, not once per show. `qualifies(_:among:)` rebuilds the whole corpus on every
        // call, and this loop calls it per picked show, which is the same quadratic as
        // `OrganisationListing.build` one file over. Same fix, and it is the same overload at fault.
        let gateCorpus = ProducerGate.Corpus(corpus)

        var keysToRun: [String] = []
        var coveredBy: [String: String] = [:]
        var representativeForOrg: [String: String] = [:]
        var organisationCount = 0
        var performerHuntCount = 0

        for show in picked {
            guard let presenter = show.presenter,
                  let orgKey = ProducerGate.key(presenter),
                  ProducerGate.qualifies(presenter, in: gateCorpus, overrides: overrides) else {
                // A one-off hunt: its own entry, and it answers for nothing else.
                keysToRun.append(show.key)
                performerHuntCount += 1
                continue
            }
            if let representative = representativeForOrg[orgKey] {
                coveredBy[show.key] = representative
            } else {
                representativeForOrg[orgKey] = show.key
                keysToRun.append(show.key)
                organisationCount += 1
            }
        }

        return Plan(keysToRun: keysToRun, coveredBy: coveredBy,
                    organisationCount: organisationCount,
                    performerHuntCount: performerHuntCount,
                    selectedCount: picked.count)
    }
}
