import Testing
import Foundation

// #2888: a response that ARRIVED and could not be understood read as an answer with nothing in it.
//
// #2879 swept the handoff FILES, and its derived guard surfaced this second set of sites and
// deliberately left them, because they are a different class with a different remedy (L129). A file sits
// on disk and can be re-read; a network response is gone. Fourteen `try? JSONSerialization.jsonObject`
// and four `try? JSONDecoder().decode` reads of live responses turned a 200 whose BODY did not decode
// into: no reply (`ReplyDetection`), no bounce (`BounceDetection`, so a pitch that bounced reads as
// delivered), and a calendar with no listings (`AlgoliaCalendar`, `SquarespaceCalendar`).
//
// WHY THE SURFACE IS A RATE AND NOT A LINE PER RESPONSE (L77). One malformed Gmail response is noise:
// it happens, the next poll gets a good one, and a warning for it is a warning Dan learns to ignore
// (L36). Every response failing for an hour is an outage, and it was invisible.
//
// WHY CONSECUTIVE FAILURES RATHER THAN A SESSION RATIO, which is the shape that looks more obvious. A
// ratio needs a minimum volume floor or it fires on the first failure of the session, and a floor
// silences the SATURATION case, which is the one that matters: a proportion cannot tell one bad out of
// two from twelve bad out of twelve (L139). Consecutive failures needs no floor at all, so a busy
// endpoint and a quiet one are judged by the same rule, and one bad response among good ones is counted
// and stays silent because the next success resets the run.
@Suite("A response that could not be understood is counted, not read as an empty answer (#2888)")
struct ResponseDecodeFailureTests {

    private func register() -> ResponseDecodeFailures { ResponseDecodeFailures() }

    // MARK: - The reader

    @Test func agoodBodyDecodesAndSaysNothing() {
        let r = register()
        let body = Data(#"{"messages": []}"#.utf8)
        let read = ResponseBody.json(body, from: "gmail.threads.list", recorder: r)

        #expect(read.value?["messages"] != nil)
        #expect(r.current().isEmpty)
    }

    // The defect itself: the caller still gets nil, so nothing about its behaviour changes, and the
    // failure is no longer invisible.
    @Test func amalformedBodyIsUndecodableAndIsRecorded() {
        let r = register()
        let read = ResponseBody.json(Data("<html>502 Bad Gateway</html>".utf8),
                                     from: "gmail.threads.list", recorder: r)

        #expect(read.value == nil)
        guard case .undecodable(let reason) = read else {
            Issue.record("a body that is not JSON at all decoded")
            return
        }
        #expect(!reason.isEmpty, "the failure was recorded with no reason, which is a line nobody can act on")
        #expect(r.current().count == 1)
        #expect(r.current().first?.endpoint == "gmail.threads.list")
    }

    // JSON that parses but is not the SHAPE the caller needs is the same defect wearing a better
    // disguise: `jsonObject` succeeds and the `as? [String: Any]` fails, which a `try?` cannot see at all.
    @Test func wellFormedJsonOfTheWrongShapeIsUndecodableToo() {
        let r = register()
        let read = ResponseBody.json(Data("[1, 2, 3]".utf8), from: "gmail.threads.list", recorder: r)

        #expect(read.value == nil)
        #expect(r.current().count == 1)
    }

    @Test func adecodableTypeIsReadTheSameWay() {
        struct Payload: Decodable, Equatable { let items: [String] }
        let r = register()

        let good = ResponseBody.decode(Payload.self, from: Data(#"{"items": ["a"]}"#.utf8),
                                       endpoint: "squarespace.calendar", recorder: r)
        #expect(good.value == Payload(items: ["a"]))
        #expect(r.current().isEmpty)

        let bad = ResponseBody.decode(Payload.self, from: Data("not json".utf8),
                                      endpoint: "squarespace.calendar", recorder: r)
        #expect(bad.value == nil)
        #expect(r.current().first?.endpoint == "squarespace.calendar")
    }

    // MARK: - The rate

    // One bad response among good ones is counted and says nothing. This is the half that keeps the
    // surface worth reading (L36).
    @Test func oneFailureAmongSuccessesDoesNotRaiseAnything() {
        let r = register()
        r.record(endpoint: "gmail.threads.list", failed: false)
        r.record(endpoint: "gmail.threads.list", failed: true)
        r.record(endpoint: "gmail.threads.list", failed: false)

        let health = r.current().first!
        #expect(health.failures == 1)
        #expect(health.attempts == 3)
        #expect(health.consecutiveFailures == 0, "a success after a failure did not end the run")
        #expect(!health.isFailing)
    }

    // The outage. Nothing about the endpoint's VOLUME is involved, which is the whole reason this is
    // counted as a run rather than as a proportion.
    @Test func aRunOfFailuresIsFailing() {
        let r = register()
        for _ in 0..<ResponseDecodeFailures.failingRun {
            r.record(endpoint: "gmail.threads.list", failed: true)
        }

        let health = r.current().first!
        #expect(health.consecutiveFailures == ResponseDecodeFailures.failingRun)
        #expect(health.isFailing)
    }

    // Saturation at the smallest possible volume: every response this endpoint has ever given has
    // failed. A session ratio with a volume floor would call this quiet, which is the case a floor is
    // least entitled to silence (L139).
    @Test func anEndpointThatHasOnlyEverFailedIsFailingAtTheSmallestVolume() {
        let r = register()
        for _ in 0..<ResponseDecodeFailures.failingRun {
            r.record(endpoint: "squarespace.calendar", failed: true)
        }

        let health = r.current().first!
        #expect(health.attempts == ResponseDecodeFailures.failingRun,
                "this endpoint has answered only \(health.attempts) times in total")
        #expect(health.isFailing)
    }

    // A recovery ENDS the condition rather than leaving a warning nothing can clear (L160's shape, and
    // the rule HandoffReadFailures already follows: the condition ends when the thing works again, and
    // nothing else is evidence of that).
    @Test func asuccessAfterARunEndsTheCondition() {
        let r = register()
        for _ in 0..<ResponseDecodeFailures.failingRun {
            r.record(endpoint: "gmail.threads.list", failed: true)
        }
        #expect(r.current().first!.isFailing)

        r.record(endpoint: "gmail.threads.list", failed: false)
        #expect(!r.current().first!.isFailing)
        // The history is KEPT. It is what says this endpoint has been unhealthy today, which a cleared
        // record could not, and it is why the count is not simply reset to nothing.
        #expect(r.current().first!.failures == ResponseDecodeFailures.failingRun)
    }

    // Two endpoints failing are two conditions, not one: they are different services with different
    // causes, and one line for both would name neither (L11).
    @Test func endpointsAreCountedApart() {
        let r = register()
        r.record(endpoint: "gmail.threads.list", failed: true)
        r.record(endpoint: "squarespace.calendar", failed: true)

        #expect(r.current().count == 2)
        #expect(r.current().map(\.endpoint) == ["gmail.threads.list", "squarespace.calendar"],
                "the list reshuffles between reads, so the surface showing it flickers")
    }

    // MARK: - The surface (L46: a register with no reader is a defect of its own)

    @Test func anEndpointThatIsMerelyUnluckyPutsNothingOnScreen() {
        let health = ResponseDecodeFailures.Health(endpoint: "gmail.threads.get", attempts: 40,
                                                   failures: 1, consecutiveFailures: 0,
                                                   lastReason: "the body is not valid JSON")
        #expect(AppNotices.responsesNotUnderstood([health]) == nil)
    }

    // The line names WHAT IS LOST, not that a decode failed: an endpoint name means nothing to Dan, and
    // a notice he cannot read is a notice he cannot act on (the rule `couldNotRead` already follows).
    @Test func afailingEndpointGetsALineNamingWhatIsLost() throws {
        let health = ResponseDecodeFailures.Health(endpoint: "gmail.threads.get", attempts: 5,
                                                   failures: 5, consecutiveFailures: 5,
                                                   lastReason: "the body is not valid JSON")
        let notice = try #require(AppNotices.responsesNotUnderstood([health]))

        #expect(notice.tone == .warning)
        #expect(notice.text.contains("Gmail"),
                "the line names an endpoint rather than the thing Dan is waiting on")
        #expect((notice.help ?? "").contains("the body is not valid JSON"),
                "the reason the responses could not be read is nowhere on the notice")
    }

    // An endpoint nothing on this list knows how to describe still gets a line. Falling back to silence
    // would mean a new call site is exempt from the surface until somebody remembers it (L113, L96).
    @Test func anUnknownEndpointStillGetsALine() throws {
        let health = ResponseDecodeFailures.Health(endpoint: "some.new.call", attempts: 3, failures: 3,
                                                   consecutiveFailures: 3, lastReason: "boom")
        let notice = try #require(AppNotices.responsesNotUnderstood([health]))
        #expect(notice.text.contains("some.new.call"))
    }

    @Test func theNoticeListCarriesTheFailingResponsesLine() {
        let health = ResponseDecodeFailures.Health(endpoint: "gmail.threads.get", attempts: 5,
                                                   failures: 5, consecutiveFailures: 5,
                                                   lastReason: "the body is not valid JSON")
        let notices = AppNotices.current(failingResponses: [health], status: StatusLine(text: nil))
        #expect(notices.contains { $0.text.contains("Gmail") },
                "the line is built and never shown, which is the same as not building it (L3)")
    }

    // Built is not wired: RootView has to READ the register and hand it to the notice list, or the whole
    // thing is a counter nobody looks at.
    @Test func rootViewPollsTheRegisterAndPassesItToTheNotices() {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("ResponseDecodeFailures.shared.failing()"),
                "RootView never reads the response failure register (#2888, L46)")
        #expect(SourceGuardHelper.containsCode("failingResponses: failingResponses", in: source),
                "RootView reads the register and does not hand it to the notice list")
    }

    // MARK: - The class, derived rather than remembered (L96)

    // No app source may turn a network response into a value with a `try?`. Derived by scanning the
    // app's own source, so a NEW site cannot arrive unnoticed, which is the only thing that keeps a
    // sweep like this true.
    //
    // The two forms are scoped differently, and both scopes are stated rather than assumed.
    // `JSONSerialization.jsonObject` is used in this app ONLY on network responses, all fourteen of
    // them, so it is flagged anywhere. `JSONDecoder().decode` is also used on FILE data, which is
    // #2879's class and already handled by `HandoffFile`, so it is flagged in `Integration/`, which is
    // where this app's network calls live.
    @Test func noAppSourceSwallowsAResponseDecode() throws {
        let offenders = AppSourceWalk.appFiles()
            .filter { $0.name != "ResponseBody.swift" }
            .flatMap { file -> [String] in
                let isIntegration = file.url.path.contains("/Integration/")
                // Comments stripped, so prose ABOUT the construct cannot satisfy or trip this (L103).
                return SwiftSource.scannableLines(in: file.text).compactMap { line in
                    let code = line.code
                    let swallowsAResponse = code.contains("try? JSONSerialization.jsonObject")
                        || (isIntegration && code.contains("try? JSONDecoder().decode"))
                    guard swallowsAResponse else { return nil }
                    return "\(file.name):\(line.line): \(code.trimmingCharacters(in: .whitespaces))"
                }
            }
        #expect(offenders.isEmpty, """
            \(offenders.count) site(s) turn a network response into a value with a `try?`, so a 200 whose \
            body does not decode reads as an empty answer (#2888):

            \(offenders.joined(separator: "\n"))

            Read it through ResponseBody instead. The caller may still do exactly what it does now with \
            a nil; what it may not do is leave the failure invisible.
            """)
    }
}

// #2888's failure path, at the real call sites rather than only at the shared reader.
//
// Split into two halves on purpose, and what each half proves is different.
//
// THE SAFE ANSWER. Every one of these entry points is handed a 200 whose body does not decode, and each
// must answer the way that leaves Dan's data alone. That is not always nil: `newestMessageIsSelf` has to
// answer FALSE, because true would mean "he has already replied to this" and would silently mark a
// conversation dealt with, and `isEventsCollection` has to answer false because a wrong yes takes a
// source off the paid read that needs it. This half needs no register and no shared state.
//
// THE REPORTING reaches the register through a real call site. Asserted for two of them rather than
// sixteen, because `noAppSourceSwallowsAResponseDecode` already proves every site goes through
// `ResponseBody`, and the suite above proves `ResponseBody` records; what these two add is that the
// composition really happens end to end, which neither of those can show on its own.
@MainActor
@Suite("A malformed body leaves each reader answering safely (#2888)", .serialized)
struct MalformedResponseAtEachSiteTests {

    // A 200 whose body is an error page, which is the shape a proxy or an outage produces.
    private let junk = Data("<html><title>502 Bad Gateway</title></html>".utf8)
    // Well formed JSON of the wrong shape, which a `try?` around the throwing half cannot see at all.
    private let wrongShape = Data("[1, 2, 3]".utf8)
    private let me = "dan@danwrightphotography.com"

    // MARK: - Gmail: replies

    @Test func replyReadersAnswerNothingRatherThanInventingOne() {
        for body in [junk, wrongShape] {
            #expect(ReplyDetection.fromAddresses(threadJSON: body).isEmpty)
            #expect(ReplyDetection.latestSentMessageID(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.latestSentMessageSentAt(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.newestMessageFromSelf(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.latestReplyMessageID(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.latestReplySender(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.latestReplySentAt(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.latestReplyId(threadJSON: body, selfEmail: me) == nil)
            #expect(ReplyDetection.latestReplyAudience(threadJSON: body, selfEmail: me)?.isEmpty ?? true)
        }
    }

    // The one whose safe answer is FALSE rather than nil. True here would mean Dan has already answered,
    // and would leave a row that is waiting on him silently marked as dealt with.
    @Test func anUnreadableThreadIsNotReadAsDanHavingAlreadyAnswered() {
        for body in [junk, wrongShape] {
            #expect(ReplyDetection.newestMessageIsSelf(threadJSON: body, selfEmail: me) == false)
        }
    }

    // MARK: - Gmail: bounces

    // The consequence the issue names: a malformed body read as NO BOUNCE reports a pitch that bounced
    // as delivered. It still answers nil, which is the safe half; what changed is that it is counted.
    @Test func anUnreadableThreadIsNotReadAsNoBounce() {
        for body in [junk, wrongShape] {
            #expect(BounceDetection.hardBounceMessageId(threadJSON: body, selfEmail: me) == nil)
            #expect(BounceDetection.delayMessageId(threadJSON: body, selfEmail: me) == nil)
        }
    }

    // MARK: - Gmail: search and signature

    @Test func anUnreadableSearchPageIsNotAnEmptyMailbox() {
        for body in [junk, wrongShape] {
            #expect(GmailReplySearch.parseList(body) == nil,
                    "an unreadable list response reads as a mailbox holding nothing")
            #expect(GmailReplySearch.parseMetadata(body) == nil)
        }
    }

    @Test func anUnreadableSendAsListYieldsNoSignature() {
        for body in [junk, wrongShape] {
            #expect(GmailSignatureService.primarySignature(fromListJSON: body) == nil)
        }
    }

    // MARK: - The venue calendars

    @Test func anUnreadableCalendarIsNotACalendarWithNoShows() {
        for body in [junk, wrongShape] {
            let parsed = AlgoliaCalendar.parse(body)
            #expect(parsed.events.isEmpty)
            #expect(parsed.nbPages == 0)
        }
        // A wrong YES here takes a source off the paid read that needs it, so false is the safe answer.
        #expect(SquarespaceCalendar.isEventsCollection(junk) == false)
    }

    // MARK: - The reporting really reaches the register

    // Through a REAL call site, not through `ResponseBody` directly. `.serialized` and a reset because
    // these two read the process-wide register, which is what the app itself uses; the assertions are on
    // a DELTA for the one endpoint each touches, so a neighbour recording something else cannot decide
    // the verdict.
    @Test func amalformedGmailThreadIsCountedAgainstItsEndpoint() {
        ResponseDecodeFailures.shared.reset()
        _ = ReplyDetection.fromAddresses(threadJSON: junk)

        let health = ResponseDecodeFailures.shared.current().first { $0.endpoint == "gmail.threads.get" }
        #expect(health?.failures == 1, "the read went through without being counted (#2888)")
        #expect(health?.lastReason?.isEmpty == false)
        ResponseDecodeFailures.shared.reset()
    }

    @Test func amalformedCalendarPageIsCountedAgainstItsEndpoint() {
        ResponseDecodeFailures.shared.reset()
        _ = AlgoliaCalendar.parse(junk)

        let health = ResponseDecodeFailures.shared.current().first { $0.endpoint == "algolia.search" }
        #expect(health?.failures == 1, "the read went through without being counted (#2888)")
        ResponseDecodeFailures.shared.reset()
    }
}
