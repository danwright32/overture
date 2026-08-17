import Foundation
import SwiftData

// Live reply watcher (#40): fetches the Gmail threads of already-sent prospects and marks
// any that received a reply. Read-only Gmail access; never sends. Skips silently when
// Gmail isn't connected or the token can't refresh (auth handling lives in
// GmailAuthManager, #50). The marking decision is the tested ReplyService/ReplyDetection.
@MainActor
struct GmailReplyChecker {
    // #949: Dan's own address (used to tell his sends apart from a stranger's reply) is the same
    // sending identity the send path and the confirmation use, read from the one SendIdentity source
    // so it can never drift from what actually sends.
    var fromEmail: String = SendIdentity.danWright.email

    // #2741: what one pass of the watcher actually established.
    //
    // It used to answer `Bool`, meaning "a save failed", and that single answer was shared by "Gmail is
    // not connected", "nothing was found" and "found something and saved it". So the one thing the tick
    // could report was the one failure mode that is not the common one, and a read that FAILED was
    // indistinguishable from a conversation nobody answered. The product was quietest exactly when it had
    // stopped working (L10, L11, L98).
    struct Outcome: Equatable, Sendable {
        var notConnected = false     // no attempt was made, which is not a failure
        var threadsChecked = 0       // threads this pass tried to read
        var unreadable = 0           // ...and could not read. Gmail refused, or could not be reached
        var saveFailed = false       // something was found and could not be persisted (#499)

        // #2741 step 5: a RATE, not a count. One unreadable thread on a tick is ordinary contention and
        // waking Dan for it teaches him to ignore the alert; every thread on a tick is Gmail being down
        // or a token being dead, which is the thing he has to know (L77).
        //
        // A pass with nothing to check is not an outage: `threadsChecked > 0` is what says the question
        // was asked at all, and finding no subjects is its own outcome rather than a pass (L98).
        var everyThreadUnreadable: Bool { threadsChecked > 0 && unreadable == threadsChecked }
    }

    // #499: reports whether a detected reply's context.save() failed, so the caller can surface it
    // instead of it failing silently.
    @discardableResult
    func checkReplies(in context: ModelContext, now: Date = Date()) async -> Outcome {
        // #1770: the periodic check is a natural place to notice a credential that died since launch,
        // and it is nowhere near a render path, so it pays for a fresh read.
        //
        // #2741: `notConnected` rather than a bare false. Nothing was attempted, so this pass established
        // nothing about anybody's replies, and saying so is different from saying nobody wrote.
        guard GmailConnection.shared.refreshedIsConnected(),
              let token = try? await GmailAuthManager.shared.validAccessToken() else {
            return Outcome(notConnected: true)
        }
        return await markReplies(in: context, token: token, now: now)
    }

    // The testable core: with a token in hand and an injected fetch, pull each unresolved
    // sent prospect's thread and mark replies via the tested ReplyService. No auth/connection
    // gating here, so a fake thread response can drive the marking without network (#84).
    @discardableResult
    func markReplies(
        in context: ModelContext,
        token: String,
        now: Date = Date(),
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) }
    ) async -> Outcome {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        // #1435: hire inquiries ride the SAME reply/bounce pipeline as a single self-thread. `try?`
        // keeps a container that predates Inquiry (an older test harness) working: it just yields none.
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        let all: [any ReplyWatchable] = prospects.map { $0 as any ReplyWatchable }
            + inquiries.map { $0 as any ReplyWatchable }
        // Watch EVERY sent recipient's own thread (#418 A2), not just the lead's first-send thread,
        // so a reply to any contact is seen. Skip a show only on a MANUAL lead resolution or a booking
        // (a closed show); never on the auto .replied rollup, or a second contact's reply would be missed.
        // An inquiry presents itself here as its own single recipient.
        let threadIds = Self.threadsToCheck(in: all)
        guard !threadIds.isEmpty else { return Outcome() }

        var outcome = Outcome(threadsChecked: threadIds.count)
        var threads: [String: Data] = [:]
        for id in threadIds {
            // #2741: an unreadable thread is COUNTED rather than quietly omitted. Omitted, it reached
            // `detectReplies` as a thread with no reply on it, so a 401 after a token expiry and a
            // genuinely quiet conversation produced the same answer and the row went on saying nobody
            // had written.
            switch await fetchThread(id: id, token: token, format: "metadata", fetch: fetch) {
            case .ok(let data): threads[id] = data
            case .unreadable: outcome.unreadable += 1
            }
        }
        // Full-fetch the body ONLY for threads that actually have a reply (lazy), so the classify
        // workflow (#112) gets the reply text without pulling full bodies for the whole sent list.
        var fullThreads: [String: Data] = [:]
        for (id, data) in threads where ReplyDetection.hasReply(
            fromAddresses: ReplyDetection.fromAddresses(threadJSON: data), selfEmail: fromEmail) {
            // A full fetch that fails is NOT counted again: the metadata read already established this
            // thread is reachable and has a reply on it, so the row is not at risk of reading as quiet.
            // Counting it would inflate the rate the outage check reads (L63).
            if case .ok(let full) = await fetchThread(id: id, token: token, format: "full", fetch: fetch) {
                fullThreads[id] = full
            }
        }
        let repliesMarked = ReplyService.detectReplies(in: all, selfEmail: fromEmail, now: now,
                                                       fetchThread: { threads[$0] }, fetchFullThread: { fullThreads[$0] })
        let bouncesMarked = BounceService.detectBounces(in: all, selfEmail: fromEmail, now: now,
                                                        fetchThread: { threads[$0] })
        // #2113: name the writer on threads that replied before any of this was recorded. Runs after
        // detection, so a reply found on this very pass has already named its own writer and is skipped.
        let respondersFilled = ReplyService.backfillResponders(in: all, selfEmail: fromEmail, now: now,
                                                               fetchThread: { threads[$0] },
                                                               fetchFullThread: { fullThreads[$0] })
        guard repliesMarked > 0 || bouncesMarked > 0 || respondersFilled > 0 else { return outcome }
        do {
            try context.save()
        } catch {
            // #499: replies were detected in memory but couldn't persist.
            outcome.saveFailed = true
        }
        return outcome
    }

    // Which Gmail threads this check pulls. Out of the method body and made testable in #2149, because the
    // question it answers is the same one its readers ask, and the two drifting is what produced a
    // permanent refetch loop: the checker went on pulling a thread the fill had already given up on.
    //
    // #2815: it is TWO questions, and asking only the first is what left a second message on an answered
    // conversation unfetched for ever. A never-replied row is watched because a reply might arrive. A
    // replied row is watched while it still has a gap something could fill (`ReplyGap`) OR while its
    // conversation is still open and could carry a new message (`ReplyWatchScope`). `detectReplies`
    // decides the second half with the same predicate, so the fetcher and the detector cannot disagree
    // about which conversations are live (L16, L70).
    //
    // #2717: an ATTACHED conversation (#2715) joins this list on exactly the same terms, and that is the
    // feature rather than an oversight: watching it is the whole reason Dan links it. Detection itself
    // (`ReplyService`) is unchanged for the same reason. The readers that had to change are the ones that
    // would WRITE to the conversation or blame this contact for something on it, not the ones that read it.
    static func threadsToCheck(in entities: [any ReplyWatchable]) -> Set<String> {
        var threadIds: Set<String> = []
        for p in entities {
            if p.replyWatchManualOutcome || p.replyWatchIsBooked { continue }
            for r in p.replyWatchRecipients {
                guard let t = r.gmailThreadId, !t.isEmpty,
                      !r.replyWatchManualOutcome, !r.replyWatchIsBooked else { continue }
                guard ReplyWatchScope.isWatched(r) else { continue }
                threadIds.insert(t)
            }
        }
        return threadIds
    }

    // #2741: the data, or the fact that it could not be read. It used to answer `Data?`, and every caller
    // read nil as "no thread", which is how a refusal became a quiet conversation. The same shape as
    // `GmailReplySearch.Read` (#2713) and `GmailThreadingRepair.Outcome`, which separate these already.
    enum ThreadRead: Equatable {
        case ok(Data)
        case unreadable
    }

    private func fetchThread(
        id: String, token: String, format: String = "metadata",
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> ThreadRead {
        // Subject is included alongside From (#398) so a hard-bounce notification can be told
        // apart from a temporary delay purely from metadata, no full-body fetch needed.
        let query = format == "metadata" ? "format=metadata&metadataHeaders=From&metadataHeaders=Subject" : "format=full"
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(id)?\(query)") else { return .unreadable }
        var req = URLRequest(url: url)
        // copy-inventory:ignore-start  the HTTP Authorization header Google reads, not a sentence
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // copy-inventory:ignore-end
        guard let (data, resp) = try? await fetch(req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unreadable }
        return .ok(data)
    }
}
