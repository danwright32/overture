import Testing
import Foundation
import SwiftUI

// #4358 slice E4d (plan item 15): THE EQUATABLE ROW, held to its own stored properties.
//
// A Scout card is `QueueSendAwareRow` with a hand written `==`, wrapped in `.equatable()` at its one call site
// (`QueueView.prospectRow`), so a body evaluation of the queue that changed nothing a card draws skips the card's
// body (#4322; `AnUnchangedScoutCardSkipsItsBodyTests` and `OneChangeDerivesTheQueueOnceTests.oneCardActionReRunsOneCardBody`
// measure that, per card, through the real view). What those cannot see is a stored property added LATER and left
// out of `==`: the card would then keep drawing its old value while every count stayed green (L14). So this
// enumerates each type's stored properties by `Mirror` and holds every one to the comparison:
//
//   * `ScoutCardInputs`, whose `==` is synthesized: every stored property must change the answer when it changes,
//     proved by moving each one alone. A new property must be added to `variations` below, which is the point.
//   * `QueueSendAwareRow`, whose `==` is written by hand: its stored properties are exactly the four it was written
//     against, `content` being the one deliberately left out (a closure SwiftUI can never find equal), so a fifth
//     fails here until somebody decides whether `==` reads it.
@MainActor
@Suite("A Scout card compares everything it is drawn from (#4322, #4358 plan item 15)")
struct ScoutCardComparesWhatItDrawsTests {

    private static func item(_ name: String = "Lantern Quartet") -> QueueItem {
        QueueItem(id: "card-1", groupName: name, discipline: "music", venue: "Venue Hall", performanceDate: "2027-03-10",
                  sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                  coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                  possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    private static func inputs(item: QueueItem = item(), today: String = "2027-01-15",
                               now: Date = Date(timeIntervalSince1970: 1_800_014_400), gmailConnected: Bool = true,
                               checkRunning: Bool = false, probeRunning: Bool = false, checkRunSince: Date? = nil,
                               checkLookups: Int? = nil, offeredEarlyAsAClient: Bool = false,
                               userExcludedTowns: Set<String> = [], allowedSeedTowns: Set<String> = []) -> ScoutCardInputs {
        ScoutCardInputs(item: item, today: today, now: now, gmailConnected: gmailConnected, checkRunning: checkRunning,
                        probeRunning: probeRunning, checkRunSince: checkRunSince, checkLookups: checkLookups,
                        offeredEarlyAsAClient: offeredEarlyAsAClient, userExcludedTowns: userExcludedTowns,
                        allowedSeedTowns: allowedSeedTowns)
    }

    // One variation per stored property, each moving that property alone.
    private static let variations: [String: ScoutCardInputs] = [
        "item": inputs(item: item("Glass Lantern Revue")),
        "today": inputs(today: "2027-01-16"),
        "clockMinute": inputs(now: Date(timeIntervalSince1970: 1_800_014_400 + 60)),
        "gmailConnected": inputs(gmailConnected: false),
        "checkRunning": inputs(checkRunning: true),
        "probeRunning": inputs(probeRunning: true),
        "checkRunSince": inputs(checkRunSince: Date(timeIntervalSince1970: 1_800_000_000)),
        "checkLookups": inputs(checkLookups: 4),
        "offeredEarlyAsAClient": inputs(offeredEarlyAsAClient: true),
        "userExcludedTowns": inputs(userExcludedTowns: ["Poughkeepsie"]),
        "allowedSeedTowns": inputs(allowedSeedTowns: ["Hoboken"]),
    ]

    @Test func everyStoredInputOfACardChangesWhetherItRedraws() {
        let base = Self.inputs()
        let stored = Set(Mirror(reflecting: base).children.compactMap(\.label))
        #expect(stored.count >= 10, "Mirror read \(stored.count) properties, so nothing was enumerated")
        #expect(stored == Set(Self.variations.keys), Comment(rawValue:
            "ScoutCardInputs stores \(stored.sorted()) and this suite varies \(Self.variations.keys.sorted()). A "
            + "property added without a variation is one nobody proved the card redraws for"))
        for (name, moved) in Self.variations {
            #expect(moved != base, "moving \(name) alone left the card equal, so it would not redraw for it")
        }
        #expect(Self.inputs() == base, "two cards built from the same inputs are not equal, so every card redraws")
    }

    @Test func theRowComparesEveryStoredPropertyButItsContent() {
        let state = SendProgressState()
        let row = QueueSendAwareRow(key: "card-1", sendState: state, redrawsOn: Self.inputs()) { _, _, _, _ in
            EmptyView()
        }
        let stored = Set(Mirror(reflecting: row).children.compactMap(\.label))
        #expect(stored == ["key", "sendState", "redrawsOn", "content"], Comment(rawValue:
            "QueueSendAwareRow stores \(stored.sorted()). Its hand written == compares key, sendState and redrawsOn "
            + "and leaves content out on purpose; decide whether == reads any new property before adding it here"))
        let moved = QueueSendAwareRow(key: "card-1", sendState: state,
                                      redrawsOn: Self.inputs(gmailConnected: false)) { _, _, _, _ in EmptyView() }
        #expect(row != moved, "the row's == ignores what the card is drawn from")
        let sameAgain = QueueSendAwareRow(key: "card-1", sendState: state, redrawsOn: Self.inputs()) { _, _, _, _ in
            EmptyView()
        }
        #expect(row == sameAgain, "two rows over the same inputs with fresh closures are not equal, so every card redraws")
    }
}
