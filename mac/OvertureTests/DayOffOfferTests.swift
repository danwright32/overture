import Testing
import Foundation

// #924: dismissing a show for a calendar reason is the most natural moment to capture a day off. The
// pure helper decides WHETHER to offer and over WHAT range, kept out of any view so the rule is testable
// (the #863 lesson) and shared by the single-tap path and the multi-night picker.
//
// #2373 (Dan's call, 2026-08-09) settled the range: it is ALWAYS the one night that was dismissed. The
// widening this file used to assert (the whole run, #924, and every linked date in the engagement, #939)
// is deliberately gone, because the sheet's default button blocked whatever it proposed and a screening
// series proposed 46 days for one night Dan could not shoot.
@Suite("Dismiss-to-day-off offer (#924)")
struct DayOffOfferTests {

    @Test func offersForEachCalendarReason() {
        for reason in [ShowOutcome.dateConflict, .hadPaidWork] {
            let offer = DayOffOffer.offer(reason: reason, performanceDate: "2026-11-18")
            #expect(offer != nil, "expected an offer for \(reason)")
        }
    }

    @Test func doesNotOfferForNonCalendarReasons() {
        // #1128: "Too soon" means Dan is FREE, there just wasn't time to reach out, so it captures no day off.
        for reason in [ShowOutcome.notAFit, .dontWantToShoot, .duplicate, .wentBy, .tooSoon] {
            #expect(DayOffOffer.offer(reason: reason, performanceDate: "2026-11-18") == nil,
                    "did not expect an offer for \(reason)")
        }
    }

    @Test func doesNotOfferWhenThereIsNoDate() {
        #expect(DayOffOffer.offer(reason: .dateConflict, performanceDate: nil) == nil)
    }

    // A single-night show blocks just that day.
    @Test func aSingleNightShowIsOneDay() {
        let offer = DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-11-18")
        #expect(offer?.start == "2026-11-18")
        #expect(offer?.end == "2026-11-18")
    }

    // #2373: the case this came from. NT Live: Inter Alia (Encore) was dismissed for 8/15 while its run
    // ran to 9/29, and the sheet opened on the whole 46 day span with Block as the default button. One
    // night dismissed means one night proposed, however long the run around it is.
    @Test func aRunEndingWeeksLaterStillProposesOnlyTheDismissedNight() {
        let offer = DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-08-15")
        #expect(offer?.start == "2026-08-15")
        #expect(offer?.end == "2026-08-15")
    }

    // The picker subtitle names the org it was dismissed for, so it can't drift from the show.
    @Test func thePickerSubtitleNamesTheOrg() {
        #expect(DayOffOffer.pickerSubtitle(org: "Vienna Philharmonic").contains("Vienna Philharmonic"))
    }

    // If the show's date is already blocked (it already shows a conflict), there is nothing to capture, so
    // dismissing a SECOND show on that same blocked date must not pop the picker again (Dan, 2026-07-15).
    @Test func anAlreadyBlockedDateOffersNothing() {
        #expect(DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-11-18",
                                  alreadyBlocked: true) == nil)
    }
}

// #2373: the widening is gone from the RULE (the signature above no longer accepts either input, which
// the compiler enforces), so the sweep that existed only to feed it must go from the call site too.
// Leaving it would keep paying for a value nothing reads (L46), which no behavioural test can see.
@Suite("The day-off offer takes no range beyond the dismissed night (#2373)")
struct DayOffOfferHasNoWideningInputsTests {
    private var mutationsSource: String { SourceGuardHelper.source("Overture/UI/ProspectMutations.swift") }

    @Test func theDismissPathNoLongerSweepsTheEngagementToBuildAnOffer() {
        #expect(!mutationsSource.isEmpty)
        // The sweep existed only to build `linkedDates`. Its other readers live elsewhere, so a mention
        // of EngagementLink inside the dismiss path is the sweep coming back.
        #expect(!mutationsSource.contains("EngagementLink.group"))
    }
}
