import Testing
import Foundation
import SwiftData

// #2928. Gmail's `format=metadata` returns ONLY the headers named in `metadataHeaders`. Everything else
// on the message is dropped, and a header that was never asked for reads back as an empty string, which
// is exactly what a header that is genuinely absent looks like.
//
// So the request and the readers are one contract. It was maintained by hand at three call sites with
// three different lists, and two live readers were on the wrong side of it, both with passing tests,
// because every Gmail fixture in the suite handed back whatever headers it felt like regardless of what
// the request had asked for. A stub like that can only ever prove a reader against a response the app
// cannot receive (L52, L143).
//
// The two, measured on this branch by making the fixtures honour the request:
//
//   - #2653's `latestReplyMessageID`. `ReplyService.recordWriter` reads it off the metadata thread, and
//     `GmailReplyChecker` asked for `From` and `Subject`. So `inboundReplyMessageId` was nil on every row
//     the ordinary reply watch has ever recorded, and `ReplyThreading.inReplyTo` fell back to Overture's
//     own last message: #2653's defect, still shipping, underneath #2653's fix.
//
//   - #2865's `isAutomatedSend`, which reads `Auto-Submitted`, `X-Autoreply`, `X-Autorespond` and
//     `Precedence`. None was ever requested, so it could only answer false, and an out of office
//     autoreply from Dan's own mailbox would have cleared a row genuinely waiting on him (L42). Its own
//     five tests are in `AnsweredOutsideOvertureTests`, and they now run against a fixture that honours
//     the request, which is what makes them mean anything.
//
// The people, addresses and words below are invented. Nothing here is anybody's real conversation.
private let threadHeaderContractGmail =
    GmailFixture(selfEmail: "dan@danwrightphotography.com", threadId: "t")

@MainActor
@Suite("A thread read asks for the headers its readers read (#2928)")
struct GmailThreadHeaderContractTests {

    private static let me = "dan@danwrightphotography.com"
    private static let them = "marguerite.eddowes@example.com"

    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let now = Date(timeIntervalSince1970: 30_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Larkspur Consort", discipline: "music",
                         venue: "Halden Street Hall", performanceDate: "2026-12-02",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect) -> Recipient {
        let r = Recipient(id: Self.them, email: Self.them, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.gmailThreadId = "t"
        r.sendGroupId = "t"
        p.addRecipient(r)
        return r
    }

    // File scope, for the same reason as `AnsweredOutsideOvertureTests`: the fetch below is a
    // nonisolated closure and cannot read a main-actor static.
    private static var gmail: GmailFixture { threadHeaderContractGmail }

    // His pitch, then their reply, which carries the `Message-ID` an answer of his has to thread onto.
    private var theyAnswered: [GmailFixture.Message] {
        [
            GmailFixture.Message(from: Self.me, to: Self.them, messageID: "<ours@mail.gmail.com>",
                                 id: "m-0", internalDateMillis: 1_000_000, text: "My pitch."),
            GmailFixture.Message(from: "Marguerite Eddowes <\(Self.them)>", to: Self.me,
                                 messageID: "<theirs@mail.gmail.com>", id: "r-1",
                                 internalDateMillis: Int64(theyWrote.timeIntervalSince1970) * 1000,
                                 text: "What would this cost?"),
        ]
    }

    // A fake Gmail that answers the way Gmail does: `format=metadata` returns only the headers the
    // request named.
    private func honouringFetch(_ messages: [GmailFixture.Message])
    -> (URLRequest) async throws -> (Data, URLResponse) {
        { req in threadHeaderContractGmail.respond(to: req, thread: messages) }
    }

    // MARK: - The reader the request has to serve

    // #2653 in the live pipeline rather than through `recordWriterForTesting` with a hand-made thread.
    // Every existing test for this reads a fixture carrying a `Message-ID` the real metadata response did
    // not return, which is why the gap survived: the reader was right and could never be fed.
    @Test func theReplyWatchStoresTheMessageIdItThreadsTheAnswerOnto() async throws {
        let ctx = ModelContext(try container())
        let r = contact(show(ctx))

        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: now, fetch: honouringFetch(theyAnswered))

        #expect(r.replied, "the premise: the reply is detected at all")
        #expect(r.inboundReplyMessageId == "<theirs@mail.gmail.com>",
                "the answer threads onto THEIR message, and this is where that id comes from")
        #expect(ReplyThreading.inReplyTo(for: r) == "<theirs@mail.gmail.com>",
                "and not back onto Overture's own last message, which is #2653's defect")
    }

    // MARK: - The list, derived from the readers rather than kept beside them

    // Every header any reader of a thread message reads has to be one the metadata read asks for. Derived
    // from the source of the two readers, so a reader that starts reading a new header fails this rather
    // than silently reading an empty string in production (L41, L96).
    @Test func everyHeaderAThreadReaderReadsIsRequested() {
        let read = Self.headerNamesRead(in: [
            SourceGuardHelper.source("Overture/Domain/ReplyDetection.swift"),
            SourceGuardHelper.source("Overture/Domain/BounceDetection.swift"),
        ])
        #expect(read.contains("from"), "the derivation itself works, or this guard checks nothing")
        #expect(read.contains("auto-submitted"), "and it reaches the automated-send headers")

        let requested = Set(GmailThreadHeaders.metadata.map { $0.lowercased() })
        let missing = read.subtracting(requested).sorted()
        let why = "a thread reader reads \(missing.joined(separator: ", ")), which no metadata read asks "
            + "Gmail for, so it can only ever see an empty value"
        #expect(missing.isEmpty, Comment(rawValue: why))
    }

    // The header names a reader pulls off a message, in the two spellings this codebase uses: through
    // `headerValue("x", of:)` and through the inline `($0["name"] as? String)?.lowercased() == "x"` match.
    static func headerNamesRead(in sources: [String]) -> Set<String> {
        var names: Set<String> = []
        for pattern in [#"headerValue\("([^"]+)""#,
                        #"as\? String\)\?\.lowercased\(\) == "([^"]+)""#] {
            let re = try! NSRegularExpression(pattern: pattern)
            for source in sources {
                let range = NSRange(source.startIndex..., in: source)
                for m in re.matches(in: source, range: range) {
                    guard let r = Range(m.range(at: 1), in: source) else { continue }
                    names.insert(String(source[r]).lowercased())
                }
            }
        }
        return names
    }

    // MARK: - One list, not three

    // Three separate fetchers read a thread, and each used to spell its own `metadataHeaders` list. Two
    // of the three were short. The rule is that none of them writes a list at all.
    @Test func everyThreadMetadataReadUsesTheSharedList() {
        for file in ["Overture/Integration/GmailReplyChecker.swift",
                     "Overture/Integration/ConfirmProposedConversation.swift",
                     "Overture/Integration/GmailThreadingRepair.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty, "\(file) could not be read, so this guard would pass while blind")
            #expect(source.contains("GmailThreadHeaders.metadataQuery"),
                    "\(file) reads a Gmail thread and must ask for the shared header list")
            #expect(!source.contains("metadataHeaders="),
                    "\(file) spells its own metadataHeaders list, which is how two of them went short")
        }
    }
}
