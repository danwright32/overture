import Foundation

// #2928: the ONE place a Gmail thread or message fixture is built, and the shape it builds is the shape
// the API really returns.
//
// Why it exists at all. Before this, thirty-two test files each wrote their own thread JSON by hand, and
// every one of them omitted `labelIds`, a field Gmail returns on EVERY message for both formats this app
// asks for. So no test in the repository had ever driven a thread reader against a real response, and the
// one thing `labelIds` answers, "did Dan SEND this or is he still composing it", could not be asked. That
// is the blind spot #2918 came through: an abandoned draft carrying his own address in `From` and an
// `internalDate` newer than the reply it answered was indistinguishable from a sent answer, and it
// silenced a real reply for good.
//
// Eight hand-rolled builders drifting apart is how that happened, so there is one builder now and a guard
// (`GmailFixtureShapeTests`) that fails when a test file writes a `"payload"` of its own.
//
// The DEFAULT is the real shape, deliberately, so a fixture written next year carries it without anybody
// remembering to (L27, a rule that lives only in a prompt is a hope). Every message gets an `id`, a
// `threadId`, an `internalDate` and a `labelIds`, because Gmail sends all four on every message. Leaving
// one out is possible and takes saying so at the call site, which is exactly the visibility that was
// missing: `.withoutLabelIds()` is the only way to get a message with no label information, and it is
// what the fail-closed tests use.
//
// It also answers a URLRequest the way Gmail does (`respond(to:)`), honouring `format` and
// `metadataHeaders`, which is the half that catches the mirror defect: a reader consuming a header the
// fetch never asked for. A stub that returns every header regardless of the request proves the reader
// works against a response the app can never receive. See `GmailThreadHeaders`.
//
// Nobody in here is real. Every address and name a test passes in is invented; this repository is public.
struct GmailFixture {

    // Whose mailbox the fixture is standing in, which is what decides a message's default labels: his own
    // message carries `SENT`, anybody else's carries `INBOX`.
    var selfEmail: String
    var threadId: String = "t1"

    init(selfEmail: String, threadId: String = "t1") {
        self.selfEmail = selfEmail
        self.threadId = threadId
    }

    // MARK: - One message

    struct Message {
        var from: String
        var to: String?
        var cc: String?
        var subject: String?
        var messageID: String?
        // Gmail's own message id. Minted from the message's position when it is not given, because Gmail
        // always sends one.
        var id: String?
        // Epoch MILLISECONDS, as Gmail sends it (a string). Minted from the position when not given, so a
        // fixture's array order is its chronological order, which is how a real thread arrives.
        var internalDateMillis: Int64?
        // The labels Gmail reports. `nil` here means "work it out from `from`", which is the default and
        // the real shape. Absence of the FIELD is a separate thing: see `withoutLabelIds()`.
        var labelIds: [String]?
        var labelIdsOmitted: Bool = false
        var text: String?
        var html: String?
        // Anything else the message carries: `Auto-Submitted`, `X-Autoreply`, `Precedence`,
        // `List-Unsubscribe`.
        var extraHeaders: [(name: String, value: String)] = []
        // A message with no `From` header at all, which Gmail does produce for some system messages.
        var omitFrom: Bool = false
        // A body Overture cannot read: an attachment part, which carries an `attachmentId` and a size
        // rather than any `data` to decode. #2149's shape, and it takes saying so.
        var attachmentOnly: Bool = false

        init(from: String, to: String? = nil, cc: String? = nil, subject: String? = nil,
             messageID: String? = nil, id: String? = nil, internalDateMillis: Int64? = nil,
             labelIds: [String]? = nil, text: String? = nil, html: String? = nil,
             extraHeaders: [(name: String, value: String)] = [], omitFrom: Bool = false,
             attachmentOnly: Bool = false) {
            self.from = from
            self.to = to
            self.cc = cc
            self.subject = subject
            self.messageID = messageID
            self.id = id
            self.internalDateMillis = internalDateMillis
            self.labelIds = labelIds
            self.text = text
            self.html = html
            self.extraHeaders = extraHeaders
            self.omitFrom = omitFrom
            self.attachmentOnly = attachmentOnly
        }

        // An unsent draft: what Gmail keeps on the thread while Dan is still composing, and what #2918
        // exists to refuse. Spelled out rather than reached by passing `["DRAFT"]` by hand, so a test
        // about drafts says so.
        func asDraft() -> Message {
            var copy = self
            copy.labelIds = ["DRAFT"]
            return copy
        }

        // NO `labelIds` field at all. Gmail never sends this, which is the point: it is the shape the
        // fail-closed rule in `ReplyDetection.wasSentByUser` has to refuse, and the only way to get it is
        // to ask for it here.
        func withoutLabelIds() -> Message {
            var copy = self
            copy.labelIdsOmitted = true
            return copy
        }

        func withLabelIds(_ labels: [String]) -> Message {
            var copy = self
            copy.labelIds = labels
            return copy
        }

        // A message with no `internalDate`, for the ordering tests whose subject is a tie.
        func withoutInternalDate() -> Message {
            var copy = self
            copy.internalDateMillis = -1
            return copy
        }
    }

    // MARK: - Building the JSON

    // A whole `threads.get` response.
    func threadObject(_ messages: [Message]) -> [String: Any] {
        [
            "id": threadId,
            "historyId": "4412207",
            "messages": messages.enumerated().map { object($1, position: $0) },
        ]
    }

    func thread(_ messages: [Message]) -> Data {
        try! JSONSerialization.data(withJSONObject: threadObject(messages))
    }

    // A single `messages.get` response, which is the same Message resource without the thread around it.
    func message(_ m: Message) -> Data {
        try! JSONSerialization.data(withJSONObject: object(m, position: 0))
    }

    private func object(_ m: Message, position: Int) -> [String: Any] {
        var obj: [String: Any] = [
            "id": m.id ?? "m\(position + 1)",
            "threadId": threadId,
            "snippet": (m.text ?? m.html ?? "").prefix(120).description,
            "sizeEstimate": 8421,
        ]
        if m.internalDateMillis != -1 {
            obj["internalDate"] = "\(m.internalDateMillis ?? Int64(position + 1) * 1000)"
        }
        if !m.labelIdsOmitted { obj["labelIds"] = m.labelIds ?? defaultLabelIds(for: m) }
        obj["payload"] = payload(m)
        return obj
    }

    // The rule, in one place: a message from the mailbox this fixture stands in was SENT by it, and
    // anything else arrived. `UNREAD` rides along on inbound mail because Gmail puts it there, and no
    // reader in this app looks at it: it is here so the fixture is not a tidier response than the real one
    // (L48).
    private func defaultLabelIds(for m: Message) -> [String] {
        Self.bareAddress(m.from) == Self.bareAddress(selfEmail)
            ? ["SENT"]
            : ["UNREAD", "INBOX", "CATEGORY_PERSONAL"]
    }

    // Deliberately its own small normaliser rather than `ReplyDetection.email(from:)`. `TestSupport` is
    // compiled into the HOSTED target too, which links the app rather than compiling it, so a fixture that
    // reached into app code would not build there. It is also the wrong direction: a fixture judged by the
    // code under test would agree with that code by construction (L70).
    static func bareAddress(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let lo = s.firstIndex(of: "<"), let hi = s.firstIndex(of: ">"), lo < hi {
            return String(s[s.index(after: lo)..<hi]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return s.lowercased()
    }

    private func payload(_ m: Message) -> [String: Any] {
        var headers: [[String: String]] = []
        if !m.omitFrom { headers.append(["name": "From", "value": m.from]) }
        if let to = m.to { headers.append(["name": "To", "value": to]) }
        if let cc = m.cc { headers.append(["name": "Cc", "value": cc]) }
        if let subject = m.subject { headers.append(["name": "Subject", "value": subject]) }
        if let messageID = m.messageID { headers.append(["name": "Message-ID", "value": messageID]) }
        for h in m.extraHeaders { headers.append(["name": h.name, "value": h.value]) }

        var payload: [String: Any] = ["headers": headers]
        if m.attachmentOnly {
            payload["mimeType"] = "image/png"
            payload["body"] = ["attachmentId": "a1", "size": 9001] as [String: Any]
            return payload
        }
        switch (m.text, m.html) {
        case let (text?, html?):
            payload["mimeType"] = "multipart/alternative"
            payload["parts"] = [
                ["mimeType": "text/plain", "body": ["data": Self.base64url(text)]] as [String: Any],
                ["mimeType": "text/html", "body": ["data": Self.base64url(html)]] as [String: Any],
            ]
        case let (text?, nil):
            payload["mimeType"] = "text/plain"
            payload["body"] = ["data": Self.base64url(text)]
        case let (nil, html?):
            payload["mimeType"] = "text/html"
            payload["body"] = ["data": Self.base64url(html)]
        case (nil, nil):
            break
        }
        return payload
    }

    static func base64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Answering a request the way Gmail does

    // #2928: a fake Gmail that HONOURS the request, which is the half a plain stub cannot do.
    //
    // A stub returning the same blob whatever was asked proves a reader works against a response the app
    // can never receive. Gmail's `format=metadata` returns ONLY the headers named in `metadataHeaders`, so
    // a reader consuming `Auto-Submitted` on a fetch that asked for `From` and `Subject` reads an empty
    // string in production and its own fixture's header in the suite. Two live readers were doing exactly
    // that when this was written; see `GmailThreadHeaders`.
    //
    // `format=full` returns everything, so nothing is filtered there.
    func respond(to request: URLRequest, thread messages: [Message]) -> (Data, URLResponse) {
        let url = request.url!
        let query = url.query ?? ""
        let body = query.contains("format=full")
            ? thread(messages)
            : metadataThread(messages, honouringHeadersIn: query)
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // The thread as `format=metadata` returns it: every field except the headers that were not asked for.
    func metadataThread(_ messages: [Message], honouringHeadersIn query: String) -> Data {
        let wanted = Set(Self.requestedMetadataHeaders(in: query).map { $0.lowercased() })
        var obj = threadObject(messages)
        let filtered = (obj["messages"] as! [[String: Any]]).map { m -> [String: Any] in
            var m = m
            var payload = m["payload"] as! [String: Any]
            let headers = (payload["headers"] as! [[String: String]])
                .filter { wanted.contains(($0["name"] ?? "").lowercased()) }
            payload["headers"] = headers
            // A metadata get returns no body parts at all, which is the other half of the shape.
            payload["parts"] = nil
            payload["body"] = nil
            m["payload"] = payload
            return m
        }
        obj["messages"] = filtered
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    static func requestedMetadataHeaders(in query: String) -> [String] {
        query.split(separator: "&").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0] == "metadataHeaders" else { return nil }
            return pair[1].removingPercentEncoding ?? pair[1]
        }
    }
}
