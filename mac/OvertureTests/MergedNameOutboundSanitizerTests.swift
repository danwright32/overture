import Testing
import Foundation
@testable import Overture

// #1260 Phase 1: a merged same-date+venue prospect (SameDateVenueMerge, #1236/#1259) carries a
// conductor-LIST groupName ("We Sing Noel; Craig Courtney; The Four Freedoms"). That is right on
// screen but wrong in an outbound email under Dan's name, and the follow-up / reminder nudge paths
// interpolate groupName verbatim with NO edit surface (unlike the AI-drafted pitch). These assert the
// merged list never reaches a recipient: every nudge substitutes a neutral phrase, while an ordinary
// single-title name is untouched. If either goes red, an ugly conductor list is going out to a stranger.
@Suite("Merged-name outbound sanitizer (#1260 Phase 1)")
struct MergedNameOutboundSanitizerTests {
    // The exact shape SameDateVenueMerge.combinedName produces (joined with "; ").
    private let merged = SameDateVenueMerge.combinedName(
        from: ["We Sing Noel", "Craig Courtney", "The Four Freedoms"])
    private let single = "Aurora Strings"

    @Test func sanitizerReplacesAMergedListButLeavesASingleTitleAlone() {
        #expect(FollowUp.safeDisplayName(merged) == FollowUp.mergedNameSubstitute)
        #expect(FollowUp.safeDisplayName(single) == single)
    }

    @Test func followUpSubjectNeverCarriesTheConductorList() {
        let s = FollowUp.nudgeSubject(groupName: merged)
        #expect(!s.contains(merged))
        #expect(s.contains(FollowUp.mergedNameSubstitute))
        // A normal name still rides through unchanged.
        #expect(FollowUp.nudgeSubject(groupName: single).contains(single))
    }

    @Test func followUpBodyNeverCarriesTheConductorList() {
        for attempt in [1, FollowUpConfig().maxFollowUps] {
            let b = FollowUp.nudgeBody(contactName: "Sam", groupName: merged,
                                       venue: "Carnegie Hall", attempt: attempt)
            #expect(!b.contains(merged))
            #expect(b.contains(FollowUp.mergedNameSubstitute))
        }
        #expect(FollowUp.nudgeBody(contactName: "Sam", groupName: single,
                                   venue: "Carnegie Hall", attempt: 1).contains(single))
    }

    @Test func conversationReminderBodiesNeverCarryTheConductorList() {
        for state in [ConversationState.interested, .wantsToBook, .hasQuestion] {
            let b = ConversationReminder.nudgeBody(for: state, contactName: "Sam",
                                                   groupName: merged, venue: "Carnegie Hall")
            #expect(!b.contains(merged))
            #expect(b.contains(FollowUp.mergedNameSubstitute))
        }
        let closing = ConversationReminder.closingNudgeBody(contactName: "Sam",
                                                            groupName: merged, venue: "Carnegie Hall")
        #expect(!closing.contains(merged))
        #expect(closing.contains(FollowUp.mergedNameSubstitute))
        // A normal name is untouched on the reminder path too.
        #expect(ConversationReminder.nudgeBody(for: .interested, contactName: "Sam",
                                               groupName: single, venue: "Carnegie Hall").contains(single))
    }
}
