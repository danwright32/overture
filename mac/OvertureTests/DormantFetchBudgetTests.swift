import Testing
import Foundation
import SwiftData

// #1557: the fetch budget is kept as a lever and is DORMANT, and this suite is what makes that state
// visible instead of ambiguous.
//
// Dan's call, 2026-08-08, offered delete-it against keep-it-as-a-lever: keep it. Fetching and hashing is
// free, so nothing caps it today, but a much larger watchlist could want a runaway guard and the ceiling
// is the lever for it.
//
// The danger that makes this worth pinning is not the budget itself, it is being MISREAD. `waitingToRead`
// has a full set of passing tests, and every one of them hands it a deferred list built by hand. Read
// quickly, that looks like evidence the "N venues still waiting to be checked" count is live. It is not:
// on every run the shipping app makes, `plan.deferred` is empty, so that filter decides nothing on screen
// and only `declined` (sources Dan chose not to read at the ScoutReadBudget prompt) reaches the popup.
//
// #1546 was filed on exactly that misreading: a reasonable-looking premise that a permanently unread
// source holds the count above zero forever, supported by the code as read, and impossible in fact
// because nothing is ever deferred.
@MainActor
@Suite("The fetch budget is a dormant lever, not live behaviour (#1557)")
struct DormantFetchBudgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(_ id: String, hasUnreadChanges: Bool = false) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, listingsURL: "https://\(id).example/events",
                              kind: .html)
        s.isActive = true
        s.hasUnreadChanges = hasUnreadChanges
        return s
    }

    // The DEFAULT plan, which is the only plan the app ever builds, defers nothing at any size. 200 is
    // comfortably past the live watchlist (62 sources as of #1498) so the assertion is not accidentally
    // true of small inputs alone.
    @Test func theDefaultPlanDefersNothingHoweverLargeTheWatchlist() {
        let sources = (1...200).map { source("org-\($0)", hasUnreadChanges: $0.isMultiple(of: 2)) }

        let plan = SourceSchedule.plan(sources: sources, depth: .readChanged, now: now)

        #expect(plan.fetch.count == 200, "the default plan must fetch every watched source")
        #expect(plan.deferred.isEmpty, "the default plan must defer nothing, so nothing is 'waiting'")
    }

    // The consequence, stated where it can fail: on a default run the waiting filter has nothing to
    // filter, however many sources carry unread listings. This is the test that stops the OTHER
    // waitingToRead tests being read as proof the count is live.
    @Test func waitingToReadDecidesNothingOnADefaultRun() {
        let sources = (1...50).map { source("org-\($0)", hasUnreadChanges: true) }

        let plan = SourceSchedule.plan(sources: sources, depth: .readChanged, now: now)

        #expect(SourceSchedule.waitingToRead(deferred: plan.deferred).isEmpty,
                "every source here carries unread listings, and still none is WAITING: a default run defers none")
    }

    // The lever itself still works, so keeping it is keeping something real rather than a comment. A
    // caller that passes a ceiling below the count gets the deferred split, and the waiting filter then
    // does decide something.
    @Test func aCallerThatPassesACeilingStillGetsOne() {
        let changed = source("changed", hasUnreadChanges: true)
        let quiet = source("quiet")
        let alsoChanged = source("also-changed", hasUnreadChanges: true)

        let plan = SourceSchedule.plan(sources: [changed, quiet, alsoChanged],
                                       depth: .readChanged, budget: 1, now: now)

        #expect(plan.fetch.count == 1)
        #expect(plan.deferred.count == 2)

        // Which of the two changed sources wins the single slot is decided by the ordering rules, not by
        // this suite, so the claim here is about the SHAPE: exactly one changed source is left deferred
        // and it is the one reported as waiting, while the quiet one is not.
        let waiting = SourceSchedule.waitingToRead(deferred: plan.deferred)
        let everyWaitingSourceHasSomethingToRead = waiting.allSatisfy(\.isCarryingUnreadListings)
        #expect(waiting.count == 1, "the one deferred source carrying unread listings is waiting")
        #expect(everyWaitingSourceHasSomethingToRead)
        #expect(!waiting.map(\.sourceId).contains("quiet"), "an unchanged source has nothing to read")
    }

    // And the reason the default holds in the shipping app: no call site sets a ceiling. Source text
    // rather than behaviour, because the value is a defaulted parameter, so no runtime call can prove
    // what every OTHER call site passes. A new caller passing a number is the change this must catch,
    // since it would make the dormant path live without anyone revisiting the decision above.
    @Test func noCallSiteInTheAppSetsACeiling() {
        let allowed = ["budget: Int = unlimitedBudget",
                       "budget: Int = SourceSchedule.unlimitedBudget",
                       "budget: budget"]
        var inspected = 0

        for path in ["Overture/Domain/SourceSchedule.swift", "Overture/Integration/ScoutService.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "\(path) did not read, so this guard is inspecting nothing")

            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                // Prose about the budget is not a call site.
                guard text.contains("budget:"), !text.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                else { continue }
                inspected += 1
                #expect(allowed.contains(where: text.contains),
                        "\(path) passes a fetch ceiling, which wakes the deferred path: \(text)")
            }
        }

        #expect(inspected >= 3,
                "expected the declaration and its forwarding call; this guard no longer reads the code it names")
    }
}
