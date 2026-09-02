import Testing
import Foundation

@Suite("Self double-booking conflict (#1219)")
struct SelfBookingConflictTests {
    // No published curtain times, which is the MAJORITY of real shows and the state every case below is
    // about: without them the #1699 gap rule can prove nothing, so these all read exactly as they did
    // before it existed. The gap's own cases live in SelfBookingWorkableNightTests.
    private func show(_ key: String, _ date: String?, commitment: Bool = false,
                      engagement: String? = nil, name: String = "Show") -> SelfBookingConflict.Show {
        // #3323: one night, spelled as the night-plural type. The run-aware cases live in
        // SelfBookingRunNightsTests; these hold the single-night behaviour that must survive expansion.
        SelfBookingConflict.Show(key: key, nights: date.map { [$0] } ?? [], isCommitment: commitment,
                                 engagementKey: engagement, name: name, timesByNight: [:])
    }

    // A committed DIFFERENT show on the same exact date is a conflict, and it is the one returned so the
    // warning can name it.
    @Test func aCommittedShowOnTheSameDateIsAConflict() {
        let target = show("b", "2026-08-01")
        let other = show("a", "2026-08-01", commitment: true, name: "Orchestra A")
        let conflicts = SelfBookingConflict.conflicts(for: target, among: [other, target])
        #expect(conflicts.map(\.other.name) == ["Orchestra A"])
    }

    // A non-committed show on the same date (kept but not drafted, or a scout candidate) is NOT a conflict.
    @Test func aNonCommittedShowOnTheSameDateIsNotAConflict() {
        let target = show("b", "2026-08-01")
        let other = show("a", "2026-08-01", commitment: false)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
    }

    // The TARGET need not itself be a commitment: a kept show being prepped still sees another committed
    // show on its date. Only the OTHER show's commitment matters.
    @Test func aNonCommittedTargetStillSeesCommittedOthers() {
        let target = show("b", "2026-08-01", commitment: false)
        let other = show("a", "2026-08-01", commitment: true, name: "Orchestra A")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.other.name) == ["Orchestra A"])
    }

    // Every committed different show on the date is returned, so the warning can count/name them all.
    @Test func multipleCommittedShowsOnTheDateAreAllReturned() {
        let target = show("c", "2026-08-01")
        let a = show("a", "2026-08-01", commitment: true, name: "Orchestra A")
        let b = show("b", "2026-08-01", commitment: true, name: "Choir B")
        let names = Set(SelfBookingConflict.conflicts(for: target, among: [a, b, target]).map(\.other.name))
        #expect(names == ["Orchestra A", "Choir B"])
    }

    // A show never conflicts with itself, even once it is a commitment.
    @Test func aShowDoesNotConflictWithItself() {
        let target = show("a", "2026-08-01", commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [target]).isEmpty)
    }

    // A show a day apart does not conflict. #3323 expanded the check to every night a run PLAYS, which is
    // not the same as expanding it to a run's SPAN: a night neither show plays is nobody's clash.
    @Test func aDifferentDateDoesNotConflict() {
        let target = show("b", "2026-08-01")
        let other = show("a", "2026-08-02", commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
    }

    // Two rows of the SAME linked production (a run touring venues) are one show, not a double-booking,
    // so a shared engagement key on the same date does not conflict.
    @Test func theSameLinkedProductionIsNotADoubleBooking() {
        let target = show("b", "2026-08-01", engagement: "run-1")
        let other = show("a", "2026-08-01", commitment: true, engagement: "run-1")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
    }

    // A show with no date can't collide with anything.
    @Test func aShowWithNoDateNeverConflicts() {
        let target = show("b", nil)
        let other = show("a", "2026-08-01", commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
    }
}

@Suite("Self double-booking copy (#1219)")
struct SelfBookingCopyTests {
    // One clashing show is named directly; several collapse to "X and N others".
    @Test func othersPhraseNamesOneOrCountsMany() {
        #expect(SelfBookingCopy.othersPhrase([]) == nil)
        #expect(SelfBookingCopy.othersPhrase(["Orchestra A"]) == "Orchestra A")
        #expect(SelfBookingCopy.othersPhrase(["Orchestra A", "Choir B"]) == "Orchestra A and 1 other")
        #expect(SelfBookingCopy.othersPhrase(["A", "B", "C"]) == "A and 2 others")
    }

    // A blank groupName never leaves a hole in the sentence; it reads as "another show".
    @Test func aBlankNameReadsAsAnotherShow() {
        #expect(SelfBookingCopy.othersPhrase([""]) == "another show")
        #expect(SelfBookingCopy.rowMarker(["  "], clashNight: nil, performanceDate: nil) == "Also pitching another show on this date")
    }

    // The row marker and the confirm warning both name the clashing show and are nil on a clear date.
    @Test func markerAndConfirmNameTheShowAndAreNilWhenClear() {
        #expect(SelfBookingCopy.rowMarker(["Orchestra A"], clashNight: "2026-08-01", performanceDate: "2026-08-01") == "Also pitching Orchestra A on this date")
        #expect(SelfBookingCopy.confirmWarning(["Orchestra A"], clashNight: "2026-08-01", performanceDate: "2026-08-01")
                == "You already have a pitch in progress for Orchestra A on this date.")
        #expect(SelfBookingCopy.rowMarker([], clashNight: nil, performanceDate: nil) == nil)
        #expect(SelfBookingCopy.confirmWarning([], clashNight: nil, performanceDate: nil) == nil)
    }

    // The prep-launch confirm names each prepping show and what it clashes with; nil when nothing clashes.
    @Test func prepConfirmMessageNamesEachClashingShow() {
        #expect(SelfBookingCopy.prepConfirmMessage([]) == nil)
        let one = [SelfBookingPrepClash(groupName: "Choir P", conflictNames: ["Orchestra A"],
                                     clashNight: "2026-08-01", performanceDate: "2026-08-01")]
        #expect(SelfBookingCopy.prepConfirmMessage(one)
                == "Choir P is on a date you already have a pitch in progress for Orchestra A.")
        let many = [SelfBookingPrepClash(groupName: "Choir P", conflictNames: ["Orchestra A", "Duo B"],
                                      clashNight: "2026-08-01", performanceDate: "2026-08-01")]
        #expect(SelfBookingCopy.prepConfirmMessage(many)
                == "Choir P is on a date you already have a pitch in progress for Orchestra A and 1 other.")
    }

    @Test func prepConfirmProceedLabelIsStable() {
        #expect(SelfBookingCopy.prepConfirmTitle == "Prep a show on a date you're already pitching?")
        #expect(SelfBookingCopy.prepConfirmProceed == "Prep anyway")
    }

    @Test func approveConfirmCopyIsStable() {
    }
}
