import Foundation
import SwiftData

// #2649: repair the stored Message-ID on conversations that are still live.
//
// #2647 fixed what a SEND stores from that point on, by reading the real Message-ID back off the sent
// message instead of storing the one Overture minted. It could not touch what was already in the store:
// Gmail discarded every `<UUID@danwrightphotography.com>` id Overture put on the wire and assigned its
// own, so every id written by a past send references a message that exists nowhere. Gmail's own web view
// still grouped those threads, because the send also passes Gmail's internal threadId, which is why this
// went unnoticed; every standards based client (Spark, Apple Mail, Outlook) threads on the headers and
// filed a second conversation.
//
// Already sent mail cannot be repaired. Live conversations can, and they are the point: these are shows
// Dan is still waiting on, so their next nudge is the one that matters.
//
// Read only, and one pass. It never sends, never blanks a stored id, and never substitutes a message it
// cannot show belongs to Dan.
@MainActor
struct GmailThreadingRepair {
    // What the pass did, in four separate counts rather than one number. "Nothing to do" and "could not
    // reach Gmail" are different outcomes and must not share a field (L11, L53): a repair that reached no
    // threads at all would otherwise be indistinguishable from one where every row was already correct.
    // There is deliberately NO "already correct" count. A row Gmail has already stamped is not selected at
    // all (see the selection below), so such a count could only ever be written if Gmail had honoured an
    // id Overture supplied, which #2647 established it does not. It would read zero forever, and a zero
    // is indistinguishable from a real measurement (L90).
    struct Outcome: Equatable {
        var repaired = 0        // a real id replaced what was stored
        var refused = 0         // the thread read fine, and no message of Dan's on it could be identified
        var unreadable = 0      // Gmail could not be read for this row's thread
        // The repairs above are a claim about the STORE, so they are only true once the write commits.
        var saveFailed = false
    }

    // The same sending identity the send path and the reply watcher read, so what counts as "Dan's own
    // message" cannot drift from what actually sends (#949).
    var fromEmail: String = SendIdentity.danWright.email

    // Connected, with a token in hand. Nil means Gmail is not connected, which is not the same as a pass
    // that ran and found nothing to do, so the caller can say which happened rather than reporting an
    // empty repair either way (L11, L98).
    @discardableResult
    func repair(in context: ModelContext) async -> Outcome? {
        guard GmailConnection.shared.refreshedIsConnected(),
              let token = try? await GmailAuthManager.shared.validAccessToken() else { return nil }
        return await repairMessageIds(in: context, token: token)
    }

    // The testable core: a token in hand and an injected fetch, so the whole decision path runs with no
    // network and no live mailbox (L2).
    @discardableResult
    func repairMessageIds(
        in context: ModelContext,
        token: String,
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) }
    ) async -> Outcome {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        // `try?` keeps a container that predates Inquiry (an older test harness) working: it yields none,
        // the same allowance GmailReplyChecker makes for the same reason.
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        let all: [any ReplyWatchableRecipient] = prospects.flatMap(\.replyWatchRecipients)
            + inquiries.map { $0 as any ReplyWatchableRecipient }

        // One read per CONVERSATION, not per row. #2046 sends one email to several contacts, so several
        // rows share a thread, and the newest message Dan sent on it is a fact about the conversation that
        // is equally true of every contact on it (L66). Reading it once per row would be the same answer
        // bought several times.
        var rowsByThread: [String: [any ReplyWatchableRecipient]] = [:]
        for row in all {
            guard let thread = row.gmailThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !thread.isEmpty else { continue }
            // Only rows still holding an id Gmail cannot have assigned. This is what makes the pass ONE
            // pass without needing a marker file or a "has it run" flag to be kept honest: a repaired row
            // now stores a `mail.gmail.com` id, so it is never selected again, and the selection empties
            // itself. A marker would be a second record of the same fact, able to drift from it (L41), and
            // one written before the work finished would make a half-done pass look complete.
            //
            // A row that is selected and then REFUSED keeps its minted id, so it is re-read on later
            // ticks. That is deliberate rather than overlooked: the read is a free metadata GET, bounded
            // by the number of live conversations, and a thread with nothing of Dan's on it today can
            // gain one, so refusing permanently would be the guard that outlives its reason.
            // #2717: never a conversation Overture did not send on. The selection above deliberately
            // takes a row with NO stored id, because a send whose read back failed needs the same repair;
            // an ATTACHED conversation (#2715) also has no stored id, and repairing it would be actively
            // wrong twice over. The premise of the manual route is that Dan found the reply in Gmail, and
            // the ordinary thing to do there is answer it, so his own hand sent message is on that thread:
            // `latestSentMessageID` would find it and store it, flipping the contact into "Overture
            // emailed them" and putting the follow-up and closing note paths back in front of him on the
            // one row they must never reach. And if he has NOT answered, the refusal branch below would
            // set `threadingDegraded` on a conversation that threads perfectly well, warning him about a
            // fault that does not exist (L11).
            guard !row.replyWatchConversationIsAttached else { continue }
            guard GmailMessage.isLocallyMintedMessageID(row.gmailMessageId, senderEmail: fromEmail)
            else { continue }
            rowsByThread[thread, default: []].append(row)
        }

        var outcome = Outcome()
        var wrote = false
        // Sorted so a run is reproducible and its log reads the same way twice; a dictionary's order is
        // not stable between runs.
        for thread in rowsByThread.keys.sorted() {
            let rows = rowsByThread[thread] ?? []
            guard let data = await fetchThread(id: thread, token: token, fetch: fetch) else {
                outcome.unreadable += rows.count
                continue
            }
            guard let realID = ReplyDetection.latestSentMessageID(threadJSON: data, selfEmail: fromEmail) else {
                // Read fine, and named no message of Dan's to reference. The stored value is left exactly
                // as it is, and the row RECORDS that it could not be repaired rather than the pass
                // shrugging: a conversation whose next follow-up cannot thread is a fact Dan can act on,
                // and `threadingDegraded` is the flag #2647 already surfaces through the
                // `.sendThreadingDegraded` focus (L11, L47). Not set on an unreadable thread above,
                // deliberately: that says Gmail was unreachable, not that this conversation is unthreadable.
                outcome.refused += rows.count
                for row in rows where !row.threadingDegraded {
                    row.threadingDegraded = true
                    wrote = true
                }
                continue
            }
            for row in rows {
                if row.gmailMessageId != realID {
                    row.gmailMessageId = realID
                    outcome.repaired += 1
                    wrote = true
                }
                // Repaired or already right, this conversation threads now, so a flag set by an earlier
                // refusal or by a send whose read back failed must not outlive the reason for it.
                if row.threadingDegraded {
                    row.threadingDegraded = false
                    wrote = true
                }
            }
        }

        // The counts describe what is IN THE STORE, so they are only true once the write commits. A pass
        // that repaired rows and then failed to save has changed nothing, and reporting the repairs anyway
        // would be success UI over a write that did not land (L12).
        if wrote {
            do {
                try context.save()
            } catch {
                outcome.saveFailed = true
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                AgentLog.note("[Overture] The threading repair could not save: \(error)")
                // copy-inventory:ignore-end
            }
        }
        return outcome
    }

    // Read only, and metadata only. A GET against the threads endpoint, which is what `thePassNeverSends`
    // asserts rather than assumes.
    //
    // #2928: through `GmailThreadHeaders` like every other thread read, rather than naming the two headers
    // this pass happens to need. The list is the union of what every thread reader reads, so a reader
    // reached from here later cannot silently find its header missing, and the extra names ride a response
    // that is already being fetched.
    // copy-inventory:ignore-start  a Google API URL and an HTTP header, not sentences Overture says (#915)
    private func fetchThread(
        id: String, token: String,
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Data? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/" + escaped
                            + "?" + GmailThreadHeaders.metadataQuery)
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
    // copy-inventory:ignore-end
}
