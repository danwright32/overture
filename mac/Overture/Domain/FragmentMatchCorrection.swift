import Foundation
import SwiftData

// #2565: take back what the OLD fragment-matching classifier gave a row.
//
// #2508 stopped the three signal lists firing INSIDE longer words. `Operation Mincemeat: Mission Recast`
// matched "opera" and read as an organisation, `Sam Gelband` matched "band", and `Let's Get Schooled!`
// matched "school", which carried it into the strong-profile list as well. The fix reaches a row only when
// the scout next re-reads its page, and the scout skips a source whose bytes have not changed, so a row
// scored under the old rule keeps what the fragment gave it for as long as its page sits still. Measured
// on the live store 2026-08-12, two of those rows were competing for Dan's attention at a fit score of 6.
//
// WHY THIS IS A SEPARATE PASS RATHER THAN AN ARM OF `ActIsThePartyRealignment`.
//
// That pass re-reads exactly these rows at every launch and only ever LIFTS (unknown to selfProduced,
// neutral to strong). That is deliberate, not an oversight, and the reason is worth stating before adding
// the direction it avoids: a re-read of a stored row knows LESS than the read that wrote it. A presenter
// since drained by `RoomPresenterSweep`, an axis merged from a second source (#1949), a title a source has
// rewritten: each makes a fresh read say less than what was true, and lowering on that basis demotes rows
// for reasons that have nothing to do with any classifier change.
//
// LIVE-STORE-CLAIM verified=2026-08-16 measure="rows a plain re-read would lower whose stored axes no signal list, old or new, produces from what the row now holds"
// That is not hypothetical. Measured on a clone of the live store 2026-08-16, three rows carry
// `self` + `strong` that NEITHER the old pattern nor the new one produces from what the row now holds
// (`Timeless Melodies: Masterpieces Inspiring Generations` and `The Alonso Brothers From Havana to New
// York` at Weill Recital Hall, `The Presence of Absence (A Cuban Nocturne)` at Thalia Spanish Theatre,
// all three with an empty presenter and a stored reason still naming a strong-fit target). A pass that
// lowered on disagreement would have demoted all three on #2508's ticket.
//
// So this lowers only on the DEFECT'S OWN SIGNATURE (L68): the stored value is one the pre-#2508 pattern
// produces from this row's own inputs, and the current pattern refuses. Anything else stays exactly where
// it is, including a value that is merely unexplainable.
//
// WHAT IT WILL NOT DO:
//
//   - It never LIFTS. A row stored below what it would earn today is `ActIsThePartyRealignment`'s
//     business, and one row cannot be handed back and forth between two passes that disagree.
//   - It never touches an `agency` verdict, in either direction. The dead-zone penalty is the point, and
//     #2508 measured no live string whose agency verdict a fragment produced (49 before, 49 after).
//   - It never touches the genre. That is Dan's to correct (#1658/#1533).
//   - It never writes `fitReason`. An empty reason is a decision (#1600) and `FitReasonRealignment` owns
//     the non-empty ones every launch, so a lowered row's sentence comes back into step there rather than
//     from two passes writing one field by opposite rules.
//   - It skips a row whose classification Dan overrode. That flag is his.
//
// Idempotent by construction rather than by a flag: the condition is a stored value the current rules
// refuse, and the pass writes what they allow, so a second run is a no-op.
//
// LIVE-STORE-CLAIM verified=2026-08-16 measure="prospect rows whose stored producer axes the pre-#2508 fragment match explains and the current classifier refuses"
// WHAT IT MOVES TODAY: nothing. Rehearsed against a clone of the Release store on 2026-08-16 (924 rows),
// it lowers 0 rows, because the store healed itself in the four days between the issue being filed and
// this being built: the scout re-read `Let's Get Schooled!` and `Operation Mincemeat: Mission Recast` on
// 2026-08-16 and both now hold `self` + `neutral`, and `Sam Gelband` never carried a value this pass could
// take back, since #2504 makes an act-named row self-produced whether or not "band" ever matched. The pass
// ships anyway because a hash-gated scout is luck: those rows sat wrong for four days and only a page
// change corrected them, and a store restored from one of the ten launch backups (every one of them older
// than #2508) arrives carrying the defect again. `FragmentMatchCorrectionLiveStoreTests` re-measures the
// number on every full local run, so it is a reading rather than a claim.
enum FragmentMatchCorrection {

    struct Summary: Equatable {
        var productionLowered = 0
        var profileLowered = 0
        var rescored = 0
    }

    // The pre-#2508 signal lists, FROZEN. This is a historical record of what the classifier used to
    // match, not a rule anybody may edit: its whole job is to answer "could the old pattern have written
    // this stored value?", and an edited copy would answer about a classifier that never ran. Kept here
    // rather than in `EventClassifier` for exactly that reason, so the live rules cannot be reached by
    // anyone maintaining these and the two can never be mistaken for one vocabulary.
    //
    // Bare alternations with no anchors and matched against the RAW string, which is what made them fire
    // inside longer words in the first place.
    private static let oldAgencySignal =
        #"competition|winners|rising stars|invitational|young artists?|debut|showcase|celebrations international|concerts international|distinguished concerts|mid.?america|national concerts|jam generation|tour|gala of"#
    private static let oldProducerSignal =
        #"choir|chorus|chorale|choral|orchestra|philharmonic|ensemble|consort|school|academy|conservatory|university|college|institute|theatre|theater|company|opera|ballet|dance|society|center|centre|foundation|church|temple|youth|community|collective|quartet|quintet|band"#
    private static let oldStrongProfile =
        #"choir|chorus|chorale|choral|school|academy|conservatory|youth|community|children|ensemble|opera|ballet|dance|theatre|theater|cultural|university|college|church|temple"#

    private static func matchedByTheOldRule(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @discardableResult
    static func run(in context: ModelContext, now: Date = Date()) -> Summary {
        var summary = Summary()
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []

        for p in prospects {
            // #1533: a classification Dan overrode is his, and this pass is not the place to revisit it.
            guard !p.classificationOverriddenByDan else { continue }

            let asStored = ExtractedEvent(title: p.groupName, presenter: p.presenter, venue: p.venue)
            // Re-read through the classifier ITSELF, so a corrected row and a freshly scouted one cannot
            // disagree about what the same inputs imply. This is never a second copy of the live rules.
            let reread = EventClassifier.classify(asStored)
            // ...and against the same two strings the classifier matched them on, from its own function.
            let strings = EventClassifier.signalStrings(for: asStored)

            // The old rule's verdict on THIS row, from the frozen lists above. `agency` is checked because
            // it outranked both of the axes below in the old classifier exactly as it does in the new one:
            // a row the old rule called agency was never given a producer signal to lose.
            let oldSaidAgency = matchedByTheOldRule(strings.haystack, Self.oldAgencySignal)
            let oldNamedAnOrganisation =
                !oldSaidAgency && matchedByTheOldRule(strings.party, Self.oldProducerSignal)
            let oldSaidStrong =
                oldNamedAnOrganisation && matchedByTheOldRule(strings.haystack, Self.oldStrongProfile)

            let storedProduction = Production(rawValue: p.production) ?? .unknown
            let storedProfile = Profile(rawValue: p.profile) ?? .neutral

            var production = storedProduction
            var profile = storedProfile
            // Lowered only where all three hold: the row stores the value, the old rule produces it from
            // what the row holds now, and today's classifier refuses it. `unknown` rather than the
            // re-read's value, which is the same thing here (the re-read cannot say `selfProduced` and
            // be refused at once) and says plainly that this is a take-back, not a re-classification.
            if storedProduction == .selfProduced, oldNamedAnOrganisation, reread.production == .unknown {
                production = .unknown
                summary.productionLowered += 1
            }
            if storedProfile == .strong, oldSaidStrong, reread.profile != .strong {
                profile = .neutral
                summary.profileLowered += 1
            }
            guard production != storedProduction || profile != storedProfile else { continue }

            p.production = production.rawValue
            p.profile = profile.rawValue

            // Coverage is DERIVED from the other axes and never merged alongside them (#1949), so it moves
            // with them here or it would describe a row nothing saw: "likely without its own photographer"
            // is drawn from being a strong-profile self-produced group, which is the very thing being taken
            // back. Derived against the STORED genre, deliberately: this pass has no business re-deciding
            // the genre, and re-reading the title would.
            let settled = Discipline(rawValue: p.discipline) ?? .other
            let derived = EventClassifier.derived(discipline: settled, production: production,
                                                  profile: profile, venue: p.venue)
            p.coverage = derived.coverage.rawValue

            let refit = ClassificationOverride.rescored(p, now: now)
            p.fitScore = refit.score
            p.tier = refit.tier.rawValue
            summary.rescored += 1
        }
        return summary
    }
}
