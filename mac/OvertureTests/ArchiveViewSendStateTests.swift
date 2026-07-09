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
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved, draftSubject: "S", draftBody: "Hi", hasPendingRecipient: true)
    }

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @Test func noOutboundSendShowsTheSendButton() throws {
        let view = ArchiveView()

        _ = try view.row(approvedItemWithDraft(), context: context(), feedback: ActionFeedback())
            .inspect().find(button: "Send")
    }

    @Test func anInFlightOutboundSendShowsTheLiveLabelInsteadOfTheButton() throws {
        let view = ArchiveView()
        let since = Date(timeIntervalSince1970: 1000)

        let rendered = view.row(approvedItemWithDraft(), context: try context(), feedback: ActionFeedback(),
                                outboundSendSince: since)
        #expect((try? rendered.inspect().find(button: "Send")) == nil)
        let texts = try rendered.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.hasPrefix("Sending") })
    }
}
