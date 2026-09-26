import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
import Observation
@testable import Overture

// #4102: what does ONE scout run cost the queue, and does it grow with the number of sources?
//
// WHAT WAS MEASURED. The automatic watch-only scout of 2026-09-21 left a train of whole-queue passes in the
// freeze log for as long as it ran, and the live sample put the queue's pass (`QueueView.body`,
// `makeRenderData`, `QueueRenderPass.make`) beside the scout's own apply on the main thread. A hosted
// `QueueView` over 60 shows, with the scout driven through `ScoutService.runScout` and the window given a
// chance to draw while each source is being read (which is what the app's run loop does between sources),
// measured the shape before this change:
//
//   1 native source   3 or 4 derivations: one change, then two or three `nothing this view reads`
//   4 native sources  16 derivations: `allProspects, prospects` then `nothing this view reads` three times,
//                     once per source, four times over
//
// So each source the run applied reached the screen as its own change, and the queue paid a whole-store
// pass for every one of them, then three more for the notifications that follow a save. A source count is
// Dan's watchlist and only grows.
//
// WHAT THIS PINS. A run over several sources reaches the queue as no more changes than a run over ONE. That is
// a statement about the structure (every source's writes land in one block), not a number to tune, and it
// holds whatever SwiftData's own notifications cost per change, which is #4252's subject rather than this
// one's.
//
// A COUNT, NOT A DURATION (L63, L290).

// A native reader that gives the window a chance to draw before it answers, as the network does in the app.
private struct DrawingExtractor: SourceExtractor, @unchecked Sendable {
    let events: [ExtractedEvent]
    let beforeAnswering: @MainActor () async -> Void
    func extract() async throws -> ExtractedListing {
        await beforeAnswering()
        return ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

@MainActor
@Suite("What a scout run costs the queue (#4102)")
struct AScoutRunDerivesTheQueueOnceTests {

    private static let rows = 60
    private static let showsPerSource = 10

    // From the real clock, because the queue reads the real clock: past dates would put every show outside
    // the lead time window and the queue would derive over nothing (L130).
    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    private func seed(_ ctx: ModelContext) {
        for n in 0..<Self.rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Venue \(n % 17) Hall", performanceDate: Self.night(n / 3),
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.presenter = "Ensemble \(n) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    private struct Harness: View {
        let container: ModelContainer
        let feedback: ActionFeedback
        let dayOffOffer: DayOffOfferRequest
        let undoStack: QueueUndoStack
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            RowsFromStore { (rows: [Prospect]) in
                QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                          allProspects: rows, onConnectGmail: { })
            }
            .modelContainer(container)
            .environment(feedback)
            .environment(dayOffOffer)
            .environment(undoStack)
        }
    }

    private func host(_ c: ModelContainer) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(Harness(container: c, feedback: ActionFeedback(),
                                                              dayOffOffer: DayOffOfferRequest(),
                                                              undoStack: QueueUndoStack())))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Waits until the derivation count has GONE QUIET rather than for a fixed time (L290), the same shape
    // as `OneChangeDerivesTheQueueOnceTests.settle`.
    private func settle(_ hosting: NSView, quietPolls: Int = 40) async -> [String] {
        var reasons: [String] = []
        var seen = QueueRenderCounter.derivations
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if QueueRenderCounter.derivations > seen {
                while QueueRenderCounter.derivations > seen {
                    seen += 1
                    reasons.append(QueueRenderCounter.lastReason)
                }
                quiet = 0
            } else {
                quiet += 1
            }
            if quiet >= quietPolls { return reasons }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reasons
    }

    private func events(for id: String) -> [ExtractedEvent] {
        (0..<Self.showsPerSource).map { k in
            ExtractedEvent(title: "Quartet \(id) \(k)", presenter: "Quartet \(id) \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: Self.night(k),
                           sourceUrl: "https://\(id).example/e\(k)", location: "New York, NY")
        }
    }

    // A TicketTailor widget, which the html loop reads NATIVELY and for free (#1295). The same shows as a
    // native source would carry, so the two kinds of source differ only in which door they come through.
    private func widget(for id: String) -> String {
        let dates = (0..<Self.showsPerSource).map { k in
            #""\#(Self.night(k))":{"available":true,"formatted_date":"x","event_series":[{"series_id":\#(k + 1),"name":"Quartet \#(id) \#(k)","venue":"Venue \#(k) Hall","event_page_url":"/events/\#(id)/\#(k)"}]}"#
        }
        return "<script>var selectableDates = {\(dates.joined(separator: ","))};</script>"
    }

    private struct Run {
        let derivations: [String]
        let outcome: ScoutService.Outcome
        let storedShows: Int

        // The derivations that saw a change of their own, as against the ones SwiftData's notifications
        // after a save provoke over data that has not moved (#4106 measured those, and #4252 holds them).
        // One per moment the store changed under the screen.
        var changes: Int { derivations.filter { $0 != QueueRenderCounter.nothingVisible }.count }
    }

    // HOW THE TWO RUNS ARE COMPARED. The number of CHANGES the screen saw is exact: one for a run whose
    // writes land together, one per source for a run whose writes do not. The TOTAL also carries the
    // notifications that follow each change, which measured two or three per change on the same code
    // depending on timing, so the total is held under twice a one source run rather than equal to it:
    // equal would be flaky, and before this change four sources cost four times one.
    private func expectNoMoreThanOneSource(_ run: Run, against one: Run, _ what: String) {
        #expect(run.changes <= one.changes, Comment(rawValue:
            "\(what) reached the queue as \(run.changes) separate changes against \(one.changes) for one "
            + "feed, so each source lands as its own change: \(run.derivations.joined(separator: " | ")) (#4102)"))
        #expect(run.derivations.count < 2 * one.derivations.count, Comment(rawValue:
            "\(what) derived the whole queue \(run.derivations.count) times against "
            + "\(one.derivations.count) for one feed: \(run.derivations.joined(separator: " | ")) (#4102)"))
    }

    // One run over `native` feed sources and `inline` TicketTailor html sources, with the window drawn while
    // each one is being read. Returns every derivation from the run's first read to the queue going quiet
    // after it. Watch-only (the automatic run the freeze was measured on) unless it has widgets, which only
    // a run Dan started reads at all (`SourceCheck.decide` hands back a page only at `.readChanged`).
    private func watchRun(native: Int, inline: Int) async throws -> Run {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let (window, hosting) = host(c)
        defer { window.close() }
        let ctx = c.mainContext
        seed(ctx)
        var ids: Set<String> = []
        for n in 0..<native {
            ctx.insert(WatchedSource(sourceId: "feed-\(n)", orgName: "Feed \(n)",
                                     listingsURL: "https://feed-\(n).example/", kind: .algolia))
            ids.insert("feed-\(n)")
        }
        for n in 0..<inline {
            let s = WatchedSource(sourceId: "tt-\(n)", orgName: "Widget \(n)",
                                  listingsURL: "https://tt-\(n).example/box-office", kind: .html)
            s.venueLocation = "New York, NY"
            ctx.insert(s)
            ids.insert("tt-\(n)")
        }
        try ctx.save()
        let appeared = await settle(hosting)
        #expect(!appeared.isEmpty, Comment(rawValue:
            "the queue never derived while appearing, so this fixture measures nothing (L98)"))

        var during: [String] = []
        let outcome = try await ScoutService.runScout(
            into: ctx, depth: inline > 0 ? .readChanged : .watchOnly, only: ids,
            extractorRegistry: { source in
                guard let id = source?.sourceId, id.hasPrefix("feed-") else { return nil }
                return DrawingExtractor(events: events(for: id)) {
                    during += await settle(hosting, quietPolls: 5)
                }
            },
            fetch: { url, _, _ in
                during += await settle(hosting, quietPolls: 5)
                let id = url.host?.replacingOccurrences(of: ".example", with: "") ?? ""
                return FetchedPage(normalizedHTML: "<html><body>widget shell</body></html>",
                                   finalURL: url.absoluteString, contentHash: "hash-\(id)",
                                   ticketTailorWidgetHTML: widget(for: id))
            },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("AScoutRunDerivesTheQueueOnceTests"))
        let after = await settle(hosting)
        let stored = try ctx.fetchCount(FetchDescriptor<Prospect>()) - Self.rows
        return Run(derivations: during + after, outcome: outcome, storedShows: stored)
    }

    @Test func aRunOverFourFeedsDerivesTheQueueNoMoreThanARunOverOne() async throws {
        let one = try await watchRun(native: 1, inline: 0)
        let four = try await watchRun(native: 4, inline: 0)

        // THE POSITIVE CONTROLS. Both runs really added their shows, and the queue really reacted to them;
        // a ceiling is satisfied by a run that wrote nothing or a queue that stopped updating (L159).
        #expect(one.storedShows == Self.showsPerSource, Comment(rawValue:
            "the one feed run stored \(one.storedShows) shows, not \(Self.showsPerSource), so nothing below was measured"))
        #expect(four.storedShows == 4 * Self.showsPerSource, Comment(rawValue:
            "the four feed run stored \(four.storedShows) shows, not \(4 * Self.showsPerSource)"))
        #expect(one.derivations.count >= 1, Comment(rawValue:
            "the queue never derived for a run that added \(one.storedShows) shows, so it did not react at all"))

        expectNoMoreThanOneSource(four, against: one, "a watch-only run over four feeds")
    }

    // The html loop's own free reads (a TicketTailor widget, a ticketing feed) are sources too, and they
    // are read BETWEEN network fetches, which is exactly where the window draws. Batching only the feeds
    // would leave these each landing as their own change (L30).
    @Test func widgetsReadInTheHtmlLoopLandTogetherWithTheFeeds() async throws {
        let one = try await watchRun(native: 1, inline: 0)
        let mixed = try await watchRun(native: 2, inline: 2)

        #expect(mixed.storedShows == 4 * Self.showsPerSource, Comment(rawValue:
            "the mixed run stored \(mixed.storedShows) shows, not \(4 * Self.showsPerSource), so the widgets "
            + "were not read natively and nothing below was measured"))
        let widgetResults = mixed.outcome.sources.filter { $0.sourceId.hasPrefix("tt-") }
        #expect(widgetResults.count == 2 && widgetResults.allSatisfy {
            if case .ingested = $0.state { return true } else { return false }
        }, Comment(rawValue: "the widgets were not reported as ingested: \(widgetResults)"))

        expectNoMoreThanOneSource(mixed, against: one, "a run over two feeds and two widgets")
    }
}
