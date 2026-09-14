import Testing
import Foundation

// #2374. A Scout date heading reads "Reachability checked" whenever every show on it has an answer, and
// says the same three words for a night answered yesterday and one answered 89 days ago. The individual
// cards do carry their own staleness line; the heading does not, so Dan scanning headings cannot see
// which nights are living on old answers.
//
// Dan's call, 2026-09-06, on being shown the measurement: add the DATE, and nothing else. Of 771 future
// shows in the live store that day, 670 had never been checked, 100 were checked inside 30 days, one sat
// between 30 and 59, and ZERO were in the 60 to 89 band. So the state a louder warning would serve does
// not exist yet, and a date is the whole fix. That also keeps the marker as quiet as #1595 and #1617
// deliberately made it.
@MainActor
@Suite("The checked-date heading says when (#2374)")
struct CheckedDateHeadingTests {

    private let older = Date(timeIntervalSince1970: 1_780_000_000)
    private var newer: Date { older.addingTimeInterval(60 * 60 * 24 * 9) }
    private var now: Date { newer.addingTimeInterval(60 * 60 * 24) }
    private let today = "2026-09-01"

    private func item(_ key: String, probedAt: Date?, sentAt: Date? = nil) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "theater", venue: "Under St Marks",
                          performanceDate: "2026-09-12", sourceListingURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.reachabilityProbedAt = probedAt
        i.sentAt = sentAt
        return i
    }

    private func label(_ d: Date) -> String {
        EasternDate.dayLabel(EasternDate.dayString(from: d)) ?? ""
    }

    // The OLDEST answer on the night, deliberately, and this is the decision worth understanding.
    //
    // A heading covers several shows and they can be answered on different days, so "which date" is a
    // real question. The oldest is the one closest to the 90 day expiry, which is the thing this exists
    // to make visible, and it can never overstate how fresh the night is: "checked Nov 2" then means
    // nothing here is older than that, whatever the spread.
    @Test func theHeadingNamesTheOldestAnswerOnTheNight() {
        let night = [item("a", probedAt: newer), item("b", probedAt: older)]
        #expect(QueueModel.dateReachabilityIsFullyChecked(night, now: now, today: today))

        let text = ReachabilityProbeCopy.dateCheckedMarker(
            checkedOn: QueueModel.dateReachabilityCheckedOn(night, now: now, today: today))

        #expect(text.hasPrefix("Reachability checked"), "the sentence Dan already knows must not change")
        #expect(text.contains(label(older)),
                "the heading named a fresher answer than the night's oldest, so it overstates the night")
        #expect(!text.contains(label(newer)))
    }

    // A night the heading is NOT claiming about must not set its date. A show already sent to is closed
    // for decision, so `probeIsWorthOffering` excludes it and the heading says nothing about it; letting
    // its much older answer set the date would date the heading from a row it does not cover (L287: a
    // notice computed over a wider scope than the surface it sits on reads as a false claim about it).
    @Test func aShowTheHeadingDoesNotCoverCannotSetItsDate() {
        let ancient = older.addingTimeInterval(-60 * 60 * 24 * 300)
        let night = [item("a", probedAt: newer),
                     item("closed", probedAt: ancient, sentAt: now)]

        let text = ReachabilityProbeCopy.dateCheckedMarker(
            checkedOn: QueueModel.dateReachabilityCheckedOn(night, now: now, today: today))

        #expect(!text.contains(label(ancient)),
                "the heading took its date from a show it makes no claim about")
        #expect(text.contains(label(newer)))
    }

    // Nothing to say is its own answer. A night whose shows carry no readable answer keeps EXACTLY the
    // sentence the marker has always shown, so this change can never turn a working marker into a broken
    // one, and the copy inventory keeps that entry unchanged (L98, L138).
    @Test func aNightWithNoReadableAnswerKeepsTheSentenceItAlreadyHad() {
        #expect(ReachabilityProbeCopy.dateCheckedMarker(checkedOn: nil) == "Reachability checked")
    }
}
