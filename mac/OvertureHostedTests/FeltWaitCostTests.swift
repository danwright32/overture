import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #2727: measure the wait DAN FEELS, not only the rebuild inside it.
//
// `QueueRebuildCostTests` times `QueueModel.items(from:sources:)`, which is the derivation that rebuilds
// every card. What Dan actually waits for after a press is wider than that: the model write,
// `context.saveOrWarn` committing synchronously, SwiftData invalidating the view's `@Query`, and then the
// rebuild AND the SwiftUI render pass over the result. A figure taken with the expensive half excluded is
// exactly the shape L102 warns about, and this one is quoted in a source comment on
// `ClosedOutDepartureRow` as what the row's animation is covering for.
//
// WHY IT IS HOSTED. The render pass is the part no unit test can reach: a SwiftUI body cannot be
// evaluated outside a real view tree, which is the whole reason `QueueRenderPass` exists. So this hosts
// the REAL `QueueView` in a real window, on `ArchiveScrollDoesNotRebuildTests`'s rig, presses the real
// mutation, and measures until the list has rebuilt.
//
// WHAT IT MEASURES, and the split is the point rather than the total:
//
//   1. the write          the mutation and `saveOrWarn`, which happen synchronously on the press
//   2. everything after   SwiftData invalidating the query, the rebuild, and SwiftUI rendering it
//
// The second is the half no existing instrument could see, and the one #2417's fix was aimed at.
//
// WHAT IT CANNOT SEE, said here so nobody reads it as more than it is. The window is never ordered
// front, because doing so crashes the shared app host (#3480), so AppKit lays the view out without a
// real display pass. The rebuild is real, the body evaluations are real, and the compositing is not. So
// this is a FLOOR on the felt wait rather than the whole of it, and it is still far more of that wait
// than a derivation timed on its own.
//
// OPT IN, like every other stopwatch in this repository and for its reason: a timing assertion on a
// shared Mac measures what else the machine is running (L224). What rides along on every push is that
// the rig still WORKS, which is asserted without a clock.
@MainActor
@Suite("What a press really costs, end to end (#2727)")
struct FeltWaitCostTests {

    // The live store's shape, through the one place that records it (#3516, #3650).
    // LIVE-SHAPE: prospects
    private static let corpusSize = 1224

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        OrgReachabilityAnswer.self, WatchedSource.self,
                                        RefusedContactAddress.self, PromotedProducer.self,
                                        DemotedHouse.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func seed(_ ctx: ModelContext, rows: Int) -> [String] {
        let dates = LiveDateClustering.dates(forRows: rows)
        var keys: [String] = []
        var made: [Prospect] = []
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Venue \(n % 169) Hall", performanceDate: dates[n],
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.presenter = "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            // #3650: a body on the rows the live store carries one on, because the draft lint is reached
            // only through a non-empty effective body and is the expensive half of building a card.
            if LiveContactShape.carriesADraftBody(n) { p.draftBody = LiveContactShape.draftBody }
            ctx.insert(p)
            made.append(p)
            keys.append(p.naturalKey)
        }
        // #3650: THE CONTACTS, at the live store's own spread, from the one place that records it.
        //
        // This rig held 1,142 prospects and NOT ONE recipient until 2026-09-07, which is the same defect
        // #2048 fixed in the unhosted cost fixture, still standing here. It matters more here than there:
        // this is the rig that measures the wait Dan actually FEELS, and almost everything expensive
        // about a card is per contact (`SendGroup.CardGroups`, `RecipientSnapshot`, and the draft lint).
        // With no recipients every one of those short-circuits on its first line, so the felt wait it
        // reported was taken over a store where building a card is nearly free (L48, L354).
        //
        // Nothing reported it, and that is the other half: `check-fixture-corpus-drift.sh` scanned only
        // `mac/OvertureTests`, so this whole target was exempt from the check written to catch it. The
        // scan root is widened in the same change (L96, L247).
        for (index, place) in LiveContactShape.placements(rowCount: rows).enumerated() {
            let r = Recipient(id: "contact-\(index)", email: "contact\(index)@example.com",
                              name: "Contact \(index)", role: "programming", provenance: .presenter)
            r.sendState = place.pending ? SendState.pending : SendState.sent
            r.prospect = made[place.row]
            ctx.insert(r)
        }
        try? ctx.save()
        return keys
    }

    // #3480's rig. AppKit really lays the view out, which is the only way a body evaluation happens at all.
    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it, which crashed the shared
        // app host and truncated the whole hosted target (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Pump the run loop until the queue has built `expected` more SCOPE ROWS, or the deadline passes.
    //
    // #3653 step 3a: ROWS, not cards, and the re-point had to land in the same change that made the pass
    // build rows at all. These four waits keyed on `WorkTally.queueItems` until then, which was the same
    // number: one card per show in scope. #3654 breaks that equality on purpose, building a card only for
    // what is on screen, and at that moment every condition here becomes unmeetable, so each of these
    // tests would burn its whole deadline (90 s, 20 s, 20 s, 60 s) in the SERIAL hosted bundle and then
    // fail, on every push, for a reason naming nothing (L98, L110).
    //
    // The card counter is deliberately still read where a test is asking about CARDS (the press and the
    // write both assert on `cardsAfterThePress`), because the ratio of the two is what Phase 4 is judged
    // by and folding them would make the saving unmeasurable at the moment it starts.
    //
    // A DEADLINE rather than a bare wait, because a wait with no deadline cannot fail, it can only hang,
    // and a hang is indistinguishable from a slow machine while holding the shared xcodebuild lock
    // (L110). It stops the MOMENT the condition holds, so the ordinary case is fast and only the failing
    // one runs out its deadline (L290).
    private func pumpUntilCardsBuilt(_ expected: Int, from start: Int, in hosting: NSView,
                                     seconds: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (QueueRenderPass.WorkTally.current?.queueRows ?? 0) - start >= expected { return true }
            // The LAYOUT AND DISPLAY are driven explicitly, and that is not decoration: this window is
            // never ordered front, because doing so crashes the shared app host (#3480), so AppKit runs
            // no display cycle of its own for it and turning the run loop alone evaluates nothing.
            //
            // Measured while building this: without these two calls the first render never happened at
            // all, and the whole 1,142 card pass instead ran AFTER the press, folded into what was being
            // reported as the cost of the press. The reading was 1,331 ms and looked entirely plausible.
            // That is why the rebuild's own card count is printed beside the timing: two whole-store
            // passes and one are the same number of milliseconds to anybody reading only the clock.
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return (QueueRenderPass.WorkTally.current?.queueRows ?? 0) - start >= expected
    }

    // The two deep-link bindings QueueView takes are held by a tiny wrapper rather than passed as
    // `.constant(nil)`: SwiftUI writes them, and a constant binding swallows the write, which would make
    // this harness quietly different from the app on the one path #1573 is about.
    private struct Harness: View {
        let container: ModelContainer
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?
        @State private var feedback = ActionFeedback()
        @State private var dayOffOffer = DayOffOfferRequest()

        var body: some View {
            QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys)
                .modelContainer(container)
                .environment(feedback)
                .environment(dayOffOffer)
        }
    }

    private func queueView(_ container: ModelContainer) -> some View {
        Harness(container: container)
    }

    // Draw the list once, and wait for it to finish, BEFORE anything is timed.
    //
    // WHY A WRITE IS NEEDED TO DO THAT, which is the thing this rig taught. A hosted `QueueView` whose
    // window is never ordered front evaluates no body at all from laying out and pumping the run loop:
    // measured 2026-09-05, sixty seconds of pumping with explicit `layoutSubtreeIfNeeded` and
    // `displayIfNeeded` built ZERO cards. What does provoke it is a SwiftData change notification, which
    // is the same thing a press provokes in the app.
    //
    // So the list is warmed with a THROWAWAY press on a different row, and only the second one is timed.
    // Without it the first render lands inside the measurement: the reading was 1,331 ms and entirely
    // plausible, and the card count beside it said 2,282 over a corpus of 1,142, which is two whole-store
    // passes reported as the cost of one. That is the reason the count is printed at all (L98).
    private func warmTheList(_ ctx: ModelContext, keys: [String], rows: Int, in hosting: NSView) -> Bool {
        let all = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        ProspectMutations.dismissAll([keys[keys.count - 1]], reason: .notAFit, dateLabel: "1 Aug",
                                     prospects: all, context: ctx, feedback: ActionFeedback())
        return pumpUntilCardsBuilt(rows - 1, from: 0, in: hosting, seconds: 90)
    }

    // The rig, proved before anything is concluded from it. A press that provoked no rebuild makes every
    // reading below meaningless, and "no rebuild" is exactly what a fast one looks like (L98, L159).
    //
    // Rides along on every push, because it carries no clock: it asserts that a press really does rebuild
    // the queue, which is the claim every timing here rests on.
    @Test func aPressReallyRebuildsTheQueue() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        // A small corpus: this asserts the mechanism, not the cost, and the cost test below is the one
        // that needs the live shape.
        let keys = seed(ctx, rows: 40)

        let (window, hosting) = host(queueView(c))
        defer { window.close() }

        var rebuiltAfterThePress = false
        var warmed = false
        var cardsAfterThePress = 0
        let built = QueueRenderPass.WorkTally.measure {
            warmed = warmTheList(ctx, keys: keys, rows: 40, in: hosting)
            // #3653 step 3a: TWO baselines, because these are two quantities now. The pump waits on ROWS
            // built, and what the test reports is CARDS built, and folding them would give a card delta
            // measured from a row baseline: the same number today, and silently wrong the moment #3654
            // stops building one card per show (L118).
            let settledRows = QueueRenderPass.WorkTally.current?.queueRows ?? 0
            let settledCards = QueueRenderPass.WorkTally.current?.queueItems ?? 0
            let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            ProspectMutations.dismissAll([keys[0]], reason: .notAFit, dateLabel: "1 Aug",
                                         prospects: rows, context: ctx, feedback: ActionFeedback())
            // Two fewer than the corpus: the warm-up dismissed one and this press dismisses another, and
            // both leave the queue's own scope.
            rebuiltAfterThePress = pumpUntilCardsBuilt(38, from: settledRows, in: hosting, seconds: 20)
            // A moment longer AFTER the condition holds, so a SECOND pass provoked by the same press is
            // counted rather than being cut off by the wait ending at the first one.
            let settle = Date().addingTimeInterval(1)
            while Date() < settle {
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            cardsAfterThePress = (QueueRenderPass.WorkTally.current?.queueItems ?? 0) - settledCards
        }

        #expect(warmed, "the list never drew at all, so there was nothing to press on")

        #expect(built.queueItems > 0, "the queue built no cards at all, so nothing here was measured")
        #expect(rebuiltAfterThePress, Comment(rawValue:
                "the press provoked no rebuild, so every timing in this suite would be a timeout rather "
                + "than a cost, and a timeout reads as a very slow press (L98, L110)"))
        let gone = ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? [])
            .first { $0.naturalKey == keys[0] }?.status
        #expect(gone == .dismissed, "the mutation did not land, so no rebuild was provoked")

        // HOW MANY whole-store passes one press provokes, which is the finding this suite turned up and
        // the reason it counts cards rather than only timing.
        //
        // It was TWO when #2727 first measured it: a press built 2,280 cards over a corpus of 1,142, and
        // half the wait Dan felt after every press was a duplicate of the other half. #2598 found the
        // second one and removed it. `QueueView.missedByACheckKeys` was a computed property reading
        // `items`, which derives the whole store, and the masthead read it while ALREADY HOLDING those
        // rows as a parameter, for a count of how many shows a check had missed.
        //
        // Nothing reported that, and nothing could: the sweep counter lives INSIDE the pass and this
        // derivation was outside it, so the guard that exists to catch exactly this shape was blind to it
        // (L63). This assertion is what is not blind to it, which is why it is pinned HERE, on the cheap
        // forty row corpus that rides along on every push, rather than in the opt-in measurement: a
        // number nobody runs is a number nobody notices moving.
        //
        // Named as PASSES rather than cards so the assertion says what it means, and bounded on BOTH
        // sides: below one would mean the list stopped rebuilding at all, above one that a second
        // derivation has come back.
        let passes = Double(cardsAfterThePress) / Double(38)
        #expect(cardsAfterThePress > 0, "the press built no cards, so no pass was counted")
        #expect(passes >= 0.9 && passes <= 1.1, Comment(rawValue:
                "one press provoked \(String(format: "%.1f", passes)) whole-store passes "
                + "(\(cardsAfterThePress) cards over 38 rows in scope). ONE is what a press is supposed "
                + "to cost. TWO is what it cost before #2598, and the way back is a computed property "
                + "that derives the store being read from the render path while the pass already holds "
                + "the rows. Less than one means the list stopped rebuilding at all, which would make "
                + "every timing in this suite a timeout rather than a cost."))
    }

    // THE CLASS, not the instance. #2598 found ONE render-path derivation and removed it; what stops the
    // next one is this, because it is about presses rather than about `missedByACheckKeys`.
    //
    // A bare field write is deliberately not a queue mutation at all: it goes through no app control, so
    // nothing here can be satisfied by whatever `dismissAll` happens to do. Any whole-store derivation
    // read from the render path shows up as a second pass however it is spelled and whoever adds it,
    // which is the property `QueueRenderPass.Corpus` has inside the pass and could not have outside it
    // (L63, L247).
    @Test func anyWriteAtAllCostsExactlyOnePass() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        let keys = seed(ctx, rows: 40)
        let (window, hosting) = host(queueView(c))
        defer { window.close() }

        var cardsAfterTheWrite = 0
        var warmed = false
        _ = QueueRenderPass.WorkTally.measure {
            warmed = warmTheList(ctx, keys: keys, rows: 40, in: hosting)
            // #3653 step 3a: TWO baselines, because these are two quantities now. The pump waits on ROWS
            // built, and what the test reports is CARDS built, and folding them would give a card delta
            // measured from a row baseline: the same number today, and silently wrong the moment #3654
            // stops building one card per show (L118).
            let settledRows = QueueRenderPass.WorkTally.current?.queueRows ?? 0
            let settledCards = QueueRenderPass.WorkTally.current?.queueItems ?? 0

            let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            rows.first { $0.naturalKey == keys[0] }?.fitScore = 9
            try? ctx.save()

            _ = pumpUntilCardsBuilt(39, from: settledRows, in: hosting, seconds: 20)
            let settle = Date().addingTimeInterval(1)
            while Date() < settle {
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            cardsAfterTheWrite = (QueueRenderPass.WorkTally.current?.queueItems ?? 0) - settledCards
        }

        #expect(warmed, "the list never drew, so there was nothing to write against")
        // 39 rows in scope: the warm-up dismissed one of the forty and this write dismisses none.
        let passes = Double(cardsAfterTheWrite) / Double(39)
        #expect(cardsAfterTheWrite > 0, "the write provoked no rebuild at all")
        #expect(passes >= 0.9 && passes <= 1.1, Comment(rawValue:
                "one field write provoked \(String(format: "%.1f", passes)) whole-store passes "
                + "(\(cardsAfterTheWrite) cards over 39 rows in scope). Any write is one pass; more than "
                + "one means something on the render path derives the store a second time (#2598)."))
    }

    @Test func measureWhatAPressCosts() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_FELT_WAIT"] != nil else {
            // Not silently skipped: an instrument that says nothing is indistinguishable from one that
            // ran and found nothing (L98).
            print("felt-wait-cost: not measured. Set TEST_RUNNER_MEASURE_FELT_WAIT=1 to run it.")
            return
        }

        let c = try container()
        let ctx = ModelContext(c)
        let keys = seed(ctx, rows: Self.corpusSize)

        let (window, hosting) = host(queueView(c))
        defer { window.close() }

        var writeSeconds = 0.0
        var afterSeconds = 0.0
        var rebuilt = false
        var cardsInTheRebuild = 0
        var firstRenderSettled = false

        let work = QueueRenderPass.WorkTally.measure {
            // Draw the list once and let it settle, so what is timed below is a press on a DRAWN list
            // rather than the list appearing for the first time.
            firstRenderSettled = warmTheList(ctx, keys: keys, rows: Self.corpusSize, in: hosting)
            // #3653 step 3a: TWO baselines, because these are two quantities now. The pump waits on ROWS
            // built, and what the test reports is CARDS built, and folding them would give a card delta
            // measured from a row baseline: the same number today, and silently wrong the moment #3654
            // stops building one card per show (L118).
            let settledRows = QueueRenderPass.WorkTally.current?.queueRows ?? 0
            let settledCards = QueueRenderPass.WorkTally.current?.queueItems ?? 0
            let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []

            // 1. THE WRITE, which is what happens synchronously under Dan's finger: the model change and
            //    saveOrWarn committing it.
            let pressed = Date()
            ProspectMutations.dismissAll([keys[0]], reason: .notAFit, dateLabel: "1 Aug",
                                         prospects: rows, context: ctx, feedback: ActionFeedback())
            writeSeconds = Date().timeIntervalSince(pressed)

            // 2. EVERYTHING AFTER: the query invalidating, the rebuild, and SwiftUI rendering the result.
            //    This is the half no existing instrument could see.
            // Two fewer than the corpus: the warm-up dismissed one and this press dismisses another.
            rebuilt = pumpUntilCardsBuilt(Self.corpusSize - 2, from: settledRows, in: hosting, seconds: 60)
            afterSeconds = Date().timeIntervalSince(pressed) - writeSeconds
            cardsInTheRebuild = (QueueRenderPass.WorkTally.current?.queueItems ?? 0) - settledCards
        }

        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        let total = writeSeconds + afterSeconds
        print("""
        felt-wait-cost: one press on a drawn queue of \(Self.corpusSize) rows (#2727)
          1. the write, under the finger    \(ms(writeSeconds)) ms
          2. the query, rebuild and render  \(ms(afterSeconds)) ms
          ------------------------------------------------
             press to the list settling     \(ms(total)) ms

          cards built after the press       \(cardsInTheRebuild), which is \(String(format: "%.1f", Double(cardsInTheRebuild) / Double(Self.corpusSize - 2))) whole-store passes

          READ THAT SECOND LINE BESIDE THE TIMING. It was 2.0 when this suite was written, and #2598
          removed the duplicate. Two whole-store passes and one slow one are the same number of
          milliseconds to anybody reading only the clock, which is why the count is printed here (L98).
          `aPressReallyRebuildsTheQueue` pins it so it cannot move unnoticed.

          Read this against QueueRebuildCostTests, which times step 2's REBUILD alone. The difference is
          what #2727 exists to name: the wait Dan feels is wider than the derivation inside it.

          A FLOOR rather than the whole wait: this window is never ordered front, because doing so
          crashes the shared app host (#3480), so AppKit lays the view out without a real display pass.
        """)

        #expect(firstRenderSettled, Comment(rawValue:
                "the list had not finished drawing when the press happened, so what step 2 reports is the "
                + "first render folded into the rebuild rather than the cost of a press on a drawn list"))
        #expect(rebuilt, "the queue never rebuilt after the press, so step 2 is a timeout and not a cost")
        #expect(cardsInTheRebuild > 0, "the press built no cards, so there is no pass to report")
        #expect(writeSeconds > 0, "the write took no measurable time, so it never ran")
        #expect(afterSeconds > 0, "nothing happened after the write, so there was no wait to measure")
    }

}
