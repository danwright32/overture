import Testing
import Foundation
import SwiftData

private let pickerRouteGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com",
                                            threadId: "thread-they-started")

// #3712 (milestone 82, Phase 6): the route #3706 exists for, driven end to end rather than a phase at a
// time.
//
// Phases 1 to 4 were each proved on their own subject: phase 1 that the menu OFFERS the picker on an
// emailed pitch, phase 2 that the picker READS the mailbox back to the pitch, phase 3 that
// `AttachConversation.attach` LANDS on a contact that already holds a thread. Every one of them passed.
// What no test drove is the sequence `LinkReplyPicker.link` actually performs, which is
// `ProposedConversation.clear`, then `propose`, then `ConfirmProposedConversation.confirm`, and `propose`
// is guarded by `isAskable`: a hand-sent FORM pitch with no conversation. An emailed pitch is neither
// half of that, so the candidate Dan picked was never stored, `confirm` found nothing standing and
// refused with "nothing linked", and the control the whole milestone exists to put on the row could not
// do its job (L3: built is not wired, and wired is not proven).
//
// Every test injects `now` (L130).
@MainActor
@Suite("Linking a reply through the picker, end to end (#3712)")
struct LinkReplyPickerRouteTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let pitched = "producer@presenter.example"
    private let writer = "performer@theirown.example"

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "show-key", groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // #3706's live shape: emailed, holding the thread the pitch went out on, no reply recorded.
    private func emailedPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: pitched, email: pitched, name: "Corin Hale", provenance: .presenter)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-9 * 86_400)
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.gmailThreadId = "thread-we-sent-on"
        p.addRecipient(r)
        return r
    }

    private let candidate = ProposedConversation.Candidate(
        messageId: "msg-1", threadId: "thread-they-started", fromAddress: "performer@theirown.example",
        fromName: "Casey Nunn", subject: "Photos for the run?",
        sentAt: Date(timeIntervalSince1970: 1_786_000_000 - 3600), score: 6)

    private func gmail() -> (URLRequest) async throws -> (Data, URLResponse) {
        let body = pickerRouteGmail.thread([
            .init(from: "Casey Nunn <\(writer)>", subject: "Photos for the run?",
                  messageID: "<theirs@mail.gmail.com>", id: "msg-1",
                  internalDateMillis: Int64(now.timeIntervalSince1970 - 3600) * 1000)
        ])
        return { req in
            (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    // Exactly what `LinkReplyPicker.link` does, in its order, so the test fails for the reason the app
    // fails rather than for one a helper invented.
    private func pickFromTheList(_ c: ProposedConversation.Candidate,
                                 on r: Recipient, of p: Prospect,
                                 in ctx: ModelContext) async -> ConfirmProposedConversation.Outcome {
        return await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, picked: c, now: now, token: "tok", fetch: gmail())
    }

    @Test("picking a message on an emailed pitch links it")
    func pickingOnAnEmailedPitchLinksIt() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)

        let outcome = await pickFromTheList(candidate, on: r, of: p, in: ctx)

        guard case .attached = outcome else {
            Issue.record("expected an attach, got \(outcome)"); return
        }
        #expect(r.gmailThreadId == "thread-they-started")
        #expect(r.attachDisplacedThreadId == "thread-we-sent-on")
        #expect(r.replied)
    }

    // The helper above REPRODUCES the picker's sequence, so on its own it proves what the test does
    // rather than what the app does (L27). This is the half that says the app still does it: the picker
    // hands the candidate over, and does not write it to the store first.
    @Test("the picker hands the candidate to confirm rather than storing it first")
    func thePickerHandsTheCandidateOver() {
        let body = SourceGuardHelper.bodyOfFunction(
            named: "link", in: SourceGuardHelper.source("Overture/UI/LinkReplyPicker.swift"))
        let link = try! #require(body)
        #expect(SourceGuardHelper.containsCode("picked: candidate", in: link),
                "the pick has to reach confirm as an argument")
        #expect(!SourceGuardHelper.containsCode("ProposedConversation.propose", in: link),
                "storing it through propose is what `isAskable` silently dropped on an emailed pitch")
    }

    // What the removed write cost, on the row it was written for. The picker cleared any standing
    // automatic proposal on its way past, so a hand link that then failed at Gmail took down a question
    // Dan had never answered and nothing said so (L5).
    @Test("a manual link that fails leaves a standing automatic question alone")
    func aFailedManualLinkLeavesTheStandingQuestionAlone() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        r.formOutreachRecordedAt = now.addingTimeInterval(-9 * 86_400)   // askable, so one can stand
        r.gmailThreadId = nil
        let standing = ProposedConversation.Candidate(
            messageId: "auto-1", threadId: "thread-overture-found", fromAddress: "someone@presenter.example",
            fromName: "Ivy Marchetti", subject: "Re: photographing the run",
            sentAt: now.addingTimeInterval(-7200), score: 8)
        ProposedConversation.propose(standing, on: r, now: now)

        let outcome = await ConfirmProposedConversation(fromEmail: me)
            .confirm(on: r, of: p, in: ctx, picked: candidate, now: now, token: "tok",
                     fetch: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 503,
                                                              httpVersion: nil, headerFields: nil)!) })

        guard case .failed = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(ProposedConversation.stored(on: r) == standing,
                "the question Overture asked is still standing and still unanswered")
    }
}
