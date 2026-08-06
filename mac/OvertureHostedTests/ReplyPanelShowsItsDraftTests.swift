import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #2143, the half only a rendered panel can answer.
//
// ReplyPanel deciding what the box should open with proves nothing about the panel putting it there: a
// seam and its wiring are two separate claims (L3). This is the claim that failed, since the decision
// never existed and the view held a hard-coded empty string.
@MainActor
@Suite("The reply panel renders the draft waiting on the contact (#2143)")
struct ReplyPanelShowsItsDraftTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Dan's real row (#2151): Every Voice Choirs, answered by the contact he pitched.
    private func panel(draft: String? = nil, requestedAt: Date? = nil) throws -> ReplySheet {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-10-31", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "nbecker@everyvoicechoirs.org", email: "nbecker@everyvoicechoirs.org",
                          provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailThreadId = "t"
        r.replied = true
        r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        r.lastReplyText = "Tuesday works for us."
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]
        r.replyDraftBody = draft
        r.replyDraftRequestedAt = requestedAt
        p.setRecipients([r])
        return ReplySheet(composition: .answering(r, of: p, context: ctx, feedback: ActionFeedback()),
                          gmailConnected: true)
    }

    // The defect: the drafted words are in the box Dan types in, not only in the Archive he never opens.
    @Test func aWaitingDraftIsInTheComposeBox() throws {
        let view = try panel(draft: "Tuesday suits me. I'll bring the 85mm and shoot the second half.")
        let typed = try view.inspect().find(ViewType.TextEditor.self).input()
        #expect(typed == "Tuesday suits me. I'll bring the 85mm and shoot the second half.")
    }

    // Hand-written is still the default, so a contact with no draft opens on an empty box as before.
    @Test func noDraftOpensAnEmptyBox() throws {
        let view = try panel()
        #expect(try view.inspect().find(ViewType.TextEditor.self).input() == "")
    }

    // A run that has been asked for and has not come back is a live run on screen: elapsed time and a
    // stall state, never a button that was pressed and then nothing (CLAUDE.md's working / still-alive /
    // failed rule). The label is asserted by the run it names and the request it counts from, so it
    // cannot pass while pointing at nothing.
    @Test func aDraftOnItsWayIsShownAsALiveRun() throws {
        let requested = Date(timeIntervalSince1970: 1_000)
        let view = try panel(requestedAt: requested)
        let label = try view.inspect().find(LiveRunLabel.self).actualView()
        #expect(label.base == ReplyPanelCopy.drafting)
        #expect(label.since == requested)
        #expect(label.timeout == RunTimeouts.replyDraft)
    }

    // And a panel with no run out carries no run label, so the drafting line cannot become furniture
    // that is always on screen and therefore never read.
    @Test func aPanelWithNoRunOutShowsNoDraftingLine() throws {
        let view = try panel(draft: "Tuesday suits me.", requestedAt: Date(timeIntervalSince1970: 1_000))
        #expect(throws: (any Error).self) {
            _ = try view.inspect().find(LiveRunLabel.self)
        }
    }
}
