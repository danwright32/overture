import Testing
@testable import Overture

private func event(date: String? = "2026-07-01", venue: String? = "Weill Recital Hall") -> ExtractedEvent {
    ExtractedEvent(title: "Test Group", presenter: "Test Choir", venue: venue, performanceDate: date, sourceUrl: nil)
}

private func classification(
    reachable: Bool = true,
    production: Production = .selfProduced,
    profile: Profile = .strong,
    coverage: Coverage = .likelyUncovered,
    discipline: Discipline = .music
) -> EventClassification {
    EventClassification(discipline: discipline, reachable: reachable, production: production,
                        profile: profile, coverage: coverage, fitReason: "reason", confidence: .confident)
}

private func verdict(relationship: PriorRelationship = .none, suppressed: Bool = false) -> MatchVerdict {
    MatchVerdict(relationship: relationship, suppressed: suppressed, downbeatClientId: nil,
                 matchedClientName: nil, possible: nil)
}

@Suite("Prospect assembler")
struct ProspectAssemblerTests {
    @Test func blockedDateIsSkipped() {
        let d = ProspectAssembler.decide(
            event: event(date: "2026-07-01"), classification: classification(),
            verdict: verdict(), blocked: ["2026-07-01"])
        #expect(d == .skip(.blocked))
    }

    @Test func dncSuppressedIsSkipped() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(),
            verdict: verdict(suppressed: true), blocked: [])
        #expect(d == .skip(.suppressed))
    }

    @Test func unreachableIsSkipped() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(reachable: false),
            verdict: verdict(), blocked: [])
        #expect(d == .skip(.unreachable))
    }

    @Test func strongSelfProducedChoirBecomesHighFitProspect() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(),
            verdict: verdict(), blocked: [])
        guard case let .prospect(p) = d else { #expect(Bool(false), "expected a prospect"); return }
        // self(2) + strong(2) + uncovered(2) + music(1, #350 merged Choral's score) = 7
        #expect(p.fitScore == 7)
        #expect(p.tier == "high")
        #expect(p.discipline == "music")
        #expect(p.priorRelationship == "none")
    }

    @Test func priorBookingCarriesIntoTheScore() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(),
            verdict: MatchVerdict(relationship: .booked, suppressed: false, downbeatClientId: "c1",
                                  matchedClientName: "DCINY", possible: nil),
            blocked: [])
        guard case let .prospect(p) = d else { #expect(Bool(false)); return }
        #expect(p.priorRelationship == "booked")
        #expect(p.matchedClientName == "DCINY")
        #expect(p.fitScore == 27) // 7 + booked(20)
    }
}
