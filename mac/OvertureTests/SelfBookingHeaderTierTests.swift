import Testing
import Foundation

// #3676: the date header note may only speak when something on the night is REAL. Dan, 2026-09-07, on the
// Sep 29 header: "this is not quite accurate. Can we reserve this statement for if I've already pitched
// someone? Prepping is not committing to pitching."
//
// Measured against the live store that day, the two rows raising the flag on Sep 29 were `drafted` with a
// draft and no `sentAt`. Nobody had been emailed and the sentence claimed somebody had. Store-wide, 15 of
// the 56 rows the check called a pitch had never been pitched.
//
// His rule, from two answers the same day: the header speaks for an EMAILED pitch still open (in exactly
// today's words, because they are then true), speaks for a BOOKED shoot in its own words (a confirmed
// shoot is not a pitch in progress), and says NOTHING for a prepped-only night. The ROW MARKER is
// untouched: he pointed at "Also pitching Nihao Broadway! on this date" as the thing that already covers a
// prepped show.
//
// Every fixture here pins both ends of its date relationship and reads no clock (L130).
@Suite("The date header only speaks for a real commitment (#3676)")
struct SelfBookingHeaderTierTests {
    private func show(_ key: String, _ nights: [String],
                      _ commitment: SelfBookingConflict.Show.Commitment? = nil,
                      name: String = "Show") -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: key, nights: nights, commitment: commitment,
                                 engagementKey: name, name: name, timesByNight: [:])
    }

    private func claim(_ group: [SelfBookingConflict.Show], on date: String?,
                       among all: [SelfBookingConflict.Show]) -> SelfBookingConflict.HeaderClaim? {
        SelfBookingConflict.headerClaim(for: group, on: date, in: SelfBookingConflict.NightIndex(all))
    }

    // THE DEFECT, as Dan met it. Two prepped shows on one night raise the header, and the sentence says a
    // pitch is in progress when nothing has been sent.
    @Test func aPreppedOnlyNightSaysNothingAtAll() {
        let card = show("card", ["2026-09-29"], nil, name: "Trio Azura")
        let prepped = show("prepped", ["2026-09-29"], .prepped, name: "Nihao Broadway!")
        let found = claim([card], on: "2026-09-29", among: [card, prepped])
        #expect(found?.commitment == .prepped)
        #expect(SelfBookingCopy.dateHeaderNote(found) == nil)
    }

    // An emailed pitch still open keeps TODAY'S EXACT SENTENCE. Dan: "If I've already emailed someone and
    // that show is not closed out, it should say exactly what it says now."
    @Test func anEmailedPitchKeepsTodaysSentence() {
        let card = show("card", ["2026-09-29"])
        let sent = show("sent", ["2026-09-29"], .emailed, name: "Orchestra A")
        #expect(SelfBookingCopy.dateHeaderNote(claim([card], on: "2026-09-29", among: [card, sent]))
                == "Another pitch is already in progress on this date")
    }

    // A booked shoot gets its OWN sentence. A confirmed shoot is not a pitch in progress, and it is the
    // strongest reason of all not to double up the night (Dan's call, 2026-09-07, from a picker).
    @Test func aBookedShootGetsItsOwnSentence() {
        let card = show("card", ["2026-09-29"])
        let booked = show("booked", ["2026-09-29"], .booked, name: "Orchestra A")
        #expect(SelfBookingCopy.dateHeaderNote(claim([card], on: "2026-09-29", among: [card, booked]))
                == "You are already shooting another show on this date")
    }

    // The run variants split the same way, so there are FOUR header sentences and not two. A clash on a
    // later night of a run in the group may not say "on this date": that would be a claim about the header
    // it sits under that the check never measured (#1501, #3323).
    @Test func bothSentencesHaveARunVariant() {
        let run = show("run", ["2026-09-29", "2026-09-30"])
        let sentLater = show("sent", ["2026-09-30"], .emailed, name: "Orchestra A")
        #expect(SelfBookingCopy.dateHeaderNote(claim([run], on: "2026-09-29", among: [run, sentLater]))
                == "Another pitch is already in progress on a night one of these runs plays")
        let bookedLater = show("booked", ["2026-09-30"], .booked, name: "Choir B")
        #expect(SelfBookingCopy.dateHeaderNote(claim([run], on: "2026-09-29", among: [run, bookedLater]))
                == "You are already shooting another show on a night one of these runs plays")
    }

    // A night holding BOTH kinds speaks for the BOOKED one: it is the stronger fact and the stronger reason
    // not to double up. Deliberately decided rather than left to whichever show sorts first, because an
    // order-dependent sentence would change between redraws.
    @Test func bookedOutranksEmailedWhenTheNightHoldsBoth() {
        let card = show("card", ["2026-09-29"])
        let sent = show("sent", ["2026-09-29"], .emailed, name: "Orchestra A")
        let booked = show("booked", ["2026-09-29"], .booked, name: "Choir B")
        #expect(SelfBookingCopy.dateHeaderNote(claim([card], on: "2026-09-29", among: [card, sent, booked]))
                == "You are already shooting another show on this date")
        #expect(SelfBookingCopy.dateHeaderNote(claim([card], on: "2026-09-29", among: [card, booked, sent]))
                == "You are already shooting another show on this date")
    }

    // A prepped clash sitting BESIDE an emailed one does not drag the header down to silence: the emailed
    // show is still a real pitch in progress and the sentence is still true of it.
    @Test func aPreppedClashDoesNotSilenceAnEmailedOne() {
        let card = show("card", ["2026-09-29"])
        let prepped = show("prepped", ["2026-09-29"], .prepped, name: "Nihao Broadway!")
        let sent = show("sent", ["2026-09-29"], .emailed, name: "Orchestra A")
        #expect(SelfBookingCopy.dateHeaderNote(claim([card], on: "2026-09-29", among: [card, prepped, sent]))
                == "Another pitch is already in progress on this date")
    }

    // The date scope is measured over the clashes AT THE TIER BEING SPOKEN FOR, so the sentence is as
    // specific as the evidence behind it. A booked clash on the header's own date says "on this date" even
    // when a prepped show the header never mentions sits on a later night of the run.
    @Test func theDateScopeIsMeasuredAtTheTierBeingSpokenFor() {
        let run = show("run", ["2026-09-29", "2026-09-30"])
        let bookedHere = show("booked", ["2026-09-29"], .booked, name: "Orchestra A")
        let preppedLater = show("prepped", ["2026-09-30"], .prepped, name: "Choir B")
        #expect(SelfBookingCopy.dateHeaderNote(claim([run], on: "2026-09-29",
                                                     among: [run, bookedHere, preppedLater]))
                == "You are already shooting another show on this date")
    }

    // A group with no clash at all produces no claim, so the caller cannot be handed a tier to speak for.
    @Test func aClearNightProducesNoClaim() {
        let card = show("card", ["2026-09-29"])
        let elsewhere = show("other", ["2026-10-05"], .emailed, name: "Orchestra A")
        #expect(claim([card], on: "2026-09-29", among: [card, elsewhere]) == nil)
        #expect(SelfBookingCopy.dateHeaderNote(nil) == nil)
    }

    // An UNKNOWN header date cannot claim "on this date", exactly as before: it falls to the run wording
    // rather than asserting a date nothing measured (L11).
    @Test func anUnknownHeaderDateFallsToTheRunWording() {
        let card = show("card", ["2026-09-29"])
        let sent = show("sent", ["2026-09-29"], .emailed, name: "Orchestra A")
        #expect(SelfBookingCopy.dateHeaderNote(claim([card], on: nil, among: [card, sent]))
                == "Another pitch is already in progress on a night one of these runs plays")
    }
}

// The queue-row half: which tier a row carries, and that the header note built from real rows obeys it.
@Suite("A queue row's commitment tier (#3676)")
struct SelfBookingCommitmentTierTests {
    // `item(...)` in QueueModelTests is private to that file, so this suite builds its own rows.
    private func row(_ key: String, _ date: String?, _ name: String,
                     status: ReviewStatus = .new) -> QueueItem {
        QueueItem(
            id: key, groupName: name, discipline: "music", venue: "Weill Recital Hall",
            performanceDate: date, sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status
        )
    }
    private func drafted(_ key: String, _ date: String, _ name: String) -> QueueItem {
        var q = row(key, date, name, status: .drafted)
        q.draftBody = "Hi"
        return q
    }
    private func emailed(_ key: String, _ date: String, _ name: String) -> QueueItem {
        var q = row(key, date, name, status: .contacted)
        q.sentAt = Date()
        return q
    }
    private func booked(_ key: String, _ date: String, _ name: String) -> QueueItem {
        var q = row(key, date, name)
        q.outcome = .booked
        return q
    }

    // The four arms of the old boolean, each now naming WHICH commitment it is, in the same order the
    // boolean decided them so no row changes whether it collides at all.
    @Test func eachArmOfTheOldPredicateNamesItsTier() {
        #expect(QueueModel.selfBookingCommitment(booked("a", "2026-09-29", "Org A")) == .booked)
        var elsewhere = row("b", nil, "Org B", status: .dismissed)
        elsewhere.showOutcome = .hadPaidWork
        #expect(QueueModel.selfBookingCommitment(elsewhere) == .booked)
        #expect(QueueModel.selfBookingCommitment(emailed("c", "2026-09-29", "Org C")) == .emailed)
        #expect(QueueModel.selfBookingCommitment(drafted("d", "2026-09-29", "Org D")) == .prepped)
        var approved = row("e", "2026-09-29", "Org E", status: .approved)
        approved.draftBody = "Hi"
        #expect(QueueModel.selfBookingCommitment(approved) == .prepped)
        #expect(QueueModel.selfBookingCommitment(row("f", "2026-09-29", "Org F", status: .queued)) == nil)
        #expect(QueueModel.selfBookingCommitment(row("g", "2026-09-29", "Org G")) == nil)
    }

    // WHICH ROWS COLLIDE IS UNCHANGED. This issue narrows one sentence, not the check: a prepped show still
    // raises the row marker, the send confirm and the prep confirm exactly as it did.
    @Test func preppingStillCollidesEverywhereElse() {
        let target = row("t", "2026-09-29", "Trio Azura", status: .queued)
        let prepped = drafted("p", "2026-09-29", "Nihao Broadway!")
        let index = QueueModel.selfBookingIndex([target, prepped])
        #expect(QueueModel.hasSelfBookingConflict(for: target, in: index))
        #expect(QueueModel.selfBookingRowMarker(for: target, in: index)
                == "Also pitching Nihao Broadway! on this date")
        #expect(QueueModel.sendSelfBookingWarning(for: target, in: index) != nil)
    }

    // ...and the header, over the same rows, now says nothing. This is the pair that makes the change a
    // narrowing of one sentence rather than of the check.
    @Test func theHeaderIsSilentOverThoseSameRows() {
        let target = row("t", "2026-09-29", "Trio Azura", status: .queued)
        let prepped = drafted("p", "2026-09-29", "Nihao Broadway!")
        #expect(QueueModel.selfBookingNote([target], on: "2026-09-29",
                                           in: QueueModel.selfBookingIndex([target, prepped])) == nil)
    }

    @Test func theHeaderSpeaksForAnEmailedRowAndForABookedOne() {
        let target = row("t", "2026-09-29", "Trio Azura", status: .queued)
        let sent = emailed("s", "2026-09-29", "Orchestra A")
        #expect(QueueModel.selfBookingNote([target], on: "2026-09-29",
                                           in: QueueModel.selfBookingIndex([target, sent]))
                == "Another pitch is already in progress on this date")
        let shoot = booked("b", "2026-09-29", "Choir B")
        #expect(QueueModel.selfBookingNote([target], on: "2026-09-29",
                                           in: QueueModel.selfBookingIndex([target, shoot]))
                == "You are already shooting another show on this date")
    }
}
