import Testing

private func event(
    date: String? = "2026-07-01", venue: String? = "Weill Recital Hall", presenter: String? = "Test Choir"
) -> ExtractedEvent {
    ExtractedEvent(title: "Test Group", presenter: presenter, venue: venue, performanceDate: date, sourceUrl: nil)
}

private func classification(
    reachable: Bool = true,
    production: Production = .selfProduced,
    profile: Profile = .strong,
    coverage: Coverage = .likelyUncovered,
    discipline: Discipline = .music
) -> EventClassification {
    EventClassification(discipline: discipline, reachable: reachable, production: production,
                        profile: profile, coverage: coverage, fitReason: "reason")
}

private func verdict(relationship: PriorRelationship = .none, suppressed: Bool = false) -> MatchVerdict {
    MatchVerdict(relationship: relationship, suppressed: suppressed, downbeatClientId: nil,
                 matchedClientName: nil, possible: nil)
}

@Suite("Prospect assembler")
struct ProspectAssemblerTests {
    // #901: the assembler no longer knows about blocked dates at all, and it must not: it decides per
    // EVENT, before the nights of a run have been grouped, so it cannot see a run's later nights. The
    // conflict is found at the run (ScoutService.apply) and FLAGS the show rather than dropping it. This
    // pins that a date, on its own, can no longer make a show vanish here.
    @Test func aDateAloneNeverSkipsAShow() {
        let d = ProspectAssembler.decide(
            event: event(date: "2026-07-01"), classification: classification(), verdict: verdict())
        guard case .prospect = d else { #expect(Bool(false), "a date must not drop a show"); return }
    }

    @Test func dncSuppressedIsSkipped() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(),
            verdict: verdict(suppressed: true))
        #expect(d == .skip(.suppressed))
    }

    @Test func unreachableIsSkipped() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(reachable: false),
            verdict: verdict())
        #expect(d == .skip(.unreachable))
    }

    @Test func strongSelfProducedChoirBecomesHighFitProspect() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(),
            verdict: verdict())
        guard case let .prospect(p) = d else { #expect(Bool(false), "expected a prospect"); return }
        // self(2) + strong(2) + uncovered(2) + music(1, #350 merged Choral's score) = 7
        #expect(p.fitScore == 7)
        #expect(p.tier == "high")
        #expect(p.discipline == "music")
        #expect(p.priorRelationship == "none")
    }

    // The classifier reads the presenter (EventClassifier.classify builds its haystack from title AND
    // presenter), but the presenter was dropped at assemble and never stored. That made every
    // classification a one-way door: #980 fixed the classifier and could not be replayed over the 128
    // existing rows, because half the input was gone. Recomputing from `groupName` alone does not
    // reproduce the classifier, it approximates it, and would write answers a real scout would not give
    // ("Chengcheng Ma and Guest Artists" presented by a chamber orchestra reads as `.other` without its
    // presenter and `.music` with it). Keeping the presenter is what makes a future rule change
    // backfillable instead of forward-only forever.
    @Test func theAssemblerKeepsThePresenterTheClassifierRead() {
        let d = ProspectAssembler.decide(
            event: event(presenter: "Indianapolis Children's Choir"),
            classification: classification(), verdict: verdict())
        guard case let .prospect(p) = d else { #expect(Bool(false), "expected a prospect"); return }
        #expect(p.presenter == "Indianapolis Children's Choir")
    }

    // A listing with no presenter is normal, not an error. It must round-trip as absent rather than as
    // an empty string, so a later backfill can tell "no presenter published" from "we never asked".
    @Test func anAbsentPresenterStaysAbsent() {
        let d = ProspectAssembler.decide(
            event: event(presenter: nil), classification: classification(), verdict: verdict())
        guard case let .prospect(p) = d else { #expect(Bool(false), "expected a prospect"); return }
        #expect(p.presenter == nil)
    }

    // #1087: a titleless-but-genuine show is named from its presenter, and that derived name is what
    // becomes the prospect's `groupName`, not the empty title string. The assembler is the single place
    // that turns an extracted event into a prospect, so this is where the rescued name has to land, or a
    // kept show would still surface nameless and key badly.
    @Test func aTitlelessShowIsNamedFromItsPresenterInGroupName() {
        let d = ProspectAssembler.decide(
            event: ExtractedEvent(title: "", presenter: "Aurora Strings", venue: "Merkin Hall",
                                  performanceDate: "2026-09-19", sourceUrl: nil, location: nil),
            classification: classification(), verdict: verdict())
        guard case let .prospect(p) = d else { #expect(Bool(false), "expected a prospect"); return }
        #expect(p.groupName == "Aurora Strings")
        // groupName is half the natural key (Prospect.makeNaturalKey pairs it with date and venue), so a
        // rescued name must produce a real, non-empty key rather than one that starts with a blank slot.
        let key = Prospect.makeNaturalKey(groupName: p.groupName, performanceDate: p.performanceDate,
                                          venue: p.venue)
        #expect(key == "aurora strings|2026-09-19|merkin hall")
    }

    // With no presenter either, the venue names the show and reaches `groupName`. The order matches the
    // guard: presenter first, venue only when there is no presenter.
    @Test func aTitlelessPresenterlessShowIsNamedFromItsVenueInGroupName() {
        let d = ProspectAssembler.decide(
            event: ExtractedEvent(title: "", presenter: nil, venue: "Merkin Hall",
                                  performanceDate: "2026-09-19", sourceUrl: nil, location: nil),
            classification: classification(), verdict: verdict())
        guard case let .prospect(p) = d else { #expect(Bool(false), "expected a prospect"); return }
        #expect(p.groupName == "Merkin Hall")
    }

    @Test func priorBookingCarriesIntoTheScore() {
        let d = ProspectAssembler.decide(
            event: event(), classification: classification(),
            verdict: MatchVerdict(relationship: .booked, suppressed: false, downbeatClientId: "c1",
                                  matchedClientName: "DCINY", possible: nil))
        guard case let .prospect(p) = d else { #expect(Bool(false)); return }
        #expect(p.priorRelationship == "booked")
        #expect(p.matchedClientName == "DCINY")
        #expect(p.fitScore == 27) // 7 + booked(20)
    }
}
