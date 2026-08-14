import Foundation
import SwiftData

// #2713: read the mailbox for a reply to a pitch Overture cannot watch.
//
// Overture watches for replies by fetching the Gmail thread named on `Recipient.gmailThreadId`. A pitch
// sent through a contact form or a social DM deliberately never stamps it, which was right at the time
// and leaves no way to be told when the presenter writes back by email. Measured live 2026-08-14: a
// form pitch through caseengaines.com was answered from a gmail.com address, and Overture knew nothing
// about it while the row went on saying it could not see a reply to that one.
//
// This half only FINDS the messages that could be an answer. It never ranks them (#2714 does, and it is
// where the refusals live), never writes a conversation onto a contact (#2715), and never puts a
// question in front of Dan (#2718). Its candidates therefore have no reader in this change beyond its
// own tests, which is stated rather than hidden: #2714 is the issue that consumes them.
//
// Read only. It uses the `gmail.readonly` scope already granted, so it needs no re-authorisation, and
// there is no code path here that can send anything.
@MainActor
struct GmailReplySearch {

    // One inbound message that could be an answer to a pitch. Metadata only: this is everything a
    // `format=metadata` get returns that the decision needs, and nothing that would require pulling a
    // body for mail that is almost all not going to be a candidate at all.
    struct InboundMessage: Equatable, Sendable {
        var messageId: String
        var threadId: String
        var fromAddress: String
        var fromName: String?
        var subject: String
        var sentAt: Date
        // #2714: the header bulk senders are required to set, and the one honest way to tell a
        // newsletter from a person. `ReplyDetection.isAutomated` catches only mailer-daemon and
        // friends, so `hello@`, `info@` and `boxoffice@` sail straight through it, and guessing at
        // words instead would over-match a personal inbox in a way that reads exactly like the
        // feature working (L104). Free: it rides the metadata get already being made.
        //
        // nil means the header was absent, which is what ordinary personal mail looks like.
        var listUnsubscribe: String?
    }

    // One page of `users.messages.list`, which answers with ids and nothing else.
    struct ListPage: Equatable {
        struct Ref: Equatable {
            var id: String
            var threadId: String
        }
        var messages: [Ref]
        var nextPageToken: String?
    }

    // What the tick did, never a bare array.
    //
    // "Nothing found" is reachable from exactly ONE of these. Every other Gmail read in this app
    // collapses them (`GmailReplyChecker.fetchThread` returns nil on any non-200, and `checkReplies`
    // returns false for both "not connected" and "nothing to save"), so a token expiry or a 429 would
    // otherwise render as a cheerful "nothing found" and tell Dan the presenter never wrote (L10, L11,
    // L98).
    //
    // `.nothingInScope` is a fifth answer the plan did not name, and it is deliberate. A tick with no
    // live form pitch has not read a mailbox and found nothing, it has not read at all. Folding it into
    // `.searched(candidates: [])` would make "Dan has no unwatchable pitches open" indistinguishable
    // from "the mailbox holds no answer to them", and only the second is something a surface is
    // entitled to say to him (L98 on the subject list rather than on the result).
    // `saveFailed` rides `.searched` rather than being a sixth case, because a tick that read the
    // mailbox and found something genuinely did both of those things; what it could not do is REMEMBER
    // that it looked. The candidates are still true and still worth acting on, and only the bookkeeping
    // is in doubt, so collapsing the two into one failure would throw away a real finding. It is not
    // silently swallowed either: it is a claim about the store, so it is only true once the write
    // commits (L12), and the caller can say so.
    enum Outcome: Equatable {
        case notConnected
        case nothingInScope
        case failed(reason: String)
        case searched(candidates: [InboundMessage], searchedThrough: Date?, saveFailed: Bool)
    }

    // #949: the same sending identity the send path and the reply watcher read, so what counts as Dan's
    // own mail cannot drift from what actually sends.
    var fromEmail: String = SendIdentity.danWright.email

    // L110: a wait with no deadline cannot fail, it can only hang, and a hang is worse than a failure
    // because it is indistinguishable from slowness. This joins a tick that already fetches serially, so
    // it gets a deadline of its own and a reason naming what it was waiting for.
    var timeout: TimeInterval = 120

    // The cost ceiling for one tick, in the unit the cost is actually in: one `messages.get` per
    // message. Truncation is announced rather than silent, and it is RESUMABLE rather than lossy, which
    // is the whole reason the messages are read oldest first (see `searchMailbox`).
    static let maxMessagesPerTick = 300
    static let maxListPages = 20

    // MARK: what it says when it cannot answer

    // The only three sentences this file produces. Each names a DIFFERENT thing that went wrong, rather
    // than one apologetic catch-all, because "Gmail refused us", "we could not get there at all" and "we
    // waited and gave up" send whoever reads them in different directions (L11). Their reader arrives
    // with the wiring in #2718; see the note on `Outcome` about where a background failure has to land.
    //
    // "a form or a DM", not "your form pitches", and that is a correction from reading the generated
    // inventory cold rather than a preference. This search covers BOTH, because a DM rides the form
    // path (#2612), and one of the five live pitches went out through Instagram. A line naming only
    // forms would tell Dan the Instagram one was not looked at, which is false.
    static func couldNotRead(status: Int) -> String {
        "Overture couldn't read Gmail while looking for replies to the pitches you sent through a form "
            + "or a DM. Gmail refused the request (HTTP \(status))."
    }
    static let couldNotReachGmail =
        "Overture couldn't reach Gmail while looking for replies to the pitches you sent through a form or a DM."
    static let gaveUpWaiting =
        "Overture gave up waiting for Gmail while looking for replies to the pitches you sent through a form or a DM."

    // MARK: the query

    // Everything inbound since the window opened. There is deliberately no `from:` term: the form's
    // domain is not a match key for the address the presenter answers from, which is exactly what the
    // live sample proved, so narrowing here would drop the one message this exists to find.
    //
    // `after:` takes epoch seconds. Gmail treats it as a search operator rather than an exact filter, so
    // `searchMailbox` re-checks every message's own `internalDate` against the window instead of
    // trusting it.
    // copy-inventory:ignore-start  a Gmail search query, not a sentence Overture says (#915)
    static func query(since: Date) -> String {
        "after:\(Int(since.timeIntervalSince1970)) -from:me -in:chats"
    }
    // copy-inventory:ignore-end

    // MARK: parsing what Gmail returns

    // Nil on anything that is not a list response, so an error body cannot parse as an empty page and
    // read as "the mailbox holds nothing".
    static func parseList(_ data: Data) -> ListPage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // A response with no `messages` key at all is a legitimate empty result; one that is not an
        // object at all is not a response.
        let raw = (root["messages"] as? [[String: Any]]) ?? []
        let refs = raw.compactMap { m -> ListPage.Ref? in
            guard let id = m["id"] as? String, let thread = m["threadId"] as? String else { return nil }
            return ListPage.Ref(id: id, threadId: thread)
        }
        return ListPage(messages: refs, nextPageToken: root["nextPageToken"] as? String)
    }

    // Reads NAMED fields and ignores everything else, so a field Google adds cannot break it.
    //
    // `internalDate` is a STRING holding MILLISECONDS since the epoch, which is the field most easily
    // read wrongly: taken as seconds it dates every message to 1970 and the window drops the lot.
    static func parseMetadata(_ data: Data) -> InboundMessage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["id"] as? String,
              let thread = root["threadId"] as? String,
              let millis = Int64((root["internalDate"] as? String) ?? ""),
              millis > 0 else { return nil }
        let headers = ((root["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }
                .flatMap { $0["value"] as? String } ?? ""
        }
        let from = header("From")
        let address = ReplyDetection.email(from: from)
        guard !address.isEmpty else { return nil }
        let unsubscribe = header("List-Unsubscribe").trimmingCharacters(in: .whitespacesAndNewlines)
        return InboundMessage(messageId: id, threadId: thread, fromAddress: address,
                              fromName: ReplyDetection.displayName(from: from),
                              subject: header("Subject").trimmingCharacters(in: .whitespacesAndNewlines),
                              sentAt: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
                              listUnsubscribe: unsubscribe.isEmpty ? nil : unsubscribe)
    }

    // MARK: the search

    // Connected, with a token in hand. `.notConnected` rather than an empty result, so a tick that never
    // reached Gmail is never reported as one that read it and found nothing.
    func search(in context: ModelContext, now: Date = Date(),
                defaults: UserDefaults = .standard) async -> Outcome {
        guard GmailConnection.shared.refreshedIsConnected(),
              let token = try? await GmailAuthManager.shared.validAccessToken() else { return .notConnected }
        return await searchMailbox(in: context, token: token, now: now, defaults: defaults)
    }

    // The testable core: a token in hand and an injected fetch, so the whole decision path runs with no
    // network and no live mailbox (L2). `clock` is separate from `now` on purpose: `now` is the tick's
    // logical instant, which every date decision is judged against, while `clock` is only ever read to
    // ask whether the deadline has passed, and a test has to be able to move one without the other.
    func searchMailbox(
        in context: ModelContext,
        token: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() },
        // Injected purely so the save-failure path is reachable from a test. A SwiftData in-memory
        // container cannot be made to fail its save on demand, so without this seam the do/catch would be
        // asserted only by reading it, which is exactly how #499's silent `try?` survived. The same seam
        // and the same reason as `ReconcileScheduler.retireShowsThatOpened(now:save:)`.
        save: (() throws -> Void)? = nil,
        fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await GmailNetworking.session.data(for: $0) }
    ) async -> Outcome {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let targets = ReplySearchScope.targets(in: prospects, now: now)
        guard !targets.isEmpty,
              let windowStart = ReplySearchScope.windowStart(
                for: targets, searchedThrough: ReplySearchHighWater.searchedThrough(from: defaults), now: now)
        else { return .nothingInScope }

        let deadline = clock().addingTimeInterval(timeout)

        // The ids first. `messages.list` is cheap (up to 500 ids a call) and answers NEWEST FIRST, so
        // collecting every page and then reversing gives oldest first, which is what makes a truncated
        // tick resumable: the mark can only ever advance to mail that was actually examined, and the
        // next tick picks up from there. Keeping the newest N instead would step the mark over every
        // older message it never looked at, and they would never be read again.
        var refs: [ListPage.Ref] = []
        var pageToken: String?
        var pages = 0
        repeat {
            if clock() > deadline { return .failed(reason: Self.gaveUpWaiting) }
            let listed = await read(Self.listURL(query: Self.query(since: windowStart), pageToken: pageToken),
                                    token: token, fetch: fetch)
            switch listed {
            case .failed(let reason): return .failed(reason: reason)
            case .ok(let data):
                guard let page = Self.parseList(data) else { return .failed(reason: Self.couldNotReachGmail) }
                refs.append(contentsOf: page.messages)
                pageToken = page.nextPageToken
            }
            pages += 1
        } while pageToken != nil && pages < Self.maxListPages

        if pageToken != nil {
            // No silent caps: a run that stopped short says so, because a truncated read that reports
            // like a complete one reads as "the mailbox holds nothing more".
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            AgentLog.note("[Overture] The reply search stopped after \(Self.maxListPages) pages of ids; "
                          + "the next tick resumes from the high-water mark.")
            // copy-inventory:ignore-end
        }

        var candidates: [InboundMessage] = []
        var examinedThrough: Date?
        var examined = 0
        for ref in refs.reversed() {
            guard examined < Self.maxMessagesPerTick else {
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                AgentLog.note("[Overture] The reply search examined \(Self.maxMessagesPerTick) messages "
                              + "this tick and stopped; the next tick resumes from the high-water mark.")
                // copy-inventory:ignore-end
                break
            }
            if clock() > deadline { return .failed(reason: Self.gaveUpWaiting) }
            switch await read(Self.metadataURL(id: ref.id), token: token, fetch: fetch) {
            case .failed(let reason): return .failed(reason: reason)
            case .ok(let data):
                examined += 1
                guard let message = Self.parseMetadata(data) else { continue }
                // Gmail's `after:` is a search operator this code does not control, so the window is
                // enforced here as well. Without it the first tick on a new contact could propose a
                // message that arrived before the pitch was even made.
                if let seen = examinedThrough { examinedThrough = max(seen, message.sentAt) }
                else { examinedThrough = message.sentAt }
                guard message.sentAt >= windowStart else { continue }
                // Dan's own mail is excluded by the query; this is the belt to that brace, since an
                // answer proposed from his own sent copy would name him as the presenter.
                guard message.fromAddress != ReplyDetection.email(from: fromEmail) else { continue }
                candidates.append(message)
            }
        }

        // Only now, and only on a tick that completed. A failed tick above returned before reaching any
        // of this, so it leaves the mark exactly where it was and stamps nobody: the messages it never
        // examined stay unexamined rather than being stepped over for ever.
        for target in targets { target.replyCandidateSearchedAt = now }
        var saveFailed = false
        do {
            if let save { try save() } else { try context.save() }
        } catch {
            saveFailed = true
            // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
            AgentLog.note("[Overture] The reply search could not record that it looked: \(error)")
            // copy-inventory:ignore-end
        }
        // The mark moves only once the stamps are DURABLE, and that ordering is the whole point rather
        // than tidiness. The mark lives in UserDefaults and the stamps live in the store, so a mark that
        // advanced over a save that failed would leave every contact reading as never searched (widening
        // its window back to the pitch) while the mark said that stretch of mailbox was already read.
        // The two would then disagree for ever, in the direction that skips mail (L5, L12).
        if !saveFailed, let examinedThrough { ReplySearchHighWater.record(examinedThrough, into: defaults) }
        return .searched(candidates: candidates, searchedThrough: examinedThrough, saveFailed: saveFailed)
    }

    // MARK: the calls

    // copy-inventory:ignore-start  Google API URLs and an HTTP header, not sentences Overture says (#915)
    static func listURL(query: String, pageToken: String?) -> URL? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: "500")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components?.queryItems = items
        return components?.url
    }

    static func metadataURL(id: String) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + escaped
                   + "?format=metadata&metadataHeaders=From&metadataHeaders=Subject"
                   + "&metadataHeaders=List-Unsubscribe")
    }

    // Two answers, never an optional. A nil body would put "Gmail refused" and "Gmail returned nothing"
    // back into one value, which is the collapse this whole file exists to avoid.
    enum Read {
        case ok(Data)
        case failed(String)
    }

    // A reason on every failure path, carrying the status when there is one, because "Gmail said no" and
    // "Gmail said 401" send whoever reads it in different directions.
    private func read(_ url: URL?, token: String,
                      fetch: (URLRequest) async throws -> (Data, URLResponse)) async -> Read {
        guard let url else { return .failed(Self.couldNotReachGmail) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req) else { return .failed(Self.couldNotReachGmail) }
        guard let http = resp as? HTTPURLResponse else { return .failed(Self.couldNotReachGmail) }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(Self.couldNotRead(status: http.statusCode))
        }
        return .ok(data)
    }
    // copy-inventory:ignore-end
}
