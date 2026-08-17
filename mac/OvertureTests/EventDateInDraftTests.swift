import Testing
import Foundation

// #2864: a pitch must name the show's own date, and must never name a different one.
//
// Measured on the live store, 2026-08-17: of the 19 prospects carrying a draft body and a stored
// performanceDate, 6 name the show's date nowhere at all, and one that was SENT told The Joyce Theater
// Dan wanted to photograph a show "on July 18" when the stored date was July 25, eight days out. A
// presence-only check passes that draft, because July 18 is a date, which is why this asks whether the
// date named MATCHES rather than whether one is there.
//
// The rule was already in the runbook four times over, as an instruction to the model. A rule that lives
// only in a prompt is a hope (L27).
@Suite("The date a pitch names")
struct EventDateInDraftTests {

    // Pinned on BOTH ends, always: this rule compares a stored date against a clock, so a fixture that
    // pinned only the date would drift into a different case as real time walked past it (L130).
    private let today = "2026-03-01"

    private func finding(_ body: String, subject: String? = nil,
                         date: String? = "2026-03-10", runEnd: String? = nil,
                         today: String? = nil) -> EventDateFinding? {
        EventDateInDraft.finding(subject: subject, body: body, performanceDate: date,
                                 runEndDate: runEnd, today: today ?? self.today)
    }

    // MARK: - The accept side, which is the half that protects a good draft (L104)

    // Every rendering a good draft legitimately uses. A matcher that missed one would refuse a pitch
    // that is entirely correct, fire on the common case, and be ignored within a week (L93, L147).
    @Test(arguments: [
        "I'd love to photograph your March 10 concert.",
        "your March 10th concert",
        "the Mar 10 performance",
        "your concert on March 10, 2026",
        "your concert on 10 March",
        "the 3/10 performance",
        "the 3/10/26 performance",
        "your concert on Tuesday, March 10",
        "Your March programme, and specifically the 10th, is what I'm writing about.",
        "MARCH 10 is the night I have in mind.",
    ])
    func aDraftNamingTheShowsDatePasses(_ body: String) {
        #expect(finding(body) == nil, "\(body)")
    }

    // "Preferably the email, but as long as it's somewhere that's what matters" (Dan, 2026-08-17), so
    // the subject counts on its own.
    @Test func theDateInTheSubjectAloneIsEnough() {
        #expect(finding("Nothing dated in here at all.",
                        subject: "Photographing your March 10 concert") == nil)
    }

    // MARK: - No date at all

    @Test func aDraftNamingNoDateAtAllIsTheFinding() {
        #expect(finding("I'd love to photograph your concert. My rate is $250 an hour plus tax.")
                == .namesNoDate(show: "March 10"))
    }

    // Two of the six drafts measured carry no date-shaped words whatever, and figures that are not dates
    // must not rescue them: a rate and a delivery window are not the show's night.
    @Test func aRateAndADeliveryWindowAreNotADate() {
        #expect(finding("My rate is $250 an hour plus tax and I deliver within two weeks.")
                == .namesNoDate(show: "March 10"))
    }

    // MARK: - A date that contradicts the show, which is the half that has already cost a real pitch

    @Test func aDraftNamingADifferentDayIsTheFinding() {
        #expect(finding("I'd love to photograph your concert on March 3.")
                == .namesADifferentDate(named: "March 3", show: "March 10"))
    }

    // The measured case, in the shape it was sent. Content invented, dates real.
    @Test func theShapeOfTheDraftThatWasActuallySent() {
        #expect(finding("...the chance to photograph your company's programme at the theater on July 18, "
                        + "working quietly from the back of house.",
                        date: "2026-07-25", runEnd: "2026-07-25", today: "2026-06-01")
                == .namesADifferentDate(named: "July 18", show: "July 25"))
    }

    // A year that is stated and wrong is a contradiction, not a match on month and day.
    @Test func theRightDayInTheWrongYearContradicts() {
        #expect(finding("your concert on March 10, 2025")
                == .namesADifferentDate(named: "March 10, 2025", show: "March 10"))
    }

    // MARK: - Multi-night runs (#1122)

    // A run reference need not carry the opening night at all: any night inside the run counts.
    @Test func anyNightInsideTheRunCounts() {
        #expect(finding("your run at BAM, March 12", date: "2026-03-10", runEnd: "2026-03-14") == nil)
    }

    @Test(arguments: ["your run March 10 to 14", "March 10-14", "March 10 through 14",
                      "the March 10 to March 14 run"])
    func aRunNamedBySpanCounts(_ body: String) {
        #expect(finding(body, date: "2026-03-10", runEnd: "2026-03-14") == nil, "\(body)")
    }

    // The span's FAR END is what carries this one: the opening night has gone, so "March 10 to 14" is only
    // acceptable through the nights BETWEEN its two numbers. Without this case the span expansion was
    // never needed by any test, and deleting it SURVIVED the suite (L159: a negative asserted in a
    // fixture where the positive could not happen).
    @Test func aSpanCountsThroughItsMiddleWhenTheOpeningNightHasGone() {
        #expect(finding("your run March 10 to 14", date: "2026-03-10", runEnd: "2026-03-14",
                        today: "2026-03-12") == nil)
    }

    @Test func aSpanThatEndsBeforeTheRunBeginsStillContradicts() {
        #expect(finding("your run March 10 to 14", date: "2026-03-20", runEnd: "2026-03-24")
                == .namesADifferentDate(named: "March 10 to 14", show: "March 20 to 24"))
    }

    @Test func aDateOutsideTheRunStillContradicts() {
        #expect(finding("your run at BAM, March 20", date: "2026-03-10", runEnd: "2026-03-14")
                == .namesADifferentDate(named: "March 20", show: "March 10 to 14"))
    }

    // The runbook FORBIDS naming an opening night that has gone (line 899): writing "your March 10
    // opening" after the 10th reads as not having looked. So a check that accepted the opening night
    // would pass a draft the runbook itself says is wrong.
    @Test func aPassedOpeningNightDoesNotCountOnceTheRunHasOpened() {
        #expect(finding("your March 10 opening", date: "2026-03-10", runEnd: "2026-03-14",
                        today: "2026-03-12")
                == .namesADifferentDate(named: "March 10", show: "March 12 to 14"))
    }

    @Test func aStillUpcomingNightOfAnOpenedRunCounts() {
        #expect(finding("your March 13 performance", date: "2026-03-10", runEnd: "2026-03-14",
                        today: "2026-03-12") == nil)
    }

    // A run entirely in the past has no upcoming night to prefer, so every night of it counts again.
    // Without this the check would contradict every correct draft on a show that has already happened,
    // which is the state a sent pitch is read back in.
    @Test func awholyPastRunAcceptsAnyOfItsOwnNights() {
        #expect(finding("your March 10 concert", date: "2026-03-10", runEnd: "2026-03-14",
                        today: "2026-04-01") == nil)
    }

    // MARK: - Nothing to check against

    @Test func aShowWithNoStoredDateIsNotJudged() {
        #expect(finding("Anything at all.", date: nil) == nil)
    }

    // MARK: - What Dan is told

    // "Make it clear why it's warning me in the message" (Dan, 2026-08-17). An override is only
    // meaningful if the person overriding can see what they are overriding, so the sentence carries
    // BOTH dates rather than saying "check the date".
    @Test func theContradictionMessageCarriesBothDates() {
        let message = EventDateFinding.namesADifferentDate(named: "July 18", show: "July 25").message
        #expect(message.contains("July 18"))
        #expect(message.contains("July 25"))
    }

    @Test func theMissingDateMessageSaysWhereItLooked() {
        let message = EventDateFinding.namesNoDate(show: "March 10").message
        #expect(message.contains("March 10"))
        #expect(message.lowercased().contains("subject"))
    }

    // MARK: - The wire, which is a separate claim from the rule

    // Every test above drives the rule directly, so all of them stay green if the review screen stops
    // rendering it. That wiring lives in a SwiftUI body where no test can reach it (#885), and the first
    // version of it went unguarded: deleting the call SURVIVED the whole suite (L3). A source guard holds
    // it, scoped to the one function so a legitimate mention elsewhere in this large file cannot answer
    // for it (L135).
    @Test func theDraftReviewScreenRendersTheDateWarning() throws {
        let source = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        guard let body = SourceGuardHelper.propertyBody("@ViewBuilder private var draftCheckFlags: some View {",
                                                        in: source) else {
            Issue.record("draftCheckFlags not found in DraftReviewView")
            return
        }
        #expect(body.contains("item.eventDateWarning()"))

        // And OUTSIDE the voice suppression, which is the whole point: a contradicted date must show on a
        // draft Dan has edited. Positional, because that is what "outside the gate" means in this file:
        // the warning has to be rendered before the suppression is consulted.
        guard let warning = body.range(of: "item.eventDateWarning()"),
              let suppression = body.range(of: "DraftReviewNotes.showsVoiceFindings(") else {
            Issue.record("expected both the date warning and the voice suppression in draftCheckFlags")
            return
        }
        #expect(warning.lowerBound < suppression.lowerBound)
    }
}
