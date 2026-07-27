import Testing
@testable import Overture

// #1597 (milestone 32 Phase 4.3): what a multi-date check actually PAYS for.
//
// The measured price of a reachability check is about $1.36 a show, so a week of 66 shows is a ~$90
// click. The work list was one entry per show with no grouping, which meant a week handed the runner
// Carnegie Hall Presents eight separate times and paid each time for the same answer.
@Suite("The probe batch pays once per organisation (#1597)")
struct ProbeBatchTests {

    private func show(_ key: String, presenter: String?, venue: String?) -> ProbeBatch.Show {
        ProbeBatch.Show(key: key, presenter: presenter, venue: venue)
    }

    // A real producer: FRIGID New York rents several rooms and its own name is never a venue.
    private var frigidCorpus: [ProbeBatch.Show] {
        [show("a", presenter: "FRIGID New York", venue: "Under St Marks"),
         show("b", presenter: "FRIGID New York", venue: "The Kraine Theater"),
         show("c", presenter: "FRIGID New York", venue: "Under St Marks")]
    }

    @Test func showsFromOneProducerCollapseToASingleEntry() {
        let plan = ProbeBatch.plan(selecting: ["a", "b", "c"], among: frigidCorpus)
        #expect(plan.keysToRun.count == 1)
        #expect(plan.organisationCount == 1)
        #expect(plan.performerHuntCount == 0)
        // The two that are not run are named, and each points at the entry that answers for it.
        #expect(plan.coveredBy.count == 2)
        let runKey = plan.keysToRun[0]
        #expect(plan.coveredBy.values.allSatisfy { $0 == runKey })
        #expect(!plan.coveredBy.keys.contains(runKey))
    }

    // THE DANGEROUS CASE, and the one the gate exists for. A room that rents itself out must never
    // collapse: its shows are unrelated productions that happen to share an address, and one answer
    // stamped across them would be a wrong contact on every card. Failing this way is worse than paying
    // three times, so the batch pays three times.
    @Test func aRoomThatRentsItselfOutNeverCollapses() {
        let corpus = [show("a", presenter: "Green Room 42", venue: "Green Room 42"),
                      show("b", presenter: "Green Room 42", venue: "Green Room 42, 570 Tenth Ave, NYC"),
                      show("c", presenter: "Green Room 42", venue: "Green Room 42")]
        let plan = ProbeBatch.plan(selecting: ["a", "b", "c"], among: corpus)
        #expect(plan.keysToRun.count == 3)
        #expect(plan.coveredBy.isEmpty)
        #expect(plan.organisationCount == 0)
        #expect(plan.performerHuntCount == 3)
    }

    // A show naming no producer is a one-off performer hunt: it is its own entry and amortises nothing.
    @Test func aShowWithNoProducerIsItsOwnEntry() {
        let corpus = [show("a", presenter: nil, venue: "Green Room 42"),
                      show("b", presenter: "", venue: "Joe's Pub")]
        let plan = ProbeBatch.plan(selecting: ["a", "b"], among: corpus)
        #expect(plan.keysToRun.count == 2)
        #expect(plan.performerHuntCount == 2)
        #expect(plan.organisationCount == 0)
    }

    // The gate is judged against the WHOLE store, not just the shows Dan ticked. Otherwise picking one
    // night would make every producer look like a single-venue house and nothing would ever amortise,
    // which is the entire saving. Here the selection sees FRIGID at one venue; the store knows better.
    @Test func theGateJudgesAgainstTheWholeStoreNotJustTheSelection() {
        let plan = ProbeBatch.plan(selecting: ["a", "c"], among: frigidCorpus)
        #expect(plan.keysToRun.count == 1)
        #expect(plan.organisationCount == 1)
    }

    // Two different producers do not merge into each other.
    @Test func differentProducersEachGetTheirOwnEntry() {
        let corpus = frigidCorpus + [
            show("d", presenter: "Ars Nova", venue: "Greenwich House"),
            show("e", presenter: "Ars Nova", venue: "The Connelly Theater"),
        ]
        let plan = ProbeBatch.plan(selecting: ["a", "b", "d", "e"], among: corpus)
        #expect(plan.keysToRun.count == 2)
        #expect(plan.organisationCount == 2)
        #expect(plan.coveredBy.count == 2)
    }

    // Same answer for the same input, every time: the entry that gets run cannot depend on dictionary
    // ordering, or the confirm would quote one show and the runner would research a different one.
    @Test func theChosenEntryIsStableAcrossRuns() {
        let first = ProbeBatch.plan(selecting: ["c", "b", "a"], among: frigidCorpus)
        let second = ProbeBatch.plan(selecting: ["c", "b", "a"], among: frigidCorpus)
        #expect(first.keysToRun == second.keysToRun)
        #expect(first.keysToRun == ["a"])  // earliest in the corpus order, not in the selection order
    }

    // A key Dan selected that is not in the store at all is dropped rather than sent to the runner as a
    // phantom entry it would research and never match back.
    @Test func aSelectedKeyThatIsNotInTheStoreIsDropped() {
        let plan = ProbeBatch.plan(selecting: ["a", "ghost"], among: frigidCorpus)
        #expect(plan.keysToRun == ["a"])
        #expect(!plan.coveredBy.keys.contains("ghost"))
    }

    // Dan's hand promotion relaxes the venue-count arm only, so a producer he has confirmed amortises
    // even when the store has only ever seen it at one room.
    @Test func aPromotedProducerAmortisesOnASingleVenue() {
        let corpus = [show("a", presenter: "Tiny Co", venue: "The Tank"),
                      show("b", presenter: "Tiny Co", venue: "The Tank")]
        #expect(ProbeBatch.plan(selecting: ["a", "b"], among: corpus).keysToRun.count == 2)
        let promoted = ProbeBatch.plan(selecting: ["a", "b"], among: corpus,
                                       promoted: [ProducerGate.key("Tiny Co")!])
        #expect(promoted.keysToRun.count == 1)
        #expect(promoted.organisationCount == 1)
    }

    // The saving, stated as the number the confirm will show Dan.
    @Test func theBatchReportsWhatItSavedOverPayingPerShow() {
        let plan = ProbeBatch.plan(selecting: ["a", "b", "c"], among: frigidCorpus)
        #expect(plan.selectedCount == 3)
        #expect(plan.keysToRun.count == 1)
        #expect(plan.coveredBy.count == 2)
        #expect(plan.selectedCount == plan.keysToRun.count + plan.coveredBy.count)
    }
}
