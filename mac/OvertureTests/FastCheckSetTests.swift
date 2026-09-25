import Foundation
import SwiftData
import Testing

// #3937, phase 1 of #2920: the fast check set, derived from the watched set.
//
// The fast lane reads a conversation with a live reply, or a pitch whose run has not passed, and it is
// the SAME collection function as the watched set with a narrower predicate (`threadsToCheck(in:fastOnly:)`),
// so it can never reach a thread the watched set would not. Each test below asserts BOTH sets, because a
// row falling out of the fast set is only correct while it is still watched.
//
// The people, shows and addresses below are invented. Nothing here is anybody's real conversation.
@MainActor
@Suite("The fast check set is derived from the watched set (#3937)")
struct FastCheckSetTests {
    // 2026-09-16 at noon Eastern, the day the plan's figures were measured.
    private let now = Date(timeIntervalSince1970: 1_789_574_400)
    private let longPassed = "2025-03-01"
    private let upcoming = "2026-10-25"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String, date: String?, runEnd: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Harborlight Chorale \(key)", discipline: "choral",
                         venue: "Rivercrest Hall", performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.runEndDate = runEnd
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, thread: String, replied: Bool = false) -> Recipient {
        let email = "\(thread)@example.com"
        let r = Recipient(id: email, email: email, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "msg-\(thread)"
        r.gmailThreadId = thread
        r.sendGroupId = thread
        if replied {
            r.replied = true
            r.repliedAt = Date(timeIntervalSince1970: 5_000)
            // Everything the gap asks for is already on file, so this row is watched ONLY because its
            // conversation is open, never because a refetch could fill something (`ReplyGap`).
            r.lastReplyId = "reply-\(thread)"
            r.lastReplyText = "Thanks for writing, tell me more."
            r.replyFromAddress = email
            r.inboundReplySentAt = Date(timeIntervalSince1970: 4_000)
            r.replyTextCheckedAt = Date(timeIntervalSince1970: 5_000)
        }
        p.addRecipient(r)
        return r
    }

    private func inquiry(_ ctx: ModelContext, thread: String, date: String?) -> Inquiry {
        let i = Inquiry(source: .directEmail, inquirerName: "Priya Raman", inquirerEmail: "\(thread)@example.com",
                        eventName: "Spring gala", performanceDate: date, createdAt: Date(timeIntervalSince1970: 1))
        i.gmailThreadId = thread
        i.gmailMessageId = "msg-\(thread)"
        ctx.insert(i)
        return i
    }

    private func watched(_ e: [any ReplyWatchable]) -> Set<String> {
        GmailReplyChecker.threadsToCheck(in: e, now: now)
    }

    private func fast(_ e: [any ReplyWatchable]) -> Set<String> {
        GmailReplyChecker.threadsToCheck(in: e, fastOnly: true, now: now)
    }

    @Test("a live reply on a long passed, closed out show is fast checked")
    func liveReplyOnAPassedClosedOutShowIsFast() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "a", date: longPassed)
        p.showOutcome = .neverHeardBack
        p.showOutcomeAt = Date(timeIntervalSince1970: 3_000)
        contact(p, thread: "t-live", replied: true)

        #expect(watched([p]) == ["t-live"])
        #expect(fast([p]) == ["t-live"], "an open conversation that has replied is live whatever the date")
    }

    @Test("a never replied pitch whose run has passed is watched but not fast checked")
    func neverRepliedPassedPitchIsWatchedNotFast() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "a", date: longPassed)
        contact(p, thread: "t-old")

        #expect(watched([p]) == ["t-old"])
        #expect(fast([p]).isEmpty)
    }

    @Test("a never replied pitch whose run has not passed is fast checked")
    func neverRepliedUpcomingPitchIsFast() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "a", date: upcoming)
        contact(p, thread: "t-soon")

        #expect(fast([p]) == ["t-soon"])
    }

    @Test("a run judged by its closing night: opened last spring, still running, is fast checked")
    func midRunPitchIsFast() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "a", date: longPassed, runEnd: upcoming)
        contact(p, thread: "t-mid")

        #expect(fast([p]) == ["t-mid"])
    }

    @Test("an undated pitch is fast checked, because an unknown date has not passed")
    func undatedPitchIsFast() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "a", date: nil)
        contact(p, thread: "t-undated")

        #expect(watched([p]) == ["t-undated"])
        #expect(fast([p]) == ["t-undated"])
    }

    @Test("an open inquiry is fast checked even when its event date has passed")
    func openInquiryIsFast() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx, thread: "t-inq", date: longPassed)

        #expect(i.isOpen)
        #expect(watched([i]) == ["t-inq"])
        #expect(fast([i]) == ["t-inq"])
    }

    @Test("a closed inquiry nobody answered is watched but not fast checked")
    func closedInquiryIsNotFast() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx, thread: "t-inq", date: upcoming)
        i.outcome = .lostHard

        #expect(watched([i]) == ["t-inq"])
        #expect(fast([i]).isEmpty)
    }

    @Test("a booked or hand resolved show is in neither set, even with a live reply on an upcoming run")
    func bookedOrHandResolvedIsInNeither() throws {
        let ctx = ModelContext(try container())
        let booked = show(ctx, key: "b", date: upcoming)
        booked.outcome = .booked
        contact(booked, thread: "t-booked", replied: true)
        let resolved = show(ctx, key: "r", date: upcoming)
        resolved.markOutcomeManually(.lostSoft, now: now)
        contact(resolved, thread: "t-resolved", replied: true)
        let contactBooked = show(ctx, key: "c", date: upcoming)
        contact(contactBooked, thread: "t-contact-booked", replied: true).resolution = .booked

        let all: [any ReplyWatchable] = [booked, resolved, contactBooked]
        #expect(watched(all).isEmpty)
        #expect(fast(all).isEmpty)
    }

    @Test("every fast checked thread is a watched thread, over a mixed fixture")
    func fastIsASubsetOfWatched() throws {
        let ctx = ModelContext(try container())
        var all: [any ReplyWatchable] = []
        var n = 0
        let dates: [(String?, String?)] = [(longPassed, nil), (upcoming, nil), (nil, nil), (longPassed, upcoming)]
        for (date, runEnd) in dates {
            for replied in [false, true] {
                for resolution in [nil, RecipientResolution.declinedSoft, .booked] {
                    for closedOut in [false, true] {
                        n += 1
                        let p = show(ctx, key: "k\(n)", date: date, runEnd: runEnd)
                        if closedOut { p.showOutcome = .neverHeardBack; p.showOutcomeAt = now }
                        let r = contact(p, thread: "t\(n)", replied: replied)
                        r.resolution = resolution
                        if replied && n % 2 == 0 { r.replyFromAddress = nil }   // some rows carry a gap
                        all.append(p)
                    }
                }
            }
        }
        for outcome in Outcome.allCases {
            for date in [longPassed, upcoming] {
                n += 1
                let i = inquiry(ctx, thread: "t\(n)", date: date)
                i.outcome = outcome
                all.append(i)
            }
        }

        let w = watched(all)
        let f = fast(all)
        // Not vacuous: both sets hold something, and the fast one is genuinely narrower.
        #expect(!f.isEmpty)
        #expect(f.count < w.count)
        #expect(f.isSubset(of: w), "fast checked but not watched: \(f.subtracting(w).sorted())")
        // And the predicate on its own, since `threadsToCheck` asks `isWatched` again and would hide a
        // fast predicate that had stopped starting from the watched one.
        let today = EasternDate.today(now)
        let escaped = all.flatMap { e in
            e.replyWatchRecipients.filter { r in
                ReplyWatchScope.isFastChecked(e, r, today: today) && !ReplyWatchScope.isWatched(r)
            }.compactMap(\.gmailThreadId)
        }
        #expect(escaped.isEmpty, "fast checked by the predicate but not watched: \(escaped.sorted())")
    }
}
