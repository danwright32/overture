import Testing
import Foundation
import SwiftData

// #2900: a show Dan has closed out went on minting an OmniFocus reply triage task for ever, because
// nothing that reads "is this reply outstanding?" could see a show-level ending at all.
// `Recipient.hasUnhandledReply` reads contact-level fields only, and `recordOutcome` deliberately
// writes the ending onto the SHOW and nothing onto the contacts (#2396, L83). So the question was
// answerable and unasked, except in `Prospect.hasUnhandledReply`, which answered it by hand for
// exactly one ending (`performanceStatus != .booked`) at exactly one call site.
//
// Decided once now, in `Prospect.hasRecordedEnding`, and read by `Recipient.hasUnhandledReply`, so
// every one of its thirteen readers inherits the answer instead of thirteen chances to forget it
// (L16). Overture's OWN two endings do not count: `wentBy` is the calendar passing, not a decision,
// and a person who writes after their show went by is still owed an answer.
@Suite("A reply on a closed out show")
struct AReplyOnAClosedOutShowTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String = "an evening of song|2026-09-04|the corner room") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Corner Room Collective", discipline: "choral",
                         venue: "the corner room", performanceDate: "2026-09-04", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    // A contact who was pitched and has written back, with nobody having answered them.
    @discardableResult
    private func repliedContact(_ ctx: ModelContext, on p: Prospect, now: Date) -> Recipient {
        let r = Recipient(id: "booking@example.invalid", email: "booking@example.invalid", provenance: .act)
        r.sentAt = now.addingTimeInterval(-86_400 * 5)
        r.sendState = .sent
        r.gmailMessageId = "msg-1"
        r.replied = true
        r.inboundReplySentAt = now.addingTimeInterval(-3_600)   // what `replyArrivedAt` derives from
        r.prospect = p
        p.recipients.append(r)
        return r
    }

    // MARK: - The predicate itself

    @Test func aReplyIsOutstandingWhileTheShowHasNoEnding() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)

        #expect(r.hasUnhandledReply)
        #expect(p.hasUnhandledReply)
        #expect(!p.hasRecordedEnding)
    }

    // Every ending Dan can choose closes it, the never-pitched half included: they are all statements
    // that this show is over. Exhaustive over the vocabulary rather than a sample, so an ending added
    // later cannot quietly land on the wrong side of this rule.
    @Test func everyEndingDanCanChooseClosesTheReply() throws {
        for ending in ShowOutcome.danCanChoose {
            let ctx = ModelContext(try container())
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let p = show(ctx)
            let r = repliedContact(ctx, on: p, now: now)
            p.showOutcome = ending

            #expect(p.hasRecordedEnding, "\(ending.rawValue) should read as an ending Dan recorded")
            #expect(!r.hasUnhandledReply, "\(ending.rawValue) should close the reply")
            #expect(!p.hasUnhandledReply, "\(ending.rawValue) should close the reply")
        }
    }

    // Overture's own two are not decisions. `wentBy` is the show's last night passing while the row sat
    // untriaged, and somebody who wrote to Dan is still owed an answer whatever the calendar did.
    @Test func overturesOwnEndingsLeaveTheReplyOutstanding() throws {
        for ending in ShowOutcome.allCases where ending.isOverturesOwn {
            let ctx = ModelContext(try container())
            let now = Date(timeIntervalSince1970: 1_780_000_000)
            let p = show(ctx)
            let r = repliedContact(ctx, on: p, now: now)
            p.showOutcome = ending

            #expect(!p.hasRecordedEnding, "\(ending.rawValue) is Overture's own, not an ending Dan recorded")
            #expect(r.hasUnhandledReply, "\(ending.rawValue) must not close a reply")
        }
    }

    // A booking recorded on the CONTACT rather than on the show. This is the case
    // `Prospect.hasUnhandledReply` used to carry by hand, at one call site; it now holds for every
    // reader, which is the whole point of moving it.
    @Test func aBookingRecordedOnTheContactClosesTheReplyForEveryReader() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        r.resolution = .booked
        // A booked contact's own resolution already closes it; the show-level read is what changed.
        #expect(p.isBooked)
        #expect(p.hasRecordedEnding)
        #expect(!p.hasUnhandledReply)
    }

    // Taking the ending back has to start it asking again. `reopenOutcome` clears `showOutcome`, and
    // because this is derived rather than mirrored onto the contacts there is nothing else to undo.
    @Test func reopeningTheShowMakesTheReplyOutstandingAgain() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        let r = repliedContact(ctx, on: p, now: now)
        p.showOutcome = .theySaidNo
        #expect(!r.hasUnhandledReply)

        p.showOutcome = nil
        #expect(r.hasUnhandledReply)
        #expect(p.hasUnhandledReply)
    }

    // A contact with no show wired at all (every bare-Recipient unit test) is unaffected: there is no
    // ending to read, and reading the absence as an ending would close every one of them.
    @Test func aContactWithNoShowIsUnaffected() {
        let r = Recipient(id: "a@example.invalid", email: "a@example.invalid", provenance: .act)
        r.replied = true
        #expect(r.hasUnhandledReply)
    }

    // MARK: - The reader this was filed from

    // The live shape of #2900: close a pitched show out from the Mark menu and the OmniFocus sync goes
    // on minting a triage task for a contact whose reply nobody answered, for ever, about a show that
    // has an ending recorded against it.
    @Test func aClosedOutShowMintsNoOmniFocusTriageTask() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let p = show(ctx)
        repliedContact(ctx, on: p, now: now)

        #expect(OmniFocusSync.desired(from: [p], now: now, horizonDays: 14).count == 1)

        p.showOutcome = .turnedThemDown
        #expect(OmniFocusSync.desired(from: [p], now: now, horizonDays: 14).isEmpty)
    }
}
