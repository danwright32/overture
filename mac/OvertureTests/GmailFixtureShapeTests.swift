import Testing
import Foundation

// #2928. Every Gmail thread fixture in this repository used to be written by hand, thirty-two files of
// them, and every single one omitted `labelIds`. Gmail returns that field on EVERY message, for both
// formats this app asks for, so no test here had ever driven a thread reader against a response the API
// can actually produce, and the question `labelIds` answers, "did Dan SEND this or is he still composing
// it", could not be asked at all. #2918 is what that cost: an abandoned draft silenced a real reply.
//
// #2918 added the field to six fixtures. That is a fix to six instances of a class (L30), and the class
// is "a fixture whose shape is nobody's job". So the shape has ONE owner now, `GmailFixture`, its default
// is the real shape, and this suite is what stops a thirty-third hand-rolled thread appearing: a rule that
// depends on being remembered is not a rule (L27).
@Suite("Gmail fixtures are built in one place, in the real shape (#2928)")
struct GmailFixtureShapeTests {

    private static let me = "dan@danwrightphotography.com"
    private static let them = "wren.holloway@example.com"

    // MARK: - The default IS the real shape

    // The point of the whole change: a fixture written with no thought about labels still carries them,
    // and carries the RIGHT ones, so a reader that asks what Dan sent gets a real answer rather than the
    // fail-closed refusal an absent field earns.
    @Test func aMessageWrittenWithNoThoughtAboutLabelsStillCarriesThem() throws {
        let data = GmailFixture(selfEmail: Self.me).thread([
            .init(from: Self.me), .init(from: Self.them),
        ])
        let messages = try Self.messages(in: data)

        #expect(ReplyDetection.labelIds(of: messages[0]) == ["SENT"], "his own message reads as sent")
        #expect(ReplyDetection.wasSentByUser(messages[0]))
        #expect(ReplyDetection.labelIds(of: messages[1])?.contains("INBOX") == true,
                "theirs reads as arrived")
        #expect(!ReplyDetection.wasSentByUser(messages[1]))
        #expect(!ReplyDetection.isDraft(messages[0]) && !ReplyDetection.isDraft(messages[1]))
    }

    // The other three fields Gmail sends on every message and the old hand-rolled fixtures dropped as
    // freely as they dropped `labelIds`. An absent `internalDate` is not a shape the API produces, and
    // several readers treat it as a refusal, so a fixture without one exercises a state nobody can reach.
    @Test func everyMessageCarriesTheIdentifiersGmailAlwaysSends() throws {
        let messages = try Self.messages(in: GmailFixture(selfEmail: Self.me, threadId: "t7")
            .thread([.init(from: Self.them), .init(from: Self.them)]))

        for m in messages {
            #expect((m["id"] as? String)?.isEmpty == false)
            #expect(m["threadId"] as? String == "t7")
            #expect(Int64((m["internalDate"] as? String) ?? "") ?? 0 > 0)
        }
        #expect(messages[0]["id"] as? String != messages[1]["id"] as? String, "and they are distinct")
    }

    // Array order is chronological order, which is how a real thread arrives, so a fixture that names no
    // dates still means what it reads as.
    @Test func arrayOrderIsChronologicalUnlessTheFixtureSaysOtherwise() throws {
        let messages = try Self.messages(in: GmailFixture(selfEmail: Self.me)
            .thread([.init(from: Self.me, id: "first"), .init(from: Self.them, id: "second")]))
        let dates = messages.compactMap { Int64(($0["internalDate"] as? String) ?? "") }

        #expect(dates.count == 2)
        #expect(dates[0] < dates[1])
    }

    // MARK: - The two states a call site has to ASK for

    @Test func aDraftIsLabelledAsOneAndIsNotASend() throws {
        let m = try Self.messages(in: GmailFixture(selfEmail: Self.me)
            .thread([GmailFixture.Message(from: Self.me).asDraft()]))[0]

        #expect(ReplyDetection.isDraft(m))
        #expect(!ReplyDetection.wasSentByUser(m), "#2918: a draft is not evidence that he answered")
    }

    // The shape the fail-closed rule exists for, and the only way to get it is to say so.
    @Test func aMessageWithNoLabelInformationTakesSayingSo() throws {
        let m = try Self.messages(in: GmailFixture(selfEmail: Self.me)
            .thread([GmailFixture.Message(from: Self.me).withoutLabelIds()]))[0]

        #expect(ReplyDetection.labelIds(of: m) == nil)
        #expect(!ReplyDetection.wasSentByUser(m), "no claim either way is refused, not accepted")
    }

    // MARK: - It answers the way Gmail answers

    // `format=metadata` returns ONLY the headers the request named, and no body at all. A stub that
    // ignores the request proves a reader against a response the app can never receive (L143), which is
    // exactly how two live readers came to be reading empty strings in production. See
    // `GmailThreadHeaderContractTests`.
    @Test func aMetadataReadReturnsOnlyTheHeadersItAskedFor() throws {
        let gmail = GmailFixture(selfEmail: Self.me)
        let messages = [GmailFixture.Message(from: Self.them, subject: "Re: the gala",
                                             messageID: "<theirs@mail.gmail.com>", text: "Yes please.")]
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1"
                      + "?format=metadata&metadataHeaders=From")!

        let (data, _) = gmail.respond(to: URLRequest(url: url), thread: messages)

        #expect(ReplyDetection.latestReplySender(threadJSON: data, selfEmail: Self.me) != nil,
                "From was asked for, so it comes back")
        #expect(ReplyDetection.latestReplyMessageID(threadJSON: data, selfEmail: Self.me) == nil,
                "Message-ID was not, so it does not, exactly as Gmail behaves")
        #expect(ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: Self.me) == nil,
                "and a metadata read carries no body")
    }

    @Test func aFullReadReturnsEverything() throws {
        let gmail = GmailFixture(selfEmail: Self.me)
        let messages = [GmailFixture.Message(from: Self.them, messageID: "<theirs@mail.gmail.com>",
                                             text: "Yes please.")]
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/t1?format=full")!

        let (data, _) = gmail.respond(to: URLRequest(url: url), thread: messages)

        #expect(ReplyDetection.latestReplyMessageID(threadJSON: data, selfEmail: Self.me)
                == "<theirs@mail.gmail.com>")
        #expect(ReplyDetection.latestReplyBody(threadJSON: data, selfEmail: Self.me) == "Yes please.")
    }

    // MARK: - Nothing builds one of these by hand any more

    // The rule that makes the default above worth having. A test file that writes a Gmail message payload
    // of its own is a fixture outside the one builder, and the only thing that kept thirty-two of them
    // honest was that nobody had looked. Matched on the JSON KEY, meaning the name followed by a colon, so
    // reading the field back off a response by subscript (which `GmailReplySearchTests` does to the
    // checked-in fixture) is untouched: this is about WRITING a message shape, not about inspecting one.
    @Test func noTestFileBuildsAGmailMessagePayloadOfItsOwn() throws {
        // Assembled from parts rather than written out, so THIS file does not carry the thing it bans
        // and answer its own question (L135). The same trick the style gate needs for an em dash.
        let quote = "\u{22}"
        let key = quote + "payload" + quote + ":"
        let spacedKey = quote + "payload" + quote + " :"

        let files = ["OvertureTests", "OvertureHostedTests"].flatMap { directory in
            AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent(directory), floor: 5)
        }
        #expect(files.count > 100, "found almost no test sources, which is a broken path")

        let offenders = files
            .filter { $0.text.replacingOccurrences(of: spacedKey, with: key).contains(key) }
            .map(\.name)
            .sorted()
        let why = "these build a Gmail message shape by hand instead of through GmailFixture, which is "
            + "how thirty-two fixtures came to omit labelIds: \(offenders.joined(separator: ", "))"
        #expect(offenders.isEmpty, Comment(rawValue: why))
    }

    // MARK: -

    private static func messages(in data: Data) throws -> [[String: Any]] {
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(obj["messages"] as? [[String: Any]])
    }
}
