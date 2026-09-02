import Testing
import Foundation

// #3323 (Phase 1 of the per-night plan): the self-booking check reads EVERY night of a run, not only its
// opening night. Measured on the live store 2026-09-01, the opening-night-only rule was missing 14 of the
// 30 live-versus-committed collisions in Dan's queue, 13 distinct rows, masked by two committed rows on
// nights that were nobody's opening.
//
// Every fixture here pins BOTH ends of its date relationship: no test in this file reads the live clock,
// so real time cannot walk a case into a different one (L130). The nights are literal on both sides and
// nothing here compares them against `Date()`.
@Suite("Run-aware self double-booking (#3323)")
struct SelfBookingRunNightsTests {
    private func show(_ key: String, _ nights: [String], commitment: Bool = false,
                      engagement: String? = nil, name: String = "Show",
                      times: [String: [String]] = [:]) -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: key, nights: nights, isCommitment: commitment,
                                 engagementKey: engagement, name: name, timesByNight: times)
    }

    // THE DEFECT. A run playing two nights, whose SECOND night holds a commitment. The opening nights
    // differ, so the exact-date rule saw nothing at all and Dan could be double-booked with no warning.
    @Test func aLaterNightOfARunCollidesWithACommitment() {
        let target = show("run", ["2026-10-28", "2026-10-29"])
        let other = show("committed", ["2026-10-29"], commitment: true, name: "Orchestra A")
        let clashes = SelfBookingConflict.conflicts(for: target, among: [other, target])
        #expect(clashes.map(\.other.name) == ["Orchestra A"])
    }

    // The colliding NIGHT comes back, not just the show. Every sentence downstream renders under a header
    // keyed to the card's opening night, so without the night the copy would make a claim the check never
    // measured (L263; #1501 solved exactly this on the blocked-calendar half).
    @Test func theOverlapNamesTheNightItWasFoundOn() {
        let target = show("run", ["2026-10-28", "2026-10-29"])
        let other = show("committed", ["2026-10-29"], commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.night)
                == ["2026-10-29"])
    }

    // The commitment side expands too, not only the target. A committed RUN whose later night holds a
    // one-night candidate must warn that candidate.
    @Test func aCommittedRunCollidesOnItsOwnLaterNight() {
        let target = show("candidate", ["2026-10-29"])
        let other = show("committed-run", ["2026-10-27", "2026-10-29"], commitment: true, name: "Choir B")
        let clashes = SelfBookingConflict.conflicts(for: target, among: [other, target])
        #expect(clashes.map(\.other.name) == ["Choir B"])
        #expect(clashes.map(\.night) == ["2026-10-29"])
    }

    // A run with NO recorded nights collides with nothing here. The fallback to `performanceDate` alone
    // belongs to the caller (QueueModel.selfBookingShow) and is deliberately NOT a span walk: copying
    // BlockedCalendar's walk would manufacture clashes on the dark nights of a weekly series, which is
    // the one direction of this change that invents a warning rather than finding one.
    @Test func aShowWithNoNightsNeverCollides() {
        let target = show("nightless", [])
        let other = show("committed", ["2026-10-29"], commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
        #expect(SelfBookingConflict.conflicts(for: other, among: [other, target]).isEmpty)
    }

    // Nights are compared as a SET: a run holding the same night twice (15 rows in the live store do,
    // 2026-09-01, from an upstream fold defect) must not raise the same clash twice.
    @Test func aRepeatedNightRaisesOneOverlapNotTwo() {
        let target = show("run", ["2026-10-29", "2026-10-29"])
        let other = show("committed", ["2026-10-29"], commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).count == 1)
    }

    // A pair sharing SEVERAL nights reports each of them, earliest first, so the copy can name the first
    // one Dan meets rather than whichever the input order happened to put first.
    @Test func severalSharedNightsComeBackEarliestFirst() {
        let target = show("run", ["2026-10-29", "2026-10-27", "2026-10-28"])
        let other = show("committed", ["2026-10-28", "2026-10-29"], commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.night)
                == ["2026-10-28", "2026-10-29"])
    }

    // THE REASSURANCE THIS EXPANSION MADE POSSIBLE, and the reason `startTimes` had to become per night.
    // A Saturday matinee eight hours clear of the other show must not quiet a Tuesday clash fifteen
    // minutes apart. A single per-show time list would have let the Saturday gap answer for Tuesday.
    @Test func aWorkableGapOnOneNightDoesNotQuietAClashOnAnother() {
        let target = show("run", ["2026-10-27", "2026-10-31"],
                          times: ["2026-10-27": ["19:30"], "2026-10-31": ["14:00"]])
        let other = show("committed", ["2026-10-27", "2026-10-31"], commitment: true, name: "Orchestra A",
                         times: ["2026-10-27": ["19:45"], "2026-10-31": ["22:00"]])
        let clashes = SelfBookingConflict.conflicts(for: target, among: [other, target])
        #expect(clashes.map(\.night) == ["2026-10-27"])
        let workable = SelfBookingConflict.workable(for: target, among: [other, target])
        #expect(workable.map(\.night) == ["2026-10-31"])
    }

    // A night for which NEITHER side published a time warns exactly as it did before the clock rule
    // existed, which is most nights: nobody said is not they are far apart.
    @Test func aNightWithNoPublishedTimesStillWarns() {
        let target = show("run", ["2026-10-27", "2026-10-31"], times: ["2026-10-27": ["19:30"]])
        let other = show("committed", ["2026-10-31"], commitment: true,
                         times: ["2026-10-27": ["09:00"]])
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.night)
                == ["2026-10-31"])
    }

    // The engagement-key exemption survives expansion, and it is read through GroupNameMatch.normalize
    // rather than as raw display text. Expansion makes this newly dangerous: a run card whose per-night
    // sibling the scout renamed shares every night with itself, so a raw-text comparison would have the
    // run clash with itself on every night of its run.
    @Test func aRenamedSiblingOfTheSameRunDoesNotClashWithItself() {
        let target = show("a", ["2026-10-28", "2026-10-29"], engagement: "The Winter Songbook")
        let other = show("b", ["2026-10-28", "2026-10-29"], commitment: true,
                         engagement: "the winter songbook.")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).isEmpty)
    }

    // Two genuinely different shows on one night are still a clash: the normalisation must not fold names
    // that merely resemble each other, or the exemption would silence real double-bookings.
    @Test func twoDifferentProductionsOnOneNightStillClash() {
        let target = show("a", ["2026-10-29"], engagement: "The Winter Songbook")
        let other = show("b", ["2026-10-29"], commitment: true, engagement: "Autumn Variations",
                         name: "Autumn Variations")
        #expect(SelfBookingConflict.conflicts(for: target, among: [other, target]).map(\.other.name)
                == ["Autumn Variations"])
    }

    // A show never clashes with itself however many nights it plays.
    @Test func aRunDoesNotClashWithItself() {
        let target = show("a", ["2026-10-28", "2026-10-29"], commitment: true)
        #expect(SelfBookingConflict.conflicts(for: target, among: [target]).isEmpty)
    }

    // The queue-wide note asks the same question of the whole group: it may say "on this date" only when
    // every clash in the group really is on that date.
    @Test func theGroupsNoteDropsThisDateWhenAClashIsOnALaterNight() {
        let laterRun = show("run", ["2026-10-27", "2026-10-29"])
        let sameNight = show("card", ["2026-10-27"])
        let committed = show("committed", ["2026-10-27", "2026-10-29"], commitment: true, name: "Orchestra A")
        let index = SelfBookingConflict.NightIndex([committed, laterRun, sameNight])
        // The one-night card clashes on its own date, so the note is unchanged.
        #expect(SelfBookingConflict.everyClashIsOn("2026-10-27", for: [sameNight], in: index))
        // The run also clashes on Oct 29, which is not the header's date.
        #expect(!SelfBookingConflict.everyClashIsOn("2026-10-27", for: [laterRun, sameNight], in: index))
    }

    // The index is the SAME predicate as the direct call, so the cheap path a render pass uses and the
    // path every other caller uses can never disagree about which shows are on a night (L16).
    @Test func theIndexAgreesWithTheDirectComparison() {
        let target = show("run", ["2026-10-28", "2026-10-29"])
        let other = show("committed", ["2026-10-29"], commitment: true, name: "Orchestra A")
        let all = [other, target]
        let index = SelfBookingConflict.NightIndex(all)
        #expect(SelfBookingConflict.conflicts(for: target, in: index)
                == SelfBookingConflict.conflicts(for: target, among: all))
        #expect(SelfBookingConflict.workable(for: target, in: index)
                == SelfBookingConflict.workable(for: target, among: all))
    }

    // #3323 section 1.5: the index is the SOLE comparison input, which is what lets a render pass build it
    // once and hand it to every row. Asserted by answering from an index whose shows the call never sees:
    // if the lookup still needed the array, this could not return the clash.
    //
    // Deliberately NOT a counted-builder test. A counter incremented by the test's own closure measures the
    // test, not the app: the thing that can actually regress is a per-row call rebuilding the index, and
    // that is held by QueueRenderDataGuardTests.theSelfBookingLookupsUseTheItemsTheyWereHanded, which reads
    // the row's own source and refuses `selfBookingIndex(` inside it (#1772's defect in its new spelling).
    @Test func theIndexIsTheOnlyComparisonInputTheLookupNeeds() {
        let committed = show("committed", ["2026-10-29"], commitment: true, name: "Orchestra A")
        let index = SelfBookingConflict.NightIndex([committed])
        let target = show("run", ["2026-10-28", "2026-10-29"])
        #expect(SelfBookingConflict.conflicts(for: target, in: index).map(\.other.name) == ["Orchestra A"])
    }
}

// The sentence a run-aware clash produces. A clash on a later night that says "on this date" is a claim
// the check never measured, and it lands under a date header naming a different night (#1501's defect
// exactly, on the other half of the system).
@Suite("Run-aware self double-booking copy (#3323)")
struct SelfBookingRunNightsCopyTests {
    // A clash on the card's OWN night reads exactly as it always has. This is the common case and it must
    // not acquire a date it never needed.
    @Test func aClashOnTheCardsOwnNightIsUnchanged() {
        #expect(SelfBookingCopy.rowMarker(["Orchestra A"], clashNight: "2026-10-29",
                                          performanceDate: "2026-10-29")
                == "Also pitching Orchestra A on this date")
    }

    // A clash on a LATER night names that night, so Dan is not told a date header's night is the problem
    // when the problem is four nights later.
    @Test func aClashOnALaterNightNamesTheNight() {
        #expect(SelfBookingCopy.rowMarker(["Orchestra A"], clashNight: "2026-10-29",
                                          performanceDate: "2026-10-27")
                == "Also pitching Orchestra A on Oct 29")
    }

    // An unreadable night falls back to saying it is later in the run, never to "on this date": naming
    // the wrong night is worse than naming none (L11).
    @Test func anUnreadableNightSaysLaterInTheRunRatherThanThisDate() {
        #expect(SelfBookingCopy.rowMarker(["Orchestra A"], clashNight: "not-a-date",
                                          performanceDate: "2026-10-27")
                == "Also pitching Orchestra A on a later night of this run")
    }

    // No night measured at all is the same case: it may not claim the card's own date.
    @Test func noNightAtAllStillDoesNotClaimThisDate() {
        #expect(SelfBookingCopy.rowMarker(["Orchestra A"], clashNight: nil,
                                          performanceDate: "2026-10-27")
                == "Also pitching Orchestra A on a later night of this run")
    }

    // The send and prep confirmations carry the same distinction, since those are the committing moments.
    @Test func theConfirmWarningNamesTheLaterNightToo() {
        #expect(SelfBookingCopy.confirmWarning(["Orchestra A"], clashNight: "2026-10-29",
                                               performanceDate: "2026-10-29")
                == "You already have a pitch in progress for Orchestra A on this date.")
        #expect(SelfBookingCopy.confirmWarning(["Orchestra A"], clashNight: "2026-10-29",
                                               performanceDate: "2026-10-27")
                == "You already have a pitch in progress for Orchestra A on Oct 29.")
    }

    // The prep-launch confirm names the night, as its OWN sentence rather than a clause bolted onto the
    // existing one. "is on a date ... for Orchestra A, on Oct 29" reads as two competing dates: the
    // sentence opens by talking about the card's date and ends by naming a different one.
    @Test func thePrepConfirmNamesTheNightOfALaterClash() {
        let later = [SelfBookingPrepClash(groupName: "Choir P", conflictNames: ["Orchestra A"],
                                          clashNight: "2026-10-29", performanceDate: "2026-10-27")]
        #expect(SelfBookingCopy.prepConfirmMessage(later)
                == "Choir P plays Oct 29, when you already have a pitch in progress for Orchestra A.")
        let sameNight = [SelfBookingPrepClash(groupName: "Choir P", conflictNames: ["Orchestra A"],
                                              clashNight: "2026-10-29", performanceDate: "2026-10-29")]
        #expect(SelfBookingCopy.prepConfirmMessage(sameNight)
                == "Choir P is on a date you already have a pitch in progress for Orchestra A.")
    }

    // An unreadable night keeps the run framing rather than claiming the card's own date.
    @Test func thePrepConfirmWithNoReadableNightStillSaysItIsLaterInTheRun() {
        let unknown = [SelfBookingPrepClash(groupName: "Choir P", conflictNames: ["Orchestra A"],
                                            clashNight: nil, performanceDate: "2026-10-27")]
        #expect(SelfBookingCopy.prepConfirmMessage(unknown)
                == "Choir P plays a later night of its run when you already have a pitch in progress for Orchestra A.")
    }

    // The date-header note sits under a header naming ONE date, so it may not say "on this date" when the
    // clash it is reporting is on a later night of a run in that group. Same defect #1501 fixed on the
    // blocked-calendar half: the sentence was true and read false, because the eye binds the date in the
    // sentence to the header above it.
    @Test func theDateHeaderNoteSaysThisDateOnlyWhenTheClashIsOnIt() {
        #expect(SelfBookingCopy.dateHeaderNote(allOnThisDate: true)
                == "Another pitch is already in progress on this date")
        #expect(SelfBookingCopy.dateHeaderNote(allOnThisDate: false)
                == "Another pitch is already in progress on a night one of these runs plays")
    }
}

// The caller's half of #3323: how a queue row becomes the night list the check compares, and the fallback
// for the rows that record no nights at all.
@Suite("Run-aware self double-booking, from the queue row (#3323)")
struct SelfBookingRowNightsTests {
    private func row(_ key: String, _ date: String, nights: [String] = [],
                     name: String = "Show", sent: Bool = false) -> QueueItem {
        var q = QueueItem(
            id: key, groupName: name, discipline: "music", venue: "Venue", performanceDate: date,
            sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new
        )
        q.runNights = nights
        if sent { q.sentAt = Date() }
        return q
    }

    // A row's recorded nights are what the check compares, so a run's later night sees a commitment.
    @Test func theRowsRecordedNightsAreWhatIsCompared() {
        let target = row("run", "2026-10-28", nights: ["2026-10-28", "2026-10-29"])
        let other = row("c", "2026-10-29", nights: ["2026-10-29"], name: "Orchestra A", sent: true)
        let index = QueueModel.selfBookingIndex([other, target])
        #expect(QueueModel.selfBookingConflictNames(for: target, in: index) == ["Orchestra A"])
        #expect(QueueModel.selfBookingClashNight(for: target, in: index) == "2026-10-29")
    }

    // THE FALLBACK, and the direction it must NOT take. A row with no recorded nights (22 in the live
    // store on 2026-09-01, 11 of them live) falls back to its performanceDate ALONE. Walking its span the
    // way BlockedCalendar does would manufacture a clash on a night the run may be dark, which is the one
    // direction of this change that invents a warning rather than finding one.
    @Test func aRowWithNoRecordedNightsFallsBackToItsOwnDateOnly() {
        let spanning = row("span", "2026-10-27")            // records no nights at all
        let onALaterDay = row("c", "2026-10-29", nights: ["2026-10-29"], name: "Orchestra A", sent: true)
        let index = QueueModel.selfBookingIndex([onALaterDay, spanning])
        #expect(QueueModel.selfBookingNights(spanning) == ["2026-10-27"])
        #expect(QueueModel.selfBookingConflictNames(for: spanning, in: index).isEmpty)

        // ...and it still sees a clash on the one night it does know about.
        let sameDay = row("d", "2026-10-27", nights: ["2026-10-27"], name: "Choir B", sent: true)
        #expect(QueueModel.selfBookingConflictNames(for: spanning,
                                                    in: QueueModel.selfBookingIndex([sameDay, spanning]))
                == ["Choir B"])
    }

    // A clash the row meets on two of its nights names the other show ONCE, not once per night.
    @Test func aShowClashingOnTwoNightsIsNamedOnce() {
        let target = row("run", "2026-10-27", nights: ["2026-10-27", "2026-10-29"])
        let other = row("c", "2026-10-27", nights: ["2026-10-27", "2026-10-29"],
                        name: "Orchestra A", sent: true)
        let index = QueueModel.selfBookingIndex([other, target])
        #expect(QueueModel.selfBookingConflictNames(for: target, in: index) == ["Orchestra A"])
    }
}
