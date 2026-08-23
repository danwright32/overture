import Foundation

// Decides whether a sent email's Gmail thread has a reply (#40): any message from an
// address other than Dan's own. Pure so it's testable without the network; the live
// thread fetch lives in the integration layer.
enum ReplyDetection {

    // #2888: every reader below is handed the body of one Gmail `threads.get`, so they share one name
    // in the failure register. Named for the CALL rather than for the reader, because what is failing
    // is the response, and eight lines saying the same endpoint is unreadable is one condition (L11).
    private static let endpoint = "gmail.threads.get"

    static func hasReply(fromAddresses: [String], selfEmail: String) -> Bool {
        let me = email(from: selfEmail)
        return fromAddresses.contains { raw in
            let e = email(from: raw)
            return !e.isEmpty && e != me && !isAutomated(e)
        }
    }

    // Bounces, postmasters, and no-reply autoresponders aren't real replies; a delivery
    // bounce is the opposite of one. Matched on the local part so a real person isn't
    // excluded by a coincidental domain.
    private static let automatedLocalParts = [
        "mailer-daemon", "postmaster", "no-reply", "noreply",
        "do-not-reply", "donotreply", "auto-reply", "autoreply", "bounce",
    ]
    static func isAutomated(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return automatedLocalParts.contains { matchesToken(local, $0) }
    }

    // True when `local` is exactly `token`, or has it as a prefix or suffix set off by a
    // separator (or the string's edge), rather than merely containing it as a substring, so a
    // real address like "bouncebackband" or "eleanoreply" isn't caught while "noreply-support"
    // or "notifications-noreply" still are.
    // Internal (not private): BounceDetection (#398) reuses this same separator-aware token
    // match instead of duplicating it.
    static func matchesToken(_ local: String, _ token: String) -> Bool {
        guard local.count >= token.count else { return false }
        if local.hasPrefix(token) {
            let after = local.index(local.startIndex, offsetBy: token.count)
            if after == local.endIndex || !(local[after].isLetter || local[after].isNumber) { return true }
        }
        if local.hasSuffix(token) {
            let before = local.index(local.endIndex, offsetBy: -token.count - 1, limitedBy: local.startIndex)
            if before == nil || !(local[before!].isLetter || local[before!].isNumber) { return true }
        }
        return false
    }

    // The bare email out of a From header ("Name <a@b.com>" or "a@b.com"), lowercased.
    static func email(from raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lo = s.firstIndex(of: "<"), let hi = s.firstIndex(of: ">"), lo < hi {
            return String(s[s.index(after: lo)..<hi]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return s.lowercased()
    }

    // From-header values of every message in a Gmail threads.get (metadata) response.
    static func fromAddresses(threadJSON data: Data) -> [String] {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { m in
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { return nil }
            return headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String
        }
    }

    // #2032: are these the same mailbox? Both sides go through `email(from:)`, so a display name, angle
    // brackets and casing are all handled in one place rather than at each comparison.
    static func isSameAddress(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let l = email(from: a), r = email(from: b)
        return !l.isEmpty && l == r
    }

    // #2113: the newest message on the thread that is a REAL reply, meaning not Dan's own and not an
    // automated sender. One definition of that, shared by every reader below, because five of them were
    // walking the messages themselves with the same three-part skip copied out. A change to what counts
    // as a real reply now reaches all of them at once instead of one and not the others (L30).
    private static func latestReplyMessage(threadJSON data: Data, selfEmail: String) -> [String: Any]? {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in newestFirst(messages) {
            let e = email(from: headerValue("from", of: m))
            if e.isEmpty || e == me || isAutomated(e) { continue }
            return m
        }
        return nil
    }

    // #2918: Gmail's `threads.get` returns UNSENT DRAFTS inside `messages`, alongside real mail, and until
    // this nothing on this path looked at `labelIds` at all. A reply Dan started answering in Gmail and
    // abandoned therefore sat on the thread carrying his own address in `From` and an `internalDate` newer
    // than the message it answered, and every reader below that asks "what did Dan send" read it as his
    // answer. `AnsweredElsewhere` stamped `replyHandledAt` off it, `hasUnhandledReply` went false, and
    // `markReplyAnswered` never moves the stamp backwards, so the reply was silenced for good. Measured on
    // a live thread on 2026-08-17: an abandoned draft sat 29 minutes above a real reply, and any check tick
    // inside that window would have buried it. It escaped by timing alone.
    //
    // Gmail already hands over the evidence: a message his mailbox really sent carries `SENT`, and one he
    // is still composing carries `DRAFT`. Both formats this app ever asks for return `labelIds` on every
    // message (`format=metadata` returns ids, labels and headers; `format=full` returns the whole Message),
    // so this costs no extra call and needed no new plumbing.
    //
    // The labels of a message, or nil when the message carries no `labelIds` field at all. The two are
    // kept apart deliberately, because that distinction is the whole of the rule below: an EMPTY list is
    // Gmail saying this message has no labels, and a MISSING one is Gmail not having been asked, or a
    // shape nobody here has seen. Upper-cased on the way out, since these are Gmail's own constants.
    static func labelIds(of message: [String: Any]) -> [String]? {
        guard let raw = message["labelIds"] as? [Any] else { return nil }
        return raw.compactMap { $0 as? String }.map { $0.uppercased() }
    }

    // A message Gmail is holding as an unsent draft. False when the labels are missing, because an absent
    // field is not a claim either way and the refusal below is what fails closed on it.
    static func isDraft(_ message: [String: Any]) -> Bool {
        labelIds(of: message)?.contains("DRAFT") ?? false
    }

    // Did Dan's mailbox actually SEND this message? The predicate every reader here uses before it will
    // let a message stand for something he did.
    //
    // It FAILS CLOSED: no label information means refused, not accepted. The two directions are not
    // symmetrical, which is the reason for the asymmetry in the code. A message wrongly accepted clears a
    // row that is genuinely waiting on him, permanently and silently, which is the defect this exists to
    // end; a message wrongly refused leaves a row asking about a conversation he has closed, which costs
    // him a glance and can be seen and corrected (L42, L98).
    static func wasSentByUser(_ message: [String: Any]) -> Bool {
        guard let labels = labelIds(of: message) else { return false }
        return labels.contains("SENT") && !labels.contains("DRAFT")
    }

    // The thread's real messages, newest first, with the drafts dropped.
    //
    // Dropped rather than treated as fatal, because a draft is not a message anybody has seen: it should
    // not be able to answer "who wrote last", and it should not be able to HIDE the message that can. An
    // abandoned draft can sit on a thread for years, so a rule that simply refused any thread topped by one
    // would silence a real answer of his underneath it for just as long.
    private static func realMessagesNewestFirst(_ messages: [[String: Any]]) -> [[String: Any]] {
        newestFirst(messages).filter { !isDraft($0) }
    }

    // #2649: the mirror of `latestReplyMessage`, and the id a follow-up on this conversation should
    // reference: the Message-ID header of the newest message on the thread that DAN sent.
    //
    // Nil is the whole point of the return type, exactly as it is on #2647's read back. There is no
    // fallback to an older message of his, to the newest message of anybody's, or to a minted value:
    // referencing a message he did not just send threads his next mail onto the wrong one and looks
    // identical to success (L75), and a substituted id is what this whole area exists to end. The caller
    // reports a refusal and leaves the stored value alone.
    //
    // Ordered by `newestFirst`, so it reads internalDate rather than trusting the array's order, and it
    // asks "is this from Dan" through the same `email(from:)` normalisation every other reader here uses,
    // so a display name or angle brackets cannot make his own message look like a stranger's.
    static func latestSentMessageID(threadJSON data: Data, selfEmail: String) -> String? {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        guard !me.isEmpty else { return nil }
        for m in realMessagesNewestFirst(messages) {
            guard email(from: headerValue("from", of: m)) == me else { continue }
            // #2918: only a message Gmail actually sent. Storing a draft's Message-ID would thread his next
            // follow-up onto something nobody ever received, and the row would read as threaded.
            guard wasSentByUser(m) else { continue }
            let id = headerValue("message-id", of: m).trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    // #2712: WHEN Dan last wrote on this thread himself, which is what dates an inquiry he answered in
    // Gmail rather than from inside Overture.
    //
    // Read from the message's own `internalDate`, never from the clock. Stamping the moment Overture
    // NOTICED would restart the follow-up nudge days after the answer actually went, which is a record
    // about the past taking a value from the present (L37).
    //
    // Nil when the thread carries nothing of his, which is a person who wrote twice before he ever
    // answered, and a state the caller must be able to tell apart from an answered one.
    static func latestSentMessageSentAt(threadJSON data: Data, selfEmail: String) -> Date? {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        guard !me.isEmpty else { return nil }
        for m in realMessagesNewestFirst(messages) {
            guard email(from: headerValue("from", of: m)) == me else { continue }
            // #2918: a draft dates nothing. An inquiry stamped from one would read as answered on a day
            // nothing went, and the follow-up nudge, the closing suggestion and the day it groups under
            // all hang off that stamp.
            guard wasSentByUser(m) else { continue }
            let millis = internalDateMillis(m)
            guard millis > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        }
        return nil
    }

    // #2865: the newest message on this thread IF Dan sent it, with the two facts an UNATTENDED check
    // needs about it and `newestMessageIsSelf` cannot give: when it went, and whether his mailbox sent it
    // by itself.
    //
    // The second is the one that matters. `newestMessageIsSelf` is enough for the attach, where a person
    // is standing there looking at the thread they just linked, and is not enough for a pass running
    // every few minutes: an out of office autoresponder is a message from his own address, arriving on
    // exactly the threads this runs over, and reading it as an answer would take a row that genuinely IS
    // waiting on him off every surface that could say so (L42).
    //
    // `isAutomated` cannot help here: it matches the LOCAL PART of the sender's address, and an
    // autoresponder from Dan's own mailbox carries Dan's own address. The evidence is in the headers the
    // standards define for exactly this (RFC 3834's `Auto-Submitted`, and the `X-Autoreply` /
    // `X-Autorespond` / `Precedence: auto_reply` conventions that predate it).
    struct SentMessage: Equatable, Sendable {
        var sentAt: Date
        var isAutomated: Bool
    }

    static func newestMessageFromSelf(threadJSON data: Data, selfEmail: String) -> SentMessage? {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]],
              let newest = realMessagesNewestFirst(messages).first else { return nil }
        let me = email(from: selfEmail)
        guard !me.isEmpty, email(from: headerValue("from", of: newest)) == me else { return nil }
        // #2918: and Gmail has to say his mailbox SENT it. This is the reader the issue was filed against.
        guard wasSentByUser(newest) else { return nil }
        let millis = internalDateMillis(newest)
        guard millis > 0 else { return nil }
        return SentMessage(sentAt: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
                           isAutomated: isAutomatedSend(newest))
    }

    private static func isAutomatedSend(_ message: [String: Any]) -> Bool {
        let autoSubmitted = headerValue("auto-submitted", of: message)
            .trimmingCharacters(in: .whitespaces).lowercased()
        // The standard's own value for a message a person really sent is "no", so anything else present
        // (auto-replied, auto-generated, auto-notified) is an automated send.
        if !autoSubmitted.isEmpty, autoSubmitted != "no" { return true }
        if !headerValue("x-autoreply", of: message).isEmpty { return true }
        if !headerValue("x-autorespond", of: message).isEmpty { return true }
        if headerValue("precedence", of: message).trimmingCharacters(in: .whitespaces).lowercased()
            == "auto_reply" { return true }
        return false
    }

    // #2715: is the NEWEST message on this thread one Dan sent?
    //
    // Deliberately not the mirror of `latestReplyMessage`, which SKIPS his own messages and so can never
    // answer this. The attach needs it because the premise of the manual route is that Dan found the
    // reply in Gmail, where the ordinary thing to do is answer it. Detection still resolves to their
    // message and sets `replied`, and `hasUnhandledReply` would then stay true for ever, because only
    // Overture's own send paths set `replyHandledAt`: the row would assert somebody is waiting on him,
    // permanently, on a conversation he closed days ago (#2170's defect by a new route).
    //
    // False, never nil, when the thread cannot be read or carries no message at all: the safe reading is
    // that he has NOT answered, which leaves the row asking rather than silently marking it dealt with.
    static func newestMessageIsSelf(threadJSON data: Data, selfEmail: String) -> Bool {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]],
              let newest = realMessagesNewestFirst(messages).first else { return false }
        let me = email(from: selfEmail)
        guard !me.isEmpty else { return false }
        // #2918: the attach stamps `replyHandledAt` off this answer, so a draft here silences the reply
        // exactly as it does on the unattended pass. The same predicate, in both places (L30).
        return email(from: headerValue("from", of: newest)) == me && wasSentByUser(newest)
    }

    private static func headerValue(_ name: String, of message: [String: Any]) -> String {
        guard let payload = message["payload"] as? [String: Any],
              let headers = payload["headers"] as? [[String: Any]] else { return "" }
        return headers.first { ($0["name"] as? String)?.lowercased() == name }?["value"] as? String ?? ""
    }

    // #2653: the Message-ID of the newest real reply, which is the message Dan's answer is a direct
    // response to. The mirror of `latestSentMessageID` above, which reads the newest message HE sent.
    //
    // Through the same `latestReplyMessage` every other inbound reader here uses, so "which message wrote"
    // cannot be answered two ways. Nil when the thread carries no real reply, and nil rather than an empty
    // string when that message has no Message-ID header, so a caller can tell "not known" from a value
    // instead of emitting an empty header.
    static func latestReplyMessageID(threadJSON data: Data, selfEmail: String) -> String? {
        guard let m = latestReplyMessage(threadJSON: data, selfEmail: selfEmail) else { return nil }
        let id = headerValue("message-id", of: m).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    // #2032: the ADDRESS the newest real reply came from, so a thread carrying more than one contact can
    // say which of them wrote. Nil when there is no real reply, exactly as `latestReplyId` is.
    static func latestReplySender(threadJSON data: Data, selfEmail: String) -> String? {
        guard let m = latestReplyMessage(threadJSON: data, selfEmail: selfEmail) else { return nil }
        let e = email(from: headerValue("from", of: m))
        return e.isEmpty ? nil : e
    }

    // #2113: the RAW From value of the newest real reply, display name and all. `latestReplySender`
    // lowercases to a bare mailbox for comparison, which is the right shape to match on and the wrong
    // shape to show a person.
    static func latestReplySenderHeader(threadJSON data: Data, selfEmail: String) -> String? {
        guard let m = latestReplyMessage(threadJSON: data, selfEmail: selfEmail) else { return nil }
        let raw = headerValue("from", of: m).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    // #2113: the display name in a From header, or nil when it carries a bare address. Nil rather than a
    // guess: inventing "nbecker" as somebody's name reads worse than showing the address they wrote from.
    static func displayName(from header: String) -> String? {
        let s = header.trimmingCharacters(in: .whitespaces)
        // No angle brackets means the header is the address itself, which names nobody.
        guard let lo = s.lastIndex(of: "<") else { return nil }
        var name = String(s[s.startIndex..<lo]).trimmingCharacters(in: .whitespaces)
        // A display name is quoted exactly when it contains something that would otherwise split it, a
        // comma most often ("Becker, Nicole"), so the quotes come off and the comma stays.
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }

    // #2113: when the newest real reply was actually SENT, from Gmail's internalDate (epoch millis).
    // Nil when the message carries no internalDate, so a caller can tell "not known" from an instant and
    // fall back rather than treating the epoch as a real send time.
    static func latestReplySentAt(threadJSON data: Data, selfEmail: String) -> Date? {
        guard let m = latestReplyMessage(threadJSON: data, selfEmail: selfEmail) else { return nil }
        let millis = internalDateMillis(m)
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    // The Gmail message id of the newest message from someone other than Dan (skipping automated
    // senders), or nil if there's no real reply. Lets a single auto-detected reply be dismissed (#219)
    // while a genuinely newer reply (a different id) still gets flagged.
    static func latestReplyId(threadJSON data: Data, selfEmail: String) -> String? {
        latestReplyMessage(threadJSON: data, selfEmail: selfEmail)?["id"] as? String
    }

    // #2063: who the latest inbound reply was addressed to, so Dan's answer can go to exactly those people
    // rather than to everyone the ORIGINAL email went to. The send group records what Overture did; only
    // the reply itself records what the other side chose, and they differ the moment somebody replies
    // privately or drops a name.
    //
    // Its SENDER plus everyone else it names, minus Dan. The sender is the point: on a reply-all they sit
    // in From and the rest in To/Cc, so taking only To/Cc would answer everybody except the person who
    // actually wrote. Deduped case-insensitively, in the order met, so nobody gets two copies.
    //
    // nil, never an empty array, when there is no real reply to mirror. The caller has to tell "never
    // captured" from a real audience, because that is what decides whether the send falls back.
    static func latestReplyAudience(threadJSON data: Data, selfEmail: String) -> [String]? {
        let me = email(from: selfEmail)
        guard let m = latestReplyMessage(threadJSON: data, selfEmail: selfEmail) else { return nil }
        let sender = email(from: headerValue("from", of: m))

        var audience: [String] = []
        for address in [sender] + addresses(inHeader: headerValue("to", of: m))
                                + addresses(inHeader: headerValue("cc", of: m)) {
            guard !address.isEmpty, address != me, !audience.contains(address) else { continue }
            audience.append(address)
        }
        return audience
    }

    // Every bare address in a To/Cc header value, lowercased. A display name may itself contain a comma
    // when quoted ("Wright, Dan" <dan@x>), so a quoted region is held together rather than split inside.
    static func addresses(inHeader raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        for ch in raw {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<": inAngles = true; current.append(ch)
            case ">": inAngles = false; current.append(ch)
            case "," where !inQuotes && !inAngles:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { email(from: $0) }.filter { !$0.isEmpty }
    }

    // The latest inbound reply's text from a threads.get (format=full) response: the NEWEST message
    // from someone other than Dan (skipping automated senders). Prefers text/plain, falls back to
    // stripped text/html; base64url-decoded and capped. Residual quoted history is left for the
    // classifier (#112) rather than perfectly stripped here. nil if there's no real reply with text.
    static func latestReplyBody(threadJSON data: Data, selfEmail: String, maxLength: Int = 6_000) -> String? {
        guard let obj = ResponseBody.json(data, from: Self.endpoint).value,
              let messages = obj["messages"] as? [[String: Any]] else { return nil }
        let me = email(from: selfEmail)
        for m in newestFirst(messages) {
            guard let payload = m["payload"] as? [String: Any],
                  let headers = payload["headers"] as? [[String: Any]] else { continue }
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? ""
            let e = email(from: from)
            if e.isEmpty || e == me || isAutomated(e) { continue }
            guard let text = bodyText(from: payload) else { return nil }
            return String(text.prefix(maxLength))
        }
        return nil
    }

    // Newest-first by Gmail's internalDate (epoch ms), since threads.get's array order isn't
    // guaranteed to be chronological. Ties, including messages with no internalDate at all, keep
    // their original order reversed, the same newest-last shape a real thread's array normally has.
    // Internal (not private): BounceDetection (#398) reuses this same chronological ordering so a
    // genuinely newer hard bounce is found instead of whichever bounce comes first in the array.
    static func newestFirst(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.enumerated()
            .sorted { a, b in
                let (dateA, dateB) = (internalDateMillis(a.element), internalDateMillis(b.element))
                return dateA != dateB ? dateA > dateB : a.offset > b.offset
            }
            .map(\.element)
    }

    private static func internalDateMillis(_ message: [String: Any]) -> Int64 {
        if let raw = message["internalDate"] as? String, let value = Int64(raw) { return value }
        if let raw = message["internalDate"] as? NSNumber { return raw.int64Value }
        return 0
    }

    // Best text out of a message payload: prefer text/plain, fall back to stripped text/html.
    private static func bodyText(from payload: [String: Any]) -> String? {
        if let plain = firstPart(payload, mime: "text/plain") { return plain }
        if let html = firstPart(payload, mime: "text/html") { return stripHTML(html) }
        return nil
    }

    // The decoded body of the first part (recursing into multipart) matching the mime type.
    private static func firstPart(_ node: [String: Any], mime: String) -> String? {
        if (node["mimeType"] as? String)?.lowercased() == mime,
           let body = node["body"] as? [String: Any], let b64 = body["data"] as? String,
           let decoded = decodeBase64URL(b64) {
            return decoded
        }
        for p in (node["parts"] as? [[String: Any]]) ?? [] {
            if let found = firstPart(p, mime: mime) { return found }
        }
        return nil
    }

    static func decodeBase64URL(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
