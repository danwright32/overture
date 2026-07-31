import Testing
import Foundation
import SwiftData
@testable import Overture

// #1817: a check that could not work out WHO to write to must not report that this show's people publish
// no address. Those are different findings, and only one of them was measured.
//
// The reported case: "Feminine Rage" at The Green Room 42 named five performers and no producer, and the
// card said "No email found" while the first performer on the bill published a contact form on her own
// site. `nothing_published` means "you looked and this show's act, performers and presenter publish no
// usable address anywhere you could reach" (`docs/prep-runbook.md`), which the run never established: it
// never had a party to look for.
//
// #1856 gave the run the ability to pursue the act on these shows, so from here the honest empty answer is
// "nobody was identified to pursue", which is its own fact and its own sentence.
@MainActor
@Suite("A check that found nobody to pursue says so (#1817)")
struct NobodyToPursueTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The contract's own spelling, pinned here because this raw string crosses the language boundary in
    // overture-prep-results.json.
    @Test func theReasonIsPartOfTheContractsVocabulary() {
        #expect(Reachability.EmptyReason(rawValue: "no_one_identified") == .noOneIdentified)
    }

    // The whole point: a distinct sentence Dan acts on differently. "Nobody publishes an address" is a
    // finished search he can give up on; "we could not tell who to write to" is a show he can look at
    // himself, and it is the one where his own knowledge of a room beats the run's.
    @Test func itSaysSomethingDifferentFromNobodyPublishingAnAddress() {
        let mine = ReachabilityCopy.emptyAnswerBadge(.noOneIdentified)
        #expect(mine != ReachabilityCopy.emptyAnswerBadge(.nothingPublished))
        #expect(ReachabilityCopy.emptyAnswerHelp(.noOneIdentified)
                != ReachabilityCopy.emptyAnswerHelp(.nothingPublished))
        // And it must not claim a search it never ran.
        #expect(!mine.lowercased().contains("no email"))
    }

    // Still an empty answer, so it keeps the same weight on the row: a new reason varies the SENTENCE and
    // nothing else (#1722's rule, which the fit score, the ledger and the pill palette all rely on).
    @Test func itIsStillTheSameEmptyAnswerUnderneath() {
        #expect(Reachability.badge(result: .noEmailFound, presenter: nil,
                                   sourceListingURL: "https://example.org/events/1",
                                   websiteURL: nil) == .noEmailFound)
        #expect(Reachability.tone(for: .noEmailFound) == .warning)
    }

    // A guard and its wiring are two claims. This one rides in on the results file, so the value has to
    // survive the trip from the run's JSON to the row Dan reads.
    @Test func theReasonReachesTheRowFromTheRunsResults() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Feminine Rage", performanceDate: "2026-08-03",
                                          venue: "The Green Room 42")
        let p = Prospect(naturalKey: key, groupName: "Feminine Rage", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-08-03",
                         sourceListingURL: "https://thegreenroom42.venuetix.com/showdetails/1/2",
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()

        let results = PrepResults(version: 7, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: nil, draft: nil, emptyReason: "no_one_identified")
        ])
        _ = PrepImporter.ingest(results, into: ctx, now: Date(), isProbe: true)

        #expect(p.reachabilityEmptyReason == .noOneIdentified)
        #expect(ReachabilityCopy.emptyAnswerBadge(p.reachabilityEmptyReason)
                == ReachabilityCopy.emptyAnswerBadge(.noOneIdentified))
    }

    // THE FAILURE DIRECTION: an unknown reason is still not coerced into this one. A run that emits
    // something nobody has taught the app must degrade to the plain wording, never to a specific claim.
    @Test func anUnknownReasonIsStillNotReadAsThisOne() {
        #expect(Reachability.EmptyReason(rawValue: "no_one_identified_yet") == nil)
        #expect(Reachability.EmptyReason(rawValue: "") == nil)
    }
}
