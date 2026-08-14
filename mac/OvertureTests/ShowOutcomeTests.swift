import Testing
import Foundation

// #2394, phase 1 of docs/plans/2026-08-09-one-outcome-vocabulary.md.
//
// Overture had seven separate lists a disposition could be picked from, holding about 28 options for
// roughly a dozen facts. This is the ONE vocabulary that replaces them: twelve values Dan can pick,
// plus two Overture writes for itself and never offers.
//
// The three defects the old spread caused are what most of these tests exist to make impossible, so
// each one is asserted as a property of the vocabulary rather than left to a reviewer's eye:
// two names for one stored value (#2388), one word meaning two opposite things ("booked"), and an
// option offered on a show it cannot possibly apply to.
@Suite("ShowOutcome, the one outcome vocabulary (#2394)")
struct ShowOutcomeTests {

    // MARK: the shape of the vocabulary

    @Test func danCanChooseExactlyThirteenValues() {
        #expect(ShowOutcome.danCanChoose.count == 13)
    }

    // The order is a property of the vocabulary rather than something each view re-decides, so it is
    // pinned here in the order Dan meets it on the menu. #2684 put `noWayToReachThem` beside the other
    // reasons and kept `duplicate` last, since that one is housekeeping rather than a reason at all.
    @Test func eightEndingsForAShowNothingWasSentTo() {
        #expect(ShowOutcome.neverPitched == [.dateConflict, .hadPaidWork, .pitchingOtherShows,
                                             .tooSoon, .notAFit, .dontWantToShoot,
                                             .noWayToReachThem, .duplicate])
    }

    @Test func fiveEndingsForAShowThatWasPitched() {
        #expect(ShowOutcome.pitched == [.booked, .neverHeardBack, .theySaidNotNow,
                                        .theySaidNo, .turnedThemDown])
    }

    // The two halves must not overlap. An overlap is how an impossible option reaches the screen:
    // "Never heard back" on a show nobody emailed, or "Date conflict" on one already pitched.
    @Test func theTwoHalvesShareNoValue() {
        let overlap = Set(ShowOutcome.neverPitched).intersection(Set(ShowOutcome.pitched))
        #expect(overlap.isEmpty)
    }

    // Every pickable value must be reachable from one of the two menus, and neither menu may offer a
    // value Overture writes for itself. Without this a value can be added to the enum and silently
    // never appear anywhere, or `wentBy` can leak into a menu as a choice Dan cannot actually make.
    @Test func thetwoMenusTogetherAreExactlyWhatDanCanChoose() {
        #expect(Set(ShowOutcome.neverPitched + ShowOutcome.pitched) == Set(ShowOutcome.danCanChoose))
    }

    @Test func overtureWritesWentByAndTooFarItselfAndNeverOffersThem() {
        #expect(ShowOutcome.wentBy.isOverturesOwn)
        #expect(ShowOutcome.tooFar.isOverturesOwn)
        #expect(!ShowOutcome.danCanChoose.contains(.wentBy))
        #expect(!ShowOutcome.danCanChoose.contains(.tooFar))
        // And the automatic pair is the ONLY thing held back, so a value cannot go missing from the
        // menus by being quietly marked as Overture's own.
        #expect(ShowOutcome.allCases.filter(\.isOverturesOwn) == [.wentBy, .tooFar])
    }

    // MARK: the words

    // #2388 was "Declined" and "Closed (not now)" writing one stored value under two names, one line
    // apart on the same row. With one list that cannot be expressed, and this is the assertion that
    // keeps it that way: no two values may read the same to Dan.
    @Test func noTwoValuesShareTheSameWords() {
        let labels = ShowOutcome.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test func everyValueHasWordsOfItsOwn() {
        for outcome in ShowOutcome.allCases {
            #expect(!outcome.label.isEmpty)
            // A label that is just the stored spelling means somebody added a case and forgot the words.
            #expect(outcome.label != outcome.rawValue)
        }
    }

    // "Already booked" (Dan was busy) and "Booked" (the client hired him) were one word for two
    // opposite facts. Exactly one value may claim the word on its own.
    @Test func onlyOneValueIsCalledBooked() {
        #expect(ShowOutcome.allCases.filter { $0.label == "Booked" } == [.booked])
    }

    @Test func beingBusyIsCalledPaidWorkNotBooked() {
        #expect(ShowOutcome.hadPaidWork.label == "I had paid work")
        #expect(!ShowOutcome.hadPaidWork.label.lowercased().contains("booked"))
    }

    // The five pitched endings in Dan's own words, from the interview. Pinned because they are a
    // contract with him, not an implementation detail: "I turned them down" replaced "You stopped
    // working this", which he rejected outright ("I will never stop working something without
    // closure").
    @Test func theFiveEndingsReadAsDanWordedThem() {
        #expect(ShowOutcome.booked.label == "Booked")
        #expect(ShowOutcome.neverHeardBack.label == "Never heard back")
        #expect(ShowOutcome.theySaidNotNow.label == "They said not now")
        #expect(ShowOutcome.theySaidNo.label == "They said no")
        #expect(ShowOutcome.turnedThemDown.label == "I turned them down")
    }

    // MARK: which menu, decided by the send record

    // Whether a show was pitched is a fact about the send record, never something encoded in the
    // words. So the menu is chosen by that fact alone.
    @Test func theMenuIsChosenByWhetherAnythingWasSent() {
        #expect(ShowOutcome.menu(wasPitched: false) == ShowOutcome.neverPitched)
        #expect(ShowOutcome.menu(wasPitched: true) == ShowOutcome.pitched)
    }

    @Test func neitherMenuOffersTheOtherHalf() {
        #expect(!ShowOutcome.menu(wasPitched: false).contains(.neverHeardBack))
        #expect(!ShowOutcome.menu(wasPitched: false).contains(.booked))
        #expect(!ShowOutcome.menu(wasPitched: true).contains(.dateConflict))
        #expect(!ShowOutcome.menu(wasPitched: true).contains(.hadPaidWork))
    }

    // MARK: never pitched is not lost

    // Dan, on the reporting: "I don't think we should count scouted but not pitched as 'lost'. I do
    // think it's worth counting though." Phase 6 reads these groups; naming them here is what stops
    // it re-deriving the split from a list of raw values.
    @Test func theNeverPitchedHalfIsNotCountedAsLost() {
        for outcome in ShowOutcome.neverPitched {
            #expect(outcome.group == .neverPitched)
        }
        #expect(ShowOutcome.booked.group == .booked)
        for outcome in [ShowOutcome.neverHeardBack, .theySaidNotNow, .theySaidNo, .turnedThemDown] {
            #expect(outcome.group == .pitchedAndLost)
        }
    }

    // Overture's own two are neither a judgement Dan made nor a pitch that failed, so they must not
    // land in any of the three reported groups. `wentBy` in particular is a fact about the calendar.
    @Test func overturesOwnTwoAreNotReportedAsAnyOutcome() {
        #expect(ShowOutcome.wentBy.group == nil)
        #expect(ShowOutcome.tooFar.group == nil)
    }
}

// The bridge that lets phase 1 move the STORAGE onto one field without rewriting every surface that
// still speaks in dismiss reasons. It is temporary (#2395 removes it), and while it exists it is the
// single point where the two vocabularies meet, so a value lost in either direction would silently
// rewrite what Dan recorded about a show.
@Suite("The dismiss-reason bridge (#2394)")
struct DismissReasonBridgeTests {

    // Every one of the nine survives the round trip. Without this a value could map onto a neighbour
    // and the show would come back reading as a different decision than the one Dan made.
    @Test func everyDismissReasonRoundTripsThroughTheOneVocabulary() {
        for reason in DismissReason.allCases {
            #expect(reason.asShowOutcome.asDismissReason == reason)
        }
    }

    // #2684 narrowed the contract to exactly the nine that predate the one vocabulary, which is what the
    // bridge is FOR: reading a store written before #2394 forward. An ending minted afterwards has no
    // legacy spelling because no store can hold one, so it is named here rather than left as an unstated
    // gap, and the round trip still has to be total over the nine.
    @Test func everyLegacyNeverPitchedValueRoundTripsBack() {
        let predateTheOneVocabulary = Set(DismissReason.allCases.map(\.asShowOutcome))
        for outcome in ShowOutcome.neverPitched + [.wentBy, .tooFar]
        where predateTheOneVocabulary.contains(outcome) {
            #expect(outcome.asDismissReason?.asShowOutcome == outcome)
        }
        #expect(predateTheOneVocabulary.count == 9)
    }

    // The other half of that narrowing, so "no legacy spelling" cannot quietly grow to cover a value
    // that should have had one. Exactly one never-pitched ending is outside the bridge today.
    @Test func onlyTheEndingMintedAfterTheBridgeHasNoLegacySpelling() {
        let outside = ShowOutcome.neverPitched.filter { $0.asDismissReason == nil }
        #expect(outside == [.noWayToReachThem])
    }

    // Distinctness in BOTH directions, which is what actually rules out a collision: nine reasons must
    // land on nine different outcomes, not merely on some outcome each.
    @Test func noTwoDismissReasonsCollapseOntoOneOutcome() {
        let mapped = DismissReason.allCases.map(\.asShowOutcome)
        #expect(Set(mapped).count == DismissReason.allCases.count)
    }

    // A show closed out AFTER a pitch was never dismissed, so it has no dismiss reason to report. Nil
    // here is the correct answer rather than a gap, and it must not fall back to a never-pitched value.
    @Test func aPitchedEndingHasNoDismissReason() {
        for outcome in ShowOutcome.pitched {
            #expect(outcome.asDismissReason == nil)
        }
    }

    // One set of words, not two. While both vocabularies exist, a reason must read to Dan exactly as its
    // outcome does, or the same decision would be described differently depending on which screen he is
    // looking at, which reads as two different decisions (#843 from the worse direction).
    @Test func aReasonReadsExactlyAsItsOutcomeDoes() {
        for reason in DismissReason.allCases {
            #expect(reason.label == reason.asShowOutcome.label)
        }
    }

    // The collision itself, asserted where it can be seen: nothing Dan can read anywhere in the
    // never-pitched half claims he was "booked", because that word now belongs to the client hiring him.
    @Test func nothingInTheNeverPitchedHalfCallsItselfBooked() {
        for reason in DismissReason.allCases {
            #expect(!reason.label.lowercased().contains("booked"))
        }
        #expect(ShowOutcome.hadPaidWork.label == "I had paid work")
    }
}
