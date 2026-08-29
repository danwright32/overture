import Testing
import Foundation

// #1598 (milestone 32 Phase 5.4): what a row actually SHOWS when the answer was paid for on another show
// by the same organisation. Dan's call, 2026-07-27: identical to a checked row, address included, with
// the provenance only in the hover text. The badge alone does not tell him whether he is looking at a
// front desk or a person, which is the whole reason the address line exists (#1597 follow-up).
@Suite("Inherited reachability (#1598)")
struct InheritedReachabilityTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inherited(_ emails: [String] = ["hello@tenet.example"], daysAgo: Double = 10)
        -> OrgAnswerLedger.Inherited {
        OrgAnswerLedger.Inherited(result: .emailFound,
                                  probedAt: now.addingTimeInterval(-daysAgo * 86_400),
                                  organisation: "Tenet Vocal Artists", emails: emails)
    }

    private func item(id: String = "k", own: Reachability.ProbeResult? = nil, probedAt: Date? = nil,
                      inheritedAnswer: OrgAnswerLedger.Inherited? = nil,
                      contacts: [String] = []) -> QueueItem {
        var i = QueueItem(id: id, groupName: "Light as Air", discipline: "music",
                          venue: "House of the Redeemer", performanceDate: "2026-09-12",
                          sourceListingURL: "https://example.org/show",
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.presenter = "Tenet Vocal Artists"
        i.reachabilityResult = own
        i.reachabilityProbedAt = probedAt
        i.inheritedReachability = inheritedAnswer
        i.contacts = contacts.map {
            RecipientSnapshot(id: $0, name: "Someone", email: $0, role: nil, provenance: .presenter,
                              sendState: .pending, replied: false, lastReplyText: nil,
                              resolution: nil, bounced: false, outcomeSource: nil)
        }
        return i
    }

    @Test("an inherited answer wears the same badge as one paid for on this show")
    func inheritedRendersAsEmailFound() {
        #expect(item(inheritedAnswer: inherited()).reachabilityBadge(now: now) == .emailFound)
    }

    @Test("with no answer of its own and nothing inherited, the row falls back to the free heuristic")
    func withoutAnythingItStaysOnTheHeuristic() {
        #expect(item().reachabilityBadge(now: now) == .none)
    }

    // A check on THIS show is about this show. The organisation's answer is about a different one, so it
    // never overrides what Dan has already paid to learn here.
    @Test("a show's own answer always wins over the organisation's")
    func ownAnswerWins() {
        let i = item(own: .noEmailFound, probedAt: now, inheritedAnswer: inherited())
        #expect(i.reachabilityBadge(now: now) == .noEmailFound)
    }

    @Test("the inherited address is what the row shows when the show has no contacts of its own")
    func inheritedAddressIsShown() {
        #expect(item(inheritedAnswer: inherited()).displayedContactEmails == ["hello@tenet.example"])
    }

    // A show that was researched itself shows ITS contacts, never the organisation's, even when both
    // exist. Mixing the two would put an address on the card that no check on this show ever produced.
    @Test("a show's own contacts are never replaced by the organisation's")
    func ownContactsWin() {
        let i = item(own: .emailFound, probedAt: now, inheritedAnswer: inherited(),
                     contacts: ["jane@thisshow.example"])
        #expect(i.displayedContactEmails == ["jane@thisshow.example"])
    }

    // The saving only lands if the paid control stops offering to research what is already answered. It
    // would also be a card contradicting itself: "Email found" beside a button offering to find one.
    @Test("a show carrying an inherited answer is no longer offered for a paid check")
    func inheritedShowsAreNotProbeCandidates() {
        let plain = item()
        let withAnswer = item(id: "k2", inheritedAnswer: inherited())
        let keys = QueueModel.reachabilityProbeCandidateKeys([plain, withAnswer], now: now,
                                                             today: "2026-08-01")
        #expect(keys == ["k"])
    }
}
