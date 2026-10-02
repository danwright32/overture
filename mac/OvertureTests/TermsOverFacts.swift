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
// (ContradictedCancellation) and T3 (feed breaks). Each later slice adds its terms here, so the fixture
// suites and the live store suite ask every ported term the same question through one comparison (L370).
enum TermsOverFacts {

    /// Every place a ported term answered differently over facts than over models, empty when they agree.
    /// `asOf` is the day the feed break term judges "still to come" against, and `drawn` the keys a
    /// surface draws, which is what the collapse hides rows in favour of (nil means every row is drawn).
    /// `facts` defaults to extracting `models` now; a positive control hands in facts taken BEFORE a model
    /// changed, to show the comparison can see a retained row that went stale (L159).
    static func findings(_ models: [Prospect], facts given: [RowFacts]? = nil, asOf: String,
                         drawn: Set<String>? = nil) -> [String] {
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
        return out
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
