import Testing
import Foundation

// #1837: ten unanswered pitches must not look as urgent as one person waiting on Dan.
//
// `AgentRoster.followUps` returned `.needsAttention` whenever `followUpsDue > 0`, so the pill's tone said
// only "there is something here". Dan, 2026-08-18: "one number, change pill color if any of that count is
// someone waiting on a reply. make it look more urgent in that case. 0 and 10 due can look exactly the
// same if the 10 are all pitches that nobody answered."
//
// This is a RESTRICTION on a tone the pill already had, not a new colour, which is worth stating because
// the first reading of it was as an addition. The NUMBER is unchanged in both branches and is still the
// whole total; only the tone narrowed, and only to `conversationsToConfirm`.
@Suite("The Follow-ups pill escalates only for someone waiting (#1837)")
struct FollowUpsPillToneTests {

    private func inputs(followUpsDue: Int, conversationsToConfirm: Int = 0,
                        stalledReplyDrafts: Int = 0) -> AgentInputs {
        AgentInputs(toTriage: 0, keptToPrep: 0, toReview: 0, readyToSend: 0, gmailConnected: true,
                    sendErrors: 0, followUpsDue: followUpsDue,
                    conversationsToConfirm: conversationsToConfirm,
                    stalledReplyDrafts: stalledReplyDrafts)
    }

    private func pill(_ i: AgentInputs) -> AgentStatus {
        AgentRoster.statuses(i).first { $0.focus == .followUps }!
    }

    // Dan's own example, and BOTH halves are in one fixture on purpose. A test that something did NOT
    // light up is satisfied by a fixture in which it could not have (L159), so the escalating case has to
    // be shown firing over the same shape.
    @Test func tenUnansweredPitchesRestAndOneWaitingReplyEscalates() {
        let quiet = pill(inputs(followUpsDue: 10))
        #expect(quiet.state == .idle, "ten pitches nobody answered is work owed, not an alarm")

        let waiting = pill(inputs(followUpsDue: 10, conversationsToConfirm: 1))
        #expect(waiting.state == .needsAttention, "one possible reply to check is somebody waiting on him")
    }

    // The number is the WHOLE total in both branches, which is the "keep ONE number" half of his answer.
    // A tone that also changed the number would make the two branches count different things (L16).
    @Test func theNumberIsTheWholeTotalWhicheverToneItWears() {
        #expect(pill(inputs(followUpsDue: 10)).count == 10)
        #expect(pill(inputs(followUpsDue: 10, conversationsToConfirm: 1)).count == 10)
        #expect(pill(inputs(followUpsDue: 10)).detail == "10 due")
        #expect(pill(inputs(followUpsDue: 10, conversationsToConfirm: 1)).detail.hasPrefix("10 due"))
    }

    // The escalated state is distinguishable WITHOUT colour. That matters more after this change rather
    // than less: the tone now carries a specific meaning, and a meaning carried only by hue is
    // unavailable to anyone who cannot separate the two (L20). The chip's spoken label is its texts
    // concatenated, so the detail differing is also what says which state it is to a screen reader.
    @Test func theTwoStatesReadDifferentlyWithNoColourAtAll() {
        let quiet = pill(inputs(followUpsDue: 3)).detail
        let waiting = pill(inputs(followUpsDue: 3, conversationsToConfirm: 2)).detail
        #expect(quiet != waiting)
        #expect(waiting.contains("somebody may have answered"))
        // And it must not be the concept sentence's own words said twice: the hover shows the concept
        // directly above this line, so a phrase lifted from it says nothing the reader has not just read
        // (#843). "a possible reply to check" was the second draft and is exactly that phrase.
        let concept = AgentRoster.chipHelp(focus: .followUps, detail: waiting)
        #expect(concept.contains("a possible reply to check"),
                "the concept sentence still lists it, which is why the detail may not repeat the phrase")
        #expect(!waiting.contains("a possible reply to check"))
    }

    // And the resting pill still SHOWS that detail, which a resting pill normally does not. Without this
    // the number would have disappeared the moment the tone was narrowed, which is the opposite of what
    // he asked for.
    @Test func theRestingPillStillStatesItsNumber() {
        #expect(AgentRoster.showsDetailWhileResting(focus: .followUps))
        #expect(AgentRoster.showsDetailWhileResting(focus: .reachedOut))
        #expect(AgentRoster.showsDetailWhileResting(focus: .scout) == false,
                "an ordinary pill still hides its resting detail; this is an exception, not the rule")
    }

    // And the VIEW asks that rule rather than keeping its own list.
    //
    // Added because `scripts/mutate.sh` refused a mutation of the view with SCOPE MISSED THE FILE: the
    // rule above was defined, tested, and nothing anywhere asserted the chip consulted it, so swapping the
    // call site back for a bare `s.focus == .reachedOut` would have taken the number off the pill with
    // every test still green. That is the #3069 shape (a wiring nothing checks) and it was one mutation
    // away from shipping in a change whose whole point is that the number stays.
    @Test func theChipAsksThatRuleRatherThanHoldingItsOwnList() throws {
        let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        let chip = try #require(SourceGuardHelper.bodyOfFunction(named: "agentChip", in: queueView))
        #expect(chip.contains("AgentRoster.showsDetailWhileResting(focus: s.focus)"),
                "the chip must consult the rule, or a resting Follow-ups pill states no number")
    }

    // A stalled reply-drafter run is a FAULT state rather than work owed, so it keeps its attention tone
    // whatever the rest of the sheet holds. Dan's answer names this explicitly.
    @Test func aStalledReplyDraftKeepsItsAttentionTone() {
        let stalled = pill(inputs(followUpsDue: 4, stalledReplyDrafts: 1))
        #expect(stalled.state == .needsAttention)
        #expect(stalled.detail == "1 reply draft stalled")
        #expect(stalled.count == 4, "#3076: the count is still the whole sheet behind the pill")
    }

    // Nothing due is still nothing due, and it still says so.
    @Test func anEmptySheetIsUnchanged() {
        let empty = pill(inputs(followUpsDue: 0))
        #expect(empty.state == .idle)
        #expect(empty.detail == "None due")
        #expect(empty.count == 0)
    }
}
