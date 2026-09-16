import Testing
import Foundation

// #3737: a run's night times are parsed once per SHOW, never once per night.
//
// WHAT THIS IS ABOUT. #3736 decomposed the queue render pass and put the self-booking night index at
// 125.9 ms of the pass's 421.6 ms floor, the single largest term in it. The cause is one line:
// `QueueModel.selfBookingShow` loops over a show's nights and calls `selfBookingStartTimes(_:on:)` for
// each, and that function's first act is to rebuild the whole night-to-times map from
// `nightStartTimes`, running a `DateFormatter` parse over every entry. A show with N nights carrying N
// entries therefore pays N squared parses to answer a question that needs N.
//
// COUNTED, NEVER TIMED. A timing assertion on a shared Mac measures what else the machine is running
// (L224). This repository already has the right shape for this exact question: #3438 added
// `WorkTally.selfBookingShowsExamined` because a CALL count is the same number whether each call reads
// one night's bucket or walks the whole queue (L63). This is that, one level down: the quantity is how
// many times the MAP IS BUILT, which moves with the code rather than with how many nights the store
// happens to hold.
@Suite("A run's night times are parsed once per show (#3737)")
struct NightTimesParsedOncePerShowTests {

    // A run of `nights` consecutive nights, each publishing its own curtain, which is the shape that
    // makes the cost quadratic: every night is both an iteration of the loop AND an entry the rebuilt map
    // has to parse. A single-night show cannot show the difference at all, which is why the fixture is
    // sized past the case rather than being minimal (L101).
    private func run(nights: Int) -> QueueScopeRow {
        let days = (1...nights).map { String(format: "2027-03-%02d", $0) }
        return QueueScopeRow(id: "k", groupName: "Aurora Strings", discipline: "music",
                             performanceDate: days.first,
                             runNights: days,
                             nightStartTimes: days.map { "\($0) 19:30" })
    }

    @Test("a ten night run parses its times once, not ten times")
    func aRunParsesItsTimesOnce() {
        let work = QueueRenderPass.WorkTally.measure {
            _ = QueueModel.selfBookingShow(run(nights: 10))
        }

        #expect(work.nightTimeMapBuilds == 1,
                Comment(rawValue: "building one show's self-booking entry parsed its night times "
                        + "\(work.nightTimeMapBuilds) times. It has ten nights, so this is once per night: "
                        + "the map is rebuilt inside the loop and every rebuild runs a DateFormatter over "
                        + "every entry, which is N squared parses for an N night run (#3737)."))
    }

    // The cost must not grow with the run's LENGTH, which is the claim a single fixture size cannot make.
    // Two sizes, and the same answer from both, is what says the term is flat rather than merely small
    // (L354: a fixture sized once silently under-represents whatever the real data grows into).
    @Test("the parse count does not grow with the number of nights")
    func theCountIsFlatInTheRunsLength() {
        let short = QueueRenderPass.WorkTally.measure { _ = QueueModel.selfBookingShow(run(nights: 2)) }
        let long = QueueRenderPass.WorkTally.measure { _ = QueueModel.selfBookingShow(run(nights: 40)) }

        #expect(short.nightTimeMapBuilds == long.nightTimeMapBuilds,
                Comment(rawValue: "a 2 night run parsed \(short.nightTimeMapBuilds) times and a 40 night "
                        + "run \(long.nightTimeMapBuilds). The cost is a function of the run's length, "
                        + "which is the quadratic #3737 removed."))
    }

    // A whole pass builds one map per show WITH NIGHTS, and none for a show without. The floor, so the
    // guard above cannot be satisfied by a map that is never built at all: zero parses and one parse are
    // different answers and both have to be sayable (L11).
    @Test("a show with no recorded nights parses nothing")
    func aShowWithNoNightsParsesNothing() {
        let bare = QueueScopeRow(id: "k", groupName: "Aurora Strings", discipline: "music",
                                 performanceDate: "2027-03-01")
        let work = QueueRenderPass.WorkTally.measure { _ = QueueModel.selfBookingShow(bare) }

        #expect(work.nightTimeMapBuilds == 0,
                Comment(rawValue: "a show carrying no night times still parsed \(work.nightTimeMapBuilds) "
                        + "times, so the map is built before anybody asks whether there is anything in it"))
    }

    // MARK: - Equivalence, which is what makes the saving safe

    // The ANSWER is unchanged, over every shape the documented behaviour distinguishes. A cost fix that
    // quietly changed which curtain belongs to which night would be invisible in the count above.
    @Test("the same show yields the same times, over every shape the rule distinguishes")
    func theAnswerIsUnchanged() {
        // A run whose nights all agree.
        let agreeing = QueueModel.selfBookingShow(run(nights: 3))
        #expect(agreeing.timesByNight == ["2027-03-01": ["19:30"], "2027-03-02": ["19:30"],
                                          "2027-03-03": ["19:30"]])

        // A run whose nights VARY, with a matinee. Each night keeps its own time and no night lends one.
        let varying = QueueScopeRow(
            id: "k", groupName: "A", discipline: "music", performanceDate: "2027-03-01",
            runNights: ["2027-03-01", "2027-03-02"],
            performanceStartTimes: ["19:30"],
            nightStartTimes: ["2027-03-01 19:30", "2027-03-02 14:00"],
            startTimesVary: true)
        #expect(QueueModel.selfBookingShow(varying).timesByNight
                == ["2027-03-01": ["19:30"], "2027-03-02": ["14:00"]])

        // A night carrying TWO curtains, which the hover renders as a double bill.
        let doubleBill = QueueScopeRow(
            id: "k", groupName: "A", discipline: "music", performanceDate: "2027-03-01",
            runNights: ["2027-03-01"],
            nightStartTimes: ["2027-03-01 14:00", "2027-03-01 19:30"])
        #expect(QueueModel.selfBookingShow(doubleBill).timesByNight == ["2027-03-01": ["14:00", "19:30"]])

        // A night the schedule says nothing about falls back to the card's own times, but ONLY when the
        // run's nights do not vary. Both directions, because the guard between them is one `!`.
        let silentNight = QueueScopeRow(
            id: "k", groupName: "A", discipline: "music", performanceDate: "2027-03-01",
            runNights: ["2027-03-01", "2027-03-02"],
            performanceStartTimes: ["19:30"],
            nightStartTimes: ["2027-03-01 19:30"])
        #expect(QueueModel.selfBookingShow(silentNight).timesByNight
                == ["2027-03-01": ["19:30"], "2027-03-02": ["19:30"]])

        let silentAndVarying = QueueScopeRow(
            id: "k", groupName: "A", discipline: "music", performanceDate: "2027-03-01",
            runNights: ["2027-03-01", "2027-03-02"],
            performanceStartTimes: ["19:30"],
            nightStartTimes: ["2027-03-01 19:30"],
            startTimesVary: true)
        #expect(QueueModel.selfBookingShow(silentAndVarying).timesByNight == ["2027-03-01": ["19:30"]])
    }

    // A malformed entry costs only ITSELF, which is the existing documented behaviour and the one a
    // rewrite is most likely to lose by making the whole map fail.
    @Test("a malformed entry loses only its own night")
    func aMalformedEntryLosesOnlyItself() {
        let mixed = QueueScopeRow(
            id: "k", groupName: "A", discipline: "music", performanceDate: "2027-03-01",
            runNights: ["2027-03-01", "2027-03-02"],
            nightStartTimes: ["not a night at all", "2027-03-02 19:30"])

        #expect(QueueModel.selfBookingShow(mixed).timesByNight == ["2027-03-02": ["19:30"]])
    }
}
