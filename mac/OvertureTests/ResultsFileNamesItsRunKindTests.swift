import Testing
import Foundation

// #3004: a finished results file says what KIND of run wrote it.
//
// It recorded `version`, `generatedAt` and `results`, and nothing about its own provenance, so a check's
// file and a Prep run's were indistinguishable once written. That is exactly the fact #2762's session 1
// got wrong, and the only thing that caught it was a person reading `prep-run.log` by eye. Since #2980
// the runner HOLDS the fact at the moment it writes the file and simply did not record it (L46, L78).
//
// The reader is the pace history. `ProbeDurationHistory`'s own header already named this gap: "at any
// moment exactly one runCost record exists on this Mac, it does not say which kind of run wrote it". The
// design worked around it by trusting the SLOT, and #2978 is what that cost: a stale prep-slot reading was
// filed as two different checks' pace for two days while the checks that really ran recorded nothing.
@Suite("A results file names its own run kind (#3004)")
struct ResultsFileNamesItsRunKindTests {
    private func results(kind: String?, slot: String? = nil, streams: Int = 3,
                         durationMs: Double = 390_000) -> Data {
        var top: [String: Any] = [
            "version": 2,
            "results": [],
            "runCost": ["recorded": true, "usd": 1.2, "durationMs": durationMs,
                        "streams": streams, "contended": false] as [String: Any],
        ]
        if let kind { top["runKind"] = kind }
        if let slot { top["runSlot"] = slot }
        return try! JSONSerialization.data(withJSONObject: top)
    }

    // MARK: the wire spelling

    // One vocabulary, not a third. The shell writes the strings `RunSlot`'s raw values already use and
    // that `docs/contracts.md` documents, and the app reads them through a named mapping rather than
    // matching literals at the point of use (L118).
    @Test func thewireSpellingIsTheOneAlreadyInUse() {
        #expect(RunKind.prep.resultsFileValue == RunSlot.prep.rawValue)
        #expect(RunKind.reachabilityCheck.resultsFileValue == RunSlot.check.rawValue)
        #expect(RunKind(resultsFileValue: "prep") == .prep)
        #expect(RunKind(resultsFileValue: "check") == .reachabilityCheck)
        #expect(RunKind(resultsFileValue: "banana") == nil)
        #expect(RunKind(resultsFileValue: "") == nil)
    }

    // MARK: reading it

    @Test func acheckSFileSaysSo() {
        #expect(RecordedRunCost.complete(from: results(kind: "check"))?.kind == .reachabilityCheck)
    }

    @Test func aprepRunSFileSaysSo() {
        #expect(RecordedRunCost.complete(from: results(kind: "prep"))?.kind == .prep)
    }

    // Absent is a THIRD state, exactly like `contended`: the runner script is resolved out of the git
    // checkout and `update-overture.sh` fast-forwards it BEFORE the rebuild, so a new app meets a script
    // that predates this stamp on every update. Reading absence as either kind would invent the fact.
    @Test func anolderRunnerSFileClaimsNoKind() {
        let cost = RecordedRunCost.complete(from: results(kind: nil))
        #expect(cost != nil, "it is still a complete cost reading")
        #expect(cost?.kind == nil)
    }

    // An unrecognised value is not a kind either, and must not be mistaken for absence being fine: it is
    // read as unknown, which is the same refusal an absent one gets from the pooling rule below.
    @Test func anunrecognisedValueIsNotAKind() {
        #expect(RecordedRunCost.complete(from: results(kind: "banana"))?.kind == nil)
    }

    // The kind is passed through, never folded into whether the COST is usable. A Prep run measures itself
    // perfectly well; whether its reading may be POOLED into the check estimate is a different question,
    // and it belongs to `ProbeRunPaceRecording` (the same split `contended` already has).
    @Test func aprepRunSCostIsStillAcompleteReading() {
        let cost = RecordedRunCost.complete(from: results(kind: "prep"))
        #expect(cost?.seconds == 390)
        #expect(cost?.streams == 3)
    }

    // MARK: refusing to learn from the wrong kind

    @Test func acheckTeachesTheEstimate() {
        let cost = RecordedRunCost.complete(from: results(kind: "check"))
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: cost, cancelled: false) != nil)
    }

    // THE point of the stamp. #2978 fixed WHICH FILE is read; this is the other half, and it holds even
    // when the file read is the right one: a check sitting in the prep slot reads the prep slot's file,
    // and what is in it may be an actual Prep run from an hour ago.
    @Test func aprepRunSReadingNeverTeachesTheCheckEstimate() {
        let cost = RecordedRunCost.complete(from: results(kind: "prep", slot: "prep"))
        #expect(cost != nil, "the reading is complete; it is the wrong kind of run")
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: cost, cancelled: false) == nil,
                "a Prep run's wall clock was filed as a check's pace")
    }

    // An unstamped file keeps today's behaviour exactly, rather than silently ending the pace learning
    // for everyone during the update window. Trusting the slot is what the app did before this and it is
    // right for a check's own file; the stamp only ever adds a way to be sure (L90).
    @Test func anunstampedReadingIsStillPooledOnTheSlotSTrust() {
        let cost = RecordedRunCost.complete(from: results(kind: nil))
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: cost, cancelled: false) != nil)
    }

    // The existing refusals are unchanged and still fire, so the new one is not carrying them.
    @Test func theolderRefusalsStillHold() {
        let stamped = RecordedRunCost.complete(from: results(kind: "check"))
        #expect(ProbeRunPaceRecording.sample(lookups: nil, cost: stamped, cancelled: false) == nil)
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: stamped, cancelled: true) == nil)
        #expect(ProbeRunPaceRecording.sample(lookups: 3, cost: nil, cancelled: false) == nil)
    }

    // MARK: the writer

    // The runner is what writes it, and the shell fixture is what drives that. This asserts the two agree
    // on the spelling, because a stamp the app cannot read is the same as no stamp at all (L26).
    @Test func therunnerWritesTheSpellingTheAppReads() {
        let runner = SourceGuardHelper.source("../mac/scripts/lib/models.sh")
        #expect(runner.contains("\"prep\", \"check\""),
                "the runner's accepted values must be the two the app maps")
        let prepRun = SourceGuardHelper.source("../mac/scripts/prep-run.sh")
        #expect(prepRun.contains("OVERTURE_RUN_KIND"))
        #expect(prepRun.contains("OVERTURE_RUN_SLOT=\"$RUN_SLOT\""),
                "the slot stamp comes from the slot the runner was given, never re-derived")
    }
}
