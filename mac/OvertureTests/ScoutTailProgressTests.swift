import Testing
import Foundation
import SwiftData

// #2203. The sweep reports once per fetched source, so "N of M done" pins at the total the instant the
// fetch loop ends. The Scouting phase is nowhere near over then: the read-budget decision, the hand-off
// to the reader and its detached launch, the deferred report, the booking reconcile over the whole store,
// the blocked-town retirement and the saves all still have to happen, and none of them reported anything.
//
// Observed 2026-08-06: the takeover sat at "68 of 68 done" and kept counting. Two failures from one
// cause. The count made a promise it could not keep, so a phase finished with one part looked frozen; and
// `advancedAt` stopped moving, so the sweep's only evidence of life expired and a slow tail was judged
// stuck by the wall clock alone.
@MainActor
@Suite("The scout reports its tail, not just its fetch loop (#2203)")
struct ScoutTailProgressTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutTailProgressTests-\(UUID().uuidString)")!
    }

    @discardableResult
    private func source(_ ctx: ModelContext, _ id: String, lastHash: String? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = lastHash
        ctx.insert(s)
        return s
    }

    private let noEvents = StubSourceExtractor(listing: ExtractedListing(events: [],
                                                                        verdict: .upcomingListings))

    private func page(_ hash: String) -> (URL, String?, String?) async throws -> FetchedPage {
        { url, _, _ in FetchedPage(normalizedHTML: "<p>shows</p>", finalURL: url.absoluteString, contentHash: hash) }
    }

    // Every part of the tail names itself, so the screen has something true to say for the whole of it.
    @Test func theTailAfterTheFetchLoopReportsEachOfItsSteps() async throws {
        let ctx = try context()
        source(ctx, "a", lastHash: "old")
        var steps: [ScoutSweepStep] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: defaults(),
            onNativeStep: { steps.append($0) })

        #expect(steps == [.handingPagesToTheReader, .checkingBookings, .clearingBlockedTowns, .saving])
    }

    // The steps land AFTER the last counted source, which is the point: the gap they fill starts where the
    // count stops. Ordering, not merely presence, because a step reported before the loop ended would be
    // describing something that had not started.
    @Test func theStepsComeAfterTheLastCountedSource() async throws {
        let ctx = try context()
        for id in ["a", "b"] { source(ctx, id, lastHash: "old") }
        var timeline: [String] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: defaults(),
            onNativeProgress: { _, index, _ in timeline.append("source \(index)") },
            onNativeStep: { timeline.append("step \($0.rawValue)") })

        #expect(timeline.prefix(2) == ["source 1", "source 2"])
        #expect(timeline.dropFirst(2).allSatisfy { $0.hasPrefix("step ") })
        #expect(timeline.count > 2, "the tail must report something at all")
    }

    // A run with nothing to hand over still reports the rest of the tail. That case is the whole of a
    // quiet night: every page unchanged, nothing to read, and the store still swept for bookings and
    // saved. A screen that went silent exactly then would go silent on the most ordinary run there is.
    @Test func arunWithNothingToReadStillReportsTheRestOfTheTail() async throws {
        let ctx = try context()
        source(ctx, "a", lastHash: "same")
        var steps: [ScoutSweepStep] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("same"),
            pin: { _, _ in URL(fileURLWithPath: "/tmp/x.html") }, launch: { _ in },
            defaults: defaults(),
            onNativeStep: { steps.append($0) })

        #expect(!steps.contains(.handingPagesToTheReader), "there was nothing to hand over")
        #expect(steps == [.checkingBookings, .clearingBlockedTowns, .saving])
    }

    // The failure path: the hand-off throws (the runner is not configured). The steps after it must still
    // report, or a run that hit the one problem Dan is most likely to hit would go dark for its whole
    // remainder, which is the state that reads as a hung app.
    @Test func atailThatFailedToHandOverStillReportsWhatItDoesNext() async throws {
        let ctx = try context()
        source(ctx, "a", lastHash: "old")
        var steps: [ScoutSweepStep] = []
        struct Nope: Error {}

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in throw Nope() },
            defaults: defaults(),
            onNativeStep: { steps.append($0) })

        #expect(steps.contains(.handingPagesToTheReader))
        #expect(steps.suffix(3) == [.handingPagesToTheReader, .clearingBlockedTowns, .saving]
                || steps.suffix(3) == [.checkingBookings, .clearingBlockedTowns, .saving])
        #expect(steps.last == .saving, "the run still finished, so it still said so")
    }

    // Each step has a sentence, and none of them is empty. The screen shows exactly this string, so an
    // empty one is a blank line where the only evidence of life was supposed to be.
    @Test func everyStepHasSomethingToSay() {
        for step in ScoutSweepStep.allCases {
            #expect(!step.line.isEmpty)
            #expect(step.line.first?.isUppercase == true)
        }
        #expect(Set(ScoutSweepStep.allCases.map(\.line)).count == ScoutSweepStep.allCases.count,
                "two steps sharing a sentence would be a screen that stops changing halfway through")
    }
}

// #2201. When the sweep parks on the read-budget question the count stops advancing, the sweep's
// heartbeat goes stale, and at RunTimeouts.scout the panel rendered "Scouting looks stuck" with a Retry
// beside it. Nothing was stuck: the run was waiting on an answer, and the message pointed Dan away from
// the one action that would have delivered it (L11).
//
// Retry compounded it. A Task suspended on `withCheckedContinuation` is not cancellable, so cancelling it
// leaked the parked run and its pending question while a second full sweep started and ended in the same
// place.
@Suite("A run waiting on Dan is not a run that is stuck (#2201)")
struct WaitingOnAnAnswerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let timeout: TimeInterval = 180

    // The defect, at the moment it appeared: past the timeout, with a stale heartbeat, which is exactly
    // what a parked run looks like to every other signal.
    @Test func arunParkedOnAQuestionIsNotCalledStuck() {
        let now = start.addingTimeInterval(600)
        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout, heartbeat: .stale)
                == .stalled(elapsed: "10:00"), "the premise: this is what it looks like otherwise")

        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout, heartbeat: .stale,
                                     waitingOnAnswer: true)
                == .waitingOnYou(elapsed: "10:00"))
    }

    // And the counter keeps ticking in it, which is what tells a waiting screen from a frozen one.
    @Test func theWaitingStateStillShowsTheRunIsAlive() {
        let line = RunProgress.waitingOnYouLabel(elapsed: "4:28")
        #expect(line.contains("4:28"))
        #expect(!line.contains("stuck"))
    }

    // A stop Dan asked for outranks waiting. He has decided; telling him the run is waiting on him after
    // he pressed Cancel would be the app asking a question he has already closed.
    @Test func astopHeAskedForOutranksTheQuestion() {
        let now = start.addingTimeInterval(600)
        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout, heartbeat: .stale,
                                     cancelRequested: true, waitingOnAnswer: true)
                == .stopping(elapsed: "10:00"))
    }

    // A marker that has GONE means the run is over, whatever it was waiting for.
    @Test func arunThatHasEndedIsOverEvenIfSomethingWasAsked() {
        let now = start.addingTimeInterval(600)
        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout, heartbeat: .absent,
                                     waitingOnAnswer: true)
                == .finishing(elapsed: "10:00"))
    }

    // Nothing waiting behaves exactly as before, so every caller with no question to ask is untouched.
    @Test func arunWithNothingToAskIsUnaffected() {
        let now = start.addingTimeInterval(60)
        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout, heartbeat: .beating)
                == .running(elapsed: "1:00"))
    }
}

// The wiring, which is a separate claim from the states being right (L3).
@Suite("The scout takeover and Retry honour a waiting run (#2201, #2203)")
struct ScoutWaitingWiringGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func theTakeoverIsToldWhenTheRunIsWaiting() throws {
        let modal = try #require(SourceGuardHelper.propertyBody(
            "private var scoutProgressModal: some View {", in: source))
        #expect(modal.contains("waitingOnAnswer: { scoutReadAsk != nil }"))
    }

    // Retry withholds itself in the waiting state (RunProgressView offers it only when stalled), and
    // refuses again here if it is ever reached another way. Two guards, because the cost of getting this
    // wrong is a leaked suspended run plus a second full 68-source sweep (L70: not one check twice).
    @Test func retryRefusesToAbandonARunThatIsWaiting() throws {
        let retry = try #require(SourceGuardHelper.bodyOfFunction(named: "retryScout", in: source))
        #expect(retry.contains("if let ask = scoutReadAsk { askReadBudget(ask); return }"))

        let view = SourceGuardHelper.source("Overture/UI/RunProgressView.swift")
        #expect(view.contains("if case .stalled = state, let onRetry {"),
                "Retry is offered in the stalled state only, so a waiting run never shows it")
    }

    // Cancelling a parked run answers its question, or the stop leaks the run instead of ending it.
    @Test func cancellingAParkedRunAnswersItsQuestion() throws {
        let cancel = try #require(SourceGuardHelper.bodyOfFunction(named: "cancelScout", in: source))
        #expect(cancel.contains("scoutReadAsk?.replyIfUnanswered()"))
    }

    // #2203: the tail's steps reach the snapshot the takeover reads, and they keep `advancedAt` moving,
    // which is the sweep's only evidence of being alive.
    @Test func theTailStepsReachTheTakeoverAndKeepItAlive() {
        #expect(source.contains("onNativeStep: { step in"))
        #expect(source.contains("advancedAt: Date(), step: step)"))
    }
}
