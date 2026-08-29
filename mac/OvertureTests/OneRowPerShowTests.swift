import Testing
import Foundation
import SwiftData

// #2396, phase 3 of docs/plans/2026-08-09-one-outcome-vocabulary.md.
//
// Dan judges shows, not contacts: "I really don't care about contact level outcomes. All I care about is
// the event level. Contact only matters because it might tell me who to reach out to in the future."
//
// Measured on the live store 2026-08-09: 4 of the 5 pitched shows have exactly one sent contact, so this
// changes almost nothing on screen today. The capability that makes it bite has already shipped (#2031, one
// email to several contacts), and one show in the store already carries 17 contacts.
//
// Note this REVERSES the model built in #389/#447, where outcomes lived on contacts and the show's status
// was derived from them. The show is the home now; contacts keep only routing facts.
@MainActor
@Suite("The Reached out row is one row per show (#2396)")
struct OneRowPerShowTests {

    private let sentAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G\(key)", discipline: "music", venue: "V",
                         performanceDate: "2030-11-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, email: String,
                         sentAt: Date? = nil, replied: Bool = false,
                         threadId: String? = nil) -> Recipient {
        let r = Recipient(id: email, email: email, provenance: .manual)
        r.sendState = .sent
        r.sentAt = sentAt ?? self.sentAt
        r.gmailMessageId = "m-\(email)"
        r.gmailThreadId = threadId
        if replied { r.reopenOnReply(at: self.sentAt.addingTimeInterval(3_600)) }
        r.prospect = p
        ctx.insert(r)
        return r
    }

    private var laterOn: Date { sentAt.addingTimeInterval(30 * 86_400) }

    // MARK: one row

    // Three contacts, three separate emails, one show. Before this the stage drew a row for each, and Dan
    // had to decide the same thing three times about one event.
    @Test func threeContactsOnOneShowDrawOneRow() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "a@b.com")
        contact(ctx, on: p, email: "b@b.com")
        contact(ctx, on: p, email: "c@b.com")

        let rows = ReachedOutQueue.activeWithDates(from: [p], now: laterOn)

        #expect(rows.count == 1)
    }

    // And the pill's number is now the same quantity as the rows beneath it, which is what the reconciling
    // note (#1232) existed to explain away.
    @Test func thepillsNumberNowMatchesTheRows() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "a@b.com")
        contact(ctx, on: p, email: "b@b.com")
        let q = show(ctx, key: "k2")
        contact(ctx, on: q, email: "d@b.com")

        let rows = ReachedOutQueue.activeWithDates(from: [p, q], now: laterOn)

        #expect(rows.count == 2)
        #expect(ReachedOutQueue.showCount(from: [p, q], now: laterOn) == rows.count)
    }

    // MARK: who the row speaks for

    // "The row must still name WHO replied when someone does, and answering must still go back to that
    // person." So when somebody has written back, the row's contact is that person and not whichever
    // address happens to sort first.
    @Test func therowNamesTheContactWhoReplied() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "aaa@b.com")                  // sorts first, never answered
        contact(ctx, on: p, email: "zzz@b.com", replied: true)    // the person who wrote

        let rows = ReachedOutQueue.activeWithDates(from: [p], now: laterOn)

        #expect(rows.count == 1)
        #expect(rows.first?.recipient.email == "zzz@b.com")
    }

    // With nobody having replied there is no such person, so the row speaks for whichever contact is due
    // soonest: that is the one the row's own action is about.
    //
    // #2366: this test's verdict DOES change when its show is pulled towards its own pinned clock, and
    // it is in `fixtures/far-future-sensitive-tests.txt` for that reason. Not a defect: the show has to
    // be genuinely ahead for the row to be active at all, and the assertion is about WHICH contact the
    // row speaks for, not about where the show sits. Recorded so the next sweep does not re-litigate it.
    @Test func withNoReplyTherowSpeaksForTheContactDueSoonest() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "later@b.com", sentAt: sentAt.addingTimeInterval(20 * 86_400))
        contact(ctx, on: p, email: "sooner@b.com", sentAt: sentAt)

        let rows = ReachedOutQueue.activeWithDates(from: [p], now: laterOn)

        #expect(rows.first?.recipient.email == "sooner@b.com")
    }

    // The row's date is the soonest across the show's contacts, so a show cannot sit lower in the list than
    // its most urgent contact deserves.
    @Test func therowsDateIsTheSoonestAcrossTheShow() throws {
        let ctx = try context()
        let p = show(ctx)
        let soon = contact(ctx, on: p, email: "sooner@b.com", sentAt: sentAt)
        contact(ctx, on: p, email: "later@b.com", sentAt: sentAt.addingTimeInterval(20 * 86_400))

        let rows = ReachedOutQueue.activeWithDates(from: [p], now: laterOn)
        let soonest = ReachedOutQueue.nextReachOut(for: soon, of: p, now: laterOn)

        #expect(rows.first?.next == soonest)
    }

    // MARK: the ending takes the show off the stage

    // The one field decides this now, on its own. This is what lets the contact-level mirror #2395 left in
    // place come out: nothing has to be written onto a contact for the row to leave.
    @Test func ashowCarryingAnEndingLeavesTheStage() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "a@b.com")
        #expect(!ReachedOutQueue.activeWithDates(from: [p], now: laterOn).isEmpty)

        p.showOutcome = .theySaidNotNow

        #expect(ReachedOutQueue.activeWithDates(from: [p], now: laterOn).isEmpty)
    }

    // Every one of the five pitched endings takes it off, not just the ones that happen to have a
    // contact-level twin.
    @Test func everyPitchedEndingTakesTheShowOff() throws {
        for ending in ShowOutcome.pitched {
            let ctx = try context()
            let p = show(ctx)
            contact(ctx, on: p, email: "a@b.com")
            p.showOutcome = ending

            #expect(ReachedOutQueue.activeWithDates(from: [p], now: laterOn).isEmpty,
                    "\(ending.label) left the show on the stage")
        }
    }

    // Reopening puts it back, because nothing is closed unless Dan closed it and taking that back has to
    // return the work to where he will see it.
    @Test func reopeningPutsTheShowBackOnTheStage() throws {
        let ctx = try context()
        let p = show(ctx)
        contact(ctx, on: p, email: "a@b.com")
        p.showOutcome = .neverHeardBack
        #expect(ReachedOutQueue.activeWithDates(from: [p], now: laterOn).isEmpty)

        p.showOutcome = nil

        #expect(!ReachedOutQueue.activeWithDates(from: [p], now: laterOn).isEmpty)
    }
}

// The other half of phase 3: the derived status reads the SHOW's ending rather than needing it copied onto
// each contact. That copy was the transitional mirror #2395 declared and this removes.
@MainActor
@Suite("A show's status reads its own ending (#2396)")
struct PerformanceStatusReadsTheShowTests {

    private func pitchedShow(_ ending: ShowOutcome?) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2030-11-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = Date()
        p.showOutcome = ending
        return p
    }

    // No contact carries anything, and the status is still right, which is the whole point: the ending has
    // one home and every reader goes to it.
    @Test func theendingAloneDecidesTheStatus() {
        #expect(PerformanceStatus.of(pitchedShow(.booked)) == .booked)
        #expect(PerformanceStatus.of(pitchedShow(.theySaidNotNow)) == .lostDoorOpen)
        #expect(PerformanceStatus.of(pitchedShow(.neverHeardBack)) == .lostDoorOpen)
        #expect(PerformanceStatus.of(pitchedShow(.theySaidNo)) == .lostNotInterested)
        #expect(PerformanceStatus.of(pitchedShow(.turnedThemDown)) == .stoodDown)
    }

    // A silence leaves the door open exactly as a soft no does. It is a distinct RECORD, so the reporting
    // can tell "they said not now" from "nobody answered", and the same STATUS, because neither is a
    // refusal.
    @Test func asilenceAndAsoftNoReadAsTheSameStatusAndDifferentRecords() {
        #expect(PerformanceStatus.of(pitchedShow(.neverHeardBack))
                == PerformanceStatus.of(pitchedShow(.theySaidNotNow)))
        #expect(pitchedShow(.neverHeardBack).showOutcome != pitchedShow(.theySaidNotNow).showOutcome)
    }

    // A show with no ending still derives from its contacts, so nothing that was working before this stops
    // working: the show-level read is a precedence, not a replacement.
    @Test func withNoEndingItStillDerivesFromTheContacts() {
        let p = pitchedShow(nil)
        #expect(PerformanceStatus.of(p) == .new, "no contacts, nothing sent from any of them")
    }

    // A never-pitched ending says nothing about a pitch, so it must not be read as a pitch outcome. Those
    // shows are spoken for by being dismissed, which Archive already gives its own bucket.
    @Test func aneverPitchedEndingIsNotAPitchStatus() {
        for ending in ShowOutcome.neverPitched + [.wentBy, .tooFar] {
            #expect(PerformanceStatus.of(pitchedShow(ending)) == .new,
                    "\(ending.label) was read as a pitch outcome")
        }
    }
}
