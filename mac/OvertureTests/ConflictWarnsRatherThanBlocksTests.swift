import Testing
import Foundation

// #3369 / #3366. Dan's call, 2026-09-01 (this session, in chat): a calendar clash WARNS at Prep and never
// blocks. His words, asked whether the Prep gate should go entirely or only stand down when a run still has
// a free night: "Maybe warn me, but let me do it."
//
// The reported harm (#3366) was a multi-night run losing Prep because ONE of its nights was blocked, while
// its other nights were free: "I just blocked the 12th and it disappeared from my prep queue." But the run
// was never the only victim. A one-night show on a blocked night was equally unable to be researched, and
// Dan could override neither.
//
// #3369 is what makes this one decision rather than three fixes: `hasUnclearedConflict` was read by four
// gates, each added on its own, and nobody had decided as one question what a clash should stop.
@Suite("A calendar clash warns at Prep and never blocks it (#3369, #3366)")
struct ConflictWarnsRatherThanBlocksTests {
    // THE FIX. A kept, undrafted show is prep work whether or not the night carries a clash.
    @Test func aKeptShowIsPrepWorkEvenWithAnOpenClash() {
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false))
    }

    // ...and the rest of the eligibility rule is untouched: a clash was the only thing removed.
    @Test func everyOtherReasonToRefusePrepStillHolds() {
        #expect(!PrepQueueBuilder.needsPrep(status: .new, hasDraft: false))
        #expect(!PrepQueueBuilder.needsPrep(status: .queued, hasDraft: true))
        #expect(PrepQueueBuilder.needsPrep(status: .drafted, hasDraft: true, reprepDraftRequested: true))
        #expect(!PrepQueueBuilder.needsPrep(status: .dismissed, hasDraft: false, reprepDraftRequested: true))
    }

    // #3366's own case, spelled out: a run playing two nights, one blocked and one free, is prep work.
    // Nothing here reads the live clock; both nights and the block are literal (L130).
    @Test func aRunWithOneBlockedNightAndOneFreeOneIsStillPrepWork() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [],
                                        exportedBlockedDates: [],
                                        daysOff: [DayOffRange(startDate: "2026-09-12", endDate: "2026-09-12",
                                                              note: "visiting nana")])
        let clash = cal.conflict(performanceDate: "2026-09-12", runEndDate: "2026-10-07",
                                 nights: ["2026-09-12", "2026-10-07"])
        #expect(clash != nil, "the blocked night is found, or this test proves nothing about what follows")
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false))
    }

    // The one gate that KEEPS its teeth. Send is the committing moment: a pitch that has gone cannot be
    // taken back, so it still refuses and confirms rather than warning past silently. If this ever goes
    // green the decision has been half-applied.
    @Test func theSendGateStillRefusesAnUnclearedClash() {
        let sendable = SourceGuardHelper.source("Overture/Domain/Recipient.swift")
        #expect(sendable.contains("prospect?.hasUnclearedConflict != true"))
    }

    // The clash is still SAID, on the card, which is the whole of what "warn" means here.
    @Test func theCardStillCarriesTheReasonTheNightIsSpokenFor() {
        let day = BlockedCalendar.Day(date: "2026-09-12", kind: .dayOff, name: "visiting nana")
        #expect(day.reason.contains("Sep 12"))
    }
}

// The pill that selected the shows the gate held back. Dan's call, 2026-09-01: retire it. With nothing
// held out of Prep it can only ever promise zero rows, and a pill's number is a promise about rows (#863).
@Suite("The Prep blocked stage is retired (#3369)")
struct PrepBlockedStageRetiredTests {
    // Derived from the enum rather than from a list somebody maintains, so this cannot pass by being
    // out of date.
    @Test func noStageFocusIsNamedForABlockedPrep() {
        #expect(!StageNavigation.countedFocuses.contains { "\($0)" == "prepBlocked" })
    }

    // Nothing in the tree still USES it: not the empty state, not the roster's attention line, not the
    // overlap families. A retired focus that keeps its sentences is a surface promising a state the app
    // can no longer be in (L29, L132).
    //
    // Matched as the CASE rather than as the word, because the comments recording why it was retired name
    // it deliberately and are worth keeping: a guard that could not tell a live reference from the note
    // explaining a removal would push the next reader into deleting the explanation (L103).
    @Test func nothingInTheAppStillUsesIt() {
        for file in ["Overture/Domain/StageNavigation.swift",
                     "Overture/Domain/StageEmptyState.swift",
                     "Overture/Domain/AgentRoster.swift",
                     "Overture/Domain/StageOverlap.swift",
                     "Overture/Domain/PrepQueue.swift",
                     "Overture/UI/QueueView+Model.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.contains("case prepBlocked"), "\(file) still declares the retired focus")
            #expect(!source.contains("case .prepBlocked"), "\(file) still matches the retired focus")
            #expect(!source.contains(".prepBlocked)"), "\(file) still passes the retired focus")
            #expect(!source.contains(".prepBlocked ="), "\(file) still writes the retired focus")
        }
    }

    // And the guard above is not enough on its own, which was found the hard way: the first version of
    // this change deleted the `case prepBlocked` line and LEFT the paragraph explaining it, so a
    // description of a stage the app no longer has ended up sitting directly over a different group of
    // cases, reading as current. Every check here passed, because they all look for the CASE.
    //
    // So a mention that survives has to mark itself as history. A comment recording WHY something was
    // retired is worth keeping (deleting it is how the next person re-adds the thing); a comment that
    // describes it as though it still exists is worse than no comment at all (L103, L346).
    @Test func everySurvivingMentionSaysItIsRetired() {
        for file in ["Overture/Domain/StageNavigation.swift",
                     "Overture/Domain/StageEmptyState.swift",
                     "Overture/Domain/AgentRoster.swift",
                     "Overture/Domain/StageOverlap.swift",
                     "Overture/Domain/PrepQueue.swift",
                     "Overture/UI/QueueView+Model.swift"] {
            for line in SourceGuardHelper.source(file).components(separatedBy: "\n")
            where line.contains("prepBlocked") {
                #expect(line.contains("#3369") || line.lowercased().contains("retired"),
                        "\(file) names the retired focus without saying it is gone: \(line)")
            }
        }
    }

    // The lifecycle stages still cover the whole state space between them (L45): a kept, undrafted show
    // is in Prep whatever its calendar says, so retiring the focus leaves nothing stranded.
    @Test func aKeptShowWithAClashIsInPrepRatherThanNowhere() {
        #expect(PrepQueueBuilder.needsPrep(status: .queued, hasDraft: false))
    }
}

// What the warning SAYS. The confirm already existed for the self-booking clash (#1219), so the calendar
// clash joins it in the same sheet rather than arriving as a second dialog: two sheets over one press is
// how a confirm becomes something to click past.
@Suite("The Prep confirm names a calendar clash (#3366)")
struct PrepCalendarClashCopyTests {
    private func clash(_ name: String, _ note: String) -> PrepCalendarClash {
        PrepCalendarClash(groupName: name, note: note)
    }

    @Test func nothingToWarnAboutSaysNothing() {
        #expect(PrepLaunchCopy.calendarClashMessage([]) == nil)
    }

    // The row's OWN sentence is quoted, so the confirm and the card cannot describe the same clash
    // differently (#843), and rewording the card can never leave this saying the old thing.
    @Test func oneClashQuotesTheCardsOwnSentence() {
        #expect(PrepLaunchCopy.calendarClashMessage([clash("Choir P", "You blocked Sep 12 (visiting nana).")])
                == "Choir P: You blocked Sep 12 (visiting nana).")
    }

    @Test func severalClashesEachGetTheirOwnLine() {
        let message = PrepLaunchCopy.calendarClashMessage([
            clash("Choir P", "You blocked Sep 12 (visiting nana)."),
            clash("Orchestra A", "You're already shooting Autumn Gala on Oct 7.")])
        #expect(message == """
        Choir P: You blocked Sep 12 (visiting nana).
        Orchestra A: You're already shooting Autumn Gala on Oct 7.
        """)
    }

    // A blank name never leaves a hole, the same rule the self-booking copy already follows.
    @Test func aBlankNameReadsAsThisShow() {
        #expect(PrepLaunchCopy.calendarClashMessage([clash("  ", "You blocked Sep 12.")])
                == "This show: You blocked Sep 12.")
    }

    // Three titles, because a confirm that says one thing about two different situations tells Dan less
    // than the situation he is actually in (L11). Each is what the sheet is really asking.
    @Test func theTitleSaysWhichKindOfClashIsBeingConfirmed() {
        #expect(PrepLaunchCopy.confirmTitle(selfBooking: true, calendar: false)
                == "Prep a show on a date you're already pitching?")
        #expect(PrepLaunchCopy.confirmTitle(selfBooking: false, calendar: true)
                == "Prep a show on a night you're not free?")
        #expect(PrepLaunchCopy.confirmTitle(selfBooking: true, calendar: true)
                == "Prep a show on a night that's already spoken for?")
    }

    // Nothing to confirm means no sheet at all, so the title is never asked for in that state.
    @Test func thereIsNoTitleWhenThereIsNothingToConfirm() {
        #expect(PrepLaunchCopy.confirmTitle(selfBooking: false, calendar: false) == nil)
    }

    // Both halves land in one sheet, self-booking first, because that is the one that can double-book him.
    @Test func bothKindsOfClashArriveInOneMessage() {
        let combined = PrepLaunchCopy.combinedMessage(
            selfBooking: "Choir P is on a date you already have a pitch in progress for Orchestra A.",
            calendar: "Choir P: You blocked Sep 12 (visiting nana).")
        #expect(combined == """
        Choir P is on a date you already have a pitch in progress for Orchestra A.

        Choir P: You blocked Sep 12 (visiting nana).
        """)
        #expect(PrepLaunchCopy.combinedMessage(selfBooking: nil, calendar: "a") == "a")
        #expect(PrepLaunchCopy.combinedMessage(selfBooking: "b", calendar: nil) == "b")
        #expect(PrepLaunchCopy.combinedMessage(selfBooking: nil, calendar: nil) == nil)
    }
}

// The two per-row controls that REFUSED on a clash. Under the decision they offer the work and let the
// confirm carry the warning: a control that is visible and inert teaches Dan that the app is broken, and
// this is the state he was told he could override.
@Suite("The per-row prep controls offer the work rather than refusing it (#3366)")
struct PerRowPrepControlsTests {
    private func kept(_ conflicted: Bool, status: ReviewStatus = .queued,
                      draft: String? = nil) -> QueueItem {
        var q = QueueItem(
            id: "k", groupName: "Choir P", discipline: "music", venue: "Venue",
            performanceDate: "2026-09-12", sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status,
            draftBody: draft)
        q.hasUnclearedConflict = conflicted
        return q
    }

    @Test func prepManuallyIsOfferedOnAClashedShow() {
        #expect(QueueModel.manualPrepOffer(for: kept(true)) == .shown)
        #expect(QueueModel.manualPrepOffer(for: kept(false)) == .shown)
    }

    @Test func reprepIsOfferedOnAClashedShow() {
        let drafted = kept(true, status: .drafted, draft: "a draft")
        #expect(QueueModel.reprepOffer(for: drafted) == .shown)
    }
}

// Which shows the confirm is built from, and the wiring that puts it in front of Dan. A pure copy function
// nothing calls is the exact shape of the defect this change is fixing on the other side (L3).
@Suite("The calendar clash reaches the Prep confirm (#3366)")
struct PrepCalendarClashWiringTests {
    private func row(_ key: String, _ name: String, conflicted: Bool, note: String?) -> QueueItem {
        var q = QueueItem(
            id: key, groupName: name, discipline: "music", venue: "Venue",
            performanceDate: "2026-09-12", sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        q.hasUnclearedConflict = conflicted
        q.conflictNote = note
        return q
    }

    // Only the SELECTED shows, and only the ones carrying an open clash.
    @Test func onlyTheSelectedClashedShowsAreCollected() {
        let all = [row("a", "Choir P", conflicted: true, note: "You blocked Sep 12 (visiting nana)."),
                   row("b", "Orchestra A", conflicted: true, note: "You blocked Sep 12."),
                   row("c", "Solo C", conflicted: false, note: nil)]
        #expect(QueueModel.calendarClashesForPrep(forKeys: ["a", "c"], among: all)
                == [PrepCalendarClash(groupName: "Choir P", note: "You blocked Sep 12 (visiting nana).")])
        #expect(QueueModel.calendarClashesForPrep(forKeys: ["c"], among: all).isEmpty)
    }

    // A clash whose reason cannot be read is not confirmed with a blank line. An empty sentence under a
    // title asking Dan to confirm it is worse than saying nothing at all (L11).
    @Test func aClashWithNoReadableReasonIsNotPutInFrontOfHim() {
        let all = [row("a", "Choir P", conflicted: true, note: nil)]
        #expect(QueueModel.calendarClashesForPrep(forKeys: ["a"], among: all).isEmpty)
    }

    // BOTH prep entry points ask. Gating only the "Prep these N" sheet leaves the per-row Re-prep able to
    // spend with no warning, which is the hole #1219's own red team found on this exact pair.
    @Test func bothPrepEntryPointsAskForTheCalendarHalf() {
        let sheet = SourceGuardHelper.source("Overture/UI/PrepSelectionSheet.swift")
        let queue = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        // The ASSIGNMENT, not the call. A mutation that left the call in place as a discarded `_ =` and
        // nulled the variable beside it SURVIVED the first version of this guard, which asked only whether
        // the file named the function. A needle still present for a harmless reason is what makes a
        // source-text guard vacuous (L135, #3157), and the fix is to match the thing the value is bound to.
        for (name, source) in [("PrepSelectionSheet", sheet), ("QueueView", queue)] {
            #expect(source.contains("let calendar = PrepLaunchCopy.calendarClashMessage("),
                    "\(name) does not bind the calendar clash message")
            #expect(source.contains("QueueModel.calendarClashesForPrep("),
                    "\(name) does not ask for the calendar clashes")
            #expect(source.contains("PrepLaunchCopy.combinedMessage(selfBooking: selfBooking,"),
                    "\(name) does not combine the two halves into one sheet")
            #expect(source.contains("calendar: calendar"),
                    "\(name) does not pass the calendar half into the combined message")
            #expect(source.contains("PrepLaunchCopy.confirmTitle("),
                    "\(name) does not take its title from the clashes it found")
        }
    }
}
