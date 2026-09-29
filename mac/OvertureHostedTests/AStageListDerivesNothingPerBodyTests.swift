import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4311: a stage's own list is derived by the render pass, never inside a body.
//
// WHAT WAS WRONG. While the Reached out stage was focused, `QueueView.reachedOutList` merged the shows and
// the inquiries (`QueueModel.reachedOutEntries`, over an `inquiries.filter`), grouped them by reach out day
// (`reachOutDateGroups`) and built the watchlist's calendar table (`sourceCalendarIndex`) inside the body,
// on every evaluation, and a body runs on events that change no data (L471). The inquiry block every other
// stage draws did the same with `groupRowsByDate`. The class #4106 removed from the masthead.
//
// WHAT THIS PINS. Over a SERVED pass the body derives nothing, so any row a stage list's derivation
// examines while the queue draws, and any calendar table built, is the BODY's work. Both counts must be
// zero. Counted, never timed (L63, L224).
//
// THE POSITIVE CONTROLS, both in the same fixture (L159). Building the pass itself moves both counters, so
// they are live under this tally. And each list's own builder is counted as it runs, so a zero is a list
// that was DRAWN and derived nothing, never a branch the view did not take. The Reached out branch is
// reached the production way, a deep link to one of its shows (`Phase0cViewRig.DeepLinkChannel`).
@MainActor
@Suite("A stage's list is derived by the pass, not the body (#4311)")
final class AStageListDerivesNothingPerBodyTests {
    private let now = Date()

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: now)!)
    }

    // Invented names and addresses (L155). Shows pitched by email (so they sit on Reached out), one show
    // not yet pitched, an inquiry Dan has replied to (Reached out) and one he has not (Review), and a
    // watched source publishing a calendar, so every derivation the list takes has something to examine.
    private func seed(_ ctx: ModelContext) throws -> (shows: [Prospect], inquiries: [Inquiry],
                                                       sources: [WatchedSource]) {
        ctx.insert(WatchedSource(sourceId: "src-thornbury", orgName: "Thornbury Arts",
                                 listingsURL: "https://thornbury.example/calendar", kind: .html))
        let sentAt = now.addingTimeInterval(-2 * 86_400)
        for n in 0..<6 {
            let p = Prospect(naturalKey: "pitched-\(n)", groupName: "Fennwick Ensemble \(n)",
                             discipline: "music", venue: "Thornbury Hall", performanceDate: night(n),
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
        let fresh = Prospect(naturalKey: "unpitched", groupName: "Larkspur Trio", discipline: "music",
                             venue: "Thornbury Hall", performanceDate: night(1), sourceListingURL: nil,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             status: .new)
        fresh.location = "New York, NY"
        ctx.insert(fresh)
        let waiting = Inquiry(source: .contactForm, inquirerName: "Odile Parmenter",
                              inquirerEmail: "odile@parmenter.example", eventName: "Spring Gala",
                              performanceDate: night(3))
        waiting.sentAt = sentAt
        waiting.gmailMessageId = "<i-1>"
        let unanswered = Inquiry(source: .contactForm, inquirerName: "Caspian Whitlow",
                                 inquirerEmail: "caspian@whitlow.example", eventName: "Recital",
                                 performanceDate: night(4))
        ctx.insert(waiting); ctx.insert(unanswered)
        try ctx.save()
        return (try ctx.fetch(FetchDescriptor<Prospect>()), try ctx.fetch(FetchDescriptor<Inquiry>()),
                try ctx.fetch(FetchDescriptor<WatchedSource>()))
    }

    // Close the window and turn the run loop past the deep link's own 2.5 s highlight timer, so nothing
    // this test built is still observing its container when the next test saves into another one. The
    // first version only closed the window, and the host died in the NEXT test's save, in a
    // `_SwiftData_SwiftUI` notification observer (#3874's signature, L86).
    private func release(_ window: NSWindow?) {
        window?.close()
        let until = Date().addingTimeInterval(3)
        while Date() < until {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
    }

    private func pass(_ t: (shows: [Prospect], inquiries: [Inquiry], sources: [WatchedSource]),
                      stage: StageFocus) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(t.shows), inquiries: t.inquiries, orgAnswers: [],
            sources: t.sources, context: StageContext(now: now, geo: .none, clients: .none),
            focusedStage: stage))
    }

    @Test func theReachedOutListDerivesNothingInTheBody() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let t = try seed(c.mainContext)

        // The positive control: the pass's own list derivations are counted under a tally.
        var reached: QueueView.RenderData?
        let built = QueueRenderPass.WorkTally.measure { reached = pass(t, stage: .reachedOut) }
        let served = try #require(reached)
        let key = try #require(served.reachedOut.first?.prospect.naturalKey,
                               "the fixture put no show on Reached out, so nothing below draws that list")
        #expect(built.stageListRows > 0 && built.sourceCalendarIndexBuilds > 0, Comment(rawValue:
            "building the Reached out pass examined \(built.stageListRows) list rows and built "
            + "\(built.sourceCalendarIndexBuilds) calendar tables under the tally, so the counters are not "
            + "reached and the zeros below would mean nothing (L159)"))

        let feed = Phase0cServedFeed(served)
        let link = Phase0cViewRig.DeepLinkChannel()
        var window: NSWindow?
        defer { release(window) }
        _ = Phase0cView.settle(bodyMustRun: true) {
            let w = Phase0cViewRig.host(c, rows: t.shows, feed: feed, size: NSSize(width: 1000, height: 800),
                                        link: link)
            window = w
            return w
        }
        // Onto the Reached out stage the way an OmniFocus link gets there. The jump derives its own target,
        // as an action may, so it is outside every reading below.
        let listBefore = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList)
        _ = Phase0cView.settle(window!, bodyMustRun: true) { link.key = LeadDeepLink(key: key) }
        #expect(QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList) > listBefore,
                "the deep link did not bring the queue onto the Reached out stage, so nothing below reads it")

        // Two served changes the body must re-run for, on that stage.
        let other = pass(t, stage: .reachedOut)
        let drawnBefore = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList)
        var bodies = 0
        let changing = QueueRenderPass.WorkTally.measure {
            bodies += Phase0cView.settle(window!, bodyMustRun: true) { feed.data = other }.bodies
            bodies += Phase0cView.settle(window!, bodyMustRun: true) { feed.data = served }.bodies
        }
        let drawn = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.reachedOutList) - drawnBefore
        #expect(bodies >= 2 && drawn >= 2, Comment(rawValue:
            "the queue's body ran \(bodies) time(s) and drew the Reached out list \(drawn) time(s), so the "
            + "zero below is a list that was never drawn rather than one that derived nothing"))
        #expect(changing.stageListRows == 0 && changing.sourceCalendarIndexBuilds == 0, Comment(rawValue:
            "drawing the Reached out list over a SERVED pass examined \(changing.stageListRows) list rows and "
            + "built \(changing.sourceCalendarIndexBuilds) calendar tables over \(drawn) draws, which the "
            + "pass had already done. Read `RenderData.reachedOutList` instead (#4311, L471)"))
    }

    @Test func aStagesInquiryBlockDerivesNothingInTheBody() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let t = try seed(c.mainContext)

        var review: QueueView.RenderData?
        let built = QueueRenderPass.WorkTally.measure { review = pass(t, stage: .review) }
        let served = try #require(review)
        #expect(!served.inquiryRows.isEmpty, "the fixture put no inquiry on Review, so no block is drawn")
        #expect(built.stageListRows > 0, Comment(rawValue:
            "building the Review pass examined no list rows under the tally, so the counter is not reached "
            + "and the zero below would mean nothing (L159)"))

        // The served stage's inquiries draw under whatever stage the view holds, since the block is in the
        // branch every stage but Reached out shares.
        let feed = Phase0cServedFeed(served)
        var window: NSWindow?
        defer { release(window) }
        let other = pass(t, stage: .review)
        let listBefore = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.inquiryList)
        var bodies = 0
        let drawing = QueueRenderPass.WorkTally.measure {
            bodies += Phase0cView.settle(bodyMustRun: true) {
                let w = Phase0cViewRig.host(c, rows: t.shows, feed: feed, size: NSSize(width: 1000, height: 800))
                window = w
                return w
            }.bodies
            bodies += Phase0cView.settle(window!, bodyMustRun: true) { feed.data = other }.bodies
        }
        let drawn = QueueRenderCounter.stageListBodyCount(QueueRenderCounter.inquiryList) - listBefore
        #expect(bodies >= 2 && drawn >= 1, Comment(rawValue:
            "the queue's body ran \(bodies) time(s) and drew the inquiry block \(drawn) time(s), so the zero "
            + "below is a block that was never drawn rather than one that derived nothing"))
        #expect(drawing.stageListRows == 0, Comment(rawValue:
            "drawing a stage's inquiry block over a SERVED pass examined \(drawing.stageListRows) rows, which "
            + "the pass had already grouped. Read `RenderData.inquiryGroups` instead (#4311, L471)"))
    }
}
