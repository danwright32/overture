import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let confirmProposedGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com", threadId: "t1")
// #2718: what happens when Dan answers the question.
//
// The proposal is stored in full so the ROW needs no Gmail call to ask. Answering does need one, because
// the attach runs detection over the real thread and cannot do that from six stored fields.
@MainActor
@Suite("Confirming a proposed conversation (#2718)")
struct ConfirmProposedConversationTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let route = "https://www.corinhale.example/contact"

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func pitchWithProposal(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "form:\(route)", email: nil, name: "Corin Hale", provenance: .act)
        r.contactFormURL = route
        r.formOutreachURL = route
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        ProposedConversation.propose(
            .init(messageId: "m1", threadId: "t1", fromAddress: "corin.hale@example.com",
                  fromName: "Corin Hale", subject: "Re: the anniversary show",
                  sentAt: now.addingTimeInterval(-3600), score: 9), on: r, now: now)
        return r
    }

    private func threadData() -> Data {
        confirmProposedGmail.thread([
            .init(from: "Corin Hale <corin.hale@example.com>",
                  subject: "Re: the anniversary show", messageID: "<theirs@mail.gmail.com>",
                  id: "m1", internalDateMillis: Int64(now.timeIntervalSince1970 - 3600) * 1000),
        ])
    }

    private func gmail(status: Int = 200) -> (URLRequest) async throws -> (Data, URLResponse) {
        let body = threadData()
        return { req in
            (status == 200 ? body : Data(),
             HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("confirming links the conversation and takes the question down")
    func confirmingLinksAndClearsTheQuestion() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = pitchWithProposal(ctx, on: p)

        let outcome = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, now: now, token: "tok", fetch: gmail())

        guard case .attached = outcome else { Issue.record("expected an attach, got \(outcome)"); return }
        #expect(r.gmailThreadId == "t1")
        #expect(r.email == "corin.hale@example.com")
        #expect(r.replied)
        #expect(ProposedConversation.stored(on: r) == nil)
    }

    // Confirming is not the same as declining, and collapsing the two would record the conversation Dan
    // just accepted as one he had rejected.
    @Test("confirming does not record the conversation as declined")
    func confirmingIsNotADecline() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = pitchWithProposal(ctx, on: p)

        _ = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, now: now, token: "tok", fetch: gmail())

        #expect(ProposedConversation.declined(r).isEmpty)
    }

    @Test("a Gmail failure is reported as a failure, and changes nothing")
    func aGmailFailureChangesNothing() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = pitchWithProposal(ctx, on: p)

        let outcome = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, now: now, token: "tok", fetch: gmail(status: 503))

        guard case .failed = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(r.gmailThreadId == nil)
        #expect(ProposedConversation.stored(on: r) != nil, "the question is still a real question")
    }

    // The question STAYS on a refusal. Taking it down would leave Dan with a row that had silently
    // stopped asking and nothing on screen saying why (L109, L142).
    @Test("a refused attach leaves the question standing")
    func aRefusedAttachLeavesTheQuestionStanding() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = pitchWithProposal(ctx, on: p)
        ContactRefusal.refuse(email: "corin.hale@example.com", scope: .show(p.naturalKey),
                              in: ctx, now: now)

        let outcome = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, now: now, token: "tok", fetch: gmail())

        guard case .refused(let reason) = outcome else {
            Issue.record("a struck address must refuse, got \(outcome)"); return
        }
        #expect(reason.contains("corin.hale@example.com"))
        #expect(ProposedConversation.stored(on: r) != nil)
        #expect(r.gmailThreadId == nil)
    }

    // A link is a claim about the store, so it is only true once the write commits (L12).
    @Test("a save failure is reported rather than read as a clean link")
    func aSaveFailureIsReported() async throws {
        struct Nope: Error {}
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = pitchWithProposal(ctx, on: p)

        let outcome = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, now: now, token: "tok",
                     save: { throw Nope() }, fetch: gmail())

        #expect(outcome == .attached(alreadyAnswered: false, saveFailed: true))
    }

    @Test("confirming with nothing proposed is refused")
    func confirmingNothingIsRefused() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "form:\(route)", email: nil, provenance: .act)
        r.formOutreachRecordedAt = now
        p.addRecipient(r)

        let outcome = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, now: now, token: "tok", fetch: gmail())

        guard case .refused = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
    }
}
