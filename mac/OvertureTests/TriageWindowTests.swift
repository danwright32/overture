import Testing
import Foundation
import SwiftData

// #2359: triage stops at the queue's stated lead time window.
//
// Nothing applied a far edge to what triage shows. `StageNavigation`'s `.scout` rule asked only whether
// a show was still untriaged and had not opened yet, so the list ran as far ahead as the scout had read.
// Measured on the live store on 2026-08-09: 585 untriaged shows were still ahead of Dan and 119 of them
// sat beyond 90 days, running out to June 2027. The one 90 day check left in the tree lived inside
// `queueOrder`, which no part of the app called, and #2348 deleted it.
//
// Dan's call, 2026-08-09: enforce it. Triage shows the next `QueueModel.leadTimeWindowDays` days and no
// further, and the shows past that edge come back as their dates roll in.
//
// The bound lives in the ONE shared rule (`StageNavigation`), never beside it, which is the whole point
// of this milestone: a second copy of this judgment is exactly the defect #1567 and #1575 exist to stop.
//
// Two things this must NOT do, each with its own test below. Work already in flight must never vanish
// for being far out, because a show disappearing off a stage reads as deletion (#1014, #901), and the
// retired filter deliberately never touched the stage lists. And an inquiry must ignore the window
// entirely, whatever its event date: an inquiry is live because a person is waiting on a reply.
@MainActor
@Suite("Triage stops at the lead time window (#2359)")
struct TriageWindowTests {
    private let today = ScoutTestClock.stageNavigationAnchor   // 2026-07-12
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Dates are computed from the anchor rather than written down, so this suite follows the constant if
    // Dan ever moves the window instead of pinning a number that silently stops being the edge. The one
    // literal below keeps that arithmetic honest.
    private func day(_ offset: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        let start = cal.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        return EasternDate.dayString(from: cal.date(byAdding: .day, value: offset, to: start)!)
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new,
                      date: String?, hasDraft: Bool = false, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hello, I photograph performances." }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    private func scoutKeys(_ ctx: ModelContext) throws -> [String] {
        StageNavigation.naturalKeys(for: .scout, in: try ctx.fetch(FetchDescriptor<Prospect>()),
                                    today: today, now: now)
    }

    // MARK: - The window itself

    @Test("The anchor's ninetieth day is the date this suite thinks it is")
    func theArithmeticThisSuiteRestsOnIsCorrect() {
        #expect(QueueModel.leadTimeWindowDays == 90)
        #expect(day(90) == "2026-10-10", "ninety days after \(today) is 2026-10-10, not \(day(90))")
        #expect(EasternDate.daysUntil(from: today, to: day(90)) == 90)
    }

    @Test("A show past the window is not waiting to be triaged")
    func aShowBeyondTheWindowLeavesTriage() throws {
        let ctx = try context()
        show(ctx, "just-past-the-edge", date: day(QueueModel.leadTimeWindowDays + 1))
        show(ctx, "next-june", date: day(330))

        #expect(try scoutKeys(ctx).isEmpty)
    }

    @Test("A show on the window's last day is still waiting to be triaged")
    func aShowOnTheEdgeStaysInTriage() throws {
        let ctx = try context()
        show(ctx, "tonight", date: today)
        show(ctx, "inside", date: day(QueueModel.leadTimeWindowDays - 1))
        show(ctx, "on-the-edge", date: day(QueueModel.leadTimeWindowDays))

        #expect(Set(try scoutKeys(ctx)) == Set(["tonight", "inside", "on-the-edge"]))
    }

    // "Date to be confirmed" is a normal state on a season page, and an undated show has not been
    // measured as far out: dropping it would lose a real lead on a fact nobody established (#861 made
    // the same call for the past edge).
    @Test("An undated show is never assumed to be beyond the window")
    func anUndatedShowStaysInTriage() throws {
        let ctx = try context()
        show(ctx, "tbc", date: nil)

        #expect(try scoutKeys(ctx) == ["tbc"])
    }

    // MARK: - Only triage is windowed

    // One far out show for every stage, so a focus added later has to be given a fixture here rather than
    // slipping through unexamined. Everything Dan has already acted on stays exactly where it was; only
    // the untriaged one leaves.
    private func farOutFixtures(_ ctx: ModelContext) -> [StageFocus: String] {
        let far = day(400)
        var keys: [StageFocus: String] = [:]

        show(ctx, "far-untriaged", status: .new, date: far)
        keys[.scout] = "far-untriaged"

        show(ctx, "far-kept", status: .queued, date: far)
        keys[.prep] = "far-kept"

        let blocked = show(ctx, "far-kept-clashing", status: .queued, date: far)
        blocked.conflictOpen = true
        keys[.prepBlocked] = "far-kept-clashing"

        show(ctx, "far-drafted", status: .drafted, date: far, hasDraft: true)
        keys[.review] = "far-drafted"

        show(ctx, "far-approved", status: .approved, date: far, hasDraft: true)
        keys[.sendApproved] = "far-approved"

        let held = show(ctx, "far-held", status: .contacted, date: far, hasDraft: true, sentAt: now)
        let heldContact = Recipient(id: "held@venue.example", email: "held@venue.example",
                                    provenance: .presenter)
        heldContact.sendState = .pending
        heldContact.looksLikeDuplicateContact = true
        held.addRecipient(heldContact)
        keys[.sendBlocked] = "far-held"

        let failed = show(ctx, "far-failed", status: .contacted, date: far, hasDraft: true)
        failed.sendError = "Gmail refused the message"
        keys[.sendErrors] = "far-failed"

        let stuck = show(ctx, "far-stuck", status: .contacted, date: far, hasDraft: true)
        let stuckContact = Recipient(id: "stuck@org.example", email: "stuck@org.example", provenance: .act)
        stuckContact.sendState = .sending
        stuckContact.sendClaimedAt = now.addingTimeInterval(-86_400)
        stuck.addRecipient(stuckContact)
        keys[.sendStuck] = "far-stuck"

        let degraded = show(ctx, "far-degraded", status: .contacted, date: far, hasDraft: true, sentAt: now)
        let degradedContact = Recipient(id: "sent@org.example", email: "sent@org.example", provenance: .act)
        degradedContact.sendState = .sent
        degradedContact.replyTrackingDegraded = true
        degraded.addRecipient(degradedContact)
        keys[.sendDegraded] = "far-degraded"

        return keys
    }

    @Test("Work already in flight never disappears for being far out")
    func onlyTriageIsWindowed() throws {
        let ctx = try context()
        let fixtures = farOutFixtures(ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        // Non-vacuous: a stage with no fixture would otherwise be silently unexamined (L63).
        for focus in StageNavigation.countedFocuses {
            #expect(fixtures[focus] != nil, "\(focus) has no far out fixture, so nothing here checks it")
        }

        for focus in StageNavigation.countedFocuses {
            guard let key = fixtures[focus] else { continue }
            let keys = StageNavigation.naturalKeys(for: focus, in: all, today: today, now: now)
            if focus == .scout {
                #expect(!keys.contains(key), "triage still offers a show \(400) days out")
            } else {
                #expect(keys.contains(key),
                        "\(focus) dropped \(key) for being far out, which reads to Dan as deletion")
            }
        }
    }

    // The masthead and the search bar are built from the same predicate, so the same rule has to hold
    // for what they promise: the far out kept show is still reachable, the far out untriaged one is not.
    @Test("The masthead and the search bar follow the same edge")
    func theSharedSurfacesAgreeAboutTheEdge() throws {
        let ctx = try context()
        let fixtures = farOutFixtures(ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let queue = StageNavigation.queueKeys(in: all, reachedOutKeys: [], today: today, now: now)

        #expect(!queue.contains(fixtures[.scout]!))
        #expect(queue.contains(fixtures[.prep]!))
        #expect(!StageNavigation.opensInQueue(key: fixtures[.scout]!, in: all, reachedOutKeys: [],
                                              today: today, now: now))
        #expect(StageNavigation.opensInQueue(key: fixtures[.review]!, in: all, reachedOutKeys: [],
                                             today: today, now: now))
    }

    // MARK: - Inquiries ignore the window

    // A hire inquiry is live because somebody is waiting on a reply from Dan, so its event date decides
    // nothing about whether he sees it. Its stage is placed by `stage(for:)`, which never consults a
    // date at all; this says so out loud, because the window landing on inquiries would silently bury
    // real waiting people behind a date they chose.
    @Test("A hire inquiry for a far out event still needs Dan's reply")
    func aFarOutInquiryIsStillInReview() {
        let inquiry = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.example",
                              eventName: "Gala")
        inquiry.performanceDate = day(700)

        #expect(StageNavigation.stage(for: inquiry) == .review)
    }

    @Test("A far out inquiry Dan has answered is still waiting on them")
    func aFarOutAnsweredInquiryIsStillReachedOut() {
        let inquiry = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: "ada@x.example",
                              eventName: "Gala")
        inquiry.performanceDate = day(700)
        inquiry.sentAt = now

        #expect(StageNavigation.stage(for: inquiry) == .reachedOut)
    }

    @Test("A far out inquiry still counts on the pill Dan taps")
    func aFarOutInquiryStillCountsOnItsPill() {
        let inquiry = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.example",
                              eventName: "Gala")
        inquiry.performanceDate = day(700)

        let inputs = AgentInputs.from(prospects: [], inquiries: [inquiry], now: now, today: today,
                                      gmailConnected: true, prepRunning: false, replyRunAlive: false)
        #expect(inputs.toReview == 1)
    }
}
