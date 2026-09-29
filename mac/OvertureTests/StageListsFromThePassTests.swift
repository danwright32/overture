import Testing
import Foundation
import SwiftData

// #4311: the Reached out stage's list and a stage's inquiry block are derived ONCE by the render pass and
// published on RenderData, and the view reads them there. `AStageListDerivesNothingPerBodyTests` (hosted)
// pins that the body derives nothing; this suite pins that moving the derivation changed NOTHING about
// what is drawn.
//
// THE EQUALITY is against the functions the body used to call, with the arguments it used to call them
// with: the pass's Reached out rows, the inquiries on the Reached out stage, the watchlist, and one
// instant. The body read `Date()` where the pass reads its own instant; a served answer is at most
// `ScopeMemo.staleAfterSeconds` old, and every date in this fixture is days from it, so the instant is the
// same answer here by construction and the test states it rather than hiding it.
//
// The fixture reaches every branch the list has (L159): a show pitched by email, an inquiry Dan has replied
// to (both on Reached out), an inquiry not yet answered (Review), reach out dates on more than one day, and
// a source publishing a calendar. A positive control shows each comparison can see a wrong answer.
//
// Both ends of every date relationship pinned (L130). Invented names throughout (L155).
@MainActor
@Suite("A stage's list comes from the pass, unchanged (#4311)")
struct StageListsFromThePassTests {
    private let today = "2026-08-16"
    private var now: Date { EasternDate.date(from: today)!.addingTimeInterval(15 * 3_600) }

    private struct Store {
        let shows: [Prospect]
        let inquiries: [Inquiry]
        let sources: [WatchedSource]
    }

    private func context() throws -> ModelContext {
        ModelContext(try TestModelContainer.inMemory(AppSchema.models))
    }

    private func seed(_ ctx: ModelContext) throws -> Store {
        ctx.insert(WatchedSource(sourceId: "src-thornbury", orgName: "Thornbury Arts",
                                 listingsURL: "https://thornbury.example/calendar", kind: .html))
        ctx.insert(WatchedSource(sourceId: "src-nolist", orgName: "Wrenfield Hall", kind: .html))
        // Pitched on two different days, so the reach out dates fall on more than one day.
        for (n, sentDaysAgo) in [(0, 2.0), (1, 9.0), (2, 2.0)] {
            let sentAt = now.addingTimeInterval(-sentDaysAgo * 86_400)
            let p = Prospect(naturalKey: "pitched-\(n)", groupName: "Fennwick Ensemble \(n)",
                             discipline: "music", venue: "Thornbury Hall", performanceDate: "2026-10-0\(n + 3)",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .contacted)
            p.location = "New York, NY"
            p.sourceIds = ["src-thornbury"]
            p.draftSubject = "S"; p.draftBody = "B"
            p.sentAt = sentAt
            ctx.insert(p)
            let r = Recipient(id: "box\(n)@fennwick.example", email: "box\(n)@fennwick.example",
                              name: "Box \(n)", provenance: .presenter)
            r.sendState = .sent
            r.sentAt = sentAt
            r.gmailThreadId = "thread-\(n)"
            r.gmailMessageId = "<m-\(n)>"
            ctx.insert(r)
            p.setRecipients([r])
        }
        let waiting = Inquiry(source: .contactForm, inquirerName: "Odile Parmenter",
                              inquirerEmail: "odile@parmenter.example", eventName: "Spring Gala",
                              performanceDate: "2026-11-02")
        waiting.sentAt = now.addingTimeInterval(-86_400)
        waiting.gmailMessageId = "<i-1>"
        let unanswered = Inquiry(source: .contactForm, inquirerName: "Caspian Whitlow",
                                 inquirerEmail: "caspian@whitlow.example", eventName: "Recital",
                                 performanceDate: "2026-11-05")
        let later = Inquiry(source: .contactForm, inquirerName: "Maren Oakhurst",
                            inquirerEmail: "maren@oakhurst.example", eventName: "Benefit",
                            performanceDate: "2026-11-09")
        ctx.insert(waiting); ctx.insert(unanswered); ctx.insert(later)
        try ctx.save()
        return Store(shows: try ctx.fetch(FetchDescriptor<Prospect>()),
                     inquiries: try ctx.fetch(FetchDescriptor<Inquiry>()),
                     sources: try ctx.fetch(FetchDescriptor<WatchedSource>()))
    }

    private func pass(_ s: Store, stage: StageFocus) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(s.shows), inquiries: s.inquiries, orgAnswers: [],
            sources: s.sources, context: .at(today, now: now, geo: .none), focusedStage: stage))
    }

    // A list compared by what it DRAWS: each row's identity and reach out date, in order.
    private func drawn(_ entries: [ReachedOutEntry]) -> [String] {
        entries.map { "\($0.id)@\($0.next.timeIntervalSince1970)" }
    }

    private func drawn(_ groups: [QueueModel.ReachOutDateGroup<ReachedOutEntry>]) -> [String] {
        groups.map { g in "\(g.id)|\(g.weekday)|\(g.monthDay)|\(g.year)|" + g.rows.map(\.id).joined(separator: ",") }
    }

    private func drawn(_ groups: [RowDateGroup]) -> [String] {
        groups.map { g in "\(g.id)|\(g.weekday)|\(g.monthDay)|\(g.year)|" + g.rows.map(\.id).joined(separator: ",") }
    }

    @Test func thePassPublishesTheReachedOutListTheBodyUsedToDerive() throws {
        let store = try seed(try context())
        let data = pass(store, stage: .reachedOut)

        // What the body did, with its own arguments, at the pass's instant.
        let old = QueueModel.reachedOutEntries(
            prospects: data.reachedOut,
            inquiries: store.inquiries.filter { StageNavigation.stage(for: $0) == .reachedOut }, now: now)
        let oldGroups = QueueModel.reachOutDateGroups(old, reachDate: { $0.next })
        let oldCalendars = QueueModel.sourceCalendarIndex(store.sources)

        // The fixture reaches every branch, or the equality is vacuous.
        #expect(old.contains { if case .prospect = $0 { true } else { false } }, "no show on the list")
        #expect(old.contains { if case .inquiry = $0 { true } else { false } }, "no inquiry on the list")
        #expect(oldGroups.count > 1, "every row falls on one day, so the grouping is not exercised")
        #expect(oldCalendars == ["src-thornbury": "https://thornbury.example/calendar"])

        #expect(drawn(data.reachedOutList.entries) == drawn(old),
                "the pass's Reached out rows differ from the ones the body used to derive")
        #expect(drawn(data.reachedOutList.groups) == drawn(oldGroups),
                "the pass's reach out day headings differ from the ones the body used to derive")
        #expect(data.reachedOutList.sourceCalendars == oldCalendars,
                "the pass's calendar table differs from the one the body used to build")

        // The positive control: the comparison can see a wrong list. Without the inquiries the list loses
        // a row, so a pass that dropped them would fail the line above.
        let withoutInquiries = QueueModel.reachedOutEntries(prospects: data.reachedOut, inquiries: [], now: now)
        #expect(drawn(withoutInquiries) != drawn(old))
    }

    // Derived only for the stage that draws it, so every other stage's pass pays nothing for it.
    @Test func onlyTheReachedOutStageCarriesTheList() throws {
        let store = try seed(try context())
        #expect(!pass(store, stage: .reachedOut).reachedOutList.entries.isEmpty)
        for stage in StageFocus.allCases where stage != .reachedOut {
            #expect(pass(store, stage: stage).reachedOutList.entries.isEmpty,
                    "the \(stage.rawValue) pass derived the Reached out list, which only that stage draws")
        }
    }

    // The inquiry block is the other stages' list, so Reached out, which draws its inquiries inside
    // `reachedOutList` instead, carries none of it, while a stage that draws the block carries it.
    @Test func onlyAStageThatDrawsTheInquiryBlockCarriesIt() throws {
        let store = try seed(try context())
        let reached = pass(store, stage: .reachedOut)
        #expect(!reached.inquiryRows.isEmpty,
                "the fixture puts no inquiry on Reached out, so nothing below tells a gate from an empty stage")
        #expect(reached.inquiryGroups.isEmpty && reached.inquiriesByRowID.isEmpty,
                "the Reached out pass grouped its inquiries for a block that stage never draws")
        let review = pass(store, stage: .review)
        #expect(!review.inquiryGroups.isEmpty && !review.inquiriesByRowID.isEmpty,
                "the Review pass did not build the inquiry block it draws")
    }

    @Test func thePassPublishesTheInquiryBlockTheBodyUsedToGroup() throws {
        let store = try seed(try context())
        let data = pass(store, stage: .review)
        #expect(data.inquiryRows.count == 2, "the fixture puts two unanswered inquiries on Review")

        let old = QueueModel.groupRowsByDate(data.inquiryRows.map { QueueRow.inquiry($0) })
        #expect(old.count == 2, "both inquiries fall on one date, so the grouping is not exercised")
        #expect(drawn(data.inquiryGroups) == drawn(old),
                "the pass's inquiry headings differ from the ones the body used to group")
        // Every row the block draws resolves to its own inquiry, which is what the body's lookup was for.
        for row in data.inquiryRows {
            #expect(data.inquiriesByRowID[row.id].map { String(describing: $0.persistentModelID) } == row.id,
                    "an inquiry row the block draws resolves to no inquiry, so its buttons would act on nothing")
        }

        // The positive control: grouped over another stage's inquiries, the headings differ.
        let otherStage = QueueModel.groupRowsByDate(
            QueueRenderPass.inquiryRows(store.inquiries, stage: .reachedOut, now: now).map { QueueRow.inquiry($0) })
        #expect(drawn(otherStage) != drawn(old))
    }
}
