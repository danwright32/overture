import Testing
import Foundation
import SwiftData

// Regression guard for the in-app Send-button deadlock: the @MainActor send path once
// blocked the main thread on a synchronous semaphore bridge while awaiting main-actor
// token work, so a real Send click froze the app. Two complementary layers:
//
//  1. Behavioral: drive SendService.sendOne (the button's real entry point) on the main
//     actor through a sender that must hop back to the main actor mid-send, under a
//     watchdog. If the main thread is ever blocked instead of completing, the watchdog
//     turns a hung suite into a fast, legible failure.
//  2. Static: fail if any blocking primitive reappears in the send/auth source files,
//     so the fix can't be silently undone even by a path the behavioral test can't reach.
//
// The suite is deliberately NOT @MainActor: the watchdog must be free to resume on a
// background thread to report a timeout even while the main actor is wedged.
@Suite("Send deadlock guard")
struct SendDeadlockGuardTests {

    // A sender whose send() awaits @MainActor-isolated work before returning, mirroring the
    // real GmailSender awaiting the main-actor access token. If sendOne (or anything it
    // calls) blocks the main thread again, this await cannot resume.
    private struct MainHopSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            await Self.mainActorTokenHop()
            return SentReceipt(threadId: "t-guard", messageID: "<guard@x.org>")
        }
        @MainActor private static func mainActorTokenHop() async {}
    }

    // A send that takes far longer than the watchdog but is cancellable, used to prove the
    // watchdog reports a too-slow send as a timeout. Cancellable (Task.sleep) so the losing
    // racer actually unwinds instead of leaking a suspended task into the shared test host.
    private struct SlowSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return SentReceipt(threadId: "slow")
        }
    }

    // Builds an approved, sendable prospect in an in-memory store and sends it, all on the
    // main actor so the SwiftData model never crosses an isolation boundary. Returns whether
    // the send completed.
    @MainActor private static func sendOne(with sender: MailSender) async -> Bool {
        let container = try! ModelContainer(
            for: Schema([Prospect.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let p = Prospect(naturalKey: "guard", groupName: "Guard", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
        ctx.insert(p)
        p.setRecipients([Recipient(id: "to@org.org", email: "to@org.org", provenance: .act)])
        try? ctx.save()
        return await SendService.sendOne(p, now: Date(), sender: sender)
    }

    // Resolves a continuation exactly once, whichever racer gets there first.
    private actor FirstToFinish<T: Sendable> {
        private var cont: CheckedContinuation<T, Never>?
        init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
        func settle(_ value: T) { cont?.resume(returning: value); cont = nil }
    }

    // Runs op, but gives up after `seconds`, so a blocked or stuck send becomes a fast failure
    // (nil) instead of a hung suite. The op and the timer race; the continuation resolves on
    // whichever finishes first, then BOTH racers are cancelled so the loser unwinds rather than
    // leaking a suspended task into the shared test host. Not main-actor isolated, so the
    // continuation can resume on a background thread even while the main actor is blocked.
    private func completes<T: Sendable>(within seconds: Double,
                                        _ op: @escaping @Sendable () async -> T) async -> T? {
        let work = Task<T?, Never> { await op() }
        let timer = Task<T?, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let winner: T? = await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let race = FirstToFinish(cont)
            Task { await race.settle(await work.value) }
            Task { await race.settle(await timer.value) }
        }
        work.cancel()
        timer.cancel()
        return winner
    }

    @Test func sendOneOnTheMainActorCompletesWithoutBlocking() async {
        let outcome = await completes(within: 5) { await SendDeadlockGuardTests.sendOne(with: MainHopSender()) }
        #expect(outcome == true,
                "SendService.sendOne did not complete within the watchdog window — the Send path may be blocking the main thread again.")
    }

    @Test func watchdogReportsAStuckSendInsteadOfHanging() async {
        // Proves the guard above can actually fail: a send that doesn't finish in time is
        // reported as a timeout (nil), not an indefinitely hung test.
        let outcome = await completes(within: 0.5) { await SendDeadlockGuardTests.sendOne(with: SlowSender()) }
        #expect(outcome == nil)
    }

    @Test func sendAndAuthSourceHasNoBlockingPrimitives() throws {
        // #filePath resolves to .../mac/OvertureTests/SendDeadlockGuardTests.swift at compile
        // time; walk up to the source tree and scan the four files that make up the send path.
        let integration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/Integration")
        let files = ["GmailSender.swift", "SendService.swift", "GmailAuthManager.swift", "MailSender.swift"]
        let forbidden = ["DispatchSemaphore", "runBlocking", ".wait()", "DispatchQueue.main.sync", ".sync {"]
        for file in files {
            let src = try String(contentsOf: integration.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                #expect(!src.contains(token),
                        "\(file) reintroduced a blocking primitive (\(token)) — the Send path must stay fully async so the Send button can't deadlock the app.")
            }
        }
    }
}
