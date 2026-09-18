import Testing
import Foundation

// #3672 and #3686, done together because they are one cold read of one surface.
//
// Both are the self-booking copy saying something imprecise, both change `SelfBookingCopy`, and AGENTS.md
// requires the new and changed sentences to be read cold in the order a person meets them on screen. Two
// pull requests would mean two partial cold reads of a surface whose whole problem is what it says when
// the pieces are composed (L605).
//
// **#3672, the header does not name the night.** "Another pitch is already in progress on a night one of
// these runs plays" is deliberately vague rather than wrong: the clash may be on a later night of a run
// filed under this header, and saying "on this date" there would assert a date nothing measured, which is
// #1501's defect. Dan read it under a `FRI Sep 25` header on 2026-09-07 and could not tell whether the
// clash was Sep 25 or a later night, and asked. The night is already known where the sentence is composed.
//
// **#3686, the row marker uses one verb for every tier.** `rowMarker` says "Also pitching X" whatever the
// other show's commitment is, so on a night holding a BOOKED shoot it claims somebody is pitching a show
// that is already booked. Dan raised it himself on #3676 and his settlement that day covered the header
// only.
//
// THE RULE FOR BOTH, and it is one rule: the strongest commitment on the night decides the wording, and
// only the shows AT that tier are described by it. That is what `headerClaim` already does
// (`SelfBookingConflict.swift:217-223`), so the row marker joins it rather than inventing a second way to
// answer the same question (L261, L342). A night holding a booked shoot and a sent pitch speaks as booked.
@Suite("The self-booking copy names the night and the right tier (#3672, #3686)")
struct SelfBookingCopyNamesTheNightAndTheTierTests {

    // MARK: - #3672: the header names the night when it can

    @Test("A clash on one named night is named, rather than called a night of the run")
    func theHeaderNamesASingleClashNight() {
        let claim = SelfBookingConflict.HeaderClaim(commitment: .emailed,
                                                    allOnThisDate: false,
                                                    night: "2026-10-02")
        #expect(SelfBookingCopy.dateHeaderNote(claim) == "Another pitch is already in progress on Oct 2",
                Comment(rawValue:
                    "The header still refuses to say which night it found the clash on, though the night "
                    + "was known where the sentence was composed. Dan had to go hunting for it."))
    }

    @Test("A booked clash on one named night says shooting, not pitching")
    func theHeaderNamesTheNightForABookedClash() {
        let claim = SelfBookingConflict.HeaderClaim(commitment: .booked,
                                                    allOnThisDate: false,
                                                    night: "2026-10-02")
        #expect(SelfBookingCopy.dateHeaderNote(claim)
                == "You are already shooting another show on Oct 2")
    }

    @Test("Clashes on SEVERAL nights keep the vague wording, because naming one would claim it is the whole story")
    func severalNightsAreNotNarrowedToOne() {
        // This is the honest case and the reason the vague sentence exists at all. A group whose rows clash
        // on two different nights may not present either as the answer (L11): the check measured two.
        let claim = SelfBookingConflict.HeaderClaim(commitment: .emailed,
                                                    allOnThisDate: false,
                                                    night: nil)
        #expect(SelfBookingCopy.dateHeaderNote(claim)
                == "Another pitch is already in progress on a night one of these runs plays")
    }

    @Test("A clash on the header's own date is unchanged")
    func theOnThisDateWordingIsUntouched() {
        let claim = SelfBookingConflict.HeaderClaim(commitment: .emailed,
                                                    allOnThisDate: true,
                                                    night: "2026-09-25")
        #expect(SelfBookingCopy.dateHeaderNote(claim) == "Another pitch is already in progress on this date")
    }

    @Test("A prepped-only night still says nothing at the header")
    func preppedStaysSilentAtTheHeader() {
        // #3676, Dan 2026-09-07: "Prepping is not committing to pitching." Unchanged by this work, and
        // asserted so that adding a night to the claim cannot quietly give prepped a sentence.
        let claim = SelfBookingConflict.HeaderClaim(commitment: .prepped,
                                                    allOnThisDate: false,
                                                    night: "2026-10-02")
        #expect(SelfBookingCopy.dateHeaderNote(claim) == nil)
    }

    // MARK: - #3686: the row marker uses the tier's own verb

    @Test("A booked show on the night is not described as being pitched")
    func theRowMarkerDoesNotCallABookedShowAPitch() {
        let marker = SelfBookingCopy.rowMarker(["Ravel and Ives"],
                                               clashNight: nil,
                                               performanceDate: nil,
                                               commitment: .booked)
        #expect(marker == "Already shooting Ravel and Ives on this date", Comment(rawValue:
            "The row marker still says somebody is pitching a show that is already booked, which is the "
            + "half of #3676 that Dan's settlement that day did not cover."))
    }

    @Test("A sent pitch on the night still reads as a pitch")
    func theRowMarkerKeepsThePitchWordingForASentPitch() {
        let marker = SelfBookingCopy.rowMarker(["Ravel and Ives"],
                                               clashNight: nil,
                                               performanceDate: nil,
                                               commitment: .emailed)
        #expect(marker == "Also pitching Ravel and Ives on this date")
    }

    @Test("A prepped show on the night still reads as a pitch, which is Dan's own settlement")
    func preppedKeepsThePitchWordingOnTheRow() {
        // Deliberately NOT nil, unlike the header. Dan pointed at "Also pitching X on this date" as the
        // thing that already covers a prepped show and said it does (#3686's own write-up). The row and
        // the header differ here on purpose, and this test is what stops somebody "consolidating" them.
        let marker = SelfBookingCopy.rowMarker(["Ravel and Ives"],
                                               clashNight: nil,
                                               performanceDate: nil,
                                               commitment: .prepped)
        #expect(marker == "Also pitching Ravel and Ives on this date")
    }

    @Test("A booked clash on a later night names that night with the booked verb")
    func theBookedVerbSurvivesTheLaterNightBranch() {
        // The tier and the night are two independent branches in one sentence, so each combination has to
        // be exercised: a fix that only reached the "on this date" arm would leave the later-night arm
        // still claiming a booked show is being pitched (L517).
        let marker = SelfBookingCopy.rowMarker(["Ravel and Ives"],
                                               clashNight: "2026-10-29",
                                               performanceDate: "2026-10-02",
                                               commitment: .booked)
        #expect(marker == "Already shooting Ravel and Ives on Oct 29")
    }

    @Test("A booked clash on an unnameable later night still uses the booked verb")
    func theBookedVerbSurvivesTheUnnamedBranch() {
        let marker = SelfBookingCopy.rowMarker(["Ravel and Ives"],
                                               clashNight: nil,
                                               performanceDate: "2026-10-02",
                                               commitment: .booked)
        #expect(marker == "Already shooting Ravel and Ives on a later night of this run")
    }

    @Test("No names still means no marker, whatever the tier")
    func noNamesMeansNoMarker() {
        for commitment in [SelfBookingConflict.Show.Commitment.booked, .emailed, .prepped] {
            #expect(SelfBookingCopy.rowMarker([], clashNight: nil, performanceDate: nil,
                                              commitment: commitment) == nil,
                    Comment(rawValue: "An empty name list produced a marker for \(commitment)."))
        }
    }
}
