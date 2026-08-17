import Foundation

// #2712: attach the Gmail conversation a hire inquiry is actually on, so an inquiry Dan answered in his
// own mailbox is watched for replies like every other one.
//
// The defect this closes: `Inquiry.gmailThreadId` had exactly one writer, `InquiryReplySender` stamping
// it from the receipt after an answer sent from inside Overture, and `GmailReplyChecker.threadsToCheck`
// skips anything whose thread id is empty. Answering in Gmail is the natural thing to do when the mail is
// already open in front of him, and doing it meant the inquiry was never watched at all.
//
// It is the SAME mechanism a form pitch got in #2713 to #2718, not a second one beside it (L30): the same
// one-search-per-tick mailbox read supplies the candidates, the same message-level refusals apply, and the
// same attach-and-detect-in-one-write records it. What differs is the identification, and it differs in
// the direction that removes work rather than adding it. A form pitch has no address to search on, so it
// is scored and the top candidate is put to Dan as a question he confirms, because confirming writes an
// address onto the contact and future email goes there. An inquiry already carries the address it came
// from, so the match is identity (`ReplyCandidateMatch.inquiryMatch`) and there is nothing to adjudicate:
// asking "is this their reply?" about a message from the exact address he recorded would be a question
// with one possible answer.
//
// Read only against Gmail. It uses the `gmail.readonly` scope already granted and there is no path here
// that can send anything.
@MainActor
struct InquiryConversationAttach {

    // What the pass established. `unreadable` is its own fact rather than folded into "nothing attached",
    // because a thread Gmail refused and an inquiry nobody wrote to are different things and only one of
    // them means something is wrong (L10, L11). `notConnected` says no attempt was made at all.
    struct Outcome: Equatable, Sendable {
        var attached = 0
        var unreadable = 0
        var notConnected = false
        // #2798: how many inquiries this pass MATCHED and therefore tried to read a thread for. Without
        // it `unreadable` is a bare count with nothing to judge it against, and the two things worth
        // telling apart, one thread Gmail happened to refuse and Gmail refusing every one of them, look
        // the same from a number alone.
        var threadsTried = 0

        // #2798: a RATE, not a count, and the same rule `GmailReplyChecker.Outcome` already applies to
        // the thread watcher (#2741). One refused thread on a tick is ordinary contention and waking Dan
        // for it teaches him to ignore the line; every thread on a tick is Gmail being down or a token
        // being dead, which is the thing he has to know (L77).
        //
        // A pass that matched NOTHING is not an outage: `threadsTried > 0` is what says the question was
        // asked at all, and finding no subjects is its own outcome rather than a pass (L98).
        var everyThreadUnreadable: Bool { threadsTried > 0 && unreadable == threadsTried }
    }

    // #949: the same sending identity every other Gmail path reads, so what counts as Dan's own mail
    // cannot drift from what actually sends.
    var fromEmail: String = SendIdentity.danWright.email

    // `token` and `fetch` are injected, defaulting to the real ones, so the whole decision path runs with
    // no network and no live mailbox (L2).
    @discardableResult
    func run(inquiries: [Inquiry],
             candidates: [GmailReplySearch.InboundMessage],
             now: Date,
             token: String? = nil,
             fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async -> Outcome {
        // The scope is asked of the SAME predicate the mailbox read selected by, so this pass cannot act
        // on an inquiry the search never read for (L16).
        let subjects = inquiries.filter { ReplySearchScope.inScope($0, now: now) }
        guard !subjects.isEmpty else { return Outcome() }

        var accessToken = token
        if accessToken == nil {
            guard GmailConnection.shared.refreshedIsConnected(),
                  let fresh = try? await GmailAuthManager.shared.validAccessToken() else {
                return Outcome(notConnected: true)
            }
            accessToken = fresh
        }
        guard let accessToken else { return Outcome(notConnected: true) }
        let fetcher = fetch ?? { try await GmailNetworking.session.data(for: $0) }

        var outcome = Outcome()
        for inquiry in subjects {
            guard let match = ReplyCandidateMatch.inquiryMatch(candidates, for: inquiry,
                                                               selfEmail: fromEmail) else { continue }
            // Counted BEFORE the read, so `unreadable` is judged against what was attempted rather than
            // against what succeeded. Counted after the match, deliberately: an inquiry nobody wrote to
            // was never a thread this pass could read, and folding it in would put the rate below the
            // bar on exactly the tick where Gmail refused everything it did try (#2798).
            outcome.threadsTried += 1
            // The metadata thread is what detection reads and what the attach cannot proceed without. A
            // thread Gmail refuses leaves the inquiry exactly as it was: stamping the id and detecting
            // nothing would leave the row holding a conversation, no reply and no parent message, which is
            // the half state the one-write design exists to avoid (L12).
            guard let metadata = await read(ConfirmProposedConversation.threadURL(id: match.threadId,
                                                                                 format: "metadata"),
                                            token: accessToken, fetch: fetcher) else {
                outcome.unreadable += 1
                continue
            }
            // The bodies, so the words are captured in the same write. Best effort, exactly as it is for
            // the pitch attach: a thread whose full form cannot be read still attaches.
            let full = await read(ConfirmProposedConversation.threadURL(id: match.threadId, format: "full"),
                                  token: accessToken, fetch: fetcher)
            let result = AttachConversation.attach(threadId: match.threadId, threadJSON: metadata,
                                                   fullThreadJSON: full, to: inquiry,
                                                   selfEmail: fromEmail, now: now)
            if case .attached = result { outcome.attached += 1 }
        }
        return outcome
    }

    // copy-inventory:ignore-start  an HTTP header, not a sentence (#915)
    private func read(_ url: URL?, token: String,
                      fetch: (URLRequest) async throws -> (Data, URLResponse)) async -> Data? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
    // copy-inventory:ignore-end
}
