import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #879: #846 put "Drafted by opus" on the two surfaces where Dan reviews a draft before it goes
// out, but that panel disappears once a show is archived, so the trace never survived to the one
// place it is actually most useful: comparing outcomes across models. The row's persistent tags
// (fitReason, coverage, contact count, …) are the one part of the card that keeps showing after a
// show is archived, so the trace belongs there, not only inside DraftReviewView.
@Suite("ProspectRowView draft trace tag (#879)")
struct ProspectRowViewDraftTraceTests {
    private func item(draftModel: String?) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-08-01", sourceListingURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        i.draftModel = draftModel
        return i
    }

    // Archived / no draft body: the review panel isn't rendering, so the row badge is where the trace
    // survives (the whole point of #879).
    @Test func aDraftedShowShowsWhichModelWroteIt() throws {
        let view = ProspectRowView(item: item(draftModel: "opus"), today: "2026-07-09",
                                   onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("Drafted by opus") })
    }

    // #1136: a card still in review (it has a draft body, so the DraftReviewView panel renders and shows
    // "Drafted by opus" next to "Edited"). The row badge must NOT restate it, so the trace appears exactly
    // once on the card, not twice.
    @Test func aCardStillInReviewShowsTheTraceExactlyOnce() throws {
        var reviewing = item(draftModel: "opus")
        reviewing.draftBody = "Hello, I photograph performances."   // hasDraft -> the panel renders
        let view = ProspectRowView(item: reviewing, today: "2026-07-09", onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.filter { $0.contains("Drafted by opus") }.count == 1)
    }

    @Test func noModelStampShowsNoTraceTag() throws {
        let view = ProspectRowView(item: item(draftModel: nil), today: "2026-07-09",
                                   onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("Drafted by") })
    }

    // #378-adjacent: a stamp that degrades to blank text (record_model's own failure mode, see
    // DraftTrace's doc comment) must read as no trace at all, never a half sentence naming nobody.
    @Test func aBlankModelStampShowsNoTraceTag() throws {
        let view = ProspectRowView(item: item(draftModel: "   "), today: "2026-07-09",
                                   onKeep: {}, onDismiss: { _ in })

        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!texts.contains { $0.contains("Drafted by") })
    }
}
