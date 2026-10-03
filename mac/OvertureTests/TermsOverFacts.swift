import Foundation
import SwiftData

// #4357 (plan v7 Phase 3, oracle part two): every ported queue term, run once over the live `Prospect`
// models and once over the very same rows as `RowFacts.extract` hands them back, compared output by output.
//
// WHAT THIS CAN AND CANNOT SEE (plan Phase 3 step 3, quoted in spirit rather than restated). Both arms run
// the SAME generic term code, so a wrong term passes here: that is oracle part one's job, old against new on
// a frozen snapshot before the old is deleted. What this sees is everything between a model and its value:
// a field `extract` copies wrongly, a field it does not carry, a computed member that answers differently
// on the two conformers. Those are exactly the faults a retained value would hide for ever, because a row
// that never goes stale looks like a row that has not changed (L40).
//
// THE FINDINGS NAME A TERM, A FIELD AND A ROW'S PERSISTENT IDENTIFIER, NEVER A TITLE OR A VENUE. The live
// store arm runs over Dan's real shows, and a failing assertion's text is what reaches a pull request
// (L222, the `CardDivergenceRecord` privacy rule). The identifier says which row without saying what it is.
//
// ONE PLACE, GROWN BY EACH SLICE. Slice A carries T1 (ShowLink group and collapse), T2
// (ContradictedCancellation) and T3 (feed breaks); slice B adds T4 (the producer tables) and T5 (the
// organisation answer ledger). Each later slice adds its terms here, so the fixture suites and the live
// store suite ask every ported term the same question through one comparison (L370).
enum TermsOverFacts {

    /// T5's inputs other than the rows: the stored organisation answers, the struck addresses, the shows a
    /// live run holds, and the instant freshness is judged at. Dan's producer corrections are read by T4
    /// as well, so they are a parameter of `findings` itself.
    struct Ledger {
        var answers: [OrgReachabilityAnswer]
        var refusals: ContactRefusal.Ledger = .none
        var heldKeys: Set<String> = []
        var now: Date
    }

    /// Every place a ported term answered differently over facts than over models, empty when they agree.
    /// `asOf` is the day the feed break term judges "still to come" against, and `drawn` the keys a
    /// surface draws, which is what the collapse hides rows in favour of (nil means every row is drawn).
    /// `facts` defaults to extracting `models` now; a positive control hands in facts taken BEFORE a model
    /// changed, to show the comparison can see a retained row that went stale (L159).
    /// `rowByRow` also asks `liveTwin` of every flagged row on both arms, which is flagged rows times all
    /// rows: about a second on the clone and over 40 on the 4x copy (measured 2026-10-02), so the 4x arm
    /// compares the indexed set alone, which is what the pass reads.
    /// `overrides` are Dan's producer corrections, read by T4 and T5. `ledger` nil means T5 is not asked,
    /// which is right for a fixture that seeds no answers: the ledger returns before reading a row when it
    /// has none.
    static func findings(_ models: [Prospect], facts given: [RowFacts]? = nil, asOf: String,
                         drawn: Set<String>? = nil, rowByRow: Bool = true,
                         overrides: ProducerOverrides = .none, ledger: Ledger? = nil) -> [String] {
        let facts = given ?? models.map(RowFacts.extract)
        let pidByKey = Dictionary(models.map { ($0.naturalKey, String(describing: $0.persistentModelID)) },
                                  uniquingKeysWith: { first, _ in first })
        func pid(_ key: String) -> String { pidByKey[key] ?? "a row no model holds" }
        var out: [String] = []

        // T1: the grouping and the collapse, over the slice both conformers build by one rule.
        let groupModels = ShowLink.group(models.map(ShowLink.Row.init))
        let groupFacts = ShowLink.group(facts.map(ShowLink.Row.init))
        for key in Set(groupModels.keys).union(groupFacts.keys).sorted()
        where Set(groupModels[key] ?? []) != Set(groupFacts[key] ?? []) {
            out.append("ShowLink.group members differ for row \(pid(key))")
        }
        let collapseModels = ShowLink.collapse(models.map(ShowLink.Row.init), drawn: drawn)
        let collapseFacts = ShowLink.collapse(facts.map(ShowLink.Row.init), drawn: drawn)
        for key in Set(collapseModels.fronts.keys).union(collapseFacts.fronts.keys).sorted()
        where Set(collapseModels.fronts[key] ?? []) != Set(collapseFacts.fronts[key] ?? []) {
            out.append("ShowLink.collapse fronts differ for row \(pid(key))")
        }
        for key in collapseModels.hidden.symmetricDifference(collapseFacts.hidden).sorted() {
            out.append("ShowLink.collapse hidden differs for row \(pid(key))")
        }

        // T2: the set the pass reads, and the row by row rule it is an index of.
        let contradictedModels = ContradictedCancellation.contradictedKeys(among: models)
        let contradictedFacts = ContradictedCancellation.contradictedKeys(among: facts)
        for key in contradictedModels.symmetricDifference(contradictedFacts).sorted() {
            out.append("ContradictedCancellation.contradictedKeys differs for row \(pid(key))")
        }
        for (model, fact) in zip(models, facts) where model.disappearedFromFeed || fact.disappearedFromFeed {
            if model.disappearedFromFeed != fact.disappearedFromFeed {
                out.append("disappearedFromFeed differs for row \(pid(model.naturalKey))")
            }
            guard rowByRow else { continue }
            let twinModel = ContradictedCancellation.liveTwin(of: model, among: models)?.persistentModelID
            let twinFact = ContradictedCancellation.liveTwin(of: fact, among: facts)?.persistentModelID
            if twinModel != twinFact {
                out.append("ContradictedCancellation.liveTwin differs for row \(pid(model.naturalKey))")
            }
        }

        // T3: every event, field by field and by name, with the contradicted set the pass shares in.
        let eventsModels = FeedBreakEvent.events(among: models, asOf: asOf, contradicted: contradictedModels)
        let eventsFacts = FeedBreakEvent.events(among: facts, asOf: asOf, contradicted: contradictedFacts)
        out += eventFindings(eventsModels, eventsFacts, term: "FeedBreakEvent.events", pid: pid)

        // T4: each row's projection, then the two whole-corpus tables and the memo key built from them.
        let showsModels = models.map(ProducerGate.Show.init)
        let showsFacts = facts.map(ProducerGate.Show.init)
        for (model, (a, b)) in zip(models, zip(showsModels, showsFacts)) where a != b {
            out.append("ProducerGate.Show differs for row \(pid(model.naturalKey))")
        }
        let tablesModels = QueueModel.ProducerTables(shows: showsModels, overrides: overrides)
        let tablesFacts = QueueModel.ProducerTables(shows: showsFacts, overrides: overrides)
        out += tableFindings(tablesModels, tablesFacts, rows: models, term: "ProducerTables", pid: pid)
        if QueueModel.ProducerTables.key(shows: showsModels, overrides: overrides)
            != QueueModel.ProducerTables.key(shows: showsFacts, overrides: overrides) {
            out.append("ProducerTables.key differs")
        }

        // T5: the inherited answer of every show, each arm with its own producer index, as the pass hands it.
        if let ledger {
            let inheritedModels = QueueModel.inheritedAnswers(
                ledger.answers, corpus: models, overrides: overrides, refusals: ledger.refusals,
                heldKeys: ledger.heldKeys, now: ledger.now, producerCorpus: tablesModels.corpus)
            let inheritedFacts = QueueModel.inheritedAnswers(
                ledger.answers, corpus: facts, overrides: overrides, refusals: ledger.refusals,
                heldKeys: ledger.heldKeys, now: ledger.now, producerCorpus: tablesFacts.corpus)
            out += inheritedFindings(inheritedModels, inheritedFacts, term: "OrgAnswerLedger.inherited", pid: pid)
        }
        return out
    }

    /// Two sets of producer tables compared, naming every row whose presenter the two answer differently
    /// about: its venue count, whether it is a venue's own brand, whether it is spelled like a room. The
    /// row's identifier only, never the presenter's name, which is a real organisation on the live store.
    /// Shared with oracle part one, which asks the same of an old and a new build.
    static func tableFindings(_ left: QueueModel.ProducerTables, _ right: QueueModel.ProducerTables,
                              rows: [Prospect], term: String, pid: (String) -> String) -> [String] {
        var out: [String] = []
        for row in rows {
            guard let presenter = row.presenter else { continue }
            if let key = ProducerGate.key(presenter),
               left.corpus.distinctVenueCount(key) != right.corpus.distinctVenueCount(key) {
                out.append("\(term).corpus venue count differs for row \(pid(row.naturalKey))")
            }
            if left.venueBrands.contains(presenter) != right.venueBrands.contains(presenter) {
                out.append("\(term).venueBrands differs for row \(pid(row.naturalKey))")
            }
            if left.venueBrands.isRoomName(presenter) != right.venueBrands.isRoomName(presenter) {
                out.append("\(term).venueBrands room name differs for row \(pid(row.naturalKey))")
            }
        }
        // The whole values too, so a difference on a presenter no row of `rows` carries is still seen.
        if out.isEmpty, left.corpus != right.corpus { out.append("\(term).corpus differs") }
        if out.isEmpty, left.venueBrands != right.venueBrands { out.append("\(term).venueBrands differs") }
        return out
    }

    /// Two inherited answer tables compared show by show, naming the show by its identifier.
    static func inheritedFindings(_ left: [String: OrgAnswerLedger.Inherited],
                                  _ right: [String: OrgAnswerLedger.Inherited], term: String,
                                  pid: (String) -> String) -> [String] {
        Set(left.keys).union(right.keys).sorted().compactMap { key in
            left[key] == right[key] ? nil : "\(term) differs for row \(pid(key))"
        }
    }

    /// Two event lists compared field by field, naming the field and the event's first member by its
    /// identifier. Shared with oracle part one, which asks the same of an old and a new term.
    static func eventFindings(_ left: [FeedBreakEvent.Event], _ right: [FeedBreakEvent.Event], term: String,
                              pid: (String) -> String) -> [String] {
        guard left.count == right.count else {
            return ["\(term) returned \(left.count) event(s) one way and \(right.count) the other"]
        }
        var out: [String] = []
        for (index, (a, b)) in zip(left, right).enumerated() {
            let at = "\(term) event \(index) (first member \(pid(a.memberKeys.first ?? "")))"
            if a.venue != b.venue { out.append("\(at): venue differs") }
            if a.missedScoutCount != b.missedScoutCount { out.append("\(at): missedScoutCount differs") }
            if a.memberKeys != b.memberKeys { out.append("\(at): memberKeys differs") }
            if a.coveredByAnotherCard != b.coveredByAnotherCard { out.append("\(at): coveredByAnotherCard differs") }
        }
        return out
    }
}
