import Foundation

// #885: what is DUE, defined once.
//
// Two views summed this for themselves: RootView's toolbar badge (`followUpsDue`) and FollowUpsView's
// own header count. Same rule, written twice, in two bodies no test can reach. They agreed only because
// they happened to read the same stored settings, and nothing asserted that they did.
//
// The number on the pill Dan clicks and the number on the sheet he lands on must be the same number by
// construction, not by coincidence. A badge that disagrees with the list behind it is the #863 defect:
// a count is a promise about rows.
enum DueWork {
    struct Counts: Equatable, Sendable {
        var followUps: Int          // silent leads waiting on a gentle nudge
        // #2397: shows whose date has passed, waiting on a closing note or on Dan saying how it ended.
        var afterTheShow: Int

        var total: Int { followUps + afterTheShow }
    }

    static func counts(prospects: [Prospect], now: Date,
                       followUp: FollowUpConfig = .init()) -> Counts {
        Counts(followUps: FollowUp.dueRecipients(from: prospects, now: now, config: followUp).count,
               afterTheShow: PostEventPrompt.dueRecipients(from: prospects, now: now).count)
    }
}

// #885: the toolbar pill's own title. It hides its count when there is nothing due, so a zero never sits
// on the masthead pretending to be work.
extension DueWork {
    static func badgeTitle(count: Int) -> String { count == 0 ? "Due" : "Due (\(count))" }
}
