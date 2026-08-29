import Testing
import Foundation
import SwiftData

// #2713: WHICH contacts the mailbox search is for, and HOW FAR BACK this tick has to read.
//
// Both halves are here rather than inside the Gmail call because both are decisions, not network: the
// scope is Dan's ("contacts with NO stored conversation"), and the window is what keeps a search that
// would otherwise re-read a month of mail every thirty minutes from doing so.
//
// Every test injects `now`. Not one reads the clock, because every fixture here is a date whose whole
// meaning is its relationship to it: a pitch inside the horizon becomes a pitch outside the horizon
// simply by real time passing, and a test that let that happen would go on asserting about a case
// nobody chose (L130).
@MainActor
@Suite("Which unwatchable pitches the mailbox search reads for (#2713)")
struct ReplySearchScopeTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let day: TimeInterval = 86_400

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // A pitch Dan made through the act's own form: recorded, no address, and no conversation for
    // Overture to watch. This is the row the whole milestone exists for.
    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect, id: String = "form:https://act.com/contact",
                           pitchedAt: Date) -> Recipient {
        let r = Recipient(id: id, email: nil, provenance: .act)
        r.contactFormURL = "https://act.com/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = pitchedAt
        r.formOutreachURL = "https://act.com/contact"
        r.sendState = .sent
        r.sentAt = pitchedAt
        p.addRecipient(r)
        return r
    }

    // MARK: scope

    @Test("a form pitch with no conversation, inside the horizon, is searched for")
    func aLiveFormPitchIsATarget() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-3 * day))

        let targets = ReplySearchScope.targets(in: [p], now: now)

        // #2712: the scope now answers with `any ReplySearchSubject`, since an inquiry rides the same
        // read, so the contact is identified by object rather than by a member only `Recipient` has.
        #expect(targets.count == 1)
        #expect(targets.first.map { $0 === r } == true)
    }

    // Dan's scope, stated in the plan: the off-thread reply on a show that WAS emailed is deliberately
    // out, because that contact already holds a different conversation and the field holds one.
    @Test("a pitch that already carries a conversation is not searched for")
    func anAttachedOrEmailedPitchIsNotATarget() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-3 * day))
        r.gmailThreadId = "t1"

        #expect(ReplySearchScope.targets(in: [p], now: now).isEmpty)
    }

    @Test("a pitch Overture emailed itself is not searched for")
    func anEmailedPitchIsNotATarget() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = Recipient(id: "them@example.com", email: "them@example.com", provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-3 * day)
        r.gmailThreadId = "t1"
        p.addRecipient(r)

        #expect(ReplySearchScope.targets(in: [p], now: now).isEmpty)
    }

    // The explicit stop the plan asks for. Without it a sent pitch never ages off (Dan closes shows out
    // by hand, and until he does the row stays live), so the window this search reads would widen for
    // ever and every tick would pay for the whole of it.
    @Test("a pitch older than the horizon is no longer searched for")
    func aPitchPastTheHorizonIsDropped() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let horizon = Double(ReplySearchScope.horizonDays)
        formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-(horizon + 1) * day))

        #expect(ReplySearchScope.targets(in: [p], now: now).isEmpty)
    }

    @Test("a pitch exactly on the horizon is still searched for")
    func aPitchOnTheHorizonIsKept() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let horizon = Double(ReplySearchScope.horizonDays)
        formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-horizon * day + 1))

        #expect(ReplySearchScope.targets(in: [p], now: now).count == 1)
    }

    // The same bound the reply watcher uses (`replyWatchConversationIsOpen`), so a conversation that
    // could still put itself in front of Dan is exactly the one still being read for, and the two
    // cannot disagree about which those are.
    @Test("a contact Dan has closed out is not searched for")
    func aClosedContactIsNotATarget() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-3 * day))
        r.resolution = .stoodDown

        #expect(ReplySearchScope.targets(in: [p], now: now).isEmpty)
    }

    @Test("a booked show is not searched for")
    func aBookedShowIsNotATarget() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-3 * day))
        p.outcome = .booked

        #expect(ReplySearchScope.targets(in: [p], now: now).isEmpty)
    }

    @Test("a contact Dan opened the form for but never confirmed sending is not searched for")
    func anUnsentFormPitchIsNotATarget() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = Recipient(id: "form:https://act.com/contact", email: nil, provenance: .act)
        r.contactFormURL = "https://act.com/contact"
        r.formOutreachStartedAt = now.addingTimeInterval(-3 * day)
        p.addRecipient(r)

        #expect(ReplySearchScope.targets(in: [p], now: now).isEmpty)
    }

    // MARK: the window this tick has to read

    @Test("with nothing in scope there is no window to read")
    func noTargetsMeansNoWindow() {
        #expect(ReplySearchScope.windowStart(for: [], searchedThrough: nil, now: Date()) == nil)
    }

    // The high-water mark says how far the MAILBOX has been read, which is only an answer for a contact
    // that was in scope when it was read. A pitch recorded since then has never been searched for at
    // all, so it needs its own window back to the pitch: reading only new mail would permanently skip
    // the reply that arrived before it joined the scope.
    @Test("a contact never searched for needs its window back to the pitch")
    func aNewContactNeedsItsOwnWindow() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let pitchedAt = now.addingTimeInterval(-10 * day)
        let r = formPitch(ctx, on: p, pitchedAt: pitchedAt)

        let start = ReplySearchScope.windowStart(for: [r], searchedThrough: now.addingTimeInterval(-1 * day),
                                                 now: now)

        #expect(start == pitchedAt)
    }

    @Test("a contact already searched for needs only the mail since the mark")
    func aSearchedContactReadsOnlyWhatIsNew() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-10 * day))
        r.replyCandidateSearchedAt = now.addingTimeInterval(-1 * day)
        let mark = now.addingTimeInterval(-1 * day)

        #expect(ReplySearchScope.windowStart(for: [r], searchedThrough: mark, now: now) == mark)
    }

    // One search per tick, not one per contact: the window is the widest any single contact needs, and
    // every contact is then scored against the one message set.
    @Test("the window is the oldest any contact in scope needs")
    func theWindowIsTheOldestNeed() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let old = formPitch(ctx, on: p, id: "form:https://a.com/c", pitchedAt: now.addingTimeInterval(-20 * day))
        let recent = formPitch(ctx, on: p, id: "form:https://b.com/c", pitchedAt: now.addingTimeInterval(-2 * day))

        let start = ReplySearchScope.windowStart(for: [recent, old], searchedThrough: nil, now: now)

        #expect(start == now.addingTimeInterval(-20 * day))
    }

    // A mark AHEAD of a searched contact's pitch is the ordinary steady state and must win, or the
    // search re-reads the whole horizon on every tick and the mark buys nothing.
    @Test("an already searched contact never widens the window back to its pitch")
    func aSearchedContactDoesNotWidenTheWindow() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let p = show(ctx)
        let r = formPitch(ctx, on: p, pitchedAt: now.addingTimeInterval(-20 * day))
        r.replyCandidateSearchedAt = now.addingTimeInterval(-2 * day)

        let start = ReplySearchScope.windowStart(for: [r], searchedThrough: now.addingTimeInterval(-2 * day),
                                                 now: now)

        #expect(start == now.addingTimeInterval(-2 * day))
    }
}
