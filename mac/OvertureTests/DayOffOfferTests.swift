import Testing
import Foundation
@testable import Overture

// #924: dismissing a show for a calendar reason is the most natural moment to capture a day off. The
// pure helper decides WHETHER to offer and over WHAT range, kept out of any view so the rule is testable
// (the #863 lesson) and shared by the single-tap path and the multi-night picker.
@Suite("Dismiss-to-day-off offer (#924)")
struct DayOffOfferTests {

    @Test func offersForEachCalendarReason() {
        for reason in [DismissReason.dateConflict, .alreadyBooked] {
            let offer = DayOffOffer.offer(reason: reason, performanceDate: "2026-11-18", runEndDate: nil)
            #expect(offer != nil, "expected an offer for \(reason)")
        }
    }

    @Test func doesNotOfferForNonCalendarReasons() {
        for reason in [DismissReason.notInterested, .dontWantToShoot, .duplicate, .wentBy] {
            #expect(DayOffOffer.offer(reason: reason, performanceDate: "2026-11-18", runEndDate: nil) == nil,
                    "did not expect an offer for \(reason)")
        }
    }

    @Test func doesNotOfferWhenThereIsNoDate() {
        #expect(DayOffOffer.offer(reason: .dateConflict, performanceDate: nil, runEndDate: nil) == nil)
    }

    // A single-night show blocks just that day: start and end are the same, and it is not multi-night, so
    // the caller takes the one-tap path.
    @Test func aSingleNightShowIsOneDay() {
        let offer = DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-11-18", runEndDate: nil)
        #expect(offer?.start == "2026-11-18")
        #expect(offer?.end == "2026-11-18")
        #expect(offer?.isMultiNight == false)
    }

    // A run spans its opening night through its closing night, and is multi-night, so the caller opens the
    // date picker pre-filled with the whole run for Dan to narrow.
    @Test func aRunSpansOpeningThroughClosing() {
        let offer = DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-11-18", runEndDate: "2026-11-20")
        #expect(offer?.start == "2026-11-18")
        #expect(offer?.end == "2026-11-20")
        #expect(offer?.isMultiNight == true)
    }

    // A run whose recorded end equals its start is still a single night, not a two-day run.
    @Test func aRunEndingOnItsOpeningNightIsSingle() {
        let offer = DayOffOffer.offer(reason: .alreadyBooked, performanceDate: "2026-11-18", runEndDate: "2026-11-18")
        #expect(offer?.isMultiNight == false)
    }

    // The picker subtitle names the org it was dismissed for, so it can't drift from the show.
    @Test func thePickerSubtitleNamesTheOrg() {
        #expect(DayOffOffer.pickerSubtitle(org: "Vienna Philharmonic").contains("Vienna Philharmonic"))
    }

    // If the show's date is already blocked (it already shows a conflict), there is nothing to capture, so
    // dismissing a SECOND show on that same blocked date must not pop the picker again (Dan, 2026-07-15).
    @Test func anAlreadyBlockedDateOffersNothing() {
        #expect(DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-11-18",
                                  runEndDate: nil, alreadyBlocked: true) == nil)
    }
}
