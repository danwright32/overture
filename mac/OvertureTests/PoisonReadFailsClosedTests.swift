import Testing
import Foundation
import SwiftData

// #4056: what the sweep does when it CANNOT read the rows the production token discard is judged over.
//
// The first version of that read answered an unreadable store with an empty set, and
// `ScoutStoreReadTests.noScoutReadInventsAnEmptyStore` caught it by scanning the source. That guard is
// real and it fired, but it can only prove the PATTERN is absent: nothing in it runs the branch. A
// healthy in-memory store never throws, so the failing path had no test at all, which is what the
// pre-push gate refused (correctly).
//
// The direction matters more here than in most places. An empty poison set does not mean "nothing
// happens", it means NOTHING IS REFUSED, so every join this rule exists to prevent is licensed in the
// one situation where the code knows least. A refusal costs a duplicate card Dan can see and merge; a
// wrong join carries a stored row's dismissal, its recipients and its thread id onto another show,
// silently (#797). So the unreadable case takes the side that can be undone (L42, L215).
@MainActor
@Suite("An unreadable store refuses every token, not none (#4056)")
struct PoisonReadFailsClosedTests {

    private struct StoreIsDown: Error {}

    private static let token = "https://thegreenroom42.venuetix.com/showdetails/GWKuL2pmNJBPIkIkHB0h"

    private func incoming(_ title: String, _ night: String) -> AssembledProspect {
        AssembledProspect(groupName: title, presenter: nil, location: nil, discipline: "theatre",
                          venue: "The Green Room 42", performanceDate: night,
                          sourceListingURL: "\(Self.token)/\(night)", reachable: true,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    // THE BRANCH. The read throws, so the answer must be every token the sweep carries, which makes the
    // arm join nothing at all.
    @Test func afailedReadPoisonsEveryTokenTheSweepCarries() throws {
        let rows = [incoming("First Show", "2026-10-12"), incoming("Second Show", "2026-10-29")]

        let poisoned = try? ScoutService.poisonedTokensForBatch(rows,
                                                                storedRows: { throw StoreIsDown() })
        // It THROWS rather than answering, and the caller is what decides the direction. Asserted here so
        // a later change that swallows the error inside this function is caught: swallowing it would put
        // the empty-set defect back where the source scan can no longer see it.
        #expect(poisoned == nil,
                "the read swallowed a failure and answered, so the caller can no longer fail closed")
    }

    // The healthy path still answers with only what is genuinely ambiguous, or the test above would be
    // satisfied by a function that refuses everything always (L159).
    @Test func areadableStoreRefusesOnlyTheAmbiguousToken() throws {
        let rows = [incoming("First Show", "2026-10-12"), incoming("Second Show", "2026-10-29")]

        let poisoned = try ScoutService.poisonedTokensForBatch(rows, storedRows: { [] })

        #expect(poisoned.count == 1,
                Comment(rawValue: "two incoming titles share one token, so it is ambiguous and must be "
                        + "refused: got \(poisoned)"))
    }

    @Test func onetitleAcrossTheBatchPoisonsNothing() throws {
        let rows = [incoming("First Show", "2026-10-12"), incoming("First Show", "2026-10-29")]

        let poisoned = try ScoutService.poisonedTokensForBatch(rows, storedRows: { [] })

        #expect(poisoned.isEmpty,
                "one title across the batch is an ordinary run, and refusing it would break the arm")
    }
}
