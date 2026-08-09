import Testing

// #1765: a large reachability selection RUNS. It is not refused.
//
// Dan picked 19 dates (77 shows) and was told: "That is 77 lookups, the better part of an hour. Overture stops at 40
// in one run so a whole week cannot go on one click. Select fewer dates and run them in batches." His call:
// "I should never be blocked by what I'm trying to do. If I want to do this, let me."
//
// Nothing downstream breaks at 41. `mac/scripts/prep-run.sh` already splits the work-list into up to ten
// chunks and works each chunk sequentially, so 77 lookups run as roughly 8 rounds, which IS the wait
// the bar quoted. The refusal was telling him to do by hand, in two clicks, the batching the runner already
// does for him (L54).
//
// The brake also punished only the person who meant it. A deliberate 19-date selection and a fat-fingered
// week are identical to the code, so the ceiling could never tell them apart, while the bar states the size
// and the wait before anything is spent and the confirm sheet is where an accident gets caught.
@Suite("A large reachability selection is runnable (#1765)")
struct ProbeSelectionRunnableTests {

    private func show(_ key: String, _ presenter: String?, _ venue: String) -> ProbeBatch.Show {
        ProbeBatch.Show(key: key, presenter: presenter, venue: venue)
    }

    private func oneOffs(_ n: Int) -> [ProbeBatch.Show] {
        (0..<n).map { show("k\($0)", "Solo Co \($0)", "Room \($0)") }
    }

    private func summary(dates: Int, shows: [ProbeBatch.Show]) -> ProbeSelection.Summary {
        ProbeSelection.summarize(dateCount: dates, candidates: shows, alreadyAnswered: 0, among: shows)
    }

    // Dan's actual selection: 19 dates, 77 one-off shows, so 77 lookups. It must reach the confirm.
    @Test func theSelectionDanWasRefusedNowReachesTheConfirm() throws {
        let s = summary(dates: 19, shows: oneOffs(77))
        #expect(s.researchCount == 77)
        guard case .confirm(let title, let message) = ProbeSelection.outcome(for: s) else {
            Issue.record("a 77-lookup selection must be runnable, not refused")
            return
        }
        #expect(title.contains("77 shows"))
        #expect(message.contains("77 lookups"))
    }

    // The old ceiling sat at 40, so 41 is the first size that was refused and the one most worth pinning.
    @Test func oneLookupPastTheOldCeilingIsRunnable() {
        if case .confirm = ProbeSelection.outcome(for: summary(dates: 7, shows: oneOffs(41))) {} else {
            Issue.record("41 lookups must be runnable")
        }
    }

    // A whole week of one-offs, the case the brake was built for, is a decision Dan is allowed to make.
    @Test func aWholeWeekOfOneOffsIsAllowed() {
        if case .confirm = ProbeSelection.outcome(for: summary(dates: 7, shows: oneOffs(120))) {} else {
            Issue.record("a week of one-offs must be runnable")
        }
    }

    // FAILURE PATH, and the reason removing the ceiling cannot quietly change what Dan is promised. The
    // wait is the number of ROUNDS, because lookups run ten at a time. 77 lookups is 8 rounds. Estimated
    // as the SUM it would be several times that, and he would never run it. This is the shape of number the
    // removed refusal used to quote, so it has to keep meaning the same thing without it.
    //
    // #1616: this summary is priced at the hand-set fallback (no history is injected), so the minute count
    // below is that constant's, and a change to it is meant to show up here in the words Dan would read.
    @Test func aMultiRoundSelectionIsPromisedTheRoundsNotTheSum() throws {
        let s = summary(dates: 19, shows: oneOffs(77))
        // 8 rounds of ten, not 77 lookups end to end.
        #expect(s.estimatedSeconds == ProbeSelection.fallbackSecondsPerRound * 8)
        let line = ProbeSelectionCopy.costLine(s)
        #expect(line.contains("about 52 minutes"))
        #expect(!line.contains("hour"))
        guard case .confirm(_, let message) = ProbeSelection.outcome(for: s) else {
            Issue.record("expected a runnable selection")
            return
        }
        // And the sheet Dan approves quotes the SAME wait the bar showed him while he was choosing.
        #expect(message.contains(line))
    }

    // A long run says what it BLOCKS, which is the one cost neither the title nor the minute figure
    // carries: a check holds the same single run slot a Prep run does, so for the whole run Dan cannot start
    // either. Modelled on ScoutReadBudget, whose ask states the wait and what the alternative leaves
    // behind and repeats nothing already on screen beside it.
    @Test func aLongRunSaysWhatItBlocks() throws {
        guard case .confirm(_, let message) = ProbeSelection.outcome(for: summary(dates: 19, shows: oneOffs(77)))
        else { Issue.record("expected a runnable selection"); return }
        #expect(message.contains("No Prep run or other check can start until it finishes."))
        // And it lands beside the wait it qualifies, not after the producer breakdown.
        let waitAt = try #require(message.range(of: "about 52 minutes"))
        let blocksAt = try #require(message.range(of: "No Prep run"))
        let huntAt = try #require(message.range(of: "one-off hunt"))
        #expect(waitAt.lowerBound < blocksAt.lowerBound)
        #expect(blocksAt.lowerBound < huntAt.lowerBound)
    }

    // A check that fits in one round does NOT get that sentence. Losing the slot for one round is not
    // worth a line, and one that appears on every confirm is one Dan stops reading (L36).
    @Test func aSingleRoundRunDoesNotMentionWhatItBlocks() throws {
        guard case .confirm(_, let message) = ProbeSelection.outcome(for: summary(dates: 1, shows: oneOffs(4)))
        else { Issue.record("expected a runnable selection"); return }
        #expect(!message.contains("No Prep run"))
    }

    // An empty selection still does nothing, so removing the ceiling did not turn the button into one that
    // starts a run over no shows.
    @Test func anEmptySelectionStillDoesNothing() {
        let s = ProbeSelection.summarize(dateCount: 0, candidates: [], alreadyAnswered: 0, among: [])
        #expect(ProbeSelection.outcome(for: s) == .nothing)
    }
}
