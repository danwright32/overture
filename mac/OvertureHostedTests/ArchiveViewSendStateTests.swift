import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #710: retrofits the #470 ViewInspector harness onto ArchiveView, the third of the three
// consumers that issue named. ArchiveView reuses ProspectRowFactory exactly as QueueView does
// (comment at the top of ArchiveView.swift), so this proves ArchiveView's OWN outboundSending
// dict threads through ProspectRowFactory into the rendered branch, the integration link one
// level up from what ProspectRowViewSendStateTests already covers for ProspectRowView itself.
@MainActor
@Suite("ArchiveView send state (#710)")
struct ArchiveViewSendStateTests {
    private func approvedItemWithDraft() -> QueueItem {
        QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi", hasPendingRecipient: true)
    }

    // #3655 Phase 5: `ArchiveView.row` takes a ROW and resolves its card through the store, which is the
    // one place a drawn row turns into a card and the only thing that records the key for the next pass.
    // So this hands it a store already holding exactly the card the test built, which keeps the assertion
    // about send-state threading and nothing else, while still driving the real row-request path.
    private func store(holding item: QueueItem) -> QueueModel.CardStore {
        QueueModel.CardStore(cards: [item.id: item], shows: [], contactsByKey: [:],
                             preamble: QueueModel.CardPreamble(
                                linked: [:], inherited: [:],
                                venueBrands: ProducerGate.VenueBrands(shows: [], overrides: .none),
                                rowCounts: [:], calendarBySourceId: [:], overrides: .none,
                                clients: .none, now: Date(), day: "2026-08-01"),
                             requestedKeys: [item.id])
    }

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @Test func noOutboundSendShowsTheSendButton() throws {
        let view = ArchiveView()

        let item = approvedItemWithDraft()

        _ = try view.row(QueueScopeRow(item), cards: store(holding: item),
                         context: context(), feedback: ActionFeedback())
            .inspect().find(button: SendConfirmCopy.openReview)
    }

    @Test func anInFlightOutboundSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let view = ArchiveView()
        let since = Date(timeIntervalSince1970: 1000)

        let item = approvedItemWithDraft()

        let rendered = view.row(QueueScopeRow(item), cards: store(holding: item),
                                context: try context(), feedback: ActionFeedback(),
                                outboundSendSince: since)
        #expect((try? rendered.inspect().find(button: SendConfirmCopy.openReview)) == nil)
        let texts = try rendered.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }
}
