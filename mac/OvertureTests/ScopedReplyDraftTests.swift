import Testing
import Foundation
import SwiftData

// #2129: "Draft with AI" must draft the ONE reply it was pressed on.
//
// The drafter run collects every reply awaiting a draft and works through them in a single detached,
// paid pass, cancellable only run-wide. That is right for the batch it was built for and wrong for a
// button on one reply: pressing it would spend across every waiting conversation, and Cancel would
// abandon all of them. Dan's rule, 2026-08-05: "buttons need to do what they say."
@MainActor
@Suite("The AI drafter can be scoped to one reply")
struct ScopedReplyDraftTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func repliedShow(_ ctx: ModelContext, key: String, address: String,
                             words: String = "Sounds good, tell me more.") -> Recipient {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.replied = true
        r.lastReplyText = words
        p.addRecipient(r)
        return r
    }

    // The batch the run was built for: unscoped, it takes everything waiting.
    @Test func theUnscopedQueueTakesEveryReplyWaiting() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let queue = ReplyClassifyService.buildQueue(from: ctx, generatedAt: "t")
        #expect(queue.items.count == 2)
    }

    // Scoped, it takes exactly the one asked for and spends on nothing else.
    @Test func aScopedQueueTakesOnlyTheReplyAskedFor() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "B", recipientId: "b@x.org"))
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.naturalKey == "B")
        #expect(queue.items.first?.recipientId == "b@x.org")
    }

    // The property that matters most: a scoped request that matches nothing yields NOTHING. Falling back
    // to the whole batch would spend Dan's money across every waiting conversation from a button he
    // pressed on one, which is the failure this scoping exists to prevent.
    @Test func aScopedRequestThatMatchesNothingDraftsNothing() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "A", recipientId: "nobody@x.org"))
        #expect(queue.items.isEmpty)
    }

    // A scope naming a contact who does not need a draft is also nothing, rather than quietly widening.
    @Test func aScopedRequestOnAContactNeedingNoDraftDraftsNothing() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        let b = repliedShow(ctx, key: "B", address: "b@x.org")
        b.replyDraftBody = "already drafted"      // no longer awaiting one
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "B", recipientId: "b@x.org"))
        #expect(queue.items.isEmpty)
    }

    // The scope matches the show as well as the contact, so two shows sharing a contact address cannot
    // draft each other's conversation.
    @Test func theScopeMatchesTheShowNotJustTheAddress() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "shared@x.org", words: "A's words")
        repliedShow(ctx, key: "B", address: "shared@x.org", words: "B's words")
        let queue = ReplyClassifyService.buildQueue(
            from: ctx, generatedAt: "t",
            only: ReplyClassifyService.Target(naturalKey: "B", recipientId: "shared@x.org"))
        #expect(queue.items.count == 1)
        #expect(queue.items.first?.replyText == "B's words")
    }

    // #2944: the queue/archive card's own "Draft a reply" button. Everything above tests `buildQueue`,
    // which is one layer below the defect: the builder scoped correctly the whole time and the CARD'S
    // call site asked it for the whole batch, so pressing the button on one conversation started the paid
    // run across every waiting one and its Cancel abandoned all of them.
    //
    // Read through the launch seam rather than from the source text, because the Target is a runtime
    // value: a guard on the words at the call site can see `only:` written and never know that nil, the
    // one value that spends on everything, is what arrives (L3).
    @Test func theCardsDraftButtonScopesTheRunToTheConversationItWasPressedOn() throws {
        let ctx = ModelContext(try container())
        repliedShow(ctx, key: "A", address: "a@x.org")
        repliedShow(ctx, key: "B", address: "b@x.org")
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let spy = ReplyDrafterLaunchSpy()

        ProspectMutations.draftReply("B", "b@x.org", prospects: prospects, context: ctx,
                                     feedback: ActionFeedback(), start: spy.record)

        #expect(spy.targets.count == 1,
                "pressing Draft a reply must launch the drafter exactly once.")
        let target = spy.targets.first ?? nil
        #expect(target != nil,
                """
                Draft a reply launched the drafter with NO scope, so it drafts every waiting \
                conversation on Dan's account instead of the one card he pressed, and its Cancel \
                abandons all of them (#2944).
                """)
        #expect(target == ReplyClassifyService.Target(naturalKey: "B", recipientId: "b@x.org"),
                "the scope must name the conversation the button was pressed on, show and contact both.")
    }

    // The stamp the card reads to show "drafting" goes on the SAME conversation the run was scoped to.
    // A scope and a stamp that disagree would leave one card saying it is working while another one's
    // reply is what the run is paying to write.
    @Test func theDraftingStampLandsOnTheConversationTheRunWasScopedTo() throws {
        let ctx = ModelContext(try container())
        let a = repliedShow(ctx, key: "A", address: "a@x.org")
        let b = repliedShow(ctx, key: "B", address: "b@x.org")
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())

        ProspectMutations.draftReply("B", "b@x.org", prospects: prospects, context: ctx,
                                     feedback: ActionFeedback(), start: { _, _ in })

        #expect(b.replyDraftRequestedAt != nil)
        #expect(a.replyDraftRequestedAt == nil,
                "a draft requested on one conversation must not stamp another as drafting.")
    }

    // The class, not the instance (L30). #2129 scoped the reply panel's button and left the card's on the
    // unscoped batch, and nothing said so. The class is a paid detached run whose SCOPE is an optional
    // argument, so a caller that omits it gets everything waiting rather than a compiler error, and the
    // omission reads like every other call. Prep's launcher has the same shape (`includedKeys:`), so it
    // is held to the same rule here rather than left for the next issue to find.
    //
    // Only the sweep at launch may go unscoped: it exists to classify whatever is waiting. Everything
    // else is a control Dan pressed on ONE thing.
    @Test func everyPaidRunLaunchedInTheAppNamesWhatItMaySpendOn() throws {
        for run in Self.paidRuns {
            var launches = 0
            for file in AppSourceWalk.appFiles() {
                let code = SwiftSource.scannableLines(in: file.text, skipping: []).map(\.code).joined(separator: "\n")
                var from = code.startIndex
                while let call = code.range(of: run.launch, range: from..<code.endIndex) {
                    from = call.upperBound
                    // The declaration itself, whose parameter list is not a call.
                    guard !code[..<call.lowerBound].hasSuffix("func ") else { continue }
                    guard let arguments = Self.arguments(from: call.upperBound, in: code) else {
                        Issue.record("Could not read the arguments of a \(run.launch) call in \(file.name).")
                        continue
                    }
                    // The service's own API, told from a call to an injected test seam by the label the
                    // service takes and a seam does not.
                    guard arguments.contains("from:") else { continue }
                    launches += 1
                    guard !arguments.contains(run.scope) else { continue }
                    let caller = Self.enclosingFunction(before: call.lowerBound, in: code) ?? "an unnamed scope"
                    #expect(run.unscopedCallers.contains(caller),
                            """
                            \(file.name): \(caller) launches \(run.what) without naming `\(run.scope)`, so one \
                            press spends across everything waiting in a single paid run and its Cancel \
                            abandons all of it. Only the sweep at launch may do that; a control pressed on \
                            one conversation or one show names that one (#2944, #2129).
                            """)
                }
            }
            #expect(launches >= 1,
                    """
                    This guard found no \(run.launch) calls in the app at all, so it is checking nothing \
                    about \(run.what) (L98).
                    """)
        }
    }

    // The paid detached runs the app launches, the argument each takes to say what it may spend on, and
    // the batch launches allowed to omit it, named by the function they sit in. An allowlist of what is
    // EXEMPT, so anything the walk finds that is missing from it is checked rather than excused (L96).
    private struct PaidRun {
        let launch: String
        let scope: String
        let what: String
        let unscopedCallers: [String]
    }

    private static let paidRuns = [
        PaidRun(launch: "startClassify(", scope: "only:", what: "the reply drafter",
                unscopedCallers: ["startReplyClassifyIfNeeded"]),
        PaidRun(launch: "startPrep(", scope: "includedKeys:", what: "a Prep run",
                unscopedCallers: []),
    ]

    // The one hop the seam hides. The spy stands in for `launchReplyDrafter`, so nothing in the suite
    // watches the real one forward the scope it was handed: writing `only: nil` there is the whole of
    // #2944 again, and it would satisfy both guards above (the spy never runs it, and the guard on the
    // words sees `only:` written). One line, so the words are what is checked.
    @Test func theLiveLauncherForwardsTheScopeItWasHanded() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        let body = try SourceGuard.functionBody(named: "launchReplyDrafter", in: source)
        #expect(body.contains("only: target"),
                """
                launchReplyDrafter no longer hands the drafter the target it was given, so every button \
                that scopes a draft is spending across every waiting conversation again (#2944).
                """)
    }

    // The balanced argument list of a call whose "(" has just been passed.
    private static func arguments(from open: String.Index, in code: String) -> String? {
        var depth = 1
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(code[open..<index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    // The name of the function a call sits inside: the nearest `func ` declared ahead of it.
    private static func enclosingFunction(before call: String.Index, in code: String) -> String? {
        guard let keyword = code.range(of: "func ", options: .backwards, range: code.startIndex..<call)
        else { return nil }
        let name = code[keyword.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

// The drafter launch, recorded instead of started. The real one spends money in a detached run, so the
// call site's scope is read here rather than by paying to watch what the run does.
@MainActor
private final class ReplyDrafterLaunchSpy {
    private(set) var targets: [ReplyClassifyService.Target?] = []
    func record(_ context: ModelContext, _ target: ReplyClassifyService.Target?) {
        targets.append(target)
    }
}
