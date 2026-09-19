import Testing
import Foundation

// #3622: a blocked LATER night of a run is no longer spoken on the cards, the date headers or the send
// confirm. Dan, 2026-09-18: "it can go from pretty much everywhere. the only place that would matter is on
// a multi-run prep where I'm selecting the nights to pitch so I'd want to see it there." And the same day,
// on the self double booking lines: remove them too, everywhere except that picker.
//
// The Prep launch confirm keeps both kinds until the per-night picker (#3325) ships, because until then it
// is the only thing between a partly blocked run and the spend of a prep run on it.
@Suite("A later night of a run stays off the card (#3622)")
struct LaterNightStaysOffTheCardTests {

    private func row(_ key: String, _ date: String, nights: [String] = [], name: String = "The Lantern Cabaret",
                     status: ReviewStatus = .new, sent: Bool = false) -> QueueItem {
        var q = QueueItem(
            id: key, groupName: name, discipline: "music", venue: "The Tin Room", performanceDate: date,
            sourceListingURL: nil,
            priorRelationship: "none", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status
        )
        q.runNights = nights
        if sent { q.sentAt = Date(timeIntervalSince1970: 1_786_000_000) }
        return q
    }

    // A run filed under Oct 27 whose Oct 29 is blocked, as the scout writes it.
    private func blockedLater(status: ReviewStatus = .new, uncleared: Bool = true) -> QueueItem {
        var q = row("run", "2026-10-27", nights: ["2026-10-27", "2026-10-29"], status: status)
        q.conflictBlockedDate = "2026-10-29"
        q.conflictNote = "A later night of this run is out: you blocked Oct 29 (Invented Retreat)."
        q.hasUnclearedConflict = uncleared
        return q
    }

    // MARK: the calendar sentence

    @Test("an untriaged card says nothing about a blocked later night")
    func anUntriagedCardIsQuiet() {
        #expect(QueueModel.cardConflictNote(blockedLater()) == nil)
    }

    @Test("a kept card whose later night was accepted says nothing either")
    func aKeptAcceptedCardIsQuiet() {
        #expect(QueueModel.cardConflictNote(blockedLater(status: .drafted, uncleared: false)) == nil)
    }

    @Test("a blocked night the card is filed under is still spoken, exactly as before")
    func thisNightIsUnchanged() {
        var q = row("one", "2026-10-27")
        q.conflictBlockedDate = "2026-10-27"
        q.conflictNote = "You blocked Oct 27 (Invented Retreat)."
        q.hasUnclearedConflict = true
        #expect(QueueModel.cardConflictNote(q) == "You blocked Oct 27 (Invented Retreat).")
    }

    // The one case the sentence still carries weight on a card: the clash holds the send, and the control
    // that releases it sits beside the sentence (L109).
    @Test("a kept card whose later night is still holding the send keeps the sentence")
    func aHeldSendKeepsItsReason() {
        #expect(QueueModel.cardConflictNote(blockedLater(status: .drafted, uncleared: true)) != nil)
    }

    @Test("the Prep launch confirm still names a blocked later night until the per-night picker ships")
    func thePrepConfirmStillNamesIt() {
        let q = blockedLater(status: .queued)
        let clashes = QueueModel.calendarClashesForPrep(forKeys: ["run"], among: [q])
        #expect(clashes.map(\.note) == ["A later night of this run is out: you blocked Oct 29 (Invented Retreat)."])
    }

    // MARK: the self double booking lines

    private let run = ["2026-10-27", "2026-10-29"]

    @Test("a row whose only clash is on a later night carries no self booking marker")
    func theRowIsQuietAboutALaterNight() {
        let target = row("run", "2026-10-27", nights: run)
        let other = row("c", "2026-10-29", nights: ["2026-10-29"], name: "Orchestra Invented", sent: true)
        let index = QueueModel.selfBookingIndex([other, target])
        #expect(QueueModel.selfBookingRowMarker(for: target, in: index) == nil)
    }

    @Test("a clash on the row's own night still reads on this date")
    func theOwnNightIsUnchanged() {
        let target = row("run", "2026-10-27", nights: run)
        let other = row("c", "2026-10-27", nights: ["2026-10-27"], name: "Orchestra Invented", sent: true)
        let index = QueueModel.selfBookingIndex([other, target])
        #expect(QueueModel.selfBookingRowMarker(for: target, in: index)
                == "Also pitching Orchestra Invented on this date")
        #expect(QueueModel.sendSelfBookingWarning(for: target, in: index)
                == "You already have a pitch in progress for Orchestra Invented on this date.")
    }

    @Test("the date header says nothing when the only clash is on a later night of a run filed there")
    func theHeaderIsQuietAboutALaterNight() {
        let target = row("run", "2026-10-27", nights: run)
        let other = row("c", "2026-10-29", nights: ["2026-10-29"], name: "Orchestra Invented", sent: true)
        let index = QueueModel.selfBookingIndex([other, target])
        #expect(QueueModel.selfBookingNote([target], on: "2026-10-27", in: index) == nil)
    }

    @Test("the send confirm says nothing about a later night")
    func theSendConfirmIsQuietAboutALaterNight() {
        let target = row("run", "2026-10-27", nights: run)
        let other = row("c", "2026-10-29", nights: ["2026-10-29"], name: "Orchestra Invented", sent: true)
        let index = QueueModel.selfBookingIndex([other, target])
        #expect(QueueModel.sendSelfBookingWarning(for: target, in: index) == nil)
    }

    @Test("the Prep launch confirm still names a self booking clash on a later night")
    func thePrepConfirmStillNamesTheSelfBookingClash() {
        let target = row("run", "2026-10-27", nights: run)
        let other = row("c", "2026-10-29", nights: ["2026-10-29"], name: "Orchestra Invented", sent: true)
        let clashes = QueueModel.selfBookingPrepClashes(forKeys: ["run"], among: [other, target])
        #expect(SelfBookingCopy.prepConfirmMessage(clashes)
                == "The Lantern Cabaret plays Oct 29, when you already have a pitch in progress for Orchestra Invented.")
    }
}
