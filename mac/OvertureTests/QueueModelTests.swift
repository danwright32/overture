import Testing
import Foundation

private func item(
    discipline: String = "music",
    venue: String? = "Weill Recital Hall",
    performanceDate: String? = "2026-07-01",
    priorRelationship: String = "none",
    production: String = "unknown",
    coverage: String = "unknown",
    fitScore: Int = 3,
    tier: String = "longshot",
    matchedClientName: String? = nil,
    possibleMatchSource: String? = nil,
    possibleMatchName: String? = nil,
    partOfRelatedRun: Bool = false,
    status: ReviewStatus = .new,
    key: String = "k",
    groupName: String = "Test Group"
) -> QueueItem {
    var q = QueueItem(
        id: key, groupName: groupName, discipline: discipline, venue: venue,
        performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
        priorRelationship: priorRelationship, production: production, profile: "neutral",
        coverage: coverage, fitScore: fitScore, tier: tier, fitReason: "reason",
        matchedClientName: matchedClientName, possibleMatchSource: possibleMatchSource,
        possibleMatchName: possibleMatchName, status: status
    )
    q.partOfRelatedRun = partOfRelatedRun
    return q
}

// #1220: every stage view groups its rows by date under "FRI Jul 17 2026" headers. The grouping is
// QueueModel.groupByDate; the view just renders it. Lock the grouping contract the view now depends on:
// date-ordered sections in first-seen order, rows sharing a date collected together, the undated bucket
// last and naming itself rather than showing a blank header.
@Suite("Date grouping (#1220)")
struct DateGroupingTests {
    @Test func rowsGroupByDateWithUndatedLast() {
        let items = [
            item(performanceDate: "2026-07-17", key: "a"),
            item(performanceDate: "2026-07-19", key: "b"),
            item(performanceDate: "2026-07-17", key: "c"),
            item(performanceDate: nil, key: "d"),
        ]
        let groups = QueueModel.groupByDate(items)
        #expect(groups.map(\.id) == ["2026-07-17", "2026-07-19", "tbd"])
        #expect(groups[0].items.map(\.id) == ["a", "c"])   // both Jul 17 rows in one group
        #expect(groups[0].monthDay == "Jul 17")
        #expect(groups[0].year == "2026")
        #expect(groups[0].weekday.isEmpty == false)         // "FRI"-style weekday present for a real date
        #expect(groups.last?.monthDay == "Date to be confirmed")  // undated names itself, no blank header
    }
}

@Suite("Date group unavailability (#901)")
struct DateGroupUnavailableTests {
    private func conflicted(_ key: String) -> QueueItem {
        var q = item(key: key)   // performanceDate defaults to 2026-07-01
        q.hasUnclearedConflict = true
        q.conflictBlockedDate = "2026-07-01"   // blocked on its own date, so the date header is honest
        q.conflictNote = "You blocked Jul 1 (Vacation)."
        return q
    }

    // The date-group HEADER gets an "Unavailable" marker when any show under it is on a day Dan can't
    // work (Dan's walk feedback, 2026-07-14: "up by the date"). A day off or a booked shoot blocks the
    // whole day, so a marked header reads as "this date is blocked", which is what he wants to see at a
    // glance without opening every row.
    @Test func aGroupWithAConflictedShowIsUnavailable() {
        #expect(QueueModel.groupIsUnavailable([item(key: "a"), conflicted("b")]))
    }

    @Test func aGroupWithNoConflictedShowIsNot() {
        #expect(QueueModel.groupIsUnavailable([item(key: "a"), item(key: "b")]) == false)
    }

    @Test func anEmptyGroupIsNot() {
        #expect(QueueModel.groupIsUnavailable([]) == false)
    }

    // #929: a multi-night run can be flagged for a LATER night while its opening night, the date it groups
    // under, is free. The date-group header is a claim about THAT date, so it must not read "Unavailable"
    // when the blocked night is a different day. The row still carries its own flag and honest note; only
    // the date-level claim has to stay true.
    @Test func aRunBlockedOnlyOnALaterNightDoesNotMarkTheOpeningDate() {
        var q = item(performanceDate: "2026-07-01", key: "b")
        q.runEndDate = "2026-07-05"
        q.hasUnclearedConflict = true
        q.conflictBlockedDate = "2026-07-03"                 // blocked mid-run; opening night is free
        q.conflictNote = "You blocked Jul 3 (Vacation)."
        #expect(QueueModel.groupIsUnavailable([item(key: "a"), q]) == false)
    }

    // The common case still marks the header: the block falls on the show's own opening night, which is
    // exactly the date the group is headed by.
    @Test func aRunBlockedOnItsOpeningNightMarksThatDate() {
        var q = item(performanceDate: "2026-07-01", key: "b")
        q.hasUnclearedConflict = true
        q.conflictBlockedDate = "2026-07-01"
        q.conflictNote = "You blocked Jul 1 (Vacation)."
        #expect(QueueModel.groupIsUnavailable([item(key: "a"), q]))
    }
}

@Suite("Queue item lifecycle")
struct QueueItemLifecycleTests {
    // #219: an auto-detected Gmail reply is flagged so Dan can dismiss it; a hand-set reply is not.
    @MainActor
    @Test func isAutoRepliedOnlyForAutoDetectedReplies() {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        p.outcomeSourceRaw = OutcomeSource.auto.rawValue
        #expect(QueueItem(p).isAutoReplied)
        p.outcomeSourceRaw = OutcomeSource.manual.rawValue
        #expect(QueueItem(p).isAutoReplied == false)   // Dan set it by hand: not dismissable as auto
        p.outcome = .booked
        p.outcomeSourceRaw = OutcomeSource.auto.rawValue
        #expect(QueueItem(p).isAutoReplied == false)   // auto, but a booking, not a reply
    }

    @Test func keptCoversPursuedStatesThroughContacted() {
        #expect(item(status: .queued).isKept)
        #expect(item(status: .drafted).isKept)
        #expect(item(status: .approved).isKept)
        #expect(item(status: .contacted).isKept)
        #expect(item(status: .new).isKept == false)
        #expect(item(status: .dismissed).isKept == false)
    }
}

// #596: a quick-glance hint on the main queue row when a prospect carries more than one
// recipient (e.g. 2 named performers found for a self-produced show, #366), so Dan doesn't have
// to expand every row to see when multiple people were found.
@Suite("Queue item contact count")
struct QueueItemContactCountTests {
    private func recipient(_ id: String) -> RecipientSnapshot {
        RecipientSnapshot(id: id, name: id, email: "\(id)@example.com", role: nil,
                          provenance: .performer, sendState: .sent, replied: false,
                          lastReplyText: nil, resolution: nil, bounced: false, outcomeSource: nil)
    }

    @Test func noLabelForZeroOrOneContact() {
        var q = item()
        #expect(q.contactCountLabel == nil)
        q.contacts = [recipient("a")]
        #expect(q.contactCountLabel == nil)
    }

    @Test func labelsMultipleContacts() {
        var q = item()
        q.contacts = [recipient("a"), recipient("b")]
        #expect(q.contactCountLabel == "2 contacts")
    }
}

// #654: the single "primary contact" a show-level display (DraftReviewView's contactLine) reads,
// now derived from `contacts` instead of a lead-level mirror field. Mirrors PrepImporter's own
// selection rule exactly: act or performer preferred (mutually exclusive per performance, #587),
// else the first contact.
@Suite("Queue item primary contact")
struct QueueItemPrimaryContactTests {
    private func recipient(_ id: String, provenance: RecipientProvenance) -> RecipientSnapshot {
        RecipientSnapshot(id: id, name: id, email: "\(id)@example.com", role: nil,
                          provenance: provenance, sendState: .sent, replied: false,
                          lastReplyText: nil, resolution: nil, bounced: false, outcomeSource: nil)
    }

    @Test func nilWhenThereAreNoContacts() {
        #expect(item().primaryContact == nil)
    }

    @Test func prefersTheActContactOverOthers() {
        var q = item()
        q.contacts = [recipient("presenter", provenance: .presenter), recipient("act", provenance: .act)]
        #expect(q.primaryContact?.id == "act")
    }

    // A performer-only self-produced show that also carries a presenter must prefer the PERFORMER,
    // never fall through to an arbitrary contact (SwiftData to-many order isn't guaranteed) and
    // mislabel the presenter as primary.
    @Test func prefersPerformerOverPresenterWhenNoAct() {
        var q = item()
        q.contacts = [recipient("presenter", provenance: .presenter), recipient("performer", provenance: .performer)]
        #expect(q.primaryContact?.id == "performer")
    }

    @Test func fallsBackToTheFirstContactWhenNoActOrPerformer() {
        var q = item()
        q.contacts = [recipient("presenter", provenance: .presenter), recipient("manual", provenance: .manual)]
        #expect(q.primaryContact?.id == "presenter")
    }
}

@Suite("Queue label helpers")
struct QueueLabelTests {
    // #1657: a stored value the app cannot state (the `other` bucket, or anything outside the enum) says
    // so, rather than naming a genre. "Performance" was a genre nothing had read, printed as though it
    // had been, on 53% of the queue.
    @Test func aGenreTheAppCannotStateSaysSo() {
        #expect(QueueModel.disciplineLabel("dance") == "Dance")
        #expect(QueueModel.disciplineLabel("other") == Discipline.other.label)
        #expect(QueueModel.disciplineLabel("nonsense") == Discipline.other.label)
    }

    // #350: Choral is no longer its own category (folded into Music). A leftover raw "choral"
    // string (a legacy value the migration missed, or unmigrated history data) degrades
    // gracefully to the same answer rather than a dedicated label.
    @Test func legacyChoralStringReadsAsAGenreTheAppCannotState() {
        #expect(QueueModel.disciplineLabel("choral") == Discipline.other.label)
    }

    @Test func productionBadgeOnlyWithSignal() {
        #expect(QueueModel.productionLabel("self") == "Self-produced")
        #expect(QueueModel.productionLabel("agency") == "Agency-routed")
        #expect(QueueModel.productionLabel("unknown") == nil)
    }

    @Test func coverageBadgeOnlyWithSignal() {
        #expect(QueueModel.coverageLabel("likely_uncovered") == "Likely uncovered")
        #expect(QueueModel.coverageLabel("likely_covered") == "Likely covered")
        #expect(QueueModel.coverageLabel("unknown") == nil)
    }
}

@Suite("History flag")
struct HistoryFlagTests {
    @Test func bookedStatedPlainlyWithName() {
        let flag = QueueModel.historyFlag(item(priorRelationship: "booked", matchedClientName: "DCINY"))
        #expect(flag == "Worked together before (DCINY)")
    }

    @Test func contactedNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "contacted")) == "Cold-contacted before, no booking")
    }

    // #1361: a past decline is irrelevant to a future pitch (usually just an old date conflict), so it
    // gets no card badge at all, unlike every other prior-relationship signal.
    @Test func declinedByYouShowsNoBadge() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "declined_by_you")) == nil)
    }

    @Test func warmNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "warm")) == "Warm lead from a prior relationship")
    }

    @Test func lostSoftNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "lost_soft")) == "Lost before, open to the future")
    }

    @Test func lostHardNoted() {
        #expect(QueueModel.historyFlag(item(priorRelationship: "lost_hard")) == "Lost before, not interested")
    }

    @Test func possibleMatchPhrasedAsQuestion() {
        let flag = QueueModel.historyFlag(item(possibleMatchSource: "downbeat_client", possibleMatchName: "Alaria Ensemble"))
        #expect(flag == "Possible match to a past client: Alaria Ensemble?")
    }

    @Test func nilWhenNoSignal() {
        #expect(QueueModel.historyFlag(item()) == nil)
    }
}

@Suite("Lost outcome")
struct LostOutcomeTests {
    @Test func isLostOnlyForLostOutcomes() {
        var soft = item(); soft.outcome = .lostSoft
        var hard = item(); hard.outcome = .lostHard
        var booked = item(); booked.outcome = .booked
        let none = item()
        #expect(soft.isLost)
        #expect(hard.isLost)
        #expect(booked.isLost == false)
        #expect(none.isLost == false)
    }

    @Test func isLostForADerivedLostShowWithNoLeadMark() {
        // Phase F: every contact declined but the lead outcome was never hand-marked; the row should
        // still read as lost, derived from the contacts.
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        r.resolution = .declinedHard
        p.setRecipients([r])
        #expect(p.outcome == .noResponse)   // no lead-level mark
        #expect(QueueItem(p).isLost)        // derived from the declined contact
    }

    @Test func isBookedForAContactBookedShowWithNoLeadMark() {
        // Phase F: a contact marked booked is the single performance-level booking; the row reads as
        // Booked even before the lead outcome is set.
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        r.resolution = .booked
        p.setRecipients([r])
        #expect(p.outcome == .noResponse)   // no lead-level mark
        #expect(QueueItem(p).isBooked)      // derived from the booked contact
    }

    @Test func blankLostReasonClearsToNil() {
        #expect(QueueModel.normalizedLostReason("") == nil)
        #expect(QueueModel.normalizedLostReason("   \n ") == nil)
        #expect(QueueModel.normalizedLostReason("  went with staff photographer ") == "went with staff photographer")
    }
}

@Suite("Timing")
struct TimingTests {
    @Test func countsLocalCalendarDays() {
        #expect(QueueModel.daysUntil(performanceDate: "2026-06-25", today: "2026-06-22") == 3)
        #expect(QueueModel.daysUntil(performanceDate: nil, today: "2026-06-22") == nil)
    }

    @Test func flagsPassedPerformance() {
        #expect(QueueModel.outreachTiming(performanceDate: "2026-06-20", today: "2026-06-22").urgency == .past)
    }

    // Within 4 days reads as too close to realistically book.
    @Test func flagsNearTermAsTooClose() {
        let today = QueueModel.outreachTiming(performanceDate: "2026-06-22", today: "2026-06-22")
        #expect(today.urgency == .tooSoon)
        #expect(today.label.contains("today"))
        let threeDays = QueueModel.outreachTiming(performanceDate: "2026-06-25", today: "2026-06-22")
        #expect(threeDays.urgency == .tooSoon)
        #expect(threeDays.label.contains("3 days"))
    }

    // Dan's call (2026-07-16), after his first walk of the queue: a five-day lead is enough time to
    // pitch, so five days out is bookable and the window closes at four. He set the boundary here
    // knowing it leaves a show four days out demoted.
    @Test func fiveDaysOutIsBookableAndFourIsNot() {
        let fourDays = QueueModel.outreachTiming(performanceDate: "2026-06-26", today: "2026-06-22")
        #expect(fourDays.urgency == .tooSoon)
        let fiveDays = QueueModel.outreachTiming(performanceDate: "2026-06-27", today: "2026-06-22")
        #expect(fiveDays.urgency == .imminent)
        #expect(fiveDays.label.contains("5 days"))
    }

    // #2348: fiveDaysOutIsNotDemoted stood here, asserting through QueueModel.queueOrder that a
    // too-close show keeps its date position rather than sinking (#1014). The queue no longer reorders
    // rows anywhere, so there is no ordering step left to hold to that ruling; the boundary this suite is
    // about still changes the LABEL, which fiveDaysOutIsBookableAndFourIsNot above pins.

    @Test func urgesOutreachJustPastTheTooCloseWindow() {
        let t = QueueModel.outreachTiming(performanceDate: "2026-06-28", today: "2026-06-22")
        #expect(t.urgency == .imminent)
        #expect(t.label.contains("6 days"))
    }

    @Test func suggestsThreeWeeksOutForDistant() {
        #expect(QueueModel.outreachTiming(performanceDate: "2026-08-01", today: "2026-06-22").urgency == .ahead)
    }
}

@Suite("Eastern today")
struct EasternTodayTests {
    // 03:00 UTC on the 25th is still 23:00 on the 24th in New York, so "today" is the 24th.
    @Test func usesNewYorkCalendarDayNotUTC() {
        let lateNightEastern = Date(timeIntervalSince1970: 1782356400) // 2026-06-25T03:00:00Z
        #expect(QueueModel.easternToday(lateNightEastern) == "2026-06-24")
    }
}

// #2348: the "Queue date window" suite stood here, six tests over QueueModel.queueOrder: a past show
// hidden, a show beyond ninety days hidden, one exactly ninety days out kept, a too-close show not
// reordered, an undated show kept, and a detected booking kept past its date. Every one of them asked the
// retired second filter, which #1567 had already taken off every surface, and the app had no caller left
// for it. What is still the product's rule is asserted against the predicate the queue really renders
// from: a past or opened show leaves triage, and an undated one never does, in
// PastShowsLeaveTheScoutQueueTests. There is no ninety-day edge left to test (see the note on
// QueueModel.leadTimeWindowDays).

// #1136: "Drafted by opus" showed twice on a card still in review, once in the row's badge and once
// inside the draft-review panel (next to "Edited"). The panel renders exactly when the item has a draft
// body (hasDraft), and it shows the trace itself, so the row badge only has a job to do once the panel is
// gone (an archived show whose draft body is no longer carried), which is the case #879 built the badge
// for. rowDraftTraceLabel is that rule, pulled out of the SwiftUI row so it can be pinned.
@Suite("The row draft-trace badge yields to the panel (#1136)")
struct RowDraftTraceBadgeTests {
    @Test func hiddenWhileTheDraftPanelIsRendering() {
        var q = item()
        q.draftModel = "opus"
        q.draftBody = "Hello, I photograph performances."   // hasDraft -> the panel renders and shows the trace
        #expect(q.hasDraft)
        #expect(q.rowDraftTraceLabel == nil)
    }

    @Test func shownOnceThePanelIsGone() {
        var q = item()
        q.draftModel = "opus"
        q.draftBody = nil   // no draft body -> the panel does not render, so the badge carries the trace
        #expect(!q.hasDraft)
        #expect(q.rowDraftTraceLabel == "Drafted by opus")
    }

    @Test func nilWithNoModelStamp() {
        var q = item()
        q.draftModel = nil
        q.draftBody = nil
        #expect(q.rowDraftTraceLabel == nil)
    }
}

// #1540, REVERSING #1122: the triage queue's near edge is the run's OPENING night, not its closing one.
//
// #1122 had moved it the other way, on the premise that a run which opened last week but plays through
// next week is still a live, pitchable show. Dan's ruling on 2026-07-26 killed that premise: "if a run
// has started I don't want to see it in the scout queue. If a run started yesterday they probably don't
// need photos anymore." The client's need for photos is effectively over once they have opened.
//
// The cut is `days < 0`, not `days < 1`, and that distinction is Dan's, made after being shown both
// readings of his own words: a show whose opening night is TONIGHT has not started, so it stays and keeps
// reading "Performs today, too close to book". Only a run that opened on an EARLIER day goes.
//
// Scoped to TRIAGE, which is the `.scout` stage: the rule asks the show's STATUS as well as its date, so
// a run Dan kept before it opened keeps working in Prep, Review and Reached out. Hiding work already in
// flight would read as deletion (#1014/#901).
// Those rows still need a label, so `.underway` survives, but Dan's second ruling the same day was that
// nothing in the app may call an opened run BOOKABLE.
@MainActor
@Suite("The triage queue's near edge is the run's opening night (#1540)")
struct MultiDateRunQueueTests {
    private func run(_ open: String?, _ close: String?, key: String = "run") -> QueueItem {
        var q = item(performanceDate: open, key: key)
        q.runEndDate = close
        return q
    }

    // MARK: - The timing label (surface 1)

    // The label a kept, opened run still carries in its stage list. It says the run has started, and it
    // must NOT claim the run is bookable: Dan's whole ruling is that it is not.
    @Test func anOpenedRunReadsAsStartedAndNeverAsBookable() {
        let t = QueueModel.outreachTiming(performanceDate: "2026-07-17", runEndDate: "2026-07-25",
                                          today: "2026-07-20")
        #expect(t.urgency == .underway)
        #expect(t.label != "Performance passed")
        #expect(!t.label.lowercased().contains("bookable"),
                "#1540: an opened run is not bookable, so no label may say it is (was \"\(t.label)\")")
    }

    // Once the CLOSING night is behind us the whole run really has passed.
    @Test func aRunWhoseLastNightHasPassedReadsAsPassed() {
        let t = QueueModel.outreachTiming(performanceDate: "2026-07-10", runEndDate: "2026-07-15",
                                          today: "2026-07-20")
        #expect(t.urgency == .past)
        #expect(t.label == "Performance passed")
    }

    // A single-night show (no runEndDate) is unchanged: judged by its one and only date.
    @Test func aSingleNightShowIsUnchanged() {
        let passed = QueueModel.outreachTiming(performanceDate: "2026-07-17", runEndDate: nil,
                                               today: "2026-07-20")
        #expect(passed.urgency == .past)
        let upcoming = QueueModel.outreachTiming(performanceDate: "2026-07-27", runEndDate: nil,
                                                 today: "2026-07-20")
        #expect(upcoming.urgency == .imminent)
    }

    // displayTiming threads runEndDate through to outreachTiming, and a booking still wins over it.
    @Test func displayTimingCarriesTheRunEndDate() {
        #expect(QueueModel.displayTiming(performanceDate: "2026-07-17", runEndDate: "2026-07-25",
                                         today: "2026-07-20", isBooked: false)
                == QueueModel.outreachTiming(performanceDate: "2026-07-17", runEndDate: "2026-07-25",
                                             today: "2026-07-20"))
        #expect(QueueModel.displayTiming(performanceDate: "2026-07-17", runEndDate: "2026-07-25",
                                         today: "2026-07-20", isBooked: true).urgency == .booked)
    }

    // MARK: - Which shows triage still holds (surface 2)

    // #2348: this half used to ask QueueModel.queueOrder, the retired second filter, which the app had
    // stopped calling. It asks the predicate triage really renders from instead, so each of Dan's rulings
    // below is now pinned against the list he actually sees. `run` builds the QueueItem the label half
    // above uses; here the same dates are put on a Prospect, because membership is decided per prospect.
    private func prospect(_ open: String?, _ close: String?, key: String = "run") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: open, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.runEndDate = close
        return p
    }

    private func triaged(_ prospects: [Prospect], today: String) -> [String] {
        StageNavigation.naturalKeys(for: .scout, in: prospects, today: today)
    }

    // #1540: the run opened three days ago and plays for another five. It is gone from triage.
    @Test func aRunThatOpenedOnAnEarlierDayLeavesTheQueue() {
        #expect(triaged([prospect("2026-07-17", "2026-07-25")], today: "2026-07-20").isEmpty)
    }

    // Dan's line: only a run that has STARTED goes. Tonight's opening has not started, so it stays, with
    // the timing line it has always had. Both halves asserted together because the pair IS the ruling.
    @Test func aShowOpeningTonightStaysAndStillReadsTooClose() {
        #expect(triaged([prospect("2026-07-20", "2026-07-28")], today: "2026-07-20") == ["run"])
        let t = QueueModel.outreachTiming(performanceDate: "2026-07-20", runEndDate: "2026-07-28",
                                          today: "2026-07-20")
        #expect(t.label == "Performs today, too close to book")
        #expect(t.urgency == .tooSoon)
    }

    // A single-night show opening tomorrow is the nearest thing triage still offers.
    @Test func aShowOpeningTomorrowStays() {
        #expect(triaged([prospect("2026-07-21", nil)], today: "2026-07-20") == ["run"])
    }

    // A run whose closing night has passed is dropped, like any other past show.
    @Test func aFullyPastRunIsDropped() {
        #expect(triaged([prospect("2026-07-10", "2026-07-15")], today: "2026-07-20").isEmpty)
    }

    // A single-night past show is still dropped (unchanged): the ordinary case never moved.
    @Test func aSingleNightPastShowIsStillDropped() {
        #expect(triaged([prospect("2026-07-17", nil)], today: "2026-07-20").isEmpty)
    }

    // An UNDATED show keeps its bypass. "Date to be confirmed" is a normal listing state on a season page,
    // and a show with no opening night has not opened: dropping it would silently lose a real lead (#798).
    @Test func anUndatedShowStillBypassesTheNearEdge() {
        #expect(triaged([prospect(nil, nil)], today: "2026-07-20") == ["run"])
    }

    // #2348: aRunOpeningBeyondTheWindowIsStillHeld stood here, asserting that a run opening in December
    // was held out of a July queue by the lead-time window. Nothing applies that window any more (#1567
    // took the last surface off it), so the assertion described only the dead function it called. The
    // near edge, which is what this suite is about, is every test above.
}

@Suite("Grouping and summary")
struct GroupingTests {
    @Test func groupsByDateWithWeekday() {
        let groups = QueueModel.groupByDate([
            item(performanceDate: "2026-06-22"),
            item(performanceDate: "2026-06-22"),
            item(performanceDate: "2026-06-23"),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].weekday == "Mon")
        #expect(groups[0].monthDay == "Jun 22")
        #expect(groups[0].items.count == 2)
    }

    @Test func undatedCollectIntoTBD() {
        let groups = QueueModel.groupByDate([item(performanceDate: nil)])
        #expect(groups[0].monthDay == "Date to be confirmed")
    }

    @Test func summaryCountsTotalAndHigh() {
        let s = QueueModel.summary([item(tier: "high"), item(tier: "longshot"), item(tier: "high")])
        #expect(s.total == 3)
        #expect(s.high == 2)
    }
}

// #1699. Dan's words, walking the queue: he is looking at a card that says `Aug 6` and cannot tell
// whether the night is workable without leaving the app.
//
// The ABSENT case matters at least as much as the present one, and is the majority: only the three native
// readers publish a time at all, so most cards have none. A card with no time must read exactly as it
// does today, so the time is additive information and never a claim, and an untimed show never looks
// worse at triage than a timed one just because of which feed it came from.
@Suite("Start time on the card (#1699)")
struct StartTimeLabelTests {
    @Test func showsAFriendlyClockTimeForASinglePerformance() {
        #expect(ClockTime.listLabel(["19:00"]) == "7:00 PM")
        #expect(ClockTime.listLabel(["21:30"]) == "9:30 PM")
        #expect(ClockTime.listLabel(["11:00"]) == "11:00 AM")
    }

    // #1984's double bills, which are 24 of 274 rows on the two live OvationTix venues. Both are named,
    // because showing one would state the day starts then, and the second show is the whole reason a
    // matinee day is worth telling apart from an evening one.
    @Test func namesBothPerformancesOfADoubleBill() {
        #expect(ClockTime.listLabel(["17:00", "21:15"]) == "5:00 PM and 9:15 PM")
        #expect(ClockTime.listLabel(["11:00", "14:00"]) == "11:00 AM and 2:00 PM")
    }

    // The majority state, and the one that must produce NOTHING rather than a placeholder, a blank
    // separator, or an invented midnight. "This source never said" is not "this show has no start time".
    @Test func saysNothingAtAllWhenNoTimeWasPublished() {
        #expect(ClockTime.listLabel([]) == nil)
    }

    // Noon and midnight are where 12-hour clocks go wrong, and a show really can start at either.
    @Test func readsNoonAndMidnightTheWayAPersonWould() {
        #expect(ClockTime.listLabel(["12:00"]) == "12:00 PM")
        #expect(ClockTime.listLabel(["00:30"]) == "12:30 AM")
    }

    // A value that is not a time yields no label rather than a mangled one. The readers already refuse
    // to store a drifted time, so this is the second net, not the first.
    @Test func aValueThatIsNotATimeIsNotRendered() {
        #expect(ClockTime.listLabel(["7pm"]) == nil)
        #expect(ClockTime.listLabel([""]) == nil)
        #expect(ClockTime.listLabel(["25:00"]) == nil)
    }

    // One unreadable half of a double bill costs only that half; the real time still reaches the card.
    @Test func oneBadTimeDoesNotCostTheGoodOneBesideIt() {
        #expect(ClockTime.listLabel(["19:00", "nonsense"]) == "7:00 PM")
    }
}

// #1699, Dan's rule (2026-08-02): a run whose nights ALL start at the same time states that time beside
// its date range; a run whose nights differ says "Times vary"; a run nobody published a time for says
// nothing, exactly as today.
//
// A run collapses to ONE card showing a date range, so any single time on it is a claim about every night
// of the run. That is why this is decided from all the nights rather than read off the opening one.
// #1699: the ONE string the card puts beside the date, which is what the view calls. Separate from
// ClockTime.listLabel because the card has a third state that a list of times cannot express: a run whose
// nights disagree, which says so instead of showing nothing (Dan's call from the rendered options,
// 2026-08-02).
@Suite("What the card says about start time (#1699)")
struct CardStartTimeTests {
    @Test func aPublishedTimeIsShown() {
        #expect(QueueModel.cardStartTime(startTimes: ["19:00"], timesVary: false) == "7:00 PM")
    }

    @Test func bothTimesOfADoubleBillAreShown() {
        #expect(QueueModel.cardStartTime(startTimes: ["17:00", "21:15"], timesVary: false)
                == "5:00 PM and 9:15 PM")
    }

    // A run whose nights differ SAYS so. Without this it would render identically to a show whose source
    // published nothing, and those are different facts about different things.
    @Test func aRunWhoseNightsDifferSaysTheTimesVary() {
        #expect(QueueModel.cardStartTime(startTimes: [], timesVary: true) == "Times vary")
    }

    // The majority state: nothing published, so nothing said. Not a placeholder, not a blank separator,
    // not an invented midnight. The card must read exactly as it does today.
    @Test func aShowWithNoPublishedTimeSaysNothing() {
        #expect(QueueModel.cardStartTime(startTimes: [], timesVary: false) == nil)
    }

    // Defensive: the scout never stores both, because a time beside "times vary" would contradict itself
    // on one line. If it ever did, the specific time wins over the vaguer sentence.
    @Test func aStoredTimeWinsOverTheVaryFlagIfBothEverArrive() {
        #expect(QueueModel.cardStartTime(startTimes: ["19:00"], timesVary: true) == "7:00 PM")
    }
}

// #1699, Dan's call (2026-08-02) after seeing the real numbers: "Times vary" turned out to be the
// MAJORITY of timed cards (16 of 30 measured against his two live ticketing venues), not the rare edge
// case it was offered as, because almost any run longer than a few nights has a weekend matinee. So the
// card keeps the short honest summary and the detail hangs off a hover, rather than either overstating
// one night or making him leave the app.
@Suite("The per-night times behind Times vary (#1699)")
struct RunNightTimesTooltipTests {
    // Each entry is self-describing ("yyyy-MM-dd HH:mm"), never a second array that has to stay aligned
    // with the nights (the #1523 runNights list is separate and could drift out of step, L15).
    @Test func listsEachNightWithItsTime() {
        let text = QueueModel.nightTimesTooltip(["2026-09-26 15:00", "2026-09-27 11:00"])
        #expect(text == "Sep 26 at 3:00 PM\nSep 27 at 11:00 AM")
    }

    // A night with two performances names both, the same way the single-date card does.
    @Test func aNightWithTwoPerformancesNamesBoth() {
        let text = QueueModel.nightTimesTooltip(["2026-09-27 11:00", "2026-09-27 14:00"])
        #expect(text == "Sep 27 at 11:00 AM and 2:00 PM")
    }

    // Nights come out in date order regardless of the order the feed listed them, because this is read as
    // a schedule.
    @Test func nightsAreListedInDateOrder() {
        let text = QueueModel.nightTimesTooltip(["2026-10-02 19:00", "2026-09-27 14:00"])
        #expect(text == "Sep 27 at 2:00 PM\nOct 2 at 7:00 PM")
    }

    // Nothing to show means no tooltip at all, rather than an empty box on hover.
    @Test func noNightsMeansNoTooltip() {
        #expect(QueueModel.nightTimesTooltip([]) == nil)
    }

    // A malformed entry costs only itself; the real nights still reach Dan.
    @Test func aMalformedEntryDoesNotCostTheRest() {
        #expect(QueueModel.nightTimesTooltip(["nonsense", "2026-09-27 14:00"]) == "Sep 27 at 2:00 PM")
        #expect(QueueModel.nightTimesTooltip(["nonsense"]) == nil)
    }
}

@Suite("A run's start time across its nights (#1699)")
struct RunStartTimesTests {
    @Test func aRunWhoseNightsAllShareOneTimeStatesIt() {
        #expect(RunStartTimes.across([["19:00"], ["19:00"], ["19:00"]]) == .same(["19:00"]))
    }

    // The real shape from The Players Theatre: weeknights at 7:00 PM, a Sunday matinee at 2:00 PM.
    @Test func aRunWhoseNightsDifferSaysSo() {
        #expect(RunStartTimes.across([["19:00"], ["19:00"], ["14:00"]]) == .varies)
    }

    // "Nobody published a time" is NOT "the times differ", and must not borrow that sentence. This is the
    // majority of runs, and it has to keep reading like today's card.
    @Test func aRunWithNoPublishedTimesSaysNothing() {
        #expect(RunStartTimes.across([[], [], []]) == .none)
        #expect(RunStartTimes.across([]) == .none)
    }

    // A run where SOME nights were published and others were not is a run whose nights do not agree, and
    // the honest answer is that they vary rather than promoting one night's time to the whole run.
    @Test func aRunWhereOnlySomeNightsPublishedATimeVaries() {
        #expect(RunStartTimes.across([["19:00"], [], ["19:00"]]) == .varies)
    }

    // A single-night "run" is just a show, and states its own time.
    @Test func aSingleNightKeepsItsOwnTime() {
        #expect(RunStartTimes.across([["19:00"]]) == .same(["19:00"]))
        #expect(RunStartTimes.across([["17:00", "21:15"]]) == .same(["17:00", "21:15"]))
    }

    // Two nights that each carry the SAME double bill agree, so the pair is stated for the whole run.
    @Test func nightsSharingTheSameDoubleBillAgree() {
        #expect(RunStartTimes.across([["17:00", "21:15"], ["17:00", "21:15"]]) == .same(["17:00", "21:15"]))
    }

    // The same times in a different order are the same day's performances, not a different schedule.
    @Test func orderDoesNotMakeTwoNightsDisagree() {
        #expect(RunStartTimes.across([["17:00", "21:15"], ["21:15", "17:00"]]) == .same(["17:00", "21:15"]))
    }

    // One night with a matinee and one without is a real difference Dan would act on, so it varies.
    @Test func anExtraPerformanceOnOneNightCountsAsVarying() {
        #expect(RunStartTimes.across([["19:00"], ["14:00", "19:00"]]) == .varies)
    }
}

@Suite("Run display")
struct RunDisplayTests {
    @Test func formatsADateRangeWhenRunSpansNights() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: "2026-06-28") == "Jun 25 to 28")
    }
    @Test func formatsCrossMonthRange() {
        #expect(QueueModel.runDateLabel(start: "2026-06-28", end: "2026-07-02") == "Jun 28 to Jul 2")
    }
    @Test func showsSingleDateWhenNoRange() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: nil) == "Jun 25")
    }
    @Test func showsSingleDateWhenEndEqualsStart() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: "2026-06-25") == "Jun 25")
    }
    @Test func returnsPlaceholderWhenStartIsNil() {
        #expect(QueueModel.runDateLabel(start: nil, end: nil) == "Date to be confirmed")
    }
    @Test func relatedRunNoteOnlyWhenFlagged() {
        var run = item(performanceDate: "2026-06-25"); run.partOfRelatedRun = true
        #expect(QueueModel.relatedRunNote(run) != nil)
        #expect(QueueModel.relatedRunNote(item(performanceDate: "2026-06-25")) == nil)
    }

    // #939: a same-production show at another venue nearby, so Dan can tell two queue rows are one
    // touring engagement rather than two unrelated leads.
    @Test func noLinkedEngagementNoteWhenThereAreNoLinkedMembers() {
        #expect(QueueModel.linkedEngagementNote(item(performanceDate: "2026-07-25")) == nil)
    }

    @Test func linkedEngagementNoteNamesTheOtherVenueAndDate() {
        var show = item(performanceDate: "2026-07-25")
        show.linkedEngagementMembers = [EngagementLink.Member(venue: "Open Door Senior Center", date: "2026-07-24")]
        #expect(QueueModel.linkedEngagementNote(show) == "This production also plays at Open Door Senior Center on Jul 24.")
    }

    @Test func linkedEngagementNoteFallsBackWhenTheOtherVenueIsUnknown() {
        var show = item(performanceDate: "2026-07-25")
        show.linkedEngagementMembers = [EngagementLink.Member(venue: nil, date: "2026-07-24")]
        #expect(QueueModel.linkedEngagementNote(show) == "This production also plays elsewhere on Jul 24.")
    }

    // #966: a short community-venue tour (3+ stops) names every venue and date, not just a count, so
    // the note is actually informative when a real multi-venue tour shows up.
    @Test func linkedEngagementNoteNamesEveryVenueForMultipleOtherVenues() {
        var show = item(performanceDate: "2026-07-20")
        show.linkedEngagementMembers = [
            EngagementLink.Member(venue: "Venue B", date: "2026-07-22"),
            EngagementLink.Member(venue: "Venue C", date: "2026-07-24"),
        ]
        #expect(QueueModel.linkedEngagementNote(show)
                == "This production also plays at Venue B on Jul 22; at Venue C on Jul 24.")
    }

    @Test func linkedEngagementNoteNamesThreeOrMoreVenues() {
        var show = item(performanceDate: "2026-07-20")
        show.linkedEngagementMembers = [
            EngagementLink.Member(venue: "Venue B", date: "2026-07-22"),
            EngagementLink.Member(venue: "Venue C", date: "2026-07-24"),
            EngagementLink.Member(venue: "Venue D", date: "2026-07-26"),
        ]
        #expect(QueueModel.linkedEngagementNote(show)
                == "This production also plays at Venue B on Jul 22; at Venue C on Jul 24; at Venue D on Jul 26.")
    }

    // An unnamed venue among otherwise-named ones still reads sensibly rather than showing "nil".
    @Test func linkedEngagementNoteHandlesAnUnknownVenueAmongMultiple() {
        var show = item(performanceDate: "2026-07-20")
        show.linkedEngagementMembers = [
            EngagementLink.Member(venue: nil, date: "2026-07-22"),
            EngagementLink.Member(venue: "Venue C", date: "2026-07-24"),
        ]
        #expect(QueueModel.linkedEngagementNote(show)
                == "This production also plays elsewhere on Jul 22; at Venue C on Jul 24.")
    }
}

// #2348: the "Disappeared-from-feed queue filtering (#133)" suite stood here. Its one test asserted
// through QueueModel.queueOrder that an untouched show gone from its feed is HIDDEN, which stopped being
// what Overture does when #1567 moved queue membership to StageNavigation: the Scout list renders that
// show struck through and still offers Keep and Dismiss, and
// QueueShowableIsOneFilterTests.aShowGoneFromTheFeedThatScoutStillRendersOpensInTheQueue pins that. So
// this was not merely testing dead code, it was recording the opposite of the live answer.

// #198: a booked prospect must read as Booked, not as a lead to pitch.
@Suite("Booked display")
struct BookedDisplayTests {
    private func booked() -> QueueItem {
        var q = item(performanceDate: "2026-07-01")
        q.outcome = .booked
        return q
    }

    @Test func bookedOutcomeIsBooked() {
        #expect(booked().isBooked)
        #expect(!item().isBooked)
    }

    @Test func displayTimingReadsBookedRegardlessOfDate() {
        // A booked prospect must never show pitch urgency ("reach out now"); the row reads "Booked".
        let t = QueueModel.displayTiming(performanceDate: "2026-07-01", today: "2026-06-26", isBooked: true)
        #expect(t.label == "Booked")
        #expect(t.urgency == .booked)
    }

    @Test func displayTimingFallsBackToOutreachWhenNotBooked() {
        let today = "2026-06-26"
        #expect(QueueModel.displayTiming(performanceDate: "2026-07-01", today: today, isBooked: false)
                == QueueModel.outreachTiming(performanceDate: "2026-07-01", today: today))
    }

    // #843: a booked row shows "BOOKED" on its seal, so the header's timing token would say it again. On a
    // booked row the header shows only the run date; every other row keeps its timing line.
    @Test func aBookedRowShowsBookedOnceNotInTheTimingLineToo() {
        #expect(QueueModel.headerShowsTimingLine(isBooked: true) == false)
        #expect(QueueModel.headerShowsTimingLine(isBooked: false))
    }

    // The guard and its wiring are two claims (#887): the rule above only holds on screen if the row
    // actually gates the timing line on it. Cut the wire and the "Booked" token comes back with the unit
    // test still green.
    @Test func theRowGatesItsTimingLineOnThatRule() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(row.contains("QueueModel.headerShowsTimingLine(isBooked: item.isBooked)"))
    }
}

// #2348: the "Booked queue placement" suite stood here, two tests over QueueModel.queueOrder for #201's
// rule (a confirmed booking leaves the reach-out queue, an auto-detected one stays until Dan confirms
// it). Both are deleted rather than repointed because there is nothing live to point them at: the only
// implementation of that rule was inside the retired filter, and StageNavigation's own stages are decided
// by status, drafts and send problems, never by the outcome. Recorded here rather than silently dropped,
// because "does a confirmed booking still belong out of the queue" is a product question for Dan and not
// something a deletion should answer on his behalf.

// #1567: the QueueReachabilityTests and DeepLinkReachabilityTests suites lived here. Both asked
// QueueModel whether a show would render in the Queue, through a date window no stage list
// applies, so they pinned an answer that disagreed with the rows Dan actually sees. Whether the
// Queue shows a lead is StageNavigation.opensInQueue now, and QueueShowableIsOneFilterTests holds
// it to the stage lists, carrying over every case these two covered.

// #674: a multi-lead OmniFocus alert's initial auto-scroll must land on a lead that's actually
// still in the focused list, not blindly the first key named in the (possibly stale) notification,
// so a lead dismissed between the notification firing and Dan tapping it doesn't leave the list
// scrolled to nowhere in particular.
@Suite("Focused leads scroll target")
struct FocusedLeadsScrollTargetTests {
    @Test func picksTheFirstKeyThatIsStillVisible() {
        let visible = [item(key: "a"), item(key: "b")]
        #expect(QueueModel.firstVisibleKey(["a", "b"], among: visible) == "a")
    }

    @Test func skipsAKeyNoLongerVisibleAndFallsBackToTheNextOne() {
        // "a" was dismissed since the notification fired and no longer appears in the queue.
        let visible = [item(key: "b")]
        #expect(QueueModel.firstVisibleKey(["a", "b"], among: visible) == "b")
    }

    @Test func returnsNilWhenNoneOfTheKeysAreVisible() {
        let visible = [item(key: "c")]
        #expect(QueueModel.firstVisibleKey(["a", "b"], among: visible) == nil)
    }
}

// #1219/#1246: self double-booking. The detection lives at the QueueModel layer (testable, the #863
// lesson); the views just render it. A commitment is keyed on PERSISTENT facts (booked / emailed / live
// draft), never a mutable stage, and the conflict is computed QUEUE-WIDE so the signal never vanishes when
// a show changes stage. Same groupName is one production. Single tier: any commitment intervenes the same.
@Suite("Self double-booking wiring (#1219)")
struct SelfBookingWiringTests {
    private func booked(_ key: String, _ date: String, _ name: String) -> QueueItem {
        var q = item(performanceDate: date, key: key, groupName: name); q.outcome = .booked; return q
    }
    private func emailed(_ key: String, _ date: String, _ name: String) -> QueueItem {
        var q = item(performanceDate: date, status: .contacted, key: key, groupName: name); q.sentAt = Date(); return q
    }
    private func drafted(_ key: String, _ date: String, _ name: String) -> QueueItem {
        var q = item(performanceDate: date, status: .drafted, key: key, groupName: name); q.draftBody = "Hi"; return q
    }

    // A confirmed booking is a commitment even though confirmBooking sets outcome, not status (red-team FLAW 2).
    @Test func aBookedShowIsACommitment() {
        #expect(QueueModel.selfBookingIsCommitment(booked("a", "2026-08-01", "Org A")))
    }

    // A sent pitch and a live draft/approved are commitments; a kept-but-undrafted or scout candidate is not.
    @Test func sentAndDraftedAreCommitmentsKeptAndScoutAreNot() {
        #expect(QueueModel.selfBookingIsCommitment(emailed("a", "2026-08-01", "Org A")))
        #expect(QueueModel.selfBookingIsCommitment(drafted("b", "2026-08-01", "Org B")))
        var approved = item(status: .approved, key: "c"); approved.draftBody = "Hi"
        #expect(QueueModel.selfBookingIsCommitment(approved))
        #expect(!QueueModel.selfBookingIsCommitment(item(status: .queued, key: "d")))        // kept, no draft
        #expect(!QueueModel.selfBookingIsCommitment(item(status: .new, key: "e")))           // scout
    }

    // #1248: a pitch that was emailed and then marked LOST frees that date again, so it no longer counts as
    // a same-date commitment (a second show on the date must not be warned or blocked by a pitch that went
    // nowhere). A booked outcome still stays a commitment, because booked is decided first and wins.
    @Test func aSentButLostPitchIsNotACommitment() {
        var lostSoft = emailed("a", "2026-08-01", "Org A"); lostSoft.outcome = .lostSoft
        var lostHard = emailed("b", "2026-08-01", "Org B"); lostHard.outcome = .lostHard
        #expect(!QueueModel.selfBookingIsCommitment(lostSoft))
        #expect(!QueueModel.selfBookingIsCommitment(lostHard))
        #expect(QueueModel.selfBookingIsCommitment(booked("c", "2026-08-01", "Org C")))  // booked still wins
    }

    // #1244: the send-confirm self-booking warning is one shared helper, so the main queue's send path and
    // the Archive send path surface a same-date clash identically and can't drift. It names the clashing show
    // when the date already holds a committed OTHER show, and is nil when the date is clear.
    @Test func sendSelfBookingWarningNamesAClashAndIsNilWhenClear() {
        let a = emailed("a", "2026-08-01", "Org A")     // already committed on this date
        let b = drafted("b", "2026-08-01", "Org B")     // a different show on the SAME date
        let clear = drafted("c", "2026-09-09", "Org C") // alone on its own date
        let all = [a, b, clear]
        let warning = QueueModel.sendSelfBookingWarning(for: b, among: all)
        #expect(warning != nil)
        #expect(warning?.contains("Org A") == true)     // names the clashing show
        #expect(QueueModel.sendSelfBookingWarning(for: clear, among: all) == nil)  // clear date, no warning
    }

    // A dead-dismissed show does NOT count (even if it still carries an old draft body) - the latent bug in
    // the first cut; but a show dismissed BECAUSE it was booked elsewhere still counts (red-team FLAW 2).
    @Test func dismissedIsExcludedUnlessBooked() {
        var dead = item(status: .dismissed, key: "a"); dead.draftBody = "Hi"; dead.dismissReason = .notInterested
        #expect(!QueueModel.selfBookingIsCommitment(dead))
        var bookedElsewhere = item(status: .dismissed, key: "b"); bookedElsewhere.dismissReason = .alreadyBooked
        #expect(QueueModel.selfBookingIsCommitment(bookedElsewhere))
        // #1821: "Pitching other shows that night" is NOT a commitment, even though it sounds like one.
        // The show Dan actually picked carries its own commitment on its own row (kept, drafted or sent);
        // counting the ones he passed over as well would warn him of a clash with a show he never pitched.
        var passedOver = item(status: .dismissed, key: "c"); passedOver.dismissReason = .pitchingOtherShows
        #expect(!QueueModel.selfBookingIsCommitment(passedOver))
    }

    // A committed different show on the same date is a conflict; a non-committed one (kept, no draft) is not.
    @Test func aCommittedOtherShowConflictsANonCommittedDoesNot() {
        let target = item(performanceDate: "2026-08-01", key: "b", groupName: "Org B")
        #expect(QueueModel.hasSelfBookingConflict(for: target, among: [emailed("a", "2026-08-01", "Org A"), target]))
        let kept = item(performanceDate: "2026-08-01", status: .queued, key: "c", groupName: "Org C")
        #expect(!QueueModel.hasSelfBookingConflict(for: target, among: [kept, target]))
    }

    // #1246: the date-header NOTE (not just the underlying conflict) must fire cross-stage. A drafted show
    // scanned in the Review stage's date group, whose only same-date clash is an EMAILED show living in
    // another stage (Reached-out/Follow-ups), still shows the note, because the note is computed against the
    // WHOLE queue, not just the current stage's group. This is the exact collision #1246 worried had no
    // header note; the guard goes red if the note is ever rescoped back to the stage group.
    @Test func theDateHeaderNoteFiresWhenTheClashingShowIsInAnotherStage() {
        let reviewGroup = [drafted("b", "2026-08-01", "Org B")]                 // Review's Aug 1 date group
        let wholeQueue = [emailed("a", "2026-08-01", "Org A")] + reviewGroup    // the clash sits elsewhere
        #expect(QueueModel.selfBookingNote(reviewGroup, among: wholeQueue) != nil)
        // With no other same-date commitment anywhere in the queue, no note.
        #expect(QueueModel.selfBookingNote(reviewGroup, among: reviewGroup) == nil)
    }

    // Two rows sharing a groupName are one production (a run), never a self double-booking.
    @Test func theSameProductionOnTheDateDoesNotConflict() {
        let a = emailed("a", "2026-08-01", "The Run")
        let b = item(performanceDate: "2026-08-01", key: "b", groupName: "The Run")
        #expect(!QueueModel.hasSelfBookingConflict(for: b, among: [a, b]))
    }

    // The names of the clashing shows are returned so the warning can say WHICH ones (one or many).
    @Test func conflictNamesListEveryClashingShow() {
        let target = item(performanceDate: "2026-08-01", key: "t", groupName: "Target")
        let all = [emailed("a", "2026-08-01", "Orchestra A"), drafted("b", "2026-08-01", "Choir B"), target]
        #expect(Set(QueueModel.selfBookingConflictNames(for: target, among: all)) == ["Orchestra A", "Choir B"])
    }

    // #1246 (the whole point): the note is QUEUE-WIDE. The other committed show is NOT in this stage's date
    // group but IS elsewhere in the queue, and the note still fires - it does not vanish when a show moves.
    @Test func theHeaderNoteIsQueueWideNotStageScoped() {
        let inGroup = item(performanceDate: "2026-08-01", status: .queued, key: "b", groupName: "Org B")
        let elsewhere = emailed("a", "2026-08-01", "Org A")   // committed, but in another stage/group
        #expect(QueueModel.selfBookingNote([inGroup], among: [inGroup, elsewhere])
                == "Another pitch is already in progress on this date")
        // A clear date (no other commitment anywhere) shows nothing.
        #expect(QueueModel.selfBookingNote([inGroup], among: [inGroup]) == nil)
    }

    // The prep-launch clash check finds every prepping (kept) show that sits on a committed date, naming
    // the clash. Shared by BOTH the batch "Prep these N" sheet and the per-row Re-prep, so neither bypasses
    // the confirm (red-team FLAW 1). A prepping show on a clear date is not listed.
    @Test func prepClashesFindPreppingShowsOnCommittedDates() {
        let committed = emailed("a", "2026-08-01", "Orchestra A")
        let prepping = item(performanceDate: "2026-08-01", status: .queued, key: "p", groupName: "Choir P")
        let clear = item(performanceDate: "2026-08-02", status: .queued, key: "c", groupName: "Solo C")
        let all = [committed, prepping, clear]
        #expect(QueueModel.selfBookingPrepClashes(forKeys: ["p", "c"], among: all)
                == [SelfBookingPrepClash(groupName: "Choir P", conflictNames: ["Orchestra A"])])
        // No selected key clashes -> nothing to confirm.
        #expect(QueueModel.selfBookingPrepClashes(forKeys: ["c"], among: all).isEmpty)
    }

    // The single-row clash powers the Approve and per-row Re-prep confirms: it names the row's committed
    // date-mates, or is nil when the date is clear.
    @Test func selfBookingClashNamesOneRowsConflict() {
        let committed = emailed("a", "2026-08-01", "Orchestra A")
        let target = item(performanceDate: "2026-08-01", key: "t", groupName: "Target")
        #expect(QueueModel.selfBookingClash(for: target, among: [committed, target])
                == SelfBookingPrepClash(groupName: "Target", conflictNames: ["Orchestra A"]))
        let clear = item(performanceDate: "2026-08-02", key: "c", groupName: "Solo")
        #expect(QueueModel.selfBookingClash(for: clear, among: [committed, clear]) == nil)
    }
}

// #1233: the Reached-out stage groups its rows under headers keyed on the REACH-OUT date (when to act),
// not the performance date, keeping the soonest-first order. Generic over the row so the keying and order
// logic is tested without SwiftData; the view passes its (prospect, recipient, next) tuples.
@Suite("Reach-out date grouping (#1233)")
struct ReachOutDateGroupingTests {
    private func at(_ iso: String) -> Date { EasternDate.date(from: iso)! }

    @Test func bucketsByEasternDayPreservingSoonestFirstOrder() {
        let groups = QueueModel.reachOutDateGroups(
            [at("2026-07-24"), at("2026-07-24"), at("2026-07-27")], reachDate: { $0 })
        #expect(groups.count == 2)
        #expect(groups[0].id == "2026-07-24")
        #expect(groups[0].rows.count == 2)          // two contacts due the same reach-out day
        #expect(groups[0].weekday == "Fri")
        #expect(groups[0].monthDay == "Jul 24")
        #expect(groups[0].year == "2026")
        #expect(groups[1].id == "2026-07-27")       // later day comes after: order preserved
        #expect(groups[1].rows.count == 1)
    }

    @Test func emptyInputYieldsNoGroups() {
        #expect(QueueModel.reachOutDateGroups([Date](), reachDate: { $0 }).isEmpty)
    }
}
